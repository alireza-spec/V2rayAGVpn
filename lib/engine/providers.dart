import 'dart:convert';

/// Providers from the repo secret, not from code.
///
/// Secret name in GitHub: PROVIDERS_JSON
/// Build passes it as base64 in dart-define PROVIDERS_B64 (see build.yml),
/// because the JSON itself contains quotes that would break a shell argument.
/// Format (one JSON array):
///   [{"id":"v2rayag","name":"V2rayAG Exclusive","enabled":true,"hours":6,
///     "sources":["https://example/sub.txt","https://example/other#Label"]}]
/// A source may carry a '#Label' fragment, exactly like the old code did.
/// If the secret is empty, invalid, or yields no providers, the built-in
/// fallback list below is used, so a build never ships with an empty list.
/// Changing providers afterwards needs NO code change: edit the secret in
/// GitHub Settings, then run the workflow (Actions > build-apk > Run workflow).
/// A new APK is built from the new secret; already-installed APKs do not
/// change until the user installs that new build, because a GitHub secret
/// is only read at build time, never at runtime by an installed app.
List<ProviderDef>? _secretProviders() {
  const b64 = String.fromEnvironment('PROVIDERS_B64');
  if (b64.isEmpty) return null;
  try {
    final raw = utf8.decode(base64Decode(b64));
    final decoded = jsonDecode(raw);
    if (decoded is! List || decoded.isEmpty) return null;
    final out = <ProviderDef>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final id = '${item['id'] ?? ''}';
      final name = '${item['name'] ?? ''}';
      final srcs = item['sources'];
      if (id.isEmpty || name.isEmpty || srcs is! List || srcs.isEmpty) continue;
      final sources = <ProviderSource>[];
      for (final s in srcs) {
        if (s is String && s.isNotEmpty) sources.add(_src(s));
      }
      if (sources.isEmpty) continue;
      final hours = item['hours'];
      out.add(ProviderDef(id, name, item['enabled'] == true, hours is int && hours > 0 ? hours : 6, sources));
    }
    return out.isEmpty ? null : out;
  } catch (_) {
    return null;
  }
}

/// Embedded Unlimited configs, from the repo secret UNLIMITED_CONFIGS
/// (base64 in dart-define UNLIMITED_B64, one config link per line).
/// These need no update at all: they are baked into the build, pinged
/// and tried like any other provider config. The secret itself is never
/// written into code or into the workflow file, only read at build time.
List<String> unlimitedEmbeddedLinks() {
  const b64 = String.fromEnvironment('UNLIMITED_B64');
  if (b64.isEmpty) return [];
  try {
    final raw = utf8.decode(base64Decode(b64));
    final re = RegExp(r'^(vless|vmess|trojan|ss|hysteria2|hy2)://');
    final seen = <String>{};
    final out = <String>[];
    for (final part in raw.split(RegExp(r'\s+'))) {
      final s = part.trim();
      if (s.isNotEmpty && re.hasMatch(s) && seen.add(s)) out.add(s);
    }
    return out;
  } catch (_) {
    return [];
  }
}

/// One subscription URL inside a provider. [label] comes from a '#fragment'
/// on the URL itself (used by Hiddify-style sources as a per-link display name)
/// and is never sent in the HTTP request.
class ProviderSource {
  final String url;
  final String? label;
  const ProviderSource(this.url, [this.label]);
}

class ProviderDef {
  final String id, name;
  final bool defaultEnabled;
  final int refreshHours;
  final List<ProviderSource> sources;
  const ProviderDef(this.id, this.name, this.defaultEnabled, this.refreshHours, this.sources);
}

ProviderSource _src(String raw) {
  final h = raw.indexOf('#');
  if (h < 0) return ProviderSource(raw);
  final url = raw.substring(0, h);
  var label = raw.substring(h + 1);
  try {
    label = Uri.decodeComponent(label);
  } catch (_) {}
  return ProviderSource(url, label.isEmpty ? null : label);
}

/// The five providers, their sources, and defaults, exactly as specified.
final List<ProviderDef> _fallbackProviders = [
  const ProviderDef('v2rayag', 'V2rayAG Exclusive', true, 6, [
    ProviderSource('https://raw.githubusercontent.com/alireza-spec/V2rayAGsub/main/sub.txt'),
  ]),
  ProviderDef('fast', 'Fast', false, 24, [
    _src('https://api.jetnox.co/sub/87a4cabf-3290-4d46-8851-79213c1cadff'),
    _src('https://api.jetnox.co/sub/a09ff82b-984f-4777-a798-ecb7756f9bf1'),
    _src('https://api.jetnox.co/sub/ccbd45cb-5200-449e-9e0b-005e9573213d'),
    _src('https://api.jetnox.co/sub/abf26d87-37b8-40c1-9a6e-9ac0f1348795'),
    _src('https://api.jetnox.co/sub/0481a614-1e7e-42a8-9f18-ca9e084e739a'),
    _src('https://api.jetnox.co/sub/4293f8a1-dbde-4ce9-a602-a1fc1d52445a'),
    _src('https://api.jetnox.co/sub/73c6b0a7-83e7-4f89-a7e2-34217f29aff0'),
    _src('https://api.jetnox.co/sub/3fd10f87-6b74-4a8a-bea7-61014b0cf8ac'),
  ]),
  ProviderDef('update', 'Update', false, 6, [
    _src('https://yamyamproxyy.github.io/Yamyamproxy/data/sub.txt'),
    _src('https://raw.githubusercontent.com/Created-By/Telegram-Eag1e_YT/main/%40Eag1e_YT'),
    _src('https://sub.namazvpn.workers.dev'),
    _src('https://bot.kahrobas.shop/sub.txt'),
    _src('https://gitverse.ru/api/repos/bikinitw22/apelsintel/raw/branch/main/alive_full.txt'),
  ]),
  ProviderDef('antifilter', 'Anti-Filter', false, 6, [
    _src('https://raw.githubusercontent.com/0xRadikal/Free-v2ray-Configs/main/verified/configs.txt'),
    _src('https://raw.githubusercontent.com/ZendanTeam/SS44-sub/main/SS44-gold.txt'),
    _src('https://raw.githubusercontent.com/ZendanTeam/SS44-sub/main/SS44.txt'),
    _src('https://raw.githubusercontent.com/ZendanTeam/SS44-sub/main/SS44-udp.txt'),
    _src('https://raw.githubusercontent.com/Bllare/V2ray-Configs/main/ALL.txt'),
    _src('https://github.com/Epodonios/v2ray-configs/raw/main/All_Configs_Sub.txt'),
    _src('https://raw.githubusercontent.com/Epodonios/v2ray-configs/main/Splitted-By-Protocol/vless.txt'),
    _src('https://raw.githubusercontent.com/morpheusadam/v2ray-config/main/subs/bundles/iran.txt'),
    _src('https://raw.githubusercontent.com/morpheusadam/v2ray-config/main/subs/bundles/best.txt'),
    _src('https://raw.githubusercontent.com/Alirewa/V2ray-Configs/main/sub1.txt'),
    _src('https://raw.githubusercontent.com/barry-far/V2ray-Config/main/Sub1.txt'),
    _src('https://raw.githubusercontent.com/IranV2raysub/sub/refs/heads/main/sub'),
    _src('https://raw.githubusercontent.com/mehrdadmb2/V2ray_Sub/refs/heads/main/Mix.txt'),
  ]),
  ProviderDef('hiddify', 'Hiddify', false, 6, [
    _src('https://raw.githubusercontent.com/4n0nymou3/multi-proxy-config-fetcher/refs/heads/main/configs/proxy_configs.txt#Anonymous%20%F0%9D%95%8F'),
    _src('https://raw.githubusercontent.com/patterniha/Free-Configs/refs/heads/main/configs.txt#Patterniha'),
    _src('https://raw.githubusercontent.com/hiddify/hiddify-app/refs/heads/main/test.configs/mahsa#Mahsa'),
  ]),
];

/// One provider from a single JSON object, as used by the per-provider
/// secrets (see below). Returns null when the object is unusable, so a
/// bad single secret never wipes out the other providers.
ProviderDef? _providerFromObject(dynamic item) {
  try {
    if (item is! Map) return null;
    final id = '${item['id'] ?? ''}';
    final name = '${item['name'] ?? ''}';
    final srcs = item['sources'];
    if (id.isEmpty || name.isEmpty) return null;
    // Lenient: sources may be a list (normal) or a single string.
    final rawSrcs = srcs is String ? [srcs] : (srcs is List ? srcs : null);
    if (rawSrcs == null || rawSrcs.isEmpty) return null;
    final sources = <ProviderSource>[];
    for (final s in rawSrcs) {
      if (s is String && s.isNotEmpty) sources.add(_src(s));
    }
    if (sources.isEmpty) return null;
    final hours = item['hours'];
    final enabled = item['enabled'] == true || item['enabled'] == 'true';
    return ProviderDef(id, name, enabled, hours is int && hours > 0 ? hours : 6, sources);
  } catch (_) {
    return null;
  }
}

/// Parses one per-provider secret value (already base64-decoded).
/// Accepted shapes, in order:
///   1. A JSON object: {"id": "...", "name": "...", "enabled": true,
///      "hours": 6, "sources": ["https://...", ...]}
///   2. A JSON array holding exactly one such object.
///   3. A JSON array of URL strings: ["https://...", "https://..."]
///      (the shape a user naturally pastes for a provider with
///      several subs).
///   4. Plain text: subscription URLs separated by whitespace and/or
///      commas, optionally wrapped in brackets, quotes or angle
///      brackets (the shape a user naturally pastes when they "put
///      the sub link" in the secret). The provider id/name then come
///      from the secret itself: the define for that provider maps to
///      that provider id with its usual display name.
///   5. One extra base64 layer around any of the above (a value the
///      user encoded by hand on top of the workflow's encoding).
/// Anything else yields null and the provider is left as-is, so a bad
/// single secret never wipes out the other providers.
ProviderDef? _parseSingleProviderSecret(String raw, String fallbackId, String fallbackName) {
  return _parseSingleProviderSecretDepth(raw, fallbackId, fallbackName, 0);
}

ProviderDef? _parseSingleProviderSecretDepth(String raw, String fallbackId, String fallbackName, int depth) {
  var text = raw.trim();
  if (text.startsWith('\uFEFF')) text = text.substring(1).trim();
  if (text.isEmpty) return null;
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) return _providerFromObject(decoded);
    if (decoded is List) {
      if (decoded.length == 1 && decoded.first is Map) return _providerFromObject(decoded.first);
      // Array of URL strings: every element must be a string, and
      // every string must be a URL; anything else stays rejected.
      if (decoded.isNotEmpty && decoded.every((e) => e is String)) {
        final sources = <ProviderSource>[];
        for (final s in decoded.cast<String>()) {
          final u = _stripLinkWrapping(s);
          if (u.startsWith('http://') || u.startsWith('https://')) sources.add(_src(u));
        }
        if (sources.length == decoded.length) return ProviderDef(fallbackId, fallbackName, true, 6, sources);
      }
    }
  } catch (_) {
    // Not JSON: fall through to the plain-URL shape below.
  }
  final sources = <ProviderSource>[];
  for (final part in text.split(RegExp(r'[\s,]+'))) {
    final u = _stripLinkWrapping(part);
    if (u.startsWith('http://') || u.startsWith('https://')) sources.add(_src(u));
  }
  if (sources.isNotEmpty) return ProviderDef(fallbackId, fallbackName, true, 6, sources);
  // Last resort: the value itself may be base64 (double-encoded by
  // hand on top of the workflow's encoding). Try one decode and
  // re-parse; never recurse deeper.
  if (depth == 0) {
    try {
      final compact = text.replaceAll(RegExp(r'\s+'), '');
      final padded = compact + '=' * ((4 - compact.length % 4) % 4);
      final decodedText = utf8.decode(base64Decode(padded));
      if (decodedText.contains('http')) {
        return _parseSingleProviderSecretDepth(decodedText, fallbackId, fallbackName, 1);
      }
    } catch (_) {}
  }
  return null;
}

/// Strips wrapping punctuation users often paste around a link
/// (brackets, quotes, angle brackets, parens) without touching the
/// URL itself: subscription URLs never start or end with these.
String _stripLinkWrapping(String s) {
  const wraps = ['[', ']', '(', ')', '"', "'", '<', '>'];
  var out = s.trim();
  while (out.isNotEmpty && wraps.contains(out[0])) {
    out = out.substring(1);
  }
  while (out.isNotEmpty && wraps.contains(out[out.length - 1])) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}

/// One status line per per-provider secret, for the app's Logs screen.
/// Names and counts only: secret VALUES are never logged. Lets the user
/// see at a glance whether a secret was picked up or silently ignored.
List<String> providerSecretDiagnostics() {
  String describe(String secretName, String b64, String fallbackId, String fallbackName) {
    if (b64.isEmpty) return 'Provider secret $secretName: not set';
    ProviderDef? p;
    try {
      p = _parseSingleProviderSecret(utf8.decode(base64Decode(b64)), fallbackId, fallbackName);
    } catch (_) {
      p = null;
    }
    if (p == null) return 'Provider secret $secretName: ignored (unusable value)';
    return 'Provider secret $secretName: ok (id=${p.id}, ${p.sources.length} sources)';
  }

  return [
    describe('PROVIDER_FAST', const String.fromEnvironment('PROVIDER_FAST_B64'), 'fast', 'Fast'),
    describe('PROVIDER_UPDATE', const String.fromEnvironment('PROVIDER_UPDATE_B64'), 'update', 'Update'),
    describe('PROVIDER_V2RAYAG', const String.fromEnvironment('PROVIDER_V2RAYAG_B64'), 'v2rayag', 'V2rayAG Exclusive'),
    describe('PROVIDER_ANTIFILTER', const String.fromEnvironment('PROVIDER_ANTIFILTER_B64'), 'antifilter', 'Anti-Filter'),
    describe('PROVIDER_HIDDIFY', const String.fromEnvironment('PROVIDER_HIDDIFY_B64'), 'hiddify', 'Hiddify'),
    describe('PROVIDER_AI', const String.fromEnvironment('PROVIDER_AI_B64'), 'ai', 'AI'),
    describe('PROVIDER_UNLIMITED', const String.fromEnvironment('PROVIDER_UNLIMITED_B64'), 'unlimited', 'Unlimited'),
  ];
}

/// Per-provider secrets: one GitHub secret per provider, so one provider
/// can be added, removed or changed without touching the others and
/// without them getting mixed up. Each secret accepts a JSON object
/// (same shape as one entry of PROVIDERS_JSON), a JSON array holding
/// exactly one such object, or plain subscription URLs, one per line
/// (see _parseSingleProviderSecret). Secret names:
///   PROVIDER_FAST, PROVIDER_UPDATE, PROVIDER_V2RAYAG,
///   PROVIDER_ANTIFILTER, PROVIDER_HIDDIFY, PROVIDER_AI
/// (PROVIDER_UNLIMITED was removed 2026-10-29: the user replaced the
/// Unlimited provider with an AI provider, so no built-in Unlimited
/// entry remains; re-adding a PROVIDER_UNLIMITED secret would append
/// it back via the override logic below.)
/// Each is passed base64 as dart-define PROVIDER_<ID>_B64. A set
/// per-provider secret replaces that one provider in the list; the
/// combined PROVIDERS_JSON list (when set) is the base it replaces
/// into, and the built-in list is the base when neither is set.
/// Display, refresh and connection behaviour are unchanged: the app
/// still runs all providers together, in the same priority order.
List<ProviderDef> _applyPerProviderSecrets(List<ProviderDef> base) {
  // String.fromEnvironment needs a constant name, so each define is
  // read explicitly below.
  final overrides = <String, ProviderDef>{};
  ProviderDef? read(String b64, String fallbackId, String fallbackName) {
    if (b64.isEmpty) return null;
    try {
      return _parseSingleProviderSecret(utf8.decode(base64Decode(b64)), fallbackId, fallbackName);
    } catch (_) {
      return null;
    }
  }

  final fast = read(const String.fromEnvironment('PROVIDER_FAST_B64'), 'fast', 'Fast');
  if (fast != null) overrides[fast.id] = fast;
  final update = read(const String.fromEnvironment('PROVIDER_UPDATE_B64'), 'update', 'Update');
  if (update != null) overrides[update.id] = update;
  final v2rayag = read(const String.fromEnvironment('PROVIDER_V2RAYAG_B64'), 'v2rayag', 'V2rayAG Exclusive');
  if (v2rayag != null) overrides[v2rayag.id] = v2rayag;
  final antifilter = read(const String.fromEnvironment('PROVIDER_ANTIFILTER_B64'), 'antifilter', 'Anti-Filter');
  if (antifilter != null) overrides[antifilter.id] = antifilter;
  final hiddify = read(const String.fromEnvironment('PROVIDER_HIDDIFY_B64'), 'hiddify', 'Hiddify');
  if (hiddify != null) overrides[hiddify.id] = hiddify;
  final ai = read(const String.fromEnvironment('PROVIDER_AI_B64'), 'ai', 'AI');
  if (ai != null) overrides[ai.id] = ai;
  final unlimited = read(const String.fromEnvironment('PROVIDER_UNLIMITED_B64'), 'unlimited', 'Unlimited');
  if (unlimited != null) overrides[unlimited.id] = unlimited;
  if (overrides.isEmpty) return base;
  final out = base.map((p) => overrides[p.id] ?? p).toList();
  for (final entry in overrides.entries) {
    if (!out.any((p) => p.id == entry.key)) out.add(entry.value);
  }
  return out;
}

/// The effective provider list: per-provider secrets override single
/// entries, the combined secret wins when it is set and valid,
/// otherwise the built-in fallback below is used (never an empty list).
final List<ProviderDef> kProviders = _applyPerProviderSecrets(_secretProviders() ?? _fallbackProviders);

/// A provider's configs, ready for the engine to try, in priority order.
class ProviderBundle {
  final String id, name;
  final List<String> links;
  ProviderBundle(this.id, this.name, this.links);
}

typedef BundleFetcher = Future<List<ProviderBundle>> Function();
