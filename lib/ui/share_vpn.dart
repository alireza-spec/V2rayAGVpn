// Share VPN page (v1.0.7): both sides of sharing, in one place.
//
// Sharer: starts the LAN relay (Proxy mode core, or Psiphon) and
// shows the address others enter. OFF by default, alive only while
// connected, with the warning that anyone on the same network can
// use the tunnel while it runs. In VPN mode the local proxy is
// locked with system-only credentials, so the page offers the
// one-tap switch to Proxy mode instead of a relay that fails.
//
// Joiner: enters the sharer's IP + port (+ optional user/pass)
// and connects the whole device through it, with no subscription
// or config of its own — a socks:// single config in Personal
// mode, verified with the same real-traffic check as any config.
// The info dialog explains all three ways to connect (shared
// Wi-Fi, hotspot, in-app) in the app's language.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/store.dart';
import '../engine/pool_engine.dart';
import '../engine/psiphon_engine.dart';

void _snack(BuildContext c, String m) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

Future<bool> _confirm(BuildContext c, Store s, String title, String body) async {
  final r = await showDialog<bool>(
    context: c,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(s.t('cancel'))),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(s.t('ok'))),
      ],
    ),
  );
  return r == true;
}

class ShareVpnPage extends StatefulWidget {
  const ShareVpnPage(this.s, {super.key});
  final Store s;
  @override
  State<ShareVpnPage> createState() => _ShareState();
}

class _ShareState extends State<ShareVpnPage> {
  late final portCtl = TextEditingController(text: widget.s.sharePort.toString());
  late final hostCtl = TextEditingController(text: widget.s.sharedProxyHost);
  late final joinPortCtl = TextEditingController(text: widget.s.sharedProxyPort.toString());
  late final userCtl = TextEditingController(text: widget.s.sharedProxyUser);
  late final passCtl = TextEditingController(text: widget.s.sharedProxyPass);
  bool starting = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return ListenableBuilder(
      listenable: s,
      builder: (ctx, _) {
        final relay = s.shareRelay;
        final engOn = s.engine.state.phase == Phase.connected;
        final psiOn = s.psiphon.state.phase == PsiphonPhase.connected;
        final connected = engOn || psiOn;
        return Scaffold(
          appBar: AppBar(
            title: Text(s.t('sharevpn')),
            actions: [
              IconButton(
                icon: const Icon(Icons.info_outline),
                tooltip: s.t('shareinfo'),
                onPressed: () => showDialog(
                  context: ctx,
                  builder: (_) => AlertDialog(
                    title: Text(s.t('shareinfo')),
                    content: SingleChildScrollView(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(s.t('shareinfo1')),
                        const SizedBox(height: 12),
                        Text(s.t('shareinfo2')),
                        const SizedBox(height: 12),
                        Text(s.t('shareinfo3')),
                      ]),
                    ),
                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.t('close')))],
                  ),
                ),
              ),
            ],
          ),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Text(s.t('sharevpn'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 4),
            Text(s.t('sharewarn'), style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
            const SizedBox(height: 12),
            if (relay != null) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${s.t('sharevia')} ${relay.targetSource}', style: const TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    for (final ip in relay.lanIps) Text('SOCKS5 $ip:${relay.port}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    if (relay.lanIps.isEmpty) Text('SOCKS5 127.0.0.1:${relay.port} (${s.t('sharevia')} ${relay.targetSource})'),
                    const SizedBox(height: 4),
                    Text('${relay.connections} connections so far', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.copy, size: 18),
                      label: Text(s.t('sharecopy')),
                      onPressed: () {
                        final addrs = relay.lanIps.isEmpty ? ['SOCKS5 127.0.0.1:${relay.port}'] : relay.lanIps.map((ip) => 'SOCKS5 $ip:${relay.port}').toList();
                        Clipboard.setData(ClipboardData(text: addrs.join('\n')));
                        _snack(ctx, s.t('copied'));
                      },
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(icon: const Icon(Icons.stop), label: Text(s.t('sharestop')), onPressed: () => s.stopShare()),
            ] else ...[
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: portCtl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: s.t('shareport'), border: const OutlineInputBorder()),
                    onChanged: (v) {
                      final p = int.tryParse(v);
                      if (p != null && p > 0 && p <= 65535) {
                        s.sharePort = p;
                        s.save();
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  icon: const Icon(Icons.share),
                  label: Text(starting ? '...' : s.t('sharestart')),
                  onPressed: !connected || starting
                      ? null
                      : () async {
                          setState(() => starting = true);
                          final err = await s.startShare();
                          if (mounted) setState(() => starting = false);
                          if (err.isNotEmpty && ctx.mounted) _snack(ctx, err);
                        },
                ),
              ]),
              if (!connected) Padding(padding: const EdgeInsets.only(top: 8), child: Text(s.t('sharenotconn'), style: const TextStyle(color: Colors.grey, fontSize: 12))),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.swap_horiz),
                label: Text(s.t('shareswitchproxy')),
                onPressed: () async {
                  if (!await _confirm(ctx, s, s.t('shareswitchproxy'), s.t('shareswitchproxy_d'))) return;
                  s.connType = 'proxy';
                  s.save();
                  await s.disconnectAll();
                  await s.connect();
                },
              ),
            ],
            const Divider(height: 32),
            Text(s.t('sharejoin'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 4),
            Text(s.t('sharejoin_d'), style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 12),
            TextField(controller: hostCtl, decoration: InputDecoration(labelText: s.t('sharehost'), border: const OutlineInputBorder(), hintText: '192.168.43.1')),
            const SizedBox(height: 10),
            TextField(controller: joinPortCtl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: s.t('shareport'), border: const OutlineInputBorder())),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: TextField(controller: userCtl, decoration: InputDecoration(labelText: s.t('shareuser'), border: const OutlineInputBorder()))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: passCtl, obscureText: true, decoration: InputDecoration(labelText: s.t('sharepass'), border: const OutlineInputBorder()))),
            ]),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.power_settings_new),
              label: Text(s.t('shareconnect')),
              onPressed: () async {
                final host = hostCtl.text.trim();
                final port = int.tryParse(joinPortCtl.text.trim());
                if (host.isEmpty || port == null || port <= 0 || port > 65535) {
                  _snack(ctx, s.t('sharehost'));
                  return;
                }
                await s.connectSharedProxy(host, port, user: userCtl.text.trim(), pass: passCtl.text);
                if (ctx.mounted) {
                  s.go(0);
                  Navigator.pop(ctx);
                }
              },
            ),
          ]),
        );
      },
    );
  }
}
