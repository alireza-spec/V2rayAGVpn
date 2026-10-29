import 'dart:convert';

const _cdnTypes = {'ws', 'grpc', 'httpupgrade', 'xhttp', 'splithttp'};

Map<String, dynamic>? _vmess(String l) {
  try {
    return jsonDecode(utf8.decode(base64.decode(base64.normalize(l.substring(8))))) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

/// True for configs that run over a CDN: WebSocket / gRPC / HTTP upgrade with TLS.
bool isCdnLink(String l) {
  try {
    if (l.startsWith('vmess://')) {
      final j = _vmess(l);
      return j != null && _cdnTypes.contains(j['net']) && j['tls'] == 'tls';
    }
    final u = Uri.parse(l);
    if (u.scheme != 'vless' && u.scheme != 'trojan') return false;
    final q = u.queryParameters;
    final sec = q['security'] ?? (u.scheme == 'trojan' ? 'tls' : '');
    return _cdnTypes.contains(q['type'] ?? 'tcp') && sec == 'tls';
  } catch (_) {
    return false;
  }
}

/// Swaps the connect address for a clean IP (keeping SNI and Host) and/or overrides the SNI.
String applyFronting(String link, {String ip = '', String host = ''}) {
  if (ip.isEmpty && host.isEmpty) return link;
  try {
    if (link.startsWith('vmess://')) {
      final j = _vmess(link);
      if (j == null) return link;
      final orig = '${j['add']}';
      if (ip.isNotEmpty) {
        j['add'] = ip;
        if ('${j['sni'] ?? ''}'.isEmpty) j['sni'] = '${j['host'] ?? ''}'.isEmpty ? orig : j['host'];
        if ('${j['host'] ?? ''}'.isEmpty) j['host'] = j['sni'];
      }
      if (host.isNotEmpty) j['sni'] = host;
      return 'vmess://${base64.encode(utf8.encode(jsonEncode(j)))}';
    }
    final u = Uri.parse(link);
    if (u.scheme != 'vless' && u.scheme != 'trojan') return link;
    final q = Map<String, String>.from(u.queryParameters);
    if (ip.isNotEmpty) {
      q['sni'] = (q['sni'] ?? '').isEmpty ? (q['host'] ?? u.host) : q['sni']!;
      if ((q['host'] ?? '').isEmpty) q['host'] = q['sni']!;
    }
    if (host.isNotEmpty) q['sni'] = host;
    return u.replace(host: ip.isNotEmpty ? ip : u.host, queryParameters: q).toString();
  } catch (_) {
    return link;
  }
}

/// Any TLS or REALITY config (fragmenting the TLS hello helps all of them).
bool isTlsLink(String l) {
  try {
    if (l.startsWith('vmess://')) return _vmess(l)?['tls'] == 'tls';
    final u = Uri.parse(l);
    if (u.scheme != 'vless' && u.scheme != 'trojan') return false;
    final sec = u.queryParameters['security'] ?? (u.scheme == 'trojan' ? 'tls' : '');
    return sec == 'tls' || sec == 'reality';
  } catch (_) {
    return false;
  }
}

/// TLS-hello fragmentation, the way MahsaNG / v2rayNG do it: a "freedom" outbound that
/// cuts the first TLS packet into pieces, and the proxy outbound dials through it.
String applyFragment(String cfg, {String length = '100-200', String interval = '10-20'}) {
  try {
    final j = jsonDecode(cfg) as Map<String, dynamic>;
    final outs = (j['outbounds'] as List).cast<Map<String, dynamic>>();
    outs.add({
      'tag': 'fragment',
      'protocol': 'freedom',
      'settings': {
        'domainStrategy': 'AsIs',
        'fragment': {'packets': 'tlshello', 'length': length, 'interval': interval},
      },
    });
    for (final o in outs) {
      if (const {'vless', 'vmess', 'trojan', 'shadowsocks'}.contains('${o['protocol']}')) {
        final ss = (o['streamSettings'] ??= <String, dynamic>{}) as Map<String, dynamic>;
        final so = (ss['sockopt'] ??= <String, dynamic>{}) as Map<String, dynamic>;
        so['dialerProxy'] = 'fragment';
        break;
      }
    }
    return jsonEncode(j);
  } catch (_) {
    return cfg;
  }
}

/// Port of the local inbound (http / socks) that the core opens for this config.
int? inboundPort(String cfg, String proto) {
  try {
    final j = jsonDecode(cfg) as Map<String, dynamic>;
    for (final i in (j['inbounds'] as List)) {
      if ('${i['protocol']}' == proto) return int.tryParse('${i['port']}');
    }
  } catch (_) {}
  return null;
}
