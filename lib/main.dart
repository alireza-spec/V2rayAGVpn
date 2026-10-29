import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app/store.dart';
import 'engine/flutter_vless_core.dart';
import 'ui/pages.dart';

/// Build-time pool: --dart-define=POOL_LIST=url1,url2,...  or  --dart-define=POOL_URL=https://...
const kPoolUrl = String.fromEnvironment('POOL_URL');
const kPoolList = String.fromEnvironment('POOL_LIST');

Future<List<String>> loadPool() async {
  final fixed = kPoolList.split(',').where((e) => e.startsWith('http')).toList();
  if (fixed.isNotEmpty) return fixed;
  if (kPoolUrl.isEmpty) return [];
  final c = HttpClient();
  try {
    final r = await (await c.getUrl(Uri.parse(kPoolUrl))).close();
    return List<String>.from(jsonDecode(await r.transform(utf8.decoder).join()));
  } catch (_) {
    return [];
  } finally {
    c.close(force: true);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final core = FlutterVlessCore();
  await core.init();
  final s = Store(core, await loadPool());
  await s.load();
  await s.restoreSession();
  s.initAllProviders(); // fire-and-forget: populates every provider's config count without blocking startup
  s.log(s.pool.isEmpty ? 'Pool is EMPTY: the POOL_LIST secret was not included in this build' : 'Pool loaded: ${s.pool.length} subscriptions');
  runApp(V2rayAgApp(s));
}

class V2rayAgApp extends StatelessWidget {
  const V2rayAgApp(this.s, {super.key});
  final Store s;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: s,
        builder: (_, __) => MaterialApp(
          title: 'V2rayAG',
          debugShowCheckedModeBanner: false,
          theme: s.themeData,
          builder: (c, w) => Directionality(textDirection: s.fa ? TextDirection.rtl : TextDirection.ltr, child: w!),
          home: Shell(s),
        ),
      );
}
