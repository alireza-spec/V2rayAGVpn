import 'dart:async';

import 'package:flutter_vless/flutter_vless.dart';

import 'vpn_core.dart';

/// Adapter for the flutter_vless plugin. Method names follow the
/// flutter_v2ray family of plugins. If your installed version differs,
/// this is the ONLY file to adjust.
class FlutterVlessCore implements VpnCore {
  final _ctrl = StreamController<CoreStatus>.broadcast();
  late final FlutterVless _v = FlutterVless(onStatusChanged: (s) {
    _ctrl.add(CoreStatus(
      durationSec: _secs('${s.duration}'),
      upSpeed: s.uploadSpeed,
      downSpeed: s.downloadSpeed,
      upTotal: s.upload,
      downTotal: s.download,
      state: '${s.state}',
    ));
  });

  static int _secs(String d) {
    final p = d.split(':').map((e) => int.tryParse(e) ?? 0).toList();
    return p.length == 3 ? p[0] * 3600 + p[1] * 60 + p[2] : (int.tryParse(d) ?? 0);
  }

  String _err = '';

  @override
  String get lastError => _err;

  @override
  Stream<CoreStatus> get status => _ctrl.stream;

  @override
  Future<void> init() => _v.initializeVless(
        notificationIconResourceType: 'drawable',
        notificationIconResourceName: 'ic_stat_v2rayag',
        providerBundleIdentifier: '',
        groupIdentifier: '',
      );

  @override
  Future<bool> requestPermission() async => await _v.requestPermission();

  @override
  ParsedConfig? parse(String link) {
    try {
      final u = FlutterVless.parseFromURL(link);
      return ParsedConfig(u.remark, u.getFullConfiguration());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int> delay(String config, String url, Duration timeout) async {
    try {
      return await _v.getServerDelay(config: config, url: url).timeout(timeout);
    } catch (e) {
      _err = '$e';
      return -1;
    }
  }

  @override
  Future<int> connectedDelay() async {
    try {
      return await _v.getConnectedServerDelay();
    } catch (e) {
      _err = '$e';
      return -1;
    }
  }

  @override
  Future<void> start(String remark, String config, {List<String>? blockedApps, bool proxyOnly = false}) async {
    await _v.startVless(
      remark: remark,
      config: config,
      blockedApps: (blockedApps == null || blockedApps.isEmpty) ? null : blockedApps,
      proxyOnly: proxyOnly,
      notificationDisconnectButtonName: 'Disconnect',
    );
  }

  @override
  Future<void> stop() async => _v.stopVless();
}
