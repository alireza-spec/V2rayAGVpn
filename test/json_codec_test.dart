import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:v2rayag/engine/pool_engine.dart';

// A v2rayNG-style full JSON config: socks + http inbounds, one
// vless outbound, routing that references the socks inbound tag.
String sampleJson({String listen = '127.0.0.1', String socksTag = 'socks'}) => jsonEncode({
      'log': {'loglevel': 'warning'},
      'inbounds': [
        {'tag': socksTag, 'port': 10808, 'listen': listen, 'protocol': 'socks', 'settings': {'auth': 'noauth', 'udp': true}},
        {'tag': 'http', 'port': 10809, 'listen': '127.0.0.1', 'protocol': 'http', 'settings': {}},
      ],
      'outbounds': [
        {
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': {
            'vnext': [
              {
                'address': '203.0.113.7',
                'port': 443,
                'users': [{'id': '11111111-2222-3333-4444-555555555555', 'encryption': 'none'}],
              },
            ],
          },
          'streamSettings': {'network': 'tcp'},
        },
        {'tag': 'direct', 'protocol': 'freedom', 'settings': {}},
      ],
      'routing': {
        'rules': [
          {'type': 'field', 'inboundTag': [socksTag], 'outboundTag': 'proxy'},
        ],
      },
    });

void main() {
  group('decodeBase64Loose', () {
    test('decodes standard base64', () {
      expect(decodeBase64Loose(base64.encode(utf8.encode('vless://x'))), 'vless://x');
    });
    test('accepts URL-safe alphabet and missing padding', () {
      final std = base64.encode(utf8.encode('hello world?'));
      final urlSafe = std.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
      expect(decodeBase64Loose(urlSafe), 'hello world?');
    });
    test('strips whitespace', () {
      final b = base64.encode(utf8.encode('abc'));
      expect(decodeBase64Loose('${b.substring(0, 2)} ${b.substring(2)}'), 'abc');
    });
    test('rejects non-base64 text', () {
      expect(decodeBase64Loose('not base64!! vless://'), isNull);
    });
  });

  group('normalizeJsonConfig', () {
    test('keeps a well-formed v2rayNG config usable', () {
      final norm = normalizeJsonConfig(sampleJson());
      expect(norm, isNotNull);
      expect(configLooksValid(norm!), isTrue);
    });
    test('pins non-loopback socks listen and renames a custom tag', () {
      final norm = normalizeJsonConfig(sampleJson(listen: '0.0.0.0', socksTag: 'my-socks'));
      expect(norm, isNotNull);
      final d = jsonDecode(norm!) as Map<String, dynamic>;
      final inbounds = d['inbounds'] as List;
      final socks = inbounds.firstWhere((e) => e['protocol'] == 'socks') as Map<String, dynamic>;
      expect(socks['listen'], '127.0.0.1');
      expect(socks['tag'], 'socks');
      final rules = (d['routing'] as Map<String, dynamic>)['rules'] as List;
      expect((rules.first as Map<String, dynamic>)['inboundTag'], ['socks']);
    });
    test('rejects JSON without outbounds', () {
      expect(normalizeJsonConfig('{"log": {}}'), isNull);
      expect(normalizeJsonConfig('not json'), isNull);
    });
  });

  group('json links', () {
    test('plain JSON text becomes a json: link and round-trips', () {
      final link = jsonLinkFromText(sampleJson());
      expect(link, startsWith('json:'));
      final cfg = decodeJsonLink(link!);
      expect(cfg, isNotNull);
      expect(jsonConfigName(cfg!), '203.0.113.7:443');
      expect(configLooksValid(cfg), isTrue);
    });
    test('base64-encoded JSON text becomes a json: link', () {
      final blob = base64.encode(utf8.encode(sampleJson()));
      final link = jsonLinkFromText(blob);
      expect(link, startsWith('json:'));
      expect(jsonConfigName(decodeJsonLink(link!)!), '203.0.113.7:443');
    });
    test('non-config text yields no json: link', () {
      expect(jsonLinkFromText('hello world'), isNull);
      expect(decodeJsonLink('vless://uuid@host:443'), isNull);
    });
  });

  group('paste decode', () {
    test('a base64 blob of several links decodes to all of them', () {
      const a = 'vless://11111111-2222-3333-4444-555555555555@203.0.113.7:443?security=tls#one';
      const b = 'vless://22222222-3333-4444-5555-666666666666@203.0.113.8:443?security=tls#two';
      final blob = base64.encode(utf8.encode('$a\n$b'));
      final links = extractLinks(blob);
      expect(links, [a, b]);
    });
  });
}
