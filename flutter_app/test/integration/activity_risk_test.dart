// End-to-end: neo-fake -> AppServices -> the experimental activity-risk readout.
// Needs `neo-fake` on PATH and UDP 5000 / TCP 5001 free; not part of CI.
// Run the integration tests ONE AT A TIME (they share the ports):
//   flutter test --concurrency=1 test/integration
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/app/app_services.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/device/device_status.dart';
import 'package:neo_companion/live/activity_risk.dart';

Future<bool> _until(bool Function() cond, Duration limit) async {
  final end = DateTime.now().add(limit);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return cond();
}

void main() {
  final exe = Platform.environment['NEO_FAKE'] ?? 'neo-fake';
  final available = Process.runSync('which', [exe]).exitCode == 0;
  const skip = 'neo-fake not on PATH';

  test('learns the wearer, stays low in ordinary wear, rises for a real change, holds for movement, and goes quiet without contact',
      () async {
    final fake = await Process.start(exe, ['--name', 'neo-risk']);
    fake.stdout.drain<void>();
    fake.stderr.drain<void>();
    final tmp = Directory.systemTemp.createTempSync('neo_risk_it_');
    final app = AppServices(dataDir: tmp, reader: DirectoryDatasetReader('test/fixtures/mini_recording'));
    final risk = app.activityRisk!;
    final seen = <ActivityRisk>[];
    risk.addListener(() => seen.add(risk.value));
    Future<void> cue(String c) async {
      fake.stdin.writeln(c);
      await fake.stdin.flush();
    }

    try {
      await app.start();
      expect(await _until(() => app.status.value.link == LinkState.connected, const Duration(seconds: 10)), isTrue);
      expect(risk.value.state, anyOf(RiskState.noData, RiskState.calibrating));

      // 1. it needs about 20 s of the wearer's own signal before it shows a number
      expect(await _until(() => risk.value.state == RiskState.calibrating, const Duration(seconds: 6)), isTrue);
      expect(risk.value.percent, isNull);
      expect(await _until(() => risk.value.state == RiskState.ok, const Duration(seconds: 40)), isTrue,
          reason: 'it should have a number after the baseline is learned');

      // 2. ordinary wear: low, and it moves a little
      seen.clear();
      await Future<void>.delayed(const Duration(seconds: 14));
      final calm = [for (final r in seen) if (r.state == RiskState.ok) r.percent!];
      // ignore: avoid_print
      print('ordinary wear: ${calm.length} readings, ${calm.reduce((a, b) => a < b ? a : b).toStringAsFixed(1)} to '
          '${calm.reduce((a, b) => a > b ? a : b).toStringAsFixed(1)} %');
      expect(calm.length, greaterThan(8));
      expect(calm.reduce((a, b) => a > b ? a : b), lessThan(25), reason: 'ordinary wear must not look like an event');

      // 3. a real change in the signal (a jaw clench, a burst of muscle activity) raises it
      seen.clear();
      for (var i = 0; i < 6; i++) {
        await cue('clench');
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }
      final burst = [for (final r in seen) if (r.percent != null) r.percent!];
      final peak = burst.reduce((a, b) => a > b ? a : b);
      // ignore: avoid_print
      print('after repeated clenches: peak ${peak.toStringAsFixed(1)} %');
      expect(peak, greaterThan(40), reason: 'a sustained change in the signal must show');
      expect(peak, lessThanOrEqualTo(98));

      // 4. it settles back once the signal does
      expect(await _until(() => risk.value.percent != null && risk.value.percent! < 25, const Duration(seconds: 20)), isTrue);

      // 5. a head nod is movement: the number is held down and the state says so
      seen.clear();
      for (var i = 0; i < 4; i++) {
        await cue('nod');
        await Future<void>.delayed(const Duration(milliseconds: 1000));
      }
      // ignore: avoid_print
      print('during nods: states ${seen.map((r) => r.state.name).toSet()}');
      expect(seen.any((r) => r.state == RiskState.movement), isTrue);

      // 6. an electrode off the skin shows no number, with its own reason
      await cue('loff');
      expect(await _until(() => risk.value.state == RiskState.noContact, const Duration(seconds: 8)), isTrue);
      expect(risk.value.percent, isNull);
      await cue('loff off');
      expect(await _until(() => risk.value.state != RiskState.noContact, const Duration(seconds: 8)), isTrue);
    } finally {
      await app.dispose();
      fake.kill();
      await fake.exitCode;
      tmp.deleteSync(recursive: true);
    }
  }, skip: available ? false : skip, timeout: const Timeout(Duration(minutes: 3)));
}
