import 'package:flutter_test/flutter_test.dart';
import 'package:v2rayag/app/store.dart';

void main() {
  group('backup envelope', () {
    test('build then parse round-trips store and chats', () {
      final store = {'myLinks': ['vless://a@h:443'], 'favorites': ['vless://a@h:443']};
      final chats = [
        {'title': 'chat', 'msgs': []},
      ];
      final doc = parseBackup(buildBackup(store, chats));
      expect(doc, isNotNull);
      expect(doc!['app'], 'V2rayAG');
      expect(doc['v'], 1);
      expect(doc['store'], store);
      expect(doc['chats'], chats);
    });
    test('null chats survives the round-trip', () {
      final doc = parseBackup(buildBackup({'a': 1}, null));
      expect(doc, isNotNull);
      expect(doc!['chats'], isNull);
    });
    test('rejects garbage and wrong envelopes', () {
      expect(parseBackup('not json'), isNull);
      expect(parseBackup('{"app": "Other", "v": 1, "store": {}}'), isNull);
      expect(parseBackup('{"app": "V2rayAG", "v": 2, "store": {}}'), isNull);
      expect(parseBackup('{"app": "V2rayAG", "v": 1, "store": []}'), isNull);
      expect(parseBackup('{"app": "V2rayAG", "v": 1, "store": {}, "chats": {}}'), isNull);
    });
  });
}
