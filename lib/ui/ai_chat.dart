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
  const _Msg(this.user, this.text);
}

enum _ActionKind { find, connect, disconnect, mode }

class _Action {
  final _ActionKind kind;
  final String? link, remark, message, mode;
  const _Action(this.kind, {this.link, this.remark, this.message, this.mode});
}

/// Direct answer from measured state, no AI call: "what
/// location am I on?" must never be stitched together or
/// guessed by the model — the app knows the exit IP for sure.
String? _localAnswer(Store s, String q) {
  final low = q.toLowerCase();
  final isWhere = RegExp(
    r'به چه لوکیشنی وصلم|به کجا وصلم|الان کجام|آیپی من چیه|لوکیشن من چیه',
  ).hasMatch(q) ||
      RegExp(r'where am i connected|what location am i|what.{0,20}my (ip|location)')
          .hasMatch(low);
  if (!isWhere) return null;
  final e = s.engine.state;
  if (e.phase == Phase.connected) {
    return '${s.t('aiwhere')} ${e.configName ?? ''}'
        '${e.exitIp == null ? '' : ' — ${e.exitIp}'}'
        '${e.location == null ? '' : ' (${e.location})'}'
        '${e.delayMs == null ? '' : ' — ${e.delayMs} ms'}';
  }
  final p = s.psiphon.state;
  if (p.phase == PsiphonPhase.connected) {
    return '${s.t('aiwhere')} Psiphon'
        '${p.exitIp == null ? '' : ' — ${p.exitIp}'}'
        '${p.location == null ? '' : ' (${p.location})'}';
  }
  return s.t('ainotconn');
}

/// Real actions the chat can DO (not just explain). Strict
/// patterns only: a question ("why does it disconnect?") must
/// never trigger an action. Connect/find use measured pings
/// first and untested provider configs second; find never
/// connects; connect only runs on an explicit connect request.
_Action? _actionFor(Store s, String q) {
  final low = q.toLowerCase();
  final isQuestion = q.contains('؟') ||
      q.contains('?') ||
      RegExp(r'\b(why|how|what is|چیست|چیه|چرا|چطور)\b').hasMatch(low);
  if (!isQuestion &&
      (RegExp(r'قطع(ش| اتصال)? کن').hasMatch(q) ||
          RegExp(r'\bdisconnect\b').hasMatch(low))) {
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
  if (!isQuestion && hasModeVerb) {
    for (final e in modeWords.entries) {
      if (e.value.any(low.contains)) {
        return _Action(_ActionKind.mode, mode: e.key);
      }
    }
  }
  final wantsConnect = q.contains('وصل کن') ||
      q.contains('متصلم کن') ||
      q.contains('وصلش کن') ||
      RegExp(r'\bconnect\b').hasMatch(low);
  final wantsFind = q.contains('پیدا کن') ||
      q.contains('می‌خوام') ||
      q.contains('میخوام') ||
      RegExp(r'\bfind\b').hasMatch(low);
  if (!wantsConnect && !wantsFind) return null;
  if (isQuestion) return null;
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
      return _Action(_ActionKind.find, message: s.t('ainofound'));
    }
    return _Action(_ActionKind.connect, link: link, remark: _remarkOf(link));
  }
  if (tested.isEmpty && untested.isEmpty) {
    return _Action(_ActionKind.find, message: s.t('ainofound'));
  }
  final lines = <String>[];
  for (final t in tested.take(3)) {
    lines.add('• ${_remarkOf(t.key)} — ${t.value} ms');
  }
  for (final l in untested.take(3 - lines.length)) {
    lines.add('• ${_remarkOf(l)}');
  }
  return _Action(_ActionKind.find, message: '${s.t('aifound')}\n${lines.join('\n')}');
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

String _systemPrompt(Store s) => '''
You are the in-app assistant for V2rayAG, an Android VPN app (Xray core + Psiphon). Answer ONLY about this app and its features, in ${s.fa ? 'natural, human Persian' : 'English'}. Keep answers short and practical; give steps when the user asks how.
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
  final history = <Map<String, String>>[];
  final ctl = TextEditingController();
  String? attached;
  String? attachLabel;
  String? remoteNote;
  bool busy = false, autoSent = false;

  @override
  void initState() {
    super.initState();
    attached = widget.attachment;
    attachLabel = widget.attachmentLabel;
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

  Future<void> _send(String text) async {
    final q = text.trim();
    if (q.isEmpty || busy) return;
    final s = widget.s;
    setState(() {
      msgs.add(_Msg(true, q));
      busy = true;
    });
    // Local first: direct answers and real actions never spend
    // quota and never hallucinate server facts.
    final local = _localAnswer(s, q);
    if (local != null) {
      if (mounted) {
        setState(() {
          msgs.add(_Msg(false, local));
          busy = false;
        });
      }
      return;
    }
    final action = _actionFor(s, q);
    if (action != null) {
      await _runAction(action);
      return;
    }
    // No key, no call, no fake answer. The gate is per provider:
    // a Gonka pick needs the Gonka key, a Z.ai pick the Z.ai key.
    final keyOk = s.aiProvider == 'gonka' ? s.gonkaReady : s.aiReady;
    if (!keyOk) {
      if (mounted) {
        setState(() {
          msgs.add(_Msg(false, s.aiProvider == 'gonka' ? s.t('gonkanokey') : s.t('ainokey')));
          busy = false;
        });
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
    history.add({'role': 'user', 'content': content});
    try {
      final reply = await _chat(s, history);
      if (!mounted) return;
      setState(() {
        msgs.add(_Msg(false, reply));
        history.add({'role': 'assistant', 'content': reply});
        busy = false;
      });
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
        if (mounted) setState(() => msgs.add(_Msg(false, s.t('aipsi'))));
        final ok = await _startPsiphonForAi(s);
        if (ok && mounted) {
          final httpPort = s.psiphon.state.httpPort;
          if (httpPort != null && httpPort > 0) {
            try {
              final reply = await _chat(s, history, proxyPort: httpPort);
              if (!mounted) return;
              setState(() {
                msgs.add(_Msg(false, reply));
                history.add({'role': 'assistant', 'content': reply});
                busy = false;
              });
              return;
            } catch (_) {
              // Fall through to the plain network error below.
            }
          }
        }
        if (mounted) {
          setState(() {
            msgs.add(_Msg(false, s.t('aipsifail')));
            busy = false;
          });
          history.removeLast();
        }
        return;
      }
      final detail = e is TimeoutException
          ? 'timed out, try again'
          : e is SocketException
              ? (connected ? s.t('ainetconn') : s.t('ainet'))
              : 'network error';
      setState(() {
        msgs.add(_Msg(false, '${s.t('aifailed')}: $detail'));
        busy = false;
      });
      history.removeLast();
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
  Future<void> _runAction(_Action a) async {
    final s = widget.s;
    switch (a.kind) {
      case _ActionKind.disconnect:
        await s.disconnectAll();
        if (!mounted) return;
        setState(() {
          msgs.add(_Msg(false, s.t('aidisconnected')));
          busy = false;
        });
      case _ActionKind.mode:
        s.mode = a.mode!;
        s.save();
        if (!mounted) return;
        setState(() {
          msgs.add(_Msg(false, '${s.t('aimodeset')} ${s.t(a.mode!)}'));
          busy = false;
        });
      case _ActionKind.find:
        if (!mounted) return;
        setState(() {
          msgs.add(_Msg(false, a.message!));
          busy = false;
        });
      case _ActionKind.connect:
        if (mounted) {
          setState(() {
            msgs.add(_Msg(false, '${s.t('aiconnecting')} ${a.remark}…'));
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
            msgs.add(
              _Msg(
                false,
                st.phase == Phase.connected
                    ? '${s.t('aiconnected')} ${st.configName ?? a.remark}${st.delayMs == null ? '' : ' (${st.delayMs} ms)'}'
                    : '${s.t('aiconnectfail')} ${st.message}',
              ),
            );
          });
        } on TimeoutException {
          if (!mounted) return;
          setState(() {
            msgs.add(_Msg(false, s.t('aiconnectwait')));
          });
        }
    }
  }

  Future<String> _chat(Store s, List<Map<String, String>> history, {int? proxyPort}) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    // Psiphon fallback: route through its HTTP proxy instead of the
    // bare network. (SOCKS would need protocol support HttpClient
    // does not offer; Psiphon's HTTP port is the right channel.)
    if (proxyPort != null) c.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
    try {
      // Provider-aware routing: Gonka picks use Gonka's base/key
      // and their own model; Z.ai keeps base/key/remote-model.
      final gonka = s.aiProvider == 'gonka';
      final base = (gonka ? s.gonkaBase : s.aiBase).replaceAll(RegExp(r'/+$'), '');
      for (var attempt = 0; attempt < 2; attempt++) {
        final req = await c.postUrl(Uri.parse('$base/chat/completions'));
        req.headers.set('Content-Type', 'application/json');
        req.headers.set('Authorization', 'Bearer ${gonka ? s.gonkaKey : s.aiKey}');
        req.add(utf8.encode(jsonEncode({
          'model': s.aiChatModel,
          'messages': [
            {'role': 'system', 'content': _systemPrompt(s)},
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
            return s.t('aifilter');
          }
          final why = switch (res.statusCode) {
            401 => s.t('aikeybad'),
            402 => s.t('gonkacredit'),
            403 => s.t('aiforbidden'),
            429 => s.t('aiquota'),
            >= 500 => '${s.t('aiserver')} (HTTP ${res.statusCode})',
            _ => '${s.t('aifailed')} (HTTP ${res.statusCode}${detail.isEmpty ? '' : ': $detail'})',
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
        if (text == null || text.trim().isEmpty) return s.t('aifailed');
        return _cleanReply(text.trim());
      }
      return s.t('aifailed');
    } finally {
      c.close(force: true);
    }
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
    final curLabel = s.aiProvider == 'gonka' ? _gonkaLabel(s.gonkaModel) : s.aiModelEff;
    return Scaffold(
      appBar: AppBar(
        // Design 1 header: title plus a live status line (model
        // menu stays in the actions). The dot is real state: green
        // only when the current provider actually has a key.
        title: ListenableBuilder(
          listenable: s,
          builder: (_, __) {
            final ready = s.aiProvider == 'gonka' ? s.gonkaReady : s.aiReady;
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
          PopupMenuButton<String>(
            tooltip: s.t('aimodel'),
            onSelected: (m) {
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
              itemCount: msgs.length + (busy ? 1 : 0),
              itemBuilder: (_, i) {
                if (i >= msgs.length) {
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
                  // Assistant: plain full-width Markdown, like
                  // professional chats — no card, no raw ** marks.
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        MarkdownBody(
                          data: m.text,
                          selectable: true,
                          styleSheet: MarkdownStyleSheet(
                            p: const TextStyle(fontSize: 14),
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
                  );
                }
                // Design 1 user bubble: solid accent blue, white
                // text — not the translucent tint it was before.
                return Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: SelectableText(m.text, style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onPrimary)),
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
              // Design 1's + button: attaches the current full log
              // as context for the next question — the same
              // attachment the Logs page's AI button sends, without
              // the trip there. Never decorative: it always does
              // exactly this.
              IconButton(
                icon: const Icon(Icons.add, size: 22),
                tooltip: s.t('aiattachlogs'),
                onPressed: () => setState(() {
                  attached = s.logs.reversed.join('\n');
                  attachLabel = '${s.logs.length} ${s.t('logs')}';
                }),
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
