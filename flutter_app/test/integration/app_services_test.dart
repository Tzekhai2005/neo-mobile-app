// End-to-end: neo-fake -> AppServices (auto-connect, live buffer, status, export) and the old screen.
// Needs `neo-fake` on PATH and UDP 5000 / TCP 5001 free; not part of CI.
// Run the integration tests ONE AT A TIME (they share the ports):
//   flutter test --concurrency=1 test/integration
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/app/app_scope.dart';
import 'package:neo_companion/app/app_services.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/device/device_status.dart';
import 'package:neo_companion/report/report_exporter.dart';
import 'package:neo_companion/ui/home/home_page.dart';
import 'package:neo_companion/ui/theme/app_theme.dart';

Future<bool> _until(bool Function() cond, Duration limit) async {
  final end = DateTime.now().add(limit);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return cond();
}

class FakeSharer implements FileSharer {
  int calls = 0;
  @override
  Future<void> share(List<File> files, {String? subject}) async => calls++;
}

void main() {
  final exe = Platform.environment['NEO_FAKE'] ?? 'neo-fake';
  final available = Process.runSync('which', [exe]).exitCode == 0;
  const skip = 'neo-fake not on PATH';

  test('start() alone connects; live data flows; reconnects by itself; export does not disturb the stream', () async {
    final fake = await Process.start(exe, ['--name', 'neo-app']);
    fake.stdout.drain<void>();
    fake.stderr.drain<void>();
    final tmp = Directory.systemTemp.createTempSync('neo_app_it_');
    final sharer = FakeSharer();
    final app = AppServices(dataDir: tmp, reader: DirectoryDatasetReader('test/fixtures/mini_recording'), sharer: sharer);
    try {
      await app.start();
      await app.start(); // twice is harmless

      // 1. no manual connect anywhere: the owner found the device and connected
      expect(await _until(() => app.status.value.link == LinkState.connected && app.status.value.batteryPct != null,
          const Duration(seconds: 10)), isTrue);
      expect(app.status.value.name, 'neo-app');
      expect(await _until(() => app.live.eegSamplesReceived >= 500, const Duration(seconds: 8)), isTrue);
      expect(app.live.channels, 2);
      expect(app.live.eegSamplesLost, 0);

      // 2. exporting a report while streaming must not stall or gap the live data
      final lostBefore = app.live.eegSamplesLost;
      var worstGapMs = 0;
      var last = DateTime.now();
      final probe = Timer.periodic(const Duration(milliseconds: 20), (_) {
        final now = DateTime.now();
        worstGapMs = worstGapMs > now.difference(last).inMilliseconds ? worstGapMs : now.difference(last).inMilliseconds;
        last = now;
      });
      final out = await app.exportReport(share: true);
      probe.cancel();
      // ignore: avoid_print
      print('export while streaming: longest pause of the UI isolate ${worstGapMs} ms, '
          'pdf ${(out.pdf.lengthSync() / 1024).round()} KB, ${out.csvFileCount} csv files');
      expect(out.pdf.existsSync() && out.csvZip.existsSync(), isTrue);
      expect(sharer.calls, 1);
      expect(app.status.value.link, LinkState.connected, reason: 'the link never stalled during the export');
      expect(app.live.eegSamplesLost, lostBefore, reason: 'no packets were lost while exporting');
      expect(worstGapMs, lessThan(800), reason: 'the UI isolate stayed responsive');

      // 3. pause the device: the owner notices, drops, and reconnects by itself on resume
      Process.killPid(fake.pid, ProcessSignal.sigstop);
      expect(await _until(() => app.status.value.link == LinkState.searching, const Duration(seconds: 7)), isTrue);
      Process.killPid(fake.pid, ProcessSignal.sigcont);
      expect(await _until(() => app.status.value.link == LinkState.connected, const Duration(seconds: 8)), isTrue);
      expect(await _until(() => app.live.latestEegIndex >= 250, const Duration(seconds: 6)), isTrue);
      expect(app.live.latestEegIndex, lessThan(2000), reason: 'the live buffer restarted at index 0');
      expect(app.live.eegSamplesLost, 0);
    } finally {
      Process.killPid(fake.pid, ProcessSignal.sigcont);
      await app.dispose();
      fake.kill();
      tmp.deleteSync(recursive: true);
    }
  }, skip: available ? false : skip, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('the start page shows the real connection and the real battery from the shared owner', (tester) async {
    await tester.runAsync(() async {
      final fake = await Process.start(exe, ['--name', 'neo-screen']);
      fake.stdout.drain<void>();
      fake.stderr.drain<void>();
      final tmp = Directory.systemTemp.createTempSync('neo_screen_it_');
      final app = AppServices(dataDir: tmp, reader: DirectoryDatasetReader('test/fixtures/mini_recording'), sharer: FakeSharer());
      try {
        await app.start();
        await tester.pumpWidget(AppScope(services: app, child: MaterialApp(theme: buildAppTheme(), home: const HomePage())));
        expect(find.text('Searching for the device'), findsOneWidget);

        expect(await _until(() => app.status.value.link == LinkState.connected && app.status.value.batteryPct != null,
            const Duration(seconds: 10)), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
        expect(find.text('Connected \u00b7 neo-screen \u00b7 87 %'), findsOneWidget,
            reason: 'the device pill shows the real name and the real STATUS battery');
        expect(find.text('Streaming'), findsOneWidget, reason: 'the live card follows the real link');

        await tester.pumpWidget(const SizedBox()); // the page goes away; the owner keeps going
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(app.status.value.link, LinkState.connected, reason: 'closing the page did not drop the connection');
      } finally {
        Process.killPid(fake.pid, ProcessSignal.sigcont);
        await app.dispose();
        fake.kill();
        tmp.deleteSync(recursive: true);
      }
    });
  }, skip: !available, timeout: const Timeout(Duration(seconds: 90)));
}
