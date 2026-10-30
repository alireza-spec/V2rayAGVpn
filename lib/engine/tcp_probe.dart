import 'dart:async';
import 'dart:convert';
import 'dart:io';

class Endpoint {
  final String host, sni;
  final int port;
  final bool tls, udp;
  Endpoint(this.host, this.port, this.tls, this.udp, this.sni);
}

String _b64(String s) => utf8.decode(base64.decode(base64.normalize(s.replaceAll('-', '+').replaceAll('_', '/'))), allowMalformed: true);

/// Where a share link actually connects to.
Endpoint? endpointOf(String l) {
  try {
    if (l.startsWith('vmess://')) {
      final j = jsonDecode(_b64(l.substring(8))) as Map<String, dynamic>;
      final host = '${j['add']}';
      final sni = '${j['sni'] ?? ''}'.isNotEmpty ? '${j['sni']}' : ('${j['host'] ?? ''}'.isNotEmpty ? '${j['host']}' : host);
      return Endpoint(host, int.parse('${j['port']}'), '${j['tls']}' == 'tls', false, sni);
    }
    if (l.startsWith('ss://')) {
      var r = l.substring(5);
      final h = r.indexOf('#');
      if (h >= 0) r = r.substring(0, h);
      final q = r.indexOf('?');
      if (q >= 0) r = r.substring(0, q);
      r = r.replaceAll(RegExp(r'/$'), '');
      final d = r.contains('@') ? r : _b64(Uri.decodeComponent(r));
      final hp = d.substring(d.lastIndexOf('@') + 1);
      final i = hp.lastIndexOf(':');
      return Endpoint(hp.substring(0, i).replaceAll(RegExp(r'[\[\]]'), ''), int.parse(hp.substring(i + 1)), false, false, '');
    }
    final u = Uri.parse(l);
    final q = u.queryParameters;
    final sec = q['security'] ?? (u.scheme == 'trojan' ? 'tls' : '');
    final sni = (q['sni'] ?? q['peer'] ?? '').isNotEmpty ? (q['sni'] ?? q['peer']!) : ((q['host'] ?? '').isNotEmpty ? q['host']! : u.host);
    final udp = const {'hysteria2', 'hy2', 'hysteria', 'tuic'}.contains(u.scheme);
    return Endpoint(u.host, u.port == 0 ? 443 : u.port, sec == 'tls' || sec == 'reality', udp, sni);
  } catch (_) {
    return null;
  }
}

class ProbeResult {
  final int ms; // -1 = unreachable, 9000 = UDP (cannot be checked this way)
  final String ip; // resolved address when the host was a domain
  ProbeResult(this.ms, this.ip);
}

/// Real ping: resolve the host with the phone's own DNS, open a TCP connection,
/// then do the TLS handshake with the config's SNI. Works on any ISP, no VPN needed.
Future<ProbeResult> probeLink(String link, {Duration timeout = const Duration(seconds: 5)}) async {
  final e = endpointOf(link);
  if (e == null) return ProbeResult(-1, '');
  if (e.udp) return ProbeResult(9000, '');
  final sw = Stopwatch()..start();
  Socket? raw;
  try {
    var addr = e.host;
    if (InternetAddress.tryParse(e.host) == null) {
      final r = await InternetAddress.lookup(e.host).timeout(timeout);
      if (r.isEmpty) return ProbeResult(-1, '');
      final v4 = r.where((a) => a.type == InternetAddressType.IPv4).toList();
      addr = (v4.isNotEmpty ? v4.first : r.first).address;
    }
    raw = await Socket.connect(addr, e.port, timeout: timeout);
    if (e.tls) {
      // v1.0.5: no certificate bypass — a config whose certificate
      // does not validate gets a failed probe (-1) instead of a
      // passing ping, so a broken or spoofed endpoint never looks
      // healthy. The probe verdict never gates a connection by itself.
      final s = await SecureSocket.secure(raw, host: e.sni).timeout(timeout);
      s.destroy();
      raw = null;
    }
    return ProbeResult(sw.elapsedMilliseconds, addr == e.host ? '' : addr);
  } catch (_) {
    return ProbeResult(-1, '');
  } finally {
    raw?.destroy();
  }
}

/// Bytes received/sent on the VPN interface (tun*), from /proc/net/dev. Null if unreadable.
Future<List<int>?> readTunBytes() async {
  try {
    var rx = 0, tx = 0, found = false;
    for (final l in await File('/proc/net/dev').readAsLines()) {
      final t = l.trim();
      if (t.startsWith('tun') || t.startsWith('vpn') || t.startsWith('ppp')) {
        final p = t.split(RegExp(r'[:\s]+'));
        rx += int.parse(p[1]);
        tx += int.parse(p[9]);
        found = true;
      }
    }
    return found ? [rx, tx] : null;
  } catch (_) {
    return null;
  }
}
