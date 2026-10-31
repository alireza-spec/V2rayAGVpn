import 'package:flutter_test/flutter_test.dart';
import 'package:v2rayag/ui/ai_chat.dart';

// v10.1.1: chat connect is test-first with provider priority:
// country connects try Fast/AI first and V2rayAG Exclusive last,
// "fast and strong" requests reverse that (V2rayAG first, AI
// last). The test pool is probed before any attempt, and only
// what passed is attempted (up to 25).
void main() {
  const all = [
    ChatCand('l-v2', 'v2rayag', false, 50),
    ChatCand('l-hid', 'hiddify', false, 50),
    ChatCand('l-af', 'antifilter', false, 50),
    ChatCand('l-up', 'update', false, 50),
    ChatCand('l-ai', 'ai', false, 50),
    ChatCand('l-fast', 'fast', false, 50),
  ];

  test('country order: Fast, AI, Update, Anti-Filter, Hiddify, V2rayAG last', () {
    expect(
        orderChatCandidates(all, false).map((c) => c.provider).toList(),
        ['fast', 'ai', 'update', 'antifilter', 'hiddify', 'v2rayag']);
  });

  test('fast&strong order: V2rayAG first, AI last', () {
    expect(
        orderChatCandidates(all, true).map((c) => c.provider).toList(),
        ['v2rayag', 'fast', 'update', 'antifilter', 'hiddify', 'ai']);
  });

  test('traffic-failed sorts last within its provider; ping ascending', () {
    const cands = [
      ChatCand('l1', 'fast', true, 10),
      ChatCand('l2', 'fast', false, 90),
      ChatCand('l3', 'fast', false, 30),
    ];
    expect(orderChatCandidates(cands, false).map((c) => c.link).toList(),
        ['l3', 'l2', 'l1']);
  });

  test('UDP 9000 probe sorts after real pings in the same provider', () {
    const cands = [
      ChatCand('l-udp', 'fast', false, 9000),
      ChatCand('l-real', 'fast', false, 120),
    ];
    expect(orderChatCandidates(cands, false).first.link, 'l-real');
  });

  test('untested sorts after tested', () {
    const cands = [
      ChatCand('l-new', 'fast', false),
      ChatCand('l-old', 'fast', false, 40),
    ];
    expect(orderChatCandidates(cands, false).map((c) => c.link).toList(),
        ['l-old', 'l-new']);
  });

  test('unknown providers sort last', () {
    const cands = [
      ChatCand('l-x', 'weird', false, 5),
      ChatCand('l-f', 'fast', false, 500),
    ];
    expect(orderChatCandidates(cands, false).first.link, 'l-f');
  });

  test('fast&strong detection: Persian and English speed words', () {
    expect(isFastStrong('منو به یه سرور سریع و قوی وصل کن',
        'منو به یه سرور سریع و قوی وصل کن'), isTrue);
    expect(isFastStrong('connect me to a fast server',
        'connect me to a fast server'), isTrue);
    expect(isFastStrong('connect me to a USA server',
        'connect me to a usa server'), isFalse);
  });

  test('USA ready question wording and flags', () {
    expect(readyQuestions[0][0], 'Connect me to a USA server');
    expect(qFlags[0], '🇺🇸');
    expect(qFlags[3], '🇬🇧');
  });
}
