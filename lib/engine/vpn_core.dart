/// The only thing the engine knows about the VPN plugin.
class CoreStatus {
  final int durationSec, upSpeed, downSpeed, upTotal, downTotal; // bytes, bytes/s
  final String state;
  const CoreStatus({
    this.durationSec = 0,
    this.upSpeed = 0,
    this.downSpeed = 0,
    this.upTotal = 0,
    this.downTotal = 0,
    this.state = 'DISCONNECTED',
  });
}

class ParsedConfig {
  final String remark, config;
  const ParsedConfig(this.remark, this.config);
}

abstract class VpnCore {
  Stream<CoreStatus> get status;
  String get lastError;
  Future<void> init();
  Future<bool> requestPermission();
  ParsedConfig? parse(String link);

  /// Real HTTP round trip through a throwaway core instance. -1 = failed.
  Future<int> delay(String config, String url, Duration timeout);

  /// Real HTTP round trip through the running tunnel. -1 = failed.
  Future<int> connectedDelay();
  Future<void> start(String remark, String config, {List<String>? blockedApps, bool proxyOnly = false});
  Future<void> stop();
}
