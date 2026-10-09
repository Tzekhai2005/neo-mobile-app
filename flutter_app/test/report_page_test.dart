import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/app/app_scope.dart';
import 'package:neo_companion/app/app_services.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/data/review_event.dart';
import 'package:neo_companion/protocol/neo_client.dart';
import 'package:neo_companion/report/pdf_previewer.dart';
import 'package:neo_companion/report/report_exporter.dart';
import 'package:neo_companion/review/review_models.dart';
import 'package:neo_companion/ui/report/report_page.dart';
import 'package:neo_companion/ui/shell/app_shell.dart';
import 'package:neo_companion/ui/theme/app_theme.dart';

import 'helpers/settle.dart';
import 'helpers/test_fonts.dart';

const mini = 'test/fixtures/mini_recording'; // one hour: 4 automatic events (1 High, 1 Medium, 2 Low) and 1 patient press
const demo = 'assets/demo_recording'; // three days, 119 events

final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

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
  Object? failWith;
  late List<PreviewPage> result = [PreviewPage(Uint8List.fromList(_png), 0.7), PreviewPage(Uint8List.fromList(_png), 0.7)];
  @override
  Future<List<PreviewPage>> render(Uint8List pdf, {int maxPages = 24}) async {
    if (failWith != null) throw failWith!;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadTestFonts);

  late Directory dir;
  late FakeSharer sharer;
  late FakePreviewer previewer;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('neo_report_page_');
    sharer = FakeSharer();
    previewer = FakePreviewer();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<AppServices> services(WidgetTester t, String dataset, {bool storage = true}) async {
    final s = AppServices(
      client: NeoClient(),
      dataDir: storage ? dir : null,
      reader: DirectoryDatasetReader(dataset),
      sharer: sharer,
      previewer: previewer,
    );
    addTearDown(s.dispose);
    if (storage) await t.runAsync(s.loadReview);
    return s;
  }

  Future<void> open(WidgetTester t, AppServices s, {Widget? home, Size size = const Size(390, 900)}) async {
    t.view.physicalSize = size * 2;
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(AppScope(
      services: s,
      child: MaterialApp(theme: buildAppTheme(), home: home ?? const Scaffold(body: ReportPage())),
    ));
    await settle(t, 120);
  }

  /// Wait (in real time) until [finder] shows, for the things that take a while:
  /// writing a PDF in another isolate.
  Future<void> until(WidgetTester t, Finder finder, {int seconds = 25}) async {
    for (var i = 0; i < seconds * 10; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await t.pump(const Duration(milliseconds: 50));
      if (finder.evaluate().isNotEmpty) break;
    }
    await t.pump();
  }

  Finder text(String s) => find.text(s);
  Finder key(String k) => find.byKey(ValueKey(k));

  Future<void> create(WidgetTester t) async {
    await t.tap(key('create-report'));
    await until(t, key('report-ready'));
    await settle(t, 40);
  }

  group('opening', () {
    testWidgets('shows the counts, the presets, the groups by band, and Create', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      expect(key('summary'), findsOneWidget);
      expect(text('events'), findsOneWidget);
      for (final k in ['preset-confirmed', 'preset-allCandidates', 'preset-markers', 'clear', 'create-report', 'label-field']) {
        expect(key(k), findsOneWidget, reason: k);
      }
      expect(text('Patient markers'), findsOneWidget);
      expect(text('High'), findsWidgets);
      expect(text('Medium'), findsWidgets);
      expect(text('Low'), findsWidgets);
      expect(text('4 selected'), findsOneWidget, reason: 'nothing confirmed, so the top candidates');
    });

    testWidgets('says why when nothing is confirmed yet', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      expect(key('fallback-notice'), findsOneWidget);
      expect(find.textContaining('Nothing is confirmed yet'), findsOneWidget);
    });

    testWidgets('says plainly when there is no storage', (t) async {
      final s = await services(t, mini, storage: false);
      await open(t, s);
      expect(key('report-message'), findsOneWidget);
      expect(find.textContaining('no app storage'), findsOneWidget);
    });

    testWidgets('says plainly when the recording cannot be opened', (t) async {
      final s = AppServices(client: NeoClient(), dataDir: dir, reader: DirectoryDatasetReader('test/fixtures/nope'), sharer: sharer, previewer: previewer);
      addTearDown(s.dispose);
      await open(t, s);
      expect(find.textContaining('could not be opened'), findsOneWidget);
    });

    testWidgets('a synthetic recording says the report will say so', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      expect(find.textContaining('synthetic'), findsWidgets);
    });
  });

  group('choosing events', () {
    testWidgets('the presets set the choice, and the chip shows which is on', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await t.tap(key('preset-allCandidates'));
      await t.pump();
      expect(text('4 selected'), findsOneWidget);
      expect(t.widget<Material>(find.descendant(of: key('preset-allCandidates'), matching: find.byType(Material)).first).color, AppColors.accentSoft);
      await t.tap(key('preset-markers'));
      await t.pump();
      expect(text('1 selected'), findsOneWidget);
      expect(key('fallback-notice'), findsNothing);
    });

    testWidgets('Clear leaves nothing, and the button says what the report will then hold', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await t.tap(key('clear'));
      await t.pump();
      expect(text('0 selected'), findsOneWidget);
      expect(find.textContaining('hold only the summary'), findsOneWidget);
    });

    testWidgets('a row ticks and unticks', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await t.tap(key('clear'));
      await t.pump();
      final id = s.recording.events().first.id;
      await t.tap(key('report-row-$id'));
      await t.pump();
      expect(text('1 selected'), findsOneWidget);
      await t.tap(key('report-row-$id'));
      await t.pump();
      expect(text('0 selected'), findsOneWidget);
    });

    testWidgets('a group box ticks and unticks the whole group', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await t.tap(key('clear'));
      await t.pump();
      await t.tap(key('group-low'));
      await t.pump();
      expect(text('2 selected'), findsOneWidget);
      expect(find.text('2 of 2'), findsOneWidget);
      await t.tap(key('group-low'));
      await t.pump();
      expect(text('0 selected'), findsOneWidget);
    });

    testWidgets('a group box is half-ticked when only some are', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await t.tap(key('clear'));
      await t.pump();
      final low = s.reviewEvents().where((e) => e.band?.name == 'low').first;
      await t.tap(key('report-row-${low.event.id}'));
      await t.pump();
      expect(t.widget<Checkbox>(key('group-low')).value, isNull, reason: 'a half-ticked box');
    });

    testWidgets('a band is shown as a word, never as a score', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      expect(find.textContaining(RegExp(r'0\.\d\d')), findsNothing);
    });
  });

  group('days', () {
    testWidgets('a recording of one day has no day picker', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      expect(key('day-from'), findsNothing);
    });

    testWidgets('a three-day recording has one, and a narrower choice changes what is listed', (t) async {
      final s = await services(t, demo);
      await open(t, s);
      expect(key('day-from'), findsOneWidget);
      expect(key('day-to'), findsOneWidget);
      await t.tap(key('preset-allCandidates'));
      await t.pump();
      final all = (t.widget<Text>(key('selected-count')).data)!;
      await t.tap(key('day-to'));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Day 1 ·').last);
      await t.pumpAndSettle();
      final one = (t.widget<Text>(key('selected-count')).data)!;
      expect(one, isNot(all));
      expect(int.parse(one.split(' ').first), lessThan(int.parse(all.split(' ').first)));
    });
  });

  group('the patient label', () {
    testWidgets('is saved a moment after typing, and is there next time', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await t.enterText(key('label-field'), 'Jordan Lee');
      await t.pump(const Duration(milliseconds: 700));
      await settle(t, 80);
      expect(File('${dir.path}/report_settings.json').readAsStringSync(), contains('Jordan Lee'));

      final s2 = await services(t, mini);
      await t.pumpWidget(const SizedBox());
      await open(t, s2);
      expect(find.text('Jordan Lee'), findsOneWidget);
    });

    testWidgets('pressing Create straight after typing uses what was typed, with no error', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await t.enterText(key('label-field'), 'Straight away'); // no pause for the save
      await t.tap(key('create-report'));
      await until(t, key('report-ready'));
      expect(t.takeException(), isNull, reason: 'the form went away with a save pending');
      await settle(t, 60);
      expect(File('${dir.path}/report_settings.json').readAsStringSync(), contains('Straight away'));
    });

    testWidgets('is not lost if the page goes away straight after typing', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await t.enterText(key('label-field'), 'Typed in a hurry');
      await t.pumpWidget(const SizedBox());
      await settle(t, 60); // the save runs after the page is gone
      expect(File('${dir.path}/report_settings.json').readAsStringSync(), contains('Typed in a hurry'));
    });
  });

  group('creating the report', () {
    testWidgets('shows the pages, what the report holds, and its files', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await t.tap(key('preset-allCandidates'));
      await t.pump();
      await create(t);
      expect(key('report-ready'), findsOneWidget);
      expect(find.textContaining('4 events'), findsOneWidget);
      expect(find.textContaining('All days'), findsOneWidget);
      expect(key('page-0'), findsOneWidget);
      expect(key('page-1'), findsOneWidget);
      expect(find.textContaining('.pdf'), findsOneWidget);
      expect(find.textContaining('-data.zip'), findsOneWidget);
      expect(sharer.calls, isEmpty, reason: 'nothing is shared until Share is pressed');
    });

    testWidgets('a three-day recording narrowed to one day says which', (t) async {
      final s = await services(t, demo);
      await open(t, s);
      await t.tap(key('day-to'));
      await t.pumpAndSettle();
      await t.tap(find.textContaining('Day 1 ·').last);
      await t.pumpAndSettle();
      await create(t);
      expect(find.textContaining('Day 1'), findsWidgets);
      expect(find.textContaining('All days'), findsNothing);
    });

    testWidgets('a page can be opened full screen and closed', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await create(t);
      await t.tap(key('page-0'));
      await t.pumpAndSettle();
      expect(key('page-viewer'), findsOneWidget);
      await t.tap(key('close-viewer'));
      await t.pumpAndSettle();
      expect(key('page-viewer'), findsNothing);
    });

    testWidgets('says when only some of the pages are shown', (t) async {
      previewer.result = [PreviewPage(Uint8List.fromList(_png), 0.7)];
      final s = await services(t, mini);
      await open(t, s);
      await create(t);
      expect(key('preview-truncated'), findsOneWidget);
      expect(find.textContaining('Showing the first 1 of'), findsOneWidget);
    });

    testWidgets('a preview that fails still lets the report be shared', (t) async {
      previewer.failWith = StateError('no renderer');
      final s = await services(t, mini);
      await open(t, s);
      await create(t);
      expect(key('preview-unavailable'), findsOneWidget);
      expect(key('share'), findsOneWidget);
    });

    testWidgets('a failure to write is said, and the choice is kept', (t) async {
      File('${dir.path}/reports').writeAsStringSync('in the way');
      final s = await services(t, mini);
      await open(t, s);
      await t.tap(key('preset-allCandidates'));
      await t.pump();
      await t.tap(key('create-report'));
      await until(t, key('report-error'));
      expect(key('report-error'), findsOneWidget);
      expect(key('create-report'), findsOneWidget);
      expect(text('4 selected'), findsOneWidget);
    });
  });

  group('sharing', () {
    testWidgets('Share hands over the two files', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await create(t);
      await t.tap(key('share'));
      await settle(t, 60);
      expect(sharer.calls.length, 1);
      expect(sharer.calls.single.length, 2);
      expect(sharer.calls.single.first, endsWith('.pdf'));
      expect(sharer.calls.single.last, endsWith('-data.zip'));
    });

    testWidgets('a share sheet that fails is said, and the report stays', (t) async {
      sharer.failWith = StateError('no sheet');
      final s = await services(t, mini);
      await open(t, s);
      await create(t);
      await t.tap(key('share'));
      await settle(t, 60);
      expect(find.textContaining('share sheet'), findsOneWidget);
      expect(key('report-ready'), findsOneWidget);
    });

    testWidgets('Create another goes back to choosing with the same choice', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await t.tap(key('preset-markers'));
      await t.pump();
      await create(t);
      await t.tap(key('create-another'));
      await t.pump();
      expect(key('create-report'), findsOneWidget);
      expect(text('1 selected'), findsOneWidget);
    });
  });

  group('inside the shell', () {
    testWidgets('decisions made on the Review page are there when the Report tab comes back', (t) async {
      final s = await services(t, mini);
      await open(t, s, home: const AppShell(initialTab: 2));
      expect(key('fallback-notice'), findsOneWidget);
      await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Review')));
      await settle(t, 60);
      final id = s.recording.events().firstWhere((e) => e.source == EventSource.auto).id;
      await t.runAsync(() => s.reviews.setStatus(id, ReviewStatus.confirmed));
      await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Report')));
      await settle(t, 60);
      expect(key('fallback-notice'), findsNothing, reason: 'something is confirmed now');
      expect(text('1 selected'), findsOneWidget);
    });

    testWidgets('a hand-made choice is not overwritten when the tab comes back', (t) async {
      final s = await services(t, mini);
      await open(t, s, home: const AppShell(initialTab: 2));
      await t.tap(key('preset-markers'));
      await t.pump();
      await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Review')));
      await settle(t, 60);
      await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Report')));
      await settle(t, 60);
      expect(text('1 selected'), findsOneWidget);
      expect(t.widget<Material>(find.descendant(of: key('preset-markers'), matching: find.byType(Material)).first).color, AppColors.accentSoft);
    });

    testWidgets('the tab keeps the phone upright', (t) async {
      final s = await services(t, mini);
      await open(t, s, home: const AppShell(initialTab: 2));
      expect(find.byType(NavigationBar), findsOneWidget);
    });
  });
}
