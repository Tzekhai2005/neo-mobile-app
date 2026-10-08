import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/live/live_signal_buffer.dart';
import 'package:neo_companion/protocol/neo_messages.dart';

// Counts encode their own index so every assertion can say which sample it expects:
// EEG counts = idx * 10 + channel, scaled by 0.5 µV/count in these tests.
const uv = 0.5;
double eegValue(int idx, int ch) => (idx * 10 + ch) * uv;

NeoInfo info({int eegRate = 250, int imuRate = 100}) => NeoInfo(
      protoMajor: 0,
      protoMinor: 1,
      fwMajor: 0,
      fwMinor: 1,
      fwPatch: 0,
      hwRev: 0x0100,
      serial: 'X',
      name: 'test',
      role: 0,
      features: 31,
      eegRateHz: eegRate,
      eegChannels: 2,
      eegFormat: 1,
      eegGain: const [6, 6],
      eegVrefUv: 2420000,
      uvPerCount: const [uv, uv],
      imuRateHz: imuRate,
      imuGPerLsb: 0.001,
      imuDpsPerLsb: 0.1,
      podPresent: 0,
    );

NeoEegPacket eeg(int idx, int n, {int ch = 2, int loff = 0, int linkGap = 0}) => NeoEegPacket(
      NeoHeader(sampleIdx: idx, linkGap: linkGap),
      ch,
      1,
      [
        for (var k = 0; k < n; k++) NeoEegSample(loff, [for (var c = 0; c < ch; c++) (idx + k) * 10 + c])
      ],
    );

/// IMU packet whose first sample sits at EEG index `eegIdx`; sample k has IMU index
/// `imuStart + k`, encoded in ax (×0.001 g), ay (negated) and gx (×0.1 °/s).
NeoImuPacket imu(int eegIdx, int imuStart, {int n = 10, int linkGap = 0}) => NeoImuPacket(
      NeoHeader(sampleIdx: eegIdx, linkGap: linkGap),
      [for (var k = 0; k < n; k++) NeoImuSample((imuStart + k), -(imuStart + k), 1000, (imuStart + k) * 10, 0, 0)],
    );

LiveSignalBuffer fresh({int window = 30}) => LiveSignalBuffer(maxWindowSec: window)..configure(info());

void pushRange(LiveSignalBuffer b, int from, int to, {int per = 10, int ch = 2}) {
  for (var i = from; i < to; i += per) {
    b.pushEeg(eeg(i, per, ch: ch));
  }
}

void main() {
  group('link loss and device loss', () {
    test('a sample gap with a seq gap is link loss', () {
      final b = fresh();
      b.pushEeg(eeg(0, 10));
      b.pushEeg(eeg(30, 10, linkGap: 2)); // two 10-sample packets missing on the link
      expect(b.eegSamplesLostLink, 20);
      expect(b.eegSamplesLostDevice, 0);
      expect(b.eegSamplesLost, 20);
    });

    test('a sample gap with no seq gap is device loss', () {
      final b = fresh();
      b.pushEeg(eeg(0, 10));
      b.pushEeg(eeg(30, 10)); // seq contiguous, but the index jumped: the device never sent them
      expect(b.eegSamplesLostLink, 0);
      expect(b.eegSamplesLostDevice, 20);
    });

    test('a seq gap that covers only part of the sample gap leaves the rest as device loss', () {
      final b = fresh();
      b.pushEeg(eeg(0, 10));
      b.pushEeg(eeg(40, 10, linkGap: 1)); // 30 samples missing, one packet (10) lost on the link
      expect(b.eegSamplesLostLink, 10);
      expect(b.eegSamplesLostDevice, 20);
    });

    test('lost IMU or STATUS packets cannot make link loss exceed the gap', () {
      final b = fresh();
      b.pushEeg(eeg(0, 10));
      b.pushEeg(eeg(10, 10, linkGap: 5)); // five packets lost, but none of them EEG: no sample gap
      expect(b.eegSamplesLost, 0);
      expect(b.eegSamplesLostLink, 0);
    });

    test('a late packet is taken back from the link count first', () {
      final b = fresh();
      b.pushEeg(eeg(0, 10));
      b.pushEeg(eeg(40, 10, linkGap: 1)); // link 10, device 20
      b.pushEeg(eeg(10, 10)); // arrives late
      expect(b.eegSamplesLostLink, 0);
      expect(b.eegSamplesLostDevice, 20);
      b.pushEeg(eeg(20, 10));
      expect(b.eegSamplesLostDevice, 10);
      expect(b.eegSamplesLost, 10);
    });

    test('IMU loss is split the same way', () {
      final b = fresh();
      b.pushEeg(eeg(0, 10));
      b.pushImu(imu(0, 0));
      b.pushImu(imu(50, 20, linkGap: 1)); // IMU samples 10..19 missing, one packet lost
      expect(b.imuSamplesLostLink, 10);
      expect(b.imuSamplesLostDevice, 0);
      b.pushImu(imu(150, 60)); // 30 more missing, seq contiguous
      expect(b.imuSamplesLostDevice, 30);
    });

    test('a seq gap seen on a STATUS or IMU packet still explains the EEG gap after it', () {
      final b = fresh();
      b.pushEeg(eeg(0, 10));
      b.noteLinkGap(1); // the packet after the loss was a STATUS
      b.pushEeg(eeg(20, 10)); // contiguous seq, but 10 samples are missing
      expect(b.eegSamplesLostLink, 10);
      expect(b.eegSamplesLostDevice, 0);
      b.pushEeg(eeg(30, 10)); // the pending gap was used up
      b.pushEeg(eeg(50, 10));
      expect(b.eegSamplesLostDevice, 10);
    });

    test('an IMU packet\'s own gap also counts for the EEG that follows', () {
      final b = fresh();
      b.pushEeg(eeg(0, 10));
      b.pushImu(imu(0, 0, linkGap: 1));
      b.pushEeg(eeg(20, 10));
      expect(b.eegSamplesLostLink, 10);
    });

    test('reset clears both counters', () {
      final b = fresh();
      b.pushEeg(eeg(0, 10));
      b.pushEeg(eeg(40, 10, linkGap: 1));
      b.reset();
      expect(b.eegSamplesLostLink, 0);
      expect(b.eegSamplesLostDevice, 0);
    });
  });

  group('EEG', () {
    test('an empty buffer has an empty snapshot', () {
      final b = fresh();
      expect(b.hasData, isFalse);
      final s = b.snapshot();
      expect(s.isEmpty, isTrue);
      expect(s.endIdx, -1);
    });

    test('values come out in µV, in order, with NaN before the first sample', () {
      final b = fresh();
      pushRange(b, 0, 20);
      expect(b.channels, 2);
      expect(b.latestEegIndex, 19);
      final s = b.snapshot(seconds: 0.1); // 25 samples: 5 before the stream began
      expect(s.eeg[0].length, 25);
      expect(s.startIdx, -5);
      expect(s.endIdx, 19);
      for (var i = 0; i < 5; i++) {
        expect(s.eeg[0][i].isNaN, isTrue);
      }
      for (var idx = 0; idx < 20; idx++) {
        expect(s.eeg[0][idx + 5], eegValue(idx, 0));
        expect(s.eeg[1][idx + 5], eegValue(idx, 1));
      }
    });

    for (final n in [2, 3, 4]) {
      test('$n channels', () {
        final b = fresh();
        pushRange(b, 0, 50, ch: n);
        expect(b.channels, n);
        final s = b.snapshot(seconds: 0.2);
        expect(s.channels, n);
        expect(s.eeg[n - 1].last, eegValue(49, n - 1));
      });
    }

    test('a different channel count starts a new stream', () {
      final b = fresh();
      pushRange(b, 0, 100, ch: 2);
      expect(b.eegSamplesReceived, 100);
      pushRange(b, 0, 20, ch: 4);
      expect(b.channels, 4);
      expect(b.eegSamplesReceived, 20);
    });

    test('the ring drops the oldest data and clamps the window', () {
      final b = fresh(window: 2); // 500 samples
      pushRange(b, 0, 1000);
      final s = b.snapshot(seconds: 5); // clamped to 2 s
      expect(s.eeg[0].length, 500);
      expect(s.startIdx, 500);
      expect(s.eeg[0].first, eegValue(500, 0));
      expect(s.eeg[0].last, eegValue(999, 0));
      expect(s.eeg[0].any((v) => v.isNaN), isFalse);
    });

    test('lost samples leave a NaN gap and are counted', () {
      final b = fresh();
      pushRange(b, 0, 10);
      pushRange(b, 30, 40);
      expect(b.eegSamplesLost, 20);
      expect(b.eegSamplesReceived, 20);
      final s = b.snapshot(seconds: 0.16); // exactly idx 0..39
      expect(s.startIdx, 0);
      for (var idx = 0; idx < 40; idx++) {
        final inGap = idx >= 10 && idx < 30;
        expect(s.eeg[0][idx].isNaN, inGap, reason: 'idx $idx');
      }
    });

    test('a late packet fills the gap in place and the loss count drops back', () {
      final b = fresh();
      pushRange(b, 0, 10);
      pushRange(b, 20, 30);
      expect(b.eegSamplesLost, 10);
      pushRange(b, 10, 20); // arrives late
      expect(b.eegSamplesLost, 0);
      expect(b.eegSamplesReceived, 30);
      final s = b.snapshot(seconds: 0.12);
      expect(s.eeg[0].sublist(0, 30).any((v) => v.isNaN), isFalse);
      expect(s.eeg[0][15], eegValue(15, 0));
    });

    test('a duplicate packet is not counted twice', () {
      final b = fresh();
      pushRange(b, 0, 10);
      pushRange(b, 0, 10);
      expect(b.eegSamplesReceived, 10);
      expect(b.eegSamplesLost, 0);
    });

    test('a small step back is reordering, not a restart', () {
      final b = fresh();
      pushRange(b, 0, 500);
      b.pushEeg(eeg(480, 10));
      expect(b.latestEegIndex, 499);
      expect(b.eegSamplesReceived, 500);
    });

    test('an index that goes back by more than a second restarts the buffer', () {
      final b = fresh();
      pushRange(b, 0, 1000);
      pushRange(b, 0, 10);
      expect(b.latestEegIndex, 9);
      expect(b.eegSamplesReceived, 10);
      expect(b.eegSamplesLost, 0);
      final s = b.snapshot(seconds: 0.1);
      expect(s.eeg[0].last, eegValue(9, 0));
      expect(s.eeg[0].where((v) => !v.isNaN).length, 10, reason: 'old data is gone');
    });

    test('reset() forgets everything', () {
      final b = fresh();
      pushRange(b, 0, 100);
      b.reset();
      expect(b.hasData, isFalse);
      expect(b.channels, 0);
      expect(b.snapshot().isEmpty, isTrue);
    });

    test('lead-off bits of the newest sample', () {
      final b = fresh();
      b.pushEeg(eeg(0, 10));
      expect(b.leadOff, isFalse);
      b.pushEeg(eeg(10, 10, loff: 0x03));
      expect(b.leadOff, isTrue);
      expect(b.leadOffMask, 0x03);
      b.pushEeg(eeg(20, 10, loff: 0x10)); // RLD only is not an electrode fault
      expect(b.leadOff, isFalse);
    });

    test('configure applies the device rates and scales and starts over', () {
      final b = fresh();
      pushRange(b, 0, 100);
      b.configure(info(eegRate: 500, imuRate: 200));
      expect(b.hasData, isFalse);
      expect(b.eegRateHz, 500);
      pushRange(b, 0, 20);
      final s = b.snapshot(seconds: 1);
      expect(s.eeg[0].length, 500);
      expect(s.eegRateHz, 500);
      expect(s.accelX.length, 200);
    });
  });

  group('IMU on the EEG clock', () {
    LiveSignalBuffer withMotion() {
      final b = fresh();
      pushRange(b, 0, 500); // 2 s of EEG
      // 10 IMU samples per 25 EEG samples; IMU index = EEG index * 0.4
      for (var e = 0; e < 475; e += 25) {
        b.pushImu(imu(e, (e * 0.4).round()));
      }
      return b;
    }

    test('the two windows cover the same time span', () {
      final b = withMotion();
      final s = b.snapshot(seconds: 1); // EEG idx 250..499
      expect(s.startIdx, 250);
      expect(s.eeg[0].length, 250);
      expect(s.accelX.length, 100);
      // EEG index 250 is IMU index 100: the left edges line up.
      expect(s.accelX[0], closeTo(100 * 0.001, 1e-6)); // float32 storage
      expect(s.accelX[50], closeTo(150 * 0.001, 1e-6));
      expect(s.accelY[0], closeTo(-100 * 0.001, 1e-6));
      expect(s.accelZ[0], closeTo(1.0, 1e-6));
      expect(s.gyroX[0], closeTo(100 * 10 * 0.1, 1e-4));
    });

    test('IMU samples that have not arrived yet are NaN', () {
      final b = withMotion(); // IMU data runs to imu index 189
      final s = b.snapshot(seconds: 1);
      expect(s.accelX[89], closeTo(189 * 0.001, 1e-6));
      expect(s.accelX[90].isNaN, isTrue);
      expect(s.accelX.last.isNaN, isTrue);
    });

    test('lost IMU packets leave gaps and are counted', () {
      final b = fresh();
      pushRange(b, 0, 500);
      b.pushImu(imu(0, 0));
      b.pushImu(imu(75, 30)); // skips imu index 10..29
      expect(b.imuSamplesLost, 20);
      expect(b.imuSamplesReceived, 20);
      final s = b.snapshot(seconds: 0.4); // 100 EEG samples: idx 400..499 -> imu 160..199
      expect(s.startIdx, 400);
      final early = b.snapshot(seconds: 2);
      expect(early.accelX[15].isNaN, isTrue);
      expect(early.accelX[5].isNaN, isFalse);
      expect(early.accelX[30].isNaN, isFalse);
    });

    test('a restart clears the motion data with the EEG data', () {
      final b = withMotion();
      pushRange(b, 0, 10); // index went back
      b.pushImu(imu(0, 0));
      expect(b.imuSamplesReceived, 10);
      // 0.1 s window ending at EEG idx 9 covers IMU idx -6..3: four real samples, none from the old stream.
      final accel = b.snapshot(seconds: 0.1).accelX;
      expect(accel.where((v) => !v.isNaN).length, 4);
      expect(accel.where((v) => !v.isNaN).every((v) => v < 0.005), isTrue);
    });
  });

  group('snapshots', () {
    test('are copies', () {
      final b = fresh();
      pushRange(b, 0, 100);
      final a = b.snapshot(seconds: 0.2);
      final before = Float32List.fromList(a.eeg[0]);
      a.eeg[0].fillRange(0, a.eeg[0].length, 999.0);
      pushRange(b, 100, 200);
      final c = b.snapshot(seconds: 0.2);
      expect(c.eeg[0].first, isNot(999.0));
      expect(c.endIdx, 199);
      expect(before.last, eegValue(99, 0), reason: 'an old snapshot is a frozen picture');
    });
  });
}
