import 'dart:math' as math;

import '../data/recording_source.dart';
import '../data/review_event.dart';
import '../data/score_band.dart';
import 'review_models.dart';

/// Events that sit too close together to tell apart at the current zoom, drawn
/// as one mark. A single event is a cluster of one.
class TimelineCluster {
  /// Oldest first.
  final List<ReviewEvent> events;

  /// Left and right edge, and centre, in pixels.
  final double left, right;

  const TimelineCluster(this.events, this.left, this.right);

  double get center => (left + right) / 2;
  bool get isSingle => events.length == 1;
  ReviewEvent get first => events.first;

  bool contains(String id) => events.any((e) => e.event.id == id);

  /// The highest band in the cluster (what its height shows); null for markers.
  ScoreBand? get topBand {
    ScoreBand? best;
    for (final e in events) {
      final b = e.band;
      if (b == null) continue;
      if (best == null || b.index < best.index) best = b; // high is index 0
    }
    return best;
  }

  /// How the cluster reads as a whole: unreviewed while any member is, otherwise
  /// confirmed if any member is, otherwise dismissed.
  ReviewStatus get status {
    if (events.any((e) => e.status == ReviewStatus.candidate)) return ReviewStatus.candidate;
    if (events.any((e) => e.status == ReviewStatus.confirmed)) return ReviewStatus.confirmed;
    return ReviewStatus.dismissed;
  }
}

/// Groups events by where they land. [xOf] turns seconds into pixels; events
/// whose marks start within [minGapPx] of the previous one's end join its cluster.
/// A mark is at least [minWidthPx] wide, so a ten second event is never invisible.
List<TimelineCluster> clusterEvents(
  List<ReviewEvent> events, {
  required double Function(double sec) xOf,
  required int eegRateHz,
  double minGapPx = 2,
  double minWidthPx = 4,
}) {
  final sorted = [...events]..sort((a, b) => a.event.startSample.compareTo(b.event.startSample));
  final out = <TimelineCluster>[];
  var group = <ReviewEvent>[];
  double left = 0, right = 0;
  for (final e in sorted) {
    final start = e.event.startSec(eegRateHz);
    final x0 = xOf(start);
    final x1 = math.max(xOf(start + e.event.durationSec(eegRateHz)), x0 + minWidthPx);
    if (group.isNotEmpty && x0 - right <= minGapPx) {
      group.add(e);
      right = math.max(right, x1);
    } else {
      if (group.isNotEmpty) out.add(TimelineCluster(group, left, right));
      group = [e];
      left = x0;
      right = x1;
    }
  }
  if (group.isNotEmpty) out.add(TimelineCluster(group, left, right));
  return out;
}

/// The cluster nearest to pixel [x], within [tolerancePx] of its edges; null if none.
TimelineCluster? hitCluster(List<TimelineCluster> clusters, double x, {double tolerancePx = 14}) {
  TimelineCluster? best;
  var bestDist = double.infinity;
  for (final c in clusters) {
    final d = x < c.left ? c.left - x : (x > c.right ? x - c.right : 0.0);
    if (d <= tolerancePx && d < bestDist) {
      best = c;
      bestDist = d;
    }
  }
  return best;
}

/// How tall a mark is, from 0 to 1 of the room for marks, by score band.
double barFraction(ScoreBand? band) => switch (band) {
      ScoreBand.high => 1.0,
      ScoreBand.medium => 0.64,
      ScoreBand.low => 0.32,
      null => 0.32,
    };

/// A label under the timeline.
class TimeAxisTick {
  final double sec;
  final String label;

  /// A day boundary: drawn with the date and a full-height line.
  final bool dayStart;

  const TimeAxisTick(this.sec, this.label, {this.dayStart = false});
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "Mon 5 Oct".
String dateLabel(DateTime local) => '${_weekdays[local.weekday - 1]} ${local.day} ${_months[local.month - 1]}';

String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// "Mon 5 Oct, 14:32:10".
String dateTimeLabel(DateTime local) =>
    '${dateLabel(local)}, ${_hhmm(local)}:${local.second.toString().padLeft(2, '0')}';

/// Labels on the clock of the recording site: every step of a round size (an hour,
/// six hours, a day) that falls in [visible], with the date at each midnight. The
/// step is the smallest that gives no more than [maxTicks] labels.
List<TimeAxisTick> axisTicks(TimeRange visible, RecordingInfo info, {int maxTicks = 7}) {
  const steps = [60, 300, 900, 1800, 3600, 3 * 3600, 6 * 3600, 12 * 3600, 86400, 2 * 86400, 7 * 86400];
  final len = visible.lengthSec;
  if (len <= 0) return const [];
  final step = steps.firstWhere((s) => len / s <= maxTicks, orElse: () => steps.last);

  final startLocal = info.localTimeAt(visible.startSec);
  final sod = startLocal.hour * 3600 + startLocal.minute * 60 + startLocal.second;
  var sec = visible.startSec + ((step - sod % step) % step);
  final out = <TimeAxisTick>[];
  while (sec < visible.endSec - 1e-6) {
    final local = info.localTimeAt(sec);
    final midnight = local.hour == 0 && local.minute == 0 && local.second == 0;
    out.add(TimeAxisTick(sec, midnight ? dateLabel(local) : _hhmm(local), dayStart: midnight));
    sec += step;
  }
  return out;
}

/// The stretches where the signal was too poor to use, merged, inside [visible].
List<TimeRange> poorStretches(OverviewBins ov, double usableQuality) {
  final out = <TimeRange>[];
  int? from;
  for (var i = 0; i <= ov.count; i++) {
    final bad = i < ov.count && ov.quality[i] < usableQuality;
    if (bad) {
      from ??= i;
    } else if (from != null) {
      out.add(TimeRange(ov.startSec + from * ov.binSec, ov.startSec + i * ov.binSec));
      from = null;
    }
  }
  return out;
}

/// Everything the timeline draws at the current zoom and width.
class TimelineSnapshot {
  final TimeRange visible;
  final OverviewBins overview;

  /// Automatic events as marks (clustered), and patient markers as their own row.
  final List<TimelineCluster> bars;
  final List<TimelineCluster> markers;
  final List<TimeAxisTick> ticks;
  final List<TimeRange> poor;

  const TimelineSnapshot({
    required this.visible,
    required this.overview,
    required this.bars,
    required this.markers,
    required this.ticks,
    required this.poor,
  });

  double xOf(double sec, double width) => (sec - visible.startSec) / visible.lengthSec * width;
}

/// How many events of each kind a day holds (a day is a 24-hour block from the start
/// of the recording), for the daily bars of a week or a month.
class DayTally {
  final int day; // 0-based
  final double startSec;
  final Map<EventCategory, int> counts;

  const DayTally(this.day, this.startSec, this.counts);

  /// Automatic events only: patient presses are shown apart.
  int get automatic =>
      (counts[EventCategory.possibleSeizure] ?? 0) +
      (counts[EventCategory.unusual] ?? 0) +
      (counts[EventCategory.normal] ?? 0);
}
