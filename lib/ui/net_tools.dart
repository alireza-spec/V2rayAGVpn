// Network tools (v1.0.6): DNS latency, domain reachability and a
// vless/trojan address modifier, inspired by the feature set of the
// network-checker app (mirarr-app/network-checker) but implemented
// here from scratch, in this app's own style, with no extra packages:
// plain dart:io (UDP DNS, HTTPS checks, string surgery). They live in
// Tools so a separate checker app is not needed. All three test
// through the current connection: with the VPN on, everything
// answers through the tunnel; with it off, they show the bare
// network, which is the interesting case.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/store.dart';
import '../engine/pool_engine.dart';

void _copy(BuildContext c, String text, String done) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(done)));
}

/// Reads a picked .txt file as text, or null when cancelled or
/// unreadable. Same pattern as the subscription file import.
Future<String?> _pickTxt() async {
  try {
    final file = await FilePicker.pickFile();
    if (file == null) return null;
    try {
      final bytes = await file.readAsBytes();
      return utf8.decode(bytes);
    } catch (_) {
      final path = file.path;
      if (path == null) return null;
      return await File(path).readAsString();
    }
  } catch (_) {
    return null;
  }
}

class _DnsEntry {
  final String name, ip;
  const _DnsEntry(this.name, this.ip);
}

const _dnsProviders = [
  _DnsEntry('Cloudflare', '1.1.1.1'),
  _DnsEntry('Google', '8.8.8.8'),
  _DnsEntry('Quad9', '9.9.9.9'),
  _DnsEntry('OpenDNS', '208.67.222.222'),
  _DnsEntry('AdGuard', '94.140.14.14'),
  _DnsEntry('Shecan', '178.22.122.100'),
  // v1.0.7: second anycast addresses + more real public resolvers.
  _DnsEntry('Cloudflare 2', '1.0.0.1'),
  _DnsEntry('Google 2', '8.8.4.4'),
  _DnsEntry('Quad9 2', '149.112.112.112'),
  _DnsEntry('OpenDNS 2', '208.67.220.220'),
  _DnsEntry('AdGuard 2', '94.140.15.15'),
  _DnsEntry('Shecan 2', '185.51.200.2'),
  _DnsEntry('ControlD', '76.76.2.0'),
  _DnsEntry('CleanBrowsing', '185.228.168.9'),
  _DnsEntry('Comodo', '8.26.56.26'),
  _DnsEntry('Yandex', '77.88.8.8'),
  _DnsEntry('OpenDNS Family', '208.67.222.123'),
  _DnsEntry('Cloudflare Malware', '1.1.1.2'),
];

/// One minimal DNS query (A record for example.com) over UDP, timed.
/// Returns milliseconds, or null on timeout / bad reply. Two attempts,
/// best wins; the caller runs providers concurrently.
Future<int?> _dnsQuery(String ip) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    final ms = await _dnsOnce(ip);
    if (ms != null) return ms;
  }
  return null;
}

Future<int?> _dnsOnce(String ip) async {
  RawDatagramSocket? sock;
  try {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0).timeout(const Duration(seconds: 3));
    final id = math.Random().nextInt(65536);
    final q = <int>[
      id >> 8, id & 0xFF, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      7, ...utf8.encode('example'), 3, ...utf8.encode('com'), 0, 0x00, 0x01, 0x00, 0x01,
    ];
    final sw = Stopwatch()..start();
    sock.send(q, InternetAddress(ip), 53);
    final done = Completer<int?>();
    final timer = Timer(const Duration(seconds: 3), () {
      if (!done.isCompleted) done.complete(null);
    });
    late StreamSubscription sub;
    sub = sock.listen((e) {
      if (e == RawSocketEvent.read) {
        final d = sock?.receive();
        if (d != null && d.data.length >= 12 && d.data[0] == (id >> 8) && d.data[1] == (id & 0xFF) && (d.data[2] & 0x80) != 0) {
          if (!done.isCompleted) done.complete(sw.elapsedMilliseconds);
        }
      }
    });
    final r = await done.future;
    timer.cancel();
    await sub.cancel();
    return r;
  } catch (_) {
    return null;
  } finally {
    sock?.close();
  }
}

class DnsTestPage extends StatefulWidget {
  const DnsTestPage(this.s, {super.key});
  final Store s;
  @override
  State<DnsTestPage> createState() => _DnsTestState();
}

class _DnsTestState extends State<DnsTestPage> {
  final customCtl = TextEditingController();
  final entries = <_DnsEntry>[..._dnsProviders];
  final results = <String, int>{};
  bool testing = false;

  Future<void> _testAll() async {
    setState(() {
      testing = true;
      results.clear();
    });
    final found = await Future.wait(entries.map((e) async {
      final ms = await _dnsQuery(e.ip);
      return MapEntry(e.ip, ms ?? -1);
    }));
    if (!mounted) return;
    setState(() {
      for (final f in found) {
        results[f.key] = f.value;
      }
      testing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final rows = [...entries];
    rows.sort((a, b) {
      final ma = results[a.ip], mb = results[b.ip];
      if (ma == null && mb == null) return 0;
      if (ma == null) return 1;
      if (mb == null) return -1;
      if (ma < 0 && mb < 0) return 0;
      if (ma < 0) return 1;
      if (mb < 0) return -1;
      return ma.compareTo(mb);
    });
    return Scaffold(
      appBar: AppBar(title: Text(s.t('dnstest'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(s.t('dnstest_d'), style: const TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: customCtl, decoration: InputDecoration(labelText: s.t('customdns'), border: const OutlineInputBorder()))),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () {
              final v = customCtl.text.trim();
              if (v.isEmpty || entries.any((e) => e.ip == v)) return;
              setState(() {
                entries.add(_DnsEntry(v, v));
                customCtl.clear();
              });
            },
            child: Text(s.t('addcustom')),
          ),
        ]),
        const SizedBox(height: 12),
        FilledButton.icon(icon: const Icon(Icons.speed), label: Text(testing ? '...' : s.t('test')), onPressed: testing ? null : _testAll),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.file_upload_outlined, size: 18),
            label: Text(s.t('importdns')),
            onPressed: () async {
              final text = await _pickTxt();
              if (text == null || !mounted) return;
              final ipRe = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
              var added = 0;
              for (final raw in text.split(RegExp(r'[\r\n]+'))) {
                final line = raw.trim();
                if (line.isEmpty) continue;
                final parts = line.split(RegExp(r'\s+'));
                String name, ip;
                if (parts.length >= 2 && ipRe.hasMatch(parts[1])) {
                  name = parts[0];
                  ip = parts[1];
                } else if (ipRe.hasMatch(parts[0])) {
                  name = parts[0];
                  ip = parts[0];
                } else {
                  continue;
                }
                if (entries.any((e) => e.ip == ip)) continue;
                entries.add(_DnsEntry(name, ip));
                added++;
                if (added >= 100) break;
              }
              if (mounted) setState(() {});
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${s.t('added')}: $added')));
            },
          ),
          if (results.values.any((v) => v >= 0))
            OutlinedButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: Text(s.t('copyworking')),
              onPressed: () {
                final working = entries.where((e) => (results[e.ip] ?? -1) >= 0).toList()..sort((a, b) => results[a.ip]!.compareTo(results[b.ip]!));
                _copy(context, working.map((e) => '${e.name} ${e.ip} ${results[e.ip]} ms').join('\n'), s.t('copy'));
              },
            ),
        ]),
        const SizedBox(height: 12),
        for (final e in rows)
          ListTile(
            dense: true,
            title: Text(e.name, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(e.ip),
            trailing: results[e.ip] == null
                ? null
                : Text(
                    results[e.ip]! < 0 ? s.t('noreply') : '${results[e.ip]} ms',
                    style: TextStyle(color: results[e.ip]! < 0 ? Colors.redAccent : (results[e.ip]! < 200 ? const Color(0xFF2BD67B) : (results[e.ip]! < 500 ? Colors.amber : Colors.orange))),
                  ),
            onTap: () => _copy(context, e.ip, s.t('copy')),
          ),
      ]),
    );
  }
}

class _DomResult {
  final bool ok;
  final int ms;
  final int? code;
  const _DomResult(this.ok, this.ms, this.code);
}

const _defaultDomains = [
  'google.com',
  'youtube.com',
  'telegram.org',
  'instagram.com',
  'x.com',
  'whatsapp.com',
  'facebook.com',
  'wikipedia.org',
  'github.com',
  'cloudflare.com',
  'apple.com',
  'microsoft.com',
  // v1.0.7: more real, popular domains across services, clouds and
  // dev tools, so the checker says something useful on any network.
  'chatgpt.com',
  'vercel.com',
  'npmjs.com',
  'nodejs.org',
  'codepen.io',
  'translate.google.com',
  'gmail.com',
  'play.google.com',
  'playstation.com',
  'xbox.com',
  'fastly.com',
  'stackoverflow.com',
  'spotify.com',
  'paypal.com',
  'ebay.com',
  'cnn.com',
  'bbc.com',
  'nytimes.com',
  'zoom.us',
  'dropbox.com',
  'adobe.com',
  'wordpress.com',
  'imgur.com',
  'quora.com',
  'salesforce.com',
  'shopify.com',
  'etsy.com',
  'gitlab.com',
  'digitalocean.com',
  'aws.amazon.com',
  'cloud.google.com',
  'azure.microsoft.com',
  'intel.com',
  'nvidia.com',
  'threads.net',
  'snapchat.com',
  'signal.org',
];

Future<_DomResult> _checkDomain(String d) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  final sw = Stopwatch()..start();
  try {
    final req = await c.getUrl(Uri.parse('https://$d/'));
    final res = await req.close().timeout(const Duration(seconds: 6));
    await res.drain();
    return _DomResult(true, sw.elapsedMilliseconds, res.statusCode);
  } catch (_) {
    return const _DomResult(false, -1, null);
  } finally {
    c.close(force: true);
  }
}

class DomainCheckPage extends StatefulWidget {
  const DomainCheckPage(this.s, {super.key});
  final Store s;
  @override
  State<DomainCheckPage> createState() => _DomainCheckState();
}

class _DomainCheckState extends State<DomainCheckPage> {
  final customCtl = TextEditingController();
  final domains = <String>[..._defaultDomains];
  final results = <String, _DomResult>{};
  bool testing = false;

  Future<void> _testAll() async {
    setState(() {
      testing = true;
      results.clear();
    });
    final found = await Future.wait(domains.map((d) async => MapEntry(d, await _checkDomain(d))));
    if (!mounted) return;
    setState(() {
      for (final f in found) {
        results[f.key] = f.value;
      }
      testing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final rows = [...domains];
    rows.sort((a, b) {
      final ra = results[a], rb = results[b];
      if (ra == null && rb == null) return 0;
      if (ra == null) return 1;
      if (rb == null) return -1;
      if (ra.ok != rb.ok) return ra.ok ? -1 : 1;
      return ra.ms.compareTo(rb.ms);
    });
    return Scaffold(
      appBar: AppBar(title: Text(s.t('domaincheck'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(s.t('domaincheck_d'), style: const TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: customCtl, decoration: InputDecoration(labelText: s.t('customdomain'), border: const OutlineInputBorder()))),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () {
              final v = customCtl.text.trim().toLowerCase().replaceAll(RegExp(r'^https?://'), '').split('/').first;
              if (v.isEmpty || domains.contains(v)) return;
              setState(() {
                domains.add(v);
                customCtl.clear();
              });
            },
            child: Text(s.t('addcustom')),
          ),
        ]),
        const SizedBox(height: 12),
        FilledButton.icon(icon: const Icon(Icons.language_outlined), label: Text(testing ? '...' : s.t('test')), onPressed: testing ? null : _testAll),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.file_upload_outlined, size: 18),
            label: Text(s.t('importdomains')),
            onPressed: () async {
              final text = await _pickTxt();
              if (text == null || !mounted) return;
              var added = 0;
              for (final raw in text.split(RegExp(r'[\s,;]+'))) {
                final v = raw.trim().toLowerCase().replaceAll(RegExp(r'^https?://'), '').split('/').first;
                if (v.isEmpty || !v.contains('.') || v.contains(' ') || domains.contains(v)) continue;
                domains.add(v);
                added++;
                if (added >= 200) break;
              }
              if (mounted) setState(() {});
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${s.t('added')}: $added')));
            },
          ),
          if (results.values.any((r) => r.ok))
            OutlinedButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: Text(s.t('copyhealthy')),
              onPressed: () {
                final ok = domains.where((d) => results[d]?.ok == true).toList()..sort((a, b) => results[a]!.ms.compareTo(results[b]!.ms));
                _copy(context, ok.map((d) => '$d ${results[d]!.ms} ms').join('\n'), s.t('copy'));
              },
            ),
        ]),
        const SizedBox(height: 12),
        for (final d in rows)
          ListTile(
            dense: true,
            title: Text(d, style: const TextStyle(fontWeight: FontWeight.w700)),
            trailing: results[d] == null
                ? null
                : Text(
                    results[d]!.ok ? '${s.t('reachable')} ${results[d]!.ms} ms' : s.t('blocked'),
                    style: TextStyle(color: results[d]!.ok ? const Color(0xFF2BD67B) : Colors.redAccent),
                  ),
            onTap: () => _copy(context, d, s.t('copy')),
          ),
      ]),
    );
  }
}

/// Expands one-per-line IPs, dash ranges (a-b) and CIDR blocks into
/// individual IPv4 addresses, capped at 256 (a /24 is 254 hosts; a
/// careless /16 would otherwise produce 65k configs).
List<String> _expandIps(String input) {
  final out = <String>[];
  final ipRe = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
  int? parseIp(String v) {
    if (!ipRe.hasMatch(v)) return null;
    final p = v.split('.').map(int.tryParse).toList();
    if (p.any((e) => e == null || e > 255)) return null;
    return (p[0]! << 24) | (p[1]! << 16) | (p[2]! << 8) | p[3]!;
  }

  String fmt(int v) => '${(v >> 24) & 0xFF}.${(v >> 16) & 0xFF}.${(v >> 8) & 0xFF}.${v & 0xFF}';
  for (final token in input.split(RegExp(r'[\s,;]+')).where((e) => e.isNotEmpty)) {
    if (out.length >= 256) break;
    if (token.contains('/')) {
      final parts = token.split('/');
      final base = parseIp(parts[0]);
      final prefix = parts.length > 1 ? int.tryParse(parts[1]) : null;
      if (base == null || prefix == null || prefix < 24 || prefix > 32) continue;
      final count = 1 << (32 - prefix);
      final mask = 0xFFFFFFFF << (32 - prefix);
      final net = base & mask;
      final start = count > 2 ? 1 : 0;
      final end = count > 2 ? count - 1 : count;
      for (var i = start; i < end && out.length < 256; i++) {
        out.add(fmt(net + i));
      }
      continue;
    }
    if (token.contains('-')) {
      final parts = token.split('-');
      if (parts.length != 2) continue;
      final a = parseIp(parts[0].trim());
      final b = parseIp(parts[1].trim());
      if (a == null || b == null || b < a) continue;
      for (var v = a; v <= b && out.length < 256; v++) {
        out.add(fmt(v));
      }
      continue;
    }
    if (parseIp(token) != null) out.add(token);
  }
  return out;
}

class VlessModifierPage extends StatefulWidget {
  const VlessModifierPage(this.s, {super.key});
  final Store s;
  @override
  State<VlessModifierPage> createState() => _VlessModifierState();
}

class _VlessModifierState extends State<VlessModifierPage> {
  final cfgCtl = TextEditingController();
  final ipsCtl = TextEditingController();
  List<String> outputs = [];
  String note = '';

  void _generate() {
    final s = widget.s;
    final cfg = cfgCtl.text.trim();
    final u = Uri.tryParse(cfg);
    if (cfg.isEmpty || u == null || (u.scheme != 'vless' && u.scheme != 'trojan')) {
      setState(() {
        outputs = [];
        note = s.t('invalidconfig');
      });
      return;
    }
    final ips = _expandIps(ipsCtl.text);
    setState(() {
      outputs = ips.map((ip) => u.replace(host: ip).toString()).toList();
      note = '${outputs.length} ${s.t('configs')}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('vlessmod'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(s.t('vlessmod_d'), style: const TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 12),
        TextField(controller: cfgCtl, minLines: 3, maxLines: 6, decoration: InputDecoration(labelText: s.t('pasteconfig'), border: const OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(controller: ipsCtl, minLines: 3, maxLines: 6, decoration: InputDecoration(labelText: s.t('iplist'), border: const OutlineInputBorder())),
        const SizedBox(height: 12),
        FilledButton.icon(icon: const Icon(Icons.swap_horiz_outlined), label: Text(s.t('generate')), onPressed: _generate),
        if (note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text(note, style: const TextStyle(fontWeight: FontWeight.w700))),
        if (outputs.isNotEmpty) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: Text(s.t('copy')),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: outputs.join('\n')));
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.t('copy'))));
            },
          ),
          const SizedBox(height: 8),
          SelectableText(outputs.join('\n'), style: const TextStyle(fontSize: 12)),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------- base64 codec

/// v10.1.7: Base64 encode/decode for any text, link or config,
/// both directions, in Tools. Decode accepts standard and
/// URL-safe alphabets and repairs missing padding, so pasted
/// encoded config blobs decode even when they were wrapped or
/// copied without padding. The result is selectable and
/// copyable; nothing is sent anywhere.
class CodecPage extends StatefulWidget {
  const CodecPage(this.s, {super.key});
  final Store s;
  @override
  State<CodecPage> createState() => _CodecState();
}

class _CodecState extends State<CodecPage> {
  final inCtl = TextEditingController();
  String out = '';
  String err = '';
  bool decode = true;

  @override
  void dispose() {
    inCtl.dispose();
    super.dispose();
  }

  void _run() {
    final text = inCtl.text.trim();
    if (text.isEmpty) {
      setState(() {
        out = '';
        err = '';
      });
      return;
    }
    if (decode) {
      final d = decodeBase64Loose(text);
      setState(() {
        out = d ?? '';
        err = d == null ? widget.s.t('codec_invalid') : '';
      });
    } else {
      setState(() {
        out = base64.encode(utf8.encode(inCtl.text));
        err = '';
      });
    }
  }

  void _clear() {
    inCtl.clear();
    setState(() {
      out = '';
      err = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('cat_codec'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          Expanded(
            child: decode
                ? FilledButton.icon(icon: const Icon(Icons.lock_open_outlined, size: 18), label: Text(s.t('codec_decode')), onPressed: () => setState(() => decode = true))
                : OutlinedButton.icon(icon: const Icon(Icons.lock_open_outlined, size: 18), label: Text(s.t('codec_decode')), onPressed: () => setState(() => decode = true)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: !decode
                ? FilledButton.icon(icon: const Icon(Icons.lock_outlined, size: 18), label: Text(s.t('codec_encode')), onPressed: () => setState(() => decode = false))
                : OutlinedButton.icon(icon: const Icon(Icons.lock_outlined, size: 18), label: Text(s.t('codec_encode')), onPressed: () => setState(() => decode = false)),
          ),
        ]),
        const SizedBox(height: 12),
        TextField(
          controller: inCtl,
          minLines: 4,
          maxLines: 12,
          decoration: InputDecoration(labelText: s.t('codec_input'), border: const OutlineInputBorder(), alignLabelWithHint: true),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: FilledButton.icon(icon: const Icon(Icons.swap_horiz_outlined, size: 18), label: Text(decode ? s.t('codec_decode') : s.t('codec_encode')), onPressed: _run)),
          const SizedBox(width: 8),
          OutlinedButton.icon(icon: const Icon(Icons.clear, size: 18), label: Text(s.t('codec_clear')), onPressed: _clear),
        ]),
        if (err.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text(err, style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w700))),
        if (out.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(s.t('codec_output'), style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(border: Border.all(color: Colors.grey), borderRadius: BorderRadius.circular(8)),
            child: SelectableText(out, style: const TextStyle(fontSize: 13)),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: Text(s.t('codec_copy')),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: out));
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.t('copied'))));
            },
          ),
        ],
      ]),
    );
  }
}
