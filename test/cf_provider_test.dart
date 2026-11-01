import 'package:flutter_test/flutter_test.dart';
import 'package:v2rayag/app/store.dart';

void main() {
  test('empty account ID means no base', () {
    expect(cfBaseFromAccountId(''), '');
    expect(cfBaseFromAccountId('   '), '');
  });

  test('builds the Workers AI base URL', () {
    expect(cfBaseFromAccountId('abc123'),
        'https://api.cloudflare.com/client/v4/accounts/abc123/ai/v1');
  });

  test('trims surrounding whitespace', () {
    expect(cfBaseFromAccountId('  abc123  '),
        'https://api.cloudflare.com/client/v4/accounts/abc123/ai/v1');
  });
}
