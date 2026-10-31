import 'package:flutter_test/flutter_test.dart';
import 'package:v2rayag/ui/ai_chat.dart';

// v1.0.10 bug: "Connect me to a US server" matched NO country
// (the list only has 'usa'/'america'), so the action connected
// the fastest server of ANY country — a German one. The bare
// code must match as a whole word, and the exit geo must match
// the requested country, not just the remark.
void main() {
  test('bare US word matches the US country', () {
    expect(countryIn('Connect me to a US server'), 'us');
    expect(countryIn('Connect me to a UK server'), 'gb');
    expect(countryIn('منو به یه سرور آمریکا وصل کن'), 'us');
    expect(countryIn('منو به یه سرور انگلیس وصل کن'), 'gb');
  });

  test('bare codes never match inside other words', () {
    // Naming a country matches, of course.
    expect(countryIn('Tell me about russia servers'), 'ru');
    // But 'us'/'tr' inside 'trusted' must not match.
    expect(countryIn('I trusted this server'), isNull);
    // 'in'/'it' are everyday words and stay excluded.
    expect(countryIn('Explain it in simple terms'), isNull);
  });

  test('geo location must really be in the requested country', () {
    expect(geoMatches('Falkenstein, Germany', 'us'), isFalse);
    expect(geoMatches('Falkenstein, Germany', 'de'), isTrue);
    expect(geoMatches('Ashburn, United States', 'us'), isTrue);
    expect(geoMatches('London, United Kingdom', 'gb'), isTrue);
    expect(geoMatches('United States', 'us'), isTrue);
    expect(geoMatches('Germany', 'us'), isFalse);
  });

  test('country display names', () {
    expect(countryName('us', false), 'America');
    expect(countryName('us', true), 'آمریکا');
    expect(countryName('gb', true), 'بریتانیا');
  });

  test('smart titles are categories, not the first message', () {
    expect(smartTitle('سلام چرا وصل نمیشه؟', true), 'رفع مشکل وصل نشدن');
    expect(smartTitle('Connect me to a US server', false),
        'Connect to America');
    expect(smartTitle('Why is my connection slow?', false),
        'Connection speed');
  });
}
