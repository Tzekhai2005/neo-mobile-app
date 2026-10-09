import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/app/app_scope.dart';
import 'package:neo_companion/app/app_services.dart';
import 'package:neo_companion/data/dataset_library.dart';
import 'package:neo_companion/data/dataset_picker.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/data/review_event.dart';
import 'package:neo_companion/device/device_status.dart';
import 'package:neo_companion/protocol/neo_client.dart';
import 'package:neo_companion/report/report_exporter.dart';
import 'package:neo_companion/ui/shell/app_shell.dart';
import 'package:neo_companion/ui/shell/tab_scope.dart';
import 'package:neo_companion/ui/widgets/destination_tile.dart';
import 'package:neo_companion/ui/theme/app_theme.dart';
import 'package:neo_companion/ui/widgets/brand_logo.dart';
import 'package:neo_companion/ui/widgets/device_pill.dart';

import 'helpers/test_fonts.dart';

const mini = 'test/fixtures/mini_recording';

class _NoShare implements FileSharer {
  @override
  Future<void> share(List<File> files, {String? subject}) async {}
}

class _Picker implements DatasetPicker {
  File? result;
  @override
  Future<File?> pickZip() async => result;
}

const _connected = DeviceStatus(
  link: LinkState.connected,
  name: 'Neo-4F2A',
  serial: 'A0B1C2D3E4F5',
  firmware: '0.1.0',
  eegChannels: 2,
  eegRateHz: 250,
  batteryPct: 48,
  batteryMv: 3720,
  rssiDbm: -52,
  leadOff: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadTestFonts);
  late Directory dir;
  late _Picker picker;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('neo_home_');
    picker = _Picker();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<AppServices> services(WidgetTester t, {bool storage = true, bool bundledDemo = false}) async {
    final s = AppServices(
      client: NeoClient(),
      dataDir: storage ? dir : null,
      reader: bundledDemo ? null : DirectoryDatasetReader(mini),
      sharer: _NoShare(),
      picker: picker,
    );
    addTearDown(s.dispose);
    // The recording is read from disk in real time; the page then finds it loaded.
    if (storage) await t.runAsync(s.loadReview);
    return s;
  }

  /// Futures begun outside the test's fake clock need real time to finish, one
  /// step at a time, and a busy spinner never lets pumpAndSettle settle. So give
  /// real time and pump in small steps until the spinner is gone.
  Future<void> settle(WidgetTester t, [int ms = 80]) async {
    await t.pump();
    final steps = ms;
    for (var i = 0; i < steps; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 4)));
      await t.pump(const Duration(milliseconds: 20));
      if (i >= steps ~/ 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await t.pumpAndSettle();
  }

  Future<void> openHome(WidgetTester t, AppServices s) async {
    t.view.physicalSize = const Size(780, 1600);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(AppScope(
      services: s,
      child: MaterialApp(theme: buildAppTheme(), home: const AppShell()),
    ));
    await settle(t);
  }

  Finder tile(String label) => find.descendant(of: find.byType(DestinationTile), matching: find.text(label));

  Future<void> navTo(WidgetTester t, String label) async {
    await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
    await settle(t);
  }

  group('start page', () {
    testWidgets('shows the logo, the live card, the two other pages and the recording', (t) async {
      final s = await services(t);
      await openHome(t, s);
      expect(find.byType(BrandLogo), findsOneWidget);
      expect(find.text('Live data'), findsOneWidget);
      expect(find.byType(DestinationTile), findsNWidgets(2));
      expect(tile('History'), findsOneWidget);
      expect(tile('Reports'), findsOneWidget);
      expect(find.text('PDF and CSV'), findsOneWidget);
      expect(find.textContaining('Research prototype, not a medical device'), findsOneWidget);
      final events = s.reviewEvents().length;
      expect(find.text('$events events \u00b7 0 reviewed'), findsOneWidget);
      expect(find.textContaining('Demo recording'), findsOneWidget);
      expect(find.textContaining('synthetic'), findsWidgets);
    });

    testWidgets('while searching it says what to do, and the live card waits', (t) async {
      final s = await services(t);
      await openHome(t, s);
      expect(find.text('Searching for the device'), findsOneWidget);
      expect(find.textContaining('same Wi-Fi'), findsOneWidget);
      expect(find.text('Waiting for the device'), findsOneWidget);
    });

    testWidgets('a connected device shows in one line, and the live card says streaming', (t) async {
      final s = await services(t);
      s.status.value = _connected;
      await openHome(t, s);
      expect(find.text('Connected \u00b7 Neo-4F2A \u00b7 48 %'), findsOneWidget);
      expect(find.text('Streaming'), findsOneWidget);
      expect(find.text('Serial'), findsNothing, reason: 'details open only when the pill is tapped');
    });

    testWidgets('the pill shows only what the device has reported', (t) async {
      expect(DevicePill.summary(const DeviceStatus()), 'Searching for the device');
      expect(DevicePill.summary(const DeviceStatus(link: LinkState.connecting, name: 'Neo-4F2A')),
          'Connecting \u00b7 Neo-4F2A');
      expect(DevicePill.summary(_connected), 'Connected \u00b7 Neo-4F2A \u00b7 48 %');
      expect(DevicePill.summary(const DeviceStatus(link: LinkState.stalled, name: 'Neo-4F2A', batteryPct: 0)),
          'No data \u00b7 Neo-4F2A \u00b7 0 %');
    });

    testWidgets('no data is said plainly', (t) async {
      final s = await services(t);
      s.status.value = _connected;
      await openHome(t, s);
      s.status.value = const DeviceStatus(link: LinkState.stalled, name: 'Neo-4F2A');
      await t.pump();
      expect(find.text('No data'), findsWidgets);
    });

    testWidgets('tapping the pill opens the details, with a dash for what is unknown', (t) async {
      final s = await services(t);
      s.status.value = const DeviceStatus(
        link: LinkState.connected,
        name: 'Neo-4F2A',
        serial: 'A0B1C2D3E4F5',
        firmware: '0.1.0',
        batteryPct: 48,
        batteryMv: 3720,
        leadOff: false,
      );
      await openHome(t, s);
      await t.tap(find.textContaining('Connected \u00b7'));
      await t.pumpAndSettle();
      expect(find.text('A0B1C2D3E4F5'), findsOneWidget);
      expect(find.text('0.1.0'), findsOneWidget);
      expect(find.text('Good'), findsOneWidget);
      expect(find.text('3720 mV'), findsOneWidget);
      expect(find.text('Wi-Fi signal'), findsOneWidget);
      expect(find.text('Lost on Wi-Fi'), findsOneWidget);
      expect(find.text('Lost on the device'), findsOneWidget);
      expect(find.text('–'), findsWidgets, reason: 'Wi-Fi, recording, and the loss figures are unknown');
    });

    testWidgets('the details follow the device while open, and show a warning', (t) async {
      final s = await services(t);
      s.status.value = _connected;
      await openHome(t, s);
      await t.tap(find.textContaining('Connected \u00b7'));
      await t.pumpAndSettle();
      expect(find.text('Last warning'), findsNothing);
      s.status.value = DeviceStatus(link: LinkState.connected, name: 'Neo-4F2A', lastIssue: 'Low battery');
      await t.pump();
      expect(find.text('Low battery'), findsOneWidget);
    });

    testWidgets('the live card opens the Live tab, and the tiles open History and Reports', (t) async {
      final s = await services(t);
      await openHome(t, s);
      expect(tester(t).selectedTab, ShellTab.home);
      await t.tap(find.text('Live data'));
      await settle(t);
      expect(tester(t).selectedTab, ShellTab.live);
      await navTo(t, 'Home');
      await t.tap(tile('Reports'));
      await settle(t);
      expect(tester(t).selectedTab, ShellTab.reports);
      await navTo(t, 'Home');
      await t.tap(tile('History'));
      await settle(t);
      expect(tester(t).selectedTab, ShellTab.history);
    });
  });

  group('the shell', () {
    testWidgets('the app opens on Home, with the tabs below and no device strip', (t) async {
      final s = await services(t);
      s.status.value = _connected;
      await openHome(t, s);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(tester(t).selectedTab, ShellTab.home);
      expect(find.byType(BrandLogo), findsOneWidget);
      expect(find.text('Contact'), findsNothing, reason: 'Home has its own device card');
    });

    testWidgets('the four tabs are Home, Live, History and Reports', (t) async {
      final s = await services(t);
      await openHome(t, s);
      for (final label in ['Home', 'Live', 'History', 'Reports']) {
        expect(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)), findsOneWidget);
      }
    });

    testWidgets('a tile opens its tab, with the strip above', (t) async {
      final s = await services(t);
      s.status.value = _connected;
      await openHome(t, s);
      await t.tap(tile('Reports'));
      await settle(t);
      expect(tester(t).selectedTab, ShellTab.reports);
      expect(find.text('Neo-4F2A'), findsOneWidget, reason: 'the strip names the device');
      expect(find.text('Contact'), findsOneWidget);
      expect(find.byKey(const ValueKey('create-report')), findsOneWidget, reason: 'the Reports page');
    });

    testWidgets('the tabs switch pages, and Home comes back with its state', (t) async {
      final s = await services(t);
      await openHome(t, s);
      await navTo(t, 'Live');
      expect(tester(t).selectedTab, ShellTab.live);
      await navTo(t, 'History');
      expect(tester(t).selectedTab, ShellTab.history);
      await navTo(t, 'Home');
      expect(find.byType(BrandLogo), findsOneWidget);
      expect(find.textContaining('Demo recording'), findsOneWidget);
    });

    testWidgets('the strip shows the device state, and electrode contact in its own colour', (t) async {
      final s = await services(t);
      s.status.value = _connected;
      await openHome(t, s);
      await navTo(t, 'Live');
      Color contactDot() {
        final probe = find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Electrode contact');
        final box = t.widget<Container>(find.descendant(of: probe, matching: find.byType(Container)));
        return (box.decoration! as BoxDecoration).color!;
      }

      expect(contactDot(), AppColors.success, reason: 'good contact is green');
      s.status.value = DeviceStatus(link: LinkState.connected, name: 'Neo-4F2A', leadOff: true);
      await t.pump();
      expect(contactDot(), AppColors.warning, reason: 'a lead-off is amber');
    });
  });

  group('without a usable recording', () {
    testWidgets('no app storage is explained, and nothing crashes', (t) async {
      final s = await services(t, storage: false);
      await openHome(t, s);
      expect(find.text("Recordings aren't available on this device"), findsOneWidget);
      expect(find.text('Unavailable'), findsOneWidget);
    });
  });

  group('the recordings sheet', () {
    Future<void> openSheet(WidgetTester t) async {
      await t.tap(find.textContaining('Demo recording'));
      await settle(t);
    }

    Map<String, List<int>> miniFiles() => {
          for (final f in DatasetLibrary.requiredFiles) f: File('$mini/$f').readAsBytesSync(),
        };

    File zipOf(String name, Map<String, List<int>> entries) {
      final a = Archive();
      entries.forEach((n, b) => a.add(ArchiveFile.bytes(n, b)));
      return File('${dir.path}/$name')..writeAsBytesSync(ZipEncoder().encodeBytes(a));
    }

    testWidgets('lists the built-in demo as the one in use', (t) async {
      final s = await services(t);
      await openHome(t, s);
      await openSheet(t);
      expect(find.text('Recordings'), findsOneWidget);
      expect(find.text('Built in · synthetic demonstration data'), findsOneWidget);
      expect(find.text('Import a recording zip'), findsOneWidget);
      expect(find.textContaining('never mixes them up'), findsOneWidget);
    });

    testWidgets('imports a zip, switches to it, and the start page follows', (t) async {
      final s = await services(t);
      picker.result = zipOf('carer-night.zip', miniFiles());
      await openHome(t, s);
      await openSheet(t);
      await t.tap(find.text('Import a recording zip'));
      await settle(t, 400);
      expect(find.text('carer-night'), findsOneWidget);
      expect(s.currentDataset, 'carer-night');
      await t.tapAt(const Offset(10, 10)); // close the sheet
      await settle(t);
      expect(find.textContaining('carer-night'), findsOneWidget, reason: 'the chip names it');
    });

    testWidgets('a file that is not a recording gets a plain explanation, and nothing changes', (t) async {
      final s = await services(t);
      picker.result = File('${dir.path}/notes.zip')..writeAsStringSync('this is not a zip');
      await openHome(t, s);
      await openSheet(t);
      await t.tap(find.text('Import a recording zip'));
      await settle(t, 300);
      expect(find.text('This is not a valid zip file.'), findsOneWidget);
      expect(s.currentDataset, isNull);
    });

    testWidgets('cancelling the chooser changes nothing and shows no error', (t) async {
      final s = await services(t);
      picker.result = null;
      await openHome(t, s);
      await openSheet(t);
      await t.tap(find.text('Import a recording zip'));
      await settle(t, 200);
      expect(find.textContaining('went wrong'), findsNothing);
      expect(find.textContaining('valid zip'), findsNothing);
    });

    testWidgets('removing asks first, and the demo comes back if it was in use', (t) async {
      final s = await services(t);
      picker.result = zipOf('carer-night.zip', miniFiles());
      await openHome(t, s);
      await openSheet(t);
      await t.tap(find.text('Import a recording zip'));
      await settle(t, 400);
      await t.tap(find.text('Remove'));
      await t.pumpAndSettle();
      expect(find.text('Remove carer-night?'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(find.text('carer-night'), findsOneWidget, reason: 'cancel keeps it');

      await t.tap(find.text('Remove'));
      await t.pumpAndSettle();
      await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Remove')));
      await settle(t, 400);
      expect(find.text('carer-night'), findsNothing);
      expect(s.currentDataset, isNull);
    });

    testWidgets('review decisions are kept for each recording when switching away and back', (t) async {
      final s = await services(t);
      picker.result = zipOf('first.zip', miniFiles());
      await openHome(t, s);
      await openSheet(t);
      await t.tap(find.text('Import a recording zip'));
      await settle(t, 400);
      final id = s.recording.events().first.id;
      await t.runAsync(() => s.reviews.setStatus(id, ReviewStatus.confirmed));

      picker.result = zipOf('second.zip', miniFiles());
      await t.tap(find.text('Import a recording zip'));
      await settle(t, 400);
      expect(s.currentDataset, 'second');

      await t.tap(find.text('first'));
      await settle(t, 400);
      expect(s.currentDataset, 'first');
      expect(s.reviewEvents().firstWhere((e) => e.event.id == id).status, ReviewStatus.confirmed,
          reason: 'its decision was kept');
    });
  });
}

/// Which tab of the open shell is selected.
_ShellProbe tester(WidgetTester t) => _ShellProbe(t);

class _ShellProbe {
  final WidgetTester t;
  _ShellProbe(this.t);
  int get selectedTab => t.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;
}
