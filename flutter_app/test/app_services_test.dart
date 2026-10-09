import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/app/app_scope.dart';
import 'package:neo_companion/app/app_services.dart';
import 'package:neo_companion/data/dataset.dart';
import 'package:neo_companion/data/dataset_library.dart';
import 'package:neo_companion/data/dataset_picker.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/config/app_config.dart';
import 'package:neo_companion/data/review_event.dart';
import 'package:neo_companion/live/activity_risk.dart';
import 'package:neo_companion/protocol/neo_messages.dart';
import 'package:neo_companion/protocol/neo_client.dart';
import 'package:neo_companion/report/report_exporter.dart';
import 'package:neo_companion/report/report_models.dart';
import 'package:neo_companion/report/report_selection.dart';

const mini = 'test/fixtures/mini_recording';
const mini4 = 'test/fixtures/mini_recording_4ch';
final fixedNow = DateTime.utc(2026, 10, 7, 9, 30);

class FakePicker implements DatasetPicker {
  File? result;
  int calls = 0;
  @override
  Future<File?> pickZip() async {
    calls++;
    return result;
  }
}

Map<String, List<int>> filesOf(String dir) => {
      for (final f in DatasetLibrary.requiredFiles) f: File('$dir/$f').readAsBytesSync(),
    };

File writeZip(Directory where, String name, Map<String, List<int>> entries) {
  final a = Archive();
  entries.forEach((n, b) => a.add(ArchiveFile.bytes(n, b)));
  return File('${where.path}/$name')..writeAsBytesSync(ZipEncoder().encodeBytes(a));
}

class FakeSharer implements FileSharer {
  final calls = <List<String>>[];
  @override
  Future<void> share(List<File> files, {String? subject}) async => calls.add([for (final f in files) f.path]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // the bundled demo is read from assets
  late Directory dir;
  late FakeSharer sharer;
  final opened = <AppServices>[];

  AppServices services({Directory? dataDir, String dataset = mini}) {
    final s = AppServices(
      client: NeoClient(),
      dataDir: dataDir ?? dir,
      reader: DirectoryDatasetReader(dataset),
      sharer: sharer,
      now: () => fixedNow,
    );
    opened.add(s);
    return s;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('neo_app_');
    sharer = FakeSharer();
  });
  tearDown(() async {
    for (final s in opened) {
      await s.dispose();
    }
    opened.clear();
    dir.deleteSync(recursive: true);
  });

  group('review', () {
    test('is not available until loaded', () {
      final s = services();
      expect(() => s.recording, throwsStateError);
      expect(() => s.reviews, throwsStateError);
    });

    test('loads the recording and the saved decisions', () async {
      final s = services();
      await s.loadReview();
      expect(s.recording.events().length, 5);
      expect(s.reviewEvents().length, 5);
      expect(s.reviewEvents().every((e) => e.status == ReviewStatus.candidate), isTrue);
      await s.loadReview(); // cached: a second call is harmless
    });

    test('decisions survive a restart and drive the one-click selection', () async {
      final first = services();
      await first.loadReview();
      final id = first.recording.events().firstWhere((e) => e.source == EventSource.auto).id;
      await first.reviews.setStatus(id, ReviewStatus.confirmed);
      await first.reviews.setNote(id, 'seen by carer');
      await first.dispose();

      final second = services(); // a new run of the app on the same folder
      final report = await second.buildReport();
      expect(second.reviewEvents().firstWhere((e) => e.event.id == id).note, 'seen by carer');
      expect(report.entries.map((e) => e.event.id), [id], reason: 'only the confirmed event is selected');
      expect(report.selectionIsFallback, isFalse);
    });

    test('decisions belong to their recording', () async {
      final s = services();
      await s.loadReview();
      final id = s.recording.events().first.id; // e0001 exists in every generated dataset
      await s.reviews.setStatus(id, ReviewStatus.confirmed);

      await s.reloadRecording(reader: DirectoryDatasetReader(mini4));
      expect(s.recording.info.eegChannels, 4);
      expect(s.reviewEvents().any((e) => e.status == ReviewStatus.confirmed), isFalse,
          reason: 'another recording must not inherit the decision');

      await s.reloadRecording(reader: DirectoryDatasetReader(mini));
      expect(s.reviewEvents().where((e) => e.status == ReviewStatus.confirmed).length, 1);
    });

    test('a failed load can be retried', () async {
      final s = AppServices(client: NeoClient(), dataDir: dir, reader: DirectoryDatasetReader('test/fixtures/nope'), sharer: sharer);
      opened.add(s);
      await expectLater(s.loadReview(), throwsA(isA<DatasetFormatException>()));
      await s.reloadRecording(reader: DirectoryDatasetReader(mini));
      expect(s.recording.events(), isNotEmpty);
    });
  });

  group('report', () {
    test('is built from the recording, with the time the app gave it', () async {
      final s = services();
      final r = await s.buildReport(patientLabel: 'Demo patient');
      expect(r.header.generatedAtUtc, fixedNow);
      expect(r.header.patientLabel, 'Demo patient');
      expect(r.selectionIsFallback, isTrue);
      expect(r.entries, isNotEmpty);
    });

    test('names a device only when told which one made the recording', () async {
      final s = services();
      expect((await s.buildReport()).header.device, isNull);
      final r = await s.buildReport(device: const ReportDevice(name: 'neo-A', serial: 'S1', firmware: '0.1.0'));
      expect(r.header.device!.serial, 'S1');
    });

    test('one click writes the PDF and the CSV zip and does not share unless asked', () async {
      final s = services();
      final out = await s.exportReport(share: false);
      expect(out.dir.path, '${dir.path}/reports/report-20261007-093000');
      expect(out.pdf.existsSync(), isTrue);
      expect(latin1.decode((await out.pdf.readAsBytes()).sublist(0, 5)), '%PDF-');
      final zip = ZipDecoder().decodeBytes(await out.csvZip.readAsBytes());
      expect(zip.files.any((f) => f.name == 'csv/events.csv'), isTrue);
      expect(out.csvFileCount, zip.files.length);
      expect(sharer.calls, isEmpty);
    });

    test('can cover only some days, and its default selection stays inside them', () async {
      final s = services(dataset: 'assets/demo_recording'); // 3 days
      final r = await s.buildReport(days: const DayRange(1, 1));
      expect(r.header.isPartial, isTrue);
      expect(r.selectionIsFallback, isTrue, reason: 'nothing confirmed yet');
      expect(r.entries, isNotEmpty);
      for (final e in r.entries) {
        expect(e.startSec, inInclusiveRange(86400.0, 2 * 86400.0), reason: 'only Day 2');
      }
      final out = await s.exportReport(days: const DayRange(1, 1), share: false);
      expect(out.pdf.path, endsWith('20261006.pdf'));
    });

    test('and shares both files by default', () async {
      final s = services();
      final out = await s.exportReport();
      expect(sharer.calls, [
        [out.pdf.path, out.csvZip.path]
      ]);
    });
  });

  group('"Seizure now" markers', () {
    NeoEegPacket eegAt(int idx, int n) => NeoEegPacket(
          NeoHeader(sampleIdx: idx),
          2,
          1,
          [for (var k = 0; k < n; k++) NeoEegSample(0, [idx + k, 0])],
        );

    test('with no signal yet, nothing is marked', () {
      final s = services();
      expect(s.markSeizure(), isNull);
      expect(s.seizureMarkers.count, 0);
    });

    test('a marker sits on the newest sample, in the stream it was made in, at the time the app gave it', () {
      final s = services();
      s.live.pushEeg(eegAt(0, 500));
      final m = s.markSeizure()!;
      expect(m.sampleIdx, 499);
      expect(m.streamId, s.live.streamId);
      expect(m.at, fixedNow);
      expect(s.seizureMarkers.markers.single, m);
    });

    test('markers are kept in order, with their own ids, and tell listeners', () {
      final s = services();
      s.live.pushEeg(eegAt(0, 500));
      var told = 0;
      s.seizureMarkers.addListener(() => told++);
      final a = s.markSeizure()!;
      s.live.pushEeg(eegAt(500, 500));
      final b = s.markSeizure()!;
      expect(a.id, isNot(b.id));
      expect([for (final m in s.seizureMarkers.markers) m.sampleIdx], [499, 999]);
      expect(told, 2);
    });

    test('a marker remembers which stream it belongs to when the stream restarts', () {
      final s = services();
      s.live.pushEeg(eegAt(0, 500));
      final before = s.markSeizure()!;
      s.live.reset();
      s.live.pushEeg(eegAt(0, 300));
      final after = s.markSeizure()!;
      expect(after.streamId, isNot(before.streamId));
      expect(s.seizureMarkers.count, 2, reason: 'the first is kept, but belongs to the old stream');
    });

    test('clearing removes them all', () {
      final s = services();
      s.live.pushEeg(eegAt(0, 500));
      s.markSeizure();
      s.seizureMarkers.clear();
      expect(s.seizureMarkers.count, 0);
    });
  });

  test('the experimental readout exists while its switch is on', () {
    final s = services();
    expect(kShowExperimentalRisk, isTrue);
    expect(s.activityRisk, isNotNull);
    expect(s.activityRisk!.value.state, RiskState.noData);
  });

  test('without app storage, review and report say so plainly', () async {
    final s = AppServices(client: NeoClient(), reader: DirectoryDatasetReader(mini), sharer: sharer);
    opened.add(s);
    await expectLater(s.loadReview(), throwsA(isA<StateError>().having((e) => e.message, 'message', contains('no app storage'))));
    await expectLater(s.exportReport(), throwsStateError);
  });

  test('dispose can be called twice, and start after dispose does nothing', () async {
    final s = services();
    await s.dispose();
    await s.dispose();
    await s.start(); // would open a socket if it ran
  });

  test('the tracker and the feed watch the same client the app uses', () async {
    final s = AppServices(dataDir: dir, reader: DirectoryDatasetReader(mini), sharer: sharer); // no client given
    opened.add(s);
    expect(s.status.value.link.name, 'searching');
    expect(s.client.state, NeoConnState.searching);
  });

  group('choosing a recording', () {
    late FakePicker picker;
    late Directory zips; // where the picker "downloads" its zip

    /// Services on the app's real path: no reader override, so the saved choice decides.
    AppServices app() {
      final s = AppServices(client: NeoClient(), dataDir: dir, sharer: sharer, picker: picker, now: () => fixedNow);
      opened.add(s);
      return s;
    }

    setUp(() {
      picker = FakePicker();
      zips = Directory.systemTemp.createTempSync('neo_zips_');
    });
    tearDown(() => zips.deleteSync(recursive: true));

    test('starts on the bundled demo', () async {
      final s = app();
      await s.loadReview();
      expect(s.currentDataset, isNull);
      expect(s.recording.info.eegChannels, 2);
      expect(s.recording.events().length, 119);
      expect(s.datasetNotice, isNull);
      expect(await s.listDatasets(), isEmpty);
    });

    test('pick, import and switch in one call; the chooser\'s cache copy is cleaned up', () async {
      final s = app();
      await s.loadReview();
      picker.result = writeZip(zips, 'Four Channel Study.zip', filesOf(mini4));
      final summary = await s.pickAndImportDataset();
      expect(summary!.name, 'four-channel-study');
      expect(s.currentDataset, 'four-channel-study');
      expect(s.recording.info.eegChannels, 4);
      expect(s.recording.events().length, 4);
      expect(picker.result!.existsSync(), isFalse, reason: 'the picker\'s temporary copy was deleted');
      expect((await s.listDatasets()).map((d) => d.name), ['four-channel-study']);
    });

    test('the choice is remembered when the app restarts', () async {
      final first = app();
      await first.loadReview();
      picker.result = writeZip(zips, 'r.zip', filesOf(mini4));
      await first.pickAndImportDataset();
      await first.dispose();

      final second = app();
      await second.loadReview();
      expect(second.currentDataset, 'r');
      expect(second.recording.info.eegChannels, 4);
    });

    test('cancelling the chooser changes nothing', () async {
      final s = app();
      await s.loadReview();
      picker.result = null;
      expect(await s.pickAndImportDataset(), isNull);
      expect(picker.calls, 1);
      expect(s.currentDataset, isNull);
      expect(s.recording.events().length, 119);
    });

    test('a zip that is not a recording is refused with an explanation, and the current recording stays', () async {
      final s = app();
      await s.loadReview();
      picker.result = writeZip(zips, 'bad.zip', {'notes.txt': [1, 2, 3]});
      await expectLater(s.pickAndImportDataset(),
          throwsA(isA<DatasetImportException>().having((e) => e.message, 'message', contains('manifest.json'))));
      expect(s.currentDataset, isNull);
      expect(s.recording.events().length, 119);
      expect(picker.result!.existsSync(), isFalse, reason: 'the temporary copy is cleaned up on failure too');
      expect(await s.listDatasets(), isEmpty);
    });

    test('review decisions follow their own recording when switching', () async {
      final s = app();
      await s.loadReview();
      final demoId = s.recording.events().first.id;
      await s.reviews.setStatus(demoId, ReviewStatus.confirmed);

      picker.result = writeZip(zips, 'r.zip', filesOf(mini));
      await s.pickAndImportDataset();
      expect(s.reviewEvents().where((e) => e.status == ReviewStatus.confirmed), isEmpty,
          reason: 'the demo\'s decision does not appear on the imported recording');

      await s.useDataset(null);
      expect(s.reviewEvents().firstWhere((e) => e.event.id == demoId).status, ReviewStatus.confirmed);
    });

    test('a saved recording that has gone bad falls back to the demo and says so', () async {
      final first = app();
      await first.loadReview();
      picker.result = writeZip(zips, 'r.zip', filesOf(mini));
      final summary = (await first.pickAndImportDataset())!;
      await first.dispose();
      File('${summary.dir.path}/manifest.json').writeAsStringSync('{ damaged');

      final second = app();
      await second.loadReview();
      expect(second.currentDataset, isNull);
      expect(second.recording.events().length, 119, reason: 'the demo is shown instead of nothing');
      expect(second.datasetNotice, allOf(contains('"r"'), contains('demo recording is shown instead')));
      expect(await second.library!.selected(), isNull, reason: 'the broken choice is forgotten');
    });

    test('removing the recording in use returns to the demo', () async {
      final s = app();
      await s.loadReview();
      picker.result = writeZip(zips, 'r.zip', filesOf(mini4));
      await s.pickAndImportDataset();
      await s.removeDataset('r');
      expect(s.currentDataset, isNull);
      expect(s.recording.events().length, 119);
      expect(await s.listDatasets(), isEmpty);
    });

    test('without app storage, importing fails before the chooser opens', () async {
      final s = AppServices(client: NeoClient(), picker: picker, sharer: sharer);
      opened.add(s);
      await expectLater(s.pickAndImportDataset(), throwsStateError);
      expect(picker.calls, 0);
      await expectLater(s.listDatasets(), throwsStateError);
    });
  });

  group('AppScope', () {
    testWidgets('hands the services to the pages below it', (tester) async {
      final s = services();
      AppServices? got;
      await tester.pumpWidget(AppScope(
        services: s,
        child: Builder(builder: (c) {
          got = AppScope.of(c);
          return const SizedBox();
        }),
      ));
      expect(got, same(s));
    });

    testWidgets('says what is wrong when there is no scope', (tester) async {
      await tester.pumpWidget(Builder(builder: (c) {
        AppScope.of(c);
        return const SizedBox();
      }));
      expect(tester.takeException(), isA<FlutterError>().having((e) => e.toString(), 'text', contains('AppScope')));
    });
  });
}
