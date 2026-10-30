// Share VPN relay (v1.0.7): exposes the phone's tunnel on the LAN
// as a SOCKS5 proxy, so a second device can ride this phone's
// tunnel with no subscription of its own.
//
// The relay itself speaks no proxy protocol: it forwards raw TCP
// between a LAN client and the phone's own local SOCKS5 proxy, so
// the SOCKS handshake (including any auth) passes through
// end-to-end. That is also why the target must answer a no-auth
// greeting: in VPN mode the plugin locks its loopback inbounds
// with random credentials only the system knows, so a relay there
// would hand joiners a proxy that always rejects them. Proxy mode
// (core) and Psiphon keep their local SOCKS open, so those are the
// shareable paths. The relay binds 0.0.0.0, which covers both the
// Wi-Fi interface and the hotspot interface, and it dies with the
// connection (Store.disconnectAll stops it): a relay with no
// tunnel behind it would hand joiners a dead proxy.

import 'dart:async';
import 'dart:io';

class ShareTarget {
  final int port;
  final String source; // 'Psiphon' or 'Core'
  const ShareTarget(this.port, this.source);
}

/// True only for a real no-auth SOCKS5 answer (0x05 0x00). A port
/// that demands auth (0x05 0x02), speaks HTTP, or stays silent is
/// NOT usable as a relay target.
Future<bool> _probeSocksNoAuth(int port) async {
  Socket? s;
  try {
    s = await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 600));
    s.add([0x05, 0x01, 0x00]);
    final reply = await s.first.timeout(const Duration(milliseconds: 800));
    return reply.length >= 2 && reply[0] == 0x05 && reply[1] == 0x00;
  } catch (_) {
    return false;
  } finally {
    try {
      await s?.close();
    } catch (_) {}
  }
}

class ShareRelay {
  ServerSocket? _server;
  StreamSubscription<Socket>? _sub;
  int port = 0;
  int targetPort = 0;
  String targetSource = '';
  List<String> lanIps = [];
  int connections = 0;

  /// Finds a shareable local SOCKS5 proxy: Psiphon's SOCKS port
  /// first (it carries the Psiphon tunnel, including combo mode's
  /// Psiphon leg), then the core's candidates. Returns null when
  /// nothing answers a no-auth greeting — the honest "cannot share
  /// from this mode" signal, not a relay that fails later.
  Future<ShareTarget?> detectTarget({int? psiphonSocks, required List<int> coreCandidates}) async {
    if (psiphonSocks != null && psiphonSocks > 0 && await _probeSocksNoAuth(psiphonSocks)) {
      return ShareTarget(psiphonSocks, 'Psiphon');
    }
    for (final p in coreCandidates) {
      if (p > 0 && await _probeSocksNoAuth(p)) return ShareTarget(p, 'Core');
    }
    return null;
  }

  /// Binds [listenPort], falling back to the next 9 ports when it
  /// is taken, and forwards every LAN connection to the local
  /// SOCKS proxy on [targetPort]. Throws when no port binds.
  Future<void> start({required int listenPort, required int targetPort}) async {
    this.targetPort = targetPort;
    ServerSocket? srv;
    Object? lastErr;
    for (var p = listenPort; p < listenPort + 10; p++) {
      try {
        srv = await ServerSocket.bind(InternetAddress.anyIPv4, p);
        break;
      } catch (e) {
        lastErr = e;
      }
    }
    if (srv == null) throw lastErr ?? StateError('Could not bind a share port');
    _server = srv;
    port = srv.port;
    lanIps = await _lanIps();
    _sub = srv.listen(_handle);
  }

  Future<List<String>> _lanIps() async {
    final out = <String>[];
    try {
      for (final ni in await NetworkInterface.list()) {
        for (final a in ni.addresses) {
          if (a.type == InternetAddressType.IPv4 && !a.isLoopback) out.add(a.address);
        }
      }
    } catch (_) {}
    return out;
  }

  void _handle(Socket client) {
    connections++;
    Socket? up;
    var closed = false;
    void kill() {
      if (closed) return;
      closed = true;
      try {
        client.destroy();
      } catch (_) {}
      try {
        up?.destroy();
      } catch (_) {}
    }

    Socket.connect('127.0.0.1', targetPort, timeout: const Duration(seconds: 5)).then((u) {
      if (closed) {
        u.destroy();
        return;
      }
      up = u;
      client.listen(
        (d) {
          try {
            u.add(d);
          } catch (_) {
            kill();
          }
        },
        onError: (_) => kill(),
        onDone: () => kill(),
      );
      u.listen(
        (d) {
          try {
            client.add(d);
          } catch (_) {
            kill();
          }
        },
        onError: (_) => kill(),
        onDone: () => kill(),
      );
    }).catchError((_) => kill());
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _server?.close();
    _server = null;
  }
}
