// End-to-end: neo-fake -> NeoClient -> DeviceStatusTracker, driven by neo-fake's cues.
// Needs `neo-fake` on PATH and UDP 5000 / TCP 5001 free; not part of CI.
// Run the integration tests ONE AT A TIME (they share the ports):
//   flutter test --concurrency=1 test/integration
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/device/device_status.dart';
import 'package:neo_companion/protocol/neo_client.dart';
import 'package:neo_companion/protocol/neo_messages.dart';

Future<bool> _until(bool Function() cond, Duration limit) async {
  final end = DateTime.now().add(limit);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return cond();
}

void main() {
  final exe = Platform.environment['NEO_FAKE'] ?? 'neo-fake';
  final available = Process.runSync('which', [exe]).exitCode == 0;

  test('the tracker shows what a real stream reports, and follows the cues', () async {
    final fake = await Process.start(exe, ['--name', 'neo-status']);
    fake.stdout.drain<void>();
    fake.stderr.drain<void>();
    final client = NeoClient();
    final tracker = DeviceStatusTracker(client);
    StreamSubscription<NeoDeviceInfo>? autoConnect;
    Future<void> cue(String line) async {
      fake.stdin.writeln(line);
      await fake.stdin.flush();
    }

    DeviceStatus s() => tracker.value;
    try {
      expect(s().link, LinkState.searching);
      await client.startDiscovery();
      autoConnect = client.onDeviceDiscovered.listen((d) => client.connectAndStart(d));

      // 1. connected, with identity and a first STATUS (they arrive once a second)
      expect(await _until(() => s().link == LinkState.connected && s().batteryPct != null, const Duration(seconds: 10)), isTrue);
      // ignore: avoid_print
      print('name ${s().name}, serial ${s().serial}, fw ${s().firmware}, ch ${s().eegChannels}, '
          'eeg ${s().eegRateHz} Hz, imu ${s().imuRateHz} Hz, battery ${s().batteryPct} % ${s().batteryMv} mV, '
          'charging ${s().charging}, wifi ${s().wifiConnected}, rssi ${s().rssiDbm}, state ${s().deviceState}, '
          'sent ${s().pktsSent}, dropped ${s().pktsDropped}, overruns ${s().eegOverruns}');
      expect(s().name, 'neo-status');
      expect(s().serial, isNotEmpty);
      expect(s().firmware, matches(RegExp(r'^\d+\.\d+\.\d+$')));
      expect(s().eegChannels, 2);
      expect(s().eegRateHz, 250);
      expect(s().imuRateHz, 100);
      expect(s().batteryPct, inInclusiveRange(1, 100));
      expect(s().batteryMv, inInclusiveRange(3000, 4400));
      expect(s().statusAt, isNotNull);
      expect(s().connectedAt, isNotNull);
      expect(s().lowBattery, isFalse);
      expect(s().buttonPresses, 0);
      expect(s().leadOff, isFalse);

      // 2. the device button
      await cue('button');
      expect(await _until(() => s().buttonPresses == 1, const Duration(seconds: 4)), isTrue);
      expect(s().recentEvents.any((e) => e.kind == NeoEventKind.button), isTrue);

      // 3. electrodes off, then back on
      await cue('loff');
      expect(await _until(() => s().leadOff == true, const Duration(seconds: 4)), isTrue);
      await cue('loff off');
      expect(await _until(() => s().leadOff == false, const Duration(seconds: 4)), isTrue);

      // 4. low battery
      await cue('lowbat');
      expect(await _until(() => s().lowBattery && s().lastIssue != null, const Duration(seconds: 5)), isTrue);
      // ignore: avoid_print
      print('after lowbat: ${s().batteryPct} %, issue "${s().lastIssue}"');
      expect(s().batteryPct, lessThanOrEqualTo(DeviceStatus.lowBatteryPercent));
      expect(s().lastIssue, startsWith('Battery low'));

      // 5. pause the device: stalled, then dropped (last known values stay), then a fresh connection
      Process.killPid(fake.pid, ProcessSignal.sigstop);
      expect(await _until(() => s().link == LinkState.stalled, const Duration(seconds: 3)), isTrue);
      expect(await _until(() => s().link == LinkState.searching, const Duration(seconds: 6)), isTrue);
      expect(s().name, 'neo-status', reason: 'last known identity stays');
      expect(s().batteryPct, isNotNull, reason: 'last known battery stays');
      expect(s().leadOff, isNull);
      Process.killPid(fake.pid, ProcessSignal.sigcont);
      expect(await _until(() => s().link == LinkState.connected, const Duration(seconds: 8)), isTrue);
      expect(s().buttonPresses, 0, reason: 'a new connection starts the counters over');
      expect(s().lastIssue, isNull);
    } finally {
      await autoConnect?.cancel();
      Process.killPid(fake.pid, ProcessSignal.sigcont);
      tracker.dispose();
      client.dispose();
      fake.kill();
    }
  }, skip: available ? false : 'neo-fake not on PATH', timeout: const Timeout(Duration(seconds: 90)));
}
