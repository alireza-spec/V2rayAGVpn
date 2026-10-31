import 'package:flutter_test/flutter_test.dart';
import 'package:v2rayag/ui/ai_chat.dart';

// v10.1.3: the shortcuts row under a connection message is no
// longer transient. It is persisted on the message (connLink) and
// its visibility is derived: only the LATEST connection message,
// only while still connected to that exact link. Later messages
// and page returns keep it; a disconnect or a newer connection
// hides it again.
void main() {
  group('lastConnectedMessageIndex', () {
    test('empty list has no connection message', () {
      expect(lastConnectedMessageIndex([]), -1);
    });
    test('all null has no connection message', () {
      expect(lastConnectedMessageIndex([null, null]), -1);
    });
    test('single connection message is its own index', () {
      expect(lastConnectedMessageIndex(['vless://a']), 0);
    });
    test('returns the last non-null, ignoring later plain messages', () {
      expect(
        lastConnectedMessageIndex(['vless://a', null, 'vless://b', null]),
        2,
      );
    });
    test('a newer connection supersedes an older one', () {
      expect(
        lastConnectedMessageIndex(['vless://a', 'vless://b']),
        1,
      );
    });
  });

  group('connShortcutsVisible', () {
    test('shows under the latest connection message while connected', () {
      expect(
        connShortcutsVisible(
          connected: true,
          currentLink: 'vless://a',
          msgLink: 'vless://a',
          isLastConn: true,
        ),
        isTrue,
      );
    });
    test('hides when disconnected', () {
      expect(
        connShortcutsVisible(
          connected: false,
          currentLink: 'vless://a',
          msgLink: 'vless://a',
          isLastConn: true,
        ),
        isFalse,
      );
    });
    test('hides under an older connection message', () {
      expect(
        connShortcutsVisible(
          connected: true,
          currentLink: 'vless://b',
          msgLink: 'vless://a',
          isLastConn: false,
        ),
        isFalse,
      );
    });
    test('hides when connected to a different link', () {
      expect(
        connShortcutsVisible(
          connected: true,
          currentLink: 'vless://b',
          msgLink: 'vless://a',
          isLastConn: true,
        ),
        isFalse,
      );
    });
    test('hides when there is no current link', () {
      expect(
        connShortcutsVisible(
          connected: true,
          currentLink: null,
          msgLink: 'vless://a',
          isLastConn: true,
        ),
        isFalse,
      );
    });
    test('hides when the message announced no connection', () {
      expect(
        connShortcutsVisible(
          connected: true,
          currentLink: 'vless://a',
          msgLink: null,
          isLastConn: false,
        ),
        isFalse,
      );
    });
  });
}
