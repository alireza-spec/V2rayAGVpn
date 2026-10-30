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

import '../app/store.dart';
import '../engine/pool_engine.dart';
import '../engine/psiphon_engine.dart';

class _Msg {
  final bool user;
  final String text;
  const _Msg(this.user, this.text);
}

/// Ready questions: the ones users actually ask first. Tapping one
/// sends it as the user's message.
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
  } else if (s.psiphon.state.phase == PsiphonPhase.connected) {
    b.write('Connected via Psiphon. ');
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

/// Free models offered in chat. glm-4.7-flash is the newer one,
/// so it is the default; the picker also shows the effective
/// model when a remote config set something else.
const _freeModels = ['glm-4.7-flash', 'glm-4.5-flash'];

class _AiChatState extends State<AiChatPage> {
  final msgs = <_Msg>[];
  final history = <Map<String, String>>[];
  final ctl = TextEditingController();
  String? attached;
  String? remoteNote;
  bool busy = false, autoSent = false;

  @override
  void initState() {
    super.initState();
    attached = widget.attachment;
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
    // No key, no call, no fake answer.
    if (!s.aiReady) {
      if (mounted) {
        setState(() {
          msgs.add(_Msg(false, s.t('ainokey')));
          busy = false;
        });
      }
      return;
    }
    var content = q;
    if (attached != null && attached!.isNotEmpty) {
      var att = attached!;
      if (att.length > 12000) att = '[earlier lines cut]\n${att.substring(att.length - 12000)}';
      content = 'Attached ${widget.attachmentLabel ?? 'log'}:\n```\n$att\n```\n\n$q';
      attached = null; // sent once; history keeps it for follow-ups
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
      final detail = e is TimeoutException
          ? 'timed out, try again'
          : e is SocketException
              ? s.t('ainet')
              : 'network error';
      setState(() {
        msgs.add(_Msg(false, '${s.t('aifailed')}: $detail'));
        busy = false;
      });
      history.removeLast();
    }
  }

  Future<String> _chat(Store s, List<Map<String, String>> history) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final base = s.aiBase.replaceAll(RegExp(r'/+$'), '');
      final req = await c.postUrl(Uri.parse('$base/chat/completions'));
      req.headers.set('Content-Type', 'application/json');
      req.headers.set('Authorization', 'Bearer ${s.aiKey}');
      req.add(utf8.encode(jsonEncode({
        'model': s.aiModelEff,
        'messages': [
          {'role': 'system', 'content': _systemPrompt(s)},
          ...history,
        ],
        'temperature': 0.3,
        'max_tokens': 1200,
      })));
      final res = await req.close().timeout(const Duration(seconds: 60));
      final body = await res.transform(utf8.decoder).join();
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
        final why = switch (res.statusCode) {
          401 => s.t('aikeybad'),
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
      return text.trim();
    } finally {
      c.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final fa = s.fa;
    // Model chips: the two free models, plus the effective model
    // when a remote config set something else.
    final models = [..._freeModels];
    if (!models.contains(s.aiModelEff)) models.add(s.aiModelEff);
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [const Icon(Icons.auto_awesome, size: 20), const SizedBox(width: 8), Text(s.t('aichat'))]),
        actions: [
          if (s.aiRemoteUrl.trim().isNotEmpty)
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: s.t('airefresh'),
              onPressed: busy ? null : _refreshRemote,
            ),
        ],
      ),
      body: Column(children: [
        if (remoteNote != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(remoteNote!, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.t('aimodel'), style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                children: [
                  for (final m in models)
                    ChoiceChip(
                      label: Text(m, style: const TextStyle(fontSize: 12)),
                      selected: m == s.aiModelEff,
                      onSelected: busy
                          ? null
                          : (_) {
                              // A manual pick wins until the next
                              // remote refresh re-applies its model.
                              s.aiModel = m;
                              s.aiRemoteModel = '';
                              s.save();
                            },
                    ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: msgs.length + (busy ? 1 : 0),
            itemBuilder: (_, i) {
              if (i >= msgs.length) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Row(children: [SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: 8), Text('…')]),
                );
              }
              final m = msgs[i];
              return Align(
                alignment: m.user ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
                  decoration: BoxDecoration(
                    color: m.user ? Theme.of(context).colorScheme.primary.withOpacity(.25) : Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Theme.of(context).colorScheme.onSurface.withOpacity(.1)),
                  ),
                  child: SelectableText(m.text, style: const TextStyle(fontSize: 14)),
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
              label: Text(widget.attachmentLabel ?? s.t('aiattach')),
              deleteIcon: const Icon(Icons.close, size: 16),
              onDeleted: () => setState(() => attached = null),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(s.t('aiquestions'), style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final q in _readyQuestions)
                ActionChip(
                  label: Text(fa ? q[1] : q[0], style: const TextStyle(fontSize: 12)),
                  onPressed: busy ? null : () => _send(fa ? q[1] : q[0]),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: ctl,
                minLines: 1,
                maxLines: 4,
                decoration: InputDecoration(hintText: s.t('aiask'), border: const OutlineInputBorder()),
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: busy ? null : _submit,
              child: const Icon(Icons.send, size: 18),
            ),
          ]),
        ),
      ]),
    );
  }

  void _submit() {
    final q = ctl.text;
    ctl.clear();
    _send(q);
  }
}
