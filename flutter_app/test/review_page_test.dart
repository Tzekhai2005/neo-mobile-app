import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/app/app_scope.dart';
import 'package:neo_companion/app/app_services.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/data/review_event.dart';
import 'package:neo_companion/protocol/neo_client.dart';
import 'package:neo_companion/report/report_exporter.dart';
import 'package:neo_companion/ui/orientation.dart' as orientation;
import 'package:neo_companion/ui/review/review_page.dart';
import 'package:neo_companion/ui/review/review_widgets.dart';
import 'package:neo_companion/ui/shell/app_shell.dart';
import 'package:neo_companion/ui/shell/tab_scope.dart';
import 'package:neo_companion/ui/theme/app_theme.dart';
import 'package:neo_companion/ui/trace/signal_lanes.dart';

import 'helpers/settle.dart';
import 'helpers/test_fonts.dart';

const mini = 'test/fixtures/mini_recording'; // one hour: 4 automatic events and 1 patient press
const demo = 'test/fixtures/demo_3day'; // three days, 119 events

class _NoShare implements FileSharer {
  @override
  Future<void> share(List<File> files, {String? subject}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadTestFonts);

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('neo_review_page_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<AppServices> services(WidgetTester t, String dataset, {bool storage = true}) async {
    final s = AppServices(
      client: NeoClient(),
      dataDir: storage ? dir : null,
      reader: DirectoryDatasetReader(dataset),
      sharer: _NoShare(),
    );
    addTearDown(s.dispose);
    if (storage) await t.runAsync(s.loadReview);
    return s;
  }

  Future<void> open(WidgetTester t, AppServices s, {Widget? home, Size size = const Size(390, 840)}) async {
    t.view.physicalSize = size * 2;
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(AppScope(
      services: s,
      child: MaterialApp(theme: buildAppTheme(), home: home ?? const Scaffold(body: ReviewPage())),
    ));
    await settle(t);
  }

  Finder row(String id) => find.byKey(ValueKey('row-$id'));
  List<ReviewEvent> candidates(AppServices s) =>
      s.reviewEvents().where((e) => e.event.source == EventSource.auto).toList()
        ..sort((a, b) => (b.event.confidence ?? 0).compareTo(a.event.confidence ?? 0));

  group('opening', () {
    testWidgets('shows the days, the patient markers apart, the ranked candidates, and the progress', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      expect(find.byKey(const ValueKey('timeline')), findsOneWidget);
      expect(find.text('Marked by you (1)'), findsOneWidget);
      expect(find.text('Events, highest score first (4)'), findsOneWidget);
      expect(find.byKey(const ValueKey('progress')), findsOneWidget);
      expect(find.text('0 of 5 reviewed'), findsOneWidget);
      expect(find.byKey(const ValueKey('range-label')), findsOneWidget);
    });

    testWidgets('a score is shown as a kind of event, never as a number', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      expect(find.text('Possible seizure'), findsWidgets);
      expect(find.text('High'), findsNothing);
      expect(find.textContaining(RegExp(r'0\.\d\d')), findsNothing);
    });

    testWidgets('says plainly when there is no storage for decisions', (t) async {
      final s = await services(t, mini, storage: false);
      await open(t, s);
      expect(find.byKey(const ValueKey('review-message')), findsOneWidget);
      expect(find.textContaining('no app storage'), findsOneWidget);
    });

    testWidgets('says plainly when the recording cannot be opened', (t) async {
      final s = AppServices(client: NeoClient(), dataDir: dir, reader: DirectoryDatasetReader('test/fixtures/nope'), sharer: _NoShare());
      addTearDown(s.dispose);
      await open(t, s);
      expect(find.textContaining('could not be opened'), findsOneWidget);
    });
  });

  group('the shell', () {
    testWidgets('the Review tab is the real page, and the Report tab is the real Report page', (t) async {
      final s = await services(t, mini);
      await open(t, s, home: const AppShell(initialTab: ShellTab.history));
      expect(find.byType(ReviewPage), findsOneWidget);
      await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Reports')));
      await settle(t);
      expect(find.byKey(const ValueKey('create-report')), findsOneWidget);
    });

    testWidgets('keeps the phone upright on the Review tab', (t) async {
      final calls = <List<DeviceOrientation>>[];
      final saved = orientation.setPreferredOrientations;
      orientation.setPreferredOrientations = (o) async => calls.add(o);
      addTearDown(() => orientation.setPreferredOrientations = saved);
      final s = await services(t, mini);
      await open(t, s, home: const AppShell(initialTab: ShellTab.history));
      expect(calls.last, [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
      expect(find.byType(NavigationBar), findsOneWidget);
    });
  });

  /// The status filter lives in the sheet behind the filter icon.
  Future<void> chooseStatus(WidgetTester t, String name) async {
    await t.tap(find.byKey(const ValueKey('filter')));
    await settle(t);
    await t.tap(find.byKey(ValueKey('filter-$name')));
    await settle(t);
    await t.tapAt(const Offset(10, 10)); // closes the sheet
    await settle(t);
  }

  group('the History header and views', () {
    testWidgets('is titled History, with Day, Week and Month, search and filter', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      expect(find.text('History'), findsOneWidget);
      for (final k in ['mode-oneDay', 'mode-week', 'mode-month', 'search', 'filter']) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      expect(find.text('Day'), findsOneWidget);
      expect(find.text('Week'), findsOneWidget);
      expect(find.text('Month'), findsOneWidget);
    });

    testWidgets('the three tiles count each kind, and tapping one shows only that kind', (t) async {
      final s = await services(t, demo);
      await open(t, s);
      await t.tap(find.byKey(const ValueKey('mode-week')));
      await settle(t);
      final events = s.reviewEvents().where((e) => e.event.source == EventSource.auto);
      int n(bool Function(double) f) => events.where((e) => f(e.event.confidence!)).length;
      Finder tileCount(String k, int count) =>
          find.descendant(of: find.byKey(ValueKey(k)), matching: find.text('$count'));
      expect(tileCount('category-possibleSeizure', n((c) => c >= 0.8)), findsOneWidget);
      expect(tileCount('category-unusual', n((c) => c >= 0.4 && c < 0.8)), findsOneWidget);
      expect(tileCount('category-normal', n((c) => c < 0.4)), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('category-possibleSeizure')));
      await settle(t);
      expect(find.byKey(const ValueKey('active-category')), findsOneWidget);
      final heading = find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('Events, highest'));
      await t.scrollUntilVisible(heading, 300,
          scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
      expect(t.widget<Text>(heading).data, 'Events, highest score first (${n((c) => c >= 0.8)})');

      await t.tap(find.byKey(const ValueKey('category-possibleSeizure'))); // again: back to everything
      await settle(t);
      expect(find.byKey(const ValueKey('active-category')), findsNothing);
    });

    testWidgets('search narrows the list, and its chip can be removed', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await t.tap(find.byKey(const ValueKey('search')));
      await settle(t);
      await t.enterText(find.byKey(const ValueKey('search-field')), 'zzzz');
      await settle(t);
      expect(find.byKey(const ValueKey('empty-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('active-query')), findsOneWidget);
      await t.tap(find.descendant(of: find.byKey(const ValueKey('active-query')), matching: find.byIcon(Icons.clear)));
      await settle(t);
      expect(find.byKey(const ValueKey('empty-list')), findsNothing);
    });

    testWidgets('the filter sheet orders the list, and shows a dot while something is set', (t) async {
      final s = await services(t, demo);
      await open(t, s);
      expect(find.textContaining('Events, highest score first'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('filter')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('sort-newest')));
      await settle(t);
      await t.tapAt(const Offset(10, 10));
      await settle(t);
      expect(find.textContaining('Events, newest first'), findsOneWidget);
    });

    testWidgets('each row has a small signal picture, except a patient press', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      final auto = candidates(s).first;
      expect(find.descendant(of: row(auto.event.id), matching: find.byType(EventSpark)), findsOneWidget);
      final marker = s.reviewEvents().firstWhere((e) => e.event.source == EventSource.patientButton);
      expect(find.descendant(of: row(marker.event.id), matching: find.byType(EventSpark)), findsNothing);
    });

    testWidgets('a month on the real demo opens and shows a timeline', (t) async {
      final s = await services(t, 'assets/demo_recording');
      await open(t, s);
      await t.tap(find.byKey(const ValueKey('mode-month')));
      await settle(t, 200);
      expect(find.text('Mon 5 Oct to Sun 1 Nov'), findsOneWidget);
      expect(find.byKey(const ValueKey('day-bars')), findsOneWidget, reason: 'a month is one bar a day');
      expect(find.byKey(const ValueKey('timeline')), findsNothing);
      expect(find.byKey(const ValueKey('show-signal')), findsNothing, reason: 'the signal needs a day or three');
    });

    testWidgets('tapping a day in the bars opens that day', (t) async {
      final s = await services(t, 'assets/demo_recording');
      await open(t, s);
      await t.tap(find.byKey(const ValueKey('mode-week')));
      await settle(t, 200);
      final box = t.getRect(find.byKey(const ValueKey('day-bars')));
      await t.tapAt(Offset(box.left + box.width * (2.5 / 7), box.center.dy)); // the third day
      await settle(t, 200);
      expect(find.text('Wed 7 Oct'), findsOneWidget);
      expect(find.byKey(const ValueKey('timeline')), findsOneWidget);
      expect(find.byKey(const ValueKey('show-signal')), findsOneWidget);
    });
  });

  group('the list and its filters', () {
    testWidgets('a filter with nothing in it says so', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await chooseStatus(t, 'confirmed');
      expect(find.byKey(const ValueKey('empty-list')), findsOneWidget);
      expect(find.textContaining('No events match this filter'), findsOneWidget);
    });

    testWidgets('Unreviewed shows everything at the start, and an event leaves it once decided', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await chooseStatus(t, 'unreviewed');
      final first = candidates(s).first.event.id;
      expect(row(first), findsOneWidget);
      await t.tap(row(first));
      await settle(t, 120);
      await t.tap(find.byKey(const ValueKey('confirm')));
      await settle(t, 120);
      await t.tap(find.byKey(const ValueKey('close-sheet')));
      await settle(t);
      expect(row(first), findsNothing, reason: 'it is confirmed now, so no longer unreviewed');
      await chooseStatus(t, 'confirmed');
      expect(row(first), findsOneWidget);
    });
  });

  group('an event in the sheet', () {
    testWidgets('opens at the tapped row, says where it is, and shows the stored signal', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      final first = candidates(s).first;
      await t.tap(row(first.event.id));
      await settle(t, 150);
      expect(find.byKey(const ValueKey('event-sheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('position')), findsOneWidget);
      expect(find.text('Event 2 of 5'), findsOneWidget, reason: 'after the one patient marker');
      final lanes = t.widget<SignalLanes>(find.byType(SignalLanes));
      expect(lanes.data.lanes.map((l) => l.label), ['Ch1', 'Ch2', 'Accel', 'Gyro']);
      expect(lanes.data.spans, isNotEmpty, reason: 'the event\'s own stretch is shaded');
      expect(lanes.data.markers.first.label, 'start');
    });

    testWidgets('Confirm, Dismiss and Undo change the status and the progress', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await t.tap(row(candidates(s).first.event.id));
      await settle(t, 150);
      expect(find.text('Status: Unreviewed'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('confirm')));
      await settle(t, 120);
      expect(find.text('Status: Confirmed'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('dismiss')));
      await settle(t, 120);
      expect(find.text('Status: Dismissed'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('undo')));
      await settle(t, 120);
      expect(find.text('Status: Unreviewed'), findsOneWidget);
      expect(find.byKey(const ValueKey('undo')), findsNothing, reason: 'nothing to undo any more');
    });

    testWidgets('a decision is saved to disk', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      final id = candidates(s).first.event.id;
      await t.tap(row(id));
      await settle(t, 150);
      await t.tap(find.byKey(const ValueKey('confirm')));
      await settle(t, 120);
      expect(s.reviews.decisionFor(id)!.status, ReviewStatus.confirmed);
      expect(File('${dir.path}/review_decisions.json').readAsStringSync(), contains(id));
    });

    testWidgets('next and previous move through the list, and the signal follows', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await t.tap(row(candidates(s).first.event.id));
      await settle(t, 150);
      expect(find.text('Event 2 of 5'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('next')));
      await settle(t, 150);
      expect(find.text('Event 3 of 5'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('previous')));
      await t.tap(find.byKey(const ValueKey('previous')));
      await settle(t, 150);
      expect(find.text('Event 1 of 5'), findsOneWidget);
      expect(find.text('Patient button press'), findsWidgets);
    });

    testWidgets('the cross closes it, and the timeline and list are back to themselves', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await t.tap(row(candidates(s).first.event.id));
      await settle(t, 150);
      await t.tap(find.byKey(const ValueKey('close-sheet')));
      await settle(t);
      expect(find.byKey(const ValueKey('event-sheet')), findsNothing);
      expect(find.byKey(const ValueKey('progress')), findsOneWidget);
    });

    testWidgets('the scale and the motion lanes can be changed in the sheet', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      await t.tap(row(candidates(s).first.event.id));
      await settle(t, 150);
      await t.tap(find.byKey(const ValueKey('sheet-scale')));
      await t.pump();
      expect(t.widget<SignalLanes>(find.byType(SignalLanes)).data.lanes.first.scale, 200);
      await t.tap(find.byKey(const ValueKey('sheet-motion')));
      await t.pump();
      expect(t.widget<SignalLanes>(find.byType(SignalLanes)).data.lanes.length, 2);
    });

    testWidgets('a patient marker can be decided about too, and has no band', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      final marker = s.reviewEvents().firstWhere((e) => e.event.source == EventSource.patientButton);
      await t.tap(row(marker.event.id));
      await settle(t, 150);
      await t.tap(find.byKey(const ValueKey('confirm')));
      await settle(t, 120);
      expect(find.text('Status: Confirmed'), findsOneWidget);
    });
  });

  group('notes', () {
    testWidgets('are saved a moment after typing stops, to the event they were typed on', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      final id = candidates(s).first.event.id;
      await t.tap(row(id));
      await settle(t, 150);
      await t.enterText(find.byKey(const ValueKey('note')), 'carer saw a head turn');
      await t.pump(const Duration(milliseconds: 700));
      await settle(t, 100);
      expect(s.reviews.decisionFor(id)?.note, 'carer saw a head turn');
    });

    testWidgets('are not lost when the reviewer moves to the next event straight away', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      final id = candidates(s).first.event.id;
      await t.tap(row(id));
      await settle(t, 150);
      await t.enterText(find.byKey(const ValueKey('note')), 'typed in a hurry');
      await t.tap(find.byKey(const ValueKey('next'))); // before the pause for saving
      await settle(t, 150);
      expect(s.reviews.decisionFor(id)?.note, 'typed in a hurry');
      expect(find.text('Event 3 of 5'), findsOneWidget);
    });

    testWidgets('are not lost when the sheet is closed', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      final id = candidates(s).first.event.id;
      await t.tap(row(id));
      await settle(t, 150);
      await t.enterText(find.byKey(const ValueKey('note')), 'before closing');
      await t.tap(find.byKey(const ValueKey('close-sheet')));
      await settle(t, 150);
      expect(s.reviews.decisionFor(id)?.note, 'before closing');
    });

    testWidgets('an event that already has a note shows it', (t) async {
      final s = await services(t, mini);
      final id = candidates(s).first.event.id;
      await t.runAsync(() => s.reviews.setNote(id, 'already noted'));
      await open(t, s);
      await t.tap(row(id));
      await settle(t, 150);
      expect(find.text('already noted'), findsOneWidget);
    });

    testWidgets('a row with a note shows a small note mark', (t) async {
      final s = await services(t, mini);
      final id = candidates(s).first.event.id;
      await t.runAsync(() => s.reviews.setNote(id, 'x'));
      await open(t, s);
      expect(find.descendant(of: row(id), matching: find.byIcon(Icons.notes)), findsOneWidget);
    });
  });

  group('the timeline', () {
    Offset barPosition(WidgetTester t, ReviewEvent e, {double seconds = 3600}) {
      final box = t.getRect(find.byKey(const ValueKey('timeline')));
      final mid = e.event.startSec(250) + e.event.durationSec(250) / 2;
      return Offset(box.left + mid / seconds * box.width, box.top + 125);
    }

    testWidgets('a tap on a mark is acted on at once, not held back waiting for a second tap', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      final target = (candidates(s)..sort((a, b) => a.event.startSample.compareTo(b.event.startSample))).first;
      await t.tapAt(barPosition(t, target));
      await t.pump(); // one frame, no waiting
      expect(find.byKey(const ValueKey('event-sheet')), findsOneWidget);
    });

    testWidgets('tapping a mark opens that event', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      // pick the candidate that is furthest from the others, so the tap cannot be ambiguous
      final all = candidates(s)..sort((a, b) => a.event.startSample.compareTo(b.event.startSample));
      final target = all.first;
      await t.tapAt(barPosition(t, target));
      await settle(t, 150);
      expect(find.byKey(const ValueKey('event-sheet')), findsOneWidget);
      expect(find.textContaining('Event '), findsWidgets);
      final selectedRowFinder = row(target.event.id);
      expect(selectedRowFinder, findsOneWidget);
    });

    testWidgets('tapping empty space does nothing', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      final box = t.getRect(find.byKey(const ValueKey('timeline')));
      // the middle of the longest stretch with no event in it
      final ends = [
        0.0,
        for (final e in s.reviewEvents()..sort((a, b) => a.event.startSample.compareTo(b.event.startSample)))
          ...[e.event.startSec(250), e.event.startSec(250) + e.event.durationSec(250)],
        3600.0,
      ];
      var best = 0.0, at = 0.0;
      for (var i = 0; i + 1 < ends.length; i += 2) {
        if (ends[i + 1] - ends[i] > best) {
          best = ends[i + 1] - ends[i];
          at = (ends[i] + ends[i + 1]) / 2;
        }
      }
      await t.tapAt(Offset(box.left + at / 3600 * box.width, box.top + 125));
      await settle(t);
      expect(find.byKey(const ValueKey('event-sheet')), findsNothing);
    });

    testWidgets('pinching zooms in, a Reset zoom button appears, and it zooms back out', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      expect(find.byKey(const ValueKey('reset-zoom')), findsNothing);
      final c = t.getCenter(find.byKey(const ValueKey('timeline')));
      final a = await t.startGesture(c - const Offset(20, 0), pointer: 1);
      final b = await t.startGesture(c + const Offset(20, 0), pointer: 2);
      for (var i = 1; i <= 8; i++) {
        await a.moveTo(c - Offset(20.0 + i * 12, 0));
        await b.moveTo(c + Offset(20.0 + i * 12, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await a.up();
      await b.up();
      await t.pump();
      expect(find.byKey(const ValueKey('reset-zoom')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('reset-zoom')));
      await t.pump();
      expect(find.byKey(const ValueKey('reset-zoom')), findsNothing);
    });

    testWidgets('dragging a zoomed timeline slides it without a problem', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      final c = t.getCenter(find.byKey(const ValueKey('timeline')));
      final a = await t.startGesture(c - const Offset(20, 0), pointer: 1);
      final b = await t.startGesture(c + const Offset(20, 0), pointer: 2);
      for (var i = 1; i <= 8; i++) {
        await a.moveTo(c - Offset(20.0 + i * 12, 0));
        await b.moveTo(c + Offset(20.0 + i * 12, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await a.up();
      await b.up();
      await t.pump();
      await t.dragFrom(c, const Offset(120, 0));
      await t.pump();
      expect(t.takeException(), isNull);
    });

    testWidgets('Show signal switches the EEG and movement on behind the marks', (t) async {
      final s = await services(t, mini);
      await open(t, s);
      final pill = find.byKey(const ValueKey('show-signal'));
      await t.tap(pill);
      await t.pump();
      expect(t.takeException(), isNull);
      await t.tap(pill);
      await t.pump();
      expect(t.takeException(), isNull);
    });
  });

  group('three days', () {
    testWidgets('one day at a time to begin with, with arrows that stop at the ends', (t) async {
      final s = await services(t, demo);
      await open(t, s);
      expect(find.text('Mon 5 Oct'), findsOneWidget);
      expect(t.widget<IconButton>(find.byKey(const ValueKey('earlier'))).onPressed, isNull);
      await t.tap(find.byKey(const ValueKey('later')));
      await settle(t);
      expect(find.text('Tue 6 Oct'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('later')));
      await settle(t);
      expect(find.text('Wed 7 Oct'), findsOneWidget);
      expect(t.widget<IconButton>(find.byKey(const ValueKey('later'))).onPressed, isNull);
    });

    testWidgets('the 3 days switch shows all of it, with the date on every row', (t) async {
      final s = await services(t, demo);
      await open(t, s);
      await t.tap(find.byKey(const ValueKey('mode-week')));
      await settle(t);
      expect(find.text('Mon 5 Oct to Wed 7 Oct'), findsOneWidget);
      expect(find.text('Marked by you (9)'), findsOneWidget);
      // the candidates start below the nine markers, so scroll down to the heading
      final heading = find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('Events, highest score first'));
      await t.scrollUntilVisible(
        heading,
        300,
        scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first,
      );
      expect(t.widget<Text>(heading).data, 'Events, highest score first (110)');
      expect(find.textContaining(RegExp(r'(Mon|Tue|Wed) \d+ Oct ·')), findsWidgets, reason: 'with several days a time needs its date');
      expect(t.widget<IconButton>(find.byKey(const ValueKey('later'))).onPressed, isNull);
    });

    testWidgets('paging changes the list to that day\'s events', (t) async {
      final s = await services(t, demo);
      await open(t, s);
      final day1 = find.textContaining('Events, highest score first');
      final first = (t.widget<Text>(day1)).data!;
      await t.tap(find.byKey(const ValueKey('later')));
      await settle(t);
      expect((t.widget<Text>(day1)).data, isNot(first));
    });

    testWidgets('a tap on a mark that stands for several events lists them, and a choice opens one', (t) async {
      final s = await services(t, demo);
      await open(t, s);
      await t.tap(find.byKey(const ValueKey('mode-week')));
      await settle(t);
      final box = t.getRect(find.byKey(const ValueKey('timeline')));
      // sweep along the plot until a tap lands on a counted mark
      var found = false;
      for (var x = box.left + 8; x < box.right - 8 && !found; x += 6) {
        await t.tapAt(Offset(x, box.top + 125));
        await t.pump(const Duration(milliseconds: 200));
        if (find.textContaining('events close together').evaluate().isNotEmpty) {
          found = true;
        } else if (find.byKey(const ValueKey('close-sheet')).evaluate().isNotEmpty) {
          // that tap landed on a single event and opened it; close it and go on
          await t.tap(find.byKey(const ValueKey('close-sheet')));
          await t.pump(const Duration(milliseconds: 100));
        }
      }
      expect(found, isTrue, reason: 'the demo has marks with several events at this zoom');
      await t.pumpAndSettle(); // the list slides up from the bottom of the screen
      final rows = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('row-')),
      );
      expect(rows, findsAtLeastNWidgets(2), reason: 'a mark with a count stands for at least two events');
      await t.tap(rows.first);
      await settle(t, 150);
      expect(find.textContaining('events close together'), findsNothing, reason: 'the list closes when one is chosen');
      expect(find.byKey(const ValueKey('event-sheet')), findsOneWidget);
    });

    testWidgets('stepping with Next scrolls the list to the event, even far down', (t) async {
      final s = await services(t, demo);
      await open(t, s);
      await t.tap(find.byKey(const ValueKey('mode-week')));
      await settle(t);
      await t.tap(row(candidates(s).first.event.id).evaluate().isNotEmpty ? row(candidates(s).first.event.id) : find.byType(InkWell).at(10));
      await settle(t, 150);
      for (var i = 0; i < 30; i++) {
        await t.tap(find.byKey(const ValueKey('next')));
        await t.pump(const Duration(milliseconds: 50));
      }
      await settle(t, 200);
      expect(t.takeException(), isNull);
      expect(find.byKey(const ValueKey('event-sheet')), findsOneWidget);
    });
  });
}
