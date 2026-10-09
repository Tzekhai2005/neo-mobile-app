import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/config/app_config.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/data/recording_source.dart';
import 'package:neo_companion/data/review_event.dart';
import 'package:neo_companion/data/review_store.dart';
import 'package:neo_companion/data/static_recording_source.dart';
import 'package:neo_companion/report/report_builder.dart';
import 'package:neo_companion/report/report_csv.dart';
import 'package:neo_companion/report/report_models.dart';
import 'package:neo_companion/report/report_selection.dart';

const mini = 'test/fixtures/mini_recording';
const mini4 = 'test/fixtures/mini_recording_4ch';
const bundled = 'test/fixtures/demo_3day';
final now = DateTime.utc(2026, 10, 7, 9, 30);

Future<StaticRecordingSource> open(String dir) async {
  final s = StaticRecordingSource(DirectoryDatasetReader(dir));
  await s.load();
  return s;
}

/// Events with decisions applied; `confirm` / `dismiss` / `notes` are event ids.
Future<List<ReviewEvent>> reviewed(
  StaticRecordingSource src, {
  List<String> confirm = const [],
  List<String> dismiss = const [],
  Map<String, String> notes = const {},
}) async {
  final dir = Directory.systemTemp.createTempSync('neo_report_');
  addTearDown(() => dir.deleteSync(recursive: true));
  final store = ReviewStore(File('${dir.path}/d.json'), datasetKey: src.info.datasetKey);
  await store.load();
  for (final id in confirm) {
    await store.setStatus(id, ReviewStatus.confirmed);
  }
  for (final id in dismiss) {
    await store.setStatus(id, ReviewStatus.dismissed);
  }
  for (final e in notes.entries) {
    await store.setNote(e.key, e.value);
  }
  return store.merge(src.events());
}

/// A small RFC 4180 parser, so the tests read CSV the way a spreadsheet would.
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == ',') {
      row.add(field.toString());
      field.clear();
    } else if (c == '\n') {
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = <String>[];
    } else {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

void main() {
  group('ReportSelection', () {
    test('with nothing reviewed, falls back to the top unreviewed automatic candidates', () async {
      final events = await reviewed(await open(mini));
      final sel = ReportSelection.defaultFor(events);
      expect(sel.isFallback, isTrue);
      final auto = events.where((e) => e.event.source == EventSource.auto).map((e) => e.event.id).toSet();
      expect(sel.ids, auto, reason: 'all 4 automatic events; the patient marker is not a candidate');
    });

    test('keeps the best N and never picks a dismissed event', () async {
      final src = await open(bundled);
      final all = await reviewed(src);
      final sel = ReportSelection.defaultFor(all, fallbackTop: 5);
      expect(sel.ids.length, 5);
      final auto = all.where((e) => e.event.source == EventSource.auto).toList();
      final chosenMin = auto.where((e) => sel.contains(e.event.id)).map((e) => e.event.confidence!).reduce((a, b) => a < b ? a : b);
      final restMax = auto.where((e) => !sel.contains(e.event.id)).map((e) => e.event.confidence!).reduce((a, b) => a > b ? a : b);
      expect(chosenMin, greaterThanOrEqualTo(restMax));

      final best = auto.reduce((a, b) => a.event.confidence! >= b.event.confidence! ? a : b).event.id;
      final after = await reviewed(src, dismiss: [best]);
      expect(ReportSelection.defaultFor(after).contains(best), isFalse);
    });

    test('once something is confirmed, exactly the confirmed events', () async {
      final src = await open(mini);
      final ids = src.events().map((e) => e.id).toList();
      final events = await reviewed(src, confirm: [ids[0], ids[2]], dismiss: [ids[1]]);
      final sel = ReportSelection.defaultFor(events);
      expect(sel.isFallback, isFalse);
      expect(sel.ids, {ids[0], ids[2]});
    });

    test('toggling and adding return new selections', () {
      const base = ReportSelection({'a'}, isFallback: true);
      final t = base.toggled('b');
      expect(t.ids, {'a', 'b'});
      expect(t.isFallback, isFalse, reason: 'an edited selection is the reviewer\'s own');
      expect(base.ids, {'a'}, reason: 'the original is unchanged');
      expect(t.toggled('a').ids, {'b'});
      expect(base.withAdded(['c', 'd']).ids, {'a', 'c', 'd'});
    });
  });

  group('summary numbers', () {
    late StaticRecordingSource src;
    late List<ReviewEvent> events;
    late List<String> autoIds;
    setUpAll(() async {
      src = await open(bundled);
      autoIds = src.events().where((e) => e.source == EventSource.auto).map((e) => e.id).toList();
      events = await reviewed(src, confirm: autoIds.take(3).toList(), dismiss: autoIds.skip(3).take(2).toList());
    });

    ReportSummary summary() {
      final fine = src.overview(TimeRange(0, src.info.durationSec.toDouble()), src.info.durationSec);
      return ReportBuilder.summarize(src.info, events, fine);
    }

    test('counts add up and match the data', () {
      final s = summary();
      expect(s.days, 3);
      expect(s.candidates, autoIds.length);
      expect(s.patientMarkers, events.where((e) => e.event.source == EventSource.patientButton).length);
      expect(s.confirmed, 3);
      expect(s.dismissed, 2);
      expect(s.unreviewed, s.candidates - 5);
      expect(s.nightCandidates + s.dayCandidates, s.candidates);
      expect(s.highConfidence, events.where((e) => (e.event.confidence ?? 0) >= kHighConfidence && e.event.source == EventSource.auto).length);
    });

    test('night events are counted from local time, independently', () {
      final rate = src.info.eegRateHz;
      final expected = events
          .where((e) => e.event.source == EventSource.auto && src.info.isNight(e.event.startSec(rate)))
          .length;
      expect(summary().nightCandidates, expected);
      expect(expected, inInclusiveRange(1, autoIds.length - 1));
    });

    test('the three days add up to the totals', () {
      final s = summary();
      expect(s.perDay.length, 3);
      expect(s.perDay.fold<int>(0, (n, d) => n + d.candidates), s.candidates);
      expect(s.perDay.fold<int>(0, (n, d) => n + d.confirmed), s.confirmed);
      expect(s.perDay.fold<int>(0, (n, d) => n + d.nightCandidates), s.nightCandidates);
      expect(s.perDay.fold<int>(0, (n, d) => n + d.patientMarkers), s.patientMarkers);
      expect(s.perDay[0].startLocal, DateTime.utc(2026, 10, 5, 8));
      expect(s.perDay[1].startLocal, DateTime.utc(2026, 10, 6, 8));
    });

    test('usable time comes from the signal quality, and no event sits in a bad stretch', () {
      final s = summary();
      final fine = src.overview(TimeRange(0, src.info.durationSec.toDouble()), src.info.durationSec);
      var bad = 0;
      for (var i = 0; i < fine.count; i++) {
        if (fine.quality[i] < kUsableQuality) bad++;
      }
      final total = fine.count * fine.binSec;
      expect(s.quality.usableSec, total - bad * fine.binSec);
      expect(s.quality.usablePercent, closeTo(100.0 * (total - bad * fine.binSec) / total, 1e-9));
      expect(s.quality.usablePercent, inInclusiveRange(80, 100));
      expect(s.quality.lowQualityStretches, isNotEmpty);
      expect(s.quality.lowQualityStretches.fold<double>(0, (n, x) => n + x.durationSec), bad * fine.binSec);
      expect(s.quality.linkLossPercent, isNull, reason: 'a stored dataset does not measure link loss');
      expect(s.quality.leadOffPercent, isNull);

      final rate = src.info.eegRateHz;
      for (final e in events.where((e) => e.event.source == EventSource.auto)) {
        final t = e.event.startSec(rate);
        expect(s.quality.lowQualityStretches.any((x) => t >= x.startSec && t < x.startSec + x.durationSec), isFalse,
            reason: 'event ${e.event.id} lies in a low-quality stretch');
      }
    });
  });

  group('ReportBuilder', () {
    test('builds the header, entries and timeline', () async {
      final src = await open(mini);
      final events = await reviewed(src);
      final sel = ReportSelection.defaultFor(events);
      final data = await ReportBuilder.build(
        source: src,
        events: events,
        selection: sel,
        generatedAtUtc: now,
        device: const ReportDevice(name: 'neo-A', serial: 'A0B1C2D3E4F5', firmware: '0.1.0'),
        patientLabel: 'Demo patient',
      );
      final h = data.header;
      expect(h.brand, kBrandName);
      expect(h.generatedAtUtc, now);
      expect(h.eegRateHz, 250);
      expect(h.eegChannels, 2);
      expect(h.imuRateHz, 100);
      expect(h.durationSec, 3600);
      expect(h.recordingStartLocal, DateTime.utc(2026, 10, 5, 8));
      expect(h.recordingEndLocal, DateTime.utc(2026, 10, 5, 9));
      expect(h.synthetic, isTrue);
      expect(h.device!.serial, 'A0B1C2D3E4F5');
      expect(h.patientLabel, 'Demo patient');
      expect(data.disclaimer, kReportDisclaimer);
      expect(data.selectionIsFallback, isTrue);

      expect(data.entries.length, sel.ids.length);
      final starts = data.entries.map((e) => e.startSec).toList();
      expect(starts, orderedEquals([...starts]..sort()));
      for (final e in data.entries) {
        expect(e.window.eventId, e.event.id);
        expect(e.window.channels, 2);
        expect(e.startLocal.hour, inInclusiveRange(8, 9));
        expect(e.night, isFalse);
      }
      expect(data.timeline.length, src.events().length, reason: 'the timeline covers every event');
      expect(data.timeline.where((t) => t.selected).length, sel.ids.length);
      expect(data.overview.count, lessThanOrEqualTo(720));
    });

    test('device and patient are optional', () async {
      final src = await open(mini);
      final data = await ReportBuilder.build(
        source: src,
        events: await reviewed(src),
        selection: const ReportSelection({}),
        generatedAtUtc: now,
      );
      expect(data.header.device, isNull);
      expect(data.header.patientLabel, isNull);
      expect(data.entries, isEmpty);
      expect(data.summary.candidates, 4, reason: 'the summary covers the whole recording, not just the selection');
    });

    test('unknown ids in the selection are ignored', () async {
      final src = await open(mini);
      final data = await ReportBuilder.build(
        source: src,
        events: await reviewed(src),
        selection: const ReportSelection({'nope'}),
        generatedAtUtc: now,
      );
      expect(data.entries, isEmpty);
    });

    test('four channels flow through', () async {
      final src = await open(mini4);
      final events = await reviewed(src);
      final data = await ReportBuilder.build(
        source: src,
        events: events,
        selection: ReportSelection.defaultFor(events),
        generatedAtUtc: now,
      );
      expect(data.header.eegChannels, 4);
      expect(data.entries.first.window.channels, 4);
      expect(eegCsv(data.entries.first).split('\n').first, 'sample_index,t_rel_s,ch1_uV,ch2_uV,ch3_uV,ch4_uV');
    });
  });

  group('CSV', () {
    test('fields are quoted only when needed', () {
      expect(csvField('plain'), 'plain');
      expect(csvField('a,b'), '"a,b"');
      expect(csvField('say "hi"'), '"say ""hi"""');
      expect(csvField('two\nlines'), '"two\nlines"');
    });

    test('local time carries its offset', () {
      expect(formatLocalIso(DateTime.utc(2026, 10, 5, 8, 3, 12), 480), '2026-10-05T08:03:12+08:00');
      expect(formatLocalIso(DateTime.utc(2026, 1, 2, 3, 4, 5), -330), '2026-01-02T03:04:05-05:30');
    });

    late StaticRecordingSource src;
    late ReportData data;
    late String awkwardNote;
    late String awkwardId;
    setUpAll(() async {
      src = await open(mini);
      final ids = src.events().map((e) => e.id).toList();
      awkwardNote = 'Fell asleep, "then" woke\nat 03:10';
      awkwardId = ids[0];
      final events = await reviewed(src, confirm: ids, notes: {awkwardId: awkwardNote});
      data = await ReportBuilder.build(
        source: src,
        events: events,
        selection: ReportSelection.defaultFor(events),
        generatedAtUtc: now,
      );
    });

    test('events.csv round-trips, including a note with a comma, quotes and a line break', () {
      final rows = parseCsv(eventsCsv(data));
      expect(rows.first, [
        'event_id', 'source', 'status', 'start_local', 'start_sec', 'duration_sec',
        'confidence', 'night', 'quality', 'channels', 'note',
      ]);
      expect(rows.length, 1 + data.entries.length);
      expect(rows.every((r) => r.length == 11), isTrue, reason: 'every row has every column');
      final byId = {for (final r in rows.skip(1)) r[0]: r};
      expect(byId[awkwardId]![10], awkwardNote);
      expect(byId[awkwardId]![2], 'confirmed');
      expect(byId[awkwardId]![3], matches(RegExp(r'^2026-10-05T0[89]:\d\d:\d\d\+08:00$')));
      expect(byId[awkwardId]![7], 'no');
      final marker = data.entries.firstWhere((e) => e.event.source == EventSource.patientButton);
      expect(byId[marker.event.id]![6], '', reason: 'a patient marker has no confidence');
      expect(byId[marker.event.id]![9], '', reason: 'and no channels');
      final auto = data.entries.firstWhere((e) => e.event.source == EventSource.auto);
      expect(byId[auto.event.id]![9], '1 2');
    });

    test('the EEG file has a row per sample on the event-relative time axis', () {
      final entry = data.entries.firstWhere((e) => e.event.source == EventSource.auto);
      final rows = parseCsv(eegCsv(entry));
      expect(rows.first, ['sample_index', 't_rel_s', 'ch1_uV', 'ch2_uV']);
      expect(rows.length, 1 + 250 * 40);
      final w = entry.window;
      expect(int.parse(rows[1][0]), w.startSample);
      expect(double.parse(rows[1][1]), closeTo(-15.0, 1e-9));
      final eventRow = rows[1 + 15 * 250];
      expect(int.parse(eventRow[0]), entry.event.startSample);
      expect(double.parse(eventRow[1]), closeTo(0.0, 1e-9), reason: 'time zero is the event start');
      expect(double.parse(rows[1234][2]), closeTo(w.eeg[0][1233], 0.051));
      expect(double.parse(rows.last[1]), closeTo(25.0 - 1 / 250, 1e-9));
    });

    test('the motion file runs at the motion sensor\'s rate', () {
      final entry = data.entries.first;
      final rows = parseCsv(motionCsv(entry));
      expect(rows.first, ['imu_index', 't_rel_s', 'ax_g', 'ay_g', 'az_g', 'gx_dps', 'gy_dps', 'gz_dps']);
      expect(rows.length, 1 + 100 * 40);
      expect(int.parse(rows[1][0]), (entry.window.startSample * 0.4).round());
      expect(double.parse(rows[1][1]), closeTo(-15.0, 1e-9));
      expect(double.parse(rows[1][4]), closeTo(1.0, 0.05), reason: 'gravity on z');
      expect(rows.every((r) => r.length == 8), isTrue);
    });

    test('reportCsvFiles names one events file and two files per event', () {
      final files = reportCsvFiles(data);
      expect(files.length, 1 + 2 * data.entries.length);
      expect(files.containsKey('events.csv'), isTrue);
      for (final e in data.entries) {
        expect(files.containsKey('${e.event.id}_eeg.csv'), isTrue);
        expect(files.containsKey('${e.event.id}_motion.csv'), isTrue);
      }
    });
  });
}
