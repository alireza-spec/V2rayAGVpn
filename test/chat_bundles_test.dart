import 'package:flutter_test/flutter_test.dart';
import 'package:v2rayag/engine/providers.dart';
import 'package:v2rayag/ui/ai_chat.dart';

// v10.1.2: the AI connect pool is the Automatic engine flow over
// every provider's country-filtered bundles, deduped across
// providers — no more enabled-only pool, and no more trying the
// same link once per provider it appears in (the v10.1.1 device
// log showed one core-rejected config retried five times while
// the providers' servers went untried).
void main() {
  ProviderBundle b(String id, List<String> links) =>
      ProviderBundle(id, id, links);
  const us1 = 'vless://u@h1:443#US-01';
  const us2 = 'vless://u@h2:443#US-02';
  const gb1 = 'vless://u@h3:443#GB-01';
  const de1 = 'vless://u@h4:443#DE-01';

  test('country filter keeps only the requested country', () {
    final out = filterChatBundles([
      b('fast', [us1, gb1]),
      b('ai', [us2, de1]),
    ], 'us', false);
    expect(out.map((x) => x.id).toList(), ['fast', 'ai']);
    expect(out[0].links, [us1]);
    expect(out[1].links, [us2]);
  });

  test('country order: Fast, AI, Update, Anti-Filter, Hiddify, V2rayAG last', () {
    final out = filterChatBundles([
      b('v2rayag', [us1]),
      b('ai', [us2]),
      b('fast', [gb1]),
    ], null, false);
    expect(out.map((x) => x.id).toList(), ['fast', 'ai', 'v2rayag']);
  });

  test('fast&strong order: V2rayAG first, AI last', () {
    final out = filterChatBundles([
      b('ai', [us1]),
      b('fast', [us2]),
      b('v2rayag', [gb1]),
    ], null, true);
    expect(out.map((x) => x.id).toList(), ['v2rayag', 'fast', 'ai']);
  });

  test('same link in two providers is kept once', () {
    final out = filterChatBundles([
      b('fast', [us1]),
      b('ai', [us1, us2]),
    ], 'us', false);
    expect(out[0].links, [us1]);
    expect(out[1].links, [us2]);
  });

  test('empty after filtering yields no bundles', () {
    final out = filterChatBundles([b('fast', [gb1])], 'us', false);
    expect(out, isEmpty);
  });
}
