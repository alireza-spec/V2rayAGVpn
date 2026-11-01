import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:v2rayag/engine/pool_engine.dart';

void main() {
  group('leakVerdict', () {
    test('off when disconnected', () {
      expect(leakVerdict(connected: false, realIp: '1.2.3.4', exitIp: '5.6.7.8'), 'leak_off');
    });
    test('ok when exit differs from real', () {
      expect(leakVerdict(connected: true, realIp: '1.2.3.4', exitIp: '5.6.7.8'), 'leak_ok');
    });
    test('warn when exit equals real', () {
      expect(leakVerdict(connected: true, realIp: '1.2.3.4', exitIp: '1.2.3.4'), 'leak_warn');
    });
    test('unknown when either IP is missing', () {
      expect(leakVerdict(connected: true, realIp: '1.2.3.4', exitIp: ''), 'leak_unknown');
      expect(leakVerdict(connected: true, realIp: '', exitIp: '5.6.7.8'), 'leak_unknown');
    });
  });

  group('dnsServersOf', () {
    test('reads string servers', () {
      final cfg = jsonEncode({
        'dns': {'servers': ['1.1.1.1', '8.8.8.8']},
        'outbounds': [],
      });
      expect(dnsServersOf(cfg), ['1.1.1.1', '8.8.8.8']);
    });
    test('reads object servers by address', () {
      final cfg = jsonEncode({
        'dns': {
          'servers': [
            {'address': '1.1.1.1', 'port': 53},
            {'address': 'https://dns.google/dns-query'},
          ],
        },
        'outbounds': [],
      });
      expect(dnsServersOf(cfg), ['1.1.1.1', 'https://dns.google/dns-query']);
    });
    test('empty when no dns section or unreadable', () {
      expect(dnsServersOf(jsonEncode({'outbounds': []})), isEmpty);
      expect(dnsServersOf('not json'), isEmpty);
    });
  });
}
