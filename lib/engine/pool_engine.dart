import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show compute;

import 'fronting.dart';
import 'speed_test.dart';
import 'native.dart';
import 'providers.dart';
import 'tcp_probe.dart';
import 'vpn_core.dart';

/// From the `subscription-userinfo` header. expire 0 / total 0 = unlimited.
class SubInfo {
  final String url;
  final int upload, download, total, expire;
  final bool known;
  const SubInfo({
    required this.url,
    this.upload = 0,
    this.download = 0,
    this.total = 0,
    this.expire = 0,
    this.known = true,
  });

  factory SubInfo.parse(String url, String? header) {
    if (header == null || header.trim().isEmpty) {
      return SubInfo(url: url, known: false);
    }
    final m = <String, int>{};
    for (final part in header.split(';')) {
      final kv = part.split('=');
      if (kv.length == 2) {
        final v = num.tryParse(kv[1].trim());
        if (v != null) m[kv[0].trim().toLowerCase()] = v.toInt();
      }
    }
    return SubInfo(
      url: url,
      upload: m['upload'] ?? 0,
      download: m['download'] ?? 0,
      total: m['total'] ?? 0,
      expire: m['expire'] ?? 0,
    );
  }

  int get used => upload + download;
  int? get remaining => total == 0 ? null : max(0, total - used);
  bool usableAt(int nowSec) {
    final margin = total == 0 ? 0 : min(1048576, total ~/ 100);
    return !(expire != 0 && expire <= nowSec) && !(total != 0 && used >= total - margin);
  }
  bool get usable => usableAt(DateTime.now().millisecondsSinceEpoch ~/ 1000);
  Duration? get timeLeft {
    if (expire == 0) return null;
    final s = expire - DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return Duration(seconds: s < 0 ? 0 : s);
  }
}

class Candidate {
  final String link, remark, config;
  final SubInfo sub;
  int? delayMs;
  String? ipConfig;
  String get cfg => ipConfig ?? config;
  Candidate(this.link, this.remark, this.config, this.sub);
}

/// Subscription body -> share links (base64 or plain).
List<String> extractLinks(String body) {
  var t = body.trim();
  if (!t.contains('://')) {
    try {
      final b = t.replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/');
      t = utf8.decode(base64.decode(base64.normalize(b)), allowMalformed: true);
    } catch (_) {
      return [];
    }
  }
  final re = RegExp(r'^(vless|vmess|trojan|ss|hysteria2|hy2)://');
  return t.split(RegExp(r'[\r\n]+')).map((e) => e.trim()).where(re.hasMatch).toList();
}

/// File/text import: finds config links anywhere in the body, not only
/// at the start of a line, so surrounding text, JSON, commas, quotes and
/// labels are ignored and only real configs are returned. A whole-body
/// base64 subscription is decoded first, like extractLinks does.
List<String> extractConfigLinks(String body) {
  var text = body.trim();
  if (!text.contains('://')) {
    try {
      final b = text.replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/');
      text = utf8.decode(base64.decode(base64.normalize(b)), allowMalformed: true);
    } catch (_) {
      return [];
    }
  }
  final re = RegExp('(vless|vmess|trojan|ss|hysteria2|hy2)://[^\\s<>\\],;]+');
  final seen = <String>{};
  final out = <String>[];
  for (final m in re.allMatches(text)) {
    var link = m.group(0)!;
    while (link.endsWith('"') || link.endsWith("'")) {
      link = link.substring(0, link.length - 1);
    }
    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme.isEmpty) continue;
    if (seen.add(link)) out.add(link);
  }
  return out;
}

/// Spreads users out: random pick among the few servers near the best
/// delay measured for THIS user, not always the single best one.
Candidate chooseFrom(List<Candidate> ranked, Random rng) {
  final best = ranked.first.delayMs!;
  final limit = max(best * 1.25, best + 40.0);
  final near = ranked.where((c) => c.delayMs! <= limit).take(3).toList();
  return near[rng.nextInt(near.length)];
}

enum Phase { idle, searching, testing, connecting, connected, switching, failed }

class EngineState {
  final Phase phase;
  final int step; // 0 fetch, 1 test, 2 connect, 3 verify
  final String message;
  final String? configName, exitIp, location, realIp, proxyInfo, providerName;
  final bool tunOk;
  final int? delayMs;
  final SubInfo? sub;
  final CoreStatus traffic;
  const EngineState({
    this.phase = Phase.idle,
    this.step = 0,
    this.message = '',
    this.configName,
    this.exitIp,
    this.location,
    this.realIp,
    this.proxyInfo,
    this.providerName,
    this.tunOk = false,
    this.delayMs,
    this.sub,
    this.traffic = const CoreStatus(),
  });
}

class _Fetched {
  final SubInfo info;
  final List<String> links;
  _Fetched(this.info, this.links);
}

class _Proof {
  final bool ok, vpnUp;
  final Map<String, String>? geo;
  final int ping;
  _Proof(this.ok, this.vpnUp, this.geo, this.ping);
}

String _same(String s) => s;
bool _all(String s) => true;
void _noop(String s) {}

class PoolEngine {
  PoolEngine(
    this.core, {
    required this.poolUrls,
    this.maxCandidates = 120,
    this.probeBudget = const Duration(seconds: 12),
  });

  final VpnCore core;
  List<String> poolUrls;
  List<String> directLinks = [];
  List<String> blockedApps = [];
  bool keepOriginal = false, cdnFragment = false, proxyOnly = false, strictVerify = true;
  String fragLen = '100-200', fragInt = '10-20';
  bool Function(String)? fallbackFilter;
  List<String> priority = ['tr gaming'];
  String Function(String) transform = _same;
  bool Function(String) linkFilter = _all;
  void Function(String) log = _noop;
  final int maxCandidates;
  final Duration probeBudget;

  final _rng = Random.secure();
  final _ctrl = StreamController<EngineState>.broadcast();
  Stream<EngineState> get states => _ctrl.stream;

  StreamSubscription<CoreStatus>? _st;
  Timer? _watch, _subTimer, _tick;
  bool _wanted = false, _checking = false, _pingOk = false, _tunOk = false, _restarting = false;

  /// True while a single-config real test is using the core.
  bool testingReal = false;

  /// Show a connecting state immediately (e.g. while Smart/Auto is
  /// still refreshing providers, before any server is tried), so the
  /// power button does not sit on NOT CONNECTED for seconds.
  void announce(String msg) {
    if (_phase == Phase.idle || _phase == Phase.failed) {
      _phase = Phase.searching;
      _step = 0;
      _msg = msg;
      _emit();
    }
  }

  /// Report a final failure from outside the engine (Smart Connect's
  /// last step, after Psiphon itself gave up).
  void failWith(String msg) {
    _phase = Phase.failed;
    _msg = msg;
    _emit();
  }
  int _skipped = 0, _usableSubs = 0;
  int _fails = 0, _step = 0, _off = 0;
  final Set<String> _bad = {};
  List<Candidate> _ranked = [];
  Candidate? _cur;
  DateTime? _connectedAt;
  int? _proxyPort;
  String? _subUrl;
  List<ProviderBundle>? _bundles;
  int _bundleIdx = 0;
  BundleFetcher? _bundleFetcher;
  String? _bundleName;
  List<int>? _b0, _bl;

  Phase _phase = Phase.idle;
  String _msg = '';
  String? _name, _ip, _loc, _realIp, _proxyInfo;
  int? _delay;
  SubInfo? _sub;
  CoreStatus _traffic = const CoreStatus();
  CoreStatus? _live;

  String? _restoredLink;

  /// Real-delay test endpoint, set from Store (Settings → Real delay test URL).
  /// Default is Cloudflare's generate_204; the probe always falls back to
  /// gstatic and Cloudflare, so one blocked host never kills the real test.
  /// This is the same kind of endpoint NPV Tunnel and V2rayNG use:
  /// generate_204 answers with an empty 204, so the test measures a real
  /// round trip through the tunnel without downloading anything.
  String testUrl = 'https://cp.cloudflare.com/generate_204';
  List<String> get _testUrls {
    final out = <String>[];
    for (final u in [testUrl, 'https://www.gstatic.com/generate_204', 'http://cp.cloudflare.com/generate_204', 'http://connectivitycheck.gstatic.com/generate_204']) {
      if (u.isNotEmpty && !out.contains(u)) out.add(u);
    }
    return out;
  }
  String? get currentLink => _cur?.link ?? _restoredLink;
  String? get currentProvider => _bundleName;

  EngineState get state => EngineState(
        phase: _phase,
        step: _step,
        message: _msg,
        configName: _name,
        exitIp: _ip,
        location: _loc,
        realIp: _realIp,
        proxyInfo: _proxyInfo,
        providerName: _bundleName,
        tunOk: _tunOk,
        delayMs: _delay,
        sub: _sub,
        traffic: _live ?? _traffic,
      );
  void _emit() => _ctrl.add(state);

  Future<void> connect() async {
    if (_wanted) return;
    _wanted = true;
    _listen();
    try {
      _phase = Phase.searching;
      _step = 0;
      _msg = 'Fetching servers';
      _emit();
      if (!proxyOnly && !await core.requestPermission()) return _fail('VPN permission was not granted');
      _bad.clear();
      _ranked = [];
      _cur = null;
      await _hardStop();
      await _select(first: true);
    } catch (e) {
      log('Error: $e');
      await _fail('Could not connect: $e');
    }
  }

  /// Automatic mode with configurable provider priority: tries each enabled
  /// provider's configs in order and only moves to the next provider once the
  /// current one is fully exhausted. [refetch] is called by this engine (never
  /// by itself) whenever a restart needs fresh provider data.
  int _maxTriesPerBundle = 0;

  Future<void> connectOrdered(List<ProviderBundle> bundles, {required BundleFetcher refetch, int maxTriesPerBundle = 0}) async {
    if (_wanted) return;
    _maxTriesPerBundle = maxTriesPerBundle;
    _wanted = true;
    _bundleFetcher = refetch;
    _bundles = bundles;
    _listen();
    try {
      _phase = Phase.searching;
      _step = 0;
      _msg = 'Fetching servers';
      _emit();
      if (!proxyOnly && !await core.requestPermission()) return _fail('VPN permission was not granted');
      _bad.clear();
      _ranked = [];
      _cur = null;
      await _hardStop();
      if (bundles.isEmpty) return _fail('No enabled provider has usable configs. Enable a provider or refresh it.');
      _enterBundle(0);
      await _select(first: true);
    } catch (e) {
      log('Error: $e');
      await _fail('Could not connect: $e');
    }
  }

  void _enterBundle(int i) {
    final b = _bundles![i];
    _bundleIdx = i;
    _bundleName = b.name;
    poolUrls = [];
    directLinks = [...b.links];
    linkFilter = (_) => true;
    keepOriginal = false;
    transform = (l) => l;
    fallbackFilter = null;
    _ranked = [];
    log('Provider ${i + 1}/${_bundles!.length}: ${b.name} (${b.links.length} configs)');
  }

  void _listen() {
    _st ??= core.status.listen((s) {
      if (s.state != _traffic.state) log('Core state: ${s.state}');
      _traffic = s;
    });
  }

  /// What the app needs to show the same connection again after it is reopened.
  Map<String, dynamic> sessionJson() => {
        'link': _cur?.link ?? _restoredLink,
        'name': _name,
        'ip': _ip,
        'loc': _loc,
        'delay': _delay,
        'pingOk': _pingOk,
        'at': _connectedAt?.millisecondsSinceEpoch,
        'b0': _b0,
        'proxyInfo': _proxyInfo,
        'subUrl': _subUrl,
      };

  Future<bool> restore(Map<String, dynamic> j) async {
    final at = j['at'];
    if (at is! int) return false;
    _wanted = true;
    _listen();
    _name = j['name'] as String?;
    _ip = j['ip'] as String?;
    _loc = j['loc'] as String?;
    _delay = (j['delay'] as num?)?.toInt();
    _pingOk = j['pingOk'] == true;
    _proxyInfo = j['proxyInfo'] as String?;
    _subUrl = j['subUrl'] as String?;
    if (_subUrl != null && _subUrl!.isNotEmpty) _sub = SubInfo(url: _subUrl!, known: false);
    _connectedAt = DateTime.fromMillisecondsSinceEpoch(at);
    _restoredLink = j['link'] as String?;
    final b = j['b0'];
    if (b is List && b.length == 2) _b0 = [(b[0] as num).toInt(), (b[1] as num).toInt()];
    _proxyPort = await _findProxy(null);
    _fails = 0;
    _off = 0;
    _phase = Phase.connected;
    _msg = 'Connected';
    log('Reopened: the connection to $_name is still active');
    _startWatch();
    _emit();
    // Re-verify the exit IP through the restored tunnel. If the lookup
    // succeeds, refresh ip/loc; if it fails, keep the saved values rather
    // than showing dashes for a connection that is still alive.
    try {
      final geo = await _lookupIp();
      if (geo != null && (geo['ip'] ?? '').isNotEmpty) {
        _ip = geo['ip'];
        _loc = '${flagOf(geo['cc'] ?? '')} ${geo['loc'] ?? ''}'.trim();
        _emit();
      }
    } catch (_) {}
    _refreshSub();
    return true;
  }

  Future<void> disconnect() async {
    _wanted = false;
    _stopTimers();
    _bundles = null;
    _bundleIdx = 0;
    _bundleFetcher = null;
    _bundleName = null;
    _bad.clear();
    _ranked = [];
    _cur = null;
    _name = _ip = _loc = _proxyInfo = null;
    _restoredLink = null;
    _delay = null;
    _sub = null;
    _subUrl = null;
    _live = null;
    _b0 = _bl = null;
    _connectedAt = null;
    _tunOk = false;
    _traffic = const CoreStatus();
    _phase = Phase.idle;
    _msg = '';
    _emit();
    await _hardStop();
  }

  /// Stops the core and waits until Android really reports the old session as gone.
  /// Starting a new config too early is refused by the plugin ("active session was preserved").
  Future<void> _hardStop() async {
    try {
      await core.stop();
    } catch (_) {}
    _proxyPort = null;
    for (var i = 0; i < 12; i++) {
      final up = proxyOnly ? await _portOpen(10809) : (await Native.vpnActive() == true);
      if (!up) break;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    await Future.delayed(const Duration(milliseconds: 300));
  }

  /// A connection that was cut (quota or time ran out, server died): start over exactly like
  /// a fresh launch. Pool subscriptions are downloaded again, expired ones are skipped,
  /// nothing from the old list is reused, and it keeps trying until the user disconnects.
  Future<void> _restart(String why) async {
    if (_restarting || !_wanted) return;
    _restarting = true;
    try {
      log('Restarting from scratch: $why');
      _stopTimers();
      _phase = Phase.switching;
      _step = 0;
      _msg = 'Refreshing the pool';
      _emit();
      await _hardStop();
      _ranked = [];
      _bad.clear();
      _cur = null;
      _live = null;
      _sub = null;
      _subUrl = null;
      _name = _ip = _loc = _proxyInfo = null;
      _delay = null;
      _connectedAt = null;
      _b0 = _bl = null;
      _fails = 0;
      _off = 0;
      if (_bundleFetcher != null) {
        _bundles = await _bundleFetcher!();
        if (_bundles!.isEmpty) {
          await _fail('No enabled provider has usable configs. Enable a provider or refresh it.');
          return;
        }
        _enterBundle(0);
      }
      if (_wanted) await _select();
    } finally {
      _restarting = false;
    }
  }

  void _stopTimers() {
    _watch?.cancel();
    _subTimer?.cancel();
    _tick?.cancel();
  }

  Future<void> _fail(String m) async {
    _wanted = false;
    _stopTimers();
    _bad.clear();
    _ranked = [];
    _cur = null;
    await _hardStop();
    _live = null;
    _phase = Phase.failed;
    _msg = m;
    _emit();
  }

  // Remark matching ignores case, spaces, dashes and underscores, so
  // "TR GAMING", "TR-GAMING" and "TRGAMING" all count as the same
  // priority server (panels write the name slightly differently).
  static String _normRemark(String r) => r.toLowerCase().replaceAll(RegExp(r'[\s\-_]+'), '');
  bool _isPriorityRemark(String remark) {
    final n = _normRemark(remark);
    return priority.any((p) => n.contains(_normRemark(p)));
  }

  bool _isPriority(Candidate c) => _isPriorityRemark(c.remark);

  /// Order: configured priority servers first, then the best-ping ones (spread a little
  /// between near-equals), then every remaining config, so nothing is skipped.
  Candidate _next() {
    final pi = _ranked.indexWhere(_isPriority);
    if (pi >= 0) return _ranked.removeAt(pi);
    final reach = _ranked.where((c) => c.delayMs != null).toList();
    if (reach.isNotEmpty) {
      final c = chooseFrom(reach, _rng);
      _ranked.remove(c);
      return c;
    }
    return _ranked.removeAt(0);
  }

  Future<void> _select({bool first = false}) async {
    _phase = first ? Phase.searching : Phase.switching;
    _step = 0;
    _msg = first ? 'Fetching servers' : 'Switching server';
    _emit();
    if (_ranked.isEmpty) {
      final c = await _gather();
      if (!_wanted) return;
      _phase = Phase.testing;
      _step = 1;
      _msg = 'Testing servers on your network';
      _emit();
      _ranked = await _probe(c.where((x) => !_bad.contains(x.link)).toList());
      if (!_wanted) return;
    }
    var tries = 0;
    while (_ranked.isNotEmpty && _wanted && (_maxTriesPerBundle == 0 || tries < _maxTriesPerBundle)) {
      tries++;
      final c = _next();
      _phase = Phase.connecting;
      _step = 2;
      _msg = 'Connecting ($tries/${tries + _ranked.length})';
      _emit();
      log('Trying ${c.remark}${c.delayMs == null ? '' : ' (${c.delayMs} ms handshake)'}');
      String wrap(String x) => cdnFragment ? applyFragment(x, length: fragLen, interval: fragInt) : x;
      final cfgs = [wrap(c.cfg), if (c.ipConfig != null) wrap(c.config)];
      var cfg = cfgs.first;
      var started = false;
      for (final x in cfgs) {
        for (var a = 0; a < 2 && !started; a++) {
          try {
            await core.start(c.remark, x, blockedApps: blockedApps, proxyOnly: proxyOnly);
            cfg = x;
            started = true;
          } catch (e) {
            final stopping = proxyOnly ? await _portOpen(10809) : (await Native.vpnActive() == true);
            log('Start failed (${c.remark}): ${stopping ? 'the previous session was still stopping' : ('$e'.contains('INVALID_CONFIG') ? 'the core rejected this config' : e)}');
            if (!stopping) break;
            await _hardStop();
          }
        }
        if (started) break;
      }
      if (!started) {
        _bad.add(c.link);
        continue;
      }
      if (!_wanted) return;
      _step = 3;
      _msg = 'Verifying real traffic';
      _emit();
      final p = await _prove(c, cfg);
      if (!_wanted) return;
      if (p.ok) {
        _b0 = await Native.bytes();
        _bl = _b0;
        _finish(c, p);
        return;
      }
      _bad.add(c.link);
      try {
        await core.stop();
      } catch (_) {}
      _proxyPort = null;
    }
    if (!_wanted) return;
    if (_maxTriesPerBundle > 0 && tries >= _maxTriesPerBundle && _bundles != null && _bundleIdx < _bundles!.length - 1) {
      log('${_bundles![_bundleIdx].name}: $tries best configs tried, none carried traffic, trying the next provider');
      _enterBundle(_bundleIdx + 1);
      return _select(first: first);
    }
    if (!_wanted) return;
    if (_bundles != null && _bundleIdx < _bundles!.length - 1) {
      log('${_bundles![_bundleIdx].name}: no working server, trying the next provider');
      _enterBundle(_bundleIdx + 1);
      return _select(first: first);
    }
    if (first) {
      log('Gave up: every config was tried and none carried traffic');
      final msg = _bundles != null
          ? 'No enabled provider has a working server right now. Enable another provider or try again.'
          : (_usableSubs == 0 && _skipped > 0 ? 'All subscriptions are expired or out of data.' : 'No server carried real traffic. Open Logs for details.');
      return _fail(msg);
    }
    // Mid-session recovery never gives up: wrap back to the first provider and keep trying.
    if (_bundles != null) _enterBundle(0);
    _bad.clear();
    _msg = 'Looking for a working server';
    _emit();
    await Future.delayed(const Duration(seconds: 6));
    if (_wanted) await _select();
  }

  void _finish(Candidate c, _Proof p) {
    _cur = c;
    _name = c.remark;
    _sub = c.sub;
    _subUrl = c.sub.url;
    _ip = p.geo?['ip'];
    _loc = '${flagOf(p.geo?['cc'] ?? '')} ${p.geo?['loc'] ?? ''}'.trim();
    _pingOk = p.ping > 0;
    _delay = p.ping > 0 ? p.ping : c.delayMs;
    _fails = 0;
    _off = 0;
    _connectedAt = DateTime.now();
    _phase = Phase.connected;
    _msg = 'Connected';
    log('CONNECTED via ${c.remark}: ${_loc ?? ''}, ping $_delay ms${_pingOk ? '' : ', traffic NOT measured (strict check is off)'}');
    _startWatch();
    _emit();
    // v1.0.5: location was decoupled from the verdict above; fill it
    // in the background now that the session is connected.
    if (p.geo == null) _refreshGeoInBackground(c.link);
  }

  /// Truth test, in order:
  /// 1. VPN mode: Android itself must report an active VPN.
  /// 2. The core must answer a real request: through its local proxy, or through its own delay check.
  /// A changed IP address is only shown, never used as proof (some networks rotate IPs).
  Future<_Proof> _prove(Candidate c, String cfg) async {
    await Future.delayed(const Duration(milliseconds: 1200));
    bool? vpn = proxyOnly ? true : null;
    for (var i = 0; i < 7 && _wanted; i++) {
      if (!proxyOnly) {
        vpn = await Native.vpnActive();
        if (vpn == false) {
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
      }
      _proxyPort ??= await _findProxy(cfg);
      var ping = -1;
      if (_proxyPort != null) ping = await measurePing();
      if (ping <= 0 && !proxyOnly) {
        final d = await core.connectedDelay();
        if (d > 0) ping = d;
      }
      if (ping > 0) {
        if (_proxyPort != null) {
          final socks = await _portOpen(10808);
          _proxyInfo = 'HTTP 127.0.0.1:$_proxyPort${socks ? '  SOCKS5 127.0.0.1:10808' : ''}';
        }
        // v1.0.5: the verdict is the traffic proof. The geo lookup
        // was never proof (see the doc comment above) and ip
        // services can hang for seconds behind a tunnel, so it no
        // longer blocks "Connected": _finish triggers it in the
        // background and it fills ip/location on the card when it
        // lands.
        return _Proof(true, true, null, ping);
      }
      if (!strictVerify && !proxyOnly) {
        return _Proof(true, true, null, -1);
      }
      await Future.delayed(const Duration(seconds: 1));
    }
    if (proxyOnly) {
      log('${c.remark}: the local proxy did not answer or the server carried no traffic');
    } else if (vpn == false) {
      log('Android never reported an active VPN. The VPN service did not start (permission, another VPN app, or app setup).');
    } else {
      log('${c.remark}: the VPN is up but this server carried no traffic');
    }
    return _Proof(false, vpn != false, null, -1);
  }

  /// Location lookup, off the connect path: when it lands on a still-
  /// connected session, it fills ip/location and re-emits; it never
  /// delays or fails the connection itself. [link] pins the lookup
  /// to the session that requested it: if a failover already moved
  /// to another server, the stale answer is dropped instead of
  /// overwriting the new session's location.
  /// v1.0.6: two robustness fixes for the blank "-" card. In VPN
  /// mode a direct fetch already goes through the TUN, so it is a
  /// safe second path to the exit IP; in proxy-only mode a direct
  /// fetch would return the real IP, so it is never used as an
  /// exit-IP answer there. And if every source fails (the tunnel
  /// may still be settling: routes, DNS), it retries once after
  /// 20s instead of leaving the card blank forever. The verify
  /// speedup from v1.0.5 is untouched: this still never blocks
  /// "Connected".
  Future<void> _refreshGeoInBackground(String link) async {
    Future<Map<String, String>?> fetch() async {
      final g = await _lookupIp();
      if (g != null) return g;
      if (!proxyOnly) return _lookupIp(direct: true);
      return null;
    }

    var geo = await fetch();
    if (geo == null) {
      log('Location lookup failed, retrying in 20s');
      await Future.delayed(const Duration(seconds: 20));
      if (!_wanted || _phase != Phase.connected || _cur?.link != link) return;
      geo = await fetch();
    }
    if (geo == null || !_wanted || _phase != Phase.connected || _cur?.link != link) return;
    _ip = geo['ip'];
    _loc = '${flagOf(geo['cc'] ?? '')} ${geo['loc'] ?? ''}'.trim();
    log('Location: $_loc');
    _emit();
  }

  Future<bool> _portOpen(int port) async {
    try {
      final s = await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 400));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The core's local HTTP proxy, if it exposes one: it is the cleanest proof a config works.
  Future<int?> _findProxy(String? cfg) async {
    final cands = <int>{if (cfg != null && inboundPort(cfg, 'http') != null) inboundPort(cfg, 'http')!, 10809};
    for (final p in cands) {
      if (!await _portOpen(p)) continue;
      _proxyPort = p;
      if (await _ping1() > 0) return p;
      _proxyPort = null;
    }
    return null;
  }

  HttpClient _client(Duration ct) {
    final c = HttpClient()..connectionTimeout = ct;
    final p = _proxyPort;
    if (p != null) c.findProxy = (_) => 'PROXY 127.0.0.1:$p';
    return c;
  }

  Future<int> _ping1() async {
    // v1.0.5: all test endpoints are tried concurrently; the first
    // positive answer wins. Same URLs and timeouts as before.
    Future<int> attempt(String u) async {
      final c = _client(const Duration(seconds: 3));
      final sw = Stopwatch()..start();
      try {
        final r = await (await c.getUrl(Uri.parse(u))).close().timeout(const Duration(seconds: 4));
        await r.drain();
        if (r.statusCode == 204 || r.statusCode == 200) return sw.elapsedMilliseconds;
      } catch (_) {
      } finally {
        c.close(force: true);
      }
      return -1;
    }

    final results = await Future.wait(_testUrls.map(attempt));
    for (final r in results) {
      if (r > 0) return r;
    }
    return -1;
  }

  /// Real ping through the core's proxy: HTTP round trips on one kept-alive connection.
  /// Tries the user's test URL first, then the built-in fallbacks, and reports the
  /// median of the probes on the first endpoint that answers.
  Future<int> measurePing() async {
    // v1.0.5: all test endpoints are probed concurrently; the first
    // endpoint (in the user's configured order) that answers wins,
    // with the same median math as before. Same URLs, same timeouts
    // — only the waiting is parallel, so one dead endpoint no longer
    // costs its full timeout before the next is tried.
    Future<int> attempt(String url) async {
      final c = _client(const Duration(seconds: 4));
      final t = <int>[];
      try {
        for (var i = 0; i < 4; i++) {
          final sw = Stopwatch()..start();
          final r = await (await c.getUrl(Uri.parse(url))).close().timeout(const Duration(seconds: 4));
          await r.drain();
          if (i > 0) t.add(sw.elapsedMilliseconds);
        }
      } catch (_) {
      } finally {
        c.close(force: true);
      }
      if (t.isEmpty) return -1;
      t.sort();
      return t[t.length ~/ 2];
    }

    final results = await Future.wait(_testUrls.map(attempt));
    for (final r in results) {
      if (r > 0) return r;
    }
    return -1;
  }

  /// Real download speed (through the core's proxy when there is one).
  Future<String> speedTest() async {
    final c = _client(const Duration(seconds: 6));
    final sw = Stopwatch()..start();
    var bytes = 0;
    try {
      final r = await (await c.getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=8000000'))).close().timeout(const Duration(seconds: 10));
      await for (final chunk in r.timeout(const Duration(seconds: 12))) {
        bytes += chunk.length;
        if (sw.elapsedMilliseconds > 12000) break;
      }
    } catch (_) {
    } finally {
      c.close(force: true);
    }
    final sec = sw.elapsedMilliseconds / 1000.0;
    if (bytes < 50000 || sec <= 0) return 'failed';
    return '${(bytes * 8 / sec / 1e6).toStringAsFixed(1)} Mbps';
  }

  /// Detailed speed test through this engine's client (local proxy when
  /// known, otherwise the system TUN route). See speed_test.dart: no
  /// metric is ever invented; upload may be null (N/A) if the endpoint
  /// does not accept the test.
  /// Real single-config test, like V2rayNG's real delay test: start
  /// the core with this one config in local-proxy mode and fetch a
  /// real URL through it. Returns the median HTTP round trip in ms,
  /// -1 when the server carried no traffic (account expired, out of
  /// data, core-rejected, or unreachable), and -2 when the test could
  /// not run at all (core busy or already testing). A TCP/TLS probe
  /// alone is never used as a pass: only traffic through the tunnel
  /// counts.
  Future<int> testSingleReal(String link) async {
    if (testingReal || _wanted) return -2;
    final p = core.parse(link);
    if (p == null) return -1;
    testingReal = true;
    try {
      await _hardStop();
      final cfg = cdnFragment ? applyFragment(p.config, length: fragLen, interval: fragInt) : p.config;
      await core.start(p.remark, cfg, proxyOnly: true);
      _proxyPort = await _findProxy(cfg);
      if (_proxyPort == null) return -1;
      return await measurePing();
    } catch (_) {
      return -1;
    } finally {
      try {
        await core.stop();
      } catch (_) {}
      _proxyPort = null;
      testingReal = false;
    }
  }

  Future<SpeedResult> speedTestDetailed({void Function(String stage)? onStage, void Function(String stage, double? currentMbps, int done, int total)? onProgress}) => runSpeedTest(_client, onStage: onStage, onProgress: onProgress);

  Future<List<Candidate>> _gather() async {
    final urls = [...poolUrls]..shuffle(_rng);
    final out = <Candidate>[];
    const none = SubInfo(url: '', known: false);
    Iterable<String> variants(String l) => {transform(l), if (keepOriginal) l};
    // Priority servers (e.g. TR GAMING) must always be in the sample:
    // with a big provider the shuffled take(60) below could otherwise
    // leave them out entirely, and the priority pick in _next() can
    // only choose among sampled configs. So partition first: every
    // priority link is sampled, the rest fill the remaining slots.
    final filtered = [...directLinks].where(linkFilter).toList();
    bool isPri(String l) {
      for (final tl in variants(l)) {
        final p = core.parse(tl);
        if (p != null && _isPriorityRemark(p.remark)) return true;
      }
      return false;
    }

    final priLinks = <String>[];
    final restLinks = <String>[];
    for (final l in filtered) {
      if (isPri(l)) {
        priLinks.add(l);
      } else {
        restLinks.add(l);
      }
    }
    restLinks.shuffle(_rng);
    final keep = 60 - priLinks.length;
    final sampled = [...priLinks, ...restLinks.take(keep > 0 ? keep : 0)];
    for (final l in sampled) {
      for (final tl in variants(l)) {
        final p = core.parse(tl);
        if (p != null) out.add(Candidate(tl, p.remark, p.config, none));
      }
    }
    log('Sources: ${urls.length} subscriptions, ${directLinks.length} direct configs');
    var ok = 0, skipped = 0, failed = 0;
    if (urls.isNotEmpty) {
      final res = await Future.wait(urls.map((u) => _fetchSub(u).timeout(const Duration(seconds: 9), onTimeout: () => null)));
      for (final r in res) {
        if (r == null) {
          failed++;
          continue;
        }
        if (!r.info.usable) {
          skipped++;
          log('Ignored (expired or out of data): ${_short(r.info.url)}');
          continue;
        }
        ok++;
        final links = [...r.links.where(linkFilter)]..shuffle(_rng);
        for (final l in links) {
          for (final tl in variants(l)) {
            final p = core.parse(tl);
            if (p != null) out.add(Candidate(tl, p.remark, p.config, r.info));
          }
        }
      }
    }
    _skipped = skipped;
    _usableSubs = ok;
    log('Pool refreshed. Subscriptions: $ok usable, $skipped expired or out of data, $failed unreachable. ${out.length} configs to test');
    if (out.isEmpty && fallbackFilter != null) {
      final saved = linkFilter;
      linkFilter = fallbackFilter!;
      fallbackFilter = null;
      log('No CDN configs found: trying TLS configs with fragment instead');
      final r = await _gather();
      linkFilter = saved;
      return r;
    }
    return out;
  }

  Future<List<Candidate>> _probe(List<Candidate> cands) async {
    cands.shuffle(_rng);
    final done = <Candidate>[];
    final sw = Stopwatch()..start();
    var idx = 0, tested = 0;
    Future<void> worker() async {
      while (idx < cands.length && done.length < 60 && sw.elapsed < probeBudget && _wanted) {
        final c = cands[idx++];
        final r = await probeLink(c.link);
        tested++;
        if (r.ms > 0) {
          c.delayMs = r.ms;
          if (r.ip.isNotEmpty) {
            final p = core.parse(applyFronting(c.link, ip: r.ip));
            if (p != null) c.ipConfig = p.config;
          }
          done.add(c);
        }
      }
    }

    await Future.wait(List.generate(24, (_) => worker()));
    done.sort((a, b) => a.delayMs!.compareTo(b.delayMs!));
    log('Server check: tested $tested, reachable ${done.length}${done.isEmpty ? '' : ', best ${done.first.delayMs} ms'}');
    return [...done, ...cands.where((c) => c.delayMs == null)];
  }

  void _startWatch() {
    _stopTimers();
    _watch = Timer.periodic(const Duration(seconds: 20), (_) => _check());
    _subTimer = Timer.periodic(const Duration(seconds: 20), (_) => _refreshSub());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _tickStats());
  }

  Future<void> _tickStats() async {
    final at = _connectedAt;
    if (at == null || _phase != Phase.connected) return;
    if (!proxyOnly) {
      final up = await Native.vpnActive();
      if (up == false) {
        if (++_off >= 10) {
          log('The VPN was stopped (notification button, Android or another VPN app)');
          await disconnect();
          return;
        }
      } else {
        _off = 0;
      }
      _tunOk = up != false;
    } else {
      _tunOk = true;
    }
    final s = await Native.bytes();
    var upS = _traffic.upSpeed, downS = _traffic.downSpeed, upT = _traffic.upTotal, downT = _traffic.downTotal;
    if (s != null) {
      _b0 ??= s;
      final last = _bl ?? s;
      downS = s[0] - last[0];
      upS = s[1] - last[1];
      downT = s[0] - _b0![0];
      upT = s[1] - _b0![1];
      _bl = s;
    }
    _live = CoreStatus(durationSec: DateTime.now().difference(at).inSeconds, upSpeed: upS, downSpeed: downS, upTotal: upT, downTotal: downT, state: 'CONNECTED');
    _emit();
  }

  Future<void> _check() async {
    if (!_wanted || _checking || _phase != Phase.connected || !_pingOk) return;
    _checking = true;
    try {
      final p = _proxyPort != null ? await measurePing() : await core.connectedDelay();
      if (p > 0) {
        _fails = 0;
        _delay = p;
        _emit();
      } else if (++_fails >= 3) {
        await _restart('the server stopped carrying traffic');
      }
    } finally {
      _checking = false;
    }
  }

  Future<void> _failover() => _restart('switching server');

  Future<void> _refreshSub() async {
    final su = _subUrl;
    if (su == null || su.isEmpty || !_wanted || _phase != Phase.connected) return;
    final r = await _fetchSub(su);
    if (r == null) return;
    _sub = r.info;
    _emit();
    if (!r.info.usable && !_checking) {
      _checking = true;
      try {
        await _restart('the subscription ran out of data or time');
      } finally {
        _checking = false;
      }
    }
  }

  String _short(String u) => u.length > 12 ? '${Uri.tryParse(u)?.host ?? ''}/...${u.substring(u.length - 6)}' : u;

  Future<Map<String, dynamic>?> inspectSub(String url) async {
    final r = await _fetchSub(url);
    return r == null ? null : {'info': r.info, 'links': r.links};
  }

  /// Same fetch, but through a local proxy on [port] (Psiphon's HTTP proxy
  /// or the core's local proxy). Used when a direct fetch from the user's
  /// own network fails, e.g. a host that is unreachable from an Iranian
  /// IP without a VPN, while a tunnel is already active.
  Future<Map<String, dynamic>?> inspectSubViaProxy(String url, int port) async {
    final r = await _fetchSub(url, viaProxyPort: port);
    return r == null ? null : {'info': r.info, 'links': r.links};
  }

  /// Fetch through the core's local proxy when it is known. Returns null
  /// when no local proxy is known (in VPN/TUN mode a direct fetch already
  /// goes through the TUN, so there is nothing extra to try).
  Future<Map<String, dynamic>?> inspectSubViaTunnel(String url) async {
    final port = _proxyPort;
    if (port == null) return null;
    final r = await _fetchSub(url, viaProxyPort: port);
    return r == null ? null : {'info': r.info, 'links': r.links};
  }

  Future<_Fetched?> _fetchSub(String url, {int? viaProxyPort}) async {
    for (final lenient in [false, true]) {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      if (viaProxyPort != null) c.findProxy = (_) => 'PROXY 127.0.0.1:$viaProxyPort';
      if (lenient) c.badCertificateCallback = (cert, host, port) => true;
      try {
        final req = await c.getUrl(Uri.parse(url));
        req.headers.set('User-Agent', 'v2rayNG/1.9.0');
        req.headers.set('Cache-Control', 'no-cache');
        req.headers.set('Pragma', 'no-cache');
        final res = await req.close().timeout(const Duration(seconds: 7));
        if (res.statusCode != 200) {
          log('Subscription HTTP ${res.statusCode}: ${_short(url)}');
          return null;
        }
        final body = await res.transform(utf8.decoder).join();
        // Large feeds (1000+ configs, seen on some providers) are parsed on a background
        // isolate so a subscription refresh never blocks the UI thread.
        final links = body.length > 20000 ? await compute(extractLinks, body) : extractLinks(body);
        if (links.isEmpty) log('Subscription has no configs: ${_short(url)}');
        return _Fetched(SubInfo.parse(url, res.headers.value('subscription-userinfo')), links);
      } on HandshakeException {
        if (lenient) log('TLS error: ${_short(url)}');
      } catch (e) {
        log('Subscription fetch failed (${e.runtimeType}): ${_short(url)}');
        if (!lenient) continue;
        return null;
      } finally {
        c.close(force: true);
      }
    }
    return null;
  }

  /// Public IP and place, looked up by IP address. [direct] skips the core's proxy.
  Future<Map<String, String>?> _lookupIp({bool direct = false}) async {
    // v1.0.5: all sources are tried concurrently; the first valid
    // answer wins. Same URLs and timeouts as before.
    // v1.0.6: more sources, because one shared tunnel exit can be
    // rate-limited or blocked on any single service. JSON sources
    // first (they carry city/country), plain-IP sources last (they
    // answer the IP but no location).
    const urls = ['http://ip-api.com/json', 'https://ipwho.is/', 'https://ipinfo.io/json', 'https://api.ipify.org?format=json', 'https://api64.ipify.org?format=json', 'https://checkip.amazonaws.com', 'https://ifconfig.me/ip'];
    Future<Map<String, String>?> attempt(String u) async {
      final c = direct ? (HttpClient()..connectionTimeout = const Duration(seconds: 4)) : _client(const Duration(seconds: 4));
      try {
        final res = await (await c.getUrl(Uri.parse(u))).close().timeout(const Duration(seconds: 5));
        final body = await res.transform(utf8.decoder).join();
        Map<String, dynamic>? j;
        try {
          final d = jsonDecode(body);
          if (d is Map<String, dynamic>) j = d;
        } catch (_) {}
        if (j != null) {
          if (j['success'] == false || j['status'] == 'fail') return null;
          final ip = '${j['ip'] ?? j['query'] ?? ''}';
          if (ip.isEmpty) return null;
          final loc = [j['city'], j['country'] ?? j['country_name']].where((e) => e != null && '$e'.isNotEmpty).join(', ');
          final cc = '${j['countryCode'] ?? j['country_code'] ?? (('${j['country']}'.length == 2) ? j['country'] : '')}';
          return {'ip': ip, 'loc': loc, 'cc': cc};
        }
        final plain = body.trim();
        if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(plain)) return {'ip': plain, 'loc': '', 'cc': ''};
        return null;
      } catch (_) {
        return null;
      } finally {
        c.close(force: true);
      }
    }

    final results = await Future.wait(urls.map(attempt));
    for (final r in results) {
      if (r != null) return r;
    }
    return null;
  }
}

/// Country flag emoji from a two-letter country code ('' if unknown).
String flagOf(String cc) {
  final c = cc.toUpperCase();
  if (!RegExp(r'^[A-Z]{2}$').hasMatch(c)) return '';
  return String.fromCharCodes(c.codeUnits.map((x) => 0x1F1E6 + x - 65));
}
