import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:v2rayag/engine/pool_engine.dart'; // change to your package name

void main() {
  test('parses subscription-userinfo', () {
    final i = SubInfo.parse('u', 'upload=10; download=20; total=100; expire=2000000000');
    expect(i.used, 30);
    expect(i.remaining, 70);
    expect(i.known, true);
  });
  test('skips expired and exhausted', () {
    const now = 1700000000;
    expect(SubInfo.parse('u', 'upload=0; download=0; total=100; expire=1600000000').usableAt(now), false);
    expect(SubInfo.parse('u', 'upload=60; download=40; total=100; expire=0').usableAt(now), false);
    expect(SubInfo.parse('u', 'upload=1; download=1; total=100; expire=0').usableAt(now), true);
    expect(SubInfo.parse('u', null).usableAt(now), true);
  });
  test('reads base64 and plain subscriptions', () {
    const l = 'vless://id@h.com:443?type=ws#a\ntrojan://pw@h2.com:443#b';
    expect(extractLinks(l).length, 2);
    expect(extractLinks(base64.encode(utf8.encode(l))).length, 2);
  });
  test('chooseFrom stays near the best delay', () {
    const sub = SubInfo(url: 'u');
    final c = [100, 110, 120, 400].map((d) => Candidate('l$d', 'r', 'c', sub)..delayMs = d).toList();
    for (var i = 0; i < 50; i++) {
      expect(chooseFrom(c, Random(i)).delayMs! <= 125, true);
    }
  });
}
