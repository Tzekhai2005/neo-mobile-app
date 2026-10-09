import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/data/review_event.dart';
import 'package:neo_companion/data/score_band.dart';
import 'package:neo_companion/review/review_models.dart';

ReviewEvent ev(String id, int start, {double? score, ReviewStatus status = ReviewStatus.candidate, String? note}) => ReviewEvent(
      RecordedEvent(
        id: id,
        source: score == null ? EventSource.patientButton : EventSource.auto,
        startSample: start,
        durationSamples: 500,
        confidence: score,
        channels: const [0, 1],
        quality: 0.9,
        window: const EventWindowRef(offset: 0, length: 0, preSec: 15, postSec: 25),
      ),
      status == ReviewStatus.candidate && note == null
          ? null
          : ReviewDecision(eventId: id, status: status, note: note, updatedAt: DateTime.utc(2026)),
    );

void main() {
  group('what an event is', () {
    test('a patient press is a marker, with no score and no band', () {
      final m = ev('m', 100);
      expect(m.isMarker, isTrue);
      expect(m.band, isNull);
    });

    test('an automatic event has a band from its score', () {
      expect(ev('a', 1, score: 0.9).band, ScoreBand.high);
      expect(ev('a', 1, score: 0.5).band, ScoreBand.medium);
      expect(ev('a', 1, score: 0.1).band, ScoreBand.low);
      expect(ev('a', 1, score: 0.9).isMarker, isFalse);
    });

    test('reviewed means confirmed or dismissed, not merely noted', () {
      expect(ev('a', 1, score: 0.5).isReviewed, isFalse);
      expect(ev('a', 1, score: 0.5, note: 'carer saw it').isReviewed, isFalse);
      expect(ev('a', 1, score: 0.5, status: ReviewStatus.confirmed).isReviewed, isTrue);
      expect(ev('a', 1, score: 0.5, status: ReviewStatus.dismissed).isReviewed, isTrue);
    });
  });

  group('filters', () {
    final all = [
      ev('u', 1, score: 0.5),
      ev('c', 2, score: 0.5, status: ReviewStatus.confirmed),
      ev('d', 3, score: 0.5, status: ReviewStatus.dismissed),
    ];

    test('each shows exactly its own', () {
      List<String> ids(ReviewFilter f) => [for (final e in all) if (passesFilter(e, f)) e.event.id];
      expect(ids(ReviewFilter.all), ['u', 'c', 'd']);
      expect(ids(ReviewFilter.unreviewed), ['u']);
      expect(ids(ReviewFilter.confirmed), ['c']);
      expect(ids(ReviewFilter.dismissed), ['d']);
    });
  });

  group('the list', () {
    final events = [
      ev('low-early', 100, score: 0.2),
      ev('high-late', 9000, score: 0.9),
      ev('mid', 500, score: 0.5),
      ev('high-early', 300, score: 0.9),
      ev('marker-late', 8000),
      ev('marker-early', 50),
      ev('tied-late', 7000, score: 0.5),
    ];

    test('candidates are ranked by score, ties in time order', () {
      final l = buildLists(events, ReviewFilter.all);
      expect([for (final e in l.candidates) e.event.id], ['high-early', 'high-late', 'mid', 'tied-late', 'low-early']);
    });

    test('patient markers are kept apart, in time order', () {
      final l = buildLists(events, ReviewFilter.all);
      expect([for (final e in l.markers) e.event.id], ['marker-early', 'marker-late']);
    });

    test('Next and Previous walk the markers first, then the candidates', () {
      final l = buildLists(events, ReviewFilter.all);
      expect([for (final e in l.ordered) e.event.id].take(3), ['marker-early', 'marker-late', 'high-early']);
      expect(l.ordered.length, events.length);
    });

    test('a filter applies to both groups', () {
      final mixed = [
        ev('a', 1, score: 0.9, status: ReviewStatus.confirmed),
        ev('b', 2, score: 0.8),
        ev('m1', 3, status: ReviewStatus.confirmed),
        ev('m2', 4),
      ];
      final l = buildLists(mixed, ReviewFilter.confirmed);
      expect([for (final e in l.ordered) e.event.id], ['m1', 'a']);
    });

    test('nothing matching is an empty list', () {
      final l = buildLists(events, ReviewFilter.confirmed);
      expect(l.isEmpty, isTrue);
      expect(l.ordered, isEmpty);
    });

    test('an equal score does not mix a marker in with the candidates', () {
      expect(buildLists([ev('m', 1)], ReviewFilter.all).candidates, isEmpty);
    });
  });

  group('counts', () {
    test('add up, with markers counted among the events', () {
      final c = ReviewCounts.of([
        ev('a', 1, score: 0.9, status: ReviewStatus.confirmed),
        ev('b', 2, score: 0.5, status: ReviewStatus.dismissed),
        ev('c', 3, score: 0.4),
        ev('m', 4),
        ev('n', 5, status: ReviewStatus.confirmed),
      ]);
      expect(c.total, 5);
      expect(c.confirmed, 2);
      expect(c.dismissed, 1);
      expect(c.unreviewed, 2);
      expect(c.reviewed, 3);
      expect(c.markers, 2);
      expect(c.confirmed + c.dismissed + c.unreviewed, c.total);
    });

    test('an empty recording', () {
      final c = ReviewCounts.of(const []);
      expect([c.total, c.reviewed, c.unreviewed], [0, 0, 0]);
    });
  });
}
