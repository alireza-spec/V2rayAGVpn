import 'dart:typed_data';

import 'package:flutter/services.dart';

class AppInfo {
  final String pkg, name;
  final bool system;
  final Uint8List icon;
  AppInfo(this.pkg, this.name, this.system, this.icon);
}

/// Bridge to MainActivity.kt: things only Android can tell us truthfully.
class Native {
  static const _c = MethodChannel('v2rayag/native');

  /// Android's own answer to "is a VPN network active?". Null if unknown.
  static Future<bool?> vpnActive() async {
    try {
      return await _c.invokeMethod<bool>('vpnActive');
    } catch (_) {
      return null;
    }
  }

  /// Bytes received/sent by this app's UID (the VPN service runs in it): [rx, tx].
  static Future<List<int>?> bytes() async {
    try {
      final r = await _c.invokeMethod<List<dynamic>>('bytes');
      if (r == null || r.length < 2) return null;
      final a = (r[0] as num).toInt(), b = (r[1] as num).toInt();
      return (a < 0 || b < 0) ? null : [a, b];
    } catch (_) {
      return null;
    }
  }

  static Future<bool> openUrl(String url) async {
    try {
      return await _c.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> launch(String pkg) async {
    try {
      return await _c.invokeMethod<bool>('launch', {'pkg': pkg}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<List<AppInfo>> apps() async {
    try {
      final r = await _c.invokeMethod<List<dynamic>>('apps') ?? [];
      return r.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return AppInfo('${m['pkg']}', '${m['name']}', m['system'] == true, m['icon'] as Uint8List);
      }).toList();
    } catch (_) {
      return [];
    }
  }
}
