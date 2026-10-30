import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

import '../app/store.dart';
import '../engine/native.dart';
import '../engine/pool_engine.dart';
import '../engine/psiphon_engine.dart';
import '../engine/scanner.dart';
import 'ai_chat.dart';
import 'logo.dart';
import 'net_tools.dart';
import 'share_vpn.dart';
import 'speed_page.dart';

const kTelegram = 'https://t.me/V2rayAG';

String fmtBytes(num b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var i = 0;
  var v = b.toDouble();
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
}

String fmtDur(int s) {
  String t(int n) => n.toString().padLeft(2, '0');
  return '${t(s ~/ 3600)}:${t(s % 3600 ~/ 60)}:${t(s % 60)}';
}

void toast(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));

Future<String> clip() async => (await Clipboard.getData('text/plain'))?.text ?? '';

void copyText(BuildContext c, Store s, String t) {
  Clipboard.setData(ClipboardData(text: t));
  toast(c, s.t('copied'));
}

Map<String, String> linkInfo(String l) {
  try {
    if (l.startsWith('vmess://')) {
      final j = jsonDecode(utf8.decode(base64.decode(base64.normalize(l.substring(8))))) as Map<String, dynamic>;
      return {'p': 'vmess', 'n': '${j['ps'] ?? ''}', 'h': '${j['add']}:${j['port']}'};
    }
    final u = Uri.parse(l);
    return {'p': u.scheme, 'n': Uri.decodeComponent(u.fragment), 'h': '${u.host}:${u.port}'};
  } catch (_) {
    return {'p': '?', 'n': l, 'h': ''};
  }
}

Widget infoRow(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(k, style: const TextStyle(color: Colors.grey)),
        const SizedBox(width: 16),
        Flexible(child: Text(v, textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w700))),
      ]),
    );

/// v1.0.7: info row whose value is a widget — used for the geo
/// rows, where a small spinner replaces "-" while the background
/// location lookup is still running (detecting, not empty).
Widget infoRowW(String k, Widget v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(k, style: const TextStyle(color: Colors.grey)),
        const SizedBox(width: 16),
        Flexible(child: Align(alignment: AlignmentDirectional.centerEnd, child: v)),
      ]),
    );

/// v1.0.7: the value side of a geo row: spinner while detecting,
/// "-" only after the lookup finished (or was never needed), the
/// real value once it lands.
Widget geoValue({required bool loading, required String? value}) {
  if (value != null && value.isNotEmpty) return Text(value, textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w700));
  if (loading) {
    return const Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
    ]);
  }
  return const Text('-', textAlign: TextAlign.end, style: TextStyle(fontWeight: FontWeight.w700));
}

Future<String?> ask(BuildContext c, Store s, String title, {String initial = ''}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: c,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: TextField(controller: ctl, autofocus: true, minLines: 1, maxLines: 4),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(s.t('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: Text(s.t('ok'))),
      ],
    ),
  );
}

// ---------------------------------------------------------------- shell

class Shell extends StatelessWidget {
  const Shell(this.s, {super.key});
  final Store s;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: s,
        builder: (ctx, _) {
          final pages = [HomePage(s), ServersPage(s), SubsPage(s), ToolsPage(s), SettingsPage(s)];
          const names = ['home', 'servers', 'subs', 'tools', 'settings'];
          const icons = [Icons.power_settings_new, Icons.dns_outlined, Icons.link, Icons.build_outlined, Icons.tune];
          return Scaffold(
            appBar: AppBar(
              title: Row(children: [
                ClipRRect(borderRadius: BorderRadius.circular(9), child: Image.memory(base64Decode(kLogoB64), width: 32, height: 32)),
                const SizedBox(width: 10),
                const Text('V2rayAG', style: TextStyle(fontWeight: FontWeight.w800)),
              ]),
              actions: [
                IconButton(
                  icon: Icon(Icons.speed, color: (s.engine.state.phase == Phase.connected || s.psiphon.state.phase == PsiphonPhase.connected) ? null : Colors.grey),
                  onPressed: (s.engine.state.phase == Phase.connected || s.psiphon.state.phase == PsiphonPhase.connected)
                      ? () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => SpeedTestPage(s, autoStart: true)))
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.star_border),
                  onPressed: () {
                    if (s.favorites.isEmpty) {
                      toast(ctx, s.t('nofav'));
                    } else {
                      Navigator.push(ctx, MaterialPageRoute(builder: (_) => FavoritesPage(s)));
                    }
                  },
                ),
                IconButton(icon: const Icon(Icons.article_outlined), onPressed: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => LogsPage(s)))),
                IconButton(
                  icon: Icon(Icons.auto_awesome, color: Theme.of(ctx).colorScheme.primary),
                  tooltip: s.t('aichat'),
                  onPressed: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => AiChatPage(s))),
                ),
              ],
            ),
            drawer: Drawer(
              child: SafeArea(
                child: ListenableBuilder(
                  listenable: s,
                  builder: (_, __) {
                    // v1.0.6: the drawer status covers every path, not
                    // just the core engine — Psiphon, Psiphon+V2ray
                    // combo, and core modes (Smart/Auto/CDN/Personal).
                    // The store notifies on Psiphon state changes, so
                    // this rebuilds when the tunnel connects, while the
                    // inner stream still feeds live engine values.
                    final psi = s.psiphon.state;
                    final psiOn = psi.phase == PsiphonPhase.connected && !s.psiComboBusy;
                    final combo = s.psiComboActive;
                    return StreamBuilder<EngineState>(
                      stream: s.engine.states,
                      initialData: s.engine.state,
                      builder: (_, snap) {
                        final e = snap.data!;
                        final engOn = e.phase == Phase.connected;
                        final on = combo || psiOn || engOn;
                        final busy = !on && (e.phase == Phase.searching || e.phase == Phase.testing || e.phase == Phase.connecting || e.phase == Phase.switching || psi.phase == PsiphonPhase.connecting || s.psiComboBusy);
                    final accent = Theme.of(ctx).colorScheme.primary;
                    final color = on ? const Color(0xFF2BD67B) : (busy ? const Color(0xFF4DA3FF) : Colors.grey);
                    Widget item(IconData ic, String label, VoidCallback f, {int? tab}) => ListTile(
                          dense: true,
                          selected: tab != null && s.tab == tab,
                          selectedTileColor: accent.withOpacity(.14),
                          leading: Icon(ic),
                          title: Text(label),
                          onTap: () {
                            Navigator.pop(ctx);
                            f();
                          },
                        );
                    Widget head(String t) => Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 2), child: Text(t, style: const TextStyle(fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: Colors.grey)));
                    return Column(children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                        decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [accent.withOpacity(.3), Colors.transparent])),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            ClipRRect(borderRadius: BorderRadius.circular(14), child: Image.memory(base64Decode(kLogoB64), width: 52, height: 52)),
                            const SizedBox(width: 12),
                            const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('V2rayAG', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 21)),
                              Text('SECURE · FAST · RELIABLE · PROXY', style: TextStyle(fontSize: 9, letterSpacing: 1)),
                            ]),
                          ]),
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(color: Theme.of(ctx).colorScheme.onSurface.withOpacity(.08), borderRadius: BorderRadius.circular(14), border: Border.all(color: color.withOpacity(.6))),
                            child: Row(children: [
                              Icon(on ? Icons.verified_user_rounded : (busy ? Icons.sync : Icons.shield_outlined), color: color, size: 22),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(on ? (combo ? s.t('drawer_combo') : (psiOn ? s.t('drawer_psi') : s.t('connected'))) : (busy ? (psi.phase == PsiphonPhase.connecting || s.psiComboBusy ? psi.message : e.message) : s.t('notconn')), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12, letterSpacing: 1)),
                                  if (on) Text(combo || engOn ? '${e.configName ?? ''}   ${fmtDur(e.traffic.durationSec)}' : '${psi.exitIp ?? ''}   ${psi.connectedAt == null ? '00:00:00' : fmtDur(DateTime.now().difference(psi.connectedAt!).inSeconds)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                                  if (on && ((combo || engOn) ? (e.location ?? '').isNotEmpty : (psi.location ?? '').isNotEmpty)) Text(combo || engOn ? e.location! : psi.location!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                ]),
                              ),
                            ]),
                          ),
                        ]),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            icon: Icon(on || busy ? Icons.power_off : Icons.power_settings_new),
                            label: Text(on || busy ? s.t('disconnect') : s.t('connect')),
                            onPressed: () {
                              Navigator.pop(ctx);
                              if (on || busy) {
                                s.disconnectAll();
                              } else {
                                s.go(0);
                                s.connect();
                              }
                            },
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView(padding: EdgeInsets.zero, children: [
                          head(s.t('navigate')),
                          item(Icons.power_settings_new, s.t('home'), () => s.go(0), tab: 0),
                          item(Icons.dns_outlined, s.t('servers'), () => s.go(1), tab: 1),
                          item(Icons.link, s.t('subs'), () => s.go(2), tab: 2),
                          item(Icons.build_outlined, s.t('tools'), () => s.go(3), tab: 3),
                          item(Icons.tune, s.t('settings'), () => s.go(4), tab: 4),
                          head(s.t('shortcuts')),
                          item(Icons.radar, s.t('scanner'), () => s.go(3)),
                          item(Icons.shield_moon_outlined, s.t('psisettings'), () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => PsiphonSetupPage(s)))),
                          item(Icons.apps, s.t('apps'), () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => AppsPage(s)))),
                          item(Icons.article_outlined, s.t('logs'), () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => LogsPage(s)))),
                          head(s.t('quick')),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Wrap(spacing: 8, runSpacing: 4, children: [
                              ChoiceChip(label: const Text('English'), selected: !s.fa, onSelected: (_) {
                                s.lang = 'en';
                                s.save();
                              }),
                              ChoiceChip(label: const Text('فارسی'), selected: s.fa, onSelected: (_) {
                                s.lang = 'fa';
                                s.save();
                              }),
                              ChoiceChip(label: Text(s.t('vpnmode')), selected: s.connType == 'vpn', onSelected: (_) {
                                s.connType = 'vpn';
                                s.save();
                              }),
                              ChoiceChip(label: Text(s.t('proxymode')), selected: s.connType == 'proxy', onSelected: (_) {
                                s.connType = 'proxy';
                                s.save();
                              }),
                            ]),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                            child: Row(children: [
                              for (final t in Store.themes)
                                GestureDetector(
                                  onTap: () {
                                    s.theme = t;
                                    s.save();
                                  },
                                  child: Container(
                                    margin: const EdgeInsetsDirectional.only(end: 10),
                                    width: 30,
                                    height: 30,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Color({'forest': 0xFF101C1A, 'black': 0xFF000000, 'graphite': 0xFF3A3D41, 'midnight': 0xFF16264A, 'light': 0xFFF3F6F6}[t]!),
                                      border: Border.all(color: s.theme == t ? accent : Colors.white24, width: s.theme == t ? 3 : 1),
                                    ),
                                  ),
                                ),
                            ]),
                          ),
                          head(s.t('aboutsec')),
                          item(Icons.send_outlined, 'Telegram @V2rayAG', () async {
                            if (!await Native.openUrl(kTelegram) && ctx.mounted) copyText(ctx, s, kTelegram);
                          }),
                          item(Icons.system_update_alt, s.t('update'), () async {
                            final m = await s.checkUpdate();
                            if (ctx.mounted) toast(ctx, m);
                          }),
                          item(Icons.share_outlined, s.t('share'), () => copyText(ctx, s, 'V2rayAG  $kTelegram')),
                          item(Icons.info_outline, s.t('about'), () => showDialog<void>(
                                context: ctx,
                                builder: (_) => AlertDialog(
                                  title: const Text('V2rayAG'),
                                  content: Text('${s.t('dev')}\nTelegram: @V2rayAG\nBuild $kBuildNum'),
                                  actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.t('ok')))],
                                ),
                              )),
                        ]),
                      ),
                      Padding(padding: const EdgeInsets.all(10), child: Text('V2rayAG  build $kBuildNum', style: const TextStyle(fontSize: 11, color: Colors.grey))),
                    ]);
                      },
                    );
                  },
                ),
              ),
            ),
            body: AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: KeyedSubtree(key: ValueKey(s.tab), child: pages[s.tab])),
            bottomNavigationBar: NavigationBar(
              selectedIndex: s.tab,
              onDestinationSelected: s.go,
              destinations: [for (var k = 0; k < 5; k++) NavigationDestination(icon: Icon(icons[k]), label: s.t(names[k]))],
            ),
          );
        },
      );
}

// ---------------------------------------------------------------- home

class HomePage extends StatelessWidget {
  const HomePage(this.s, {super.key});
  final Store s;

  Widget _modes(BuildContext ctx, bool locked) {
    final icons = {'smart': Icons.auto_awesome, 'auto': Icons.bolt, 'cdn': Icons.cloud_outlined, 'personal': Icons.person_outline, 'psiphon': Icons.shield_moon_outlined};
    final accent = Theme.of(ctx).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: Theme.of(ctx).cardColor, borderRadius: BorderRadius.circular(18), border: Border.all(color: Theme.of(ctx).colorScheme.onSurface.withOpacity(.12))),
      child: Row(children: [
        for (final m in ['smart', 'auto', 'cdn', 'personal', 'psiphon'])
          Expanded(
            child: GestureDetector(
              onTap: locked
                  ? null
                  : () {
                      // v1.0.6: the CDN chip switches to the CDN tab
                      // like every other mode (tap chip, tap power to
                      // connect). Its fields live on the CDN setup
                      // page, reached from the tab's setup button.
                      // CDN is core fronting, not Psiphon, so its
                      // settings do not belong in Psiphon settings.
                      if (m == 'psiphon') {
                        // v45: tapping Psiphon only switches to Psiphon mode.
                        // It must NOT start connecting by itself: like every
                        // other section, the connection starts on the user's
                        // tap of the power button. Sponsor/Channel IDs live
                        // only in Psiphon settings (sidebar).
                        s.mode = 'psiphon';
                        s.single = null;
                        s.save();
                        return;
                      }
                      s.mode = m;
                      s.single = null;
                      s.save();
                    },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: s.mode == m ? accent.withOpacity(.2) : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: s.mode == m ? accent : Colors.transparent),
                ),
                child: Column(children: [
                  Icon(icons[m], size: 20, color: s.mode == m ? accent : Colors.grey),
                  const SizedBox(height: 2),
                  Text(s.t(m), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: s.mode == m ? accent : Colors.grey)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _steps(int step, Color color) {
    const names = ['step1', 'step2', 'step3', 'step4'];
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 0; i < 4; i++) ...[
          Column(children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 12,
              height: 12,
              decoration: BoxDecoration(shape: BoxShape.circle, color: i <= step ? color : Colors.white12, boxShadow: i == step ? [BoxShadow(color: color.withOpacity(.6), blurRadius: 10)] : null),
            ),
            const SizedBox(height: 4),
            Text(s.t(names[i]), style: TextStyle(fontSize: 11, color: i <= step ? color : Colors.grey)),
          ]),
          if (i < 3) Container(width: 28, height: 2, margin: const EdgeInsets.only(bottom: 16, left: 6, right: 6), color: i < step ? color : Colors.white12),
        ],
      ]),
    );
  }

  Widget _speed(BuildContext ctx, IconData ic, Color c, String label, String speed, String total) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Icon(ic, color: c, size: 18), const SizedBox(width: 6), Text(label, style: const TextStyle(color: Colors.grey))]),
              const SizedBox(height: 6),
              Text(speed, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              Text(total, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => s.mode == 'psiphon' ? _buildPsiphon(context) : _buildEngine(context);

  Widget _buildEngine(BuildContext context) => StreamBuilder<EngineState>(
        stream: s.engine.states,
        initialData: s.engine.state,
        builder: (ctx, snap) {
          final e = snap.data!;
          final on = e.phase == Phase.connected;
          final busy = e.phase == Phase.searching || e.phase == Phase.testing || e.phase == Phase.connecting || e.phase == Phase.switching;
          final st = on ? 2 : (busy ? 1 : 0);
          final color = on ? const Color(0xFF2BD67B) : (busy ? const Color(0xFF4DA3FF) : Theme.of(ctx).colorScheme.primary);
          final sub = e.sub;
          const grey = TextStyle(color: Colors.grey, fontSize: 13);
          final label = on ? s.t('connected') : (busy ? e.message.toUpperCase() : s.t('notconn'));
          return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
            _modes(ctx, on || busy),
            const SizedBox(height: 10),
            Text(s.t('${s.mode}_d'), textAlign: TextAlign.center, style: grey),
            if (s.mode == 'cdn') Text(s.cdnUsingProviderFallback ? '${s.t('cdnfromproviders')}: ${s.cdnCandidateCount}' : (s.cdnLinks.isNotEmpty ? '${s.t('cdnconfigs')}: ${s.cdnLinks.length}' : '${s.t('pool')}: ${s.pool.length}'), textAlign: TextAlign.center, style: grey.copyWith(fontSize: 12)),
            if (s.mode == 'cdn') Center(child: TextButton.icon(icon: const Icon(Icons.settings_outlined, size: 16), label: Text(s.t('cdnsetup'), style: const TextStyle(fontSize: 12)), onPressed: on || busy ? null : () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => CdnPage(s))))),
            if (s.mode == 'auto' || s.mode == 'smart') ProvidersPanel(s: s, locked: on || busy),
            Center(
              child: PowerButton(
                color: color,
                state: st,
                onTap: () {
                  if (on || busy) {
                    s.disconnectAll();
                  } else if (s.mode == 'personal' && s.mySubs.isEmpty && s.personalLinks.isEmpty && s.single == null) {
                    toast(ctx, s.t('addfirst'));
                  } else {
                    s.connect();
                  }
                },
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Text(label, key: ValueKey(label), textAlign: TextAlign.center, style: TextStyle(color: color, fontWeight: FontWeight.w800, letterSpacing: 2, fontSize: 15)),
            ),
            if (busy) _steps(e.step, color),
            if (e.phase == Phase.failed) Padding(padding: const EdgeInsets.only(top: 8), child: Text(e.message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent))),
            if (s.mode == 'personal' && s.activeSub != null && e.phase == Phase.failed) TryNextSubButton(s: s, current: s.activeSub!),
            if (busy) Center(child: TextButton(onPressed: s.disconnectAll, child: Text(s.t('cancel')))),
            if (on) ...[
              const SizedBox(height: 6),
              Text(fmtDur(e.traffic.durationSec), textAlign: TextAlign.center, style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w300, letterSpacing: 2)),
              const SizedBox(height: 10),
              Row(children: [
                _speed(ctx, Icons.arrow_downward_rounded, const Color(0xFF2BD67B), s.t('down'), '${fmtBytes(e.traffic.downSpeed)}/s', fmtBytes(e.traffic.downTotal)),
                _speed(ctx, Icons.arrow_upward_rounded, const Color(0xFF5AA2FF), s.t('up'), '${fmtBytes(e.traffic.upSpeed)}/s', fmtBytes(e.traffic.upTotal)),
              ]),
              Stack(children: [
                Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(children: [
                    infoRow(s.t('server'), e.configName ?? '-'),
                    infoRowW(s.t('ip'), geoValue(loading: e.geoLoading, value: e.exitIp)),
                    infoRowW(s.t('loc'), geoValue(loading: e.geoLoading, value: (e.location ?? '').isEmpty ? null : e.location)),
                    infoRow(s.t('ping'), e.delayMs == null ? '-' : '${e.delayMs} ms'),
                    if (s.connType == 'vpn') infoRow(s.t('tun'), e.tunOk ? s.t('active') : s.t('missing')),
                    if (e.proxyInfo != null) infoRow(s.t('proxyinfo'), e.proxyInfo!),
                  ]),
                ),
              ),
                if (s.curLink != null)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: IconButton(
                      icon: Icon(s.isFavorite(s.curLink!) ? Icons.star : Icons.star_border, size: 20),
                      onPressed: () => s.toggleFavorite(s.curLink!),
                    ),
                  ),
              ]),
              Row(children: [
                OutlinedButton.icon(icon: const Icon(Icons.speed), label: Text(s.t('speedtest')), onPressed: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => SpeedTestPage(s, autoStart: true)))),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy, size: 18),
                  label: Text(s.t('copyaddr')),
                  onPressed: e.exitIp == null || e.exitIp!.isEmpty ? null : () => copyText(ctx, s, e.exitIp!),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(s.speedResult, style: const TextStyle(fontWeight: FontWeight.w800))),
              ]),
              if (sub != null && sub.url.isNotEmpty) SubCard(s, sub),
              Center(child: FilledButton.tonal(onPressed: s.disconnectAll, child: Text(s.t('disconnect')))),
            ],
          ]);
        },
      );

  Widget _buildPsiphon(BuildContext context) => StreamBuilder<PsiphonState>(
        stream: s.psiphon.states,
        initialData: s.psiphon.state,
        builder: (ctx, snap) {
          final e = snap.data!;
          final on = e.phase == PsiphonPhase.connected && !s.psiComboBusy;
          final busy = e.phase == PsiphonPhase.connecting || s.psiComboBusy;
          final st = on ? 2 : (busy ? 1 : 0);
          final color = on ? const Color(0xFF2BD67B) : (busy ? const Color(0xFF4DA3FF) : Theme.of(ctx).colorScheme.primary);
          const grey = TextStyle(color: Colors.grey, fontSize: 13);
          final label = on ? s.t('connected') : (busy ? (s.psiComboBusy ? s.t('connecting') : e.message.toUpperCase()) : s.t('notconn'));
          final flag = flagOf(e.region);
          final locShown = (e.location ?? '').isEmpty ? '-' : (flag.isEmpty ? e.location! : '$flag ${e.location!}');
          return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
            _modes(ctx, on || busy),
            // v45: the Psiphon page stays uncluttered: every explanation
            // lives behind this info button, on this page only.
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: IconButton(
                icon: const Icon(Icons.info_outline),
                tooltip: s.t('psiphon'),
                onPressed: () => showPsiphonInfo(ctx, s),
              ),
            ),
            if (s.psiphonVpnActive)
              Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(s.t('psivpn_on'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.w700, fontSize: 13))),
            if (s.psiComboActive)
              Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(s.t('psi_combo_on'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.w700, fontSize: 13))),
            if (s.psiphonVpnError.isNotEmpty)
              Padding(padding: const EdgeInsets.only(bottom: 4, left: 16, right: 16), child: Text(s.psiphonVpnError, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent, fontSize: 12))),
            Center(
              child: PowerButton(
                color: color,
                state: st,
                onTap: () {
                  if (on || busy) {
                    // Must go through disconnectAll: in whole-device mode
                    // the plugin core (VPN layer) has to stop too, not
                    // just the Psiphon tunnel.
                    s.disconnectAll();
                  } else {
                    s.connect();
                  }
                },
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Text(label, key: ValueKey(label), textAlign: TextAlign.center, style: TextStyle(color: color, fontWeight: FontWeight.w800, letterSpacing: 2, fontSize: 15)),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${s.t('psi_attempts_total')}: #${s.psiphonAttempts}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, fontSize: 13)),
            ),
            if (e.phase == PsiphonPhase.needsConfig || e.phase == PsiphonPhase.failed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(e.message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent)),
              ),
            if (busy) ...[
              Center(child: TextButton(onPressed: s.disconnectAll, child: Text(s.t('cancel')))),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Text(s.t('psiphon_hint'), textAlign: TextAlign.center, style: grey)),
              Center(child: TextButton(onPressed: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => LogsPage(s))), child: Text(s.t('logs')))),
              Center(child: TextButton(onPressed: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => PsiphonSetupPage(s))), child: Text(s.t('psisettings')))),
            ],
            if (e.phase == PsiphonPhase.failed)
              Center(child: Row(mainAxisSize: MainAxisSize.min, children: [
                TextButton(onPressed: () => s.connect(), child: Text(s.t('retry'))),
                TextButton(onPressed: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => LogsPage(s))), child: Text(s.t('logs'))),
              ])),
            if (on) ...[
              const SizedBox(height: 6),
              Text(e.connectedAt == null ? '00:00:00' : fmtDur(DateTime.now().difference(e.connectedAt!).inSeconds), textAlign: TextAlign.center, style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w300, letterSpacing: 2)),
              const SizedBox(height: 10),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(children: [
                    infoRow(s.t('conntype'), s.t('psiphon')),
                    infoRowW(s.t('ip'), geoValue(loading: e.geoLoading, value: e.exitIp)),
                    infoRowW(s.t('loc'), geoValue(loading: e.geoLoading, value: (e.location ?? '').isEmpty ? null : locShown)),
                    infoRow(s.t('ping'), e.pingMs == null ? '-' : '${e.pingMs} ms'),
                    infoRow(s.t('down'), '${fmtBytes(e.downSpeed)}/s'),
                    infoRow(s.t('up'), '${fmtBytes(e.upSpeed)}/s'),
                    infoRow(s.t('total'), '${fmtBytes(e.downTotal + e.upTotal)}'),
                    infoRow(s.t('proxyinfo'), 'HTTP 127.0.0.1:${e.httpPort ?? '-'}  SOCKS5 127.0.0.1:${e.socksPort ?? '-'}'),
                  ]),
                ),
              ),
              // v45: the ping note and the proxy warning moved into the
              // info dialog; the page keeps only status and controls.
              // v36: Psiphon is a local proxy, so Telegram and other apps need
              // its proxy address entered in their own proxy settings. Show
              // the live addresses with copy buttons instead of leaving the
              // user to guess them from the info card.
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.t('psi_proxy_use'), style: const TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    infoRow('SOCKS5', '127.0.0.1:${e.socksPort ?? '-'}'),
                    infoRow('HTTP', '127.0.0.1:${e.httpPort ?? '-'}'),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(icon: const Icon(Icons.copy, size: 16), label: Text(s.t('psi_proxy_copy')), onPressed: () => copyText(ctx, s, 'SOCKS5 127.0.0.1:${e.socksPort ?? ''}')),
                  ]),
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                OutlinedButton.icon(icon: const Icon(Icons.speed), label: Text(s.t('speedtest')), onPressed: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => SpeedTestPage(s, autoStart: true)))),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy, size: 18),
                  label: Text(s.t('copyaddr')),
                  onPressed: e.exitIp == null || e.exitIp!.isEmpty ? null : () => copyText(ctx, s, e.exitIp!),
                ),
              ]),
            ],
          ]);
        },
      );
}

/// Flag emoji for a 2-letter ISO country code, '' when unknown.
String flagOf(String? cc) {
  if (cc == null || cc.length != 2) return '';
  final up = cc.toUpperCase();
  if (!RegExp(r'^[A-Z]{2}$').hasMatch(up)) return '';
  return String.fromCharCodes(up.runes.map((c) => 0x1F1E6 + c - 65));
}

/// v45: Psiphon egress countries offered in settings, in English
/// alphabetical order. The codes are what Psiphon's EgressRegion takes.
const psiCountries = {
  'AT': 'Austria',
  'BR': 'Brazil',
  'CA': 'Canada',
  'CZ': 'Czech Republic',
  'FR': 'France',
  'DE': 'Germany',
  'IN': 'India',
  'IT': 'Italy',
  'JP': 'Japan',
  'NL': 'Netherlands',
  'PL': 'Poland',
  'RO': 'Romania',
  'SG': 'Singapore',
  'ES': 'Spain',
  'SE': 'Sweden',
  'CH': 'Switzerland',
  'TR': 'Turkey',
  'GB': 'United Kingdom',
  'US': 'United States',
};

/// v45: every Psiphon explanation lives here, behind the info button
/// on the Psiphon page only, so the page itself stays uncluttered.
void showPsiphonInfo(BuildContext ctx, Store s) {
  showDialog(
    context: ctx,
    builder: (_) => AlertDialog(
      title: Text(s.t('psiphon')),
      content: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.t('psiphon_d')),
          const SizedBox(height: 12),
          Text(s.t('psivpn_h')),
          const SizedBox(height: 12),
          Text(s.t('psi_proxy_warn')),
          const SizedBox(height: 12),
          Text(s.t('psi_proxy_how')),
          const SizedBox(height: 12),
          Text(s.t('ping_h')),
          const SizedBox(height: 12),
          Text(s.t('psiphon_hint')),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.t('close')))],
    ),
  );
}

class ProvidersPanel extends StatelessWidget {
  const ProvidersPanel({super.key, required this.s, required this.locked});
  final Store s;
  final bool locked;

  String _ago(DateTime? d, String never) {
    if (d == null) return never;
    final m = DateTime.now().difference(d).inMinutes;
    if (m < 1) return 'now';
    if (m < 60) return '${m}m';
    if (m < 1440) return '${m ~/ 60}h';
    return '${m ~/ 1440}d';
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final open = s.providersExpanded;
    final onCount = s.providerOrder.where((id) => s.providerEnabled[id] == true).length;
    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: open ? 14 : 4),
      decoration: BoxDecoration(border: Border.all(color: Theme.of(context).colorScheme.onSurface.withOpacity(.12)), borderRadius: BorderRadius.circular(18), color: Theme.of(context).cardColor),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            s.providersExpanded = !s.providersExpanded;
            s.save();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.t('providers'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  Text('$onCount/${s.providerOrder.length} ${s.t('enabledcount')}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ]),
              ),
              AnimatedRotation(turns: open ? .5 : 0, duration: const Duration(milliseconds: 200), child: const Icon(Icons.keyboard_arrow_down)),
            ]),
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 200),
          crossFadeState: open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SizedBox(height: 2),
            Text(s.t('providers_h'), style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              TextButton.icon(onPressed: locked ? null : () => s.refreshEnabledProviders(force: true), icon: const Icon(Icons.refresh, size: 16), label: Text(s.t('updateselected'), style: const TextStyle(fontSize: 12))),
              TextButton.icon(onPressed: locked ? null : () => s.refreshAllProviders(force: true), icon: const Icon(Icons.cloud_sync_outlined, size: 16), label: Text(s.t('updateall'), style: const TextStyle(fontSize: 12))),
              TextButton.icon(
                onPressed: locked
                    ? null
                    : () => s.selectAllProviders(!(s.providerOrder.isNotEmpty && s.providerOrder.every((id) => s.providerEnabled[id] == true))),
                icon: const Icon(Icons.select_all, size: 16),
                label: Text((s.providerOrder.isNotEmpty && s.providerOrder.every((id) => s.providerEnabled[id] == true)) ? s.t('deselectall') : s.t('selectall'), style: const TextStyle(fontSize: 12)),
              ),
            ]),
            for (var i = 0; i < s.providerOrder.length; i++) _row(context, accent, i),
          ]),
        ),
      ]),
    );
  }

  Widget _row(BuildContext context, Color accent, int i) {
    final id = s.providerOrder[i];
    final p = s.providerById(id);
    final on = s.providerEnabled[id] == true;
    final count = s.providerConfigCount(id);
    final busy = s.providerStatus[id] == 'loading';
    final updated = (p.id == 'unlimited' && s.unlimitedEmbedded.isNotEmpty)
        ? 'Embedded'
        : (p.id == 'fast'
            ? (s.providerLastRefresh['fast'] == null ? s.t('noneyet') : _ago(DateTime.fromMillisecondsSinceEpoch(s.providerLastRefresh['fast']! * 1000), s.t('noneyet')))
            : _ago(s.providerLastUpdated(id), s.t('noneyet')));
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: on ? accent.withOpacity(.08) : Colors.transparent, borderRadius: BorderRadius.circular(12), border: Border.all(color: on ? accent.withOpacity(.4) : Theme.of(context).colorScheme.onSurface.withOpacity(.12))),
      child: Row(children: [
        Checkbox(value: on, onChanged: locked ? null : (_) => s.toggleProvider(id)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${i + 1}. ${p.name}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            Text('$count ${s.t('configs')}   ·   ${s.t('lastupdate')} $updated${p.id == 'fast' ? '   ·   ${s.t('fastlimit')}' : ''}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
          ]),
        ),
        if (busy)
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        else
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: locked ? null : () => s.refreshProvider(p, force: true),
          ),
        IconButton(padding: EdgeInsets.zero, constraints: const BoxConstraints(), icon: const Icon(Icons.keyboard_arrow_up, size: 20), onPressed: locked || i == 0 ? null : () => s.moveProvider(i, i - 1)),
        IconButton(padding: EdgeInsets.zero, constraints: const BoxConstraints(), icon: const Icon(Icons.keyboard_arrow_down, size: 20), onPressed: locked || i == s.providerOrder.length - 1 ? null : () => s.moveProvider(i, i + 1)),
      ]),
    );
  }
}

class SpeedTestRow extends StatefulWidget {
  const SpeedTestRow({super.key, required this.run, required this.label});
  final Future<String> Function() run;
  final String label;
  @override
  State<SpeedTestRow> createState() => _SpeedTestRowState();
}

class _SpeedTestRowState extends State<SpeedTestRow> {
  bool busy = false;
  String result = '';

  @override
  Widget build(BuildContext context) => Row(children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.speed),
          label: Text(busy ? '...' : widget.label),
          onPressed: busy
              ? null
              : () async {
                  setState(() => busy = true);
                  final r = await widget.run();
                  if (mounted) setState(() {
                    busy = false;
                    result = r;
                  });
                },
        ),
        const SizedBox(width: 12),
        Text(result, style: const TextStyle(fontWeight: FontWeight.w800)),
      ]);
}

class PsiphonSetupPage extends StatefulWidget {
  const PsiphonSetupPage(this.s, {super.key});
  final Store s;
  @override
  State<PsiphonSetupPage> createState() => _PsiSetupState();
}

class _PsiSetupState extends State<PsiphonSetupPage> {
  // v46: no Sponsor/Channel fields any more; the tunnel always uses
  // the built-in public bootstrap (or the PSIPHON_JSON build secret).
  late String mode = widget.s.psiMode;
  late String country = widget.s.psiCountry;
  late final comboLinks = TextEditingController(text: widget.s.psiComboLinks);
  late bool comboUseApp = widget.s.psiComboUseApp;
  late bool proxyCustom = widget.s.psiProxyCustom;
  late final proxyIp = TextEditingController(text: widget.s.psiProxyIp);
  late final proxyPort = TextEditingController(text: widget.s.psiProxyPort);

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    InputDecoration d(String l) => InputDecoration(labelText: l, border: const OutlineInputBorder());
    return Scaffold(
      appBar: AppBar(title: Text(s.t('psisetup'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(s.t('psisetup_h')))),
        const SizedBox(height: 14),
        // Section 1: mode. The combo box and the custom-proxy fields
        // only appear when their own option is selected, never before.
        Card(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.all(8), child: Text(s.t('psi_mode'), style: const TextStyle(fontWeight: FontWeight.w800))),
              RadioListTile<String>(
                title: Text(s.t('psi_mode_vpn')),
                subtitle: Text(s.t('psivpn_h')),
                value: 'vpn',
                groupValue: mode,
                onChanged: (v) {
                  if (v != null) setState(() => mode = v);
                },
              ),
              RadioListTile<String>(
                title: Text(s.t('psi_mode_proxy')),
                subtitle: Text(s.t('psi_mode_proxy_h')),
                value: 'proxy',
                groupValue: mode,
                onChanged: (v) {
                  if (v != null) setState(() => mode = v);
                },
              ),
              RadioListTile<String>(
                title: Text(s.t('psi_mode_combo')),
                subtitle: Text(s.t('psi_combo_h')),
                value: 'combo',
                groupValue: mode,
                onChanged: (v) {
                  if (v != null) setState(() => mode = v);
                },
              ),
              if (mode == 'proxy') ...[
                const Divider(),
                RadioListTile<bool>(
                  title: Text(s.t('psi_proxy_local')),
                  value: false,
                  groupValue: proxyCustom,
                  onChanged: (v) {
                    if (v != null) setState(() => proxyCustom = v);
                  },
                ),
                RadioListTile<bool>(
                  title: Text(s.t('psi_proxy_custom')),
                  subtitle: Text(s.t('psi_proxy_custom_h')),
                  value: true,
                  groupValue: proxyCustom,
                  onChanged: (v) {
                    if (v != null) setState(() => proxyCustom = v);
                  },
                ),
                if (proxyCustom) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: TextField(controller: proxyIp, decoration: d(s.t('psi_proxy_ip'))),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: TextField(controller: proxyPort, decoration: d(s.t('psi_proxy_port')), keyboardType: TextInputType.number),
                  ),
                ],
              ],
              if (mode == 'combo') ...[
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: TextField(
                    controller: comboLinks,
                    decoration: d(s.t('psi_combo_links')),
                    minLines: 4,
                    maxLines: 10,
                    enabled: !comboUseApp,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(s.t('psi_combo_links_h'), style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ),
                CheckboxListTile(
                  title: Text(s.t('psi_combo_useapp')),
                  subtitle: Text(s.t('psi_combo_useapp_h')),
                  value: comboUseApp,
                  onChanged: (v) {
                    if (v != null) setState(() => comboUseApp = v);
                  },
                ),
              ],
            ]),
          ),
        ),
        const SizedBox(height: 14),
        // Section 2: egress country (v45). '' = all regions (default);
        // a code makes Psiphon only try servers in that country.
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.t('psi_country'), style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              DropdownButton<String>(
                value: (country.isEmpty || psiCountries.containsKey(country)) ? country : '',
                isExpanded: true,
                items: [
                  DropdownMenuItem(value: '', child: Text('🌍 ${s.t('all_regions')}')),
                  for (final e in psiCountries.entries) DropdownMenuItem(value: e.key, child: Text('${flagOf(e.key)} ${e.value}')),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => country = v);
                },
              ),
              const SizedBox(height: 8),
              Text(s.t('psi_country_h'), style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ]),
          ),
        ),
        // v46: the email/GitHub support buttons are gone with the ID fields.
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            onPressed: () {
              s.psiMode = mode;
              s.psiCountry = country;
              s.psiComboLinks = comboLinks.text;
              s.psiComboUseApp = comboUseApp;
              s.psiProxyCustom = proxyCustom;
              s.psiProxyIp = proxyIp.text.trim();
              s.psiProxyPort = proxyPort.text.trim();
              s.save();
              s.mode = 'psiphon';
              s.single = null;
              s.save();
              Navigator.pop(context);
              s.connect();
            },
            child: Padding(padding: const EdgeInsets.all(14), child: Text(s.t('save'))),
          ),
        ),
      ),
    );
  }
}

class TryNextSubButton extends StatefulWidget {
  const TryNextSubButton({super.key, required this.s, required this.current});
  final Store s;
  final String current;
  @override
  State<TryNextSubButton> createState() => _TryNextState();
}

class _TryNextState extends State<TryNextSubButton> {
  bool _busy = false, _none = false;

  @override
  void didUpdateWidget(TryNextSubButton old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current) {
      _busy = false;
      _none = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    if (_none) {
      return Padding(padding: const EdgeInsets.only(top: 10), child: Text(s.t('nomoresubs'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.orangeAccent, fontSize: 13)));
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Center(
        child: FilledButton.tonalIcon(
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.skip_next),
          label: Text(s.t('trynext')),
          onPressed: _busy
              ? null
              : () {
                  final next = s.nextPersonalSub(widget.current);
                  if (next == null) {
                    setState(() => _none = true);
                    return;
                  }
                  setState(() => _busy = true);
                  s.connectSub(next);
                },
        ),
      ),
    );
  }
}

class SubCard extends StatelessWidget {
  const SubCard(this.s, this.i, {super.key});
  final Store s;
  final SubInfo i;

  @override
  Widget build(BuildContext context) {
    if (!i.known) return Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(s.t('nousage'))));
    final left = i.timeLeft;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          infoRow(s.t('total'), i.total == 0 ? s.t('unl') : fmtBytes(i.total)),
          infoRow(s.t('remain'), i.remaining == null ? s.t('unl') : fmtBytes(i.remaining!)),
          if (i.total != 0) Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: LinearProgressIndicator(value: (i.used / i.total).clamp(0.0, 1.0), minHeight: 6)),
          infoRow(s.t('expires'), i.expire == 0 ? s.t('never') : DateTime.fromMillisecondsSinceEpoch(i.expire * 1000).toLocal().toString().split(' ').first),
          infoRow(s.t('left'), left == null ? s.t('unl') : '${left.inDays} d ${left.inHours % 24} h'),
        ]),
      ),
    );
  }
}

/// state: 0 disconnected, 1 connecting, 2 connected
class PowerButton extends StatefulWidget {
  const PowerButton({super.key, required this.color, required this.state, required this.onTap});
  final Color color;
  final int state;
  final VoidCallback onTap;
  @override
  State<PowerButton> createState() => _PBState();
}

class _PBState extends State<PowerButton> with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  Widget _icon(double v) {
    switch (widget.state) {
      case 2:
        return const Icon(Icons.verified_user_rounded, key: ValueKey(2), size: 84, color: Colors.white);
      case 1:
        return Transform.scale(key: const ValueKey(1), scale: 1 + 0.08 * math.sin(v * 6.2832 * 2), child: const Icon(Icons.public, size: 82, color: Colors.white));
      default:
        return const Icon(Icons.power_settings_new_rounded, key: ValueKey(0), size: 80, color: Colors.white70);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.state;
    final col = widget.color;
    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: 280,
        height: 280,
        child: AnimatedBuilder(
          animation: c,
          builder: (_, __) => CustomPaint(
            painter: _Rings(c.value, col, st),
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                width: 176,
                height: 176,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: st == 2
                      ? const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF3BE88C), Color(0xFF0E9F5F)])
                      : RadialGradient(colors: [col.withOpacity(.24), col.withOpacity(.06)]),
                  border: Border.all(color: col.withOpacity(st == 2 ? 0 : .8), width: 3),
                  boxShadow: [BoxShadow(color: col.withOpacity(st == 0 ? .25 : .5), blurRadius: st == 0 ? 24 : 48, spreadRadius: st == 2 ? 6 : 0)],
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 350),
                  transitionBuilder: (w, a) => ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: w)),
                  child: _icon(c.value),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Rings extends CustomPainter {
  _Rings(this.v, this.color, this.state);
  final double v;
  final Color color;
  final int state;

  @override
  void paint(Canvas canvas, Size size) {
    final ctr = size.center(Offset.zero);
    final line = Paint()..style = PaintingStyle.stroke;
    if (state == 0) {
      canvas.drawCircle(ctr, 104 + 4 * math.sin(v * 6.2832), line..strokeWidth = 1.5..color = color.withOpacity(.35));
    } else if (state == 1) {
      final rect = Rect.fromCircle(center: ctr, radius: 112);
      canvas.drawCircle(ctr, 112, Paint()..shader = SweepGradient(colors: [color.withOpacity(0), color.withOpacity(.5)], transform: GradientRotation(v * 6.2832)).createShader(rect));
      canvas.drawCircle(ctr, 112, line..strokeWidth = 1.5..color = color.withOpacity(.5));
      for (var k = 0; k < 3; k++) {
        final ang = v * 6.2832 * (1 + k * .5) + k * 2.1;
        canvas.drawCircle(ctr + Offset((124.0 + k * 4) * math.cos(ang), (124.0 + k * 4) * math.sin(ang)), 5.0 - k, Paint()..color = color);
      }
      final t = (v * 1.5) % 1;
      canvas.drawCircle(ctr, 100 + t * 36, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = color.withOpacity((1 - t) * .5));
    } else {
      for (var i = 0; i < 3; i++) {
        final t = (v + i / 3) % 1;
        canvas.drawCircle(ctr, 92 + t * 46, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = color.withOpacity((1 - t) * .45));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _Rings o) => true;
}

// ---------------------------------------------------------------- servers

Widget selectable(Store s, BuildContext ctx, bool selected, Widget child) {
  final accent = Theme.of(ctx).colorScheme.primary;
  final connected = s.phase == Phase.connected;
  final busy = s.phase == Phase.searching || s.phase == Phase.testing || s.phase == Phase.connecting || s.phase == Phase.switching;
  final c = !selected ? Theme.of(ctx).colorScheme.onSurface.withOpacity(.12) : (connected ? const Color(0xFF2BD67B) : (busy ? (s.pulse ? const Color(0xFF4DA3FF) : const Color(0x664DA3FF)) : accent));
  return AnimatedContainer(
    duration: const Duration(milliseconds: 450),
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    decoration: BoxDecoration(
      color: Theme.of(ctx).cardColor,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: c, width: selected ? 2 : 1),
      boxShadow: selected && (connected || busy) ? [BoxShadow(color: c.withOpacity(.4), blurRadius: 14)] : null,
    ),
    child: child,
  );
}

Widget pingText(int? p) => Text(
      p == null ? '' : (p < 0 ? 'timeout' : (p == 9000 ? 'UDP' : '$p ms')),
      style: TextStyle(fontWeight: FontWeight.w700, color: p == null ? null : (p < 0 ? Colors.redAccent : (p < 300 ? const Color(0xFF2BD67B) : (p < 800 ? Colors.amber : Colors.orange)))),
    );

// A ping only proves the endpoint answers TCP/TLS; it never proves the
// account still works. A config that failed a real connect (core
// rejected it, or it carried no traffic) shows that failure instead of
// a green ping, so an expired config can never look healthy again.
Widget pingOrFailed(Store s, String l) => s.trafficFailed.contains(l)
    ? Text(s.t('trafficfailed'), style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.redAccent, fontSize: 12))
    : pingText(s.pings[l]);

Future<bool> confirm(BuildContext c, Store s, String title) async =>
    (await showDialog<bool>(
      context: c,
      builder: (_) => AlertDialog(
        title: Text(title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(s.t('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(s.t('ok'))),
        ],
      ),
    )) ??
    false;

Widget cfgTile(BuildContext ctx, Store s, String l, {String? sub}) {
  final inf = linkInfo(l);
  final used = s.single == l && s.mode == 'personal';
  return selectable(
    s,
    ctx,
    used,
    ListTile(
      key: ValueKey('${sub ?? ''}|$l'),
      dense: true,
      leading: sub == null
          ? Checkbox(
              value: s.sel.contains(l),
              onChanged: (v) {
                v == true ? s.sel.add(l) : s.sel.remove(l);
                s.refresh();
              },
            )
          : null,
      title: Text(inf['n']!.isEmpty ? inf['h']! : inf['n']!, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${inf['p']}   ${inf['h']}${used ? '   •   ${s.t('inuse')}' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        pingOrFailed(s, l),
        IconButton(
          icon: Icon(s.isFavorite(l) ? Icons.star : Icons.star_border, size: 20),
          tooltip: s.t('favorites'),
          onPressed: () => s.toggleFavorite(l),
        ),
        IconButton(
          icon: const Icon(Icons.speed, size: 20),
          tooltip: s.t('test'),
          onPressed: () => s.testPings([l]),
        ),
        IconButton(icon: const Icon(Icons.play_circle_outline), onPressed: () => s.connectLink(l)),
        PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'copy') copyText(ctx, s, l);
            if (v == 'del') {
              if (s.deleteConfirm && !await confirm(ctx, s, s.t('delete'))) return;
              if (sub == null) {
                s.myLinks.remove(l);
                s.sel.remove(l);
                s.save();
              } else {
                s.removeFromSub(sub, [l]);
              }
            }
          },
          itemBuilder: (_) => [PopupMenuItem(value: 'copy', child: Text(s.t('copy'))), PopupMenuItem(value: 'del', child: Text(s.t('delete')))],
        ),
      ]),
    ),
  );
}

class FavoritesPage extends StatelessWidget {
  const FavoritesPage(this.s, {super.key});
  final Store s;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: s,
        builder: (ctx, _) {
          final list = [...s.favorites];
          return Scaffold(
            appBar: AppBar(
              title: Text(s.t('favorites')),
              actions: [
                if (list.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.delete_sweep_outlined),
                    onPressed: () async {
                      if (await confirm(ctx, s, s.t('favdelall'))) s.clearFavorites();
                    },
                  ),
              ],
            ),
            body: list.isEmpty
                ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(s.t('nofav'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey))))
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final l = list[i];
                      final inf = linkInfo(l);
                      return ListTile(
                        key: ValueKey(l),
                        dense: true,
                        title: Text(inf['n']!.isEmpty ? inf['h']! : inf['n']!, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${inf['p']}   ${inf['h']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          pingOrFailed(s, l),
                          IconButton(icon: const Icon(Icons.star, size: 20), onPressed: () => s.removeFavorite(l)),
                          IconButton(icon: const Icon(Icons.speed, size: 20), onPressed: () => s.testPings([l])),
                          IconButton(icon: const Icon(Icons.play_circle_outline), onPressed: () => s.connectFavorite(l)),
                          IconButton(icon: const Icon(Icons.delete_outline, size: 20), onPressed: () => s.removeFavorite(l)),
                        ]),
                      );
                    },
                  ),
          );
        },
      );
}

class ServersPage extends StatelessWidget {
  const ServersPage(this.s, {super.key});
  final Store s;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: s,
        builder: (ctx, _) {
          final list = [...s.myLinks];
          final chosen = list.where(s.sel.contains).toList();
          Widget btn(IconData ic, String label, VoidCallback f) => OutlinedButton.icon(onPressed: f, icon: Icon(ic, size: 18), label: Text(label));
          return Column(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                btn(Icons.content_paste, s.t('paste'), () async {
                  final r = await s.addText(await clip());
                  if (ctx.mounted) toast(ctx, '${s.t('added')}: $r');
                }),
                btn(Icons.file_upload_outlined, 'Import file', () async {
                  try {
                    final file = await FilePicker.pickFile();
                    if (file == null) return;
                    String content;
                    try {
                      final bytes = await file.readAsBytes();
                      content = utf8.decode(bytes);
                    } catch (_) {
                      final path = file.path;
                      if (path == null) return;
                      content = await File(path).readAsString();
                    }
                    final r = await s.importFileText(content);
                    if (ctx.mounted) toast(ctx, 'Imported: $r (added/duplicates/subs)');
                  } catch (_) {
                    if (ctx.mounted) toast(ctx, 'Could not read that file');
                  }
                }),
                btn(Icons.speed, s.testing ? '${s.pingDone}/${s.pingTotal}' : s.t('test'), s.testing ? () {} : s.testMy),
                btn(Icons.copy, s.t('copy'), () => copyText(ctx, s, (chosen.isEmpty ? list : chosen).join('\n'))),
                btn(Icons.link, s.t('subtext'), () => copyText(ctx, s, s.subText(chosen.isEmpty ? list : chosen))),
                btn(Icons.delete_outline, s.t('delete'), () async {
                  if (s.deleteConfirm && !await confirm(ctx, s, s.t('delete'))) return;
                  s.myLinks.removeWhere(s.sel.contains);
                  s.sel.clear();
                  s.save();
                }),
                btn(Icons.cleaning_services_outlined, s.t('deleteinvalid'), () {
                  if (!s.tested(s.myLinks)) {
                    toast(ctx, s.t('testfirst'));
                    return;
                  }
                  s.deleteInvalidMy();
                }),
                btn(Icons.delete_sweep_outlined, s.t('deleteall'), () async {
                  if (list.isNotEmpty && await confirm(ctx, s, s.t('deleteall'))) {
                    s.myLinks.clear();
                    s.sel.clear();
                    s.pings.clear();
                    s.save();
                  }
                }),
              ]),
            ),
            if (s.testing) LinearProgressIndicator(value: s.pingTotal == 0 ? null : s.pingDone / s.pingTotal),
            Expanded(
              child: list.isEmpty
                  ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(s.t('empty'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey))))
                  : ListView.builder(itemCount: list.length, itemBuilder: (_, i) => cfgTile(ctx, s, list[i])),
            ),
          ]);
        },
      );
}

// ---------------------------------------------------------------- subscriptions

Color barColor(double left) => left > .5 ? const Color(0xFF2BD67B) : (left > .2 ? Colors.amber : Colors.redAccent);

class SubsPage extends StatelessWidget {
  const SubsPage(this.s, {super.key});
  final Store s;

  Widget _bars(SubInfo? i, String u) {
    if (i == null) return const Padding(padding: EdgeInsets.only(top: 6), child: LinearProgressIndicator());
    if (!i.known) return Text(s.t('nousage'));
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final leftVol = i.total == 0 ? 1.0 : ((i.total - i.used) / i.total).clamp(0.0, 1.0);
    var leftTime = 1.0;
    if (i.expire != 0) {
      final first = s.subFirst[u] ?? now;
      final span = (i.expire - first) <= 0 ? 30 * 86400 : (i.expire - first);
      leftTime = ((i.expire - now) / span).clamp(0.0, 1.0);
    }
    final tl = i.timeLeft;
    Widget bar(String label, String value, double v) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)), Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))]),
            const SizedBox(height: 3),
            ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: v, minHeight: 7, color: barColor(v), backgroundColor: Colors.white12)),
          ]),
        );
    return Column(children: [
      bar(s.t('volume'), i.total == 0 ? s.t('unl') : '${fmtBytes(i.remaining ?? 0)} / ${fmtBytes(i.total)}', leftVol),
      bar(s.t('left'), tl == null ? s.t('unl') : '${tl.inDays} d ${tl.inHours % 24} h', leftTime),
    ]);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: s,
        builder: (ctx, _) => ListView(padding: const EdgeInsets.only(top: 8, bottom: 24), children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(spacing: 8, children: [
              FilledButton.icon(
                icon: const Icon(Icons.add_link),
                label: Text(s.t('addsub')),
                onPressed: () async {
                  final c = await clip();
                  final r = await ask(ctx, s, s.t('link'), initial: c.startsWith('http') ? c : '');
                  if (r != null && r.isNotEmpty) {
                    await s.addText(r);
                    s.refreshSubs();
                  }
                },
              ),
              OutlinedButton.icon(icon: const Icon(Icons.refresh), label: Text(s.t('refresh')), onPressed: s.refreshSubs),
            ]),
          ),
          if (s.mySubs.isEmpty) Padding(padding: const EdgeInsets.all(32), child: Text(s.t('empty'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey))),
          for (final u in s.mySubs) _sub(ctx, u),
          const Divider(height: 32),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(s.t('profiles'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
          Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.playlist_add),
              label: Text(s.t('mkprofile')),
              onPressed: () async {
                final chosen = s.myLinks.where(s.sel.contains).toList();
                if (chosen.isEmpty) {
                  toast(ctx, s.t('addfirst'));
                  return;
                }
                final n = await ask(ctx, s, s.t('name'));
                if (n != null && n.isNotEmpty) {
                  s.profiles[n] = chosen;
                  s.activeProfile = n;
                  s.save();
                }
              },
            ),
          ),
          for (final n in s.profiles.keys)
            ListTile(
              leading: Icon(s.activeProfile == n ? Icons.radio_button_checked : Icons.radio_button_off),
              title: Text(n),
              subtitle: Text('${s.profiles[n]!.length}'),
              onTap: () {
                s.activeProfile = s.activeProfile == n ? '' : n;
                s.save();
              },
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(icon: const Icon(Icons.copy), onPressed: () => copyText(ctx, s, s.subText(s.profiles[n]!))),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    s.profiles.remove(n);
                    if (s.activeProfile == n) s.activeProfile = '';
                    s.save();
                  },
                ),
              ]),
            ),
        ]),
      );

  Widget _sub(BuildContext ctx, String u) {
    final i = s.subInfo[u];
    final links = s.subLinks[u] ?? [];
    final host = Uri.tryParse(u)?.host ?? u;
    final used = s.activeSub == u && s.single == null && s.mode == 'personal';
    Widget act(IconData ic, String t, VoidCallback f) => OutlinedButton.icon(onPressed: f, icon: Icon(ic, size: 16), label: Text(t, style: const TextStyle(fontSize: 12)));
    return selectable(
      s,
      ctx,
      used,
      Theme(
        data: Theme.of(ctx).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          leading: Icon(i != null && !i.usable ? Icons.error_outline : Icons.cloud_done_outlined, color: i != null && !i.usable ? Colors.redAccent : null),
          title: Text('$host${used ? '   •   ${s.t('inuse')}' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: _bars(i, u),
          childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          children: [
            Wrap(spacing: 6, runSpacing: 6, children: [
              act(Icons.play_arrow, s.t('usesub'), () => s.connectSub(u)),
              act(Icons.speed, s.testing ? '${s.pingDone}/${s.pingTotal}' : s.t('testsub'), s.testing ? () {} : () => s.testSub(u)),
              act(Icons.copy, s.t('copyall'), () => copyText(ctx, s, links.join('\n'))),
              act(Icons.cleaning_services_outlined, s.t('deleteinvalid'), () {
                if (!s.tested(links)) {
                  toast(ctx, s.t('testfirst'));
                  return;
                }
                s.removeFromSub(u, links.where((l) => s.pings[l] == -1).toList());
              }),
              act(Icons.download, s.t('import'), () async {
                final n = await s.importSub(u);
                if (ctx.mounted) toast(ctx, '${s.t('added')}: $n');
              }),
              act(Icons.refresh, s.t('refresh'), () => s.refreshOneSub(u)),
              act(Icons.delete_outline, s.t('delsub'), () async {
                if (await confirm(ctx, s, s.t('delsub'))) s.removeSub(u);
              }),
            ]),
            const SizedBox(height: 8),
            if (links.isEmpty) Padding(padding: const EdgeInsets.all(12), child: Text(s.t('nocfg'), style: const TextStyle(color: Colors.grey))),
            // A large subscription (1000+ configs) must never be built all at once: past a
            // small count this switches to a bounded, truly lazy list instead of ExpansionTile's
            // plain children (which lays out every item as soon as it is expanded).
            if (links.isNotEmpty && links.length <= 40)
              for (final l in links) cfgTile(ctx, s, l, sub: u)
            else if (links.isNotEmpty)
              SizedBox(
                height: 420,
                child: ListView.builder(itemCount: links.length, itemBuilder: (_, i) => cfgTile(ctx, s, links[i], sub: u)),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- CDN setup

class CdnPage extends StatefulWidget {
  const CdnPage(this.s, {super.key});
  final Store s;
  @override
  State<CdnPage> createState() => _CdnState();
}

class _CdnState extends State<CdnPage> {
  late final cfg = TextEditingController(text: widget.s.cdnLinks.join('\n'));
  late final ip = TextEditingController(text: widget.s.cleanIp);
  late final host = TextEditingController(text: widget.s.frontHost);
  late final len = TextEditingController(text: widget.s.fragLen);
  late final itv = TextEditingController(text: widget.s.fragInt);
  late bool frag = widget.s.fragment;

  void _save() {
    final s = widget.s;
    s.cdnLinks = extractLinks(cfg.text);
    s.cleanIp = ip.text.trim();
    s.frontHost = host.text.trim();
    s.fragment = frag;
    s.fragLen = len.text.trim().isEmpty ? '100-200' : len.text.trim();
    s.fragInt = itv.text.trim().isEmpty ? '10-20' : itv.text.trim();
    s.save();
    Navigator.pop(context);
    s.startCdn();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    InputDecoration d(String l, [String? h]) => InputDecoration(labelText: l, helperText: h, helperMaxLines: 3, border: const OutlineInputBorder());
    return Scaffold(
      appBar: AppBar(title: Text(s.t('cdnsetup'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: cfg, minLines: 2, maxLines: 5, decoration: d(s.t('cdncfg'), s.t('cdncfg_h'))),
        const SizedBox(height: 14),
        TextField(controller: ip, decoration: d(s.t('cleanip'), s.t('clean_h'))),
        const SizedBox(height: 14),
        TextField(controller: host, decoration: d(s.t('fronthost'), s.t('clean_h'))),
        const SizedBox(height: 8),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(s.t('fragment')), subtitle: Text(s.t('fragment_h')), value: frag, onChanged: (v) => setState(() => frag = v)),
        if (frag)
          Row(children: [
            Expanded(child: TextField(controller: len, decoration: d(s.t('fraglen')))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: itv, decoration: d(s.t('fragint')))),
          ]),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(onPressed: _save, child: Padding(padding: const EdgeInsets.all(14), child: Text(s.t('save')))),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- tools

class ToolsPage extends StatefulWidget {
  const ToolsPage(this.s, {super.key});
  final Store s;
  @override
  State<ToolsPage> createState() => _ToolsState();
}

class _ToolsState extends State<ToolsPage> {
  late final ipCtl = TextEditingController(text: widget.s.cleanIp);
  late final hostCtl = TextEditingController(text: widget.s.frontHost);
  String myIp = '';
  bool hostsExpanded = false;
  // v1.0.7: IPs imported from a .txt file (session list, like the
  // scanner hits: the chosen clean IP persists, the list itself
  // does not need to).
  final importedIps = <String>[];
  final importedIpMs = <String, int>{};
  bool testingImported = false;

  /// Reads a picked .txt file as text, or null when cancelled or
  /// unreadable. Same pattern as the subscription file import.
  Future<String?> _pickTxt() async {
    try {
      final file = await FilePicker.pickFile();
      if (file == null) return null;
      try {
        final bytes = await file.readAsBytes();
        return utf8.decode(bytes);
      } catch (_) {
        final path = file.path;
        if (path == null) return null;
        return await File(path).readAsString();
      }
    } catch (_) {
      return null;
    }
  }

  Future<void> _importHosts() async {
    final text = await _pickTxt();
    if (text == null || !mounted) return;
    final n = widget.s.addUserHosts(text);
    if (mounted) toast(context, '${widget.s.t('added')}: $n');
  }

  Future<void> _importIps() async {
    final text = await _pickTxt();
    if (text == null || !mounted) return;
    final ipRe = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
    final seen = <String>{};
    final out = <String>[];
    for (final token in text.split(RegExp(r'[\s,;]+'))) {
      final v = token.trim();
      if (v.isEmpty || !ipRe.hasMatch(v)) continue;
      final parts = v.split('.').map(int.tryParse).toList();
      if (parts.any((e) => e == null || e > 255)) continue;
      if (seen.add(v)) out.add(v);
      if (out.length >= 500) break;
    }
    setState(() {
      importedIps
        ..clear()
        ..addAll(out);
      importedIpMs.clear();
    });
    if (mounted) toast(context, '${widget.s.t('added')}: ${out.length}');
  }

  /// Real TLS probes of the imported IPs against the chosen SNI
  /// (the same probeIp the scanner uses): only IPs that answer
  /// Cloudflare's trace page are usable as clean IPs.
  Future<void> _testImportedIps() async {
    if (testingImported || importedIps.isEmpty) return;
    setState(() {
      testingImported = true;
      importedIpMs.clear();
    });
    final sni = hostCtl.text.trim().isEmpty ? 'speed.cloudflare.com' : hostCtl.text.trim();
    final queue = [...importedIps];
    var i = 0;
    Future<void> worker() async {
      while (i < queue.length) {
        final ip = queue[i++];
        final h = await probeIp(ip, sni);
        if (mounted) setState(() => importedIpMs[ip] = h == null ? -1 : h.ms);
      }
    }

    await Future.wait(List.generate(8, (_) => worker()));
    if (mounted) setState(() => testingImported = false);
  }

  Future<void> _myIp() async {
    final c = HttpClient();
    try {
      final r = await (await c.getUrl(Uri.parse('https://ipwho.is/'))).close().timeout(const Duration(seconds: 8));
      final j = jsonDecode(await r.transform(utf8.decoder).join());
      if (mounted) setState(() => myIp = '${j['ip']}  ${j['city'] ?? ''} ${j['country'] ?? ''}');
    } catch (_) {
      if (mounted) setState(() => myIp = 'failed');
    } finally {
      c.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final hosts = s.allHosts;
    final healthyHosts = hosts.where((h) => (s.hostMs[h] ?? -1) > 0).toList()..sort((a, b) => s.hostMs[a]!.compareTo(s.hostMs[b]!));
    final healthyImported = importedIps.where((ip) => (importedIpMs[ip] ?? -1) > 0).toList()..sort((a, b) => importedIpMs[a]!.compareTo(importedIpMs[b]!));
    return ListView(padding: const EdgeInsets.all(16), children: [
      _section(context, s, Icons.cloud_outlined, s.t('cat_fronting'), s.t('cat_fronting_d'), [
        TextField(
          controller: ipCtl,
        decoration: InputDecoration(labelText: s.t('cleanip'), border: const OutlineInputBorder()),
        onChanged: (v) {
          s.cleanIp = v.trim();
          s.save();
        },
      ),
      const SizedBox(height: 10),
      TextField(
        controller: hostCtl,
        decoration: InputDecoration(labelText: s.t('fronthost'), border: const OutlineInputBorder()),
        onChanged: (v) {
          s.frontHost = v.trim();
          s.save();
        },
        ),
      ]),
      _section(context, s, Icons.radar, s.t('cat_scan'), s.t('cat_scan_d'), [
        Wrap(spacing: 8, children: [
        for (final c in ['Cloudflare', 'Fastly'])
          ChoiceChip(
            label: Text(c),
            selected: s.scanCdn == c,
            onSelected: s.scanning
                ? null
                : (_) {
                    s.scanCdn = c;
                    s.refresh();
                  },
          ),
      ]),
      Row(children: [
        DropdownButton<int>(
          value: s.scanCount,
          items: [for (final n in [100, 300, 600, 1000]) DropdownMenuItem(value: n, child: Text('$n IP'))],
          onChanged: s.scanning
              ? null
              : (v) {
                  s.scanCount = v!;
                  s.refresh();
                },
        ),
        const SizedBox(width: 6),
        TextButton.icon(onPressed: s.scanning ? null : s.updateRanges, icon: const Icon(Icons.cloud_download_outlined, size: 18), label: Text(s.t('updateranges'))),
        const Spacer(),
        FilledButton(onPressed: s.scanning ? s.stopScan : s.runScan, child: Text(s.scanning ? s.t('stop') : s.t('start'))),
      ]),
      Text(s.rangesInfo(s.scanCdn), style: const TextStyle(color: Colors.grey, fontSize: 11)),
      if (s.scanning) ...[
        const SizedBox(height: 6),
        Text(s.t('stage${s.scanStageNo}'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: s.scanTotal == 0 ? null : s.scanDone / s.scanTotal),
      ],
      if (s.scanHits.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Wrap(spacing: 8, children: [
            FilledButton.tonalIcon(
              icon: const Icon(Icons.check_circle_outline, size: 18),
              label: Text(s.t('usebest')),
              onPressed: () {
                ipCtl.text = s.scanHits.first.ip;
                s.cleanIp = s.scanHits.first.ip;
                s.save();
              },
            ),
            OutlinedButton.icon(icon: const Icon(Icons.copy, size: 18), label: Text(s.t('copytop')), onPressed: () => copyText(context, s, s.scanHits.take(20).map((h) => h.ip).join('\n'))),
          ]),
        ),
      for (final h in s.scanHits.take(30))
        ListTile(
          dense: true,
          title: Text(h.ip, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text('${h.cdn}${h.colo.isEmpty ? '' : ' ${h.colo}'}    ${h.ok}/${h.tries}${h.mbps == null ? '' : '    ${h.mbps!.toStringAsFixed(1)} Mbps'}'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('${h.ms} ms'),
            IconButton(
              icon: Icon(s.cleanIp == h.ip ? Icons.check_circle : Icons.check_circle_outline),
              onPressed: () {
                ipCtl.text = h.ip;
                s.cleanIp = h.ip;
                s.save();
              },
            ),
          ]),
          onTap: () => copyText(context, s, h.ip),
        ),
        const Divider(height: 24),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(icon: const Icon(Icons.file_upload_outlined, size: 18), label: Text(s.t('importips')), onPressed: _importIps),
          if (importedIps.isNotEmpty)
            OutlinedButton.icon(icon: const Icon(Icons.speed, size: 18), label: Text(testingImported ? '...' : s.t('testimported')), onPressed: testingImported ? null : _testImportedIps),
          if (healthyImported.isNotEmpty) OutlinedButton.icon(icon: const Icon(Icons.copy, size: 18), label: Text(s.t('copyhealthy')), onPressed: () => copyText(context, s, healthyImported.join('\n'))),
        ]),
        for (final ip in importedIps)
          ListTile(
            dense: true,
            title: Text(ip, style: const TextStyle(fontWeight: FontWeight.w700)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(importedIpMs[ip] == null ? '' : (importedIpMs[ip]! < 0 ? 'no reply' : '${importedIpMs[ip]} ms'), style: TextStyle(color: importedIpMs[ip] != null && importedIpMs[ip]! < 0 ? Colors.redAccent : null)),
              IconButton(
                icon: Icon(s.cleanIp == ip ? Icons.check_circle : Icons.check_circle_outline),
                onPressed: () {
                  ipCtl.text = ip;
                  s.cleanIp = ip;
                  s.save();
                },
              ),
            ]),
            onTap: () => copyText(context, s, ip),
          ),
      ]),
      Card(
        margin: const EdgeInsets.only(bottom: 16),
        child: ExpansionTile(
          leading: const Icon(Icons.dns_outlined),
          title: Text('${s.t('cat_hosts')} (${hosts.length})', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          subtitle: Text(s.t('cat_hosts_d'), style: const TextStyle(color: Colors.grey, fontSize: 12)),
          initiallyExpanded: hostsExpanded,
          onExpansionChanged: (v) => hostsExpanded = v,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.t('hostgrid_d'), style: const TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.travel_explore),
                    label: Text(s.hostTesting ? '...' : s.t('hosttest')),
                    onPressed: s.hostTesting
                        ? null
                        : () async {
                            await s.testHosts();
                            hostCtl.text = s.frontHost;
                          },
                  ),
                  OutlinedButton.icon(icon: const Icon(Icons.file_upload_outlined, size: 18), label: Text(s.t('importfile')), onPressed: _importHosts),
                  if (healthyHosts.isNotEmpty) OutlinedButton.icon(icon: const Icon(Icons.copy, size: 18), label: Text(s.t('copyhealthy')), onPressed: () => copyText(context, s, healthyHosts.join('\n'))),
                ]),
                const SizedBox(height: 12),
                GridView.count(
                  crossAxisCount: 5,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  childAspectRatio: 0.9,
                  children: [
                    for (final h in hosts)
                      InkWell(
                        onTap: () {
                          hostCtl.text = h;
                          s.frontHost = h;
                          s.save();
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: s.frontHost == h ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurface.withOpacity(.15)),
                            color: s.frontHost == h ? Theme.of(context).colorScheme.primary.withOpacity(.12) : null,
                          ),
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Icon(
                              s.hostMs[h] == null ? Icons.circle_outlined : (s.hostMs[h]! < 0 ? Icons.cancel : Icons.check_circle),
                              size: 14,
                              color: s.hostMs[h] == null ? Colors.grey : (s.hostMs[h]! < 0 ? Colors.redAccent : const Color(0xFF2BD67B)),
                            ),
                            const SizedBox(height: 2),
                            Text(h, textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9)),
                          ]),
                        ),
                      ),
                  ],
                ),
              ]),
            ),
          ],
        ),
      ),
      _section(context, s, Icons.bug_report_outlined, s.t('cat_checks'), s.t('cat_checks_d'), [
        OutlinedButton.icon(
          icon: const Icon(Icons.bug_report_outlined),
          label: Text(s.t('selftest')),
          onPressed: () async {
            final r = await s.selfTest();
            if (context.mounted) toast(context, r);
          },
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(icon: const Icon(Icons.public), label: Text(s.t('myip')), onPressed: _myIp),
        if (myIp.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(myIp)),
      ]),
      _section(context, s, Icons.build_outlined, s.t('cat_net'), s.t('cat_net_d'), [
        OutlinedButton.icon(icon: const Icon(Icons.dns_outlined), label: Text(s.t('dnstest')), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DnsTestPage(s)))),
        const SizedBox(height: 8),
        OutlinedButton.icon(icon: const Icon(Icons.language_outlined), label: Text(s.t('domaincheck')), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DomainCheckPage(s)))),
        const SizedBox(height: 8),
        OutlinedButton.icon(icon: const Icon(Icons.swap_horiz_outlined), label: Text(s.t('vlessmod')), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => VlessModifierPage(s)))),
      ]),
    ]);
  }

  Widget _section(BuildContext context, Store s, IconData icon, String title, String desc, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Icon(icon, size: 20), const SizedBox(width: 8), Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)))]),
            const SizedBox(height: 4),
            Text(desc, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 12),
            ...children,
          ]),
        ),
      );
}

// ---------------------------------------------------------------- apps

class AppsPage extends StatefulWidget {
  const AppsPage(this.s, {super.key});
  final Store s;
  @override
  State<AppsPage> createState() => _AppsState();
}

class _AppsState extends State<AppsPage> {
  String q = '', filter = 'user';

  @override
  void initState() {
    super.initState();
    widget.s.loadApps();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return ListenableBuilder(
      listenable: s,
      builder: (ctx, _) {
        final accent = Theme.of(ctx).colorScheme.primary;
        final all = s.apps;
        final shown = all.where((a) {
          if (filter == 'user' && a.system) return false;
          if (filter == 'system' && !a.system) return false;
          if (filter == 'sel' && !s.appSet.contains(a.pkg)) return false;
          final k = q.toLowerCase();
          return k.isEmpty || a.name.toLowerCase().contains(k) || a.pkg.toLowerCase().contains(k);
        }).toList();
        Widget mode(String m, String label, IconData ic) => Expanded(
              child: GestureDetector(
                onTap: () {
                  s.appMode = m;
                  s.save();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: s.appMode == m ? accent.withOpacity(.2) : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: s.appMode == m ? accent : Colors.transparent),
                  ),
                  child: Column(children: [
                    Icon(ic, size: 20, color: s.appMode == m ? accent : Colors.grey),
                    const SizedBox(height: 2),
                    Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: s.appMode == m ? accent : Colors.grey)),
                  ]),
                ),
              ),
            );
        return Scaffold(
          appBar: AppBar(title: Text(s.t('apps')), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: () => s.loadApps(force: true))]),
          body: Column(children: [
            Container(
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: Theme.of(ctx).cardColor, borderRadius: BorderRadius.circular(18), border: Border.all(color: Theme.of(ctx).colorScheme.onSurface.withOpacity(.12))),
              child: Row(children: [
                mode('all', s.t('apps_all'), Icons.public),
                mode('only', s.t('apps_only'), Icons.filter_alt_outlined),
                mode('except', s.t('apps_except'), Icons.block),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: s.t('search'), border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)), isDense: true),
                onChanged: (v) => setState(() => q = v),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(children: [
                for (final f in [['user', s.t('userapps')], ['system', s.t('sysapps')], ['sel', '${s.t('chosen')} (${s.appSet.length})']])
                  Padding(padding: const EdgeInsetsDirectional.only(end: 8), child: ChoiceChip(label: Text(f[1]), selected: filter == f[0], onSelected: (_) => setState(() => filter = f[0]))),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    s.appSet.addAll(shown.map((a) => a.pkg));
                    s.save();
                  },
                  child: Text(s.t('selectall')),
                ),
                TextButton(
                  onPressed: () {
                    s.appSet.clear();
                    s.save();
                  },
                  child: Text(s.t('clearsel')),
                ),
              ]),
            ),
            if (s.appsLoading) const LinearProgressIndicator(),
            Expanded(
              child: shown.isEmpty && !s.appsLoading
                  ? Center(child: Text(s.t('empty'), style: const TextStyle(color: Colors.grey)))
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (_, i) {
                        final a = shown[i];
                        final on = s.appSet.contains(a.pkg);
                        return Container(
                          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                          decoration: BoxDecoration(
                            color: Theme.of(ctx).cardColor,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: on ? accent : Theme.of(ctx).colorScheme.onSurface.withOpacity(.12), width: on ? 2 : 1),
                          ),
                          child: ListTile(
                            dense: true,
                            leading: ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.memory(a.icon, width: 40, height: 40, gaplessPlayback: true)),
                            title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Text(a.pkg, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                            trailing: Switch(
                              value: on,
                              onChanged: (v) {
                                v ? s.appSet.add(a.pkg) : s.appSet.remove(a.pkg);
                                s.save();
                              },
                            ),
                            onTap: () {
                              on ? s.appSet.remove(a.pkg) : s.appSet.add(a.pkg);
                              s.save();
                            },
                          ),
                        );
                      },
                    ),
            ),
          ]),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- settings & logs

class SettingsPage extends StatelessWidget {
  const SettingsPage(this.s, {super.key});
  final Store s;

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
        ListTile(
          title: Text(s.t('language')),
          trailing: DropdownButton<String>(
            value: s.lang,
            items: const [DropdownMenuItem(value: 'en', child: Text('English')), DropdownMenuItem(value: 'fa', child: Text('فارسی'))],
            onChanged: (v) {
              s.lang = v!;
              s.save();
            },
          ),
        ),
        ListTile(
          title: Text(s.t('theme')),
          trailing: DropdownButton<String>(
            value: s.theme,
            items: [for (final t in Store.themes) DropdownMenuItem(value: t, child: Text(t))],
            onChanged: (v) {
              s.theme = v!;
              s.save();
            },
          ),
        ),
        ListTile(
          title: Text(s.t('accent')),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(spacing: 10, children: [
              for (final c in Store.accents)
                GestureDetector(
                  onTap: () {
                    s.accent = c;
                    s.save();
                  },
                  child: CircleAvatar(radius: 16, backgroundColor: Color(c), child: s.accent == c ? const Icon(Icons.check, size: 18, color: Colors.black) : null),
                ),
            ]),
          ),
        ),
        ListTile(title: Text(s.t('conntype')), subtitle: Text(s.t('conntype_h'))),
        Wrap(spacing: 8, children: [
          ChoiceChip(
            avatar: const Icon(Icons.vpn_lock, size: 18),
            label: Text(s.t('vpnmode')),
            selected: s.connType == 'vpn',
            onSelected: (_) {
              s.connType = 'vpn';
              s.save();
            },
          ),
          ChoiceChip(
            avatar: const Icon(Icons.dns_outlined, size: 18),
            label: Text(s.t('proxymode')),
            selected: s.connType == 'proxy',
            onSelected: (_) {
              s.connType = 'proxy';
              s.save();
            },
          ),
        ]),
        ListTile(
          leading: const Icon(Icons.apps),
          title: Text(s.t('apps')),
          subtitle: Text(s.t('apps_${s.appMode}') + (s.appMode == 'all' ? '' : '  (${s.appSet.length})')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AppsPage(s))),
        ),
        SwitchListTile(title: Text(s.t('strict')), subtitle: Text(s.t('strict_h')), value: s.strict, onChanged: (v) {
          s.strict = v;
          s.save();
        }),
        SwitchListTile(title: Text(s.t('fragall')), subtitle: Text(s.t('fragment_h')), value: s.fragAll, onChanged: (v) {
          s.fragAll = v;
          s.save();
        }),
        SwitchListTile(title: Text(s.t('autosort')), subtitle: Text(s.t('autosort_h')), value: s.autoSortAfterTest, onChanged: (v) {
          s.autoSortAfterTest = v;
          s.save();
        }),
        SwitchListTile(title: Text(s.t('deleteconfirm')), subtitle: Text(s.t('deleteconfirm_h')), value: s.deleteConfirm, onChanged: (v) {
          s.deleteConfirm = v;
          s.save();
        }),
        SwitchListTile(title: Text(s.t('ipv6')), subtitle: Text(s.t('ipv6_h')), value: s.useIpv6, onChanged: (v) {
          s.useIpv6 = v;
          s.save();
        }),
        const SizedBox(height: 8),
        TextFormField(
          initialValue: s.testUrl,
          minLines: 1,
          maxLines: 2,
          decoration: InputDecoration(labelText: s.t('testurl2'), border: const OutlineInputBorder(), hintText: 'https://cp.cloudflare.com/generate_204'),
          onChanged: (v) {
            s.testUrl = v.trim().isEmpty ? 'https://cp.cloudflare.com/generate_204' : v.trim();
            s.save();
          },
        ),
        Padding(padding: const EdgeInsets.only(top: 4), child: Text(s.t('testurl2_h'), style: const TextStyle(color: Colors.grey, fontSize: 12))),
        const SizedBox(height: 8),
        TextFormField(
          initialValue: s.bypass,
          minLines: 1,
          maxLines: 4,
          decoration: InputDecoration(labelText: s.t('testurl'), border: const OutlineInputBorder(), hintText: 'org.telegram.messenger'),
          onChanged: (v) {
            s.bypass = v;
            s.save();
          },
        ),
        const SizedBox(height: 16),
        ListTile(leading: const Icon(Icons.share_outlined), title: Text(s.t('sharevpn')), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ShareVpnPage(s)))),
        ListTile(leading: const Icon(Icons.auto_awesome), title: Text(s.t('aichat')), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AiChatPage(s)))),
        ListTile(title: Text(s.t('aikey')), subtitle: Text(s.t('aikey_h'))),
        TextFormField(
          initialValue: s.aiApiKey,
          obscureText: true,
          decoration: InputDecoration(labelText: s.t('aikey'), border: const OutlineInputBorder()),
          onChanged: (v) {
            s.aiApiKey = v.trim();
            s.save();
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(s.aiApiKey.isNotEmpty ? s.t('aikey_own') : (s.aiReady ? s.t('aikey_builtin') : s.t('aikey_none')), style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ),
        const SizedBox(height: 12),
        ListTile(title: Text(s.t('airemote')), subtitle: Text(s.t('airemote_h'))),
        TextFormField(
          initialValue: s.aiRemoteUrl,
          decoration: InputDecoration(labelText: s.t('airemote'), border: const OutlineInputBorder()),
          onChanged: (v) {
            s.aiRemoteUrl = v.trim();
            s.save();
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(s.t('airefresh')),
            onPressed: () async {
              final r = await s.refreshAiRemote();
              if (context.mounted) toast(context, r);
            },
          ),
        ),
        const SizedBox(height: 16),
        ListTile(leading: const Icon(Icons.article_outlined), title: Text(s.t('logs')), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LogsPage(s)))),
        ListTile(leading: const Icon(Icons.send_outlined), title: const Text('Telegram @V2rayAG'), subtitle: const Text(kTelegram), onTap: () => copyText(context, s, kTelegram)),
        ListTile(leading: const Icon(Icons.info_outline), title: Text(s.t('dev'))),
        ListTile(leading: const Icon(Icons.restart_alt, color: Colors.redAccent), title: Text(s.t('reset')), onTap: s.resetAll),
      ]);
}

class LogsPage extends StatelessWidget {
  const LogsPage(this.s, {super.key});
  final Store s;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: s,
        builder: (ctx, _) => Scaffold(
          appBar: AppBar(title: Text(s.t('logs')), actions: [
            IconButton(
              icon: const Icon(Icons.auto_awesome),
              tooltip: s.t('aichat'),
              onPressed: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => AiChatPage(s, attachment: s.logs.reversed.join('\n'), attachmentLabel: '${s.logs.length} ${s.t('logs')}'))),
            ),
            IconButton(icon: const Icon(Icons.bug_report_outlined), tooltip: 'System log', onPressed: s.captureSystemLog),
            IconButton(icon: const Icon(Icons.copy), onPressed: () => copyText(ctx, s, s.logs.reversed.join('\n'))),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () {
                s.logs.clear();
                s.refresh();
              },
            ),
          ]),
          // v45: tidy log table. Each log sits in its own grey-bordered
          // box with its time on one side and its text on the other.
          // Connected logs tint green, failed/error logs tint red, the
          // rest stay plain. Text color is inherited, so it stays
          // light on dark themes and dark on light themes; borders are
          // always grey.
          body: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: s.logs.length,
            itemBuilder: (_, i) {
              final line = s.logs[i];
              // Log lines are "HH:MM:SS  message" (see Store.log).
              final m = RegExp(r'^(\d{2}:\d{2}:\d{2})\s+(.*)$').firstMatch(line);
              final time = m?.group(1) ?? '';
              final msg = m?.group(2) ?? line;
              final low = msg.toLowerCase();
              final isFail = low.contains('failed') || low.contains('error');
              final isConn = !isFail && low.contains('connected') && !low.contains('disconnected');
              final tint = isFail ? Colors.redAccent : (isConn ? Colors.greenAccent : null);
              // v1.0.7: tapping a log box opens the AI chat with
              // exactly that line attached, and the AI starts
              // explaining it in plain language right away.
              return InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => AiChatPage(s, attachment: line, attachmentLabel: s.t('ailogline'), autoAsk: s.t('aiexplain_q')))),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(8),
                    color: tint?.withOpacity(0.10),
                  ),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (time.isNotEmpty) ...[
                      Text(time, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.grey)),
                      const SizedBox(width: 10),
                    ],
                    Expanded(child: SelectableText(msg, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
                  ]),
                ),
              );
            },
          ),
        ),
      );
}
