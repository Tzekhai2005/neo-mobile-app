import 'dart:math' as math;
import 'dart:typed_data';

import '../data/recording_source.dart';

/// Every spark is drawn at the same scale (µV from the middle to the edge), so a
/// bigger event looks bigger in the list.
const double kSparkScaleUv = 150;

/// A small picture of an event's first EEG channel: [points] buckets, each as a
/// minimum and a maximum (so the result has `2 * points` values), between -1 and 1.
/// It spans a few seconds before the event to a few after it, with the slow offset
/// removed. A bucket with no samples is 0, 0.
Float32List sparkOf(SignalWindow w, double eventDurationSec, {int points = 40, double marginSec = 3}) {
  final out = Float32List(points * 2);
  if (w.eeg.isEmpty || w.eeg.first.isEmpty) return out;
  final x = w.eeg.first;
  final rate = w.eegRateHz;
  var from = ((w.preSec - marginSec) * rate).floor().clamp(0, x.length - 1);
  var to = ((w.preSec + math.max(eventDurationSec, 2) + marginSec) * rate).ceil().clamp(from + 1, x.length);
  var sum = 0.0;
  var n = 0;
  for (var i = from; i < to; i++) {
    if (!x[i].isNaN) {
      sum += x[i];
      n++;
    }
  }
  final mean = n == 0 ? 0.0 : sum / n;
  final span = to - from;
  for (var p = 0; p < points; p++) {
    final a = from + (p * span / points).floor();
    final b = math.max(a + 1, from + ((p + 1) * span / points).floor());
    var lo = double.infinity, hi = -double.infinity;
    for (var i = a; i < b && i < to; i++) {
      final v = x[i];
      if (v.isNaN) continue;
      final d = v - mean;
      if (d < lo) lo = d;
      if (d > hi) hi = d;
    }
    if (lo == double.infinity) {
      lo = 0;
      hi = 0;
    }
    out[2 * p] = (lo / kSparkScaleUv).clamp(-1.0, 1.0);
    out[2 * p + 1] = (hi / kSparkScaleUv).clamp(-1.0, 1.0);
  }
  return out;
}
