import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'trace_layout.dart';
import 'trace_math.dart';
import 'trace_models.dart';

/// Stacked lanes of signal: EEG channels, accelerometer, gyro. It draws what it
/// is given and holds no state, so the live view and the review view share it.
///
///  * every trace is clipped to its own lane; where it leaves the lane a small
///    arrow marks the edge it crossed;
///  * samples that were lost are a visible gap with a red band, never a smoothed line;
///  * markers, spans and time labels are laid over all the lanes.
class SignalLanes extends StatelessWidget {
  final TraceData data;

  /// Called with the index of the lane that was tapped.
  final ValueChanged<int>? onLaneTap;

  const SignalLanes({super.key, required this.data, this.onLaneTap});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, c.hasBoundedHeight ? c.maxHeight : 80.0 * math.max(1, data.lanes.length) + 18);
      final layout = TraceLayout.compute(size, [for (final l in data.lanes) l.weight]);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: onLaneTap == null
            ? null
            : (d) {
                final i = layout.laneAt(d.localPosition);
                if (i != null) onLaneTap!(i);
              },
        child: CustomPaint(size: size, painter: _LanesPainter(data, layout, DefaultTextStyle.of(context).style)),
      );
    });
  }
}

class _LanesPainter extends CustomPainter {
  final TraceData data;
  final TraceLayout layout;

  /// The app's own text style, so labels use the same font as everything else.
  final TextStyle base;

  _LanesPainter(this.data, this.layout, this.base);

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < data.lanes.length; i++) {
      _paintLane(canvas, data.lanes[i], layout.lanes[i]);
    }
    _paintMarkers(canvas, size);
    // Time labels: where each would sit, then only as many as fit side by side.
    final spots = <({double left, double width, bool important})>[];
    for (final t in data.ticks) {
      final w = _measure(base, t.label);
      final x = layout.xOf(t.t, data.durationSec, size.width);
      final left = (x - w / 2).clamp(0.0, math.max(0.0, size.width - w)).toDouble();
      spots.add((left: left, width: w, important: t.important));
    }
    for (final i in visibleLabels(spots)) {
      _text(canvas, base, data.ticks[i].label, Offset(spots[i].left, layout.axis.top + 3), color: AppColors.textMuted);
    }
  }

  void _paintLane(Canvas canvas, TraceLane lane, Rect r) {
    final rrect = RRect.fromRectAndRadius(r, const Radius.circular(10));
    canvas.drawRRect(rrect, Paint()..color = AppColors.surface);
    canvas.save();
    canvas.clipRRect(rrect);

    for (final s in data.spans) {
      final x0 = layout.xOf(s.start, data.durationSec, r.width), x1 = layout.xOf(s.end, data.durationSec, r.width);
      canvas.drawRect(Rect.fromLTRB(x0, r.top, math.max(x1, x0 + 2), r.bottom), Paint()..color = s.color);
    }

    // The zero line.
    canvas.drawLine(Offset(r.left, r.center.dy), Offset(r.right, r.center.dy),
        Paint()..color = AppColors.border..strokeWidth = 1);

    // Lost samples: a red band, and its name when there is room.
    if (lane.series.isNotEmpty && lane.series.first.isNotEmpty) {
      final n = lane.series.first.length;
      for (final g in mergeRuns(gapRuns(lane.series), 0)) {
        final x0 = r.left + g.from / n * r.width, x1 = r.left + g.to / n * r.width;
        canvas.drawRect(Rect.fromLTRB(x0, r.top, math.max(x1, x0 + 1.5), r.bottom),
            Paint()..color = AppColors.danger.withValues(alpha: 0.13));
        if (r.height >= 60 && x1 - x0 >= 30) {
          _text(canvas, base, 'lost', Offset((x0 + x1) / 2, r.top + 4), anchor: _Anchor.center, color: AppColors.danger);
        }
      }
    }

    for (var k = 0; k < lane.series.length; k++) {
      final raw = lane.series[k];
      if (raw.isEmpty) continue;
      final v = lane.removeBaseline ? removeBaseline(raw, lane.rateHz) : raw;
      canvas.drawPath(
        _tracePath(v, r, lane.scale),
        Paint()
          ..color = lane.colors[math.min(k, lane.colors.length - 1)]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..strokeJoin = StrokeJoin.round,
      );
      _paintOverflow(canvas, v, r, lane.scale, lane.colors[math.min(k, lane.colors.length - 1)]);
    }
    canvas.restore();
    canvas.drawRRect(rrect, Paint()..color = AppColors.border..style = PaintingStyle.stroke..strokeWidth = 1);

    // Labels last, on a faint chip so a trace under them does not hide them.
    var x = r.left + 8;
    x += _text(canvas, base, lane.label, Offset(x, r.top + 5), color: AppColors.textSecondary, bold: true, chip: true) + 6;
    for (var k = 0; k < lane.seriesNames.length; k++) {
      x += _text(canvas, base, lane.seriesNames[k], Offset(x, r.top + 5),
              color: lane.colors[math.min(k, lane.colors.length - 1)], bold: true, chip: true) +
          5;
    }
    if (r.height >= 44) {
      _text(canvas, base, '±${_trim(lane.scale)} ${lane.unit}', Offset(r.right - 8, r.bottom - 16),
          anchor: _Anchor.right, color: AppColors.textMuted, chip: true);
    }
  }

  Path _tracePath(Float32List v, Rect r, double scale) {
    final n = v.length;
    final path = Path();
    final half = r.height / 2 * 0.92, cy = r.center.dy;
    double y(double value) => cy - laneFraction(value, scale) * half;

    if (n <= r.width * 1.5) {
      var pen = false;
      for (var i = 0; i < n; i++) {
        if (v[i].isNaN) {
          pen = false;
          continue;
        }
        final x = r.left + (n == 1 ? 0 : i / (n - 1) * r.width);
        pen ? path.lineTo(x, y(v[i])) : path.moveTo(x, y(v[i]));
        pen = true;
      }
      return path;
    }

    // Many samples per pixel: draw each column's lowest-to-highest range.
    final ranges = columnRanges(v, r.width.floor());
    var pen = false;
    var lastY = 0.0;
    for (var c = 0; c < ranges.length; c++) {
      final g = ranges[c];
      if (!g.hasData) {
        pen = false;
        continue;
      }
      final x = r.left + c + 0.5;
      final top = y(g.max), bottom = y(g.min);
      if (!pen) {
        path.moveTo(x, top);
        path.lineTo(x, bottom);
        lastY = bottom;
        pen = true;
      } else if ((lastY - top).abs() <= (lastY - bottom).abs()) {
        path.lineTo(x, top);
        path.lineTo(x, bottom);
        lastY = bottom;
      } else {
        path.lineTo(x, bottom);
        path.lineTo(x, top);
        lastY = top;
      }
    }
    return path;
  }

  void _paintOverflow(Canvas canvas, Float32List v, Rect r, double scale, Color color) {
    final o = overflowRuns(v, scale);
    final n = v.length;
    if (n == 0) return;
    final gap = (n / r.width * 8).ceil();
    final paint = Paint()..color = color;
    void arrows(List<Run> runs, bool up) {
      for (final run in mergeRuns(runs, gap).take(12)) {
        final x = r.left + (run.from + run.to) / 2 / n * r.width;
        final y = up ? r.top + 3 : r.bottom - 3;
        final d = up ? 5.0 : -5.0;
        canvas.drawPath(
          Path()
            ..moveTo(x, y)
            ..lineTo(x - 4, y + d)
            ..lineTo(x + 4, y + d)
            ..close(),
          paint,
        );
      }
    }

    arrows(o.above, true);
    arrows(o.below, false);
  }

  void _paintMarkers(Canvas canvas, Size size) {
    if (layout.lanes.isEmpty) return;
    final top = layout.lanes.first.top, bottom = layout.lanes.last.bottom;
    final labelled = <({double x, TraceMarker m, double left, double width})>[];
    for (final m in data.markers) {
      final x = layout.xOf(m.t, data.durationSec, size.width);
      final paint = Paint()..color = m.color..strokeWidth = 1.3;
      for (var y = top; y < bottom; y += 7) {
        canvas.drawLine(Offset(x, y), Offset(x, math.min(y + 4, bottom)), paint);
      }
      if (m.label != null) {
        final w = _measure(base, m.label!, bold: true);
        final onRight = x + 4 + w <= size.width - 2;
        labelled.add((x: x, m: m, left: onRight ? x + 4 : x - 4 - w, width: w));
      }
    }
    // Labels that would collide go on rows below each other.
    labelled.sort((a, b) => a.left.compareTo(b.left));
    final rows = stackLabelRows([for (final l in labelled) (left: l.left, width: l.width)]);
    for (var i = 0; i < labelled.length; i++) {
      final l = labelled[i];
      _text(canvas, base, l.m.label!, Offset(l.left, top + 5 + rows[i] * 16),
          color: l.m.color, bold: true, chip: true);
    }
  }

  static String _trim(double v) => v == v.roundToDouble() ? v.round().toString() : v.toString();

  @override
  bool shouldRepaint(covariant _LanesPainter old) => old.data != data || old.base != base;
}

enum _Anchor { left, center, right }

double _measure(TextStyle base, String s, {bool bold = false}) => (TextPainter(
      text: TextSpan(text: s, style: base.copyWith(fontSize: 11, fontWeight: bold ? FontWeight.w600 : FontWeight.w400)),
      textDirection: TextDirection.ltr,
    )..layout())
    .width;

/// Draws text and returns its width. [chip] puts a faint background behind it.
double _text(
  Canvas canvas,
  TextStyle base,
  String s,
  Offset at, {
  _Anchor anchor = _Anchor.left,
  Color color = AppColors.text,
  bool bold = false,
  bool chip = false,
}) {
  final tp = TextPainter(
    text: TextSpan(text: s, style: base.copyWith(fontSize: 11, color: color, fontWeight: bold ? FontWeight.w600 : FontWeight.w400)),
    textDirection: TextDirection.ltr,
  )..layout();
  final dx = switch (anchor) {
    _Anchor.left => at.dx,
    _Anchor.center => at.dx - tp.width / 2,
    _Anchor.right => at.dx - tp.width,
  };
  if (chip) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(dx - 3, at.dy - 1, tp.width + 6, tp.height + 2), const Radius.circular(4)),
      Paint()..color = AppColors.surface.withValues(alpha: 0.85),
    );
  }
  tp.paint(canvas, Offset(dx, at.dy));
  return tp.width;
}
