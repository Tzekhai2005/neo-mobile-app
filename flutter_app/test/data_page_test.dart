import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/app/app_scope.dart';
import 'package:neo_companion/app/app_services.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/device/device_status.dart';
import 'package:neo_companion/live/activity_risk.dart';
import 'package:neo_companion/protocol/neo_client.dart';
import 'package:neo_companion/protocol/neo_messages.dart';
import 'package:neo_companion/report/report_exporter.dart';
import 'package:neo_companion/ui/data/data_controls.dart';
import 'package:neo_companion/ui/data/data_page.dart';
import 'package:neo_companion/ui/orientation.dart' as orientation;
import 'package:neo_companion/ui/shell/app_shell.dart';
import 'package:neo_companion/ui/widgets/brand_logo.dart';
import 'package:neo_companion/ui/shell/tab_scope.dart';
import 'package:neo_companion/ui/theme/app_theme.dart';
import 'package:neo_companion/ui/trace/signal_lanes.dart';

import 'helpers/test_fonts.dart';

class _NoShare implements FileSharer {
  @override
  Future<void> share(List<File> files, {String? subject}) async {}
}

NeoEegPacket eeg(int idx, int n) => NeoEegPacket(
      NeoHeader(sampleIdx: idx),
      2,
      1,
      [for (var k = 0; k < n; k++) NeoEegSample(0, [200000 + ((idx + k) % 100) * 10, ((idx + k) % 70) * 8])],
    );

const connected = DeviceStatus(link: LinkState.connected, name: 'Neo-4F2A', batteryPct: 48, leadOff: false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadTestFonts);

  late Directory dir;
  late List<List<DeviceOrientation>> orientations;
  final saved = orientation.setPreferredOrientations;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('neo_data_');
    orientations = [];
    orientation.setPreferredOrientations = (o) async => orientations.add(o);
  });
  tearDown(() {
    orientation.setPreferredOrientations = saved;
    dir.deleteSync(recursive: true);
  });

  AppServices services() {
    final s = AppServices(
      client: NeoClient(),
      dataDir: dir,
      reader: DirectoryDatasetReader('test/fixtures/mini_recording'),
      sharer: _NoShare(),
    );
    addTearDown(s.dispose);
    return s;
  }

  var nextIdx = 0;
  setUp(() => nextIdx = 0);

  /// [seconds] more signal, continuing where the last call stopped (the default is
  /// enough to fill a 10 second view and leave room to look back).
  void stream(AppServices s, {double seconds = 40}) {
    final total = nextIdx + (seconds * 250).round();
    for (; nextIdx < total; nextIdx += 10) {
      s.live.pushEeg(eeg(nextIdx, 10));
    }
  }

  Future<void> show(WidgetTester t, AppServices s, {Size size = const Size(390, 800), Widget? home}) async {
    t.view.physicalSize = size * 2;
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(AppScope(
      services: s,
      child: MaterialApp(theme: buildAppTheme(), home: home ?? const Scaffold(body: DataPage())),
    ));
    await t.pump(const Duration(milliseconds: 200));
  }

  SignalLanes lanes(WidgetTester t) => t.widget<SignalLanes>(find.byType(SignalLanes));

  group('before there is anything to draw', () {
    testWidgets('says what it is waiting for', (t) async {
      final s = services();
      await show(t, s);
      expect(find.text('Waiting for the device'), findsOneWidget);
      expect(find.byType(SignalLanes), findsNothing);
      s.status.value = const DeviceStatus(link: LinkState.connecting);
      await t.pump();
      expect(find.text('Connecting'), findsOneWidget);
      s.status.value = connected;
      await t.pump();
      expect(find.text('Waiting for the first data'), findsOneWidget);
      s.status.value = const DeviceStatus(link: LinkState.stalled);
      await t.pump();
      expect(find.text('No data'), findsOneWidget);
    });

    testWidgets('the controls and the button are still there', (t) async {
      final s = services();
      await show(t, s);
      expect(find.byKey(const ValueKey('scale')), findsOneWidget);
      expect(find.byKey(const ValueKey('seizure-now')), findsOneWidget);
    });
  });

  group('with a live signal', () {
    testWidgets('draws two EEG lanes and the two motion lanes', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await show(t, s);
      expect(lanes(t).data.lanes.map((l) => l.label), ['Ch1', 'Ch2', 'Accel', 'Gyro']);
      expect(lanes(t).data.durationSec, closeTo(10, 0.01));
    });

    testWidgets('a 200 000 µV electrode offset does not push the trace off its lane', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await show(t, s);
      // the lane still carries the offset in the data; it is the drawing that removes it
      expect(lanes(t).data.lanes.first.removeBaseline, isTrue);
    });

    testWidgets('the window can be 5, 10 or 15 seconds', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await show(t, s);
      for (final w in [5, 15, 10]) {
        await t.tap(find.byKey(ValueKey('window-$w')));
        await t.pump();
        expect(lanes(t).data.durationSec, closeTo(w.toDouble(), 0.01), reason: '$w s');
      }
    });

    testWidgets('tapping the scale steps it round: 100, 200, 500, 1000, then 25', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await show(t, s);
      final seen = <String>[];
      String label() => (t.widget<PillButton>(find.byKey(const ValueKey('scale')))).label;
      seen.add(label());
      for (var i = 0; i < 4; i++) {
        await t.tap(find.byKey(const ValueKey('scale')));
        await t.pump();
        seen.add(label());
      }
      expect(seen, ['±100 µV', '±200 µV', '±500 µV', '±1000 µV', '±25 µV']);
      expect(lanes(t).data.lanes.first.scale, 25);
    });

    testWidgets('the motion lanes are open, and can be closed and opened', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await show(t, s);
      expect(lanes(t).data.lanes.length, 4);
      await t.tap(find.byKey(const ValueKey('motion')));
      await t.pump();
      expect(lanes(t).data.lanes.length, 2);
      await t.tap(find.byKey(const ValueKey('motion')));
      await t.pump();
      expect(lanes(t).data.lanes.length, 4);
    });

    testWidgets('keeps up with new data while live', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await show(t, s);
      final before = lanes(t).data;
      stream(s, seconds: 1);
      await t.pump(const Duration(milliseconds: 200));
      expect(identical(lanes(t).data, before), isFalse);
    });
  });

  group('pause', () {
    testWidgets('freezes the view, says so, and resumes', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await show(t, s);
      await t.tap(find.byKey(const ValueKey('pause')));
      await t.pump();
      expect(find.byTooltip('Resume the live view'), findsOneWidget);
      expect(find.byKey(const ValueKey('paused-badge')), findsOneWidget);
      expect(lanes(t).data.ticks.last.label, 'paused');

      final frozen = lanes(t).data;
      stream(s, seconds: 3);
      await t.pump(const Duration(milliseconds: 300));
      expect(identical(lanes(t).data, frozen), isTrue);

      await t.tap(find.byKey(const ValueKey('pause')));
      await t.pump();
      expect(find.byTooltip('Freeze the view'), findsOneWidget);
      expect(find.byKey(const ValueKey('paused-badge')), findsNothing);
      expect(lanes(t).data.ticks.last.label, 'now');
    });

    testWidgets('a paused view can be dragged back in time, and the labels follow', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await show(t, s);
      await t.tap(find.byKey(const ValueKey('pause')));
      await t.pump();
      expect(find.textContaining('drag to look back'), findsOneWidget);
      final box = t.getRect(find.byType(SignalLanes));
      await t.dragFrom(Offset(box.left + 60, box.top + 40), const Offset(150, 0));
      await t.pump();
      expect(lanes(t).data.ticks.last.label, startsWith('−'), reason: 'no longer the moment of pausing');
      // dragging left again comes forward
      await t.dragFrom(Offset(box.left + 200, box.top + 40), const Offset(-400, 0));
      await t.pump();
      expect(lanes(t).data.ticks.last.label, 'paused');
    });

    testWidgets('a live view is not dragged anywhere', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await show(t, s);
      final box = t.getRect(find.byType(SignalLanes));
      await t.dragFrom(Offset(box.left + 60, box.top + 40), const Offset(150, 0));
      await t.pump();
      expect(lanes(t).data.ticks.last.label, 'now');
    });
  });

  group('"Seizure now"', () {
    testWidgets('with no signal it says so and marks nothing', (t) async {
      final s = services();
      await show(t, s);
      await t.tap(find.byKey(const ValueKey('seizure-now')));
      await t.pump();
      expect(find.textContaining('nothing to mark'), findsOneWidget);
      expect(s.seizureMarkers.count, 0);
    });

    testWidgets('with a signal it marks the moment, says when, and draws the line', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await show(t, s);
      await t.tap(find.byKey(const ValueKey('seizure-now')));
      await t.pump(const Duration(milliseconds: 200));
      expect(s.seizureMarkers.count, 1);
      expect(find.textContaining('Marked at'), findsOneWidget);
      expect(lanes(t).data.markers.map((m) => m.label), ['Seizure now']);
    });

    testWidgets('markers stay when the page is left and come back to', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await show(t, s);
      await t.tap(find.byKey(const ValueKey('seizure-now')));
      await t.pump();
      await t.pumpWidget(const SizedBox()); // the page is gone
      expect(s.seizureMarkers.count, 1);
      await show(t, s);
      expect(lanes(t).data.markers.map((m) => m.label), ['Seizure now']);
    });

    testWidgets('a device button press is drawn as "button"', (t) async {
      final s = services();
      stream(s);
      s.status.value = DeviceStatus(link: LinkState.connected, leadOff: false, recentEvents: [
        DeviceEventRecord(
          eventId: NeoEventKind.button.id,
          kind: NeoEventKind.button,
          arg: 0,
          sampleIdx: s.live.latestEegIndex - 400,
          at: DateTime(2026),
        ),
      ]);
      await show(t, s);
      expect(lanes(t).data.markers.map((m) => m.label), ['button']);
    });
  });

  group('the experimental readout', () {
    testWidgets('is a card with its number and its small print', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      s.activityRisk!.value = const ActivityRisk(27.4, RiskState.ok);
      await show(t, s);
      expect(find.byKey(const ValueKey('risk-card')), findsOneWidget);
      expect(find.text('27 %'), findsOneWidget);
      expect(find.text('Experimental, not a diagnosis'), findsOneWidget);
    });

    testWidgets('says why when it has no number', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await show(t, s);
      final r = s.activityRisk!;
      for (final (state, text) in [
        (RiskState.calibrating, 'Learning your normal signal…'),
        (RiskState.noContact, 'Check the electrodes'),
        (RiskState.noData, 'Waiting for data'),
      ]) {
        r.value = ActivityRisk(null, state);
        await t.pump();
        expect(find.text(text), findsOneWidget, reason: '$state');
        expect(find.text('–'), findsOneWidget);
      }
      r.value = const ActivityRisk(9, RiskState.movement);
      await t.pump();
      expect(find.text('Moving, so the number is held down'), findsOneWidget);
    });

    testWidgets('follows the monitor as it changes', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await show(t, s);
      s.activityRisk!.value = const ActivityRisk(12, RiskState.ok);
      await t.pump();
      expect(find.text('12 %'), findsOneWidget);
      s.activityRisk!.value = const ActivityRisk(64, RiskState.ok);
      await t.pump();
      expect(find.text('64 %'), findsOneWidget);
    });
  });

  group('expanding a lane', () {
    testWidgets('tapping a lane shows it alone, turns the phone to landscape, and the cross brings it back', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await show(t, s);
      final box = t.getRect(find.byType(SignalLanes));
      await t.tapAt(Offset(box.left + 80, box.top + 40)); // the first lane
      await t.pump();
      expect(find.byKey(const ValueKey('collapse')), findsOneWidget);
      expect(lanes(t).data.lanes.single.label, 'Ch1');
      expect(orientations.last, [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);

      await t.tap(find.byKey(const ValueKey('collapse')));
      await t.pump();
      expect(find.byKey(const ValueKey('collapse')), findsNothing);
      expect(lanes(t).data.lanes.length, 4);
      expect(orientations.last, DeviceOrientation.values);
    });

    testWidgets('an EEG lane has scale steps that stop at the ends; a motion lane has none', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await show(t, s);
      var box = t.getRect(find.byType(SignalLanes));
      await t.tapAt(Offset(box.left + 80, box.top + 40));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('scale-up')));
      await t.pump();
      expect(lanes(t).data.lanes.single.scale, 200);
      for (var i = 0; i < 6; i++) {
        await t.tap(find.byKey(const ValueKey('scale-down')));
        await t.pump();
      }
      expect(lanes(t).data.lanes.single.scale, 25);

      await t.tap(find.byKey(const ValueKey('collapse')));
      await t.pump();
      box = t.getRect(find.byType(SignalLanes));
      await t.tapAt(Offset(box.left + 80, box.bottom - 40)); // the gyro lane
      await t.pump();
      expect(lanes(t).data.lanes.single.label, 'Gyro');
      expect(find.byKey(const ValueKey('scale-up')), findsNothing);
    });

    testWidgets('Seizure now is still there in an expanded lane', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await show(t, s);
      final box = t.getRect(find.byType(SignalLanes));
      await t.tapAt(Offset(box.left + 80, box.top + 40));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('seizure-now')));
      await t.pump();
      expect(s.seizureMarkers.count, 1);
    });
  });

  group('landscape', () {
    const wide = Size(800, 390);

    testWidgets('gives the lanes the width, with the controls in a bar and the readout beside them', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      s.activityRisk!.value = const ActivityRisk(18, RiskState.ok);
      await show(t, s, size: wide);
      expect(find.byKey(const ValueKey('risk-panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('risk-card')), findsNothing);
      expect(find.text('18 %'), findsOneWidget);
      expect(lanes(t).data.lanes.length, 4, reason: 'every channel at once');
      final lanesBox = t.getRect(find.byType(SignalLanes));
      final panel = t.getRect(find.byKey(const ValueKey('risk-panel')));
      expect(lanesBox.right, lessThanOrEqualTo(panel.left), reason: 'the readout never covers a trace');
      expect(find.byKey(const ValueKey('seizure-now')), findsOneWidget);
    });

    testWidgets('has its own way home, because the strip is hidden', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await show(t, s, size: wide);
      expect(find.byTooltip('Home'), findsOneWidget);
    });
  });

  group('inside the shell', () {
    Future<void> openShell(WidgetTester t, AppServices s, {Size size = const Size(390, 800), int tab = ShellTab.live}) async {
      t.view.physicalSize = size * 2;
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(AppScope(
        services: s,
        child: MaterialApp(theme: buildAppTheme(), home: AppShell(initialTab: tab)),
      ));
      await t.pump(const Duration(milliseconds: 200));
    }

    testWidgets('the Live tab is the real page, and may be turned any way', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await openShell(t, s);
      expect(find.byType(DataPage), findsOneWidget);
      expect(orientations.last, DeviceOrientation.values);
    });

    testWidgets('the other tabs keep the phone upright', (t) async {
      final s = services();
      await openShell(t, s, tab: ShellTab.history);
      expect(orientations.last, [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
      await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Live')));
      await t.pump();
      expect(orientations.last, DeviceOrientation.values);
      await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Reports')));
      await t.pump();
      expect(orientations.last, [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    });

    testWidgets('in landscape on the Live tab the strip and the tabs give way to the lanes', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await openShell(t, s, size: const Size(800, 390));
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Contact'), findsNothing, reason: 'the device strip is hidden');
      expect(find.byType(SignalLanes), findsOneWidget);
    });

    testWidgets('the landscape home button goes to Home, upright', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await openShell(t, s, size: const Size(800, 390));
      await t.tap(find.byTooltip('Home'));
      await t.pump(const Duration(milliseconds: 200));
      expect(orientations.last, [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
      expect(find.byType(DataPage, skipOffstage: false), findsOneWidget, reason: 'kept alive behind Home');
      expect(find.byType(BrandLogo), findsOneWidget);
    });

    testWidgets('portrait shows the strip and the tabs as before', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await openShell(t, s);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('Contact'), findsOneWidget);
    });

    testWidgets('leaving the shell puts the phone back upright', (t) async {
      final s = services();
      await openShell(t, s);
      await t.pumpWidget(const SizedBox());
      expect(orientations.last, [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    });

    testWidgets('a page that is not on top does no work, and catches up when shown again', (t) async {
      final s = services();
      s.status.value = connected;
      stream(s);
      await openShell(t, s);
      SignalLanes anyLanes() => t.widget<SignalLanes>(find.byType(SignalLanes, skipOffstage: false));
      final before = anyLanes().data;
      await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('History')));
      await t.pump();
      stream(s, seconds: 2);
      await t.pump(const Duration(milliseconds: 600)); // many ticks' worth of time
      expect(identical(anyLanes().data, before), isTrue, reason: 'hidden, so not redrawn');
      await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Live')));
      await t.pump(); // the page learns it is shown again during this frame
      await t.pump(const Duration(milliseconds: 300));
      expect(identical(anyLanes().data, before), isFalse, reason: 'shown again, so it caught up');
    });
  });
}
