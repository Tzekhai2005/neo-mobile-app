import 'dart:ui';

/// Where each lane sits in a view of a given size. Pure geometry, so it can be
/// tested and shared by the painter and by tap handling.
class TraceLayout {
  final List<Rect> lanes;
  final Rect axis;

  const TraceLayout(this.lanes, this.axis);

  /// Stacks lanes top to bottom, sharing the height by [weights], with [gap]
  /// between them and [axisHeight] left under the last one for the time labels.
  factory TraceLayout.compute(Size size, List<double> weights, {double gap = 6, double axisHeight = 18}) {
    if (weights.isEmpty) return TraceLayout(const [], Rect.fromLTWH(0, size.height - axisHeight, size.width, axisHeight));
    final usable = size.height - axisHeight - gap * (weights.length - 1);
    final total = weights.fold<double>(0, (a, b) => a + b);
    final lanes = <Rect>[];
    var y = 0.0;
    for (final w in weights) {
      final h = usable * w / total;
      lanes.add(Rect.fromLTWH(0, y, size.width, h));
      y += h + gap;
    }
    return TraceLayout(lanes, Rect.fromLTWH(0, size.height - axisHeight, size.width, axisHeight));
  }

  /// The lane under [p], or null (between lanes, or on the axis).
  int? laneAt(Offset p) {
    for (var i = 0; i < lanes.length; i++) {
      if (lanes[i].contains(p)) return i;
    }
    return null;
  }

  /// The x position of [t] seconds, in a view covering [durationSec].
  double xOf(double t, double durationSec, double width) =>
      durationSec <= 0 ? 0 : (t / durationSec * width).clamp(0.0, width);
}

/// Gives each label a row so that labels never sit on top of each other. A
/// label that fits beside the ones already placed stays on the first row; one
/// that would overlap moves down a row. Labels are given as (left, width) pairs
/// in the order they should be placed; the result has one row number per label.
List<int> stackLabelRows(List<({double left, double width})> labels, {double pad = 4}) {
  final rowEnds = <double>[]; // right edge of the last label on each row
  final rows = <int>[];
  for (final l in labels) {
    var row = rowEnds.indexWhere((end) => l.left >= end + pad);
    if (row < 0) {
      row = rowEnds.length;
      rowEnds.add(0);
    }
    rowEnds[row] = l.left + l.width;
    rows.add(row);
  }
  return rows;
}

/// Which labels to draw so that none overlap. Labels are given left to right as
/// (left, width, important); important ones are always kept, and the others are
/// kept, in order, only when they leave [pad] pixels clear of every label kept
/// before them. Returns the indexes to draw.
List<int> visibleLabels(List<({double left, double width, bool important})> labels, {double pad = 6}) {
  final kept = <int>[];
  bool clear(int i) => kept.every((k) {
        final a = labels[i], b = labels[k];
        return a.left >= b.left + b.width + pad || b.left >= a.left + a.width + pad;
      });
  for (var i = 0; i < labels.length; i++) {
    if (labels[i].important) kept.add(i);
  }
  for (var i = 0; i < labels.length; i++) {
    if (!labels[i].important && clear(i)) kept.add(i);
  }
  return kept..sort();
}
