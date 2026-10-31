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
String? _countryIn(String q) {
  final low = q.toLowerCase();
  for (final e in _countries.entries) {
    if (q.contains(e.value.first)) return e.key; // the flag
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
  const _Msg(this.user, this.text, [this.attach]);
}

/// One saved conversation for the history sidebar.
class _Chat {
  final String id;
  final String title;
  final List<_Msg> msgs;
  _Chat({required this.id, required this.title, required this.msgs});
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

enum _ActionKind { find, connect, disconnect, mode }

class _Action {
  final _ActionKind kind;
  final String? link, remark, message, mode;
  const _Action(this.kind, {this.link, this.remark, this.message, this.mode});
}

/// Direct answer from measured state, no AI call: "what
/// location am I on?" must never be stitched together or
/// guessed by the model — the app knows the exit IP for sure.
String? _localAnswer(Store s, String q, bool fa) {
  final low = q.toLowerCase();
  final isWhere = RegExp(
    r'به چه لوکیشنی وصلم|به کجا وصلم|الان کجام|آیپی من چیه|لوکیشن من چیه',
  ).hasMatch(q) ||
      RegExp(r'where am i connected|what location am i|what.{0,20}my (ip|location)')
          .hasMatch(low);
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
  if (RegExp(r'قطع(ش| اتصال)? کن').hasMatch(q) ||
      RegExp(r'\bdisconnect\b').hasMatch(low)) {
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
  if (!wantsConnect && !wantsFind) return null;
  final code = _countryIn(q);
  final tested = <MapEntry<String, int>>[];
  final untested = <String>[];
  for (final b in s.buildBundles()) {
    for (final l in b.links) {
      if (code != null && !_remarkMatchesCountry(_remarkOf(l), code)) {
        continue;
      }
      final ms = s.pings[l];
      if (ms != null && ms > 0) {
        tested.add(MapEntry(l, ms));
      } else {
        untested.add(l);
      }
    }
  }
  tested.sort((a, b) => a.value.compareTo(b.value));
  if (wantsConnect) {
    final link =
        tested.isNotEmpty ? tested.first.key : (untested.isNotEmpty ? untested.first : null);
    if (link == null) {
      return _Action(_ActionKind.find, message: s.tLang('ainofound', fa));
    }
    return _Action(_ActionKind.connect, link: link, remark: _remarkOf(link));
  }
  if (tested.isEmpty && untested.isEmpty) {
    return _Action(_ActionKind.find, message: s.tLang('ainofound', fa));
  }
  final lines = <String>[];
  for (final t in tested.take(3)) {
    lines.add('• ${_remarkOf(t.key)} — ${t.value} ms');
  }
  for (final l in untested.take(3 - lines.length)) {
    lines.add('• ${_remarkOf(l)}');
  }
  return _Action(_ActionKind.find, message: '${s.tLang('aifound', fa)}\n${lines.join('\n')}');
}

/// Ready questions: the ones users actually ask first. Tapping one
/// sends it as the user's message.
/// Icons for the ready questions, in the same order: connect,
/// drop, best server, share, logs, CDN, Psiphon, tools.
const _qIcons = [Icons.link_off, Icons.wifi_off, Icons.star, Icons.share, Icons.bug_report, Icons.dns, Icons.shield, Icons.build];

const _readyQuestions = [
  ['Why won\'t it connect?', 'چرا وصل نمی‌شه؟'],
  ['Why does my connection drop?', 'چرا اتصالم قطع می‌شه؟'],
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
You are the in-app assistant for V2rayAG, an Android VPN app (Xray core + Psiphon). Answer ONLY about this app and its features, in ${fa ? 'natural, human Persian' : 'English'}. Keep answers short and practical; give steps when the user asks how.
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
  // Live "connecting" row for a real action-connect: set when the
  // action starts, cleared only when the verdict lands.
  String? actionProgress;
  bool actionProgressFa = false;
  // History sidebar: saved conversations + which one is open.
  final savedChats = <_Chat>[];
  String currentChatId = '';
  String currentTitle = '';
  final _scaffoldKey = GlobalKey<ScaffoldState>();

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
          ms.add(_Msg(xm['u'] == true, '${xm['t'] ?? ''}', xm['a'] as String?));
        }
        savedChats.add(_Chat(id: '${m['id'] ?? ''}', title: '${m['title'] ?? ''}', msgs: ms));
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
        final chat = _Chat(
          id: currentChatId,
          title: currentTitle.isEmpty ? widget.s.t('ainewchat') : currentTitle,
          msgs: snap,
        );
        final idx = savedChats.indexWhere((c) => c.id == currentChatId);
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
                'msgs': c.msgs
                    .map((m) => {
                          'u': m.user,
                          't': m.text,
                          if (m.attach != null) 'a': m.attach,
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

  void _deleteChat(String id) {
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
    final sendAttach = attachLabel ?? pendingImageName;
    if (currentTitle.isEmpty) {
      currentTitle = q.length > 30 ? '${q.substring(0, 30)}…' : q;
    }
    setState(() {
      msgs.add(_Msg(true, q, sendAttach));
      busy = true;
    });
    _saveChats();
    // Local first: direct answers and real actions never spend
    // quota and never hallucinate server facts.
    final local = _localAnswer(s, q, fa);
    if (local != null) {
      if (mounted) {
        setState(() {
          msgs.add(_Msg(false, local));
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
          msgs.add(_Msg(
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
        msgs.add(_Msg(false, reply));
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
        if (mounted) setState(() => msgs.add(_Msg(false, s.tLang('aipsi', fa))));
        final ok = await _startPsiphonForAi(s);
        if (ok && mounted) {
          final httpPort = s.psiphon.state.httpPort;
          if (httpPort != null && httpPort > 0) {
            try {
              final reply = await _chat(s, history, proxyPort: httpPort, fa: fa);
              if (!mounted) return;
              setState(() {
                msgs.add(_Msg(false, reply));
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
            msgs.add(_Msg(false, s.tLang('aipsifail', fa)));
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
        msgs.add(_Msg(false, '${s.tLang('aifailed', fa)}: $detail'));
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
  Future<void> _runAction(_Action a, bool fa) async {
    final s = widget.s;
    switch (a.kind) {
      case _ActionKind.disconnect:
        await s.disconnectAll();
        if (!mounted) return;
        setState(() {
          msgs.add(_Msg(false, s.tLang('aidisconnected', fa)));
          busy = false;
        });
      case _ActionKind.mode:
        s.mode = a.mode!;
        s.save();
        if (!mounted) return;
        setState(() {
          msgs.add(_Msg(false, '${s.tLang('aimodeset', fa)} ${s.tLang(a.mode!, fa)}'));
          busy = false;
        });
      case _ActionKind.find:
        if (!mounted) return;
        setState(() {
          msgs.add(_Msg(false, a.message!));
          busy = false;
        });
      case _ActionKind.connect:
        // A live progress row stays up until the real verdict
        // lands, so "connecting" is never just words: the row
        // only clears when the engine reports connected/failed
        // or the 90s wait expires.
        if (mounted) {
          setState(() {
            msgs.add(_Msg(false, '${s.tLang('aiconnecting', fa)} ${a.remark}…'));
            actionProgress = a.remark;
            actionProgressFa = fa;
            busy = false;
          });
        }
        s.connectLink(a.link!);
        try {
          final st = await s.engine.states
              .firstWhere(
                (e) => e.phase == Phase.connected || e.phase == Phase.failed,
              )
              .timeout(const Duration(seconds: 90));
          if (!mounted) return;
          setState(() {
            actionProgress = null;
            msgs.add(
              _Msg(
                false,
                st.phase == Phase.connected
                    ? '${s.tLang('aiconnected', fa)} ${st.configName ?? a.remark}${st.delayMs == null ? '' : ' (${st.delayMs} ms)'}'
                    : '${s.tLang('aiconnectfail', fa)} ${st.message}',
              ),
            );
          });
        } on TimeoutException {
          if (!mounted) return;
          setState(() {
            actionProgress = null;
            msgs.add(_Msg(false, s.tLang('aiconnectwait', fa)));
          });
        }
    }
  }

  Future<String> _chat(Store s, List<Map<String, dynamic>> history, {int? proxyPort, required bool fa}) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    // Psiphon fallback: route through its HTTP proxy instead of the
    // bare network. (SOCKS would need protocol support HttpClient
    // does not offer; Psiphon's HTTP port is the right channel.)
    if (proxyPort != null) c.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
    try {
      // Provider-aware routing: Gonka picks use Gonka's base/key
      // and their own model; custom picks use their own base/key/
      // model; Z.ai keeps base/key/remote-model.
      final gonka = s.aiProvider == 'gonka';
      final custom = s.aiProvider == 'custom';
      final base = (gonka
              ? s.gonkaBase
              : custom
                  ? s.customBase
                  : s.aiBase)
          .replaceAll(RegExp(r'/+$'), '');
      final key = gonka ? s.gonkaKey : custom ? s.customKey : s.aiKey;
      for (var attempt = 0; attempt < 2; attempt++) {
        final req = await c.postUrl(Uri.parse('$base/chat/completions'));
        req.headers.set('Content-Type', 'application/json');
        req.headers.set('Authorization', 'Bearer $key');
        req.add(utf8.encode(jsonEncode({
          'model': s.aiChatModel,
          'messages': [
            {'role': 'system', 'content': _systemPrompt(s, fa)},
            ...history,
          ],
          'temperature': 0.3,
          'max_tokens': 1200,
        })));
        final res = await req.close().timeout(const Duration(seconds: 60));
        final body = await res.transform(utf8.decoder).join();
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
            return s.tLang('aifilter', fa);
          }
          // Vision is per-model, not per-app: if the provider
          // rejects an image part, say so honestly instead of
          // pretending the photo was seen.
          if (res.statusCode == 400 &&
              (lowDetail.contains('image') ||
                  lowDetail.contains('vision') ||
                  lowDetail.contains('multimodal'))) {
            return s.tLang('ainovision', fa);
          }
          final why = switch (res.statusCode) {
            401 => s.tLang('aikeybad', fa),
            402 => gonka
                ? s.tLang('gonkacredit', fa)
                : '${s.tLang('aifailed', fa)} (HTTP 402${detail.isEmpty ? '' : ': $detail'})',
            403 => s.tLang('aiforbidden', fa),
            429 => s.tLang('aiquota', fa),
            >= 500 => '${s.tLang('aiserver', fa)} (HTTP ${res.statusCode})',
            _ => '${s.tLang('aifailed', fa)} (HTTP ${res.statusCode}${detail.isEmpty ? '' : ': $detail'})',
          };
          return why;
        }
        final j = jsonDecode(body) as Map<String, dynamic>;
        final choices = j['choices'] as List?;
        String? text;
        if (choices != null && choices.isNotEmpty) {
          final msg = choices[0]['message'];
          if (msg is Map) text = msg['content'] as String?;
        }
        if (text == null || text.trim().isEmpty) return s.tLang('aifailed', fa);
        return _cleanReply(text.trim());
      }
      return s.tLang('aifailed', fa);
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
                  setD(() {
                    testing = false;
                    status =
                        '${s.t('aitestfail')} (HTTP ${res.statusCode})';
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
                status = '${s.t('aitestfail')}: network error';
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
                    : ListView.builder(
                        itemCount: savedChats.length,
                        itemBuilder: (_, i) {
                          final c = savedChats[i];
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
                            trailing: IconButton(
                              icon: const Icon(Icons.delete, size: 18),
                              onPressed: () => _deleteChat(c.id),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
      appBar: AppBar(
        // Design 1 header: title plus a live status line (model
        // menu stays in the actions). The dot is real state: green
        // only when the current provider actually has a key.
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
              for (var i = 0; i < s.customProviders.length; i++) ...[
                PopupMenuItem(
                  enabled: false,
                  child: Text(
                    s.customProviders[i]['name'] as String,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                for (final m in (s.customProviders[i]['models'] as List))
                  PopupMenuItem(
                    value: 'custom:$i:$m',
                    child: Row(children: [
                      if (s.aiProvider == 'custom' &&
                          s.customName == s.customProviders[i]['name'] &&
                          m == s.customModel)
                        const Icon(Icons.check, size: 16),
                      if (s.aiProvider == 'custom' &&
                          s.customName == s.customProviders[i]['name'] &&
                          m == s.customModel)
                        const SizedBox(width: 6),
                      Text('$m', style: const TextStyle(fontSize: 13)),
                    ]),
                  ),
              ],
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
                            '${s.tLang('aiconnecting', actionProgressFa)} $actionProgress…',
                            style: const TextStyle(color: Colors.grey, fontSize: 13),
                          ),
                        ),
                      ]),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 8),
                      Text(s.t('aithinking'), style: const TextStyle(color: Colors.grey, fontSize: 13)),
                    ]),
                  );
                }
                final m = msgs[i];
                if (!m.user) {
                  // Assistant: a distinct faint card (Design 1
                  // refinement) so AI and user messages never blend,
                  // plain full-width Markdown inside — no raw **.
                  // Direction comes from the message itself, so a
                  // Persian answer with English terms inside lays
                  // out correctly instead of scrambling.
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(.06),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Directionality(
                            textDirection: _dirOf(m.text),
                            child: MarkdownBody(
                              data: m.text,
                              selectable: true,
                              styleSheet: MarkdownStyleSheet(
                                p: const TextStyle(fontSize: 14),
                              ),
                            ),
                          ),
                          Row(children: [
                            IconButton(
                              icon: const Icon(Icons.copy, size: 16),
                              tooltip: s.t('copied'),
                              onPressed: () async {
                                await Clipboard.setData(ClipboardData(text: m.text));
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(s.t('copied')), duration: const Duration(seconds: 1)),
                                  );
                                }
                              },
                            ),
                          ]),
                        ],
                      ),
                    ),
                  );
                }
                // Design 1 user bubble: solid accent blue, white
                // text — not the translucent tint it was before.
                // The bubble stays on the right; only the text
                // inside takes the message's own direction.
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
                          color: Theme.of(context).colorScheme.primary,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: SelectableText(
                          m.text,
                          textDirection: _dirOf(m.text),
                          style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onPrimary),
                        ),
                      ),
                      if (m.attach != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.attach_file, size: 12, color: Colors.grey),
                              const SizedBox(width: 4),
                              Text(m.attach!, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                            ],
                          ),
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
              itemCount: _readyQuestions.length,
              itemBuilder: (_, i) {
                final q = _readyQuestions[i];
                return ActionChip(
                  avatar: Icon(_qIcons[i], size: 16),
                  label: Text(fa ? q[1] : q[0], style: const TextStyle(fontSize: 12)),
                  onPressed: busy ? null : () => _send(fa ? q[1] : q[0]),
                );
              },
            ),
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
