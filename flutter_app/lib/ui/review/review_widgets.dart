import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/review_event.dart';
import '../../data/score_band.dart';
import '../../review/review_models.dart';
import '../../review/timeline_model.dart';
import '../theme/app_theme.dart';

/// "11 s", "1 min 5 s".
String durationShort(double sec) {
  final s = sec.round();
  if (s < 60) return '$s s';
  final m = s ~/ 60, r = s % 60;
  return r == 0 ? '$m min' : '$m min $r s';
}

/// "Ch1 Ch2", or "Patient button press" for a marker.
String channelsText(ReviewEvent e) =>
    e.isMarker ? 'Patient button press' : [for (final c in e.event.channels) 'Ch${c + 1}'].join(' ');

String bandName(ScoreBand b) =>
    switch (b) { ScoreBand.high => 'High', ScoreBand.medium => 'Medium', ScoreBand.low => 'Low' };

String statusName(ReviewStatus s) => switch (s) {
      ReviewStatus.candidate => 'Unreviewed',
      ReviewStatus.confirmed => 'Confirmed',
      ReviewStatus.dismissed => 'Dismissed',
      ReviewStatus.unsure => 'Not sure',
    };

Color statusColor(ReviewStatus s) => switch (s) {
      ReviewStatus.candidate => AppColors.warning,
      ReviewStatus.confirmed => AppColors.success,
      ReviewStatus.dismissed => AppColors.textMuted,
      ReviewStatus.unsure => AppColors.accent,
    };

/// The small mark at the start of a row: a circle for an event, a diamond for a
/// patient marker; hollow while unreviewed, filled once confirmed, grey when dismissed.
class StatusMark extends StatelessWidget {
  final ReviewStatus status;
  final bool isMarker;

  const StatusMark({super.key, required this.status, required this.isMarker});

  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(20, 20), painter: _MarkPainter(status, isMarker));
}

class _MarkPainter extends CustomPainter {
  final ReviewStatus status;
  final bool isMarker;
  _MarkPainter(this.status, this.isMarker);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final color = isMarker && status != ReviewStatus.dismissed ? const Color(0xFFD4472B) : statusColor(status);
    final filled = status == ReviewStatus.confirmed;
    final fill = Paint()
      ..color = filled ? color : color.withValues(alpha: status == ReviewStatus.dismissed ? 0.5 : 0.18);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    final shape = isMarker
        ? (Path()
          ..moveTo(c.dx, c.dy - 8)
          ..lineTo(c.dx + 8, c.dy)
          ..lineTo(c.dx, c.dy + 8)
          ..lineTo(c.dx - 8, c.dy)
          ..close())
        : (Path()..addOval(Rect.fromCircle(center: c, radius: 7)));
    canvas.drawPath(shape, fill);
    canvas.drawPath(shape, line);
    if (status == ReviewStatus.confirmed) {
      canvas.drawPath(
        Path()
          ..moveTo(c.dx - 3.5, c.dy)
          ..lineTo(c.dx - 1, c.dy + 3)
          ..lineTo(c.dx + 3.5, c.dy - 3),
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MarkPainter old) => old.status != status || old.isMarker != isMarker;
}

/// High, Medium or Low, as a small tag. Never the raw score.
class BandChip extends StatelessWidget {
  final ScoreBand band;
  const BandChip({super.key, required this.band});

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (band) {
      ScoreBand.high => (AppColors.navy, AppColors.onNavy),
      ScoreBand.medium => (AppColors.accentSoft, AppColors.navy),
      ScoreBand.low => (AppColors.surfaceHigh, AppColors.textSecondary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Text(categoryName(categoryOfBand(band)),
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}

/// The colour of each kind of event, in the list, the tiles and the timeline legend.
Color categoryColor(EventCategory c) => switch (c) {
      EventCategory.possibleSeizure => AppColors.danger,
      EventCategory.unusual => AppColors.warning,
      EventCategory.normal => AppColors.accent,
      EventCategory.marked => const Color(0xFFD4472B),
    };

/// A filled dot in the colour of the event's kind (a diamond for a patient press).
class CategoryDot extends StatelessWidget {
  final EventCategory category;
  final double size;
  const CategoryDot({super.key, required this.category, this.size = 14});

  @override
  Widget build(BuildContext context) {
    final c = categoryColor(category);
    if (category == EventCategory.marked) {
      return Transform.rotate(
        angle: 0.785398,
        child: Container(
            width: size * 0.78, height: size * 0.78, decoration: BoxDecoration(border: Border.all(color: c, width: 2))),
      );
    }
    return Container(width: size, height: size, decoration: BoxDecoration(color: c, shape: BoxShape.circle));
  }
}

/// The small picture of an event's signal at the end of a row. While it loads, or if
/// it cannot, there is simply nothing there.
class EventSpark extends StatelessWidget {
  final Future<Float32List?> future;
  final Color color;
  const EventSpark({super.key, required this.future, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      height: 26,
      child: FutureBuilder<Float32List?>(
        future: future,
        builder: (context, snap) {
          final v = snap.data;
          return v == null ? const SizedBox() : CustomPaint(painter: _SparkPainter(v, color));
        },
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final Float32List v;
  final Color color;
  _SparkPainter(this.v, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final n = v.length ~/ 2;
    if (n < 2) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    final mid = size.height / 2;
    for (var i = 0; i < n; i++) {
      final x = i / (n - 1) * size.width;
      final lo = mid - v[2 * i + 1] * mid;
      final hi = mid - v[2 * i] * mid;
      canvas.drawLine(Offset(x, lo), Offset(x, math.max(hi, lo + 0.6)), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) => old.v != v || old.color != color;
}

/// One event in the list: its kind, when and for how long, a small picture of its
/// signal, and what has been decided.
class ReviewRow extends StatelessWidget {
  final ReviewEvent review;
  final String when; // already formatted
  final double durationSec;
  final bool selected;
  final VoidCallback onTap;

  /// The small signal picture; null leaves it out (a patient press has no signal of its own).
  final Future<Float32List?>? spark;

  const ReviewRow({
    super.key,
    required this.review,
    required this.when,
    required this.durationSec,
    required this.selected,
    required this.onTap,
    this.spark,
  });

  @override
  Widget build(BuildContext context) {
    final e = review;
    final cat = e.category;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? AppColors.accentSoft : AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: selected ? AppColors.accent : AppColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('row-${e.event.id}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
            child: Row(children: [
              SizedBox(width: 20, child: Center(child: CategoryDot(category: cat))),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(categoryName(cat), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    [when, if (!e.isMarker) durationShort(durationSec)].join(' · '),
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ]),
              ),
              if (e.note != null)
                const Padding(
                    padding: EdgeInsets.only(left: 6), child: Icon(Icons.notes, size: 16, color: AppColors.textMuted)),
              if (e.status != ReviewStatus.candidate)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(statusName(e.status),
                      style: TextStyle(fontSize: 12, color: statusColor(e.status), fontWeight: FontWeight.w500)),
                ),
              if (spark != null)
                Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: EventSpark(future: spark!, color: categoryColor(cat))),
              const Icon(Icons.chevron_right, size: 18, color: AppColors.textMuted),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The three kinds of automatic event, as tiles with their counts. Tapping one shows
/// only that kind; tapping it again shows everything.
class CategoryTiles extends StatelessWidget {
  final Map<EventCategory, int> counts;
  final EventCategory? selected;
  final ValueChanged<EventCategory> onTap;

  const CategoryTiles({super.key, required this.counts, required this.selected, required this.onTap});

  static const kinds = [EventCategory.possibleSeizure, EventCategory.unusual, EventCategory.normal];

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      for (var i = 0; i < kinds.length; i++) ...[
        if (i > 0) const SizedBox(width: 8),
        Expanded(child: _tile(kinds[i])),
      ],
    ]);
  }

  Widget _tile(EventCategory c) {
    final on = selected == c;
    final color = categoryColor(c);
    return Material(
      color: on ? color.withValues(alpha: 0.12) : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: on ? color : AppColors.border, width: on ? 1.5 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('category-${c.name}'),
        onTap: () => onTap(c),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CategoryDot(category: c, size: 10),
              const SizedBox(width: 6),
              Text('${counts[c] ?? 0}',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.navy)),
            ]),
            const SizedBox(height: 2),
            Text(categoryName(c), maxLines: 2, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ]),
        ),
      ),
    );
  }
}

/// "All", "Unreviewed", "Confirmed", "Dismissed".
class FilterChips extends StatelessWidget {
  final ReviewFilter value;
  final ValueChanged<ReviewFilter> onChanged;

  const FilterChips({super.key, required this.value, required this.onChanged});

  static String label(ReviewFilter f) => switch (f) {
        ReviewFilter.all => 'All',
        ReviewFilter.unreviewed => 'Unreviewed',
        ReviewFilter.confirmed => 'Confirmed',
        ReviewFilter.dismissed => 'Dismissed',
        ReviewFilter.unsure => 'Not sure',
      };

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final f in ReviewFilter.values)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              key: ValueKey('filter-${f.name}'),
              label: Text(label(f)),
              selected: value == f,
              onSelected: (_) => onChanged(f),
              showCheckmark: false,
              selectedColor: AppColors.accentSoft,
              backgroundColor: AppColors.surface,
              side: BorderSide(color: value == f ? AppColors.accent : AppColors.border),
              labelStyle: TextStyle(
                  fontSize: 13,
                  color: value == f ? AppColors.navy : AppColors.textSecondary,
                  fontWeight: value == f ? FontWeight.w600 : FontWeight.w400),
              visualDensity: VisualDensity.compact,
            ),
          ),
      ]),
    );
  }
}

/// The list shown when a tap lands on several events at once.
Future<String?> pickFromCluster(
  BuildContext context,
  TimelineCluster cluster, {
  required String Function(ReviewEvent) when,
  required double Function(ReviewEvent) duration,
}) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${cluster.events.length} events close together',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final e in cluster.events)
                ReviewRow(
                    review: e,
                    when: when(e),
                    durationSec: duration(e),
                    selected: false,
                    onTap: () => Navigator.pop(c, e.event.id)),
            ]),
          ),
        ]),
      ),
    ),
  );
}
