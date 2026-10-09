import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/data/recording_source.dart';
import 'package:neo_companion/data/review_event.dart';
import 'package:neo_companion/data/score_band.dart';
import 'package:neo_companion/review/timeline_model.dart';

const rate = 250;

ReviewEvent ev(String id, double startSec, {double? score = 0.5, double durSec = 2, ReviewStatus? status}) => ReviewEvent(
      RecordedEvent(
        id: id,
        source: score == null ? EventSource.patientButton : EventSource.auto,
        startSample: (startSec * rate).round(),
        durationSamples: (durSec * rate).round(),
        confidence: score,
        channels: const [0, 1],
        quality: 0.9,
        window: const EventWindowRef(offset: 0, length: 0, preSec: 15, postSec: 25),
      ),
      status == null ? null : ReviewDecision(eventId: id, status: status, updatedAt: DateTime.utc(2026)),
    );

final info = RecordingInfo(
  startUtc: DateTime.utc(2026, 10, 5),
  utcOffsetMinutes: 480, // the recording starts at 08:00 on Monday 5 October, local time
  durationSec: 259200,
  eegRateHz: rate,
  eegChannels: 2,
  imuRateHz: 100,
  synthetic: true,
  generator: 'test',
  datasetKey: 'k',
);

void main() {
  // 3600 s across 360 px: 0.1 px per second
  double x(double sec) => sec * 0.1;
  List<TimelineCluster> cluster(List<ReviewEvent> e, {double gap = 6, double minW = 4}) =>
      clusterEvents(e, xOf: x, eegRateHz: rate, minGapPx: gap, minWidthPx: minW);

  group('clusterEvents', () {
    test('events far apart stay separate', () {
      final c = cluster([ev('a', 100), ev('b', 1100), ev('c', 2100)]);
      expect(c.length, 3);
      expect(c.every((k) => k.isSingle), isTrue);
    });

    test('events that would touch on screen become one mark with a count', () {
      final c = cluster([ev('a', 100), ev('b', 140), ev('c', 190)]); // 5 px apart or less
      expect(c.length, 1);
      expect(c.single.events.length, 3);
      expect(c.single.isSingle, isFalse);
    });

    test('a cluster grows along a chain even when its two ends are far apart', () {
      final c = cluster([ev('a', 100), ev('b', 160), ev('c', 220), ev('d', 280)]);
      expect(c.length, 1);
      expect(c.single.right - c.single.left, greaterThan(15));
    });

    test('the order of the input does not matter, and events inside are oldest first', () {
      final c = cluster([ev('c', 190), ev('a', 100), ev('b', 140)]);
      expect([for (final e in c.single.events) e.event.id], ['a', 'b', 'c']);
    });

    test('a short event is still at least as wide as the minimum, so it can be seen and tapped', () {
      final c = cluster([ev('a', 100, durSec: 1)], minW: 4);
      expect(c.single.right - c.single.left, 4);
    });

    test('a long event is as wide as it lasted', () {
      final c = cluster([ev('a', 100, durSec: 400)]);
      expect(c.single.left, closeTo(10, 1e-9));
      expect(c.single.right, closeTo(50, 1e-9));
    });

    test('an event that starts inside a long one joins it', () {
      final c = cluster([ev('a', 100, durSec: 400), ev('b', 300, durSec: 2)]);
      expect(c.length, 1);
    });

    test('zooming in separates what zooming out merged', () {
      final events = [ev('a', 100), ev('b', 140)];
      expect(cluster(events).length, 1);
      final zoomed = clusterEvents(events, xOf: (s) => s * 1.0, eegRateHz: rate);
      expect(zoomed.length, 2);
    });

    test('nothing gives nothing', () {
      expect(cluster(const []), isEmpty);
    });

    test('its centre is halfway between its edges', () {
      final c = cluster([ev('a', 100, durSec: 400)]).single;
      expect(c.center, closeTo(30, 1e-9));
    });
  });

  group('what a cluster says about itself', () {
    test('its height shows the highest band inside it', () {
      final c = cluster([ev('a', 100, score: 0.2), ev('b', 120, score: 0.9), ev('c', 140, score: 0.5)]).single;
      expect(c.topBand, ScoreBand.high);
    });

    test('a marker alone has no band', () {
      expect(cluster([ev('m', 100, score: null)]).single.topBand, isNull);
    });

    test('it reads as unreviewed while any event in it is', () {
      final c = cluster([
        ev('a', 100, status: ReviewStatus.confirmed),
        ev('b', 120),
      ]).single;
      expect(c.status, ReviewStatus.candidate);
    });

    test('when all are decided, confirmed wins over dismissed', () {
      final c = cluster([
        ev('a', 100, status: ReviewStatus.confirmed),
        ev('b', 120, status: ReviewStatus.dismissed),
      ]).single;
      expect(c.status, ReviewStatus.confirmed);
      expect(cluster([ev('d', 100, status: ReviewStatus.dismissed)]).single.status, ReviewStatus.dismissed);
    });

    test('it knows whether an event is in it', () {
      final c = cluster([ev('a', 100), ev('b', 120)]).single;
      expect(c.contains('b'), isTrue);
      expect(c.contains('zzz'), isFalse);
    });
  });

  group('tapping the timeline', () {
    final clusters = cluster([ev('a', 100), ev('b', 1000), ev('c', 1010, durSec: 500)]);

    test('a tap on a mark finds it', () {
      expect(hitCluster(clusters, 10.5)!.first.event.id, 'a');
    });

    test('a tap close beside a mark still finds it, because a finger is not exact', () {
      expect(hitCluster(clusters, 10.2 + 12)!.first.event.id, 'a');
    });

    test('a tap far from every mark finds nothing', () {
      expect(hitCluster(clusters, 70), isNull);
    });

    test('between two marks it picks the nearer', () {
      final two = cluster([ev('p', 100), ev('q', 400)]); // marks near x 10 and 40
      expect(hitCluster(two, 22, tolerancePx: 30)!.first.event.id, 'p');
      expect(hitCluster(two, 30, tolerancePx: 30)!.first.event.id, 'q');
    });

    test('with nothing there is nothing to find', () {
      expect(hitCluster(const [], 10), isNull);
    });
  });

  test('a mark is tallest for High, shorter for Medium, shortest for Low', () {
    expect(barFraction(ScoreBand.high), greaterThan(barFraction(ScoreBand.medium)));
    expect(barFraction(ScoreBand.medium), greaterThan(barFraction(ScoreBand.low)));
    expect(barFraction(ScoreBand.high), 1);
    expect(barFraction(null), greaterThan(0));
  });

  group('time labels', () {
    test('one day is labelled every six hours on the clock of the place, with the date at midnight', () {
      final t = axisTicks(const TimeRange(0, 86400), info);
      expect([for (final k in t) k.label], ['12:00', '18:00', 'Tue 6 Oct', '06:00']);
      expect([for (final k in t) k.dayStart], [false, false, true, false]);
    });

    test('three days are labelled every twelve hours', () {
      final t = axisTicks(const TimeRange(0, 259200), info);
      expect(t.length, lessThanOrEqualTo(7));
      expect(t.where((k) => k.dayStart).map((k) => k.label), ['Tue 6 Oct', 'Wed 7 Oct', 'Thu 8 Oct']);
      expect(t.where((k) => !k.dayStart).every((k) => k.label == '12:00'), isTrue);
    });

    test('zoomed to half an hour it is every five minutes, on the five minutes', () {
      final t = axisTicks(const TimeRange(5 * 3600.0, 5 * 3600.0 + 1800), info); // 13:00 to 13:30
      expect(t.map((k) => k.label), ['13:00', '13:05', '13:10', '13:15', '13:20', '13:25']);
    });

    test('the labels are always inside the view and never too many', () {
      for (final len in [600.0, 1800.0, 3600.0, 21600.0, 86400.0, 259200.0]) {
        for (final start in [0.0, 12345.0, 50000.0]) {
          final t = axisTicks(TimeRange(start, start + len), info);
          expect(t.length, lessThanOrEqualTo(7), reason: '$len s from $start');
          expect(t.every((k) => k.sec >= start && k.sec < start + len), isTrue, reason: '$len s from $start');
        }
      }
    });

    test('an empty view has no labels', () {
      expect(axisTicks(const TimeRange(100, 100), info), isEmpty);
    });
  });

  group('poor signal', () {
    OverviewBins bins(List<double> quality, {double start = 0, double binSec = 60}) => OverviewBins(
          binSec: binSec,
          startSec: start,
          count: quality.length,
          eegMin: [Float32List(quality.length)],
          eegMax: [Float32List(quality.length)],
          activity: Float32List(quality.length),
          quality: Float32List.fromList(quality),
        );

    test('stretches below the usable level are found, merged, and placed on the time axis', () {
      final r = poorStretches(bins([1, 0.2, 0.3, 1, 1, 0.1, 1], start: 600), 0.5);
      expect([for (final s in r) [s.startSec, s.endSec]], [
        [660, 780],
        [900, 960],
      ]);
    });

    test('a stretch at the very end is closed', () {
      final r = poorStretches(bins([1, 1, 0.2, 0.2]), 0.5);
      expect(r.single.endSec, 240);
    });

    test('exactly usable is usable', () {
      expect(poorStretches(bins([0.5, 0.5]), 0.5), isEmpty);
    });

    test('nothing poor, nothing found', () {
      expect(poorStretches(bins([1, 1, 1]), 0.5), isEmpty);
    });
  });

  test('dates and times read plainly', () {
    expect(dateLabel(DateTime(2026, 10, 5)), 'Mon 5 Oct');
    expect(dateLabel(DateTime(2026, 12, 31)), 'Thu 31 Dec');
    expect(dateTimeLabel(DateTime(2026, 10, 5, 14, 32, 10)), 'Mon 5 Oct, 14:32:10');
    expect(dateTimeLabel(DateTime(2026, 10, 6, 0, 5, 3)), 'Tue 6 Oct, 00:05:03');
  });
}
