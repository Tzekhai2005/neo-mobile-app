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

/// The lowest and highest real value of the samples that fall in one pixel
/// column. [min] and [max] are NaN when the column has no real sample.
class ColumnRange {
  final double min, max;
  const ColumnRange(this.min, this.max);
  bool get hasData => !min.isNaN;
}

/// Splits [x] into [columns] equal groups and keeps each group's range, so a
/// spike is never lost when many samples share a pixel.
List<ColumnRange> columnRanges(Float32List x, int columns) {
  if (columns <= 0) return const [];
  final n = x.length;
  return [
    for (var c = 0; c < columns; c++)
      () {
        final from = (c * n / columns).floor();
        final to = math.max(from + 1, ((c + 1) * n / columns).floor()).clamp(0, n);
        var lo = double.infinity, hi = double.negativeInfinity;
        for (var i = from; i < to; i++) {
          final v = x[i];
          if (v.isNaN) continue;
          if (v < lo) lo = v;
          if (v > hi) hi = v;
        }
        return lo == double.infinity ? const ColumnRange(double.nan, double.nan) : ColumnRange(lo, hi);
      }()
  ];
}

/// Where a value sits in a lane: -1 at the bottom edge, 0 in the middle, +1 at
/// the top edge. A value beyond the scale is held at the edge.
double laneFraction(double value, double scale) => (value / scale).clamp(-1.0, 1.0);

/// A run of samples, [from] up to but not including [to].
class Run {
  final int from, to;
  const Run(this.from, this.to);
  int get length => to - from;
}

/// Runs where the value is beyond +[scale] (above) or below -[scale] (below),
/// so the view can mark that the trace left its lane.
({List<Run> above, List<Run> below}) overflowRuns(Float32List x, double scale) {
  final above = <Run>[], below = <Run>[];
  int? a, b;
  for (var i = 0; i <= x.length; i++) {
    final v = i < x.length ? x[i] : 0.0;
    final isAbove = !v.isNaN && v > scale;
    final isBelow = !v.isNaN && v < -scale;
    if (isAbove) {
      a ??= i;
    } else if (a != null) {
      above.add(Run(a, i));
      a = null;
    }
    if (isBelow) {
      b ??= i;
    } else if (b != null) {
      below.add(Run(b, i));
      b = null;
    }
  }
  return (above: above, below: below);
}

/// Runs where no series of a lane has a real sample: samples that were lost.
List<Run> gapRuns(List<Float32List> series) {
  if (series.isEmpty) return const [];
  final n = series.first.length;
  final runs = <Run>[];
  int? start;
  for (var i = 0; i <= n; i++) {
    final missing = i < n && series.every((s) => i < s.length && s[i].isNaN);
    if (missing) {
      start ??= i;
    } else if (start != null) {
      runs.add(Run(start, i));
      start = null;
    }
  }
  return runs;
}

/// Joins runs that are within [gap] samples of each other.
List<Run> mergeRuns(List<Run> runs, int gap) {
  if (runs.isEmpty) return const [];
  final out = <Run>[runs.first];
  for (final r in runs.skip(1)) {
    final last = out.last;
    if (r.from - last.to <= gap) {
      out[out.length - 1] = Run(last.from, r.to);
    } else {
      out.add(r);
    }
  }
  return out;
}

/// "−10 s", "start", "+25 s": a time relative to a reference point.
String relativeSeconds(double sec, {String zero = 'now'}) {
  final r = sec.round();
  if (r == 0) return zero;
  return r < 0 ? '−${r.abs()} s' : '+$r s';
}
