import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/recording_source.dart';
import '../../data/review_event.dart';
import '../../review/review_controller.dart';
import '../../review/timeline_model.dart';
import '../theme/app_theme.dart';

/// The compressed timeline of the days on show: one mark per event at its real time,
/// as tall as its score band, with the patient's button presses in a row above.
/// With the signal switched on, the EEG envelope and the movement sit behind the marks.
///
/// Pinch to zoom, drag to slide, tap a mark to open the event (the Reset zoom button
/// above zooms back out; a double-tap is not used, because it would make every single
/// tap wait to see whether a second one follows). Marks that would touch at this zoom become one with a count; tapping that
/// lists them.
class ReviewTimeline extends StatelessWidget {
  static const height = 176.0;

  final ReviewController controller;

  /// A tap landed on several events at once.
  final ValueChanged<TimelineCluster> onCluster;

  const ReviewTimeline({super.key, required this.controller, required this.onCluster});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth;
      final snap = controller.snapshotFor(width);
      final selected = controller.selected;
      return _Gestures(
        controller: controller,
        snap: snap,
        width: width,
        onCluster: onCluster,
        child: CustomPaint(
          key: const ValueKey('timeline'),
          size: Size(width, height),
          painter: _TimelinePainter(
            snap: snap,
            showSignal: controller.showSignal,
            selectedId: controller.selectedId,
            selectedStartSec: selected?.event.startSec(controller.info.eegRateHz),
            base: DefaultTextStyle.of(context).style,
          ),
        ),
      );
    });
  }
}

class _Gestures extends StatefulWidget {
  final ReviewController controller;
  final TimelineSnapshot snap;
  final double width;
  final ValueChanged<TimelineCluster> onCluster;
  final Widget child;

  const _Gestures({
    required this.controller,
    required this.snap,
    required this.width,
    required this.onCluster,
    required this.child,
  });

  @override
  State<_Gestures> createState() => _GesturesState();
}

class _GesturesState extends State<_Gestures> {
  double _lastScale = 1;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: (_) => _lastScale = 1,
      onScaleUpdate: (d) {
        if (d.pointerCount >= 2 && d.scale > 0) {
          c.zoom(d.scale / _lastScale, (d.localFocalPoint.dx / widget.width).clamp(0.0, 1.0));
          _lastScale = d.scale;
        }
        // Dragging slides the view; the part under the fingers follows them.
        c.pan(-d.focalPointDelta.dx / widget.width * c.visible.lengthSec);
      },
      onTapUp: (d) {
        final all = [...widget.snap.markers, ...widget.snap.bars];
        // The marker row is on top; prefer it when the tap is up there.
        final inMarkerRow = d.localPosition.dy < _TimelinePainter.markerRowBottom;
        final hit = hitCluster(inMarkerRow ? widget.snap.markers : widget.snap.bars, d.localPosition.dx) ??
            hitCluster(all, d.localPosition.dx);
        if (hit == null) return;
        if (hit.isSingle) {
          c.select(hit.first.event.id);
        } else {
          widget.onCluster(hit);
        }
      },
      child: widget.child,
    );
  }
}

class _TimelinePainter extends CustomPainter {
  static const markerRowBottom = 30.0;
  static const _plotTop = 36.0;
  static const _plotBottom = 138.0;

  final TimelineSnapshot snap;
  final bool showSignal;
  final String? selectedId;
  final double? selectedStartSec;
  final TextStyle base;

  _TimelinePainter({
    required this.snap,
    required this.showSignal,
    required this.selectedId,
    required this.selectedStartSec,
    required this.base,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final track = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, _plotBottom + 4), const Radius.circular(12));
    canvas.drawRRect(track, Paint()..color = AppColors.surface);
    canvas.save();
    canvas.clipRRect(track);

    // Stretches where the signal was too poor to use.
    for (final r in snap.poor) {
      final x0 = snap.xOf(r.startSec, w), x1 = snap.xOf(r.endSec, w);
      canvas.drawRect(Rect.fromLTRB(x0, 0, math.max(x1, x0 + 1.5), _plotBottom + 4), Paint()..color = AppColors.danger.withValues(alpha: 0.12));
    }

    // Day boundaries.
    for (final t in snap.ticks.where((t) => t.dayStart)) {
      final x = snap.xOf(t.sec, w);
      canvas.drawLine(Offset(x, 0), Offset(x, _plotBottom + 4), Paint()..color = AppColors.border..strokeWidth = 1);
    }

    if (showSignal) _paintSignal(canvas, w);

    // Base line the marks stand on.
    canvas.drawLine(Offset(0, _plotBottom), Offset(w, _plotBottom), Paint()..color = AppColors.border..strokeWidth = 1);

    // The selected event's start.
    final s = selectedStartSec;
    if (s != null && s >= snap.visible.startSec && s <= snap.visible.endSec) {
      final x = snap.xOf(s, w);
      canvas.drawLine(Offset(x, 4), Offset(x, _plotBottom), Paint()..color = AppColors.accent..strokeWidth = 1.4);
    }

    for (final c in snap.bars) {
      _paintBar(canvas, c);
    }
    for (final c in snap.markers) {
      _paintMarker(canvas, c);
    }
    canvas.restore();
    canvas.drawRRect(track, Paint()..color = AppColors.border..style = PaintingStyle.stroke..strokeWidth = 1);

    // Time labels.
    for (final t in snap.ticks) {
      final x = snap.xOf(t.sec, w);
      final tp = _label(t.label, bold: t.dayStart);
      final left = (x - tp.width / 2).clamp(0.0, math.max(0.0, w - tp.width)).toDouble();
      tp.paint(canvas, Offset(left, _plotBottom + 10));
    }
  }

  void _paintSignal(Canvas canvas, double w) {
    final ov = snap.overview;
    if (ov.count == 0) return;
    final mid = (_plotTop + _plotBottom) / 2, half = (_plotBottom - _plotTop) / 2;

    // The envelope over all channels, centred on its own middle and scaled to its
    // own size, so a recording with a large offset still sits in the plot.
    final lo = Float64List.fromList([for (var i = 0; i < ov.count; i++) _min(ov, i)]);
    final hi = Float64List.fromList([for (var i = 0; i < ov.count; i++) _max(ov, i)]);
    final centre = ([for (var i = 0; i < ov.count; i++) (lo[i] + hi[i]) / 2]..sort())[ov.count ~/ 2];
    final mags = [for (var i = 0; i < ov.count; i++) math.max((hi[i] - centre).abs(), (lo[i] - centre).abs())]..sort();
    final peak = math.max(mags[(mags.length * 0.98).floor().clamp(0, mags.length - 1)], 1e-6);
    final top = Path(), bottom = <Offset>[];
    for (var i = 0; i < ov.count; i++) {
      final x = snap.xOf(ov.startSec + (i + 0.5) * ov.binSec, w);
      final yHi = mid - ((hi[i] - centre) / peak).clamp(-1.0, 1.0) * half * 0.9;
      final yLo = mid - ((lo[i] - centre) / peak).clamp(-1.0, 1.0) * half * 0.9;
      i == 0 ? top.moveTo(x, yHi) : top.lineTo(x, yHi);
      bottom.add(Offset(x, yLo));
    }
    for (final p in bottom.reversed) {
      top.lineTo(p.dx, p.dy);
    }
    top.close();
    canvas.drawPath(top, Paint()..color = AppColors.channel[0].withValues(alpha: 0.30));

    // Movement along the bottom.
    for (var i = 0; i < ov.count; i++) {
      final x0 = snap.xOf(ov.startSec + i * ov.binSec, w), x1 = snap.xOf(ov.startSec + (i + 1) * ov.binSec, w);
      final h = ov.activity[i].clamp(0.0, 1.0) * (_plotBottom - _plotTop) * 0.3;
      canvas.drawRect(Rect.fromLTRB(x0, _plotBottom - h, math.max(x1, x0 + 0.8), _plotBottom), Paint()..color = AppColors.axis[1].withValues(alpha: 0.55));
    }
  }

  static double _min(OverviewBins ov, int i) {
    var m = double.infinity;
    for (final ch in ov.eegMin) {
      m = math.min(m, ch[i]);
    }
    return m;
  }

  static double _max(OverviewBins ov, int i) {
    var m = double.negativeInfinity;
    for (final ch in ov.eegMax) {
      m = math.max(m, ch[i]);
    }
    return m;
  }

  void _paintBar(Canvas canvas, TimelineCluster c) {
    final room = _plotBottom - _plotTop;
    final h = math.max(10.0, barFraction(c.topBand) * room);
    final rect = RRect.fromRectAndRadius(Rect.fromLTRB(c.left, _plotBottom - h, c.right, _plotBottom), const Radius.circular(2));
    final color = _color(c.status);
    final selected = selectedId != null && c.contains(selectedId!);
    canvas.drawRRect(rect, Paint()..color = c.status == ReviewStatus.confirmed ? color : color.withValues(alpha: c.status == ReviewStatus.dismissed ? 0.5 : 0.30));
    canvas.drawRRect(rect, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.3);
    if (selected) {
      canvas.drawRRect(rect.inflate(2.5), Paint()..color = AppColors.accent..style = PaintingStyle.stroke..strokeWidth = 2);
    }
    if (!c.isSingle) _count(canvas, Offset(c.center, _plotBottom - h - 11), c.events.length);
  }

  void _paintMarker(Canvas canvas, TimelineCluster c) {
    final cx = c.center, cy = 16.0;
    final color = c.status == ReviewStatus.dismissed ? AppColors.textMuted : const Color(0xFFD4472B);
    final path = Path()
      ..moveTo(cx, cy - 8)
      ..lineTo(cx + 8, cy)
      ..lineTo(cx, cy + 8)
      ..lineTo(cx - 8, cy)
      ..close();
    canvas.drawPath(path, Paint()..color = c.status == ReviewStatus.candidate ? color.withValues(alpha: 0.2) : color);
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.5);
    if (selectedId != null && c.contains(selectedId!)) {
      canvas.drawCircle(Offset(cx, cy), 12, Paint()..color = AppColors.accent..style = PaintingStyle.stroke..strokeWidth = 2);
    }
    if (!c.isSingle) _count(canvas, Offset(cx + 10, cy - 8), c.events.length);
  }

  void _count(Canvas canvas, Offset at, int n) {
    final tp = _label('$n', color: Colors.white, bold: true);
    final r = math.max(8.0, tp.width / 2 + 4);
    canvas.drawCircle(at, r, Paint()..color = AppColors.navy);
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  TextPainter _label(String s, {bool bold = false, Color color = AppColors.textMuted}) => TextPainter(
        text: TextSpan(text: s, style: base.copyWith(fontSize: 11, color: color, fontWeight: bold ? FontWeight.w600 : FontWeight.w400)),
        textDirection: TextDirection.ltr,
      )..layout();

  Color _color(ReviewStatus s) => switch (s) {
        ReviewStatus.candidate => AppColors.warning,
        ReviewStatus.confirmed => AppColors.success,
        ReviewStatus.dismissed => AppColors.textMuted,
      };

  @override
  bool shouldRepaint(covariant _TimelinePainter old) =>
      !identical(old.snap, snap) || old.showSignal != showSignal || old.selectedId != selectedId || old.selectedStartSec != selectedStartSec;
}
