import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/data/review_event.dart';
import 'package:neo_companion/data/static_recording_source.dart';
import 'package:neo_companion/report/report_builder.dart';
import 'package:neo_companion/review/review_models.dart';
import 'package:neo_companion/report/report_choice.dart';
import 'package:neo_companion/report/report_pdf.dart';
import 'package:neo_companion/report/report_selection.dart';

ReviewEvent ev(String id, int start, {double? score, ReviewStatus status = ReviewStatus.candidate}) => ReviewEvent(
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
      status == ReviewStatus.candidate ? null : ReviewDecision(eventId: id, status: status, updatedAt: DateTime.utc(2026)),
    );

void main() {
  final events = [
    ev('h1', 100, score: 0.95),
    ev('h2', 200, score: 0.85, status: ReviewStatus.confirmed),
    ev('m1', 300, score: 0.6),
    ev('m2', 400, score: 0.5, status: ReviewStatus.dismissed),
    ev('l1', 500, score: 0.2),
    ev('l2', 600, score: 0.3, status: ReviewStatus.confirmed),
    ev('mk2', 900),
    ev('mk1', 50, status: ReviewStatus.confirmed),
  ];

  group('groups', () {
    final g = buildGroups(events);

    test('the patient markers are apart, in time order', () {
      expect([for (final e in g.markers) e.event.id], ['mk1', 'mk2']);
    });

    test('candidates fall into High, Medium and Low by score, best first in each', () {
      expect([for (final e in g.high) e.event.id], ['h1', 'h2']);
      expect([for (final e in g.medium) e.event.id], ['m1', 'm2']);
      expect([for (final e in g.low) e.event.id], ['l2', 'l1']);
    });

    test('together they hold every event once', () {
      expect(g.all.length, events.length);
      expect({for (final e in g.all) e.event.id}.length, events.length);
    });

    test('a group can be asked for by band', () {
      expect(g.forBand(events[0].band!).length, 2);
    });

    test('nothing gives empty groups', () {
      final empty = buildGroups(const []);
      expect(empty.all, isEmpty);
    });
  });

  group('presets', () {
    ids(ReportSelection s) => s.ids.toList()..sort();

    test('Confirmed is every confirmed event, markers included', () {
      final s = selectionFor(ReportPreset.confirmed, events);
      expect(ids(s), ['h2', 'l2', 'mk1']);
      expect(s.isFallback, isFalse);
    });

    test('Confirmed with nothing confirmed falls back to the top candidates, and says so', () {
      final none = [ev('a', 1, score: 0.9), ev('b', 2, score: 0.4), ev('c', 3, score: 0.7)];
      final s = selectionFor(ReportPreset.confirmed, none);
      expect(s.isFallback, isTrue);
      expect(ids(s), ['a', 'b', 'c']);
    });

    test('All candidates is every automatic event that was not dismissed', () {
      expect(ids(selectionFor(ReportPreset.allCandidates, events)), ['h1', 'h2', 'l1', 'l2', 'm1']);
    });

    test('Markers is every patient press', () {
      expect(ids(selectionFor(ReportPreset.markers, events)), ['mk1', 'mk2']);
    });

    test('a preset is recognised when the choice is exactly it, and not when it was changed by hand', () {
      final s = selectionFor(ReportPreset.allCandidates, events);
      expect(presetOf(s, events), ReportPreset.allCandidates);
      expect(presetOf(s.toggled('h1'), events), isNull);
      expect(presetOf(const ReportSelection({}), events), isNull);
    });

    test('the fallback is Confirmed even when it holds the same events as All candidates', () {
      final few = [ev('a', 1, score: 0.9), ev('b', 2, score: 0.4)]; // nothing confirmed, fewer than five
      final fallback = selectionFor(ReportPreset.confirmed, few);
      final all = selectionFor(ReportPreset.allCandidates, few);
      expect(fallback.ids, all.ids);
      expect(presetOf(fallback, few), ReportPreset.confirmed);
      expect(presetOf(all, few), ReportPreset.allCandidates);
    });

    test('presets over no events are empty and still recognised', () {
      expect(selectionFor(ReportPreset.allCandidates, const []).ids, isEmpty);
    });
  });

  group('a whole group at once', () {
    final g = buildGroups(events);

    test('the box is empty, half, or full', () {
      expect(groupCheck(const ReportSelection({}), g.high), GroupCheck.none);
      expect(groupCheck(const ReportSelection({'h1'}), g.high), GroupCheck.some);
      expect(groupCheck(const ReportSelection({'h1', 'h2'}), g.high), GroupCheck.all);
      expect(groupCheck(const ReportSelection({'h1', 'h2'}), const []), GroupCheck.none);
    });

    test('ticking the group adds all of it and keeps the rest', () {
      final s = withGroup(const ReportSelection({'l1'}), g.high, on: true);
      expect(s.ids, {'l1', 'h1', 'h2'});
    });

    test('unticking removes only that group', () {
      final s = withGroup(const ReportSelection({'h1', 'h2', 'l1'}), g.high, on: false);
      expect(s.ids, {'l1'});
    });

    test('the result is the reviewer\'s own choice, never the fallback', () {
      final fb = ReportSelection.defaultFor([ev('a', 1, score: 0.9)]);
      expect(fb.isFallback, isTrue);
      expect(withGroup(fb, g.high, on: true).isFallback, isFalse);
    });
  });

  group('counting pages in a finished PDF', () {
    test('matches the real thing, compressed or not', () async {
      final src = StaticRecordingSource(DirectoryDatasetReader('test/fixtures/mini_recording'));
      await src.load();
      final data = await ReportBuilder.build(
        source: src,
        events: [for (final e in src.events()) ReviewEvent(e, null)],
        selection: ReportSelection({for (final e in src.events()) e.id}),
        generatedAtUtc: DateTime.utc(2026, 10, 9),
      );
      for (final compress in [true, false]) {
        final bytes = await ReportPdf.build(data, compress: compress);
        final raw = latin1.decode(bytes);
        final expected = RegExp(r'/Type\s*/Pages?\b').allMatches(raw).length - 1; // the /Pages tree is not a page
        expect(countPdfPages(bytes), greaterThanOrEqualTo(2), reason: 'compress: $compress');
        expect(countPdfPages(bytes), expected, reason: 'compress: $compress');
      }
    });

    test('bytes that are not a PDF have no pages', () {
      expect(countPdfPages(utf8.encode('hello')), 0);
      expect(countPdfPages(const []), 0);
    });
  });
}
