import 'package:flutter_test/flutter_test.dart';
import 'package:v2rayag/engine/pool_engine.dart';

void main() {
  test('no local proxy on every config points at the proxy-mode trap', () {
    final h = diagnosisHint(30, 0, 30, 30);
    expect(h, contains('VPN mode instead of Proxy mode'));
  });

  test('mostly start failures point at refreshing providers', () {
    final h = diagnosisHint(30, 20, 5, 0);
    expect(h, contains('refresh the providers'));
  });

  test('otherwise servers answer but carry no traffic', () {
    final h = diagnosisHint(30, 2, 28, 0);
    expect(h, contains('carried no traffic'));
  });

  test('partial no-proxy counts do not trigger the proxy-mode hint', () {
    final h = diagnosisHint(30, 2, 28, 5);
    expect(h, isNot(contains('VPN mode instead of Proxy mode')));
  });
}
