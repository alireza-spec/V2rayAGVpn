import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/store.dart';
import '../engine/pool_engine.dart';
import '../engine/psiphon_engine.dart';
import '../engine/speed_test.dart';

/// Live speed-test screen, modelled on the familiar speedtest.net gauge:
/// a large circular gauge with a needle, live ping/download/upload
/// numbers, and a clear stage label, so it is always obvious what the
/// test is doing right now. No number is invented: download/upload are
/// real bytes over real time, ping/jitter are real HTTP round trips,
/// upload is N/A (never a fake number) when the endpoint does not
/// accept it, and packet loss is never claimed from HTTP probes.
class SpeedTestPage extends StatefulWidget {
  const SpeedTestPage(this.s, {super.key, this.autoStart = false});
  final Store s;
  final bool autoStart;

  @override
  State<SpeedTestPage> createState() => _SpeedTestState();
}

class _SpeedTestState extends State<SpeedTestPage> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();
  SpeedResult? _result;
  String _stage = '';
  String _error = '';
  bool _running = false;
  bool _cancel = false;
  double _liveMbps = 0;
  double _gaugeMax = 10;
  int _pingDone = 0;
  int _pingTotal = 5;
  int _doneBytes = 0;
  int _totalBytes = 0;
  String _stageDetail = '';

  bool get _connected => widget.s.engine.state.phase == Phase.connected || widget.s.psiphon.state.phase == PsiphonPhase.connected;
  String get _modeLabel {
    if (widget.s.psiphon.state.phase == PsiphonPhase.connected) return 'Psiphon';
    return widget.s.mode;
  }

  @override
  void initState() {
    super.initState();
    if (widget.autoStart && _connected) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    }
  }

  @override
  void dispose() {
    _cancel = true;
    _anim.dispose();
    super.dispose();
  }

  void _onStage(String stage) {
    if (!mounted) return;
    setState(() {
      _stage = stage;
      _stageDetail = stage == 'ping'
          ? 'Measuring ping…'
          : stage == 'download'
              ? 'Measuring download…'
              : stage == 'upload'
                  ? 'Measuring upload…'
                  : stage;
    });
  }

  void _onProgress(String stage, double? mbps, int done, int total) {
    if (!mounted) return;
    setState(() {
      _stage = stage;
      if (stage == 'ping') {
        _pingDone = done;
        _pingTotal = total;
        _stageDetail = 'Ping $done / $total';
        _liveMbps = 0;
      } else {
        _doneBytes = done;
        _totalBytes = total;
        if (mbps != null && mbps > 0) {
          // Smooth the live value: each 250 ms window is noisy on its
          // own, so blend it into the previous value instead of
          // jumping the needle to every single sample.
          _liveMbps = _liveMbps == 0 ? mbps : (_liveMbps * 0.55 + mbps * 0.45);
          if (_liveMbps * 1.25 > _gaugeMax) _gaugeMax = _liveMbps * 1.25;
        }
        final pct = total > 0 ? (done * 100 ~/ total) : 0;
        _stageDetail = stage == 'download' ? 'Download $pct%  ·  ${(done / 1048576).toStringAsFixed(1)} MB' : 'Upload $pct%  ·  ${(done / 1048576).toStringAsFixed(1)} MB';
      }
    });
  }

  Future<void> _start() async {
    if (_running || !_connected) return;
    setState(() {
      _running = true;
      _cancel = false;
      _result = null;
      _error = '';
      _stage = 'ping';
      _stageDetail = 'Measuring ping…';
      _liveMbps = 0;
      _gaugeMax = 10;
      _pingDone = 0;
      _doneBytes = 0;
      _totalBytes = 0;
    });
    SpeedResult r;
    try {
      if (widget.s.psiphon.state.phase == PsiphonPhase.connected) {
        final port = widget.s.psiphon.state.httpPort ?? 0;
        r = await runSpeedTest(
          (ct) {
            final c = HttpClient()..connectionTimeout = ct;
            if (port > 0) c.findProxy = (_) => 'PROXY 127.0.0.1:$port';
            return c;
          },
          isCancelled: () => _cancel,
          onStage: _onStage,
          onProgress: _onProgress,
        );
      } else {
        r = await widget.s.engine.speedTestDetailed(onStage: _onStage, onProgress: _onProgress);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = 'Speed test failed. Check the connection and try again.';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      if (r.cancelled) {
        _error = 'Test cancelled';
      } else {
        _result = r;
        _liveMbps = r.downloadMbps ?? 0;
        if (_liveMbps > 0 && _liveMbps * 1.25 > _gaugeMax) _gaugeMax = _liveMbps * 1.25;
        widget.s.addSpeedResult(r, _modeLabel);
      }
    });
  }

  Widget _metric(String label, String value) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(14)),
          child: Column(children: [
            Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final r = _result;
    final gaugeValue = _running ? _liveMbps : (r?.downloadMbps ?? 0);
    final gaugeMax = math.max(math.max(_gaugeMax, gaugeValue * 1.25), 10.0);
    return Scaffold(
      appBar: AppBar(title: Text(widget.s.t('speedtest'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (!_connected)
          Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(widget.s.t('speedneedconn'), textAlign: TextAlign.center))),
        Text('speed.cloudflare.com  ·  ${_connected ? 'via active tunnel ($_modeLabel)' : 'not connected'}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 8),
        Center(
          child: SizedBox(
            width: 280,
            height: 280,
            child: TweenAnimationBuilder<double>(
              // Animate the needle between samples instead of teleporting
              // it: the gauge glides up and down as the speed changes.
              duration: const Duration(milliseconds: 300),
              tween: Tween<double>(begin: 0, end: gaugeValue),
              builder: (context, animatedValue, _) => CustomPaint(
                painter: _GaugePainter(animatedValue, gaugeMax, accent, _running ? _anim.value : 0),
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_running ? _stageDetail : (r == null ? widget.s.t('speedtest') : 'Done'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, fontSize: 13)),
                  const SizedBox(height: 6),
                  Text(gaugeValue > 0 ? gaugeValue.toStringAsFixed(1) : '-', style: const TextStyle(fontSize: 48, fontWeight: FontWeight.w300)),
                  const Text('Mbps download', style: TextStyle(color: Colors.grey)),
                  if (_running) ...[
                    const SizedBox(height: 10),
                    const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                  if (r != null && r.pingMs != null) ...[
                    const SizedBox(height: 6),
                    Text('Ping ${r.pingMs} ms', style: const TextStyle(fontWeight: FontWeight.w700)),
                  ],
                ]),
              ),
            ),
          ),
        ),
        ),
        const SizedBox(height: 8),
        if (_running && _stage != 'ping')
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(value: _totalBytes > 0 ? (_doneBytes / _totalBytes).clamp(0.0, 1.0) : null, minHeight: 6),
          ),
        if (_running && _stage == 'ping')
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(value: _pingTotal > 0 ? (_pingDone / _pingTotal).clamp(0.0, 1.0) : null, minHeight: 6),
          ),
        if (_error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent))),
        const SizedBox(height: 12),
        Row(children: [
          _metric('Ping', r == null ? (_running ? '…' : '-') : (r.pingMs == null ? '-' : '${r.pingMs} ms')),
          const SizedBox(width: 8),
          _metric('Download', r == null ? (_running ? '…' : '-') : (r.downloadMbps == null ? '-' : '${r.downloadMbps!.toStringAsFixed(1)} Mbps')),
          const SizedBox(width: 8),
          _metric('Upload', r == null ? (_running ? '…' : '-') : (r.uploadMbps == null ? 'N/A' : '${r.uploadMbps!.toStringAsFixed(1)} Mbps')),
        ]),
        if (r != null) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                _infoRow('Jitter', r.jitterMs == null ? '-' : '${r.jitterMs} ms'),
                _infoRow('Failed probes', '${r.failedProbes} / 5'),
                _infoRow('Duration', '${r.durationSec.toStringAsFixed(1)} s'),
                _infoRow('Mode', _modeLabel),
                if (r.downloadMbps == null) Text(r.downloadError ?? 'Download did not finish on this tunnel', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                if (r.uploadMbps == null) Text(r.uploadError ?? 'Upload unavailable', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                const Text('Packet loss is not claimed from HTTP probes; only failed probe counts are shown.', style: TextStyle(color: Colors.grey, fontSize: 11)),
              ]),
            ),
          ),
          if (r.downloadSamples.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(height: 120, child: CustomPaint(painter: _GraphPainter(r.downloadSamples, accent))),
            const Text('Download speed over time', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ],
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              icon: Icon(_running ? Icons.cancel : Icons.play_arrow),
              label: Text(_running ? widget.s.t('cancel') : widget.s.t('start')),
              onPressed: _running
                  ? () => setState(() => _cancel = true)
                  : (_connected ? _start : null),
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(icon: const Icon(Icons.refresh), label: Text(widget.s.t('retest')), onPressed: (_running || !_connected) ? null : _start),
        ]),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: Text(widget.s.t('history'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
          if (widget.s.speedHistory.isNotEmpty) TextButton(onPressed: widget.s.clearSpeedHistory, child: Text(widget.s.t('deleteall'))),
        ]),
        if (widget.s.speedHistory.isEmpty)
          const Text('No completed tests yet.', style: TextStyle(color: Colors.grey))
        else
          for (final h in widget.s.speedHistory)
            ListTile(
              dense: true,
              title: Text('${h['mode']}  ·  ${h['download'] == null ? '-' : '${(h['download'] as num).toStringAsFixed(1)} Mbps'} down  ·  ${h['upload'] == null ? 'N/A' : '${(h['upload'] as num).toStringAsFixed(1)} Mbps'} up'),
              subtitle: Text('Ping ${h['ping'] ?? '-'} ms  ·  ${DateTime.fromMillisecondsSinceEpoch(h['at'] as int)}'),
            ),
      ]),
    );
  }
}

Widget _infoRow(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(k, style: const TextStyle(color: Colors.grey)),
        const SizedBox(width: 16),
        Flexible(child: Text(v, textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w700))),
      ]),
    );

class _GaugePainter extends CustomPainter {
  _GaugePainter(this.value, this.max, this.color, this.pulse);
  final double value;
  final double max;
  final Color color;
  final double pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 8;
    const start = math.pi * 0.75;
    const sweep = math.pi * 1.5;
    final bg = Paint()
      ..color = Colors.grey.withOpacity(.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), start, sweep, false, bg);
    final frac = max > 0 ? (value / max).clamp(0.0, 1.0) : 0.0;
    final fg = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round;
    if (frac > 0) canvas.drawArc(Rect.fromCircle(center: center, radius: radius), start, sweep * frac, false, fg);
    final angle = start + sweep * frac;
    final needlePaint = Paint()
      ..color = color.withOpacity(.9)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final tip = center + Offset(math.cos(angle), math.sin(angle)) * (radius - 18);
    canvas.drawLine(center, tip, needlePaint);
    canvas.drawCircle(center, 6, Paint()..color = color);
    if (pulse != 0) {
      final pr = Paint()
        ..color = color.withOpacity(.12 + .08 * math.sin(pulse * 6.2832))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(center, radius + 6, pr);
    }
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) => old.value != value || old.pulse != pulse || old.max != max;
}

class _GraphPainter extends CustomPainter {
  _GraphPainter(this.samples, this.color);
  final List<double> samples;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;
    final maxV = samples.reduce(math.max);
    if (maxV <= 0) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = size.width * (samples.length == 1 ? 0.5 : i / (samples.length - 1));
      final y = size.height - (samples[i] / maxV) * (size.height - 8) - 4;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _GraphPainter old) => old.samples != samples;
}
