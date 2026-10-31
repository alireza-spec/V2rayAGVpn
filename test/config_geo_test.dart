import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:v2rayag/engine/pool_engine.dart';

void main() {
  group('configLooksValid', () {
    test('accepts a vless config in vnext form', () {
      expect(
        configLooksValid(jsonEncode({
          'outbounds': [
            {
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {
                    'address': '1.2.3.4',
                    'port': 443,
                    'users': [
                      {'id': '11111111-2222-3333-4444-555555555555', 'encryption': 'none'}
                    ]
                  }
                ]
              }
            }
          ]
        })),
        isTrue,
      );
    });

    test('accepts a vless config in flat form', () {
      expect(
        configLooksValid(jsonEncode({
          'outbounds': [
            {
              'protocol': 'vless',
              'settings': {'address': '1.2.3.4', 'port': 443, 'id': 'some-uuid'}
            }
          ]
        })),
        isTrue,
      );
    });

    test('accepts vmess, trojan and shadowsocks with complete fields', () {
      expect(
        configLooksValid(jsonEncode({
          'outbounds': [
            {
              'protocol': 'vmess',
              'settings': {
                'vnext': [
                  {
                    'address': '1.2.3.4',
                    'port': 443,
                    'users': [
                      {'id': 'some-uuid'}
                    ]
                  }
                ]
              }
            }
          ]
        })),
        isTrue,
      );
      expect(
        configLooksValid(jsonEncode({
          'outbounds': [
            {
              'protocol': 'trojan',
              'settings': {'address': '1.2.3.4', 'port': 443, 'password': 'pw'}
            }
          ]
        })),
        isTrue,
      );
      expect(
        configLooksValid(jsonEncode({
          'outbounds': [
            {
              'protocol': 'shadowsocks',
              'settings': {'address': '1.2.3.4', 'port': 8388, 'method': 'aes-256-gcm', 'password': 'pw'}
            }
          ]
        })),
        isTrue,
      );
    });

    test('rejects an empty id, a missing address, empty outbounds and bad JSON', () {
      expect(
        configLooksValid(jsonEncode({
          'outbounds': [
            {
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {
                    'address': '1.2.3.4',
                    'port': 443,
                    'users': [
                      {'id': ''}
                    ]
                  }
                ]
              }
            }
          ]
        })),
        isFalse,
      );
      expect(
        configLooksValid(jsonEncode({
          'outbounds': [
            {
              'protocol': 'vless',
              'settings': {}
            }
          ]
        })),
        isFalse,
      );
      expect(configLooksValid(jsonEncode({'outbounds': []})), isFalse);
      expect(configLooksValid('not json at all'), isFalse);
    });

    test('is forgiving for unknown protocols with an address and port', () {
      expect(
        configLooksValid(jsonEncode({
          'outbounds': [
            {
              'protocol': 'hysteria2',
              'settings': {'address': '1.2.3.4', 'port': 443}
            }
          ]
        })),
        isTrue,
      );
    });
  });

  group('serverHostFromLink', () {
    test('reads the host of vless, trojan and shadowsocks links', () {
      expect(serverHostFromLink('vless://11111111-2222-3333-4444-555555555555@us.example.com:443?security=tls#US-01'), 'us.example.com');
      expect(serverHostFromLink('trojan://pw@uk.example.com:443#UK-01'), 'uk.example.com');
      expect(serverHostFromLink('ss://YWVzLTI1Ni1nY206cHc=@ss.example.com:8388#SS'), 'ss.example.com');
    });

    test('reads the add field of a vmess link', () {
      final vmess = 'vmess://${base64Encode(utf8.encode(jsonEncode({'v': '2', 'ps': 'TEST', 'add': '5.6.7.8', 'port': '443', 'id': 'some-uuid'})))}';
      expect(serverHostFromLink(vmess), '5.6.7.8');
    });

    test('returns null for garbage', () {
      expect(serverHostFromLink('not a link'), isNull);
    });
  });

  group('parseGeoBody', () {
    test('parses an ip-api answer', () {
      final g = parseGeoBody('{"status":"success","query":"205.252.135.147","country":"Germany","countryCode":"DE","city":"Frankfurt am Main"}');
      expect(g, isNotNull);
      expect(g!['ip'], '205.252.135.147');
      expect(g['loc'], 'Frankfurt am Main, Germany');
      expect(g['cc'], 'DE');
    });

    test('parses an ipwho.is answer', () {
      final g = parseGeoBody('{"ip":"8.8.8.8","country":"United States","country_code":"US","city":"Mountain View"}');
      expect(g, isNotNull);
      expect(g!['ip'], '8.8.8.8');
      expect(g['loc'], 'Mountain View, United States');
      expect(g['cc'], 'US');
    });

    test('rejects a failure status and accepts a plain IPv4 body', () {
      expect(parseGeoBody('{"status":"fail","message":"reserved range"}'), isNull);
      final g = parseGeoBody('46.143.126.1');
      expect(g, isNotNull);
      expect(g!['ip'], '46.143.126.1');
      expect(g['loc'], '');
      expect(g['cc'], '');
    });
  });
}
