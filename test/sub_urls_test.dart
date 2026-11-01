import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:v2rayag/engine/pool_engine.dart';

void main() {
  group('extractSubUrls', () {
    test('single plain URL', () {
      expect(extractSubUrls('https://example.com/sub'), ['https://example.com/sub']);
    });
    test('comma-separated without spaces', () {
      expect(
        extractSubUrls('https://a.com/s1,https://b.com/s2'),
        ['https://a.com/s1', 'https://b.com/s2'],
      );
    });
    test('URLs mixed with prose and labels', () {
      expect(
        extractSubUrls('my subs:\nfirst: https://a.com/s1\nsecond one is https://b.com/s2 enjoy'),
        ['https://a.com/s1', 'https://b.com/s2'],
      );
    });
    test('quoted, bracketed and trailing punctuation', () {
      expect(
        extractSubUrls('"https://a.com/s1", (https://b.com/s2); https://c.com/s3.'),
        ['https://a.com/s1', 'https://b.com/s2', 'https://c.com/s3'],
      );
    });
    test('deduplicates, keeps order', () {
      expect(
        extractSubUrls('https://a.com/s1 https://b.com/s2 https://a.com/s1'),
        ['https://a.com/s1', 'https://b.com/s2'],
      );
    });
    test('share links are configs, not subs', () {
      expect(extractSubUrls('vless://abc@h:443#x https://a.com/s1'), ['https://a.com/s1']);
    });
    test('whole-body base64 blob decodes to URLs', () {
      final blob = base64.encode(utf8.encode('https://a.com/s1\nhttps://b.com/s2'));
      expect(extractSubUrls(blob), ['https://a.com/s1', 'https://b.com/s2']);
    });
    test('empty and URL-free text', () {
      expect(extractSubUrls(''), isEmpty);
      expect(extractSubUrls('no links here at all'), isEmpty);
    });
  });
}
