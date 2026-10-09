import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/config/app_config.dart';
import 'package:neo_companion/data/dataset.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/data/recording_source.dart';
import 'package:neo_companion/data/review_event.dart';
import 'package:neo_companion/data/review_store.dart';
import 'package:neo_companion/data/static_recording_source.dart';

const mini = 'test/fixtures/mini_recording';
const mini4 = 'test/fixtures/mini_recording_4ch';
const bundled = 'assets/demo_recording';

Future<StaticRecordingSource> open(String dir) async {
  final s = StaticRecordingSource(DirectoryDatasetReader(dir));
  await s.load();
  return s;
}

/// A writable copy of a dataset folder.
Directory copyOf(String dir) {
  final tmp = Directory.systemTemp.createTempSync('neo_ds_');
  for (final f in Directory(dir).listSync().whereType<File>()) {
    f.copySync('${tmp.path}/${f.uri.pathSegments.last}');
  }
  return tmp;
}

void main() {
  group('loading a dataset folder', () {
    test('2-channel fixture', () async {
      final s = await open(mini);
      final info = s.info;
      expect(info.synthetic, isTrue);
      expect(info.durationSec, 3600);
      expect(info.eegChannels, 2);
      expect(info.eegRateHz, 250);
      expect(info.imuRateHz, 100);
      final events = s.events();
      expect(events.length, 5);
      expect(events.map((e) => e.startSample).toList(), orderedEquals([...events.map((e) => e.startSample)]..sort()));
      expect(events.map((e) => e.id).toSet().length, 5, reason: 'unique ids');
      expect(events.where((e) => e.source == EventSource.patientButton).length, 1);
    });

    test('4-channel fixture loads through the same code', () async {
      final s = await open(mini4);
      expect(s.info.eegChannels, 4);
      final e = s.events().firstWhere((e) => e.source == EventSource.auto);
      final w = await s.eventWindow(e.id);
      expect(w.channels, 4);
      expect(w.eeg.every((c) => c.length == 250 * 40), isTrue);
    });

    test('the bundled demo recording loads and spans 3 days', () async {
      final s = await open(bundled);
      expect(s.info.durationSec, 3 * 24 * 3600);
      expect(s.events().length, 119);
      final days = [
        for (var d = 0; d < 3; d++) s.events(range: TimeRange(d * 86400.0, (d + 1) * 86400.0)),
      ];
      expect(days.every((d) => d.isNotEmpty), isTrue);
      expect(days.fold<int>(0, (n, d) => n + d.length), 119, reason: 'every event falls in exactly one day');
      final o = s.overview(const TimeRange(0, 86400), 100);
      expect(o.count, lessThanOrEqualTo(100));
      expect(o.count, greaterThan(50));
    });

    test('the bundled assets load the same way the app will load them', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final s = StaticRecordingSource(readerFor(kDatasetLocation));
      await s.load();
      expect(s.events().length, 119);
      final ev = s.events().firstWhere((e) => e.truth == 'seizure-like');
      final w = await s.eventWindow(ev.id);
      expect(w.eeg.length, 2);
      expect(w.eeg[0].length, 250 * 40);
    });

    test('local time and night', () async {
      final info = (await open(mini)).info;
      expect(info.localTimeAt(0).hour, 8); // recording starts 08:00 local
      expect(info.isNight(0), isFalse);
      expect(info.isNight(15 * 3600), isTrue); // 23:00
      expect(info.isNight(22 * 3600), isTrue); // 06:00
      expect(info.isNight(23 * 3600), isFalse); // 07:00
    });

    test('use before load throws', () {
      final s = StaticRecordingSource(DirectoryDatasetReader(mini));
      expect(() => s.events(), throwsStateError);
    });
  });

  group('rejecting bad datasets', () {
    late Directory tmp;
    setUp(() => tmp = copyOf(mini));
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<void> expectRejected(Matcher message) async {
      await expectLater(
        StaticRecordingSource(DirectoryDatasetReader(tmp.path)).load(),
        throwsA(isA<DatasetFormatException>().having((e) => e.message, 'message', message)),
      );
    }

    test('unsupported format version', () async {
      final f = File('${tmp.path}/manifest.json');
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      j['formatVersion'] = 2;
      f.writeAsStringSync(jsonEncode(j));
      await expectRejected(contains('formatVersion 2'));
    });

    test('missing file', () async {
      File('${tmp.path}/overview.json').deleteSync();
      await expectRejected(contains('overview.json'));
    });

    test('truncated windows.bin', () async {
      final f = File('${tmp.path}/windows.bin');
      f.writeAsBytesSync(f.readAsBytesSync().sublist(0, 1000));
      await expectRejected(contains('outside'));
    });

    test('channel count outside 2..4', () async {
      final f = File('${tmp.path}/manifest.json');
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      (j['eeg'] as Map<String, dynamic>)['channels'] = 5;
      f.writeAsStringSync(jsonEncode(j));
      await expectRejected(contains('2..4'));
    });

    test('not JSON', () async {
      File('${tmp.path}/manifest.json').writeAsStringSync('{ nope');
      await expectRejected(contains('JSON'));
    });
  });

  group('overview', () {
    test('coarsening keeps extremes and the worst quality', () async {
      final s = await open(mini);
      const all = TimeRange(0, 3600);
      final fine = s.overview(all, 1000);
      expect(fine.count, 60);
      expect(fine.binSec, 60);
      final coarse = s.overview(all, 10);
      expect(coarse.count, 10);
      expect(coarse.binSec, 360);
      for (var c = 0; c < 2; c++) {
        for (var i = 0; i < 10; i++) {
          final slice = [for (var b = i * 6; b < i * 6 + 6; b++) b];
          expect(coarse.eegMax[c][i], slice.map((b) => fine.eegMax[c][b]).reduce(math.max));
          expect(coarse.eegMin[c][i], slice.map((b) => fine.eegMin[c][b]).reduce(math.min));
        }
      }
      for (var i = 0; i < 10; i++) {
        expect(coarse.quality[i], [for (var b = i * 6; b < i * 6 + 6; b++) fine.quality[b]].reduce(math.min));
      }
    });

    test('a sub-range starts on its first bin and never exceeds maxBins', () async {
      final s = await open(mini);
      final o = s.overview(const TimeRange(600, 1800), 1000);
      expect(o.startSec, 600);
      expect(o.count, 20);
      expect(s.overview(const TimeRange(0, 3600), 7).count, lessThanOrEqualTo(7));
      expect(s.overview(const TimeRange(5000, 6000), 10).count, 0); // beyond the recording
      expect(() => s.overview(const TimeRange(0, 60), 0), throwsArgumentError);
    });
  });

  group('events', () {
    test('range filter uses the event start', () async {
      final s = await open(mini);
      final all = s.events();
      final first = all.first.startSec(250);
      expect(s.events(range: TimeRange(first, first + 1)), [all.first]);
      expect(s.events(range: TimeRange(0, first)), isEmpty);
    });

    test('minConfidence filters automatic events but keeps patient markers', () async {
      final s = await open(mini);
      final strict = s.events(minConfidence: 1.1);
      expect(strict, isNotEmpty);
      expect(strict.every((e) => e.source == EventSource.patientButton), isTrue);
      final seizure = s.events().firstWhere((e) => e.truth == 'seizure-like');
      expect(s.events(minConfidence: 0.8), contains(seizure));
      expect(s.events(minConfidence: 0.0).length, 5);
    });
  });

  group('event windows', () {
    test('lengths, scales and signal content', () async {
      final s = await open(mini);
      final ev = s.events().firstWhere((e) => e.truth == 'seizure-like');
      final w = await s.eventWindow(ev.id);
      expect(w.eeg.length, 2);
      expect(w.eeg[0].length, 250 * 40);
      expect(w.accelX.length, 100 * 40);
      expect(w.gyroZ.length, 100 * 40);
      expect(w.durationSec, 40);
      expect(w.startSample, ev.startSample - 15 * 250);

      double ptp(Float32List x, int from, int to) {
        var lo = x[from], hi = x[from];
        for (var i = from; i < to; i++) {
          lo = math.min(lo, x[i]);
          hi = math.max(hi, x[i]);
        }
        return (hi - lo).toDouble();
      }

      final evStart = (w.preSec * w.eegRateHz).round();
      expect(ptp(w.eeg[0], evStart, evStart + ev.durationSamples), greaterThan(150), reason: 'seizure-like burst in µV');
      expect(ptp(w.eeg[0], 0, 10 * 250), lessThan(100), reason: 'quiet baseline before the event');
      var z = 0.0;
      for (var i = 0; i < 500; i++) {
        z += w.accelZ[i];
      }
      expect(z / 500, closeTo(0.995, 0.02), reason: 'gravity on z, in g');
    });

    test('a patient marker next to a seizure sees the same signal', () async {
      final s = await open(mini);
      final marker = s.events().firstWhere((e) => e.source == EventSource.patientButton);
      final w = await s.eventWindow(marker.id);
      expect(w.eeg[0].length, 250 * 40);
    });

    test('unknown event id', () async {
      final s = await open(mini);
      expect(s.eventWindow('nope'), throwsArgumentError);
    });
  });

  group('ReviewStore', () {
    late Directory tmp;
    late File file;
    var tick = 0;
    DateTime clock() => DateTime.utc(2026, 10, 6, 12, 0, tick++);

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('neo_review_');
      file = File('${tmp.path}/sub/decisions.json');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    ReviewStore store(String key) => ReviewStore(file, datasetKey: key, now: clock);

    test('missing file is an empty store; decisions survive a reload', () async {
      final a = store('k1');
      await a.load();
      expect(a.decisionFor('e0001'), isNull);
      await a.setStatus('e0001', ReviewStatus.confirmed);
      await a.setNote('e0001', '  tired, then fell asleep  ');
      expect(file.existsSync(), isTrue);
      expect(File('${file.path}.tmp').existsSync(), isFalse, reason: 'atomic write leaves no temp file');

      final b = store('k1');
      await b.load();
      final d = b.decisionFor('e0001')!;
      expect(d.status, ReviewStatus.confirmed);
      expect(d.note, 'tired, then fell asleep');
      expect(d.updatedAt.isUtc, isTrue);
    });

    test('status keeps the note, note keeps the status, defaults are not stored', () async {
      final s = store('k1');
      await s.load();
      await s.setNote('e1', 'felt an aura');
      expect(s.decisionFor('e1')!.status, ReviewStatus.candidate);
      await s.setStatus('e1', ReviewStatus.dismissed);
      expect(s.decisionFor('e1')!.note, 'felt an aura');
      await s.setNote('e1', '   ');
      expect(s.decisionFor('e1')!.note, isNull);
      expect(s.decisionFor('e1')!.status, ReviewStatus.dismissed);
      await s.setStatus('e1', ReviewStatus.candidate); // back to default, no note
      expect(s.decisionFor('e1'), isNull);
    });

    test('merge applies decisions and ignores unknown ids', () async {
      final src = await open(mini);
      final events = src.events();
      final s = store(src.info.datasetKey);
      await s.load();
      await s.setStatus(events[1].id, ReviewStatus.confirmed);
      await s.setStatus('does-not-exist', ReviewStatus.confirmed);
      final merged = s.merge(events);
      expect(merged.length, events.length);
      expect(merged[1].status, ReviewStatus.confirmed);
      expect(merged[0].status, ReviewStatus.candidate);
      expect(merged[0].note, isNull);
    });

    test('decisions are scoped to the dataset', () async {
      final a = store('dataset-A');
      await a.load();
      await a.setStatus('e0001', ReviewStatus.confirmed);

      final b = store('dataset-B'); // another recording reusing the id e0001
      await b.load();
      expect(b.decisionFor('e0001'), isNull);
      await b.setStatus('e0002', ReviewStatus.dismissed);

      final a2 = store('dataset-A');
      await a2.load();
      expect(a2.decisionFor('e0001')!.status, ReviewStatus.confirmed, reason: 'B did not erase A');
      expect(a2.decisionFor('e0002'), isNull);
    });

    test('a corrupt file throws and is left untouched', () async {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{ not json');
      final s = store('k1');
      await expectLater(s.load(), throwsA(isA<ReviewStoreException>()));
      expect(file.readAsStringSync(), '{ not json');
    });

    group('when the file cannot be written', () {
      // A folder where the file should be: the final rename onto it fails.
      Future<ReviewStore> blocked() async {
        file.parent.createSync(recursive: true);
        Directory(file.path).createSync();
        final s = store('k1');
        await s.load();
        return s;
      }

      test('a new decision is not kept in memory, and the error is thrown', () async {
        final s = await blocked();
        await expectLater(s.setStatus('e1', ReviewStatus.confirmed), throwsA(anything));
        expect(s.decisionFor('e1'), isNull, reason: 'it must not claim what it could not save');
      });

      test('a change of mind goes back to what was there', () async {
        file.parent.createSync(recursive: true);
        final s = store('k1');
        await s.load();
        await s.setStatus('e1', ReviewStatus.confirmed); // saved fine
        file.deleteSync();
        Directory(file.path).createSync(); // now it cannot be written
        await expectLater(s.setStatus('e1', ReviewStatus.dismissed), throwsA(anything));
        expect(s.decisionFor('e1')!.status, ReviewStatus.confirmed);
      });

      test('a note that could not be saved is not kept either', () async {
        final s = await blocked();
        await expectLater(s.setNote('e1', 'hello'), throwsA(anything));
        expect(s.decisionFor('e1'), isNull);
      });

      test('merging shows only what is really saved', () async {
        final s = await blocked();
        await expectLater(s.setStatus('e1', ReviewStatus.confirmed), throwsA(anything));
        final events = [
          RecordedEvent(
            id: 'e1',
            source: EventSource.auto,
            startSample: 0,
            durationSamples: 1,
            confidence: 0.5,
            channels: const [0],
            quality: 1,
            window: const EventWindowRef(offset: 0, length: 0, preSec: 1, postSec: 1),
          ),
        ];
        expect(s.merge(events).single.status, ReviewStatus.candidate);
      });
    });

    test('updatedAt comes from the injected clock', () async {
      final s = store('k1');
      await s.load();
      await s.setStatus('e1', ReviewStatus.confirmed);
      expect(s.decisionFor('e1')!.updatedAt.year, 2026);
    });
  });
}
