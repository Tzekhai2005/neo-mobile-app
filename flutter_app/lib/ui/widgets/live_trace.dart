import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../device/device_status.dart';
import '../../live/live_signal_buffer.dart';

/// Squeezes live samples into `points` values between -1 and 1 for a small
/// preview. The slow offset is removed (the mean), the size is set from the
/// signal itself (its 5th to 95th percentile), and a stretch of missing samples
/// stays NaN so it draws as a gap. There is no axis: this is a preview, not a
/// measurement. Returns null when there are fewer than two real samples.
Float64List? normalizeTrace(Float32List samples, {int points = 160}) {
  if (samples.isEmpty || points < 2) return null;
  final bucket = samples.length / points;
  final avg = Float64List(points);
  var finite = 0;
  for (var i = 0; i < points; i++) {
    final from = (i * bucket).floor();
    final to = math.max(from + 1, ((i + 1) * bucket).floor()).clamp(0, samples.length);
    var sum = 0.0;
    var n = 0;
    for (var k = from; k < to; k++) {
      final v = samples[k];
      if (!v.isNaN) {
        sum += v;
        n++;
      }
    }
    avg[i] = n == 0 ? double.nan : sum / n;
    if (n > 0) finite++;
  }
  if (finite < 2) return null;
  final vals = [for (final v in avg) if (!v.isNaN) v]..sort();
  final mean = vals.reduce((a, b) => a + b) / vals.length;
  final lo = vals[(vals.length * 0.05).floor()];
  final hi = vals[math.min(vals.length - 1, (vals.length * 0.95).floor())];
  final half = math.max((hi - lo) / 2, 1e-6); // a flat line stays flat, not blown up
  final out = Float64List(points);
  for (var i = 0; i < points; i++) {
    out[i] = avg[i].isNaN ? double.nan : ((avg[i] - mean) / half).clamp(-1.0, 1.0);
  }
  return out;
}

/// A small live preview of the first EEG channel. Drawn from [buffer] while the
/// device streams; a flat, faint line when it does not. It repaints about eight
/// times a second, and only while the device is connected.
class LiveTraceStrip extends StatefulWidget {
  final LiveSignalBuffer buffer;
  final ValueListenable<DeviceStatus> status;
  final Color color;
  final double seconds;

  const LiveTraceStrip({
    super.key,
    required this.buffer,
    required this.status,
    required this.color,
    this.seconds = 4,
  });

  @override
  State<LiveTraceStrip> createState() => _LiveTraceStripState();
}

class _LiveTraceStripState extends State<LiveTraceStrip> {
  Timer? _timer;
  Float64List? _trace;

  @override
  void initState() {
    super.initState();
    widget.status.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    widget.status.removeListener(_sync);
    _timer?.cancel();
    super.dispose();
  }

  void _sync() {
    final live = widget.status.value.link == LinkState.connected;
    if (live && _timer == null) {
      _timer = Timer.periodic(const Duration(milliseconds: 120), (_) => _refresh());
    } else if (!live) {
      _timer?.cancel();
      _timer = null;
      if (_trace != null && mounted) setState(() => _trace = null);
    }
  }

  void _refresh() {
    if (!mounted || !widget.buffer.hasData) return;
    final snap = widget.buffer.snapshot(seconds: widget.seconds);
    final next = snap.eeg.isEmpty ? null : normalizeTrace(snap.eeg.first);
    setState(() => _trace = next);
  }

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _TracePainter(_trace, widget.color), size: Size.infinite);
}

class _TracePainter extends CustomPainter {
  final Float64List? trace;
  final Color color;

  _TracePainter(this.trace, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final t = trace;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (t == null) {
      paint.color = color.withValues(alpha: 0.35);
      canvas.drawLine(Offset(0, mid), Offset(size.width, mid), paint);
      return;
    }
    paint.color = color;
    final path = Path();
    var pen = false;
    for (var i = 0; i < t.length; i++) {
      if (t[i].isNaN) {
        pen = false;
        continue;
      }
      final x = i / (t.length - 1) * size.width;
      final y = mid - t[i] * (size.height / 2) * 0.9;
      if (pen) {
        path.lineTo(x, y);
      } else {
        path.moveTo(x, y);
        pen = true;
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _TracePainter old) => old.trace != trace || old.color != color;
}
