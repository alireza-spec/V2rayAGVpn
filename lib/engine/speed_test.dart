import 'dart:async';
import 'dart:io';
import 'dart:math';

/// Real, sample-based speed measurement. No result is ever invented:
/// download/upload are bytes actually transferred over elapsed time,
/// ping/jitter come from real HTTP round trips, and upload is null
/// (shown as N/A) when the upload endpoint does not accept the test.
class SpeedResult {
  final double? downloadMbps;
  final double? uploadMbps;
  final int? pingMs;
  final int? jitterMs;
  final int failedProbes;
  final List<double> downloadSamples;
  final List<double> uploadSamples;
  final double durationSec;
  final String? uploadError;
  final String? downloadError;
  final bool cancelled;
  const SpeedResult({
    this.downloadMbps,
    this.uploadMbps,
    this.pingMs,
    this.jitterMs,
    this.failedProbes = 0,
    this.downloadSamples = const [],
    this.uploadSamples = const [],
    this.durationSec = 0,
    this.uploadError,
    this.downloadError,
    this.cancelled = false,
  });
}

Future<SpeedResult> runSpeedTest(
  HttpClient Function(Duration timeout) clientFactory, {
  bool Function()? isCancelled,
  void Function(String stage)? onStage,
  void Function(String stage, double? currentMbps, int done, int total)? onProgress,
}) async {
  bool cancelled() => isCancelled != null && isCancelled();
  final totalSw = Stopwatch()..start();
  // ---- Ping / jitter: 8 real round trips, median + mean absolute diff.
  final pingSamples = <int>[];
  var failed = 0;
  onStage?.call('ping');
  for (var i = 0; i < 5 && !cancelled(); i++) {
    final c = clientFactory(const Duration(seconds: 4));
    final sw = Stopwatch()..start();
    try {
      final r = await (await c.getUrl(Uri.parse('http://cp.cloudflare.com/generate_204'))).close().timeout(const Duration(seconds: 4));
      await r.drain();
      if (r.statusCode == 204 || r.statusCode == 200) {
        pingSamples.add(sw.elapsedMilliseconds);
        onProgress?.call('ping', null, pingSamples.length, 5);
      } else {
        failed++;
        onProgress?.call('ping', null, pingSamples.length + failed, 5);
      }
    } catch (_) {
      failed++;
    } finally {
      c.close(force: true);
    }
  }
  int? pingMs;
  int? jitterMs;
  if (pingSamples.isNotEmpty) {
    final sorted = [...pingSamples]..sort();
    pingMs = sorted[sorted.length ~/ 2];
    if (pingSamples.length >= 2) {
      var sum = 0;
      for (var i = 1; i < pingSamples.length; i++) {
        sum += (pingSamples[i] - pingSamples[i - 1]).abs();
      }
      jitterMs = sum ~/ (pingSamples.length - 1);
    }
  }
  if (cancelled()) return SpeedResult(pingMs: pingMs, jitterMs: jitterMs, failedProbes: failed, cancelled: true, durationSec: totalSw.elapsedMilliseconds / 1000.0);
  // ---- Download: real bytes from a public test endpoint, sampled per window.
  onStage?.call('download');
  final dlSamples = <double>[];
  var dlBytes = 0;
  String? dlError;
  Future<void> downloadAttempt(int bytesWanted, int capMs) async {
    final sw = Stopwatch()..start();
    var wBytes = 0;
    var wStart = sw.elapsedMilliseconds;
    try {
      final c = clientFactory(const Duration(seconds: 6));
      try {
        final r = await (await c.getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=$bytesWanted'))).close().timeout(const Duration(seconds: 10));
        await for (final chunk in r.timeout(const Duration(seconds: 12))) {
          if (cancelled()) break;
          dlBytes += chunk.length;
          wBytes += chunk.length;
          final now = sw.elapsedMilliseconds;
          if (now - wStart >= 250) {
            final sec = (now - wStart) / 1000.0;
            if (sec > 0) {
              final mbps = wBytes * 8 / sec / 1e6;
              dlSamples.add(mbps);
              onProgress?.call('download', mbps, dlBytes, bytesWanted);
            }
            wBytes = 0;
            wStart = now;
          }
          if (sw.elapsedMilliseconds > capMs) break;
        }
      } finally {
        c.close(force: true);
      }
    } catch (_) {
      dlError = 'Download did not finish in time on this tunnel';
    }
  }
  final dlSw = Stopwatch()..start();
  await downloadAttempt(12000000, 12000);
  if (dlBytes < 20000 && !cancelled()) {
    // Slow tunnels need a smaller, finishable file rather than a dash.
    dlSamples.clear();
    dlBytes = 0;
    dlError = null;
    await downloadAttempt(2000000, 10000);
    if (dlBytes < 20000) dlError = 'Download did not finish in time on this tunnel';
  }
  final dlSec = dlSw.elapsedMilliseconds / 1000.0;
  final dlMbps = dlBytes >= 20000 && dlSec > 0 ? dlBytes * 8 / dlSec / 1e6 : null;
  if (cancelled()) return SpeedResult(downloadMbps: dlMbps, downloadSamples: dlSamples, pingMs: pingMs, jitterMs: jitterMs, failedProbes: failed, cancelled: true, durationSec: totalSw.elapsedMilliseconds / 1000.0);
  // ---- Upload: real bytes sent to the test endpoint. If it does not
  // accept the upload, upload stays null and the caller shows N/A.
  onStage?.call('upload');
  final upSamples = <double>[];
  var upBytes = 0;
  double? upMbps;
  String? upError;
  final upSw = Stopwatch()..start();
  var upWindowBytes = 0;
  var upWindowStart = upSw.elapsedMilliseconds;
  try {
    const total = 2 * 1024 * 1024;
    final chunk = List<int>.filled(64 * 1024, 0x41);
    final c = clientFactory(const Duration(seconds: 6));
    try {
      final req = await c.postUrl(Uri.parse('https://speed.cloudflare.com/__up'));
      req.contentLength = total;
      var sent = 0;
      while (sent < total && !cancelled() && upSw.elapsedMilliseconds <= 12000) {
        final n = min(chunk.length, total - sent);
        req.add(chunk.sublist(0, n));
        sent += n;
        upBytes = sent;
        final now = upSw.elapsedMilliseconds;
        if (now - upWindowStart >= 250) {
          final sec = (now - upWindowStart) / 1000.0;
          if (sec > 0) upSamples.add(upWindowBytes * 8 / sec / 1e6);
          upWindowBytes = 0;
          upWindowStart = now;
        }
        await req.flush();
        upWindowBytes += n;
        if (upWindowBytes > 0) onProgress?.call('upload', null, sent, total);
      }
      if (cancelled()) {
        // fall through with partial data discarded
      } else {
        final res = await req.close().timeout(const Duration(seconds: 10));
        await res.drain();
        if (res.statusCode == 200) {
          final sec = upSw.elapsedMilliseconds / 1000.0;
          if (upBytes >= 50000 && sec > 0) upMbps = upBytes * 8 / sec / 1e6;
        } else {
          upError = 'Upload endpoint returned ${res.statusCode}';
        }
      }
    } finally {
      c.close(force: true);
    }
  } catch (_) {
    upError = 'Upload endpoint timed out on this tunnel';
  }
  if (cancelled()) return SpeedResult(downloadMbps: dlMbps, downloadSamples: dlSamples, pingMs: pingMs, jitterMs: jitterMs, failedProbes: failed, cancelled: true, durationSec: totalSw.elapsedMilliseconds / 1000.0);
  return SpeedResult(
    downloadMbps: dlMbps,
    downloadError: dlMbps == null ? dlError : null,
    uploadMbps: upMbps,
    downloadSamples: dlSamples,
    uploadSamples: upSamples,
    pingMs: pingMs,
    jitterMs: jitterMs,
    failedProbes: failed,
    durationSec: totalSw.elapsedMilliseconds / 1000.0,
    uploadError: upMbps == null ? (upError ?? 'Upload endpoint did not accept the test') : null,
  );
}
