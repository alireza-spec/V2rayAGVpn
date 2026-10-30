import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Cloudflare's official IPv4 ranges (https://www.cloudflare.com/ips-v4).
const kCfRanges = <String>[
  '173.245.48.0/20', '103.21.244.0/22', '103.22.200.0/22', '103.31.4.0/22', '141.101.64.0/18',
  '108.162.192.0/18', '190.93.240.0/20', '188.114.96.0/20', '197.234.240.0/22', '198.41.128.0/17',
  '162.158.0.0/15', '104.16.0.0/13', '104.24.0.0/14', '172.64.0.0/13', '131.0.72.0/22',
];

/// Fastly's public ranges (https://api.fastly.com/public-ip-list).
const kFastlyRanges = <String>[
  '23.235.32.0/20', '43.249.72.0/22', '103.244.50.0/24', '103.245.222.0/23', '103.245.224.0/24',
  '104.156.80.0/20', '140.248.64.0/18', '140.248.128.0/17', '146.75.0.0/17', '151.101.0.0/16',
  '157.52.64.0/18', '167.82.0.0/17', '167.82.128.0/20', '167.82.160.0/20', '167.82.224.0/20',
  '172.111.64.0/18', '185.31.16.0/22', '199.27.72.0/21', '199.232.0.0/16',
];

String randomIpIn(String cidr, Random rng) {
  final p = cidr.split('/');
  final o = p[0].split('.').map(int.parse).toList();
  final base = (o[0] << 24) | (o[1] << 16) | (o[2] << 8) | o[3];
  final size = 1 << (32 - int.parse(p[1]));
  final ip = (base & (~(size - 1) & 0xFFFFFFFF)) | rng.nextInt(size);
  return '${(ip >> 24) & 255}.${(ip >> 16) & 255}.${(ip >> 8) & 255}.${ip & 255}';
}

class ScanHit {
  final String ip, colo;
  final int ms;
  ScanHit(this.ip, this.colo, this.ms);
}

/// Real TLS handshake with the given SNI, then GET /cdn-cgi/trace.
/// A reply with "colo=" means the IP really serves Cloudflare traffic for you.
/// v1.0.5: no certificate bypass — an IP whose certificate does not
/// validate for the SNI is rejected like any other failed probe, so a
/// spoofed or broken endpoint can never be picked as a fronting address.
Future<ScanHit?> probeIp(String ip, String sni, {Duration timeout = const Duration(seconds: 4)}) async {
  final sw = Stopwatch()..start();
  Socket? raw;
  try {
    raw = await Socket.connect(ip, 443, timeout: timeout);
    final s = await SecureSocket.secure(raw, host: sni).timeout(timeout);
    s.write('GET /cdn-cgi/trace HTTP/1.1\r\nHost: $sni\r\nConnection: close\r\n\r\n');
    final body = await utf8.decoder.bind(s).join().timeout(timeout);
    final m = RegExp(r'colo=(\w+)').firstMatch(body);
    if (m == null) return null;
    return ScanHit(ip, m.group(1)!, sw.elapsedMilliseconds);
  } catch (_) {
    return null;
  } finally {
    raw?.destroy();
  }
}

Future<void> scanRanges({
  required List<String> ranges,
  required int count,
  required String sni,
  required void Function(ScanHit) onHit,
  required void Function(int) onProgress,
  required bool Function() cancelled,
}) async {
  final rng = Random();
  final ips = <String>{};
  while (ips.length < count) {
    ips.add(randomIpIn(ranges[rng.nextInt(ranges.length)], rng));
  }
  final q = ips.toList();
  var i = 0, done = 0;
  Future<void> worker() async {
    while (i < q.length && !cancelled()) {
      final h = await probeIp(q[i++], sni);
      onProgress(++done);
      if (h != null) onHit(h);
    }
  }

  await Future.wait(List.generate(24, (_) => worker()));
}

/// Current official range list straight from the provider (null if it cannot be downloaded).
Future<List<String>?> fetchLiveRanges(String cdn) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final fastly = cdn == 'Fastly';
    final r = await (await c.getUrl(Uri.parse(fastly ? 'https://api.fastly.com/public-ip-list' : 'https://www.cloudflare.com/ips-v4'))).close().timeout(const Duration(seconds: 10));
    final body = await r.transform(utf8.decoder).join();
    final raw = fastly ? List<String>.from(jsonDecode(body)['addresses']) : body.split(RegExp(r'\s+'));
    final ok = raw.where((x) => RegExp(r'^\d+\.\d+\.\d+\.\d+/\d+$').hasMatch(x)).toList();
    return ok.length >= 5 ? ok : null;
  } catch (_) {
    return null;
  } finally {
    c.close(force: true);
  }
}

class CdnHit {
  final String ip, cdn, colo;
  int ms, ok = 0, tries = 0;
  double? mbps;
  CdnHit(this.ip, this.cdn, this.colo, this.ms);
  double get score => ok * 200.0 - ms + (mbps ?? 0) * 10;
}

String? _detectCdn(String h) {
  if (h.contains('cf-ray') || h.contains('server: cloudflare')) return 'Cloudflare';
  if (h.contains('x-served-by') || h.contains('fastly') || h.contains('varnish')) return 'Fastly';
  if (h.contains('akamai')) return 'Akamai';
  if (h.contains('x-amz-cf-id') || h.contains('cloudfront')) return 'CloudFront';
  if (h.contains('server: gws') || h.contains('server: esf') || h.contains('server: gse')) return 'Google';
  if (h.contains('x-azure-ref')) return 'Azure';
  return null;
}

/// One real probe: TCP + TLS with the given SNI, then an HTTP request. The reply headers
/// must belong to a CDN, so dead IPs and look-alike hosts are rejected.
Future<CdnHit?> probeCdn(String ip, String sni, {Duration timeout = const Duration(seconds: 4)}) async {
  final sw = Stopwatch()..start();
  Socket? raw;
  try {
    raw = await Socket.connect(ip, 443, timeout: timeout);
    final s = await SecureSocket.secure(raw, host: sni).timeout(timeout);
    raw = null;
    s.write('GET / HTTP/1.1\r\nHost: $sni\r\nUser-Agent: Mozilla/5.0\r\nAccept: */*\r\nConnection: close\r\n\r\n');
    final buf = StringBuffer();
    try {
      await for (final chunk in const Utf8Decoder(allowMalformed: true).bind(s).timeout(timeout)) {
        buf.write(chunk);
        if (buf.length > 3000 || buf.toString().contains('\r\n\r\n')) break;
      }
    } finally {
      s.destroy();
    }
    final head = buf.toString().toLowerCase();
    if (!head.startsWith('http/')) return null;
    final cdn = _detectCdn(head);
    if (cdn == null) return null;
    final m = RegExp(r'cf-ray:\s*[0-9a-f]+-(\w+)').firstMatch(head);
    return CdnHit(ip, cdn, (m?.group(1) ?? '').toUpperCase(), sw.elapsedMilliseconds);
  } catch (_) {
    return null;
  } finally {
    raw?.destroy();
  }
}

/// Real download speed (Mbps) from one Cloudflare IP, about 5 seconds at most.
Future<double?> speedVia(String ip, {String sni = 'speed.cloudflare.com'}) async {
  Socket? raw;
  final sw = Stopwatch()..start();
  var bytes = 0;
  try {
    raw = await Socket.connect(ip, 443, timeout: const Duration(seconds: 4));
    final s = await SecureSocket.secure(raw, host: sni).timeout(const Duration(seconds: 4));
    raw = null;
    s.write('GET /__down?bytes=3000000 HTTP/1.1\r\nHost: $sni\r\nConnection: close\r\n\r\n');
    try {
      await for (final c in s.timeout(const Duration(seconds: 5))) {
        bytes += c.length;
        if (sw.elapsedMilliseconds > 5000) break;
      }
    } finally {
      s.destroy();
    }
  } catch (_) {
  } finally {
    raw?.destroy();
  }
  final sec = sw.elapsedMilliseconds / 1000.0;
  return (bytes < 100000 || sec <= 0) ? null : bytes * 8 / sec / 1e6;
}

List<CdnHit> _rank(List<CdnHit> l) => [...l]..sort((a, b) => b.score.compareTo(a.score));

/// Three stages, like a serious scanner: (1) quick probe of many random IPs, weighted by range
/// size, (2) five probes each for the 30 fastest, keeping only those that answer at least 3 of 5,
/// (3) a real download on the best 8 (Cloudflare).
Future<void> scanSmart({
  required List<String> ranges,
  required int count,
  required String sni,
  required void Function(int stage, int done, int total) onProgress,
  required void Function(List<CdnHit>) onResults,
  required bool Function() cancelled,
}) async {
  final rng = Random();
  final sizes = ranges.map((r) => 1 << (32 - int.parse(r.split('/')[1]))).toList();
  final total = sizes.fold<int>(0, (a, b) => a + b);
  String pick() {
    var x = rng.nextInt(total);
    for (var i = 0; i < ranges.length; i++) {
      if (x < sizes[i]) return randomIpIn(ranges[i], rng);
      x -= sizes[i];
    }
    return randomIpIn(ranges.last, rng);
  }

  final ips = <String>{};
  while (ips.length < count) {
    ips.add(pick());
  }
  final q = ips.toList();
  final found = <CdnHit>[];
  var i = 0, done = 0;
  Future<void> w1() async {
    while (i < q.length && !cancelled()) {
      final h = await probeCdn(q[i++], sni);
      onProgress(1, ++done, q.length);
      if (h != null) found.add(h);
    }
  }

  await Future.wait(List.generate(24, (_) => w1()));
  if (cancelled() || found.isEmpty) return onResults([]);
  found.sort((a, b) => a.ms.compareTo(b.ms));
  final top = found.take(30).toList();
  var j = 0, d2 = 0;
  Future<void> w2() async {
    while (j < top.length && !cancelled()) {
      final h = top[j++];
      final times = <int>[];
      for (var k = 0; k < 5 && !cancelled(); k++) {
        final r = await probeCdn(h.ip, sni);
        if (r != null) times.add(r.ms);
      }
      h.ok = times.length;
      h.tries = 5;
      if (times.isNotEmpty) {
        times.sort();
        h.ms = times[times.length ~/ 2];
      }
      onProgress(2, ++d2, top.length);
    }
  }

  await Future.wait(List.generate(8, (_) => w2()));
  var stable = top.where((h) => h.ok >= 3).toList();
  if (stable.isEmpty) stable = top.where((h) => h.ok >= 1).toList();
  onResults(_rank(stable));
  final best = _rank(stable).take(8).toList();
  for (var k = 0; k < best.length && !cancelled(); k++) {
    if (best[k].cdn == 'Cloudflare') best[k].mbps = await speedVia(best[k].ip);
    onProgress(3, k + 1, best.length);
    onResults(_rank(stable));
  }
}
