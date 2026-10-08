// End-to-end: neo-fake -> NeoClient -> LiveFeed -> LiveSignalBuffer.
// Needs `neo-fake` on PATH and UDP 5000 / TCP 5001 free; not part of CI.
// Run the integration tests ONE AT A TIME (they share the ports):
//   flutter test --concurrency=1 test/integration
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/live/live_feed.dart';
import 'package:neo_companion/live/live_signal_buffer.dart';
import 'package:neo_companion/protocol/neo_client.dart';

Future<bool> _until(bool Function() cond, Duration limit) async {
  final end = DateTime.now().add(limit);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return cond();
}

int _nan(List<double> x) => x.where((v) => v.isNaN).length;

void main() {
  final exe = Platform.environment['NEO_FAKE'] ?? 'neo-fake';
  final available = Process.runSync('which', [exe]).exitCode == 0;

  test('live buffer fills from a real stream, shows real packet loss, resets on reconnect', () async {
    final fake = await Process.start(exe, ['--name', 'neo-live']);
    fake.stdout.drain<void>();
    fake.stderr.drain<void>();
    final client = NeoClient();
    final buffer = LiveSignalBuffer();
    final feed = LiveFeed(client, buffer);
    StreamSubscription<NeoDeviceInfo>? autoConnect;
    try {
      await client.startDiscovery();
      final dev = await client.onDeviceDiscovered.first.timeout(const Duration(seconds: 6));
      expect(await client.connectAndStart(dev), isTrue);

      // 1. a clean stream: wait for 2.6 s worth of samples, however long the machine takes
      expect(await _until(() => buffer.eegSamplesReceived >= 650, const Duration(seconds: 10)), isTrue);
      var s = buffer.snapshot(seconds: 2);
      // ignore: avoid_print
      print('channels ${buffer.channels}, eeg ${s.eeg[0].length}, imu ${s.accelX.length}, '
          'rates ${s.eegRateHz}/${s.imuRateHz}, imuRecv ${buffer.imuSamplesReceived}');
      expect(buffer.channels, 2);
      expect(s.eegRateHz, 250);
      expect(s.imuRateHz, 100);
      expect(s.eeg.length, 2);
      expect(s.eeg[0].length, 500);
      expect(_nan(s.eeg[0]), 0, reason: 'no gaps on a clean stream');
      expect(buffer.eegSamplesLost, 0);
      final peak = s.eeg[0].map((v) => v.abs()).reduce(math.max);
      // ignore: avoid_print
      print('EEG peak ${peak.toStringAsFixed(1)} µV');
      expect(peak, inInclusiveRange(1, 1000), reason: 'plausible µV, so the INFO scale was applied');
      final finiteAccel = s.accelZ.where((v) => !v.isNaN).length;
      expect(finiteAccel, greaterThan(150), reason: 'IMU arrives in bursts; the last ~0.1 s may be pending');
      expect(buffer.imuSamplesLost, 0);
      final mag = [
        for (var i = 0; i < s.accelX.length; i++)
          if (!s.accelX[i].isNaN) math.sqrt(s.accelX[i] * s.accelX[i] + s.accelY[i] * s.accelY[i] + s.accelZ[i] * s.accelZ[i])
      ];
      final meanMag = mag.reduce((a, b) => a + b) / mag.length;
      // ignore: avoid_print
      print('mean |accel| ${meanMag.toStringAsFixed(3)} g');
      expect(meanMag, inInclusiveRange(0.5, 1.5), reason: 'gravity, so the IMU scale was applied');

      // 2. real packet loss: neo-fake skips the next 6 data packets
      fake.stdin.writeln('drop 6');
      await fake.stdin.flush();
      expect(await _until(() => buffer.eegSamplesLost > 0, const Duration(seconds: 6)), isTrue,
          reason: 'neo-fake must have dropped packets');
      await Future<void>.delayed(const Duration(milliseconds: 600)); // let the rest of the drop land
      final lost = buffer.eegSamplesLost;
      s = buffer.snapshot(seconds: 3);
      // ignore: avoid_print
      print('after drop 6: EEG lost $lost samples, IMU lost ${buffer.imuSamplesLost}, NaN in window ${_nan(s.eeg[0])}');
      expect(lost, greaterThan(0));
      expect(lost % 10, 0, reason: 'whole 10-sample EEG packets');
      expect(_nan(s.eeg[0]), lost, reason: 'every lost sample is a visible gap');
      expect(_nan(s.eeg[1]), lost);
      // neo-fake spends a seq number on every dropped packet, so this is link loss and not device loss
      expect(client.linkPacketsLost, 6, reason: 'seq gap = the 6 dropped packets');
      expect(buffer.eegSamplesLostLink, lost);
      expect(buffer.eegSamplesLostDevice, 0);

      // 3. pause the device until the client drops, then resume: the buffer starts over
      autoConnect = client.onDeviceDiscovered.listen((d) => client.connectAndStart(d));
      Process.killPid(fake.pid, ProcessSignal.sigstop);
      expect(await _until(() => client.state == NeoConnState.searching, const Duration(seconds: 6)), isTrue);
      Process.killPid(fake.pid, ProcessSignal.sigcont);
      expect(await _until(() => client.state == NeoConnState.connected, const Duration(seconds: 8)), isTrue);
      // the check below reads a 1 s window (250 samples), so wait until the restarted stream has filled it
      expect(await _until(() => buffer.latestEegIndex >= 300, const Duration(seconds: 8)), isTrue);
      // ignore: avoid_print
      print('after reconnect: latest index ${buffer.latestEegIndex}, lost ${buffer.eegSamplesLost}');
      expect(buffer.latestEegIndex, lessThan(1000), reason: 'the index restarted at 0');
      expect(buffer.latestEegIndex, greaterThan(100));
      expect(buffer.eegSamplesLost, 0);
      expect(_nan(buffer.snapshot(seconds: 1).eeg[0]), 0);
    } finally {
      await autoConnect?.cancel();
      Process.killPid(fake.pid, ProcessSignal.sigcont);
      await feed.dispose();
      client.dispose();
      fake.kill();
    }
  }, skip: available ? false : 'neo-fake not on PATH', timeout: const Timeout(Duration(seconds: 90)));
}
