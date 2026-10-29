import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'native.dart';

/// Real bridge to ca.psiphon:psiphontunnel (Psiphon-Labs/psiphon-tunnel-core-Android-library)
/// via MainActivity.kt's PsiphonBridge. This talks to Psiphon's actual, documented API
/// (PsiphonTunnel.HostService); it does not simulate a connection.
///
/// How other Psiphon-based apps actually do this, and what changed here:
/// Shir o Khorshid and the official client embed a full bootstrap set at
/// build time (SponsorId, PropagationChannelId, plus a remote server list
/// URL and its signature key). They do not ask the user to type IDs, and
/// they do not start with no servers at all. The previous V2rayAG build
/// did both of those things wrong: it sent only SponsorId/ChannelId and
/// no server-list bootstrap, so even a valid pair had nowhere to go.
/// This build therefore supplies a bootstrap by default, from the PUBLIC
/// sample config published for tunnel-core (the same sample used in
/// public docs and sample configs, not another app's private IDs):
/// generic sample Sponsor/Channel values plus the public remote server
/// list URL and its public signature key. A repo secret can replace the
/// whole bootstrap without a code change (PSIPHON_JSON, base64 in
/// dart-define PSIPHON_B64, JSON keys: sponsorId, propagationChannelId,
/// remoteServerListUrl, remoteServerListSignaturePublicKey). Manually
/// entered IDs in the app still override the built-in bootstrap.
/// Honest limit, unchanged: "connected" is only reported after real
/// traffic passes through the local proxy (see _verify). If the public
/// sample bootstrap does not connect from the user's network, the app
/// reports failure, it does not fake a connection. That outcome can only
/// be settled by testing the built app on a real phone, which this
/// environment cannot do.
/// Kept fully independent of PoolEngine (the VLESS/V2ray engine): different lifecycle, different
/// native library, no shared state, so it can be changed or removed without touching Automatic,
/// CDN or Personal mode.
enum PsiphonPhase { idle, needsConfig, connecting, connected, failed }

class PsiphonState {
  final PsiphonPhase phase;
  final String message;
  final int? socksPort, httpPort;
  final String? exitIp, location, region;
  final int? pingMs;
  final DateTime? connectedAt;
  final double downSpeed, upSpeed;
  final int downTotal, upTotal;
  const PsiphonState({
    this.phase = PsiphonPhase.idle,
    this.message = '',
    this.socksPort,
    this.httpPort,
    this.exitIp,
    this.location,
    this.region,
    this.pingMs,
    this.connectedAt,
    this.downSpeed = 0,
    this.upSpeed = 0,
    this.downTotal = 0,
    this.upTotal = 0,
  });
}

class PsiphonEngine {
  static const _m = MethodChannel('v2rayag/psiphon');
  static const _e = EventChannel('v2rayag/psiphon/events');

  final _ctrl = StreamController<PsiphonState>.broadcast();
  Stream<PsiphonState> get states => _ctrl.stream;
  void Function(String) log = (_) {};

  // Built-in public sample bootstrap (see comment above). Not private IDs.
  static const _publicSponsor = 'FFFFFFFFFFFFFFFF';
  static const _publicChannel = 'FFFFFFFFFFFFFFFF';
  static const _publicRemoteUrl = 'https://s3.amazonaws.com//psiphon/web/mjr4-p23r-puwl/server_list_compressed';
  static const _publicRemoteKey = 'MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM=';

  String _remoteUrl = _publicRemoteUrl;
  String _remoteKey = _publicRemoteKey;

  Map<String, String>? _secretBootstrap() {
    const b64 = String.fromEnvironment('PSIPHON_B64');
    if (b64.isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(base64Decode(b64)));
      if (decoded is! Map) return null;
      return {for (final e in decoded.entries) '${e.key}': '${e.value ?? ''}'};
    } catch (_) {
      return null;
    }
  }


  StreamSubscription? _sub;
  Timer? _tick;
  Timer? _liveTick;
  int? _baseRx, _baseTx, _lastRx, _lastTx;
  DateTime? _lastLiveAt;
  PsiphonState _s = const PsiphonState();
  bool _wanted = false;
  // v48: a verification already in flight (duplicate 'connected'
  // events must not run a second one concurrently and reset the timer).
  bool _verifying = false;
  // v48: when a connected tunnel starts re-dialing (see 'connecting'
  // below), the moment the re-dial began. After 60s without
  // re-establishing, the session honestly drops to connecting.
  DateTime? _redialAt;

  PsiphonState get state => _s;
  void _set(PsiphonState s) {
    _s = s;
    _ctrl.add(s);
  }

  void init() {
    _sub ??= _e.receiveBroadcastStream().listen(_onEvent, onError: (e) => log('Psiphon event error: $e'));
  }

  Future<bool> isConfigured() async {
    try {
      return await _m.invokeMethod<bool>('configured') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// v48: current native tunnel state, for session restore on app
  /// reopen. Ports above zero mean the tunnel process is still alive
  /// and listening; Dart still re-probes traffic before restoring.
  Future<Map<String, dynamic>?> status() async {
    try {
      final r = await _m.invokeMethod('status');
      return r is Map ? Map<String, dynamic>.from(r) : null;
    } catch (_) {
      return null;
    }
  }

  /// v48: restore a previously verified session (app reopened while
  /// the tunnel kept running). The caller already confirmed live
  /// listening ports via [status]; the bridge's re-emitted 'connected'
  /// event then refreshes ping/location without resetting the timer.
  void restoreConnected({
    required int socksPort,
    required int httpPort,
    String? exitIp,
    String? location,
    String? region,
    DateTime? connectedAt,
  }) {
    _wanted = true;
    _redialAt = null;
    _set(PsiphonState(
      phase: PsiphonPhase.connected,
      message: 'Connected',
      socksPort: socksPort,
      httpPort: httpPort,
      exitIp: exitIp,
      location: location,
      region: region,
      connectedAt: connectedAt ?? DateTime.now(),
    ));
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 20), (_) => _recheck());
    _startLive();
  }

  // v46: no manual IDs any more (the setup page no longer asks for
  // them). The secret bootstrap wins, otherwise the built-in public
  // sample bootstrap is used, so Psiphon always has servers to try.
  Future<void> configure({String egressRegion = '', String upstreamProxy = ''}) async {
    final secret = _secretBootstrap();
    var s = '';
    var c = '';
    _remoteUrl = _publicRemoteUrl;
    _remoteKey = _publicRemoteKey;
    if (secret != null) {
      s = (secret['sponsorId'] ?? '').trim();
      c = (secret['propagationChannelId'] ?? '').trim();
      if ((secret['remoteServerListUrl'] ?? '').isNotEmpty) _remoteUrl = secret['remoteServerListUrl']!;
      if ((secret['remoteServerListSignaturePublicKey'] ?? '').isNotEmpty) _remoteKey = secret['remoteServerListSignaturePublicKey']!;
    }
    if (s.isEmpty && c.isEmpty) {
      s = _publicSponsor;
      c = _publicChannel;
      log('Psiphon: using built-in public sample bootstrap');
    }
    try {
      await _m.invokeMethod('setup', {
        'sponsorId': s,
        'propagationChannelId': c,
        'remoteServerListUrl': _remoteUrl,
        'remoteServerListSignaturePublicKey': _remoteKey,
        'egressRegion': egressRegion,
        'upstreamProxy': upstreamProxy,
      });
    } catch (e) {
      log('Psiphon configure failed: $e');
    }
  }

  Future<void> connect() async {
    if (_wanted) return;
    init();
    if (!await isConfigured()) {
      log('Psiphon: bridge reports not configured');
      _set(const PsiphonState(phase: PsiphonPhase.needsConfig, message: 'Psiphon could not be configured. Check the build bootstrap.'));
      return;
    }
    _wanted = true;
    _set(const PsiphonState(phase: PsiphonPhase.connecting, message: 'Starting Psiphon'));
    try {
      await _m.invokeMethod('start');
    } on PlatformException catch (e) {
      _wanted = false;
      log('Psiphon start failed: ${e.message}');
      _set(PsiphonState(phase: PsiphonPhase.failed, message: e.message ?? 'Could not start'));
    }
  }

  Future<void> disconnect() async {
    _wanted = false;
    _redialAt = null;
    _tick?.cancel();
    _liveTick?.cancel();
    try {
      await _m.invokeMethod('stop');
    } catch (_) {}
    _set(const PsiphonState());
  }

  void _onEvent(dynamic raw) {
    final j = Map<String, dynamic>.from(raw as Map);
    final event = '${j['event']}';
    switch (event) {
      case 'connecting':
        // v48: tunnel-core re-dials on its own when the network
        // changes, and starting the VPN layer IS a network change
        // (the VPN interface comes up). That re-dial used to surface
        // as a full disconnect right after the first connect: the UI
        // dropped to CONNECTING, the timer and exit info were thrown
        // away, then it all came back. The session never actually
        // stopped (the VPN layer keeps running through the proxy
        // listeners, which stay up across a re-dial), so while a
        // re-dial is in progress the connected state is kept, with
        // live speeds showing the real gap (0 while it re-establishes).
        // A genuine failure still ends the session via 'failed' below,
        // and a re-dial longer than 60s drops to connecting in _recheck.
        if (!_wanted) break;
        if (_s.phase == PsiphonPhase.connected) {
          _redialAt ??= DateTime.now();
          log('Psiphon: tunnel re-establishing, keeping session');
        } else {
          log('Psiphon: connecting');
          _set(PsiphonState(phase: PsiphonPhase.connecting, message: 'Connecting', socksPort: _s.socksPort, httpPort: _s.httpPort));
        }
        break;
      case 'waitingForNetwork':
        if (!_wanted) break;
        if (_s.phase == PsiphonPhase.connected) {
          _redialAt ??= DateTime.now();
          log('Psiphon: tunnel re-establishing, keeping session');
        } else {
          log('Psiphon: waiting for network connectivity');
          _set(PsiphonState(phase: PsiphonPhase.connecting, message: 'Waiting for network', socksPort: _s.socksPort, httpPort: _s.httpPort));
        }
        break;
      case 'socksPort':
        _s = PsiphonState(phase: _s.phase, message: _s.message, socksPort: j['port'] as int, httpPort: _s.httpPort);
        break;
      case 'httpPort':
        _s = PsiphonState(phase: _s.phase, message: _s.message, socksPort: _s.socksPort, httpPort: j['port'] as int);
        break;
      case 'connected':
        // v48: late events after a user disconnect must not start a
        // verification that then reports failure over a clean stop.
        if (!_wanted) break;
        _redialAt = null;
        if (_s.phase == PsiphonPhase.connected) {
          // Re-dial or re-emit for an already verified session: one
          // light probe to refresh ping/location, never a failure
          // verdict from this path, and the timer is preserved.
          _verify(light: true);
        } else {
          log('Psiphon: tunnel-core reports connected, verifying real traffic');
          _verify();
        }
        break;
      case 'failed':
        _wanted = false;
        _redialAt = null;
        log('Psiphon failed: ${j['error']}');
        _set(PsiphonState(phase: PsiphonPhase.failed, message: '${j['error'] ?? 'Connection failed'}'));
        break;
      case 'stopped':
        _tick?.cancel();
        _redialAt = null;
        if (_wanted) {
          // tunnel-core exited on its own; honest state, not a silent "still connected".
          log('Psiphon: tunnel exited');
          _set(const PsiphonState(phase: PsiphonPhase.failed, message: 'The Psiphon tunnel stopped'));
          _wanted = false;
        }
        break;
      case 'log':
        final msg = '${j['message']}';
        // v46: tunnel-core SOCKS warnings about clients probing UDP
        // (command 0x03) are benign noise: the tunnel carries traffic
        // fine while they spam, and logging each one turns Logs red
        // for a healthy connection. Drop them, keep everything else.
        if (!msg.contains('SOCKS proxy accept error')) log('[psiphon] $msg');
        break;
    }
  }

  HttpClient _client(Duration ct) {
    final c = HttpClient()..connectionTimeout = ct;
    final p = _s.httpPort;
    if (p != null && p > 0) c.findProxy = (_) => 'PROXY 127.0.0.1:$p';
    return c;
  }

  /// Proof, not assumption: a request must actually succeed through Psiphon's local proxy
  /// before this reports "connected". Mirrors the same honesty rule used for VLESS servers
  /// elsewhere in this app.
  /// Full verification for a fresh connect: up to 10 traffic probes,
  /// then connected (with timer and live speeds) or an honest failure.
  /// Light verification for an already connected session (re-dial or
  /// restore re-emit): a single probe that refreshes ping/location
  /// and preserves the timer; a failed light probe never ends the
  /// session, the periodic recheck keeps trying.
  Future<void> _verify({bool light = false}) async {
    if (_verifying) return;
    _verifying = true;
    try {
      if (light) {
        final ping = await _ping();
        if (ping > 0) {
          final geo = await _lookupIp();
          _set(PsiphonState(
            phase: PsiphonPhase.connected,
            message: 'Connected',
            socksPort: _s.socksPort,
            httpPort: _s.httpPort,
            exitIp: geo?['ip'] ?? _s.exitIp,
            location: geo?['loc'] ?? _s.location,
            region: (geo?['cc'] ?? '').isEmpty ? _s.region : geo?['cc'],
            pingMs: ping,
            connectedAt: _s.connectedAt ?? DateTime.now(),
            downSpeed: _s.downSpeed,
            upSpeed: _s.upSpeed,
            downTotal: _s.downTotal,
            upTotal: _s.upTotal,
          ));
        }
        return;
      }
      for (var i = 0; i < 10 && _wanted; i++) {
        final ping = await _ping();
        if (ping > 0) {
          final geo = await _lookupIp();
          _set(PsiphonState(
            phase: PsiphonPhase.connected,
            message: 'Connected',
            socksPort: _s.socksPort,
            httpPort: _s.httpPort,
            exitIp: geo?['ip'],
            location: geo?['loc'],
            region: (geo?['cc'] ?? '').isEmpty ? null : geo?['cc'],
            pingMs: ping,
            connectedAt: DateTime.now(),
          ));
          log('Psiphon CONNECTED: exit ${geo?['ip'] ?? 'unknown'} (${geo?['loc'] ?? ''}), ping $ping ms');
          _tick?.cancel();
          _tick = Timer.periodic(const Duration(seconds: 20), (_) => _recheck());
          _startLive();
          return;
        }
        await Future.delayed(const Duration(seconds: 1));
      }
      // A disconnect during verification is a clean stop, not a
      // failure: never report failed over it.
      if (!_wanted) return;
      log('Psiphon: tunnel-core connected but no traffic passed through its local proxy');
      _set(const PsiphonState(phase: PsiphonPhase.failed, message: 'Psiphon reported connected, but no traffic passed through the tunnel'));
      _wanted = false;
    } finally {
      _verifying = false;
    }
  }

  void _startLive() {
    _liveTick?.cancel();
    _baseRx = _baseTx = _lastRx = _lastTx = null;
    _lastLiveAt = null;
    _liveTick = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!_wanted || _s.phase != PsiphonPhase.connected) return;
      try {
        final b = await Native.bytes();
        if (b == null || b.length < 2) return;
        final now = DateTime.now();
        final prevRx = _lastRx, prevTx = _lastTx, prevAt = _lastLiveAt;
        _baseRx ??= b[0];
        _baseTx ??= b[1];
        _lastRx = b[0];
        _lastTx = b[1];
        _lastLiveAt = now;
        double down = _s.downSpeed, up = _s.upSpeed;
        if (prevRx != null && prevTx != null && prevAt != null) {
          final sec = now.difference(prevAt).inMilliseconds / 1000.0;
          if (sec > 0) {
            down = (b[0] - prevRx) / sec;
            up = (b[1] - prevTx) / sec;
            if (down < 0) down = 0;
            if (up < 0) up = 0;
          }
        }
        _set(PsiphonState(
          phase: _s.phase,
          message: _s.message,
          socksPort: _s.socksPort,
          httpPort: _s.httpPort,
          exitIp: _s.exitIp,
          location: _s.location,
          region: _s.region,
          pingMs: _s.pingMs,
          connectedAt: _s.connectedAt,
          downSpeed: down,
          upSpeed: up,
          downTotal: b[0] - (_baseRx ?? b[0]),
          upTotal: b[1] - (_baseTx ?? b[1]),
        ));
      } catch (_) {}
    });
  }

  Future<void> _recheck() async {
    if (!_wanted || _s.phase != PsiphonPhase.connected) return;
    // v48 safety valve for a kept-connected re-dial: if the tunnel
    // has not re-established after 60s, stop showing connected and
    // honestly show that it is still trying.
    if (_redialAt != null && DateTime.now().difference(_redialAt!).inSeconds > 60) {
      _redialAt = null;
      log('Psiphon: tunnel still re-establishing after 60s');
      _set(PsiphonState(phase: PsiphonPhase.connecting, message: 'Reconnecting', socksPort: _s.socksPort, httpPort: _s.httpPort));
      return;
    }
    final p = await _ping();
    if (p > 0) {
      _set(PsiphonState(
        phase: _s.phase,
        message: _s.message,
        socksPort: _s.socksPort,
        httpPort: _s.httpPort,
        exitIp: _s.exitIp,
        location: _s.location,
        region: _s.region,
        pingMs: p,
        connectedAt: _s.connectedAt,
        downSpeed: _s.downSpeed,
        upSpeed: _s.upSpeed,
        downTotal: _s.downTotal,
        upTotal: _s.upTotal,
      ));
    }
  }

  Future<int> _ping() async {
    for (final u in ['http://cp.cloudflare.com/generate_204', 'http://connectivitycheck.gstatic.com/generate_204']) {
      final c = _client(const Duration(seconds: 4));
      final sw = Stopwatch()..start();
      try {
        final r = await (await c.getUrl(Uri.parse(u))).close().timeout(const Duration(seconds: 5));
        await r.drain();
        if (r.statusCode == 204 || r.statusCode == 200) return sw.elapsedMilliseconds;
      } catch (_) {
      } finally {
        c.close(force: true);
      }
    }
    return -1;
  }

  Future<Map<String, String>?> _lookupIp() async {
    for (final u in ['http://ip-api.com/json', 'https://ipwho.is/']) {
      final c = _client(const Duration(seconds: 5));
      try {
        final res = await (await c.getUrl(Uri.parse(u))).close().timeout(const Duration(seconds: 6));
        final j = jsonDecode(await res.transform(utf8.decoder).join());
        if (j is! Map || j['success'] == false || j['status'] == 'fail') continue;
        final ip = '${j['ip'] ?? j['query'] ?? ''}';
        if (ip.isEmpty) continue;
        final loc = [j['city'], j['country'] ?? j['country_name']].where((e) => e != null && '$e'.isNotEmpty).join(', ');
        final cc = '${j['countryCode'] ?? j['country_code'] ?? ''}';
        return {'ip': ip, 'loc': loc, 'cc': cc};
      } catch (_) {
      } finally {
        c.close(force: true);
      }
    }
    return null;
  }

  /// Real download speed through Psiphon's local proxy, bounded to ~8s / ~6MB.
  Future<String> speedTest() async {
    final c = _client(const Duration(seconds: 6));
    final sw = Stopwatch()..start();
    var bytes = 0;
    try {
      final r = await (await c.getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=6000000'))).close().timeout(const Duration(seconds: 8));
      await for (final chunk in r.timeout(const Duration(seconds: 10))) {
        bytes += chunk.length;
        if (sw.elapsedMilliseconds > 8000) break;
      }
    } catch (_) {
    } finally {
      c.close(force: true);
    }
    final sec = sw.elapsedMilliseconds / 1000.0;
    if (bytes < 50000 || sec <= 0) return 'failed';
    return '${(bytes * 8 / sec / 1e6).toStringAsFixed(1)} Mbps';
  }
}
