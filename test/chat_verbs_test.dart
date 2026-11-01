import 'package:flutter_test/flutter_test.dart';
import 'package:v2rayag/ui/ai_chat.dart';

void main() {
  test('connect verbs cover user phrasings', () {
    expect(wantsConnectText('به آمریکا وصلم کن'), true);
    expect(wantsConnectText('به کانفیگ انگلیس وصلم کن'), true);
    expect(wantsConnectText('به آمریکا متصلم کن'), true);
    expect(wantsConnectText('کانکتم کن به آلمان'), true);
    expect(wantsConnectText('وصل کن به فرانسه'), true);
    expect(wantsConnectText('اتصال به ژاپن'), true);
    expect(wantsConnectText('به هلند وصل شو'), true);
    expect(wantsConnectText('connect me to a USA server'), true);
  });

  test('info questions never act', () {
    expect(isInfoQuestion('درباره اتصالم توضیح بده'), true);
    expect(isInfoQuestion('وضعیت اتصالم چیه؟'), true);
    expect(isInfoQuestion('چرا اتصالم قطعه؟'), true);
    expect(isInfoQuestion('وصل کن یعنی چی؟'), true);
    expect(isInfoQuestion('explain my connection'), true);
  });

  test('new countries parse', () {
    expect(countryIn('به استرالیا وصلم کن'), 'au');
    expect(countryIn('برزیل'), 'br');
    expect(countryIn('نروژ'), 'no');
    expect(countryIn('اتریش'), 'at');
    expect(countryIn('کره جنوبی'), 'kr');
  });

  test('everyday words do not false-match countries', () {
    expect(countryIn('no, thanks'), null);
    expect(countryIn('connect me at once'), null);
    expect(countryIn('my server is slow'), null);
    expect(countryIn('a US server'), 'us');
  });
}
