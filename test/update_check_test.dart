import 'package:flutter_test/flutter_test.dart';
import 'package:v2rayag/app/store.dart';

void main() {
  test('newer tag is an update', () {
    expect(updateAvailableFor('v10.1.11', '10110'), true);
  });

  test('same tag is not an update', () {
    expect(updateAvailableFor('v10.1.10', '10110'), false);
  });

  test('older tag is not an update', () {
    // A version reset (2.0.0 after 10.1.10) must never badge.
    expect(updateAvailableFor('v2.0.0', '10110'), false);
  });

  test('garbage tag or build is not an update', () {
    expect(updateAvailableFor('draft', '10110'), false);
    expect(updateAvailableFor('v10.1.12', '0'), false);
  });
}
