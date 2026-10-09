import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/app/app_services.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/data/review_event.dart';
import 'package:neo_companion/protocol/neo_client.dart';
import 'package:neo_companion/report/pdf_previewer.dart';
import 'package:neo_companion/report/report_choice.dart';
import 'package:neo_companion/report/report_controller.dart';
import 'package:neo_companion/report/report_exporter.dart';
import 'package:neo_companion/report/report_selection.dart';
import 'package:neo_companion/review/review_models.dart';

const mini = 'test/fixtures/mini_recording'; // one hour: 4 automatic events and 1 patient press
const demo = 'assets/demo_recording'; // three days, 119 events

class FakeSharer implements FileSharer {
  final calls = <List<String>>[];
  Object? failWith;
  @override
  Future<void> share(List<File> files, {String? subject}) async {
    if (failWith != null) throw failWith!;
    calls.add([for (final f in files) f.path]);
  }
}

class FakePreviewer implements PdfPreviewer {
  final calls = <int>[]; // size of each PDF it was given
  Object? failWith;
  List<PreviewPage> result = [PreviewPage(Uint8List.fromList([1, 2, 3]), 0.7), PreviewPage(Uint8List.fromList([4]), 0.7)];
  @override
  Future<List<PreviewPage>> render(Uint8List pdf, {int maxPages = 24}) async {
    calls.add(pdf.length);
    if (failWith != null) throw failWith!;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); // the PDF fonts are read from the app's assets
  late Directory dir;
  late FakeSharer sharer;
  late FakePreviewer previewer;
  final opened = <AppServices>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('neo_report_ctl_');
    sharer = FakeSharer();
    previewer = FakePreviewer();
  });
  tearDown(() async {
    for (final s in opened) {
      await s.dispose();
    }
    opened.clear();
    dir.deleteSync(recursive: true);
  });

  AppServices services(String dataset, {Directory? at, bool storage = true}) {
    final s = AppServices(
      client: NeoClient(),
      dataDir: storage ? (at ?? dir) : null,
      reader: DirectoryDatasetReader(dataset),
      sharer: sharer,
      previewer: previewer,
      now: () => DateTime.utc(2026, 10, 9, 8, 30),
    );
    opened.add(s);
    return s;
  }

  Future<ReportController> loaded(String dataset, {Directory? at}) async {
    final c = ReportController(services(dataset, at: at));
    await c.load();
    return c;
  }

  Future<ReportController> loadedWith(AppServices s) async {
    final c = ReportController(s);
    await c.load();
    return c;
  }

  group('loading', () {
    test('opens ready to choose, with the one-tap default', () async {
      final c = await loaded(mini);
      expect(c.stage, ReportStage.editing);
      expect(c.counts.total, 5);
      expect(c.patientLabel, '');
      expect(c.isFallback, isTrue, reason: 'nothing is confirmed yet');
      expect(c.preset, ReportPreset.confirmed);
    });

    test('without app storage it says so', () async {
      final c = ReportController(services(mini, storage: false));
      await c.load();
      expect(c.stage, ReportStage.unavailable);
      expect(c.message, contains('no app storage'));
    });

    test('a recording that will not open is said plainly', () async {
      final c = ReportController(services('test/fixtures/nope'));
      await c.load();
      expect(c.stage, ReportStage.unavailable);
      expect(c.message, contains('could not be opened'));
    });

    test('starts in loading', () async {
      final c = ReportController(services(mini));
      expect(c.stage, ReportStage.loading);
      await c.load();
    });
  });

  group('the default follows the decisions until the reviewer chooses', () {
    test('confirmed events replace the fallback once the page looks again', () async {
      final s = services(mini);
      final c = await loadedWith(s);
      final id = s.recording.events().firstWhere((e) => e.source == EventSource.auto).id;
      await s.reviews.setStatus(id, ReviewStatus.confirmed);
      c.refreshEvents();
      expect(c.isFallback, isFalse);
      expect(c.selection.ids, {id});
    });

    test('a choice made by hand is left alone', () async {
      final s = services(mini);
      final c = await loadedWith(s);
      final events = s.recording.events();
      c.toggle(events.first.id);
      final before = {...c.selection.ids};
      await s.reviews.setStatus(events[1].id, ReviewStatus.confirmed);
      c.refreshEvents();
      expect(c.selection.ids, before);
    });
  });

  group('choosing', () {
    test('each preset sets the choice, and the page knows which one it is', () async {
      final c = await loaded(mini);
      c.applyPreset(ReportPreset.allCandidates);
      expect(c.selectedCount, 4);
      expect(c.preset, ReportPreset.allCandidates);
      c.applyPreset(ReportPreset.markers);
      expect(c.selectedCount, 1);
      expect(c.preset, ReportPreset.markers);
    });

    test('ticking one by hand makes it a custom choice', () async {
      final c = await loaded(mini);
      c.applyPreset(ReportPreset.allCandidates);
      c.toggle(c.groups.all.first.event.id);
      expect(c.preset, isNull);
    });

    test('toggling twice returns to where it was', () async {
      final c = await loaded(mini);
      final id = c.groups.all.first.event.id;
      final before = {...c.selection.ids};
      c.toggle(id);
      c.toggle(id);
      expect(c.selection.ids, before);
    });

    test('a whole group can be ticked and unticked', () async {
      final c = await loaded(demo);
      c.clearSelection();
      final g = c.groups;
      c.setGroup(g.high, on: true);
      expect(c.selectedCount, g.high.length);
      c.setGroup(g.high, on: false);
      expect(c.selectedCount, 0);
    });

    test('clearing leaves nothing chosen', () async {
      final c = await loaded(mini);
      c.clearSelection();
      expect(c.selectedCount, 0);
      expect(c.isFallback, isFalse);
    });

    test('the groups hold the events of the days covered', () async {
      final c = await loaded(demo);
      expect(c.groups.all.length, 119);
      c.setDays(1, 1);
      final rate = c.info.eegRateHz;
      expect(c.groups.all.every((e) => e.event.startSec(rate) >= 86400 && e.event.startSec(rate) < 172800), isTrue);
    });
  });

  group('days', () {
    test('the whole recording to begin with, which is no limit', () async {
      final c = await loaded(demo);
      expect([c.firstDay, c.lastDay, c.dayCount], [0, 2, 3]);
      expect(c.days, isNull);
    });

    test('a run of days is a limit; every day is not', () async {
      final c = await loaded(demo);
      c.setDays(1, 2);
      expect(c.days, const DayRange(1, 2));
      c.setDays(0, 2);
      expect(c.days, isNull);
    });

    test('days given the wrong way round are put right, and out-of-range ones held in range', () async {
      final c = await loaded(demo);
      c.setDays(2, 1);
      expect([c.firstDay, c.lastDay], [1, 2]);
      c.setDays(-5, 99);
      expect([c.firstDay, c.lastDay], [0, 2]);
    });

    test('a choice that was a preset follows the new days', () async {
      final c = await loaded(demo);
      c.applyPreset(ReportPreset.allCandidates);
      c.setDays(0, 0);
      expect(c.preset, ReportPreset.allCandidates);
      expect(c.selectedCount, c.groups.all.where((e) => !e.isMarker && e.status != ReviewStatus.dismissed).length);
    });

    test('a custom choice keeps its ticks, but only those inside the days count', () async {
      final c = await loaded(demo);
      c.clearSelection();
      final rate = c.info.eegRateHz;
      final day1 = c.groups.all.firstWhere((e) => e.event.startSec(rate) < 86400);
      final day3 = c.groups.all.firstWhere((e) => e.event.startSec(rate) >= 172800);
      c.toggle(day1.event.id);
      c.toggle(day3.event.id);
      expect(c.selectedCount, 2);
      c.setDays(0, 0);
      expect(c.selectedCount, 1);
      expect(c.selection.contains(day3.event.id), isTrue, reason: 'still ticked, just outside the days');
    });

    test('a recording shorter than a day has one day', () async {
      final c = await loaded(mini);
      expect(c.dayCount, 1);
      expect(c.days, isNull);
    });
  });

  group('the patient label', () {
    test('is saved, and is there next time', () async {
      final s1 = services(mini);
      final a = await loadedWith(s1);
      await a.setPatientLabel('  Subject 4092 ');
      expect(a.patientLabel, 'Subject 4092');
      final b = await loaded(mini);
      expect(b.patientLabel, 'Subject 4092');
    });

    test('can be changed and cleared', () async {
      final a = await loaded(mini);
      await a.setPatientLabel('One');
      await a.setPatientLabel('');
      expect((await loaded(mini)).patientLabel, '');
    });

    test('quick edits end on the last one', () async {
      final a = await loaded(mini);
      final w = [a.setPatientLabel('a'), a.setPatientLabel('ab'), a.setPatientLabel('abc')];
      await Future.wait(w);
      expect((await loaded(mini)).patientLabel, 'abc');
    });

    test('a failure to remember it does not stop the report', () async {
      Directory('${dir.path}/report_settings.json').createSync();
      final a = await loaded(mini);
      await a.setPatientLabel('kept for now');
      expect(a.patientLabel, 'kept for now');
    });

    test('typing applies at once, before it is saved, so a quick Create cannot miss it', () async {
      final c = await loaded(mini);
      c.editLabel('  Typed just now ');
      expect(c.patientLabel, 'Typed just now');
      expect(File('${dir.path}/report_settings.json').existsSync(), isFalse, reason: 'not saved yet');
      await c.saveLabel();
      expect((await loaded(mini)).patientLabel, 'Typed just now');
    });

    test('editing and saving announce nothing, so they are safe while a page is going away', () async {
      final c = await loaded(mini);
      var told = 0;
      c.addListener(() => told++);
      c.editLabel('quiet');
      await c.saveLabel();
      expect(told, 0);
    });

    test('goes on the report', () async {
      final a = await loaded(mini);
      await a.setPatientLabel('Subject 4092');
      await a.create();
      final pdf = latin1.decode(await a.exported!.pdf.readAsBytes());
      expect(pdf.contains('Subject'), isTrue);
    });
  });

  group('creating the report', () {
    test('writes the PDF and the CSV zip, then shows pages', () async {
      final c = await loaded(mini);
      final seen = <ReportStage>[];
      c.addListener(() => seen.add(c.stage));
      await c.create();
      expect(seen, containsAllInOrder([ReportStage.building, ReportStage.ready]));
      expect(c.stage, ReportStage.ready);
      expect(c.exported!.pdf.existsSync(), isTrue);
      expect(c.exported!.csvZip.existsSync(), isTrue);
      expect(latin1.decode(c.exported!.pdf.readAsBytesSync().sublist(0, 5)), '%PDF-');
      expect(previewer.calls.single, c.exported!.pdf.lengthSync(), reason: 'the preview is of this very file');
      expect(c.pages.length, 2);
      expect(c.pageCount, greaterThanOrEqualTo(2));
      expect(c.previewFailed, isFalse);
      expect(sharer.calls, isEmpty, reason: 'nothing is shared until the reviewer says so');
    });

    test('remembers how many events it holds', () async {
      final c = await loaded(mini);
      c.applyPreset(ReportPreset.allCandidates);
      await c.create();
      expect(c.eventsInReport, 4);
    });

    test('covers only the days chosen, and says so on the file', () async {
      final c = await loaded(demo);
      c.setDays(1, 1);
      await c.create();
      expect(c.builtDays, const DayRange(1, 1));
      expect(c.exported!.pdf.path, endsWith('20261006.pdf'));
    });

    test('with nothing chosen the report is still made, from the summary alone', () async {
      final c = await loaded(mini);
      c.clearSelection();
      await c.create();
      expect(c.stage, ReportStage.ready);
      expect(c.eventsInReport, 0);
    });

    test('the fallback reaches the report, and is gone once the reviewer has chosen', () async {
      final sa = services(mini);
      final a = await loadedWith(sa);
      expect(a.isFallback, isTrue);
      expect((await sa.buildReport(selection: a.selection)).selectionIsFallback, isTrue);

      final sb = services(mini);
      final b = await loadedWith(sb);
      b.applyPreset(ReportPreset.allCandidates);
      expect(b.isFallback, isFalse);
      expect((await sb.buildReport(selection: b.selection)).selectionIsFallback, isFalse);
    });

    test('a preview that fails does not stop the report', () async {
      previewer.failWith = StateError('no renderer');
      final c = await loaded(mini);
      await c.create();
      expect(c.stage, ReportStage.ready);
      expect(c.previewFailed, isTrue);
      expect(c.pages, isEmpty);
      expect(c.exported!.pdf.existsSync(), isTrue);
    });

    test('a preview with no pages counts as failed', () async {
      previewer.result = const [];
      final c = await loaded(mini);
      await c.create();
      expect(c.previewFailed, isTrue);
    });

    test('a failure to write is said, and the choice is kept', () async {
      File('${dir.path}/reports').writeAsStringSync('in the way'); // a file where the folder should be
      final c = await loaded(mini);
      c.applyPreset(ReportPreset.allCandidates);
      await c.create();
      expect(c.stage, ReportStage.editing);
      expect(c.error, isNotNull);
      expect(c.preset, ReportPreset.allCandidates);
    });

    test('asking twice while it is building makes one report', () async {
      final c = await loaded(mini);
      await Future.wait([c.create(), c.create()]);
      expect(previewer.calls.length, 1);
    });

    test('cannot create from a page that is not choosing', () async {
      final c = ReportController(services(mini));
      await c.create(); // still loading
      expect(c.stage, ReportStage.loading);
    });
  });

  group('sharing', () {
    test('hands over exactly the two files that were written', () async {
      final c = await loaded(mini);
      await c.create();
      await c.share();
      expect(sharer.calls, [
        [c.exported!.pdf.path, c.exported!.csvZip.path]
      ]);
      expect(c.isSharing, isFalse);
    });

    test('a share sheet that fails is said, and the report is still there', () async {
      sharer.failWith = StateError('no sheet');
      final c = await loaded(mini);
      await c.create();
      await c.share();
      expect(c.error, contains('share sheet'));
      expect(c.stage, ReportStage.ready);
    });

    test('with no report there is nothing to share', () async {
      final c = await loaded(mini);
      await c.share();
      expect(sharer.calls, isEmpty);
    });
  });

  group('making another', () {
    test('goes back to choosing with the same choice, and a second report can be made', () async {
      final c = await loaded(mini);
      c.applyPreset(ReportPreset.allCandidates);
      await c.create();
      c.createAnother();
      expect(c.stage, ReportStage.editing);
      expect(c.exported, isNull);
      expect(c.pages, isEmpty);
      expect(c.preset, ReportPreset.allCandidates);
      await c.create();
      expect(c.stage, ReportStage.ready);
      expect(c.exported!.pdf.existsSync(), isTrue);
    });

    test('does nothing unless there is a report to leave', () async {
      final c = await loaded(mini);
      c.createAnother();
      expect(c.stage, ReportStage.editing);
    });
  });

  test('a page that is gone is not disturbed by a build that finishes late', () async {
    final c = await loaded(mini);
    final pending = c.create();
    c.dispose();
    await pending; // must not throw
  });
}
