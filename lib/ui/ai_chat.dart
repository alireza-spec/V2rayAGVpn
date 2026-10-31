// AI chat (v1.0.7): a real OpenAI-compatible chat about V2rayAG,
// nothing else. Every call is user-triggered (a sent message or a
// tapped ready question); the app never calls the AI in the
// background, because calls cost quota and logs/configs can carry
// IPs and hosts. The key comes from the AI_API_KEY repo secret
// baked at build time, the in-app override in Settings → AI, or
// the remote config (Settings → AI); with no key the chat says
// so instead of faking an answer. Failures name their HTTP
// status (401 = bad/expired key, 429 = quota) so the real
// reason is visible instead of a generic error.
// Attachments (full log from Logs, or one log line tapped in Logs)
// are sent once, with the first question, as context — never
// re-sent on later turns — and the model is told never to repeat
// keys, passwords, subscription URLs or full config links.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../app/store.dart';
import '../engine/pool_engine.dart';
import '../engine/psiphon_engine.dart';
import '../engine/tcp_probe.dart';
import 'speed_page.dart';

/// Strips a model's thinking trace from its reply. GLM models
/// sometimes emit their <think>…</think> reasoning inline, and
/// showing it looks broken and leaks internal monologue.
String _cleanReply(String t) {
  var out = t.replaceAll(
    RegExp(r'<think>.*?</think>', dotAll: true, caseSensitive: false),
    '',
  );
  out = out.replaceAll(RegExp(r'</?think>', caseSensitive: false), '');
  return out.trim();
}

/// Country match tokens: code → flag, English names, Persian
/// names. A server matches when its remark contains the flag, a
/// whole-word code (so 'US' never matches 'russia' and 'TR'
/// never matches 'trusted'), or one of the names.
const _countries = {
  'us': ['🇺🇸', 'usa', 'america', 'آمریکا'],
  'gb': ['🇬🇧', 'uk', 'gb', 'england', 'britain', 'انگلیس', 'بریتانیا'],
  'de': ['🇩🇪', 'germany', 'آلمان'],
  'nl': ['🇳🇱', 'netherlands', 'holland', 'هلند'],
  'tr': ['🇹🇷', 'turkey', 'ترکیه'],
  'fr': ['🇫🇷', 'france', 'فرانسه'],
  'ca': ['🇨🇦', 'canada', 'کانادا'],
  'se': ['🇸🇪', 'sweden', 'سوئد'],
  'fi': ['🇫🇮', 'finland', 'فنلاند'],
  'jp': ['🇯🇵', 'japan', 'ژاپن'],
  'sg': ['🇸🇬', 'singapore', 'سنگاپور'],
  'ae': ['🇦🇪', 'emirates', 'امارات'],
  'in': ['🇮🇳', 'india', 'هند'],
  'pl': ['🇵🇱', 'poland', 'لهستان'],
  'ch': ['🇨🇭', 'switzerland', 'سوئیس'],
  'it': ['🇮🇹', 'italy', 'ایتالیا'],
  'es': ['🇪🇸', 'spain', 'اسپانیا'],
  'ru': ['🇷🇺', 'russia', 'روسیه'],
};

/// Finds a country code in the user's message, if any. Flags
/// match directly; short codes only as whole words, so 'us'
/// never matches a word like 'russia' in free text.
String? countryIn(String q) {
  final low = q.toLowerCase();
  for (final e in _countries.entries) {
    if (q.contains(e.value.first)) return e.key; // the flag
    // Bare 2-letter codes as whole words ("a US server") — this
    // was the v1.0.10 bug: "Connect me to a US server" matched
    // NO country (the list only has 'usa'/'america'), so the
    // action connected the fastest server of ANY country.
    // 'in'/'it' stay excluded: they are everyday English words.
    if (e.key.length == 2 && !{'in', 'it'}.contains(e.key)) {
      if (RegExp('\\b${e.key}\\b').hasMatch(low)) return e.key;
    }
    for (final token in e.value.skip(1)) {
      if (token.length == 2) {
        if (RegExp('\\b$token\\b').hasMatch(low)) return e.key;
      } else if (low.contains(token)) {
        return e.key;
      }
    }
  }
  return null;
}

/// Canonical geo-service country names that are NOT in
/// _countries (geo returns "United States", not "USA").
const _geoExtraNames = {
  'us': ['united states', 'united states of america'],
  'gb': ['united kingdom', 'great britain'],
  'de': ['deutschland'],
  'ae': ['united arab emirates'],
  'ru': ['russian federation'],
};

/// Does a geo location ("Falkenstein, Germany") really sit in
/// the requested country? A remark that says "US" is not proof
/// — free subscriptions mislabel servers — so a country connect
/// is only a success when the exit IP's country matches. The
/// country is the part after the comma when there is one.
bool geoMatches(String location, String code) {
  final low = location.toLowerCase();
  final names = _countries[code];
  if (names == null) return false;
  final parts = low.split(',');
  final countryPart = parts.length > 1 ? parts.last.trim() : low.trim();
  final candidates = <String>{
    code,
    ...names.sublist(1).where((n) => RegExp(r'^[a-z ]+$').hasMatch(n)),
    ...(_geoExtraNames[code] ?? []),
  };
  return candidates.any((n) => countryPart == n || countryPart.contains(n));
}

bool _remarkMatchesCountry(String remark, String code) {
  final low = remark.toLowerCase();
  final tokens = _countries[code]!;
  if (low.contains(tokens.first)) return true; // the flag
  // Long names as substrings; 2-letter codes only as whole
  // words, so 'uk' never matches a remark like 'Sukuna-01'.
  if (tokens.skip(1).where((t) => t.length > 2).any(low.contains)) {
    return true;
  }
  final words = low.split(RegExp(r'[^a-z0-9]+'));
  return words.contains(code);
}

class _Msg {
  final bool user;
  final String text;
  // Label of the attachment sent with this message (log count,
  // file name, photo name) — shown as a caption under the bubble
  // so a sent attachment stays visible in the conversation.
  final String? attach;
  // When the message was sent, so every bubble can show its
  // time (English digits, small, under the message, Telegram
  // style). Null only for chats saved before v1.0.10, whose
  // messages show no time.
  final DateTime? time;
  const _Msg(this.user, this.text, [this.attach, this.time]);
}

/// One saved conversation for the history sidebar.
class _Chat {
  final String id;
  // Mutable: the user can rename a chat, or pin it to the top.
  String title;
  bool pinned;
  final List<_Msg> msgs;
  _Chat(
      {required this.id,
      required this.title,
      required this.msgs,
      this.pinned = false});
}

/// True when the text is written in Persian/Arabic script — used
/// for per-message direction and for mirroring the reply
/// language to the language the user actually wrote in.
bool _isFaText(String t) => RegExp(r'[\u0600-\u06FF]').hasMatch(t);

/// Reply language for a user message: Persian script → fa,
/// Latin script → en, anything else → the app UI language.
/// (The old code answered in the app UI language, which is why
/// Persian questions got English answers on an English UI.)
bool _replyFa(Store s, String q) {
  if (_isFaText(q)) return true;
  if (RegExp(r'[A-Za-z]').hasMatch(q)) return false;
  return s.fa;
}

TextDirection _dirOf(String t) =>
    _isFaText(t) ? TextDirection.rtl : TextDirection.ltr;

/// "14:32" — built from ints, so the digits are always
/// English regardless of the device locale.
String _fmtTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Display name for a country code, in the chat's language:
/// the longest Latin name for English ("America"), the last
/// (Persian) name for Persian ("آمریکا").
String countryName(String code, bool fa) {
  final names = _countries[code];
  if (names == null || names.length < 2) return code.toUpperCase();
  if (fa) return names.last;
  final latin = names
      .sublist(1)
      .where((n) => RegExp(r'^[a-z ]+$').hasMatch(n))
      .toList();
  if (latin.isEmpty) return code.toUpperCase();
  var best = latin.first;
  for (final n in latin) {
    if (n.length > best.length) best = n;
  }
  return best[0].toUpperCase() + best.substring(1);
}

/// Analytic sidebar title for a chat, from its first message:
/// a category ("Connection failure"), not the message itself
/// ("hi why won't it connect?"), so the sidebar stays
/// scannable days later.
String smartTitle(String q, bool fa) {
  final low = q.toLowerCase();
  String pick(String en, String faTitle) => fa ? faTitle : en;
  if (q.contains('قطع') ||
      low.contains('disconnect') ||
      low.contains('drop')) {
    return pick('Connection drops', 'قطع شدن اتصال');
  }
  // Persian spelling varies (نمی‌شه / نمیشه / نمی شه), so
  // all three forms must count as a connection failure.
  if (q.contains('وصل نمی‌شه') ||
      q.contains('وصل نمیشه') ||
      q.contains('وصل نمی شه') ||
      q.contains('متصل نمی‌شه') ||
      q.contains('متصل نمیشه') ||
      q.contains('متصل نمی شه') ||
      low.contains("won't connect") ||
      low.contains('cannot connect') ||
      low.contains("can't connect") ||
      low.contains('not connecting')) {
    return pick('Connection failure', 'رفع مشکل وصل نشدن');
  }
  // Speed before connect: "Why is my connection slow?"
  // contains "connect" as a substring but is about speed —
  // unless it is a real connect command ("وصل کن" / connect
  // as its own word), which stays a connect title.
  final isConnectCommand = q.contains('وصل کن') ||
      q.contains('متصل کن') ||
      RegExp(r'\bconnect\b').hasMatch(low);
  if (!isConnectCommand &&
      (q.contains('سرعت') ||
          q.contains('کند') ||
          q.contains('پینگ') ||
          low.contains('speed') ||
          low.contains('slow') ||
          low.contains('ping'))) {
    return pick('Connection speed', 'سرعت اتصال');
  }
  if (q.contains('وصل') || q.contains('متصل') || low.contains('connect')) {
    final code = countryIn(q);
    if (code != null) {
      final name = countryName(code, fa);
      return fa ? 'اتصال به $name' : 'Connect to $name';
    }
    return pick('Connect to a server', 'اتصال به سرور');
  }
  if (q.contains('لاگ') || low.contains('log')) {
    return pick('Log explanations', 'توضیح لاگ‌ها');
  }
  if (q.contains('اشتراک') || low.contains('share')) {
    return pick('Share VPN', 'اشتراک‌گذاری VPN');
  }
  if (q.contains('فرانتینگ') || low.contains('cdn')) {
    return pick('CDN Fronting', 'فرانتینگ CDN');
  }
  if (q.contains('سایفون') || low.contains('psiphon')) {
    return pick('Psiphon', 'سایفون');
  }
  if (q.contains('سرور') || low.contains('server')) {
    return pick('Server choice', 'انتخاب سرور');
  }
  if (q.contains('ابزار') || low.contains('tool')) {
    return pick('Tools', 'ابزارها');
  }
  return q.length > 30 ? '${q.substring(0, 30)}…' : q;
}

enum _ActionKind { find, connect, disconnect, mode, psiphon }

class _Action {
  final _ActionKind kind;
  final String? link, remark, message, mode, country;
  // "disconnect and connect to X": stop the current tunnel
  // first, then connect — one message, one sequence.
  final bool disconnectFirst;
  // Ordered connect candidates (best first) for the
  // country-verified loop: a failed or wrong-country server
  // falls through to the next one instead of giving up.
  // v10.1.1: the TEST pool (up to 80), not the attempt list —
  // _runAction probes this pool first and attempts only what
  // passed, up to 25.
  final List<ChatCand>? candidates;
  // v10.1.1: "fast and strong" request → V2rayAG-first order;
  // otherwise the country order (Fast/AI first, V2rayAG last).
  final bool fastStrong;
  const _Action(this.kind,
      {this.link,
      this.remark,
      this.message,
      this.mode,
      this.country,
      this.disconnectFirst = false,
      this.candidates,
      this.fastStrong = false});
}

/// Direct answer from measured state, no AI call: "what
/// location am I on?" must never be stitched together or
/// guessed by the model — the app knows the exit IP for sure.
String _fmtBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String _fmtDur(int sec) {
  final h = (sec ~/ 3600).toString().padLeft(2, '0');
  final m = ((sec % 3600) ~/ 60).toString().padLeft(2, '0');
  final s = (sec % 60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

String? _localAnswer(Store s, String q, bool fa) {
  final low = q.toLowerCase();
  final isWhere = RegExp(
    r'به چه لوکیشنی وصلم|به کجا وصلم|الان کجام|آیپی من چیه|لوکیشن من چیه',
  ).hasMatch(q) ||
      RegExp(r'where am i connected|what location am i|what.{0,20}my (ip|location)')
          .hasMatch(low);
  // "How is my ping/traffic/speed?" — answered from the live
  // connection's own counters, never guessed by the model.
  final isStats = RegExp(r'پینگش|سرعتش|ترافیک|وضعیت اتصال|مصرف')
          .hasMatch(q) ||
      RegExp(r'\b(my )?(ping|speed|traffic|download|upload)\b|connection status')
          .hasMatch(low);
  if (isStats) {
    final e = s.engine.state;
    if (e.phase == Phase.connected) {
      final t = e.traffic;
      if (fa) {
        return 'اتصال فعلی: ${e.configName ?? ''}'
            '${e.exitIp == null ? '' : '\nآی‌پی خروجی: ${e.exitIp}'}'
            '${e.location == null ? '' : '\nلوکیشن: ${e.location}'}'
            '${e.delayMs == null ? '' : '\nپینگ: ${e.delayMs} ms'}'
            '\nمدت اتصال: ${_fmtDur(t.durationSec)}'
            '\nدانلود: ${_fmtBytes(t.downSpeed)}/s (مجموع ${_fmtBytes(t.downTotal)})'
            '\nآپلود: ${_fmtBytes(t.upSpeed)}/s (مجموع ${_fmtBytes(t.upTotal)})';
      }
      return 'Current connection: ${e.configName ?? ''}'
          '${e.exitIp == null ? '' : '\nExit IP: ${e.exitIp}'}'
          '${e.location == null ? '' : '\nLocation: ${e.location}'}'
          '${e.delayMs == null ? '' : '\nPing: ${e.delayMs} ms'}'
          '\nDuration: ${_fmtDur(t.durationSec)}'
          '\nDownload: ${_fmtBytes(t.downSpeed)}/s (total ${_fmtBytes(t.downTotal)})'
          '\nUpload: ${_fmtBytes(t.upSpeed)}/s (total ${_fmtBytes(t.upTotal)})';
    }
    final p = s.psiphon.state;
    if (p.phase == PsiphonPhase.connected) {
      final dur = p.connectedAt == null
          ? null
          : _fmtDur(DateTime.now().difference(p.connectedAt!).inSeconds);
      if (fa) {
        return 'اتصال فعلی: سایفون'
            '${p.exitIp == null ? '' : '\nآی‌پی خروجی: ${p.exitIp}'}'
            '${p.location == null ? '' : '\nلوکیشن: ${p.location}'}'
            '${p.pingMs == null ? '' : '\nپینگ: ${p.pingMs} ms'}'
            '${dur == null ? '' : '\nمدت اتصال: $dur'}';
      }
      return 'Current connection: Psiphon'
          '${p.exitIp == null ? '' : '\nExit IP: ${p.exitIp}'}'
          '${p.location == null ? '' : '\nLocation: ${p.location}'}'
          '${p.pingMs == null ? '' : '\nPing: ${p.pingMs} ms'}'
          '${dur == null ? '' : '\nDuration: $dur'}';
    }
    return s.tLang('aistatsnone', fa);
  }
  if (!isWhere) return null;
  final e = s.engine.state;
  if (e.phase == Phase.connected) {
    return '${s.tLang('aiwhere', fa)} ${e.configName ?? ''}'
        '${e.exitIp == null ? '' : ' — ${e.exitIp}'}'
        '${e.location == null ? '' : ' (${e.location})'}'
        '${e.delayMs == null ? '' : ' — ${e.delayMs} ms'}';
  }
  final p = s.psiphon.state;
  if (p.phase == PsiphonPhase.connected) {
    return '${s.tLang('aiwhere', fa)} Psiphon'
        '${p.exitIp == null ? '' : ' — ${p.exitIp}'}'
        '${p.location == null ? '' : ' (${p.location})'}';
  }
  return s.tLang('ainotconn', fa);
}

/// Real actions the chat can DO (not just explain). Strict
/// patterns only: a question ("why does it disconnect?") must
/// never trigger an action. Connect/find use measured pings
/// first and untested provider configs second; find never
/// connects; connect only runs on an explicit connect request.
_Action? _actionFor(Store s, String q) {
  final low = q.toLowerCase();
  final fa = _replyFa(s, q);
  // Genuine information questions never act, even when they
  // mention an action word: "وصل کن یعنی چی؟" asks what
  // connecting means, "چطور وصل کنم؟" asks how, "چرا لیست
  // سرورها خالیه؟" asks why. But a bare question mark never
  // blocks an action on its own — polite Persian requests
  // ("میتونی منو... وصل کنی؟") ARE commands, and the old code
  // rejected exactly those.
  final isInfo = q.contains('یعنی چی') ||
      q.contains('چیست') ||
      q.contains('چیه') ||
      q.contains('چطور') ||
      q.contains('چگونه') ||
      q.contains('چرا') ||
      RegExp(r'\b(how|why|what is|what does)\b').hasMatch(low);
  if (isInfo) return null;
  // Verbs first, so the combined cases below can use them.
  // "وصل کنی؟" contains "وصل کن" as a substring, so polite
  // requests already match these verbs — the old ؟ block was
  // the only thing stopping them.
  final wantsConnect = q.contains('وصل کن') ||
      q.contains('متصلم کن') ||
      q.contains('وصلش کن') ||
      q.contains('متصل کن') ||
      q.contains('وصل شو') ||
      q.contains('متصل شو') ||
      q.contains('کانکت کن') ||
      RegExp(r'\bconnect\b').hasMatch(low);
  // "لیست..." is a find request too ("لیست سرورهای آمریکا"):
  // the old code only knew پیدا کن / می‌خوام / find.
  final wantsFind = q.contains('پیدا کن') ||
      q.contains('می‌خوام') ||
      q.contains('میخوام') ||
      q.contains('لیست') ||
      q.contains('نشون بده') ||
      q.contains('نمایش بده') ||
      RegExp(r'\b(find|list|show)\b').hasMatch(low);
  final hasDisconnect = RegExp(r'قطع(ش| اتصال)? کن').hasMatch(q) ||
      RegExp(r'\bdisconnect\b').hasMatch(low);
  final psiWord = q.contains('سایفون') || low.contains('psiphon');
  final code = countryIn(q);
  // "به سرور آمریکا سایفون وصل کن": Psiphon to that country,
  // not a Personal config — a mode switch alone never connects.
  // Without a country ("به سایفون وصل کن"), Psiphon to the
  // configured region (or any region when that is empty).
  if (psiWord && wantsConnect) {
    return _Action(_ActionKind.psiphon, country: code ?? s.psiCountry);
  }
  // "قطع کن و به X وصل کن": one sequence, not just a
  // disconnect — the connect below carries disconnectFirst.
  if (hasDisconnect && !wantsConnect) {
    return const _Action(_ActionKind.disconnect);
  }
  const modeWords = {
    'smart': ['اسمارت', 'هوشمند', 'smart'],
    'auto': ['خودکار', 'automatic', 'auto'],
    'cdn': ['سی‌دی‌ان', 'cdn'],
    'personal': ['شخصی', 'personal'],
    'psiphon': ['سایفون', 'psiphon'],
  };
  final hasModeVerb = q.contains('بذار') ||
      q.contains('تغییر بده') ||
      q.contains('عوض کن') ||
      q.contains('فعال کن') ||
      RegExp(r'\b(switch|set|change)\b').hasMatch(low);
  if (hasModeVerb) {
    for (final e in modeWords.entries) {
      if (e.value.any(low.contains)) {
        return _Action(_ActionKind.mode, mode: e.key);
      }
    }
  }
  if (!wantsConnect && !wantsFind) return null;
  // Candidates: every config of the requested country (by name,
  // flag or real location), ordered so the test phase tries the
  // most promising providers first. The test pool is capped at
  // 80: the app tests first and only attempts what passed, so a
  // pool of thousands would cost minutes of probing for nothing.
  // Servers already known to carry no traffic sort last, so a
  // retry naturally tries someone else instead of the same dead
  // one.
  final fastStrong = isFastStrong(q, low);
  final all = <ChatCand>[];
  for (final b in s.buildBundles()) {
    for (final l in b.links) {
      if (code != null && !_remarkMatchesCountry(_remarkOf(l), code)) {
        continue;
      }
      all.add(ChatCand(l, b.id, s.trafficFailed.contains(l), s.pings[l]));
    }
  }
  final ordered = orderChatCandidates(all, fastStrong);
  if (wantsConnect) {
    if (ordered.isEmpty) {
      return _Action(_ActionKind.find, message: s.tLang('ainofound', fa));
    }
    final first = ordered.first;
    return _Action(_ActionKind.connect,
        link: first.link,
        remark: _remarkOf(first.link),
        country: code,
        disconnectFirst: hasDisconnect,
        fastStrong: fastStrong,
        candidates: ordered.take(80).toList());
  }
  if (ordered.isEmpty) {
    return _Action(_ActionKind.find, message: s.tLang('ainofound', fa));
  }
  final lines = <String>[];
  for (final t in ordered.where((c) => c.ms != null).take(3)) {
    lines.add('• ${_remarkOf(t.link)} — ${t.ms} ms');
  }
  for (final l in ordered.where((c) => c.ms == null).take(3 - lines.length)) {
    lines.add('• ${_remarkOf(l.link)}');
  }
  return _Action(_ActionKind.find, message: '${s.tLang('aifound', fa)}\n${lines.join('\n')}');
}

/// One connect candidate: its link, its provider, whether it
/// already proved it carries no traffic, and its measured ping.
class ChatCand {
  final String link, provider;
  final bool stale;
  final int? ms;
  const ChatCand(this.link, this.provider, this.stale, [this.ms]);
}

/// v10.1.1: provider order for a chat country connect (Fast and
/// AI first — they connect most reliably — V2rayAG Exclusive
/// last), and for a "fast and strong" request (V2rayAG Exclusive
/// first: its TR GAMING servers are the speed pick).
const _countryProviderOrder = ['fast', 'ai', 'update', 'antifilter', 'hiddify', 'v2rayag'];
const _fastStrongProviderOrder = ['v2rayag', 'fast', 'update', 'antifilter', 'hiddify', 'ai'];

int providerRank(String id, bool fastStrong) {
  final order = fastStrong ? _fastStrongProviderOrder : _countryProviderOrder;
  final i = order.indexOf(id);
  return i < 0 ? order.length : i;
}

/// "Fast and strong" request? Words, not provider names: a user
/// asking for speed gets the V2rayAG-first order, everyone else
/// gets the country order.
bool isFastStrong(String q, String low) =>
    low.contains('fast') ||
    low.contains('strong') ||
    low.contains('quick') ||
    q.contains('سریع') ||
    q.contains('قوی') ||
    q.contains('پرسرعت');

/// Order chat candidates: previously measured before untested,
/// provider rank, already-traffic-failed last, fastest ping
/// first inside a provider. A UDP config's 9000 ms probe sorts
/// last inside its provider — it answered nothing measurable,
/// so it is tried after real pings, not dropped.
List<ChatCand> orderChatCandidates(List<ChatCand> cands, bool fastStrong) {
  final sorted = [...cands];
  sorted.sort((a, b) {
    final ta = a.ms != null ? 0 : 1, tb = b.ms != null ? 0 : 1;
    if (ta != tb) return ta - tb;
    final ra = providerRank(a.provider, fastStrong), rb = providerRank(b.provider, fastStrong);
    if (ra != rb) return ra - rb;
    if (a.stale != b.stale) return a.stale ? 1 : -1;
    return (a.ms ?? 1 << 30).compareTo(b.ms ?? 1 << 30);
  });
  return sorted;
}

/// Ready questions: the ones users actually ask first. Tapping one
/// sends it as the user's message.
/// Icons for the ready questions, in the same order: USA
/// connect, drop, UK connect, best server, share, logs, CDN,
/// Psiphon, tools. The two country connects show their flag
/// instead of an icon (v10.1.1: USA, not US, to avoid confusion).
const _qIcons = [Icons.public, Icons.link_off, Icons.wifi_off, Icons.flag, Icons.star, Icons.share, Icons.bug_report, Icons.dns, Icons.shield, Icons.build];
const qFlags = ['🇺🇸', null, null, '🇬🇧', null, null, null, null, null, null];

const readyQuestions = [
  // First: the one users actually ask for most — and it IS an
  // action ("connect me"), not just a question, so tapping it
  // really connects (see _actionFor).
  ['Connect me to a USA server', 'منو به یه سرور آمریکا وصل کن'],
  ['Why won\'t it connect?', 'چرا وصل نمی‌شه؟'],
  ['Why does my connection drop?', 'چرا اتصالم قطع می‌شه؟'],
  // UK connect sits in the middle, not first, as asked — same
  // verified-country action as the US one.
  ['Connect me to a UK server', 'منو به یه سرور انگلیس وصل کن'],
  ['Which server is best for me?', 'کدوم سرور برای من بهتره؟'],
  ['How does Share VPN work?', 'اشتراک‌گذاری VPN چطور کار می‌کنه؟'],
  ['What do the logs mean?', 'لاگ‌ها یعنی چی؟'],
  ['How do I use CDN Fronting?', 'فرانتینگ CDN چطور استفاده می‌شه؟'],
  ['Why is Psiphon slow?', 'چرا سایفون کنده؟'],
  ['What do the Tools sections do?', 'بخش‌های ابزارها چی کار می‌کنن؟'],
];

String _remarkOf(String l) {
  try {
    if (l.startsWith('vmess://')) {
      final j = jsonDecode(utf8.decode(base64.decode(base64.normalize(l.substring(8))))) as Map<String, dynamic>;
      return '${j['ps'] ?? ''}';
    }
    final u = Uri.parse(l);
    final frag = Uri.decodeComponent(u.fragment);
    if (frag.isNotEmpty) return frag;
    return u.host;
  } catch (_) {
    return l;
  }
}

/// Measured, just-now snapshot of this phone's app: mode, current
/// server, provider counts, fastest tested servers (remarks + ms
/// only, never links). This is what lets the AI advise on server
/// choice from real data instead of guessing.
String _snapshot(Store s) {
  final b = StringBuffer();
  b.write('Mode: ${s.mode}. ');
  final e = s.engine.state;
  if (e.phase == Phase.connected) {
    b.write('Connected: ${e.configName ?? ''}${e.delayMs == null ? '' : ' (${e.delayMs} ms)'}. ');
    // Real exit facts, so "what location am I on?" is answered
    // from measured state, never stitched together or guessed.
    if (e.exitIp != null) {
      b.write('Exit IP: ${e.exitIp}, location: ${e.location ?? 'unknown'}. ');
    }
  } else if (s.psiphon.state.phase == PsiphonPhase.connected) {
    b.write('Connected via Psiphon. ');
    final p = s.psiphon.state;
    if (p.exitIp != null) {
      b.write('Exit IP: ${p.exitIp}, location: ${p.location ?? p.region ?? 'unknown'}. ');
    }
  } else {
    b.write('Not connected. ');
  }
  b.write('Providers: ');
  b.write(s.providerOrder.map((id) => '${s.providerById(id).name} ${s.providerConfigCount(id)}').join(', '));
  b.write('. ');
  final best = s.pings.entries.where((e) => e.value > 0).toList()..sort((a, b) => a.value.compareTo(b.value));
  if (best.isNotEmpty) {
    b.write('Fastest tested servers: ');
    b.write(best.take(5).map((e) => '${_remarkOf(e.key)} ${e.value} ms').join(', '));
    b.write('.');
  }
  return b.toString();
}

String _systemPrompt(Store s, bool fa) => '''
You are the in-app assistant for V2rayAG, an Android VPN app (Xray core + Psiphon). Answer ONLY about this app and its features, in ${fa ? 'natural, human Persian' : 'English'}. Always write the app name in Latin letters exactly as V2rayAG — never transliterate it into Persian script (never وی‌توری‌ای‌جی or anything like it). Your memory (this conversation), your tasks and your real actions are shared across every provider and model the user picks: switching models never resets what you know or what you can do. Keep answers short and practical; give steps when the user asks how.
Never invent a server status. Never claim a server works without a real traffic test: a ping only proves the endpoint answers, and "Connected" in this app means real traffic passed, not just a ping. Never ask for, repeat, or output API keys, passwords, subscription URLs, or full config links. If the user attached a log, explain only what they ask about, in plain words, and say what to try next.
App facts: modes: Smart (providers, then CDN, then Psiphon until one carries real traffic), Automatic (provider pool), CDN Fronting (clean IP + front host from Tools), Personal (own servers/subs), Psiphon (independent emergency transport). Refresh rules: providers refresh once on first install, then every 12h, except Fast (first time, its row arrow, or Update all only; ticking never refreshes). Geo IP/location fills in the background after connect and never blocks Connected. Tools: IP scanner (finds clean IPs), Host/SNI finder (tests which hosts work as a fronting SNI on the user's operator; only hosts that answer Cloudflare pass), DNS latency test, Domain checker, Vless modifier, Share VPN (sharer exposes the tunnel as a LAN SOCKS5 proxy in Proxy mode or Psiphon mode; joiner enters sharer IP + port and connects with no subscription; hotspot clients must set the proxy because Android hotspot bypasses the sharer's VPN by default). IPv6 switch in Settings (default off) adds Xray DNS queryStrategy UseIPv6 to core modes only.
App snapshot (measured just now): ${_snapshot(s)}
''';

class AiChatPage extends StatefulWidget {
  const AiChatPage(this.s, {super.key, this.attachment, this.attachmentLabel, this.autoAsk});
  final Store s;

  /// Text attached to the first question (full log, or one line).
  final String? attachment;

  /// Short label shown on the attachment chip.
  final String? attachmentLabel;

  /// Question sent automatically on open (per-log explanation).
  final String? autoAsk;

  @override
  State<AiChatPage> createState() => _AiChatState();
}

/// Free Z.ai models offered in chat. glm-4.5-flash is the default
/// (fresh installs); the picker also shows the effective model
/// when a remote config set something else.
const _freeModels = ['glm-4.7-flash', 'glm-4.5-flash'];

/// GonkaRouter's three routed models (OpenAI-compatible IDs).
/// GLM-4.5 Flash is NOT one of them — it is a Z.ai model, which is
/// why the app default stays on Z.ai's glm-4.5-flash while these
/// three are switchable choices.
const _gonkaModels = ['zai-org/GLM-5.3-Flash', 'deepseek-ai/DeepSeek-V4-Flash-0731', 'MiniMaxAI/MiniMax-M2.7'];

String _gonkaLabel(String m) => switch (m) {
      'zai-org/GLM-5.3-Flash' => 'GLM-5.3 Flash',
      'deepseek-ai/DeepSeek-V4-Flash-0731' => 'DeepSeek V4 Flash',
      'MiniMaxAI/MiniMax-M2.7' => 'MiniMax M2.7',
      _ => m,
    };

/// Display name for a model id in the fallback note: Gonka ids
/// get their short label, everything else shows its id.
String _modelLabel(String m) => _gonkaModels.contains(m) ? _gonkaLabel(m) : m;

class _AiChatState extends State<AiChatPage> {
  final msgs = <_Msg>[];
  final history = <Map<String, dynamic>>[];
  final ctl = TextEditingController();
  String? attached;
  String? attachLabel;
  Uint8List? pendingImage;
  String? pendingImageName;
  String? pendingImageMime;
  String? remoteNote;
  bool busy = false, autoSent = false;
  // Quote of an AI message the user is replying to: it rides
  // in the API history only (the bubble shows just what the
  // user typed), so replies work even on old messages.
  String? replyQuote;
  // Live "connecting" row for a real action-connect: set when the
  // action starts, cleared only when the verdict lands.
  String? actionProgress;
  bool actionProgressFa = false;
  // v10.1.1: the progress row has two phases — "testing servers"
  // first, then "connecting" — and the user can cancel either one.
  // Cancel is only offered for a chat connect (never for the
  // Psiphon branch, which has its own settled-result loop).
  bool actionProgressTesting = false;
  bool actionProgressCancellable = false;
  bool _connectCancelled = false;
  // v10.1.1: shortcuts under the Connected message only: the
  // index of that message and the link it connected. They render
  // only while that message is still the last one, so the next
  // message (from either side) hides them automatically. They are
  // transient — never saved with the chat.
  int? connectedShortcutIndex;
  String? connectedShortcutLink;
  // v10.1.1: model-fallback note, shown in the thinking row while
  // the retry runs ("Switched to …").
  String? modelSwitchNote;
  // History sidebar: saved conversations + which one is open.
  final savedChats = <_Chat>[];
  String currentChatId = '';
  String currentTitle = '';
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// A new message, stamped with "now" so its bubble can show
  /// its time. Loaded history keeps its saved stamp instead.
  _Msg _m(bool user, String text, [String? attach]) =>
      _Msg(user, text, attach, DateTime.now());

  @override
  void initState() {
    super.initState();
    attached = widget.attachment;
    attachLabel = widget.attachmentLabel;
    currentChatId = DateTime.now().millisecondsSinceEpoch.toString();
    _loadChats();
    // A plain open resumes the last conversation; a Logs-opened
    // chat (attachment/autoAsk) always starts fresh.
    if (widget.attachment == null &&
        widget.autoAsk == null &&
        savedChats.isNotEmpty) {
      final last = savedChats.first;
      _applyChat(last.id, last.title, last.msgs);
    }
    // v1.0.7b: one refresh round when AI work starts, so a key /
    // base URL / model rotated in the remote config reaches this
    // phone with no new app version. Silent failure: the note
    // only shows, chat itself is never blocked by it.
    if (widget.s.aiRemoteUrl.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final r = await widget.s.refreshAiRemote();
        if (mounted) setState(() => remoteNote = r);
      });
    }
    if (widget.autoAsk != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!autoSent && mounted) {
          autoSent = true;
          _send(widget.autoAsk!);
        }
      });
    }
  }

  Future<void> _refreshRemote() async {
    final r = await widget.s.refreshAiRemote();
    if (mounted) setState(() => remoteNote = r);
  }

  /// Chat history file: same directory rule as Store's own file
  /// (app-private files dir, temp dir as a fallback).
  File _chatsFile() {
    const d = '/data/data/com.v2rayag.v2rayag/files';
    final dir = Directory(d);
    return File('${dir.existsSync() ? d : Directory.systemTemp.path}/aichats.json');
  }

  void _loadChats() {
    try {
      final f = _chatsFile();
      if (!f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync()) as List;
      savedChats.clear();
      for (final e in j) {
        final m = e as Map<String, dynamic>;
        final ms = <_Msg>[];
        for (final x in (m['msgs'] as List? ?? [])) {
          final xm = x as Map<String, dynamic>;
          final ts = xm['ts'];
          ms.add(_Msg(
            xm['u'] == true,
            '${xm['t'] ?? ''}',
            xm['a'] as String?,
            ts is int ? DateTime.fromMillisecondsSinceEpoch(ts) : null,
          ));
        }
        savedChats.add(_Chat(
          id: '${m['id'] ?? ''}',
          title: '${m['title'] ?? ''}',
          msgs: ms,
          pinned: m['p'] == true,
        ));
      }
    } catch (_) {
      savedChats.clear();
    }
  }

  /// Persists the open conversation (and the deletion of one).
  /// Empty conversations are never kept — opening a new chat
  /// must not fill the sidebar with blank rows.
  void _saveChats() {
    try {
      if (msgs.isEmpty) {
        savedChats.removeWhere((c) => c.id == currentChatId);
      } else {
        var snap = List.of(msgs);
        if (snap.length > 100) snap = snap.sublist(snap.length - 100);
        final idx = savedChats.indexWhere((c) => c.id == currentChatId);
        // The entry is rebuilt on every save, so a renamed or
        // pinned flag must be carried over, not reset.
        final chat = _Chat(
          id: currentChatId,
          title: currentTitle.isEmpty ? widget.s.t('ainewchat') : currentTitle,
          msgs: snap,
          pinned: idx >= 0 ? savedChats[idx].pinned : false,
        );
        if (idx >= 0) {
          savedChats[idx] = chat;
        } else {
          savedChats.insert(0, chat);
        }
        while (savedChats.length > 20) {
          savedChats.removeLast();
        }
      }
      _chatsFile().writeAsStringSync(jsonEncode(savedChats
          .map((c) => {
                'id': c.id,
                'title': c.title,
                if (c.pinned) 'p': true,
                'msgs': c.msgs
                    .map((m) => {
                          'u': m.user,
                          't': m.text,
                          if (m.attach != null) 'a': m.attach,
                          if (m.time != null)
                            'ts': m.time!.millisecondsSinceEpoch,
                        })
                    .toList(),
              })
          .toList()));
    } catch (_) {}
  }

  void _applyChat(String id, String title, List<_Msg> m) {
    currentChatId = id;
    currentTitle = title;
    msgs.clear();
    msgs.addAll(m);
    history.clear();
    for (final x in m) {
      history.add({'role': x.user ? 'user' : 'assistant', 'content': x.text});
    }
    attached = null;
    attachLabel = null;
    pendingImage = null;
    pendingImageName = null;
    pendingImageMime = null;
    actionProgress = null;
    // Shortcuts belong to one live session only: switching or
    // starting a chat must never show them under another chat's
    // message with a coincidentally equal index.
    connectedShortcutIndex = null;
    connectedShortcutLink = null;
  }

  void _switchChat(_Chat c) {
    _saveChats();
    setState(() => _applyChat(c.id, c.title, c.msgs));
  }

  void _newChat() {
    _saveChats();
    setState(() => _applyChat(
        DateTime.now().millisecondsSinceEpoch.toString(), '', []));
  }

  /// Renames a sidebar chat (its open title follows when the
  /// renamed chat is the one on screen).
  Future<void> _renameChat(_Chat c) async {
    final s = widget.s;
    final ctl = TextEditingController(text: c.title);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('airename')),
        content: TextField(
          controller: ctl,
          decoration: InputDecoration(hintText: c.title),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: Text(s.t('aisave')),
          ),
        ],
      ),
    );
    if (next == null || next.isEmpty || !mounted) return;
    setState(() {
      c.title = next;
      if (c.id == currentChatId) currentTitle = next;
    });
    _saveChats();
  }

  /// Re-runs the pipeline for a message as a NEW turn appended
  /// at the end: a failed connect retries with the next
  /// candidate (failed servers sort last), a model reply gets
  /// a fresh answer. Works for old messages too — the question
  /// text is all it needs. Blocked while busy or while a
  /// connect is already running, so two actions never race.
  Future<void> _retryAt(int index) async {
    if (busy || actionProgress != null) return;
    if (index < 0 || index >= msgs.length) return;
    var q = '';
    for (var j = index; j >= 0; j--) {
      if (msgs[j].user) {
        q = msgs[j].text;
        break;
      }
    }
    if (q.isEmpty) return;
    final s = widget.s;
    final fa = _replyFa(s, q);
    setState(() => busy = true);
    final local = _localAnswer(s, q, fa);
    if (local != null) {
      if (mounted) {
        setState(() {
          msgs.add(_m(false, local));
          busy = false;
        });
        _saveChats();
      }
      return;
    }
    final action = _actionFor(s, q);
    if (action != null) {
      await _runAction(action, fa);
      _saveChats();
      return;
    }
    final keyOk = s.aiProvider == 'gonka'
        ? s.gonkaReady
        : s.aiProvider == 'custom'
            ? s.customReady
            : s.aiReady;
    if (!keyOk) {
      if (mounted) {
        setState(() {
          msgs.add(_m(
              false,
              s.aiProvider == 'gonka'
                  ? s.tLang('gonkanokey', fa)
                  : s.aiProvider == 'custom'
                      ? s.tLang('customnokey', fa)
                      : s.tLang('ainokey', fa)));
          busy = false;
        });
        _saveChats();
      }
      return;
    }
    history.add({'role': 'user', 'content': q});
    try {
      final reply = await _chat(s, history, fa: fa);
      if (!mounted) return;
      setState(() {
        msgs.add(_m(false, reply));
        history.add({'role': 'assistant', 'content': reply});
        busy = false;
      });
      _saveChats();
    } catch (e) {
      if (!mounted) return;
      final detail =
          e is TimeoutException ? 'timed out, try again' : 'network error';
      setState(() {
        msgs.add(_m(false, '${s.tLang('aifailed', fa)}: $detail'));
        busy = false;
      });
      history.removeLast();
      _saveChats();
    }
  }

  Future<void> _deleteChat(String id) async {
    // v10.1.1: delete takes a confirmation, so a stray tap
    // never wipes a conversation.
    if (_scaffoldKey.currentState?.isDrawerOpen == true) {
      Navigator.pop(context);
    }
    final s = widget.s;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('aidelete')),
        content: Text(s.t('aideleteconfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.t('delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final wasCurrent = id == currentChatId;
    savedChats.removeWhere((c) => c.id == id);
    setState(() {
      if (wasCurrent) {
        if (savedChats.isNotEmpty) {
          final n = savedChats.first;
          _applyChat(n.id, n.title, n.msgs);
        } else {
          _applyChat(
              DateTime.now().millisecondsSinceEpoch.toString(), '', []);
        }
      }
    });
    _saveChats();
  }

  Future<void> _send(String text) async {
    final q = text.trim();
    if (q.isEmpty || busy) return;
    final s = widget.s;
    // The reply language mirrors the language the user wrote in,
    // and the sent message keeps its attachment label as a
    // caption, so a sent attachment stays visible in the chat.
    final fa = _replyFa(s, q);
    // A reply in progress: consumed by this send, then cleared.
    final quote = replyQuote;
    replyQuote = null;
    final sendAttach = attachLabel ?? pendingImageName;
    if (currentTitle.isEmpty) {
      // Analytic title, not the first message itself — the
      // sidebar must stay scannable days later.
      currentTitle = smartTitle(q, fa);
    }
    setState(() {
      msgs.add(_m(true, q, sendAttach));
      busy = true;
    });
    _saveChats();
    // Local first: direct answers and real actions never spend
    // quota and never hallucinate server facts.
    final local = _localAnswer(s, q, fa);
    if (local != null) {
      if (mounted) {
        setState(() {
          msgs.add(_m(false, local));
          busy = false;
        });
        _saveChats();
      }
      return;
    }
    final action = _actionFor(s, q);
    if (action != null) {
      await _runAction(action, fa);
      _saveChats();
      return;
    }
    // No key, no call, no fake answer. The gate is per provider:
    // a Gonka pick needs the Gonka key, a Z.ai pick the Z.ai key,
    // a custom pick its own key.
    final keyOk = s.aiProvider == 'gonka'
        ? s.gonkaReady
        : s.aiProvider == 'custom'
            ? s.customReady
            : s.aiReady;
    if (!keyOk) {
      if (mounted) {
        setState(() {
          msgs.add(_m(
              false,
              s.aiProvider == 'gonka'
                  ? s.tLang('gonkanokey', fa)
                  : s.aiProvider == 'custom'
                      ? s.tLang('customnokey', fa)
                      : s.tLang('ainokey', fa)));
          busy = false;
        });
        _saveChats();
      }
      return;
    }
    var content = q;
    if (attached != null && attached!.isNotEmpty) {
      var att = attached!;
      if (att.length > 12000) att = '[earlier lines cut]\n${att.substring(att.length - 12000)}';
      content = 'Attached ${attachLabel ?? 'log'}:\n```\n$att\n```\n\n$q';
      attached = null; // sent once; history keeps it for follow-ups
      attachLabel = null;
    }
    // A reply quotes the earlier AI message into the API
    // history only — the bubble still shows just what the
    // user typed, and local answers/actions still see the
    // typed text alone.
    if (quote != null && quote.isNotEmpty) {
      final short =
          quote.length > 500 ? '${quote.substring(0, 500)}…' : quote;
      content = 'In reply to your earlier message: "$short"\n\n$content';
    }
    final img = pendingImage;
    final imgMime = pendingImageMime;
    if (img != null) {
      // Vision attempt: the image rides as an OpenAI-style part.
      // If this model cannot see images, _chat returns the honest
      // ainovision note instead of pretending it was seen.
      history.add({
        'role': 'user',
        'content': [
          {'type': 'text', 'text': content},
          {
            'type': 'image_url',
            'image_url': {
              'url': 'data:$imgMime;base64,${base64Encode(img)}'
            }
          },
        ],
      });
      pendingImage = null;
      pendingImageName = null;
      pendingImageMime = null;
    } else {
      history.add({'role': 'user', 'content': content});
    }
    try {
      final reply = await _chat(s, history, fa: fa);
      if (!mounted) return;
      setState(() {
        msgs.add(_m(false, reply));
        history.add({'role': 'assistant', 'content': reply});
        busy = false;
      });
      _saveChats();
    } catch (e) {
      if (!mounted) return;
      // The hint depends on the real state: "connect first"
      // is wrong advice when the tunnel is already up and the
      // current server itself blocks the AI endpoint.
      final connected = s.engine.state.phase == Phase.connected ||
          s.psiphon.state.phase == PsiphonPhase.connected;
      final isNet = e is TimeoutException || e is SocketException;
      // VPN-off disaster case: the AI endpoint is filtered on the
      // bare network exactly when the user needs help most. With
      // the setting on, start Psiphon in proxy form just for this
      // answer and route the retry through its HTTP proxy.
      if (isNet && !connected && s.aiViaPsiphon) {
        if (mounted) setState(() => msgs.add(_m(false, s.tLang('aipsi', fa))));
        final ok = await _startPsiphonForAi(s);
        if (ok && mounted) {
          final httpPort = s.psiphon.state.httpPort;
          if (httpPort != null && httpPort > 0) {
            try {
              final reply = await _chat(s, history, proxyPort: httpPort, fa: fa);
              if (!mounted) return;
              setState(() {
                msgs.add(_m(false, reply));
                history.add({'role': 'assistant', 'content': reply});
                busy = false;
              });
              _saveChats();
              return;
            } catch (_) {
              // Fall through to the plain network error below.
            }
          }
        }
        if (mounted) {
          setState(() {
            msgs.add(_m(false, s.tLang('aipsifail', fa)));
            busy = false;
          });
          history.removeLast();
          _saveChats();
        }
        return;
      }
      final detail = e is TimeoutException
          ? 'timed out, try again'
          : e is SocketException
              ? (connected ? s.tLang('ainetconn', fa) : s.tLang('ainet', fa))
              : 'network error';
      setState(() {
        msgs.add(_m(false, '${s.tLang('aifailed', fa)}: $detail'));
        busy = false;
      });
      history.removeLast();
      _saveChats();
    }
  }

  /// Starts Psiphon in proxy form (local ports only, no VPN layer,
  /// no mode change) so one AI answer can go through it while the
  /// VPN is off. Returns true only when the tunnel reports
  /// connected. Sets [_psiStartedByAi] so dispose can stop a tunnel
  /// this chat started; a tunnel the user already had is left alone.
  bool _psiStartedByAi = false;

  Future<bool> _startPsiphonForAi(Store s) async {
    final ph = s.psiphon.state.phase;
    if (ph == PsiphonPhase.connected) return true;
    if (ph != PsiphonPhase.connecting) {
      await s.psiphon.configure(egressRegion: s.psiCountry);
      await s.psiphon.connect();
      _psiStartedByAi = true;
    }
    // Psiphon can take a while on a filtered network; the chat
    // keeps its thinking row up meanwhile.
    for (var i = 0; i < 90; i++) {
      final p = s.psiphon.state.phase;
      if (p == PsiphonPhase.connected) return true;
      if (p == PsiphonPhase.failed || p == PsiphonPhase.needsConfig || p == PsiphonPhase.idle) return false;
      await Future.delayed(const Duration(seconds: 1));
    }
    return s.psiphon.state.phase == PsiphonPhase.connected;
  }

  @override
  void dispose() {
    _saveChats();
    // A Psiphon tunnel this chat started for AI is stopped when the
    // chat closes, so it never lingers or gets restored as a
    // session the user did not ask for. Tunnels the user already
    // had, and real VPN connections, are left untouched.
    if (_psiStartedByAi) {
      final s = widget.s;
      if (s.mode != 'psiphon' &&
          s.engine.state.phase != Phase.connected &&
          s.psiphon.state.phase == PsiphonPhase.connected) {
        unawaited(s.psiphon.disconnect());
      }
    }
    super.dispose();
  }

  /// Runs a chat action for real: disconnect / mode switch /
  /// server list happen at once; connect starts through the
  /// normal Personal path (full-device VPN, traffic-proof
  /// verify) and the outcome is posted back into the chat.
  /// Verdict wait for one chat attempt: the engine's connected /
  /// failed verdict, a 60 s cap, or the user's Cancel — whichever
  /// comes first. The engine stream is broadcast, so the
  /// abandoned firstWhere subscription (when Cancel or the cap
  /// wins) is harmless. 60 s, down from 90: the test stage
  /// already filtered dead servers, so a config still unproven
  /// after a minute is not worth more waiting.
  Future<EngineState?> _awaitVerdict() async {
    return Future.any<EngineState?>([
      widget.s.engine.states.firstWhere(
        (e) => e.phase == Phase.connected || e.phase == Phase.failed,
      ),
      Future<EngineState?>.delayed(const Duration(seconds: 60)),
      () async {
        while (!_connectCancelled) {
          await Future.delayed(const Duration(milliseconds: 300));
        }
        return null;
      }(),
    ]);
  }

  /// v10.1.1: the three small shortcuts under a Connected
  /// message — check ping & traffic (a live in-chat answer),
  /// add to favorites, and the speed test page. Small and
  /// subtle, side by side, never under errors or other messages.
  Widget _connectedShortcuts(Store s, String link) {
    final fav = s.isFavorite(link);
    final btnStyle = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    const labelStyle = TextStyle(fontSize: 11);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            icon: const Icon(Icons.speed, size: 14),
            label: Text(s.t('aipingtraffic'), style: labelStyle),
            style: btnStyle,
            onPressed: () {
              final cur = s.engine.state;
              final t = cur.traffic;
              final parts = <String>[];
              final loc = cur.location;
              if (loc != null && loc.isNotEmpty) {
                parts.add(loc);
              }
              if (cur.delayMs != null) parts.add('${cur.delayMs} ms');
              parts.add('↓ ${_fmtBytes(t.downTotal)} ↑ ${_fmtBytes(t.upTotal)}');
              setState(() {
                msgs.add(_m(false,
                    parts.isEmpty ? s.t('aistatsnone') : parts.join(' · ')));
              });
              _saveChats();
            },
          ),
          TextButton.icon(
            icon: Icon(fav ? Icons.star : Icons.star_border, size: 14),
            label: Text(s.t('favorites'), style: labelStyle),
            style: btnStyle,
            onPressed: () {
              s.toggleFavorite(link);
              setState(() {
                msgs.add(_m(false, s.t(fav ? 'aifavremoved' : 'aifavadded')));
              });
              _saveChats();
            },
          ),
          TextButton.icon(
            icon: const Icon(Icons.timer, size: 14),
            label: Text(s.t('speedtest'), style: labelStyle),
            style: btnStyle,
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => SpeedTestPage(s, autoStart: true))),
          ),
        ],
      ),
    );
  }

  Future<void> _runAction(_Action a, bool fa) async {
    final s = widget.s;
    switch (a.kind) {
      case _ActionKind.disconnect:
        await s.disconnectAll();
        if (!mounted) return;
        setState(() {
          msgs.add(_m(false, s.tLang('aidisconnected', fa)));
          busy = false;
        });
      case _ActionKind.mode:
        s.mode = a.mode!;
        s.save();
        if (!mounted) return;
        setState(() {
          msgs.add(_m(false, '${s.tLang('aimodeset', fa)} ${s.tLang(a.mode!, fa)}'));
          busy = false;
        });
      case _ActionKind.find:
        if (!mounted) return;
        setState(() {
          msgs.add(_m(false, a.message!));
          busy = false;
        });
      case _ActionKind.connect:
        // "Connecting" is a loading row (like Thinking), NOT a
        // chat message: it stays up while an attempt runs and
        // vanishes when the verdict lands, leaving only the
        // final Connected/failed message in the conversation.
        // v10.1.1: the row has TWO phases now. First "testing
        // servers": the country's configs are handshake-probed
        // (like Smart/Auto does) and only the ones that answer
        // are attempted — dead configs cost no connect time.
        // Then "connecting" for the attempts themselves, up to
        // 25 servers before the honest "can't connect" error.
        // A Cancel button stops either phase at any time.
        _connectCancelled = false;
        if (mounted) {
          setState(() {
            actionProgress = a.remark;
            actionProgressTesting = false;
            actionProgressCancellable = true;
            actionProgressFa = fa;
            busy = false;
          });
        }
        // Switching while connected, or "disconnect and connect
        // to X": stop the current tunnel first. Starting a new
        // connect on top of a live session is exactly what used
        // to make the chat answer "you are already connected"
        // instead of switching.
        if (a.disconnectFirst ||
            s.engine.state.phase == Phase.connected ||
            s.psiphon.state.phase == PsiphonPhase.connected) {
          await s.disconnectAll();
        }
        if (!mounted) return;
        // Stage 1 — test. 10 probes at a time, 4 s each: fast
        // enough to cover the pool, slow enough not to flood a
        // filtered network. A probe that answers (ms > 0) is a
        // pass; UDP configs answer 9000 (unmeasurable) and are
        // kept after real pings, not dropped.
        final pool = a.candidates ??
            [if (a.link != null) ChatCand(a.link!, '', false)];
        final passed = <ChatCand>[];
        if (mounted) {
          setState(() {
            actionProgress = '0/${pool.length}';
            actionProgressTesting = true;
          });
        }
        var testedCount = 0;
        var poolIdx = 0;
        Future<void> worker() async {
          while (poolIdx < pool.length && !_connectCancelled) {
            final c = pool[poolIdx++];
            final r = await probeLink(c.link, timeout: const Duration(seconds: 4));
            testedCount++;
            if (r.ms > 0) passed.add(ChatCand(c.link, c.provider, c.stale, r.ms));
            if (mounted) {
              setState(() => actionProgress = '$testedCount/${pool.length}');
            }
          }
        }

        await Future.wait(List.generate(10, (_) => worker()));
        if (!mounted) return;
        if (_connectCancelled) {
          setState(() {
            actionProgress = null;
            actionProgressTesting = false;
            actionProgressCancellable = false;
            msgs.add(_m(false, s.tLang('aicancelled', fa)));
            busy = false;
          });
          _saveChats();
          return;
        }
        // Stage 2 — attempt only what passed, up to 25, in
        // provider order (Fast/AI first, or V2rayAG first for a
        // fast-and-strong request), fastest ping first inside a
        // provider, traffic-failed last.
        final tries = orderChatCandidates(passed, a.fastStrong).take(25).toList();
        if (tries.isEmpty) {
          setState(() {
            actionProgress = null;
            actionProgressTesting = false;
            actionProgressCancellable = false;
            msgs.add(_m(false, s.tLang('ainopass', fa)));
            busy = false;
          });
          _saveChats();
          return;
        }
        // Try candidates in order until one REALLY connects to
        // the requested country: a remark that says "US" is not
        // proof — the exit IP's country is. A server whose geo
        // lands elsewhere is dropped and the next candidate
        // runs; the retry button re-runs this same loop with
        // the failed servers pushed last.
        var triedMismatch = false;
        var failDetail = '';
        for (var t = 0; t < tries.length; t++) {
          if (_connectCancelled) break;
          final link = tries[t].link;
          final remark = _remarkOf(link);
          if (mounted) {
            setState(() {
              actionProgress = remark;
              actionProgressTesting = false;
              actionProgressFa = fa;
            });
          }
          s.connectLink(link);
          final st = await _awaitVerdict();
          if (!mounted) return;
          if (_connectCancelled) break;
          if (st == null || st.phase != Phase.connected) {
            failDetail = st?.message ?? '';
            await s.disconnectAll();
            continue;
          }
          if (a.country != null && a.country!.isNotEmpty) {
            final okGeo = await _verifyExitCountry(a.country!);
            if (!mounted) return;
            if (_connectCancelled) break;
            if (!okGeo) {
              triedMismatch = true;
              await s.disconnectAll();
              continue;
            }
          }
          final cur = s.engine.state;
          final msgIndex = msgs.length;
          setState(() {
            actionProgress = null;
            actionProgressTesting = false;
            actionProgressCancellable = false;
            // Shortcuts live under this message only, while it
            // is still the last message (see the bubble builder).
            connectedShortcutIndex = msgIndex;
            connectedShortcutLink = link;
            msgs.add(_m(
              false,
              '${s.tLang('aiconnected', fa)} ${cur.configName ?? remark}${cur.delayMs == null ? '' : ' (${cur.delayMs} ms)'}',
            ));
          });
          _saveChats();
          // Success leaves the chat for the Connected page, so
          // the user SEES the connection — after the message,
          // with a beat to read it. Failure and disconnect stay
          // in the chat, as asked.
          await Future.delayed(const Duration(milliseconds: 900));
          if (mounted) {
            Navigator.of(context).popUntil((route) => route.isFirst);
          }
          return;
        }
        if (!mounted) return;
        setState(() {
          actionProgress = null;
          actionProgressTesting = false;
          actionProgressCancellable = false;
          msgs.add(_m(
            false,
            _connectCancelled
                ? s.tLang('aicancelled', fa)
                : triedMismatch
                    ? '${s.tLang('aicountrymismatch', fa)} ${countryName(a.country!, fa)}'
                    : '${s.tLang('aiconnectfail', fa)}${failDetail.isEmpty ? '' : ' $failDetail'}',
          ));
          busy = false;
        });
        _saveChats();
      case _ActionKind.psiphon:
        // Psiphon to a country (or any region when no country
        // was named): mode + region, then the normal Psiphon
        // connect. The tunnel reports through psiphon.state,
        // not engine.states, so it is polled here — and the
        // chat reports the SETTLED result, never "check the
        // Home tab": Psiphon is slow on filtered networks, so
        // the progress row keeps updating with elapsed time
        // until the tunnel connects, fails, or stops.
        final code = a.country ?? '';
        final name = code.isEmpty ? '' : countryName(code, fa);
        final label = name.isEmpty ? 'Psiphon' : 'Psiphon $name';
        if (mounted) {
          setState(() {
            actionProgress = label;
            actionProgressFa = fa;
            busy = false;
          });
        }
        if (s.engine.state.phase == Phase.connected ||
            s.psiphon.state.phase == PsiphonPhase.connected) {
          await s.disconnectAll();
        }
        s.mode = 'psiphon';
        s.psiCountry = code;
        s.save();
        unawaited(s.connect());
        final started = DateTime.now();
        PsiphonPhase? settled;
        for (var i = 0;; i++) {
          if (!mounted) return;
          final ph = s.psiphon.state.phase;
          if (ph == PsiphonPhase.connected || ph == PsiphonPhase.failed) {
            settled = ph;
            break;
          }
          // Idle right after starting is just "not started
          // yet" (or a permission refusal, which sets the
          // error): only treat it as settled once the error is
          // set or 10s have passed without a tunnel starting.
          if (ph == PsiphonPhase.idle &&
              (s.psiphonVpnError.isNotEmpty || i >= 10)) {
            settled = ph;
            break;
          }
          if (i > 0 && i % 30 == 0 && mounted) {
            final el = DateTime.now().difference(started);
            final mm = (el.inMinutes).toString().padLeft(2, '0');
            final ss = (el.inSeconds % 60).toString().padLeft(2, '0');
            setState(() => actionProgress = '$label ($mm:$ss)');
          }
          await Future.delayed(const Duration(seconds: 1));
        }
        if (!mounted) return;
        if (settled == PsiphonPhase.connected) {
          final p = s.psiphon.state;
          setState(() {
            actionProgress = null;
            msgs.add(_m(
              false,
              '${s.tLang('aipsiconnected', fa)} $label'
              '${p.exitIp == null ? '' : ' — ${p.exitIp}'}'
              '${p.location == null ? '' : ' (${p.location})'}',
            ));
          });
          await Future.delayed(const Duration(milliseconds: 900));
          if (mounted) {
            Navigator.of(context).popUntil((route) => route.isFirst);
          }
        } else if (settled == PsiphonPhase.failed ||
            s.psiphonVpnError.isNotEmpty) {
          setState(() {
            actionProgress = null;
            msgs.add(_m(
              false,
              '${s.tLang('aiconnectfail', fa)}'
              '${s.psiphonVpnError.isEmpty ? '' : ' — ${s.psiphonVpnError}'}',
            ));
          });
        } else {
          setState(() {
            actionProgress = null;
            msgs.add(_m(false, s.tLang('aipsistopped', fa)));
          });
        }
    }
  }

  /// Waits for the background geo lookup of the current session
  /// (up to 25s) and checks the exit location against the
  /// requested country. Geo unavailable (no location at all)
  /// passes: the remark match is all the evidence there is,
  /// and a missing geo must not block every connect.
  Future<bool> _verifyExitCountry(String code) async {
    final s = widget.s;
    for (var i = 0; i < 25; i++) {
      final e = s.engine.state;
      if (e.phase != Phase.connected) return false;
      if (!e.geoLoading) break;
      await Future.delayed(const Duration(seconds: 1));
    }
    final e = s.engine.state;
    if (e.phase != Phase.connected) return false;
    final loc = e.location;
    if (loc == null || loc.isEmpty) return true;
    return geoMatches(loc, code);
  }

  /// v10.1.1: model auto-fallback. If the current model does not
  /// answer within a few seconds (timeout, network failure, empty
  /// reply, 5xx), the chat automatically tries the next model and
  /// says so in the thinking row — Z.ai models first, then Gonka,
  /// then user-added providers. The user's saved provider/model
  /// never changes: the fallback is for this answer only. Key
  /// errors (401/403/402) and quota (429) are final answers, not
  /// fallback triggers — another model on the same key would fail
  /// the same way. When every model fails on the network, the
  /// TimeoutException propagates so _send's Psiphon fallback (for
  /// a filtered network) still runs.
  Future<String> _chat(Store s, List<Map<String, dynamic>> history, {int? proxyPort, required bool fa}) async {
    final chain = _fallbackChain(s);
    if (chain.isEmpty) return s.tLang('aikeybad', fa);
    var sawNetwork = false;
    for (var i = 0; i < chain.length; i++) {
      final c = chain[i];
      if (i > 0 && mounted) {
        setState(() => modelSwitchNote = '${s.tLang('aiswitched', fa)} ${_modelLabel(c.model)}');
      }
      final r = await _chatOnce(s, history, proxyPort: proxyPort, fa: fa, base: c.base, key: c.key, model: c.model);
      if (r.answer != null) {
        if (mounted) setState(() => modelSwitchNote = null);
        return r.answer!;
      }
      if (r.network) sawNetwork = true;
    }
    if (mounted) setState(() => modelSwitchNote = null);
    if (sawNetwork) throw TimeoutException('no model answered');
    return s.tLang('aifailed', fa);
  }

  /// One model attempt: its provider base + key + model id.
  /// Z.ai's free models first, then Gonka's routed models (only
  /// with a Gonka key), then every user-added provider's models.
  /// The current pick is first; duplicates (same base + model)
  /// are skipped.
  List<({String base, String key, String model})> _fallbackChain(Store s) {
    final chain = <({String base, String key, String model})>[];
    void add(String base, String key, String model) {
      if (key.isEmpty) return;
      if (chain.any((c) => c.base == base && c.model == model)) return;
      chain.add((base: base, key: key, model: model));
    }

    final gonka = s.aiProvider == 'gonka';
    final custom = s.aiProvider == 'custom';
    final base = (gonka ? s.gonkaBase : custom ? s.customBase : s.aiBase).replaceAll(RegExp(r'/+$'), '');
    final key = gonka ? s.gonkaKey : custom ? s.customKey : s.aiKey;
    add(base, key, s.aiChatModel);
    for (final m in _freeModels) {
      add(s.aiBase.replaceAll(RegExp(r'/+$'), ''), s.aiKey, m);
    }
    for (final m in _gonkaModels) {
      add(s.gonkaBase, s.gonkaKey, m);
    }
    for (final p in s.customProviders) {
      final b = '${p['base'] ?? ''}'.replaceAll(RegExp(r'/+$'), '');
      final k = '${p['key'] ?? ''}';
      final models = p['models'];
      if (models is List) {
        for (final m in models) {
          add(b, k, '$m');
        }
      }
    }
    return chain;
  }

  /// One attempt against one model. Returns (answer, network):
  /// answer != null is final (a reply, or a key/quota/filter
  /// explanation); answer == null means "try the next model",
  /// with network telling whether the failure was on the network
  /// (timeout, socket, 5xx) or the model just gave nothing.
  Future<({String? answer, bool network})> _chatOnce(Store s, List<Map<String, dynamic>> history,
      {int? proxyPort, required bool fa, required String base, required String key, required String model}) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    // Psiphon fallback: route through its HTTP proxy instead of the
    // bare network. (SOCKS would need protocol support HttpClient
    // does not offer; Psiphon's HTTP port is the right channel.)
    if (proxyPort != null) c.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
        final req = await c.postUrl(Uri.parse('$base/chat/completions'));
        req.headers.set('Content-Type', 'application/json');
        req.headers.set('Authorization', 'Bearer $key');
        req.add(utf8.encode(jsonEncode({
          'model': model,
          'messages': [
            {'role': 'system', 'content': _systemPrompt(s, fa)},
            ...history,
          ],
          'temperature': 0.3,
          'max_tokens': 1200,
        })));
        final res = await req.close().timeout(const Duration(seconds: 15));
        final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
        if (res.statusCode == 429 && attempt == 0) {
          // Free tiers allow ~1 request/sec: a rapid second tap
          // trips 429 even though the key is fine. One retry
          // after a short pause fixes the tap-tap case; a
          // sustained 429 (shared daily quota) still reports.
          await Future.delayed(const Duration(milliseconds: 2500));
          continue;
        }
        if (res.statusCode != 200) {
          // Plain, actionable reason: a bad/expired key must read
          // as exactly that, not as a generic failure.
          var detail = '';
          try {
            final j = jsonDecode(body) as Map<String, dynamic>;
            final err = j['error'];
            if (err is Map && err['message'] != null) detail = '${err['message']}';
          } catch (_) {}
          if (detail.length > 200) detail = detail.substring(0, 200);
          final lowDetail = detail.toLowerCase();
          if (res.statusCode == 400 &&
              (lowDetail.contains('sensitive') || lowDetail.contains('unsafe'))) {
            return (answer: s.tLang('aifilter', fa), network: false);
          }
          // Vision is per-model, not per-app: if the provider
          // rejects an image part, say so honestly instead of
          // pretending the photo was seen.
          if (res.statusCode == 400 &&
              (lowDetail.contains('image') ||
                  lowDetail.contains('vision') ||
                  lowDetail.contains('multimodal'))) {
            return (answer: s.tLang('ainovision', fa), network: false);
          }
          // 5xx is a "not responding" failure: another model
          // may answer. Everything else below is final.
          if (res.statusCode >= 500) return (answer: null, network: true);
          final isGonka = base == s.gonkaBase;
          final why = switch (res.statusCode) {
            401 => s.tLang('aikeybad', fa),
            402 => isGonka
                ? s.tLang('gonkacredit', fa)
                : '${s.tLang('aifailed', fa)} (HTTP 402${detail.isEmpty ? '' : ': $detail'})',
            403 => s.tLang('aiforbidden', fa),
            429 => s.tLang('aiquota', fa),
            _ => '${s.tLang('aifailed', fa)} (HTTP ${res.statusCode}${detail.isEmpty ? '' : ': $detail'})',
          };
          return (answer: why, network: false);
        }
        final j = jsonDecode(body) as Map<String, dynamic>;
        final choices = j['choices'] as List?;
        String? text;
        if (choices != null && choices.isNotEmpty) {
          final msg = choices[0]['message'];
          if (msg is Map) text = msg['content'] as String?;
        }
        if (text == null || text.trim().isEmpty) return (answer: null, network: false);
        return (answer: _cleanReply(text.trim()), network: false);
        } on TimeoutException {
          return (answer: null, network: true);
        } on SocketException {
          return (answer: null, network: true);
        }
      }
      return (answer: null, network: false);
    } finally {
      c.close(force: true);
    }
  }

  /// The + button menu: Photos (gallery images only), Files
  /// (any file, read as text), current Logs (auto-attached).
  /// Exactly one pending attachment at a time: picking one
  /// replaces the previous, so a send never mixes two.
  Future<void> _showAttachMenu() async {
    final s = widget.s;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo),
              title: Text(s.t('aiphotos')),
              onTap: () => Navigator.pop(ctx, 'photo'),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: Text(s.t('aifiles')),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            ListTile(
              leading: const Icon(Icons.article),
              title: Text(s.t('ailogs')),
              onTap: () => Navigator.pop(ctx, 'logs'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'photo') {
      await _pickPhoto();
    } else if (choice == 'file') {
      await _pickFile();
    } else if (choice == 'logs') {
      setState(() {
        attached = s.logs.reversed.join('\n');
        attachLabel = '${s.logs.length} ${s.t('logs')}';
        pendingImage = null;
        pendingImageName = null;
        pendingImageMime = null;
      });
    }
  }

  Future<void> _pickPhoto() async {
    final s = widget.s;
    final f = await FilePicker.pickFile(type: FileType.image);
    if (f == null || !mounted) return;
    final bytes = await f.readAsBytes();
    if (bytes.length > 4 * 1024 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.t('aibigimage'))),
        );
      }
      return;
    }
    final ext = (f.name.split('.').lastOrNull ?? '').toLowerCase();
    setState(() {
      pendingImage = bytes;
      pendingImageName = f.name;
      pendingImageMime = ext == 'png' ? 'image/png' : 'image/jpeg';
      attached = null;
      attachLabel = null;
    });
  }

  Future<void> _pickFile() async {
    final s = widget.s;
    final f = await FilePicker.pickFile();
    if (f == null || !mounted) return;
    final bytes = await f.readAsBytes();
    if (bytes.length > 2 * 1024 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.t('aibigfile'))),
        );
      }
      return;
    }
    String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.t('aibadfile'))),
        );
      }
      return;
    }
    setState(() {
      attached = text;
      attachLabel = f.name;
      pendingImage = null;
      pendingImageName = null;
      pendingImageMime = null;
    });
  }

  /// Add yours: name + base URL + key, then Test & Add. The test
  /// calls the provider's own /models list with the key: only a
  /// 200 with real model IDs adds the provider, with those exact
  /// models — never a guessed model name.
  /// One user-added provider's section in the model menu: a
  /// header row (name, collapse arrow, delete ×) plus its
  /// models when expanded. The header is a disabled item so
  /// taps on it never pick a model; its buttons close the menu
  /// themselves, because an open menu cannot rebuild in place
  /// — the next open shows the new state.
  List<PopupMenuEntry<String>> _providerMenuItems(Store s, int i) {
    final name = s.customProviders[i]['name'] as String;
    final collapsed = s.collapsedProviders.contains(name);
    return [
      PopupMenuItem(
        enabled: false,
        child: Row(children: [
          Expanded(
            child: Text(name, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          IconButton(
            icon: Icon(
              collapsed ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
              size: 18,
            ),
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            onPressed: () {
              setState(() {
                if (collapsed) {
                  s.collapsedProviders.remove(name);
                } else {
                  s.collapsedProviders.add(name);
                }
                s.save();
              });
              Navigator.of(context).pop();
            },
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            onPressed: () => _confirmDeleteProvider(name),
          ),
        ]),
      ),
      if (!collapsed)
        for (final m in (s.customProviders[i]['models'] as List))
          PopupMenuItem(
            value: 'custom:$i:$m',
            child: GestureDetector(
              // Long-press deletes just this model (confirm) —
              // for dead or paid models, while the rest stay.
              // A quick tap still picks the model normally.
              onLongPress: () => _confirmDeleteModel(i, '$m'),
              child: Row(children: [
                if (s.aiProvider == 'custom' &&
                    s.customName == name &&
                    m == s.customModel)
                  const Icon(Icons.check, size: 16),
                if (s.aiProvider == 'custom' &&
                    s.customName == name &&
                    m == s.customModel)
                  const SizedBox(width: 6),
                Expanded(child: Text('$m', style: const TextStyle(fontSize: 13))),
              ]),
            ),
          ),
    ];
  }

  /// Delete a whole user-added provider (key + all its models),
  /// with confirm. After the dialog, the menu behind it closes
  /// too, so the reopened menu shows the provider gone.
  Future<void> _confirmDeleteProvider(String name) async {
    final s = widget.s;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('aidelprovider')),
        content: Text('${s.t('aidelprovider_h')}\n$name'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.t('aidelete')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final wasSelected = s.aiProvider == 'custom' && s.customName == name;
    s.customProviders.removeWhere((p) => p['name'] == name);
    s.collapsedProviders.remove(name);
    if (wasSelected) {
      s.aiProvider = 'zai';
      s.customName = '';
      s.customModel = '';
    }
    s.save();
    setState(() {});
    Navigator.of(context).pop();
  }

  /// Delete one model of a user-added provider, with confirm.
  /// If it was the last model, the provider goes with it (a
  /// provider with no models cannot be used). If it was the
  /// selected model, selection falls back to Z.ai.
  Future<void> _confirmDeleteModel(int i, String model) async {
    final s = widget.s;
    if (i < 0 || i >= s.customProviders.length) return;
    final name = s.customProviders[i]['name'] as String;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('aidelmodel')),
        content: Text('${s.t('aidelmodel_h')}\n$model'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.t('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.t('aidelete')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final models = s.customProviders[i]['models'] as List;
    models.remove(model);
    final empty = models.isEmpty;
    if (empty) {
      s.customProviders.removeAt(i);
      s.collapsedProviders.remove(name);
    }
    if (s.aiProvider == 'custom' &&
        s.customName == name &&
        (s.customModel == model || empty)) {
      s.aiProvider = 'zai';
      s.customName = '';
      s.customModel = '';
    }
    s.save();
    setState(() {});
    Navigator.of(context).pop();
  }

  Future<void> _showAddCustom() async {
    final s = widget.s;
    final nameCtl = TextEditingController();
    final baseCtl = TextEditingController();
    final keyCtl = TextEditingController();
    String? status;
    var testing = false;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          Future<void> runTest() async {
            var base = baseCtl.text.trim();
            final name = nameCtl.text.trim();
            final key = keyCtl.text.trim();
            if (name.isEmpty || base.isEmpty || key.isEmpty) {
              setD(() => status = s.t('aifillall'));
              return;
            }
            // Normalize in this order: a pasted base ending in
            // "/chat/completions/" (trailing slash) used to
            // survive the strip and break the /models test.
            base = base.replaceAll(RegExp(r'/+$'), '');
            if (base.endsWith('/chat/completions')) {
              base = base.substring(
                  0, base.length - '/chat/completions'.length);
            }
            base = base.replaceAll(RegExp(r'/+$'), '');
            setD(() {
              testing = true;
              status = null;
            });
            try {
              final c = HttpClient()
                ..connectionTimeout = const Duration(seconds: 15);
              try {
                final req = await c.getUrl(Uri.parse('$base/models'));
                req.headers.set('Authorization', 'Bearer $key');
                final res =
                    await req.close().timeout(const Duration(seconds: 20));
                final body = await res.transform(utf8.decoder).join();
                if (res.statusCode != 200) {
                  // Show the provider's own reason, not just the
                  // code: a 403 for a revoked key reads very
                  // differently from a 403 for a wrong base URL.
                  var detail = '';
                  try {
                    final j = jsonDecode(body) as Map;
                    final err = j['error'];
                    if (err is Map && err['message'] != null) {
                      detail = '${err['message']}';
                    }
                  } catch (_) {}
                  if (detail.length > 200) detail = detail.substring(0, 200);
                  setD(() {
                    testing = false;
                    status =
                        '${s.t('aitestfail')} (HTTP ${res.statusCode}${detail.isEmpty ? '' : ': $detail'})';
                  });
                  return;
                }
                final ids = <String>[];
                try {
                  final j = jsonDecode(body) as Map;
                  for (final d in (j['data'] as List? ?? [])) {
                    final id = d['id'];
                    if (id is String && id.isNotEmpty) ids.add(id);
                  }
                } catch (_) {}
                if (ids.isEmpty) {
                  setD(() {
                    testing = false;
                    status = s.t('aitestfail');
                  });
                  return;
                }
                s.customProviders.removeWhere((p) => p['name'] == name);
                s.customProviders.add({
                  'name': name,
                  'base': base,
                  'key': key,
                  'models': ids,
                });
                // A freshly added provider opens expanded, so the
                // user picks a model right away.
                s.collapsedProviders.remove(name);
                s.save();
                setD(() {
                  testing = false;
                  status = s.t('aitestok');
                });
                await Future.delayed(const Duration(milliseconds: 700));
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) setState(() {});
              } finally {
                c.close(force: true);
              }
            } catch (_) {
              setD(() {
                testing = false;
                status =
                    '${s.t('aitestfail')}: network error (if this provider is filtered, connect the VPN and try again)';
              });
            }
          }

          return AlertDialog(
            title: Text(s.t('aicustom')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtl,
                    decoration:
                        InputDecoration(labelText: s.t('aiprovider')),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: baseCtl,
                    decoration: InputDecoration(
                      labelText: s.t('aibaseurl'),
                      hintText: 'https://api.example.com/v1',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: keyCtl,
                    decoration:
                        InputDecoration(labelText: s.t('aiapikey')),
                    obscureText: true,
                  ),
                  if (status != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      status!,
                      style: TextStyle(
                        color: status == s.t('aitestok')
                            ? Colors.green
                            : Colors.red,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  if (s.customProviders.isNotEmpty) ...[
                    const Divider(height: 24),
                    for (final p in s.customProviders)
                      Row(children: [
                        Expanded(
                          child: Text(
                            p['name'] as String,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete, size: 18),
                          onPressed: () {
                            final wasSelected = s.aiProvider == 'custom' &&
                                s.customName == p['name'];
                            s.customProviders.removeWhere(
                                (x) => x['name'] == p['name']);
                            s.collapsedProviders.remove(p['name']);
                            if (wasSelected) {
                              s.aiProvider = 'zai';
                              s.customName = '';
                              s.customModel = '';
                            }
                            s.save();
                            setD(() {});
                            if (mounted) setState(() {});
                          },
                        ),
                      ]),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(s.t('cancel')),
              ),
              FilledButton(
                onPressed: testing ? null : runTest,
                child: Text(s.t('aitestadd')),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final fa = s.fa;
    // Model menu: Z.ai models, then GonkaRouter's three, in two
    // labelled groups. A pick sets both the provider and that
    // provider's model, so switching back never sends a Gonka
    // model ID to Z.ai (or vice versa). In the header, like
    // professional chats — not a chip block eating the page.
    final models = [..._freeModels];
    if (!models.contains(s.aiModelEff)) models.add(s.aiModelEff);
    final curLabel = s.aiProvider == 'gonka'
        ? _gonkaLabel(s.gonkaModel)
        : s.aiProvider == 'custom'
            ? s.customModel
            : s.aiModelEff;
    return Scaffold(
      key: _scaffoldKey,
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              // v10.1.1: back arrow at the top of the drawer,
              // back to the chat.
              ListTile(
                leading: const Icon(Icons.arrow_back),
                title: Text(s.t('aichats')),
                onTap: () => Navigator.pop(context),
              ),
              ListTile(
                leading: const Icon(Icons.add),
                title: Text(s.t('ainewchat')),
                onTap: () {
                  Navigator.pop(context);
                  _newChat();
                },
              ),
              const Divider(height: 1),
              Expanded(
                child: savedChats.isEmpty
                    ? Center(
                        child: Text(
                          s.t('aichatempty'),
                          style: const TextStyle(color: Colors.grey),
                        ),
                      )
                    : Builder(builder: (_) {
                        // Pinned chats first, then the rest —
                        // display order only; savedChats itself
                        // stays most-recent-first so reopening
                        // still resumes the last conversation.
                        final display = [
                          ...savedChats.where((c) => c.pinned),
                          ...savedChats.where((c) => !c.pinned),
                        ];
                        return ListView.builder(
                          itemCount: display.length,
                          itemBuilder: (_, i) {
                            final c = display[i];
                            return ListTile(
                              selected: c.id == currentChatId,
                              title: Text(
                                c.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                              onTap: () {
                                Navigator.pop(context);
                                _switchChat(c);
                              },
                              // v10.1.1: one ⋮ menu per chat
                              // (rename / pin / delete) instead
                              // of three icons crowding the row.
                              // Delete asks for confirmation.
                              trailing: PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert, size: 18),
                                onSelected: (v) async {
                                  if (v == 'pin') {
                                    c.pinned = !c.pinned;
                                    _saveChats();
                                    setState(() {});
                                  } else if (v == 'rename') {
                                    _renameChat(c);
                                  } else if (v == 'delete') {
                                    await _deleteChat(c.id);
                                  }
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: 'pin',
                                    child: Row(children: [
                                      Icon(
                                        c.pinned
                                            ? Icons.push_pin
                                            : Icons.push_pin_outlined,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(s.t(c.pinned ? 'aiunpin' : 'aipin')),
                                    ]),
                                  ),
                                  PopupMenuItem(
                                    value: 'rename',
                                    child: Row(children: [
                                      const Icon(Icons.edit, size: 18),
                                      const SizedBox(width: 8),
                                      Text(s.t('airename')),
                                    ]),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Row(children: [
                                      const Icon(Icons.delete, size: 18),
                                      const SizedBox(width: 8),
                                      Text(s.t('aidelete')),
                                    ]),
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                      }),
              ),
            ],
          ),
        ),
      ),
      appBar: AppBar(
        // Design 1 header: title plus a live status line (model
        // menu stays in the actions). The dot is real state: green
        // only when the current provider actually has a key.
        // v10.1.1: explicit back arrow in the top corner, next
        // to the title, back to the previous page.
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: ListenableBuilder(
          listenable: s,
          builder: (_, __) {
            final ready = s.aiProvider == 'gonka'
                ? s.gonkaReady
                : s.aiProvider == 'custom'
                    ? s.customReady
                    : s.aiReady;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [const Icon(Icons.auto_awesome, size: 20), const SizedBox(width: 8), Text(s.t('aichat'))]),
                const SizedBox(height: 2),
                Row(children: [
                  Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: ready ? Colors.greenAccent : Colors.grey)),
                  const SizedBox(width: 6),
                  Text(ready ? s.t('aionline') : s.t('aioffline'), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ]),
              ],
            );
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.history, size: 20),
            tooltip: s.t('aichats'),
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
          PopupMenuButton<String>(
            tooltip: s.t('aimodel'),
            onSelected: (m) {
              if (m == '__add__') {
                Future.microtask(_showAddCustom);
                return;
              }
              if (m.startsWith('custom:')) {
                final parts = m.split(':');
                final idx = int.tryParse(parts.length > 1 ? parts[1] : '') ?? -1;
                if (idx >= 0 && idx < s.customProviders.length) {
                  final p = s.customProviders[idx];
                  s.aiProvider = 'custom';
                  s.customName = p['name'] as String;
                  s.customModel = parts.sublist(2).join(':');
                  s.save();
                  setState(() {});
                }
                return;
              }
              if (m.startsWith('gonka:')) {
                s.aiProvider = 'gonka';
                s.gonkaModel = m.substring(6);
              } else {
                // A manual pick wins until the next remote
                // refresh re-applies its model.
                s.aiProvider = 'zai';
                s.aiModel = m;
                s.aiRemoteModel = '';
              }
              s.save();
              setState(() {});
            },
            itemBuilder: (_) => [
              const PopupMenuItem(enabled: false, child: Text('Z.ai', style: TextStyle(fontSize: 12, color: Colors.grey))),
              for (final m in models)
                PopupMenuItem(
                  value: m,
                  child: Row(children: [
                    if (s.aiProvider == 'zai' && m == s.aiModelEff) const Icon(Icons.check, size: 16),
                    if (s.aiProvider == 'zai' && m == s.aiModelEff) const SizedBox(width: 6),
                    Text(m, style: const TextStyle(fontSize: 13)),
                  ]),
                ),
              const PopupMenuItem(enabled: false, child: Text('GonkaRouter', style: TextStyle(fontSize: 12, color: Colors.grey))),
              for (final m in _gonkaModels)
                PopupMenuItem(
                  value: 'gonka:$m',
                  child: Row(children: [
                    if (s.aiProvider == 'gonka' && m == s.gonkaModel) const Icon(Icons.check, size: 16),
                    if (s.aiProvider == 'gonka' && m == s.gonkaModel) const SizedBox(width: 6),
                    Text(_gonkaLabel(m), style: const TextStyle(fontSize: 13)),
                  ]),
                ),
              // User-added providers, each with its real models
              // from Test & Add time, then Add yours at the bottom.
              // A provider header carries its own delete (×, with
              // confirm) and collapse arrow; a long-press on one
              // of its models deletes just that model (confirm).
              for (var i = 0; i < s.customProviders.length; i++)
                ..._providerMenuItems(s, i),
              PopupMenuItem(
                value: '__add__',
                child: Row(children: [
                  const Icon(Icons.add, size: 16),
                  const SizedBox(width: 6),
                  Text(s.t('aiaddmine'), style: const TextStyle(fontSize: 13)),
                ]),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                Text(curLabel, style: const TextStyle(fontSize: 13)),
                const Icon(Icons.arrow_drop_down, size: 18),
              ]),
            ),
          ),
          if (s.aiRemoteUrl.trim().isNotEmpty)
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: s.t('airefresh'),
              onPressed: busy ? null : _refreshRemote,
            ),
        ],
      ),
      // Rebuilds on Store changes (model pick, remote refresh)
      // without waiting for the next sent message.
      body: ListenableBuilder(
        listenable: s,
        builder: (_, __) => Column(children: [
          if (remoteNote != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(remoteNote!, style: const TextStyle(color: Colors.grey, fontSize: 12)),
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: msgs.length +
                  ((busy || actionProgress != null) ? 1 : 0),
              itemBuilder: (_, i) {
                if (i >= msgs.length) {
                  // A real action-connect keeps its progress row
                  // up until the verdict lands; a plain AI call
                  // shows the thinking row instead.
                  if (!busy && actionProgress != null) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(children: [
                        const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            actionProgressTesting
                                ? '${s.tLang('aitesting', actionProgressFa)} $actionProgress…'
                                : '${s.tLang('aiconnecting', actionProgressFa)} $actionProgress…',
                            style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(.6), fontSize: 13),
                          ),
                        ),
                        // Cancel: stops the test or the attempt
                        // at any time, so the user can send the
                        // next request instead of waiting it out.
                        // Only a chat connect is cancellable.
                        if (actionProgressCancellable)
                          TextButton(
                            onPressed: () => setState(() => _connectCancelled = true),
                            child: Text(s.t('cancel')),
                          ),
                      ]),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 8),
                      // v10.1.1: a model fallback announces
                      // itself here ("Thinking… (Switched to …)")
                      // so the switch is never silent.
                      Expanded(
                        child: Text(
                          modelSwitchNote == null ? s.t('aithinking') : '${s.t('aithinking')} ($modelSwitchNote)',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(.6), fontSize: 13),
                        ),
                      ),
                    ]),
                  );
                }
                final m = msgs[i];
                if (!m.user) {
                  // Design 1 (Telegram style): the AI has a
                  // profile — a sparkle avatar tinted with the
                  // theme accent — and its own bubble on the
                  // left, with the time underneath, so AI and
                  // user messages never blend. Every color here
                  // comes from the theme, so changing the app
                  // theme recolors the chat too. Direction comes
                  // from the message itself, so a Persian answer
                  // with English terms inside lays out correctly
                  // instead of scrambling.
                  final cs = Theme.of(context).colorScheme;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: cs.primary.withOpacity(.18),
                          child: Icon(Icons.auto_awesome, size: 16, color: cs.primary),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: cs.onSurface.withOpacity(.08),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Directionality(
                                  textDirection: _dirOf(m.text),
                                  child: MarkdownBody(
                                    data: m.text,
                                    selectable: true,
                                    styleSheet: MarkdownStyleSheet(
                                      p: const TextStyle(fontSize: 14),
                                    ),
                                  ),
                                ),
                              ),
                              Row(children: [
                                IconButton(
                                  icon: const Icon(Icons.copy, size: 16),
                                  tooltip: s.t('copied'),
                                  padding: const EdgeInsets.all(4),
                                  constraints: const BoxConstraints(),
                                  onPressed: () async {
                                    await Clipboard.setData(ClipboardData(text: m.text));
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text(s.t('copied')), duration: const Duration(seconds: 1)),
                                      );
                                    }
                                  },
                                ),
                                // Retry: a fresh answer (or the
                                // next server) for the same
                                // question, even on old messages.
                                IconButton(
                                  icon: const Icon(Icons.refresh, size: 16),
                                  tooltip: s.t('airetry'),
                                  padding: const EdgeInsets.all(4),
                                  constraints: const BoxConstraints(),
                                  onPressed: (busy || actionProgress != null)
                                      ? null
                                      : () => _retryAt(i),
                                ),
                                // Reply: quote this answer into
                                // the next send, so the follow-up
                                // stays on this message's topic.
                                IconButton(
                                  icon: const Icon(Icons.reply, size: 16),
                                  tooltip: s.t('aireply'),
                                  padding: const EdgeInsets.all(4),
                                  constraints: const BoxConstraints(),
                                  onPressed: () => setState(() {
                                    final t = m.text;
                                    replyQuote = t.length > 500
                                        ? '${t.substring(0, 500)}…'
                                        : t;
                                  }),
                                ),
                                if (m.time != null)
                                  Text(
                                    _fmtTime(m.time!),
                                    style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(.55)),
                                  ),
                              ]),
                              // v10.1.1: three small shortcuts
                              // under the Connected message ONLY,
                              // and only while it is still the
                              // last message — the next message
                              // (from either side) hides them.
                              if (connectedShortcutIndex == i &&
                                  i == msgs.length - 1 &&
                                  connectedShortcutLink != null)
                                _connectedShortcuts(s, connectedShortcutLink!),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }
                // Design 1 user bubble: solid accent blue, onPrimary
                // text, on the right; the time sits inside the
                // bubble's bottom, Telegram style. Only the text
                // inside takes the message's own direction.
                final cs = Theme.of(context).colorScheme;
                return Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
                        decoration: BoxDecoration(
                          color: cs.primary,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            SelectableText(
                              m.text,
                              textDirection: _dirOf(m.text),
                              style: TextStyle(fontSize: 14, color: cs.onPrimary),
                            ),
                            if (m.time != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  _fmtTime(m.time!),
                                  style: TextStyle(fontSize: 11, color: cs.onPrimary.withOpacity(.75)),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (m.attach != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.attach_file, size: 12, color: cs.onSurface.withOpacity(.55)),
                              const SizedBox(width: 4),
                              Text(m.attach!, style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(.55))),
                            ],
                          ),
                        ),
                      // Retry on user messages too: resend the
                      // same question for a fresh answer.
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 16),
                        tooltip: s.t('airetry'),
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(),
                        onPressed: (busy || actionProgress != null)
                            ? null
                            : () => _retryAt(i),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (attached != null && attached!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Chip(
                avatar: const Icon(Icons.attach_file, size: 16),
                label: Text(attachLabel ?? s.t('aiattach')),
                deleteIcon: const Icon(Icons.close, size: 16),
                onDeleted: () => setState(() {
                  attached = null;
                  attachLabel = null;
                }),
              ),
            ),
          if (pendingImage != null && pendingImageName != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Chip(
                avatar: const Icon(Icons.photo, size: 16),
                label: Text(pendingImageName!),
                deleteIcon: const Icon(Icons.close, size: 16),
                onDeleted: () => setState(() {
                  pendingImage = null;
                  pendingImageName = null;
                  pendingImageMime = null;
                }),
              ),
            ),
          // Ready questions: ONE horizontal scrollable row above
          // the composer, like every professional chat app — never
          // a multi-row block eating the conversation.
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemCount: readyQuestions.length,
              itemBuilder: (_, i) {
                final q = readyQuestions[i];
                final flag = qFlags[i];
                return ActionChip(
                  avatar: flag != null
                      ? Text(flag, style: const TextStyle(fontSize: 16))
                      : Icon(_qIcons[i], size: 16),
                  label: Text(fa ? q[1] : q[0], style: const TextStyle(fontSize: 12)),
                  onPressed: busy ? null : () => _send(fa ? q[1] : q[0]),
                );
              },
            ),
          ),
          // Reply bar: what the next message answers, with a
          // cancel ×. The quote rides in the API history only.
          if (replyQuote != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Row(children: [
                const Icon(Icons.reply, size: 16, color: Colors.grey),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${s.t('aireplying')}: ${replyQuote!.length > 80 ? '${replyQuote!.substring(0, 80)}…' : replyQuote!}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(),
                  onPressed: () => setState(() => replyQuote = null),
                ),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              // Design 1's + button: opens the attach menu —
              // Photos, Files, or the current Logs (the old
              // one-tap logs attach lives there now).
              IconButton(
                icon: const Icon(Icons.add, size: 22),
                tooltip: s.t('aiattachmenu'),
                onPressed: _showAttachMenu,
              ),
              Expanded(
                child: TextField(
                  controller: ctl,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: s.t('aiask'),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(28)),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(width: 8),
              // Design 1's circular blue send button.
              InkWell(
                onTap: busy ? null : _submit,
                customBorder: const CircleBorder(),
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: busy ? Colors.grey : Theme.of(context).colorScheme.primary,
                  ),
                  child: const Icon(Icons.send, size: 20, color: Colors.white),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  void _submit() {
    final q = ctl.text;
    ctl.clear();
    _send(q);
  }
}
