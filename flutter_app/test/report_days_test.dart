import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/data/review_event.dart';
import 'package:neo_companion/data/static_recording_source.dart';
import 'package:neo_companion/report/report_builder.dart';
import 'package:neo_companion/report/report_models.dart';
import 'package:neo_companion/report/report_pdf.dart';
import 'package:neo_companion/report/report_selection.dart';

const bundled = 'assets/demo_recording'; // 3 days
final now = DateTime.utc(2026, 10, 8, 9, 30);

String wordsOf(String rawPdf) {
  String unescape(String s) => s
      .replaceAllMapped(RegExp(r'\\([0-7]{3})'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)))
      .replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);
  return RegExp(r'\[\(((?:\\.|[^\\)])*)\)\]TJ').allMatches(rawPdf).map((m) => unescape(m[1]!)).join(' ');
}

void main() {
  late StaticRecordingSource src;
  late List<ReviewEvent> events;
  late int rate;

  setUpAll(() async {
    src = StaticRecordingSource(DirectoryDatasetReader(bundled));
    await src.load();
    rate = src.info.eegRateHz;
    events = [for (final e in src.events()) ReviewEvent(e, null)];
  });

  bool inDay(ReviewEvent r, int day) {
    final t = r.event.startSec(rate);
    return t >= day * 86400.0 && t < (day + 1) * 86400.0;
  }

  Future<ReportData> build({DayRange? days, ReportSelection? selection}) => ReportBuilder.build(
        source: src,
        events: events,
        selection: selection ?? ReportSelection({for (final r in events) r.event.id}),
        generatedAtUtc: now,
        days: days,
      );

  group('DayRange', () {
    test('knows whether it fits a recording', () {
      expect(const DayRange(0, 2).fits(3), isTrue);
      expect(const DayRange(1, 1).fits(3), isTrue);
      expect(const DayRange(0, 3).fits(3), isFalse);
      expect(const DayRange(-1, 1).fits(3), isFalse);
      expect(const DayRange(2, 1).fits(3), isFalse);
      expect(const DayRange(1, 2).count, 2);
      expect(const DayRange(1, 2).startSec, 86400);
      expect(const DayRange(1, 2), const DayRange(1, 2));
    });
  });

  group('a report of some days', () {
    test('every day is the same as the whole recording', () async {
      final whole = await build();
      final all = await build(days: const DayRange(0, 2));
      expect(all.header.isPartial, isFalse);
      expect(all.summary.candidates, whole.summary.candidates);
      expect(all.summary.durationSec, whole.summary.durationSec);
      expect(all.entries.length, whole.entries.length);
      expect(all.timeline.length, whole.timeline.length);
    });

    test('one day covers that day only, with its own dates', () async {
      final d = await build(days: const DayRange(1, 1));
      final h = d.header;
      expect(h.isPartial, isTrue);
      expect([h.firstDay, h.lastDay, h.recordingDays], [1, 1, 3]);
      expect(h.durationSec, 86400);
      expect(h.recordingStartLocal, DateTime.utc(2026, 10, 6, 8));
      expect(h.recordingEndLocal, DateTime.utc(2026, 10, 7, 8));
      expect(d.summary.days, 1);
      expect(d.summary.durationSec, 86400);
      expect(d.summary.perDay.length, 1);
      expect(d.summary.perDay.single.index, 1, reason: 'still called Day 2');
    });

    test('counts come only from the days chosen, and add up across ranges', () async {
      final day1 = await build(days: const DayRange(0, 0));
      final rest = await build(days: const DayRange(1, 2));
      final whole = await build();
      int auto(Iterable<ReviewEvent> e) => e.where((r) => r.event.source == EventSource.auto).length;
      expect(day1.summary.candidates, auto(events.where((r) => inDay(r, 0))));
      expect(rest.summary.candidates, auto(events.where((r) => inDay(r, 1) || inDay(r, 2))));
      expect(day1.summary.candidates + rest.summary.candidates, whole.summary.candidates);
      expect(day1.summary.patientMarkers + rest.summary.patientMarkers, whole.summary.patientMarkers);
      expect(day1.summary.nightCandidates + rest.summary.nightCandidates, whole.summary.nightCandidates);
      expect(rest.summary.perDay.map((x) => x.index), [1, 2]);
      expect(rest.summary.durationSec, 2 * 86400);
    });

    test('events outside the days never appear, even when selected', () async {
      final d = await build(days: const DayRange(2, 2)); // everything is selected
      expect(d.entries, isNotEmpty);
      for (final e in d.entries) {
        expect(e.startSec, inInclusiveRange(2 * 86400.0, 3 * 86400.0), reason: e.event.id);
      }
      expect(d.entries.length, events.where((r) => inDay(r, 2)).length);
      expect(d.timeline.length, d.entries.length, reason: 'the figure shows only these days');
    });

    test('the figure counts from the left edge of the first day', () async {
      final d = await build(days: const DayRange(1, 1));
      expect(d.overview.startSec, 0);
      expect(d.overview.count * d.overview.binSec, closeTo(86400, d.overview.binSec));
      for (final t in d.timeline) {
        expect(t.startSec, inInclusiveRange(0, 86400));
      }
      for (final s in d.summary.quality.lowQualityStretches) {
        expect(s.startSec, inInclusiveRange(0, 86400));
      }
    });

    test('usable time never exceeds the days covered', () async {
      final d = await build(days: const DayRange(1, 1));
      expect(d.summary.quality.usableSec, lessThanOrEqualTo(86400));
      expect(d.summary.quality.usablePercent, inInclusiveRange(0, 100));
    });

    test('days outside the recording are refused', () async {
      for (final r in const [DayRange(0, 3), DayRange(-1, 1), DayRange(2, 1), DayRange(3, 3)]) {
        expect(() => build(days: r), throwsArgumentError, reason: '$r');
      }
    });

    test('the PDF says which days it covers, and only when it is partial', () async {
      Future<String> text(DayRange? r) async =>
          wordsOf(latin1.decode(await ReportPdf.build(await build(days: r), compress: false)));
      expect(await text(const DayRange(1, 1)), contains('Day 2 of 3'));
      expect(await text(const DayRange(1, 2)), contains('Days 2 to 3 of 3'));
      expect(await text(null), isNot(contains('Days covered')));
    });

    test('the file name carries the first day covered', () async {
      expect(ReportPdf.suggestedFileName(await build(days: const DayRange(1, 1))), endsWith('20261006.pdf'));
      expect(ReportPdf.suggestedFileName(await build()), endsWith('20261005.pdf'));
    });
  });

  group('score bands', () {
    test('High from 0.8, Medium from 0.4, otherwise Low, none without a score', () {
      expect(scoreBandOf(0.97), ScoreBand.high);
      expect(scoreBandOf(0.8), ScoreBand.high);
      expect(scoreBandOf(0.79), ScoreBand.medium);
      expect(scoreBandOf(0.4), ScoreBand.medium);
      expect(scoreBandOf(0.39), ScoreBand.low);
      expect(scoreBandOf(0), ScoreBand.low);
      expect(scoreBandOf(null), isNull);
    });

    test('the report agrees: its high-confidence count is the High band', () async {
      final d = await build();
      final high = events.where((r) => scoreBandOf(r.event.confidence) == ScoreBand.high).length;
      expect(d.summary.highConfidence, high);
      expect(kHighConfidence, 0.8);
    });

    test('the demo recording spreads over all three bands', () {
      final counts = <ScoreBand, int>{};
      for (final r in events) {
        final b = scoreBandOf(r.event.confidence);
        if (b != null) counts[b] = (counts[b] ?? 0) + 1;
      }
      expect(counts[ScoreBand.high], 15);
      expect(counts[ScoreBand.medium], 31);
      expect(counts[ScoreBand.low], 64);
    });
  });
}
