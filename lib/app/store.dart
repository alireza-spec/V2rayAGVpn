import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;

import '../engine/fronting.dart';
import '../engine/native.dart';
import '../engine/pool_engine.dart';
import '../engine/speed_test.dart';
import '../engine/psiphon_engine.dart';
import '../engine/providers.dart';
import '../engine/scanner.dart';
import '../engine/tcp_probe.dart';
import '../engine/vpn_core.dart';

const kBuildNum = String.fromEnvironment('BUILD_NUM', defaultValue: '0');

const _tr = <String, List<String>>{
  'home': ['Home', 'خانه'],
  'servers': ['Servers', 'سرورها'],
  'subs': ['Subscriptions', 'اشتراک‌ها'],
  'tools': ['Tools', 'ابزارها'],
  'settings': ['Settings', 'تنظیمات'],
  'auto': ['Automatic', 'خودکار'],
  'smart': ['Smart', 'هوشمند'],
  'cdn': ['CDN Fronting', 'فرانتینگ CDN'],
  'personal': ['Personal', 'شخصی'],
  'mode': ['CONNECTION MODE', 'حالت اتصال'],
  'auto_d': ['Connects you to the best server in the V2rayAG pool. No setup needed.', 'شما را به بهترین سرور مجموعه V2rayAG وصل می‌کند. بدون نیاز به تنظیمات.'],
  'smart_d': ['Tries providers, then CDN, then Psiphon automatically, until one carries real traffic.', 'خودکار پروایدرها، بعد CDN، بعد سایفون را امتحان می‌کند تا یکی واقعاً ترافیک بدهد.'],
  'cdn_d': ['Uses CDN configs with your clean IP and host from Tools.', 'از کانفیگ‌های CDN با آی‌پی تمیز و هاست شما از بخش ابزارها استفاده می‌کند.'],
  'personal_d': ['Uses only the servers and subscriptions you added.', 'فقط از سرورها و اشتراک‌هایی که خودتان اضافه کرده‌اید استفاده می‌کند.'],
  'pool': ['Pool', 'مجموعه'],
  'connected': ['CONNECTED', 'متصل'],
  'notconn': ['NOT CONNECTED', 'قطع'],
  'server': ['Server', 'سرور'],
  'ip': ['IP address', 'آدرس IP'],
  'loc': ['Location', 'موقعیت'],
  'ping': ['Ping', 'پینگ'],
  'time': ['Time', 'زمان'],
  'down': ['Download', 'دانلود'],
  'up': ['Upload', 'آپلود'],
  'total': ['Total volume', 'حجم کل'],
  'remain': ['Remaining', 'باقیمانده'],
  'expires': ['Expires', 'انقضا'],
  'left': ['Time left', 'زمان باقیمانده'],
  'unl': ['Unlimited', 'نامحدود'],
  'never': ['Never', 'ندارد'],
  'nousage': ['No usage info', 'اطلاعات مصرف موجود نیست'],
  'addfirst': ['Add a server or subscription first', 'ابتدا سرور یا اشتراک اضافه کنید'],
  'paste': ['Paste', 'چسباندن'],
  'test': ['Test all', 'تست همه'],
  'sort': ['Sort by ping', 'مرتب‌سازی با پینگ'],
  'copy': ['Copy', 'کپی'],
  'delete': ['Delete', 'حذف'],
  'connect': ['Connect', 'اتصال'],
  'psiphon': ['Psiphon', 'سایفون'],
  'connecting': ['CONNECTING', 'در حال اتصال'],
  'psisettings': ['Psiphon settings', 'تنظیمات سایفون'],
  'psivpn': ['Whole device (VPN)', 'کل گوشی (VPN)'],
  'psivpn_h': ['Route the whole phone through Psiphon: Android shows the VPN key icon and every app uses the tunnel, not just apps with their own proxy setting. Takes effect on the next connect. If VPN mode fails to start, Psiphon keeps working as a local proxy.', 'کل گوشی را از سایفون رد کن: اندروید آیکن کلید VPN را نشان می‌دهد و همه اپ‌ها از تونل استفاده می‌کنند، نه فقط اپ‌هایی که خودشان پروکسی دارند. از اتصال بعدی اعمال می‌شود. اگر حالت VPN شروع نشد، سایفون همچنان به‌صورت پروکسی محلی کار می‌کند.'],
  'psivpn_on': ['VPN mode: whole device routes through Psiphon', 'حالت VPN: کل گوشی از سایفون رد می‌شود'],
  'psi_proxy_use': ['Use Psiphon in other apps (proxy)', 'استفاده از سایفون در اپ‌های دیگر (پروکسی)'],
  'psi_proxy_how': ['Psiphon here is a local proxy, not a system VPN, so other apps do not use it automatically. In an app that supports proxies (for example Telegram: Settings → Data and Storage → Proxy → Add Proxy), add a SOCKS5 proxy with the address below while Psiphon is connected. Android only shows the VPN key icon for a system VPN, so its absence here does not mean the tunnel is broken.', 'سایفون در اینجا پروکسی محلی است، نه VPN سیستمی، پس بقیه اپ‌ها خودکار از آن استفاده نمی‌کنند. در اپی که پروکسی پشتیبانی می‌کند (مثلاً تلگرام: تنظیمات → داده و حافظه → پروکسی → افزودن پروکسی)، یک پروکسی SOCKS5 با آدرس زیر اضافه کن، وقتی سایفون متصل است. آیکن کلید VPN اندروید فقط برای VPN سیستمی نشان داده می‌شود، پس نبودنش به معنی خراب بودن تونل نیست.'],
  'psi_proxy_copy': ['Copy proxy address', 'کپی آدرس پروکسی'],
  'testurl2': ['Real delay test URL', 'آدرس تست تأخیر واقعی'],
  'testurl2_h': ['Used for real-traffic ping tests (like V2rayNG true delay). Leave the default unless you know a better endpoint.', 'برای تست پینگ با ترافیک واقعی استفاده می‌شود (مثل true delay در V2rayNG). مگر اینکه آدرس بهتری بشناسید، پیش‌فرض را عوض نکنید.'],
  'autosort': ['Auto sort after testing', 'مرتب‌سازی خودکار پس از تست'],
  'autosort_h': ['Sort configs by ping after a test finishes. Turn off to keep the original order.', 'پس از پایان تست، کانفیگ‌ها بر اساس پینگ مرتب شوند. با خاموش کردن، ترتیب اصلی حفظ می‌شود.'],
  'deleteconfirm': ['Delete config confirmation', 'تأیید حذف کانفیگ'],
  'deleteconfirm_h': ['Ask before deleting a single config. Delete-all already asks.', 'پیش از حذف یک کانفیگ بپرسد. حذف همه از قبل تأیید می‌خواهد.'],
  'psiphon_d': ['Independent emergency transport (Psiphon). Starts with a built-in public bootstrap, like other Psiphon apps. Only real traffic through the tunnel counts as connected.', 'انتقال اضطراری مستقل (سایفون). با بوت‌استرپ عمومی داخلی شروع می‌شود، مثل بقیه اپ‌های سایفونی. فقط ترافیک واقعی از تونل، به‌معنای متصل بودن است.'],
  'psiphon_hint': ['Psiphon is trying servers one by one. On a filtered network this can take several minutes, and some networks block every server. Logs show each attempt.', 'سایفون دارد سرورها را یکی‌یکی امتحان می‌کند. در شبکه‌های فیلترشده این کار چند دقیقه طول می‌کشد و بعضی شبکه‌ها همه سرورها را مسدود می‌کنند. جزئیات هر تلاش در لاگ‌هاست.'],
  'psi_proxy_warn': ['Psiphon is a local proxy, NOT a system VPN: your browser and other apps do NOT use it automatically, so a browser page will not load through it even while Psiphon shows connected. Use the in-app speed test to check the tunnel itself.', 'سایفون یک پروکسی محلی است، نه VPN سیستمی: مرورگر و بقیه اپ‌ها خودکار از آن استفاده نمی‌کنند، پس حتی وقتی سایفون متصل نشان می‌دهد، صفحه مرورگر از آن رد نمی‌شود. برای بررسی خود تونل، از تست سرعت داخل اپ استفاده کن.'],
  'trafficfailed': ['Traffic failed', 'ترافیک نگرفت'],
  'deselectall': ['Deselect all', 'لغو انتخاب همه'],
  'retry': ['Retry', 'تلاش دوباره'],
  'psi_mode': ['Psiphon Mode', 'حالت سایفون'],
  'psi_mode_vpn': ['VPN (whole device)', 'VPN (کل گوشی)'],
  'psi_mode_proxy': ['Proxy (local only)', 'پروکسی (فقط محلی)'],
  'psi_mode_proxy_h': ['Only apps with their own proxy setting use Psiphon. No VPN key icon.', 'فقط اپ‌هایی که خودشان تنظیم پروکسی دارند از سایفون استفاده می‌کنند. آیکن کلید VPN ندارد.'],
  'psi_country': ['Country', 'کشور'],
  'psi_country_h': ['Psiphon will only try servers in this country. Takes effect on the next connect.', 'سایفون فقط سرورهای این کشور را امتحان می‌کند. از اتصال بعدی اعمال می‌شود.'],
  'all_regions': ['All regions', 'همه مناطق'],
  'close': ['Close', 'بستن'],
  'psisetup': ['Psiphon setup', 'تنظیم سایفون'],
  'psisetup_h': ['Psiphon starts with its built-in public bootstrap, so the tunnel itself needs no setup. Choose the mode and the country below; they take effect on the next connect.', 'سایفون با بوت‌استرپ عمومی داخلی شروع می‌شود، پس خود تونل نیازی به تنظیم ندارد. حالت و کشور را پایین انتخاب کن؛ از اتصال بعدی اعمال می‌شوند.'],
  'psi_mode_combo': ['Psiphon+V2ray', 'سایفون + V2ray'],
  'psi_combo_h': ['Chain a V2Ray config through the Psiphon tunnel: the config is reached through Psiphon, so it works where the config alone is blocked. Connects as a VPN, with the key icon.', 'یک کانفیگ V2ray را از تونل سایفون رد کن: کانفیگ از طریق سایفون به سرورش می‌رسد، پس جایی که کانفیگ تنها مسدود است کار می‌کند. به‌صورت VPN وصل می‌شود، با آیکن کلید.'],
  'psi_combo_links': ['V2Ray configs', 'کانفیگ‌های V2ray'],
  'psi_combo_links_h': ['Enter one config per line. They are tried in order, with a long timeout each, until one connects.', 'هر خط یک کانفیگ. به ترتیب امتحان می‌شوند، هر کدام با تایم‌اوت طولانی، تا یکی وصل شود.'],
  'psi_combo_useapp': ['Use the app\'s configs', 'استفاده از کانفیگ‌های اپ'],
  'psi_combo_useapp_h': ['Try the provider pool instead of your own configs: configs that already ping well first, then the next ones, never repeating within one attempt.', 'به‌جای کانفیگ‌های خودت، از مجموعه پروایدرها امتحان کن: اول کانفیگ‌هایی که پینگ خوبی دارند، بعد بعدی‌ها، بدون تکرار در یک تلاش.'],
  'psi_combo_on': ['Psiphon+V2ray Connected', 'سایفون + V2ray متصل شد'],
  'psi_combo_need': ['Enter at least one config, or turn on "Use the app\'s configs".', 'دست‌کم یک کانفیگ وارد کن، یا «استفاده از کانفیگ‌های اپ» را روشن کن.'],
  'psi_combo_nopool': ['No provider configs available. Refresh providers, or paste your own configs.', 'کانفیگی از پروایدرها در دسترس نیست. پروایدرها را به‌روز کن، یا کانفیگ خودت را وارد کن.'],
  'psi_combo_fail': ['Psiphon+V2ray: no config connected. Psiphon local proxy still works.', 'سایفون + V2ray: هیچ کانفیگی وصل نشد. پروکسی محلی سایفون هنوز کار می‌کند.'],
  'psi_proxy_local': ['Local proxy (default)', 'پروکسی محلی (پیش‌فرض)'],
  'psi_proxy_custom': ['Custom Proxy', 'پروکسی سفارشی'],
  'psi_proxy_custom_h': ['Psiphon connects through your own SOCKS proxy below, instead of dialing directly.', 'سایفون به‌جای اتصال مستقیم، از طریق پروکسی SOCKS خودت که پایین می‌دهی وصل می‌شود.'],
  'psi_proxy_ip': ['Proxy IP', 'آیپی پروکسی'],
  'psi_proxy_port': ['Proxy port', 'پورت پروکسی'],
  'ping_h': ['Ping is measured through the Psiphon tunnel, to an external endpoint, not to the Psiphon server itself.', 'پینگ از طریق تونل سایفون و به یک سرور خارجی اندازه‌گیری می‌شود، نه خود سرور سایفون.'],

  'providers': ['Subscription providers', 'ارائه‌دهندگان اشتراک'],
  'providers_h': ['Choose which providers Automatic is allowed to use, and the order it tries them in.', 'انتخاب کنید خودکار از کدام ارائه‌دهندگان و با چه ترتیبی استفاده کند.'],
  'updateselected': ['Update selected', 'به‌روزرسانی انتخاب‌شده‌ها'],
  'updateall': ['Update all', 'به‌روزرسانی همه'],
  'configs': ['configs', 'کانفیگ'],
  'lastupdate': ['Updated', 'به‌روزرسانی شد'],
  'noneyet': ['not yet', 'هنوز نشده'],
  'fastlimit': ['once a day', 'یک‌بار در روز'],
  'enabledcount': ['enabled', 'فعال'],
  'trynext': ['Try next subscription', 'امتحان اشتراک بعدی'],
  'nomoresubs': ['No more subscriptions to try. Add or enable another one.', 'اشتراک دیگری برای امتحان نیست. یکی دیگر اضافه یا فعال کنید.'],
  'navigate': ['NAVIGATE', 'پیمایش'],
  'shortcuts': ['SHORTCUTS', 'میانبرها'],
  'quick': ['QUICK SETTINGS', 'تنظیمات سریع'],
  'aboutsec': ['ABOUT', 'درباره'],
  'update': ['Check for updates', 'بررسی به‌روزرسانی'],
  'share': ['Share the app', 'اشتراک‌گذاری برنامه'],
  'openapp': ['Open', 'باز کردن'],
  'scan_h': ['Three stages on your own network: a quick probe, five repeat probes on the fastest, then a real download. Only stable IPs are kept.', 'سه مرحله روی اینترنت خودتان: بررسی سریع، پنج بار تکرار روی سریع‌ترین‌ها، و سپس دانلود واقعی. فقط آی‌پی‌های پایدار می‌مانند.'],
  'updateranges': ['Update ranges', 'به‌روزرسانی رنج‌ها'],
  'usebest': ['Use the best', 'استفاده از بهترین'],
  'copytop': ['Copy top 20', 'کپی ۲۰ تای برتر'],
  'stage1': ['Stage 1 of 3: quick probe', 'مرحله ۱ از ۳: بررسی سریع'],
  'stage2': ['Stage 2 of 3: stability (5 tries each)', 'مرحله ۲ از ۳: پایداری (۵ بار برای هر کدام)'],
  'stage3': ['Stage 3 of 3: real download speed', 'مرحله ۳ از ۳: سرعت دانلود واقعی'],
  'conntype': ['Connection type', 'نوع اتصال'],
  'conntype_h': ['VPN tunnels the whole phone. Proxy only opens a local proxy (127.0.0.1) that apps can be pointed to.', 'وی‌پی‌ان کل گوشی را تونل می‌کند. پروکسی فقط یک پروکسی محلی (127.0.0.1) باز می‌کند که برنامه‌ها به آن وصل می‌شوند.'],
  'vpnmode': ['VPN', 'وی‌پی‌ان'],
  'proxymode': ['Proxy 127.0.0.1', 'پروکسی 127.0.0.1'],
  'strict': ['Strict traffic check', 'بررسی دقیق ترافیک'],
  'strict_h': ['Only show Connected when the server really answers. Turn off only to troubleshoot.', 'فقط وقتی سرور واقعاً پاسخ می‌دهد متصل نشان بده. فقط برای عیب‌یابی خاموش کنید.'],
  'apps': ['Apps', 'برنامه‌ها'],
  'apps_all': ['All apps use the VPN', 'همه برنامه‌ها از وی‌پی‌ان استفاده می‌کنند'],
  'apps_only': ['Only selected apps use the VPN', 'فقط برنامه‌های انتخاب‌شده از وی‌پی‌ان استفاده می‌کنند'],
  'apps_except': ['Selected apps skip the VPN', 'برنامه‌های انتخاب‌شده از وی‌پی‌ان عبور می‌کنند'],
  'search': ['Search apps', 'جستجوی برنامه‌ها'],
  'selectall': ['Select all', 'انتخاب همه'],
  'clearsel': ['Clear', 'پاک کردن'],
  'userapps': ['User', 'کاربر'],
  'sysapps': ['System', 'سیستم'],
  'chosen': ['Selected', 'انتخاب‌شده'],
  'proxyinfo': ['Local proxy', 'پروکسی محلی'],
  'deleteall': ['Delete all', 'حذف همه'],
  'deleteinvalid': ['Delete invalid', 'حذف نامعتبرها'],
  'testfirst': ['Test the configs first', 'ابتدا کانفیگ‌ها را تست کنید'],
  'cdnsetup': ['CDN Fronting setup', 'تنظیم فرانتینگ CDN'],
  'cdncfg': ['CDN configs (optional)', 'کانفیگ‌های CDN (اختیاری)'],
  'cdncfg_h': ['Paste vless / trojan / vmess WebSocket or gRPC configs that sit behind a CDN. Leave empty to use the pool.', 'کانفیگ‌های وی‌لس / تروجان / وی‌مس وب‌سوکت یا gRPC پشت CDN را بچسبانید. خالی بگذارید تا از مجموعه استفاده شود.'],
  'fragment': ['TLS fragment', 'فرگمنت TLS'],
  'fragment_h': ['Cuts the TLS hello into pieces so filtering cannot read the host name. This is how MahsaNG bypasses Iranian operators.', 'پیام TLS را تکه‌تکه می‌کند تا فیلترینگ نتواند نام هاست را بخواند. مهسا‌ان‌جی هم همین‌طور از اپراتورهای ایران عبور می‌کند.'],
  'fraglen': ['Fragment length', 'طول فرگمنت'],
  'fragint': ['Interval (ms)', 'فاصله (میلی‌ثانیه)'],
  'fragall': ['Use fragment in all modes', 'استفاده از فرگمنت در همه حالت‌ها'],
  'save': ['Save and connect', 'ذخیره و اتصال'],
  'tun': ['VPN interface', 'رابط VPN'],
  'active': ['Active', 'فعال'],
  'missing': ['Not found', 'یافت نشد'],
  'copyall': ['Copy all', 'کپی همه'],
  'delsub': ['Delete subscription', 'حذف اشتراک'],
  'testsub': ['Test ping', 'تست پینگ'],
  'usesub': ['Use this subscription', 'استفاده از این اشتراک'],
  'volume': ['Volume', 'حجم'],
  'inuse': ['In use', 'در حال استفاده'],
  'nocfg': ['No configs yet. Tap refresh.', 'هنوز کانفیگی نیست. به‌روزرسانی را بزنید.'],
  'clean_h': ['Leave empty to use each config as it is.', 'خالی بگذارید تا هر کانفیگ همان‌طور که هست استفاده شود.'],
  'disconnect': ['Disconnect', 'قطع اتصال'],
  'hosts': ['Host / SNI finder', 'یابنده هاست / SNI'],
  'hosttest': ['Find the best host for my network', 'بهترین هاست را برای شبکه من پیدا کن'],
  'hostnote': ['Tests real handshakes on your own internet, so the result fits your operator.', 'روی اینترنت خودتان تست واقعی انجام می‌دهد، پس برای اپراتور شما مناسب است.'],
  'selftest': ['Core self-test', 'آزمون هسته'],
  'realip': ['IP before VPN', 'آی‌پی قبل از VPN'],
  'speedtest': ['Speed test', 'تست سرعت'],
  'speedneedconn': ['Connect to a server first to run a speed test.', 'برای تست سرعت اول به یک سرور وصل شو.'],
  'history': ['History', 'تاریخچه'],
  'retest': ['Retest', 'تست دوباره'],
  'step1': ['Pool', 'مجموعه'],
  'step2': ['Test', 'تست'],
  'step3': ['Connect', 'اتصال'],
  'step4': ['Verify', 'تأیید'],
  'subtext': ['Copy as sub', 'کپی به صورت ساب'],
  'empty': ['Nothing here yet. Tap Paste to add configs or subscription links.', 'هنوز چیزی نیست. برای افزودن کانفیگ یا لینک اشتراک روی چسباندن بزنید.'],
  'favorites': ['Favorites', 'موردعلاقه‌ها'],
  'nofav': ['Add a config to favorites first', 'اول یک کانفیگ را به موردعلاقه‌ها اضافه کن'],
  'favdelall': ['Delete all favorites', 'حذف همه موردعلاقه‌ها'],
  'added': ['Added', 'اضافه شد'],
  'copied': ['Copied', 'کپی شد'],
  'selected': ['Selected. Go to Home and tap the button.', 'انتخاب شد. به خانه بروید و دکمه را بزنید.'],
  'addsub': ['Add subscription', 'افزودن اشتراک'],
  'refresh': ['Refresh', 'به‌روزرسانی'],
  'import': ['Import configs', 'وارد کردن کانفیگ‌ها'],
  'profiles': ['Profiles', 'پروفایل‌ها'],
  'mkprofile': ['Create profile from selected servers', 'ساخت پروفایل از سرورهای انتخاب‌شده'],
  'name': ['Name', 'نام'],
  'use': ['Use', 'استفاده'],
  'fronting': ['CDN Fronting', 'فرانتینگ CDN'],
  'cleanip': ['Clean IP', 'آی‌پی تمیز'],
  'fronthost': ['Host / SNI domain', 'دامنه هاست / SNI'],
  'scanner': ['Clean IP scanner', 'اسکنر آی‌پی تمیز'],
  'start': ['Start', 'شروع'],
  'stop': ['Stop', 'توقف'],
  'scanned': ['Scanned', 'اسکن‌شده'],
  'found': ['Found', 'یافت‌شده'],
  'myip': ['Check my IP', 'بررسی IP من'],
  'language': ['Language', 'زبان'],
  'theme': ['Theme', 'پوسته'],
  'accent': ['Accent color', 'رنگ تأکید'],
  'testurl': ['Bypass apps (package names)', 'برنامه‌های خارج از VPN (نام بسته)'],
  'logs': ['Logs', 'گزارش‌ها'],
  'about': ['About', 'درباره'],
  'dev': ['Developer: Alireza Ahmadi (HashtagAlireza)', 'توسعه‌دهنده: علیرضا احمدی (HashtagAlireza)'],
  'reset': ['Reset all data', 'بازنشانی همه داده‌ها'],
  'clear': ['Clear', 'پاک کردن'],
  'cancel': ['Cancel', 'انصراف'],
  'ok': ['OK', 'تأیید'],
  'link': ['Subscription link', 'لینک اشتراک'],
};

class Store extends ChangeNotifier {
  Store(this.core, this.pool) {
    engine = PoolEngine(core, poolUrls: pool)..log = log;
    psiphon = PsiphonEngine()..log = log;
    psiphon.states.listen((e) {
      notifyListeners();
      // v48: persist the Psiphon session on phase transitions only
      // (never on the 1s live ticks), so reopening the app can
      // restore it. Connecting keeps the last saved session: it is
      // still validated against the live tunnel on restore.
      if (e.phase != _lastPsiPhase) {
        _lastPsiPhase = e.phase;
        _syncPsiSession();
      }
    });
    engine.states.listen((e) {
      final busy = e.phase == Phase.searching || e.phase == Phase.testing || e.phase == Phase.connecting || e.phase == Phase.switching;
      final changed = phase != e.phase;
      phase = e.phase;
      curLink = engine.currentLink;
      if (busy && _pulseT == null) {
        _pulseT = Timer.periodic(const Duration(milliseconds: 600), (_) {
          pulse = !pulse;
          notifyListeners();
        });
      }
      if (!busy && _pulseT != null) {
        _pulseT!.cancel();
        _pulseT = null;
        pulse = false;
      }
      if (changed) notifyListeners();
      if (changed && e.phase == Phase.connected) {
        sessionData = engine.sessionJson();
        save();
      }
      if (changed && (e.phase == Phase.idle || e.phase == Phase.failed) && sessionData != null) {
        sessionData = null;
        save();
      }
      if (changed && e.phase == Phase.failed) captureSystemLog();
    });
    Timer.periodic(const Duration(minutes: 5), (_) {
      if (mySubs.isNotEmpty) refreshSubs();
    });
  }
  Timer? _pulseT;
  Map<String, dynamic>? sessionData;
  // v48: the Psiphon session (mode, layer flags, exit info, start
  // time), saved on connect and cleared on disconnect/failure, so a
  // reopened app restores it instead of showing NOT CONNECTED while
  // the tunnel is still running. Ports are never saved: restore reads
  // the live ports from the bridge.
  Map<String, dynamic>? psiSessionData;
  PsiphonPhase _lastPsiPhase = PsiphonPhase.idle;

  /// v48: write (or clear) the saved Psiphon session from the current
  /// engine state and layer flags. Called on phase transitions and
  /// whenever a layer flag flips (VPN/combo layer up).
  void _syncPsiSession() {
    if (psiphon.state.phase == PsiphonPhase.connected) {
      final e = psiphon.state;
      psiSessionData = {
        'vpnActive': psiphonVpnActive,
        'comboActive': psiComboActive,
        'exitIp': e.exitIp,
        'location': e.location,
        'region': e.region,
        'at': e.connectedAt?.millisecondsSinceEpoch,
      };
    } else if (psiphon.state.phase == PsiphonPhase.idle || psiphon.state.phase == PsiphonPhase.failed) {
      psiSessionData = null;
    } else {
      return;
    }
    save();
  }
  final VpnCore core;
  final List<String> pool;
  late final PoolEngine engine;
  late final PsiphonEngine psiphon;

  String lang = 'en', theme = 'graphite', mode = 'auto', cleanIp = '', frontHost = '', bypass = '', activeProfile = '';
  String? single, activeSub, curLink;
  // v46: Psiphon mode: 'vpn' (whole device, default), 'proxy' (local
  // only), 'combo' (Psiphon+V2ray). Migrated from the old psiphonVpn
  // bool on load: true/absent -> vpn, false -> proxy.
  String psiMode = 'vpn';
  // v46: combo-mode user configs (one per line) + pool option.
  String psiComboLinks = '';
  bool psiComboUseApp = false;
  // v46: Custom Proxy sub-option of proxy mode (upstream SOCKS).
  bool psiProxyCustom = false;
  String psiProxyIp = '';
  String psiProxyPort = '';
  bool psiComboActive = false;
  bool psiComboBusy = false;
  // Egress country for Psiphon (ISO code, '' = all regions). v45.
  String psiCountry = '';
  Phase phase = Phase.idle;
  bool pulse = false, fragment = true, fragAll = false, strict = true, appsLoading = false;
  String connType = 'vpn', appMode = 'all';
  Map<String, bool> providerEnabled = {for (final p in kProviders) p.id: (String.fromEnvironment('PROVIDERS_B64').isNotEmpty ? p.defaultEnabled : true)};
  // Fresh installs start with the user's priority order, not the
  // built-in list order: Fast first, Update second, V2rayAG Exclusive
  // third. The old migration only ran when a saved file existed, so a
  // fresh install kept Exclusive first; field defaults fix that.
  List<String> providerOrder = String.fromEnvironment('PROVIDERS_B64').isNotEmpty || String.fromEnvironment('PROVIDER_FAST_B64').isNotEmpty
      ? kProviders.map((p) => p.id).toList()
      : ['fast', 'update', 'v2rayag', 'antifilter', 'hiddify'];
  Map<String, int> providerLastRefresh = {};
  Map<String, Map<String, dynamic>> srcCache = {};
  final Map<String, String> providerStatus = {};
  bool providersExpanded = false;
  Set<String> appSet = {};
  List<AppInfo> apps = [];
  String fragLen = '100-200', fragInt = '10-20';
  String testUrl = 'https://cp.cloudflare.com/generate_204';
  bool autoSortAfterTest = true, deleteConfirm = false;
  // v46: psiphonVpn is replaced by psiMode above; old saves migrate on load.
  bool psiphonVpnActive = false;
  String psiphonVpnError = '';
  List<String> cdnLinks = [];
  Map<String, List<String>> subLinks = {}, subRemoved = {};
  Map<String, int> subFirst = {};
  int pingDone = 0, pingTotal = 0;
  int accent = 0xFF3CC4BA, tab = 0;
  String scanCdn = 'Cloudflare', scanStage = '';
  int scanCount = 300, scanDone = 0, scanTotal = 0, scanStageNo = 0;
  bool scanning = false, _scanStop = false;
  List<CdnHit> scanHits = [];
  final Map<String, List<String>> liveRanges = {};
  final Map<String, String> rangesStamp = {};
  bool sortPing = false, testing = false, hostTesting = false, speedBusy = false;
  String speedResult = '';
  final Map<String, int> hostMs = {};
  List<String> myLinks = [], mySubs = [];
  List<String> favorites = [];
  int psiphonAttempts = 0;
  // Links that answered a TCP/TLS ping but failed a real connect attempt
  // (core rejected the config, or the server carried no traffic). A ping
  // only proves the endpoint answers; it never proves the account works,
  // so a failed connect must override a good ping in the UI, not the
  // other way round. Persisted, so an expired config does not look good
  // again after every restart; cleared only by a successful connect.
  Set<String> trafficFailed = {};
  int themeDefaultsVersion = 1;
  final List<String> unlimitedEmbedded = unlimitedEmbeddedLinks();
  int providerDefaultsVersion = 1;
  List<Map<String, dynamic>> speedHistory = [];
  Map<String, List<String>> profiles = {};
  final Map<String, int> pings = {};
  final Map<String, SubInfo> subInfo = {};
  final Map<String, int> subCount = {};
  final Set<String> sel = {};
  final List<String> logs = [];

  bool get fa => lang == 'fa';
  String t(String k) => (_tr[k] ?? [k, k])[fa ? 1 : 0];
  void refresh() => notifyListeners();
  void go(int i) {
    tab = i;
    notifyListeners();
  }

  void log(String m) {
    final n = DateTime.now();
    String z(int v) => v.toString().padLeft(2, '0');
    final line = '${z(n.hour)}:${z(n.minute)}:${z(n.second)}  $m';
    // v46: logs are for important events. An identical message
    // repeating back-to-back is spam, not information: skip it.
    if (logs.isNotEmpty && logs.first.length >= 10 && line.length >= 10 && logs.first.substring(10) == line.substring(10)) return;
    logs.insert(0, line);
    if (logs.length > 300) logs.removeLast();
    notifyListeners();
  }

  File get _file {
    final d = Directory('/data/data/com.v2rayag.v2rayag/files');
    try {
      if (!d.existsSync()) d.createSync(recursive: true);
    } catch (_) {}
    return File('${d.existsSync() ? d.path : Directory.systemTemp.path}/v2rayag.json');
  }

  Future<void> load() async {
    try {
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      lang = j['lang'] ?? lang;
      theme = j['theme'] ?? theme;
      mode = j['mode'] ?? mode;
      cleanIp = j['cleanIp'] ?? '';
      frontHost = j['frontHost'] ?? '';
      bypass = j['bypass'] ?? '';
      activeProfile = j['activeProfile'] ?? '';
      accent = j['accent'] ?? accent;
      myLinks = List<String>.from(j['myLinks'] ?? []);
      mySubs = List<String>.from(j['mySubs'] ?? []);
      favorites = List<String>.from(j['favorites'] ?? []);
      psiphonAttempts = j['psiphonAttempts'] ?? 0;
      if (j['trafficFailed'] is List) trafficFailed = Set<String>.from(j['trafficFailed']);
      themeDefaultsVersion = j['themeDefaultsVersion'] ?? 1;
      var migrated = false;
      if (themeDefaultsVersion < 2 && theme == 'forest') {
        // Default theme is graphite now. One-time: an existing install
        // that never chose a theme (still on the old forest default)
        // moves to graphite; the flag is saved so a later choice of
        // forest is never overridden again.
        theme = 'graphite';
        themeDefaultsVersion = 2;
        migrated = true;
      }
      if (j['speedHistory'] is List) speedHistory = (j['speedHistory'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      cdnLinks = List<String>.from(j['cdnLinks'] ?? []);
      fragment = j['fragment'] ?? true;
      fragAll = j['fragAll'] ?? false;
      fragLen = j['fragLen'] ?? fragLen;
      strict = j['strict'] ?? true;
      psiCountry = j['psiCountry'] ?? '';
      psiMode = j['psiMode'] ?? (j['psiphonVpn'] == false ? 'proxy' : 'vpn');
      psiComboLinks = j['psiComboLinks'] ?? '';
      psiComboUseApp = j['psiComboUseApp'] == true;
      psiProxyCustom = j['psiProxyCustom'] == true;
      psiProxyIp = j['psiProxyIp'] ?? '';
      psiProxyPort = j['psiProxyPort'] ?? '';
      if (j['providerEnabled'] is Map) (j['providerEnabled'] as Map).forEach((k, v) => providerEnabled[k as String] = v == true);
      providerDefaultsVersion = j['providerDefaultsVersion'] ?? 1;
      if (j['providerOrder'] is List) providerOrder = List<String>.from(j['providerOrder']);
      for (final p in kProviders) {
        if (!providerOrder.contains(p.id)) providerOrder.add(p.id);
      }
      if (providerDefaultsVersion < 2 && String.fromEnvironment('PROVIDERS_B64').isEmpty) {
        // One-time migration to the new defaults: Fast first, Update
        // second, then the rest in their previous order, and every
        // provider enabled, so a fresh install (and an existing install
        // upgrading to this build) tries everything instead of only
        // V2rayAG Exclusive. The user can change this afterwards; the
        // version flag stops it from resetting on every launch.
        const desired = ['fast', 'update', 'v2rayag', 'antifilter', 'hiddify', 'unlimited'];
        final rest = providerOrder.where((id) => !desired.contains(id)).toList();
        providerOrder = [...desired.where((id) => kProviders.any((p) => p.id == id)), ...rest];
        for (final id in providerOrder) {
          providerEnabled[id] = true;
        }
        providerDefaultsVersion = 2;
        migrated = true;
      }
      // One line per per-provider secret (names and counts only, never
      // values), so a silently ignored secret is visible in Logs instead
      // of showing up as a mysteriously missing provider.
      for (final line in providerSecretDiagnostics()) {
        log(line);
      }
      providerLastRefresh = Map<String, int>.from(j['providerLastRefresh'] ?? {});
      srcCache = (j['srcCache'] as Map<String, dynamic>? ?? {}).map((k, v) => MapEntry(k, Map<String, dynamic>.from(v)));
      providersExpanded = j['providersExpanded'] == true;
      sessionData = j['session'] == null ? null : Map<String, dynamic>.from(j['session']);
      psiSessionData = j['psiSession'] == null ? null : Map<String, dynamic>.from(j['psiSession']);
      connType = j['connType'] ?? 'vpn';
      appMode = j['appMode'] ?? 'all';
      appSet = Set<String>.from(j['appSet'] ?? []);
      fragInt = j['fragInt'] ?? fragInt;
      testUrl = j['testUrl'] ?? testUrl;
      autoSortAfterTest = j['autoSortAfterTest'] ?? true;
      deleteConfirm = j['deleteConfirm'] ?? false;
      // v46: old psiphonVpn bool migrates into psiMode above; no longer read here.
      subFirst = Map<String, int>.from(j['subFirst'] ?? {});
      subLinks = (j['subLinks'] as Map<String, dynamic>? ?? {}).map((k, v) => MapEntry(k, List<String>.from(v)));
      subRemoved = (j['subRemoved'] as Map<String, dynamic>? ?? {}).map((k, v) => MapEntry(k, List<String>.from(v)));
      profiles = (j['profiles'] as Map<String, dynamic>? ?? {}).map((k, v) => MapEntry(k, List<String>.from(v)));
      // Persist one-time migrations immediately. Previously the provider
      // migration only lived in memory, so a user's later provider
      // changes could be reset by the next launch; now the flag is on
      // disk and the migration truly runs once.
      if (migrated) save();
    } catch (_) {}
  }

  void save() {
    try {
      _file.writeAsStringSync(jsonEncode({
        'lang': lang, 'theme': theme, 'mode': mode, 'cleanIp': cleanIp, 'frontHost': frontHost,
        'bypass': bypass, 'activeProfile': activeProfile, 'accent': accent,
        'myLinks': myLinks, 'mySubs': mySubs, 'profiles': profiles, 'favorites': favorites, 'psiphonAttempts': psiphonAttempts, 'trafficFailed': trafficFailed.toList(), 'themeDefaultsVersion': themeDefaultsVersion, 'speedHistory': speedHistory,
        'session': sessionData, 'psiSession': psiSessionData, 'strict': strict, 'psiCountry': psiCountry, 'psiMode': psiMode, 'psiComboLinks': psiComboLinks, 'psiComboUseApp': psiComboUseApp, 'psiProxyCustom': psiProxyCustom, 'psiProxyIp': psiProxyIp, 'psiProxyPort': psiProxyPort,
        'providerEnabled': providerEnabled, 'providerDefaultsVersion': providerDefaultsVersion, 'providerOrder': providerOrder,
        'providerLastRefresh': providerLastRefresh, 'srcCache': srcCache, 'providersExpanded': providersExpanded, 'connType': connType, 'appMode': appMode, 'appSet': appSet.toList(),
        'cdnLinks': cdnLinks, 'fragment': fragment, 'fragAll': fragAll, 'fragLen': fragLen, 'fragInt': fragInt, 'testUrl': testUrl, 'autoSortAfterTest': autoSortAfterTest, 'deleteConfirm': deleteConfirm,
        'subFirst': subFirst, 'subLinks': subLinks, 'subRemoved': subRemoved,
      }));
    } catch (_) {}
    notifyListeners();
  }

  List<String> get personalLinks => profiles.containsKey(activeProfile) ? profiles[activeProfile]! : myLinks;

  // Token bumped by every user disconnect, so a Smart Connect chain
  // that is still awaiting a step never resumes into the next step
  // (CDN, then Psiphon) after the user stopped it.
  int _connectToken = 0;

  Future<void> disconnectAll() async {
    _connectToken++;
    await engine.disconnect();
    // engine.disconnect() already stopped the plugin core (the VPN layer);
    // only the flags need clearing here.
    psiphonVpnActive = false;
    psiComboActive = false;
    psiComboBusy = false;
    psiphonVpnError = '';
    // v48: an explicit user disconnect must also clear the saved
    // Psiphon session, or the next launch would try to restore a
    // session the user deliberately ended.
    psiSessionData = null;
    save();
    if (psiphon.state.phase != PsiphonPhase.idle) await psiphon.disconnect();
    notifyListeners();
  }

  /// Whole-device Psiphon (v44, reverted base v37 + this fix): after the
  /// Psiphon tunnel itself is connected, start the plugin core in VPN mode
  /// with an Xray config whose only outbound is a SOCKS proxy pointing at
  /// Psiphon's own SOCKS port, and NO hand-built inbounds. v37's version
  /// had socks 10808 + http 10809 inbounds and was rejected on device
  /// with INVALID_CONFIG ("VPN configuration or local inbound policy is
  /// incompatible"): in VPN mode the plugin injects its own local inbound
  /// for tun2socks, so a hand-built inbound on the same job clashes with
  /// it. Letting the plugin own the inbound is the shape its own generated
  /// configs use. The app's own package is excluded from the VPN
  /// (blockedApps): without that, Psiphon's own tunnel traffic would loop
  /// back into the VPN. Returns true only when Android really reports a
  /// VPN active; on any failure the Psiphon local proxy keeps working and
  /// the error is shown, never a fake "VPN mode" badge.
  Future<bool> startPsiphonVpn() async {
    psiphonVpnError = '';
    final socks = psiphon.state.socksPort;
    if (psiphon.state.phase != PsiphonPhase.connected || socks == null || socks <= 0) {
      psiphonVpnError = 'Psiphon is not connected yet';
      notifyListeners();
      return false;
    }
    try {
      if (!await core.requestPermission()) {
        psiphonVpnError = 'VPN permission was not granted';
        log('Psiphon VPN mode: permission not granted, staying on local proxy');
        notifyListeners();
        return false;
      }
      engine.proxyOnly = false;
      final cfg = jsonEncode({
        'log': {'loglevel': 'warning'},
        'dns': {'servers': ['1.1.1.1']},
        'outbounds': [
          {'protocol': 'socks', 'settings': {'servers': [{'address': '127.0.0.1', 'port': socks}]}, 'tag': 'psiphon'},
        ],
        'routing': {'rules': [{'type': 'field', 'outboundTag': 'psiphon', 'network': 'tcp,udp'}]},
      });
      final blocked = <String>{'com.v2rayag.v2rayag', ...bypass.split(RegExp(r'[\s,]+')).where((x) => x.contains('.'))};
      await core.start('Psiphon VPN', cfg, blockedApps: blocked.toList(), proxyOnly: false);
      for (var i = 0; i < 20; i++) {
        if (await Native.vpnActive() == true) {
          psiphonVpnActive = true;
          log('Psiphon VPN mode: whole device now routes through Psiphon (SOCKS 127.0.0.1:$socks)');
          notifyListeners();
          _syncPsiSession();
          return true;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
      try {
        await core.stop();
      } catch (_) {}
      psiphonVpnError = 'VPN mode did not start (Android reports no VPN); Psiphon local proxy is still working';
      log('Psiphon VPN mode: start did not produce an active VPN, staying on local proxy');
      notifyListeners();
      return false;
    } catch (e) {
      try {
        await core.stop();
      } catch (_) {}
      psiphonVpnError = 'VPN mode failed: $e';
      log('Psiphon VPN mode failed: $e (local proxy still working)');
      notifyListeners();
      return false;
    }
  }

  /// v46: the layer on top of a connected Psiphon, by mode. Proxy mode
  /// needs nothing more; VPN mode layers the Xray SOCKS tunnel; combo
  /// mode chains a V2Ray config through the tunnel.
  Future<void> _applyPsiphonLayer() async {
    if (psiMode == 'vpn') {
      await startPsiphonVpn();
    } else if (psiMode == 'combo') {
      await startPsiphonV2ray();
    }
  }

  /// v46: the upstream SOCKS proxy for proxy mode's Custom Proxy
  /// sub-option, or '' for the default local proxy. Only used when
  /// proxy mode + Custom Proxy are both selected and the IP/port are
  /// valid; anything else silently means "no upstream proxy".
  String _upstreamProxy() {
    if (psiMode != 'proxy' || !psiProxyCustom) return '';
    final ip = psiProxyIp.trim();
    final port = int.tryParse(psiProxyPort.trim());
    if (ip.isEmpty || port == null || port < 1 || port > 65535) return '';
    // v47: Psiphon's UpstreamProxyURL only accepts socks5:// (or
    // socks4a://) for SOCKS, per its own DialConfig docs; a bare
    // socks:// scheme is not documented and would fail to parse.
    return 'socks5://$ip:$port';
  }

  /// v46: candidate configs for combo mode, in try order.
  /// User configs: exactly what was pasted, deduplicated.
  /// App pool: provider bundles from cache, configs that already have
  /// a good ping first, then the rest, in provider order, never
  /// repeating within one attempt.
  List<String> _comboCandidates() {
    if (!psiComboUseApp) {
      final seen = <String>{};
      return extractLinks(psiComboLinks).where((l) => seen.add(l)).toList();
    }
    final all = <String>[];
    final seen = <String>{};
    for (final b in buildBundles()) {
      for (final l in b.links) {
        if (seen.add(l)) all.add(l);
      }
    }
    final good = all.where((l) => (pings[l] ?? -1) > 0).toList();
    final rest = all.where((l) => (pings[l] ?? -1) <= 0).toList();
    return [...good, ...rest];
  }

  /// v46: chain one parsed Xray config through Psiphon's SOCKS proxy.
  /// Adds a SOCKS outbound (tag 'psiphon') and points every chainable
  /// outbound at it via proxySettings, so the config's server is
  /// reached through the Psiphon tunnel. Returns null when the config
  /// has no chainable outbound (freedom/blackhole/dns only).
  String? _chainThroughPsiphon(String configJson, int socksPort) {
    try {
      final cfg = jsonDecode(configJson);
      if (cfg is! Map) return null;
      final outbounds = cfg['outbounds'];
      if (outbounds is! List) return null;
      var chained = false;
      for (final o in outbounds) {
        if (o is! Map) continue;
        final proto = '${o['protocol'] ?? ''}';
        if (proto == 'freedom' || proto == 'blackhole' || proto == 'dns') continue;
        o['proxySettings'] = {'tag': 'psiphon'};
        chained = true;
      }
      if (!chained) return null;
      outbounds.add({
        'protocol': 'socks',
        'settings': {
          'servers': [
            {'address': '127.0.0.1', 'port': socksPort}
          ]
        },
        'tag': 'psiphon',
      });
      return jsonEncode(cfg);
    } catch (_) {
      return null;
    }
  }

  /// v48: ping through the running core's local HTTP proxy, i.e.
  /// through the chained route itself (core -> Psiphon -> server).
  /// Same proof the normal engine uses: the chained config's own http
  /// inbound port, else 10809. Returns milliseconds, or -1.
  Future<int> _comboProxyPing(String cfgJson) async {
    final ports = <int>{};
    final hp = inboundPort(cfgJson, 'http');
    if (hp != null) ports.add(hp);
    ports.add(10809);
    for (final p in ports) {
      try {
        (await Socket.connect('127.0.0.1', p, timeout: const Duration(milliseconds: 400))).destroy();
      } catch (_) {
        continue;
      }
      for (final u in ['http://cp.cloudflare.com/generate_204', 'http://connectivitycheck.gstatic.com/generate_204']) {
        final c = HttpClient()..connectionTimeout = const Duration(seconds: 4);
        c.findProxy = (_) => 'PROXY 127.0.0.1:$p';
        final sw = Stopwatch()..start();
        try {
          final r = await (await c.getUrl(Uri.parse(u))).close().timeout(const Duration(seconds: 5));
          await r.drain();
          if (r.statusCode == 204 || r.statusCode == 200) return sw.elapsedMilliseconds;
        } catch (_) {
        } finally {
          c.close(force: true);
        }
      }
    }
    return -1;
  }

  /// v46: Psiphon+V2ray. Psiphon is already connected when this runs.
  /// Tries each candidate config in order (long timeout each): parse
  /// it, chain it through Psiphon's SOCKS proxy, start the Xray core
  /// in VPN mode, and prove real traffic with the core's own delay
  /// test. A merely "VPN up" badge is NOT success: the server must
  /// answer through the tunnel. App-pool attempts stop after 30
  /// configs in one tap; user-pasted configs are all tried. On any
  /// failure the Psiphon local proxy keeps working and the error is
  /// shown, never a fake "Psiphon+V2ray" badge.
  Future<bool> startPsiphonV2ray() async {
    final token = _connectToken;
    psiComboBusy = true;
    psiComboActive = false;
    psiphonVpnError = '';
    notifyListeners();
    final socks = psiphon.state.socksPort;
    if (psiphon.state.phase != PsiphonPhase.connected || socks == null || socks <= 0) {
      psiComboBusy = false;
      psiphonVpnError = 'Psiphon is not connected yet';
      notifyListeners();
      return false;
    }
    if (psiComboUseApp && buildBundles().isEmpty) {
      psiComboBusy = false;
      psiphonVpnError = t('psi_combo_nopool');
      log('Psiphon+V2ray: provider pool is empty, nothing to try');
      notifyListeners();
      return false;
    }
    final raw = _comboCandidates();
    if (raw.isEmpty) {
      psiComboBusy = false;
      psiphonVpnError = t('psi_combo_need');
      log('Psiphon+V2ray: no configs to try');
      notifyListeners();
      return false;
    }
    // v48: parse + chain FIRST, so configs the plugin cannot parse or
    // that have no chainable outbound never eat one of the 30 slots of
    // a tap. Previously the cap cut the raw list, so a tap could spend
    // all 30 tries on unusable configs and report failure without ever
    // reaching a workable one. User-pasted configs are all tried.
    final tried = <({String remark, String cfg})>[];
    var skippedParse = 0, skippedChain = 0;
    for (final link in raw) {
      if (psiComboUseApp && tried.length >= 30) break;
      final parsed = core.parse(link);
      if (parsed == null) {
        skippedParse++;
        continue;
      }
      final cfg = _chainThroughPsiphon(parsed.config, socks);
      if (cfg == null) {
        skippedChain++;
        continue;
      }
      tried.add((remark: parsed.remark, cfg: cfg));
    }
    if (skippedParse > 0 || skippedChain > 0) {
      log('Psiphon+V2ray: skipped $skippedParse unparseable and $skippedChain unchainable configs');
    }
    if (tried.isEmpty) {
      psiComboBusy = false;
      psiphonVpnError = t('psi_combo_fail');
      log('Psiphon+V2ray: no config could be chained through Psiphon (Psiphon local proxy still works)');
      notifyListeners();
      return false;
    }
    if (psiComboUseApp && tried.length >= 30) {
      log('Psiphon+V2ray: trying 30 chainable configs this tap, the rest wait for the next tap');
    }
    final blocked = <String>{'com.v2rayag.v2rayag', ...bypass.split(RegExp(r'[\s,]+')).where((x) => x.contains('.'))};
    for (final c in tried) {
      if (token != _connectToken) return false;
      try {
        engine.proxyOnly = false;
        await core.start('Psiphon+V2ray', c.cfg, blockedApps: blocked.toList(), proxyOnly: false);
      } catch (e) {
        log('Psiphon+V2ray: core start failed for ${c.remark}: $e');
        continue;
      }
      var ok = false;
      for (var i = 0; i < 60; i++) {
        if (token != _connectToken) return false;
        if (await Native.vpnActive() == true && psiphon.state.phase == PsiphonPhase.connected) {
          ok = true;
          break;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (!ok) {
        log('Psiphon+V2ray: ${c.remark}: VPN did not come up, trying the next one');
        try {
          await core.stop();
        } catch (_) {}
        continue;
      }
      // VPN up is not proof: the server must answer through the tunnel.
      // v48: prove it the way the normal engine does: a real request
      // through the core's own local proxy FIRST (it travels the
      // chained route: core -> Psiphon -> server), the plugin's delay
      // test only as a fallback. The delay test alone rejects chained
      // configs whose servers are only reachable through Psiphon,
      // because it can measure the server directly instead.
      var proved = false;
      final proxyPing = await _comboProxyPing(c.cfg);
      if (proxyPing > 0) {
        proved = true;
        log('Psiphon+V2ray: ${c.remark} carried traffic through its local proxy (${proxyPing} ms)');
      } else {
        try {
          final d = await core.connectedDelay().timeout(const Duration(seconds: 15));
          proved = d >= 0;
        } catch (_) {
          proved = false;
        }
      }
      if (token != _connectToken) return false;
      if (proved) {
        psiComboBusy = false;
        psiComboActive = true;
        log('Psiphon+V2ray CONNECTED via ${c.remark}');
        notifyListeners();
        _syncPsiSession();
        return true;
      }
      try {
        await core.stop();
      } catch (_) {}
      log('Psiphon+V2ray: ${c.remark} did not carry traffic, trying the next one');
    }
    psiComboBusy = false;
    psiphonVpnError = t('psi_combo_fail');
    log('Psiphon+V2ray: no config connected (Psiphon local proxy still works)');
    notifyListeners();
    return false;
  }

  Future<void> connect() async {
    // A real test is using the core right now; starting a connect on
    // top of it would corrupt both. The test is short per config, and
    // the log tells the user to wait for it.
    if (engine.testingReal) {
      log('Wait for the real test to finish before connecting');
      return;
    }
    // Leaving Psiphon VPN/combo mode for another mode: the plugin core
    // running the Psiphon layer config must stop first, or the next
    // start is refused ("active session was preserved").
    // engine.disconnect() stops the core.
    if (psiphonVpnActive || psiComboActive || psiComboBusy) {
      await engine.disconnect();
      psiphonVpnActive = false;
      psiComboActive = false;
      psiComboBusy = false;
      psiphonVpnError = '';
    }
    if (mode == 'psiphon') {
      psiphonAttempts++;
      save();
      if (engine.state.phase != Phase.idle && engine.state.phase != Phase.failed) await engine.disconnect();
      psiphonVpnActive = false;
      psiComboActive = false;
      psiComboBusy = false;
      psiphonVpnError = '';
      // v46: VPN-capable modes need the system VPN permission BEFORE
      // the tunnel starts. Asking after connect breaks the connection:
      // the tunnel comes up, the dialog appears, and the grant tears
      // it down. So permission first, tunnel second.
      if (psiMode != 'proxy' && !await core.requestPermission()) {
        psiphonVpnError = 'VPN permission was not granted';
        log('Psiphon: VPN permission not granted, not connecting');
        notifyListeners();
        return;
      }
      final upstream = _upstreamProxy();
      if (psiMode == 'proxy' && psiProxyCustom && upstream.isEmpty) {
        log('Psiphon: custom proxy IP/port invalid, using the local proxy');
      }
      await psiphon.configure(egressRegion: psiCountry, upstreamProxy: upstream);
      await psiphon.connect();
      if (psiMode != 'proxy') {
        // Wait for the tunnel itself (no artificial timeout: Psiphon can
        // take minutes on a filtered network), then layer VPN/combo on top.
        final token = _connectToken;
        while (token == _connectToken && psiphon.state.phase == PsiphonPhase.connecting) {
          await Future.delayed(const Duration(seconds: 1));
        }
        if (token == _connectToken && psiphon.state.phase == PsiphonPhase.connected) {
          await _applyPsiphonLayer();
        }
      }
      return;
    }
    if (psiphon.state.phase != PsiphonPhase.idle) await psiphon.disconnect();
    await _prepare();
    log('Mode: $mode');
    if (mode == 'smart') {
      // Smart Connect: providers first, then CDN fronting, then Psiphon,
      // automatically, without the user switching modes. Each step only
      // counts as success if real traffic passes, exactly like the
      // individual modes do. A step is only entered when the previous
      // step genuinely FAILED (phase failed); a user disconnect leaves
      // the engine idle and must stop the chain here, never jump to
      // CDN or Psiphon on its own. The token below is the second guard
      // for disconnects that happen while a refresh is still running.
      final token = _connectToken;
      engine.announce(t('connecting'));
      log('Smart Connect order: ${providerOrder.where((id) => providerEnabled[id] == true).map(providerById).map((p) => p.name).join(' → ')} (5 configs each)');
      final bundles = buildBundles();
      await engine.connectOrdered(bundles, maxTriesPerBundle: 5, refetch: () async {
        // v34: a connect never refreshes providers. The refetch callback only
        // rebuilds bundles from the cache (e.g. after a mid-session recovery),
        // so Smart Connect can no longer hammer provider hosts or stall on
        // their update limits. Fresh data arrives at app start (after the
        // 12h/24h interval) or when the user taps Update manually.
        return buildBundles();
      });
      if (engine.state.phase == Phase.connected) {
        return;
      }
      if (token != _connectToken || engine.state.phase != Phase.failed) {
        mode = 'smart';
        return;
      }
      log('Smart Connect: providers failed, trying CDN');
      mode = 'cdn';
      await _prepare();
      await engine.connect();
      mode = 'smart';
      if (engine.state.phase == Phase.connected) {
        return;
      }
      if (token != _connectToken || engine.state.phase != Phase.failed) {
        return;
      }
      log('Smart Connect: CDN failed, trying Psiphon');
      psiphonAttempts++;
      save();
      await psiphon.configure(egressRegion: psiCountry, upstreamProxy: _upstreamProxy());
      await psiphon.connect();
      // Psiphon starts event-driven and keeps trying on its own: wait
      // for it to settle instead of inventing a timeout that would cut
      // a slow tunnel off. Only when Psiphon itself reports failure do
      // we report the final error: no mode connected.
      while (token == _connectToken && psiphon.state.phase == PsiphonPhase.connecting) {
        await Future.delayed(const Duration(seconds: 1));
      }
      if (token != _connectToken) return;
      if (psiphon.state.phase == PsiphonPhase.connected) {
        // Whole-device mode is a bonus layer on top of a connected
        // Psiphon: if it fails, Smart still counts Psiphon itself as
        // connected (local proxy), exactly like direct Psiphon mode.
        if (psiMode != 'proxy') await _applyPsiphonLayer();
        return;
      }
      engine.failWith('No mode connected: providers, CDN and Psiphon all failed. Tap again to retry from the start.');
      return;
    }
    if (mode == 'auto') {
      engine.announce(t('connecting'));
      final bundles = buildBundles();
      await engine.connectOrdered(bundles, refetch: () async {
        return buildBundles();
      });
    } else {
      await engine.connect();
      // A single personal config that was just tried: a good TCP/TLS
      // ping must not outlive a failed real connect. The core's
      // CONFIG_REJECTED / no-traffic failure (e.g. an expired account
      // whose server still answers) marks the config, so the list
      // shows "traffic failed" instead of a green ping, until it
      // connects successfully again.
      if (mode == 'personal' && single != null) {
        if (engine.state.phase == Phase.connected) {
          trafficFailed.remove(single);
        } else {
          trafficFailed.add(single!);
        }
        save();
        notifyListeners();
      }
    }
  }

  // ---------------------------------------------------------------- providers

  ProviderDef providerById(String id) => kProviders.firstWhere((p) => p.id == id);

  void toggleProvider(String id) {
    // User rule (v1.0.4): ticking or unticking a provider NEVER
    // refreshes it. Refresh happens only on first app open, after the
    // 12h interval, or on a manual tap (row arrow, Update selected,
    // Update all). The old forced refresh on enable is what made
    // re-ticking a provider start an update.
    final on = !(providerEnabled[id] ?? false);
    providerEnabled[id] = on;
    save();
  }

  void selectAllProviders(bool on) {
    for (final id in providerOrder) {
      providerEnabled[id] = on;
    }
    save();
  }

  void moveProvider(int from, int to) {
    if (to < 0 || to >= providerOrder.length) return;
    final id = providerOrder.removeAt(from);
    providerOrder.insert(to, id);
    save();
  }

  // Refresh policy (v34, user-set; Fast rule tightened in v48 and
  // v1.0.3): a connect tap NEVER refreshes. Automatic refresh happens
  // only at app start (first use, and again once the interval has
  // elapsed: every other provider once per 12 hours, per source).
  // Fast is different: it auto-refreshes exactly ONCE, on the first
  // run after install, and NEVER again automatically — even if that
  // first fetch failed and it still has zero configs, because
  // retrying on every startup is what hammers its host's daily limit
  // (the old "has configs" check retried forever while the count was
  // zero). The timestamp below is written on every Fast refresh, so
  // a single attempt, manual or automatic, already seals it. A manual
  // tap (per provider, Update selected, Update all) always forces a
  // refresh.
  bool _fresh(ProviderDef p) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (p.id == 'fast') {
      return providerLastRefresh.containsKey('fast');
    }
    for (final src in p.sources) {
      final c = srcCache[src.url];
      if (c == null || now - (c['fetchedAt'] as int) >= 12 * 3600) return false;
    }
    return true;
  }

  Future<void> _refreshSource(ProviderSource src) async {
    var r = await engine.inspectSub(src.url);
    if (r == null) {
      // Direct fetch failed. If a tunnel is already active, retry through
      // it: Psiphon's local proxy, or the core's local proxy. This is the
      // only way a host that is unreachable from the user's own network
      // can be fetched at all.
      final psiPort = psiphon.state.httpPort;
      if (r == null && psiphon.state.phase == PsiphonPhase.connected && psiPort != null && psiPort > 0) {
        r = await engine.inspectSubViaProxy(src.url, psiPort);
        if (r != null) log('Refreshed ${Uri.tryParse(src.url)?.host ?? src.url} via the active Psiphon tunnel');
      }
      if (r == null && engine.state.phase == Phase.connected) {
        r = await engine.inspectSubViaTunnel(src.url);
        if (r != null) log('Refreshed ${Uri.tryParse(src.url)?.host ?? src.url} via the active tunnel');
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (r == null) {
      log('Could not refresh ${Uri.tryParse(src.url)?.host ?? src.url} (kept last known configs)');
      if (srcCache[src.url] == null) {
        log('Hint: this host may be unreachable from your network without a VPN. Connect via another provider first, then press Update again - v26 retries via the active tunnel.');
      }
      return;
    }
    final info = r['info'] as SubInfo;
    srcCache[src.url] = {
      'label': src.label,
      'links': List<String>.from(r['links']),
      'fetchedAt': now,
      'total': info.total, 'upload': info.upload, 'download': info.download, 'expire': info.expire, 'known': info.known,
    };
  }

  /// Refreshes a provider's sources, but only if its interval has elapsed
  /// (others: once per 12 hours, per source; Fast: only once ever, on
  //  the first run after install — see _fresh) unless [force] is set.
  /// A failed source keeps its last known-good data; it is never cleared.
  /// Only stale sources are fetched: a provider with one dead source no longer
  /// re-fetches all of its healthy sources on every refresh, which is what was
  /// hammering provider hosts and slowing connects down.
  Future<void> refreshProvider(ProviderDef p, {bool force = false}) async {
    if (!force && _fresh(p)) {
      log('${p.name}: cache still fresh, using it');
      return;
    }
    final now0 = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final stale = force ? p.sources : p.sources.where((src) {
      final c = srcCache[src.url];
      return c == null || now0 - (c['fetchedAt'] as int) >= 12 * 3600;
    }).toList();
    if (stale.isEmpty) {
      log('${p.name}: cache still fresh, using it');
      return;
    }
    providerStatus[p.id] = 'loading';
    notifyListeners();
    await Future.wait(stale.map(_refreshSource));
    if (p.id == 'fast') providerLastRefresh['fast'] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    providerStatus[p.id] = 'done';
    save();
    log('${p.name}: refreshed, ${providerConfigCount(p.id)} configs now available');
  }

  Future<void> refreshEnabledProviders({bool force = false}) async {
    // User rule (v1.0.4): "Update selected" never touches Fast. Fast
    // refreshes only on the first run after install, on its own row
    // arrow, or via "Update all" (refreshAllProviders below). Skipping
    // it here keeps a manual multi-provider update from burning its
    // host's daily limit.
    for (final id in providerOrder) {
      if (id == 'fast') continue;
      if (providerEnabled[id] == true) await refreshProvider(providerById(id), force: force);
    }
  }

  /// Refreshes only providers that currently have no configs at all
  /// (fresh installs, or a host that failed directly). Callers are
  /// expected to be connected already, so _refreshSource can retry via
  /// the active tunnel.
  Future<void> refreshZeroProviders() async {
    for (final id in providerOrder) {
      if (providerEnabled[id] == true && providerConfigCount(id) == 0) {
        await refreshProvider(providerById(id), force: true);
      }
    }
  }

  Future<void> refreshAllProviders({bool force = false}) async {
    for (final p in kProviders) {
      await refreshProvider(p, force: force);
    }
  }

  /// Called once at app startup (never awaited by main(), so the UI is never blocked):
  /// populates every provider's config count, whether or not it is enabled, respecting
  /// each one's normal freshness interval. Never touches providerEnabled.
  Future<void> initAllProviders() async {
    for (final p in kProviders) {
      await refreshProvider(p);
    }
  }

  /// The next personal subscription (after [current], in list order) that has at
  /// least one usable config. Forward-only: never wraps back to one already tried,
  /// so a failed subscription is never retried in the same pass.
  String? nextPersonalSub(String current) {
    final i = mySubs.indexOf(current);
    for (var k = i + 1; k < mySubs.length; k++) {
      final u = mySubs[k];
      if ((subLinks[u] ?? []).isNotEmpty) return u;
    }
    return null;
  }

  int providerConfigCount(String id) {
    final p = providerById(id);
    final seen = <String>{};
    if (id == 'unlimited') seen.addAll(unlimitedEmbedded);
    for (final src in p.sources) {
      final c = srcCache[src.url];
      if (c == null) continue;
      for (final l in (c['links'] as List)) {
        seen.add(l as String);
      }
    }
    return seen.length;
  }

  DateTime? providerLastUpdated(String id) {
    final p = providerById(id);
    int? best;
    for (final src in p.sources) {
      final t = srcCache[src.url]?['fetchedAt'] as int?;
      if (t != null && (best == null || t < best)) best = t;
    }
    return best == null ? null : DateTime.fromMillisecondsSinceEpoch(best * 1000);
  }

  /// Every enabled provider's configs, in priority order, deduplicated within
  /// each provider but never across providers (a provider with no cached data
  /// yet simply contributes nothing, rather than blocking the others).
  List<ProviderBundle> buildBundles() {
    final out = <ProviderBundle>[];
    for (final id in providerOrder) {
      if (providerEnabled[id] != true) continue;
      final p = providerById(id);
      final links = <String>[], seen = <String>{};
      if (id == 'unlimited') {
        for (final l in unlimitedEmbedded) {
          if (seen.add(l)) links.add(l);
        }
      }
      for (final src in p.sources) {
        final c = srcCache[src.url];
        if (c == null) continue;
        for (final l in (c['links'] as List)) {
          if (seen.add(l as String)) links.add(l);
        }
      }
      if (links.isNotEmpty) out.add(ProviderBundle(p.id, p.name, links));
    }
    return out;
  }

  Future<void> _prepare() async {
    final e = engine;
    var blocked = bypass.split(RegExp(r'[\s,]+')).where((x) => x.contains('.')).toList();
    if (connType == 'vpn') {
      if (appMode == 'except') blocked = {...blocked, ...appSet}.toList();
      if (appMode == 'only') {
        final all = await loadApps();
        blocked = all.map((a) => a.pkg).where((x) => !appSet.contains(x)).toList();
      }
    }
    e.blockedApps = blocked;
    e.proxyOnly = connType == 'proxy';
    e.strictVerify = strict;
    e.testUrl = testUrl;
    if (mode == 'cdn') {
      // CDN mode uses only the registered pool, never personal configs.
      // Your registered CDN configs first; with none, the pool's CDN (then TLS) configs.
      e.poolUrls = cdnLinks.isEmpty ? [...pool] : [];
      e.directLinks = [...cdnLinks];
      e.linkFilter = cdnLinks.isEmpty ? isCdnLink : (_) => true;
      e.fallbackFilter = cdnLinks.isEmpty ? isTlsLink : null;
      e.keepOriginal = cleanIp.isNotEmpty || frontHost.isNotEmpty;
      e.transform = (l) => applyFronting(l, ip: cleanIp, host: frontHost);
    } else if (mode == 'personal') {
      e.fallbackFilter = null;
      e.poolUrls = single != null ? [] : (activeSub != null ? [activeSub!] : [...mySubs]);
      e.directLinks = single != null ? [single!] : (activeSub != null ? [] : [...personalLinks]);
      e.linkFilter = (_) => true;
      e.keepOriginal = false;
      e.transform = (l) => l;
    } else {
      // Automatic mode is driven entirely by the provider system (see connect());
      // the engine's poolUrls/directLinks are set per provider as it is tried.
      e.fallbackFilter = null;
    }
    e.cdnFragment = mode == 'cdn' ? fragment : fragAll;
    e.fragLen = fragLen;
    e.fragInt = fragInt;
  }

  /// Imports configs from a file's text: only real, deduplicated
  /// config links are added; surrounding text is ignored. Returns
  /// "added/duplicates/subs" for the result message.
  Future<String> importFileText(String text) async {
    var added = 0, subs = 0;
    final subSeen = mySubs.toSet();
    for (final x in text.split(RegExp(r'\s+'))) {
      var clean = x.trim();
      while (clean.endsWith('"') || clean.endsWith("'") || clean.endsWith(',') || clean.endsWith(';') || clean.endsWith(']')) clean = clean.substring(0, clean.length - 1);
      if (RegExp(r'^https?://').hasMatch(clean) && subSeen.add(clean)) {
        mySubs.add(clean);
        subs++;
      }
    }
    final linkSeen = myLinks.toSet();
    final links = text.length > 20000 ? await compute(extractConfigLinks, text) : extractConfigLinks(text);
    for (final l in links) {
      if (linkSeen.add(l)) {
        myLinks.add(l);
        added++;
      }
    }
    save();
    return '$added/${links.length - added}/$subs';
  }

  /// Adds configs and subscription links found in [text]. Returns "configs/subs".
  Future<String> addText(String text) async {
    var c = 0, s = 0;
    final subSeen = mySubs.toSet();
    for (final x in text.split(RegExp(r'\s+'))) {
      if (RegExp(r'^https?://').hasMatch(x) && subSeen.add(x)) {
        mySubs.add(x);
        s++;
      }
    }
    // Parsing a large pasted body (1000+ lines) off the UI isolate keeps the app responsive.
    final links = text.length > 20000 ? await compute(extractLinks, text) : extractLinks(text);
    final linkSeen = myLinks.toSet();
    for (final l in links) {
      if (linkSeen.add(l)) {
        myLinks.add(l);
        c++;
      }
    }
    save();
    return '$c / $s';
  }

  String subText(Iterable<String> links) => base64.encode(utf8.encode(links.join('\n')));

  Future<void> testPings(List<String> links) async {
    if (testing) return;
    // A real test needs the core, so it cannot run while a connection
    // (or another connect attempt) is using it; refusing here avoids
    // marking good configs as failed just because the core was busy.
    if (engine.state.phase == Phase.connected || engine.state.phase == Phase.searching || engine.state.phase == Phase.testing || engine.state.phase == Phase.connecting || engine.state.phase == Phase.switching || engine.testingReal) {
      log('Real test skipped: disconnect first, so the test core can run');
      return;
    }
    testing = true;
    pingDone = 0;
    pingTotal = links.length;
    // Fresh test, fresh verdicts: a previous run's "traffic failed" marks
    // must not survive into this run, or a config fixed since then would
    // still show red even before it is tested.
    for (final l in links) {
      trafficFailed.remove(l);
    }
    notifyListeners();
    // Stage 1: fast TCP/TLS probe, only to filter out unreachable hosts.
    // Its results are deliberately NOT written to pings: in v34 they were,
    // so the list first showed every config green and then flipped them
    // one by one to red as stage 2 ran, which looked like the test itself
    // was breaking healthy configs. Only stage 2's verdict is shown.
    final probe = <String, int>{};
    var i = 0;
    DateTime lastUi = DateTime.now();
    Future<void> worker() async {
      while (i < links.length) {
        final l = links[i++];
        final p = core.parse(l);
        probe[l] = p == null ? -1 : (await probeLink(l)).ms;
        pingDone++;
        final now = DateTime.now();
        if (pingDone == pingTotal || now.difference(lastUi).inMilliseconds > 180) {
          lastUi = now;
          notifyListeners();
        }
      }
    }

    await Future.wait(List.generate(16, (_) => worker()));
    // Stage 2: real delay test, the way V2rayNG, MahsaNG, NekoBox and
    // Happ do it: the CORE itself measures the delay (the plugin's
    // getServerDelay), running the config and fetching the test URL
    // through the tunnel internally. v34 instead started the core in
    // local-proxy mode, guessed its proxy port, and fetched through an
    // external HTTP client, which systematically failed healthy configs
    // whenever the proxy port, the HTTP/SOCKS mode or the HTTPS CONNECT
    // step did not line up, and then marked every one of them
    // "traffic failed". The core's own delay test removes all three
    // failure modes, and it is also what "real delay" means in those
    // apps: a config only passes if the account actually works.
    log('Real test stage: verifying traffic for ${links.where((l) => (probe[l] ?? -1) > 0).length} reachable configs');
    pingDone = 0;
    var verified = 0, failed = 0;
    for (final l in links) {
      if (engine.state.phase != Phase.idle && engine.state.phase != Phase.failed) break;
      final pr = probe[l] ?? -1;
      if (pr <= 0 || pr == 9000) {
        // Unreachable (or UDP, which the TCP probe cannot judge): keep
        // stage 1's result, but do NOT call it "traffic failed" – an
        // unreachable host is not a rejected account.
        pings[l] = pr;
        pingDone++;
        continue;
      }
      final p = core.parse(l);
      var ms = -1;
      if (p != null) {
        final cfg = fragAll ? applyFragment(p.config, length: fragLen, interval: fragInt) : p.config;
        ms = await core.delay(cfg, testUrl, const Duration(seconds: 10));
      }
      if (ms > 0) {
        pings[l] = ms;
        trafficFailed.remove(l);
        verified++;
      } else {
        pings[l] = -1;
        trafficFailed.add(l);
        failed++;
      }
      pingDone++;
      notifyListeners();
    }
    if (failed > 0 || verified > 0) save();
    testing = false;
    notifyListeners();
    log('Real test finished: $verified verified, $failed failed traffic');
  }

  Future<void> refreshSubs() async {
    for (final u in List<String>.from(mySubs)) {
      await refreshOneSub(u);
    }
    log('Subscriptions updated');
  }

  /// Manual refresh of ONE subscription only (v34): the per-sub Refresh button
  /// in the Subs tab no longer re-fetches every subscription.
  Future<void> refreshOneSub(String u) async {
    final r = await engine.inspectSub(u);
    if (r != null) {
      subInfo[u] = r['info'] as SubInfo;
      final all = List<String>.from(r['links']);
      final gone = (subRemoved[u] ?? []).toSet();
      final fresh = all.where((l) => !gone.contains(l)).toList();
      final freshSet = fresh.toSet();
      final old = subLinks[u] ?? [];
      final oldSet = old.toSet();
      subLinks[u] = [...old.where(freshSet.contains), ...fresh.where((l) => !oldSet.contains(l))];
      subCount[u] = subLinks[u]!.length;
      subFirst.putIfAbsent(u, () => DateTime.now().millisecondsSinceEpoch ~/ 1000);
      save();
    }
    notifyListeners();
  }

  int _k(String l) {
    if (trafficFailed.contains(l)) return 99999;
    final p = pings[l];
    return p == null ? 50000 : (p < 0 ? 99999 : p);
  }

  void sortMy() {
    myLinks.sort((a, b) => _k(a).compareTo(_k(b)));
    save();
  }

  bool isFavorite(String l) => favorites.contains(l);
  void toggleFavorite(String l) {
    if (favorites.contains(l)) {
      favorites.remove(l);
    } else {
      favorites.add(l);
    }
    save();
  }
  void removeFavorite(String l) {
    favorites.remove(l);
    save();
  }
  void clearFavorites() {
    favorites.clear();
    save();
  }
  void connectFavorite(String l) => connectLink(l);

  void addSpeedResult(SpeedResult r, String modeLabel) {
    speedHistory.insert(0, {
      'at': DateTime.now().millisecondsSinceEpoch,
      'mode': modeLabel,
      'download': r.downloadMbps,
      'upload': r.uploadMbps,
      'ping': r.pingMs,
      'jitter': r.jitterMs,
      'failedProbes': r.failedProbes,
      'duration': r.durationSec,
    });
    if (speedHistory.length > 50) speedHistory = speedHistory.sublist(0, 50);
    save();
  }
  void clearSpeedHistory() {
    speedHistory.clear();
    save();
  }

  Future<void> testMy() async {
    await testPings(myLinks);
    if (autoSortAfterTest) sortMy();
  }

  bool tested(List<String> l) => l.isNotEmpty && l.every(pings.containsKey);

  void deleteInvalidMy() {
    myLinks.removeWhere((l) => pings[l] == -1 || trafficFailed.contains(l));
    trafficFailed.removeWhere((l) => !myLinks.contains(l));
    save();
  }

  Future<void> testSub(String u) async {
    await testPings(subLinks[u] ?? []);
    if (autoSortAfterTest) sortSub(u);
  }

  void sortSub(String u) {
    subLinks[u]?.sort((a, b) => _k(a).compareTo(_k(b)));
    save();
  }

  void removeFromSub(String u, Iterable<String> ls) {
    subRemoved.putIfAbsent(u, () => []).addAll(ls);
    subLinks[u]?.removeWhere((l) => ls.contains(l));
    save();
  }

  void removeSub(String u) {
    mySubs.remove(u);
    subLinks.remove(u);
    subInfo.remove(u);
    subRemoved.remove(u);
    if (activeSub == u) activeSub = null;
    save();
  }

  void startCdn() {
    mode = 'cdn';
    single = null;
    activeSub = null;
    save();
    go(0);
    connect();
  }

  void connectLink(String l) {
    mode = 'personal';
    single = l;
    activeSub = null;
    save();
    go(0);
    connect();
  }

  void connectSub(String u) {
    mode = 'personal';
    activeSub = u;
    single = null;
    save();
    go(0);
    connect();
  }

  Future<int> importSub(String u) async {
    final r = await engine.inspectSub(u);
    if (r == null) return 0;
    var c = 0;
    final seen = myLinks.toSet();
    for (final l in List<String>.from(r['links'])) {
      if (seen.add(l)) {
        myLinks.add(l);
        c++;
      }
    }
    save();
    return c;
  }

  static const hostPresets = [
    'speed.cloudflare.com', 'www.cloudflare.com', 'cdnjs.cloudflare.com', 'developers.cloudflare.com',
    'dash.cloudflare.com', 'blog.cloudflare.com', 'workers.cloudflare.com', 'pages.cloudflare.com',
    'one.one.one.one', 'www.speedtest.net', 'discord.com', 'canva.com', 'www.shopify.com', 'medium.com',
    'www.udemy.com', 'zula.ir', 'gitlab.com', 'www.digitalocean.com', 'nodejs.org', 'www.fiverr.com',
  ];

  /// Real TLS handshake with each candidate host as SNI against a Cloudflare IP.
  /// Only hosts that answer with Cloudflare's trace page pass, on YOUR operator.
  Future<void> testHosts() async {
    if (hostTesting) return;
    hostTesting = true;
    hostMs.clear();
    notifyListeners();
    final rng = Random();
    final ip = cleanIp.isNotEmpty ? cleanIp : randomIpIn('104.16.0.0/13', rng);
    var i = 0;
    Future<void> worker() async {
      while (i < hostPresets.length) {
        final h = hostPresets[i++];
        var ms = -1;
        for (var k = 0; k < 3 && ms < 0; k++) {
          final r = await probeIp(k == 0 ? ip : randomIpIn('104.16.0.0/13', rng), h);
          if (r != null) ms = r.ms;
        }
        hostMs[h] = ms;
        notifyListeners();
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    hostTesting = false;
    final ok = hostMs.entries.where((e) => e.value > 0).toList()..sort((a, b) => a.value.compareTo(b.value));
    if (ok.isNotEmpty) frontHost = ok.first.key;
    log('Host finder: ${ok.length}/${hostPresets.length} hosts work${ok.isEmpty ? '' : ', best ${ok.first.key} (${ok.first.value} ms)'}');
    save();
  }

  /// This app's own Android system log (the VPN plugin writes its errors there).
  Future<void> captureSystemLog() async {
    try {
      final r = await Process.run('logcat', ['-d', '-t', '800']);
      final re = RegExp(r'vpn|xray|v2ray|vless|AndroidRuntime|FATAL|ForegroundService|v2rayag|tun2socks|libv2ray', caseSensitive: false);
      final lines = '${r.stdout}'.split('\n').where(re.hasMatch).toList();
      if (lines.isEmpty) log('[sys] nothing relevant in the system log');
      for (final l in lines.reversed.take(60).toList().reversed) {
        log('[sys] ${l.length > 230 ? l.substring(0, 230) : l}');
      }
    } catch (e) {
      log('[sys] could not read the system log: $e');
    }
  }

  /// The VPN keeps running when the app window is closed. When the app is opened again,
  /// show that connection (timer, server, usage) instead of pretending nothing is connected.
  /// v48: the engine session and the Psiphon session restore
  /// independently, mode-matching one first. Two old defects fixed
  /// here: the Psiphon session was never saved at all, and a single
  /// lagging VPN-status check at startup permanently deleted a live
  /// engine session. A failed check now only skips this launch's
  /// restore; the saved session survives for the next launch and is
  /// cleared by the next real connect/disconnect.
  Future<void> restoreSession() async {
    if (mode == 'psiphon') {
      if (await _restorePsiphonSession()) return;
      await _restoreEngineSession();
    } else {
      if (await _restoreEngineSession()) return;
      await _restorePsiphonSession();
    }
  }

  /// v48: is anything actually still running? Retried, because the
  /// VPN status lags on reopen even while the tunnel is alive.
  Future<bool> _aliveCheck() async {
    for (var i = 0; i < 3; i++) {
      if (connType == 'proxy') {
        try {
          (await Socket.connect('127.0.0.1', 10809, timeout: const Duration(milliseconds: 500))).destroy();
          return true;
        } catch (_) {}
      } else {
        if (await Native.vpnActive() == true) return true;
        try {
          (await Socket.connect('127.0.0.1', 10809, timeout: const Duration(milliseconds: 500))).destroy();
          return true;
        } catch (_) {}
      }
      if (i < 2) await Future.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  Future<bool> _restoreEngineSession() async {
    final j = sessionData;
    if (j == null) return false;
    if (!await _aliveCheck()) return false;
    await _prepare();
    return await engine.restore(j);
  }

  /// v48: restore a saved Psiphon session when the native tunnel is
  /// really still listening (bridge status ports). Layer flags
  /// (VPN/combo) are only restored when Android also reports a VPN:
  /// a live tunnel alone means local-proxy mode.
  Future<bool> _restorePsiphonSession() async {
    final j = psiSessionData;
    if (j == null) return false;
    final st = await psiphon.status();
    final socks = (st?['socksPort'] as num?)?.toInt() ?? 0;
    final http = (st?['httpPort'] as num?)?.toInt() ?? 0;
    if (socks <= 0 && http <= 0) {
      // No tunnel is actually listening: nothing to restore. Clear
      // the stale session so the next launch does not retry it.
      psiSessionData = null;
      save();
      return false;
    }
    final vpnUp = await Native.vpnActive() == true;
    psiphonVpnActive = (j['vpnActive'] == true) && vpnUp;
    psiComboActive = (j['comboActive'] == true) && vpnUp;
    final at = j['at'];
    psiphon.restoreConnected(
      socksPort: socks,
      httpPort: http,
      exitIp: j['exitIp'] as String?,
      location: j['location'] as String?,
      region: j['region'] as String?,
      connectedAt: at is int ? DateTime.fromMillisecondsSinceEpoch(at) : null,
    );
    // Subscribing re-emits the bridge's current state, which refreshes
    // ping/location without resetting the restored timer.
    psiphon.init();
    mode = 'psiphon';
    log('Reopened: the Psiphon connection is still active');
    notifyListeners();
    return true;
  }

  Future<List<AppInfo>> loadApps({bool force = false}) async {
    if (apps.isNotEmpty && !force) return apps;
    appsLoading = true;
    notifyListeners();
    apps = await Native.apps();
    appsLoading = false;
    notifyListeners();
    return apps;
  }

  List<String> rangesFor(String cdn) => liveRanges[cdn] ?? (cdn == 'Fastly' ? kFastlyRanges : kCfRanges);
  String rangesInfo(String cdn) => '${rangesFor(cdn).length} ranges, ${rangesStamp[cdn] ?? 'built-in list'}';

  Future<void> updateRanges() async {
    final r = await fetchLiveRanges(scanCdn);
    if (r == null) {
      log('Could not download the $scanCdn range list. Using the built-in one');
    } else {
      liveRanges[scanCdn] = r;
      rangesStamp[scanCdn] = 'updated ${DateTime.now().toString().split(' ').first}';
      log('$scanCdn ranges updated: ${r.length}');
    }
    notifyListeners();
  }

  Future<void> runScan() async {
    if (scanning) return;
    scanning = true;
    _scanStop = false;
    scanHits = [];
    scanDone = 0;
    scanTotal = 0;
    scanStageNo = 1;
    notifyListeners();
    final sni = scanCdn == 'Fastly' ? 'pypi.org' : (frontHost.isNotEmpty ? frontHost : 'speed.cloudflare.com');
    await scanSmart(
      ranges: rangesFor(scanCdn),
      count: scanCount,
      sni: sni,
      onProgress: (st, d, t) {
        scanStageNo = st;
        scanDone = d;
        scanTotal = t;
        if (d % 8 == 0 || d == t) notifyListeners();
      },
      onResults: (l) {
        scanHits = l;
        notifyListeners();
      },
      cancelled: () => _scanStop,
    );
    scanning = false;
    log('Scan finished: ${scanHits.length} stable IPs on $scanCdn');
    notifyListeners();
  }

  void stopScan() => _scanStop = true;

  Future<String> checkUpdate() async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final r = await (await c.getUrl(Uri.parse('https://api.github.com/repos/alireza-spec/V2rayAGVpn/releases/latest'))).close().timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return 'Could not check for updates';
      final j = jsonDecode(await r.transform(utf8.decoder).join());
      final n = int.tryParse('${j['tag_name']}'.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
      final cur = int.tryParse(kBuildNum) ?? 0;
      if (cur > 0 && n > cur) {
        await Native.openUrl('${j['html_url']}');
        return 'New version available: ${j['tag_name']}';
      }
      return 'You have the latest version';
    } catch (_) {
      return 'Could not check for updates';
    } finally {
      c.close(force: true);
    }
  }


  Future<void> speedTest() async {
    speedBusy = true;
    speedResult = '';
    notifyListeners();
    speedResult = await engine.speedTest();
    log('Speed test through the tunnel: $speedResult');
    speedBusy = false;
    notifyListeners();
  }

  Future<String> selfTest() async {
    if (myLinks.isEmpty) return 'Add a server first (Servers tab, Paste)';
    final l = myLinks.first;
    final p = core.parse(l);
    if (p == null) return 'The core could not read this config';
    final r = await probeLink(l);
    final d = await core.delay(p.config, 'https://www.gstatic.com/generate_204', const Duration(seconds: 12));
    final m = 'Handshake: ${r.ms} ms, core delay: $d ms${core.lastError.isEmpty ? '' : ', error: ${core.lastError}'}';
    log(m);
    return m;
  }

  void resetAll() {
    myLinks = [];
    mySubs = [];
    cdnLinks = [];
    subLinks = {};
    subRemoved = {};
    subFirst = {};
    profiles = {};
    activeProfile = '';
    single = null;
    pings.clear();
    sel.clear();
    save();
  }

  static const _pal = {
    'forest': [0xFF081110, 0xFF101C1A],
    'black': [0xFF000000, 0xFF0D0D0D],
    'graphite': [0xFF1B1C1E, 0xFF26282B],
    'midnight': [0xFF080D1A, 0xFF101A30],
    'light': [0xFFF3F6F6, 0xFFFFFFFF],
  };
  static const themes = ['forest', 'black', 'graphite', 'midnight', 'light'];
  static const accents = [0xFF3CC4BA, 0xFF5FD068, 0xFF5AA2FF, 0xFFA58BFF, 0xFFF0B429, 0xFFFF6B6B];

  ThemeData get themeData {
    final p = _pal[theme] ?? _pal['graphite']!;
    final light = theme == 'light';
    final cs = ColorScheme.fromSeed(seedColor: Color(accent), brightness: light ? Brightness.light : Brightness.dark)
        .copyWith(primary: Color(accent), surface: Color(p[1]));
    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: Color(p[0]),
      canvasColor: Color(p[1]),
      cardColor: Color(p[1]),
      appBarTheme: AppBarTheme(backgroundColor: Color(p[0]), elevation: 0),
      navigationBarTheme: NavigationBarThemeData(backgroundColor: Color(p[1]), indicatorColor: Color(accent).withOpacity(.22)),
      drawerTheme: DrawerThemeData(backgroundColor: Color(p[1])),
      dialogTheme: DialogThemeData(backgroundColor: Color(p[1]), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
      bottomSheetTheme: BottomSheetThemeData(backgroundColor: Color(p[1]), shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16)))),
      popupMenuTheme: PopupMenuThemeData(color: Color(p[1]), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      dividerTheme: DividerThemeData(color: cs.onSurface.withOpacity(.12)),
    );
  }
}
