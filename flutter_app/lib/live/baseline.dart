import 'dart:math' as math;
import 'dart:typed_data';

/// Takes the slow baseline out of a signal for display: a one-pole high-pass at
/// [cutoffHz]. The baseline starts at the first real sample, so a signal sitting
/// on a large offset starts at zero instead of far off the lane. Missing samples
/// (NaN) stay missing, and the baseline is held across them. The recorded data
/// is never touched; this is only for drawing.
Float32List removeBaseline(Float32List x, int rateHz, {double cutoffHz = 0.5}) {
  final out = Float32List(x.length);
  if (rateHz <= 0) {
    out.setAll(0, x);
    return out;
  }
  final alpha = 1 - math.exp(-2 * math.pi * cutoffHz / rateHz);
  double? base;
  for (var i = 0; i < x.length; i++) {
    final v = x[i];
    if (v.isNaN) {
      out[i] = double.nan;
      continue;
    }
    base ??= v;
    base += alpha * (v - base);
    out[i] = v - base;
  }
  return out;
}
