import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/data/static_recording_source.dart';
import 'package:neo_companion/live/live_signal_buffer.dart';
import 'package:neo_companion/protocol/neo_messages.dart';
import 'package:neo_companion/ui/theme/app_theme.dart';
import 'package:neo_companion/ui/trace/trace_models.dart';
import 'package:neo_companion/ui/trace/trace_sources.dart';

NeoEegPacket eeg(int idx, int n, {int ch = 2}) => NeoEegPacket(
      NeoHeader(sampleIdx: idx),
      ch,
      1,
      [for (var k = 0; k < n; k++) NeoEegSample(0, [for (var c = 0; c < ch; c++) (idx + k) * 3 + c])],
    );

NeoImuPacket imu(int eegIdx, int imuStart, {int n = 10}) => NeoImuPacket(
      NeoHeader(sampleIdx: eegIdx),
      [for (var k = 0; k < n; k++) NeoImuSample(imuStart + k, 0, 1000, 0, 0, 0)],
    );

void main() {
  group('liveTicks', () {
    test('never more than six, and the last is "now"', () {
      for (final d in [3.0, 5.0, 10.0, 15.0, 30.0]) {
        final t = liveTicks(d);
        expect(t.length, lessThanOrEqualTo(7), reason: '$d s');
        expect(t.last.label, 'now');
        expect(t.last.important, isTrue);
        expect(t.last.t, d);
        expect(t.every((x) => x.t >= 0 && x.t <= d), isTrue, reason: '$d s');
      }
    });

    test('10 seconds is labelled every 2 seconds, from the left', () {
      final t = liveTicks(10);
      expect(t.map((x) => x.label), ['−10 s', '−8 s', '−6 s', '−4 s', '−2 s', 'now']);
      expect(t.first.t, 0);
    });

    test('15 seconds is labelled every 5', () {
      expect(liveTicks(15).map((x) => x.label), ['−15 s', '−10 s', '−5 s', 'now']);
    });

    test('nothing to label for an empty view', () {
      expect(liveTicks(0), isEmpty);
    });
  });

  test('eventTicks runs from before the event to after it, with "start" at zero', () {
    final t = eventTicks(40, 15);
    expect(t.first.label, '−15 s');
    expect(t.first.t, 0);
    expect(t.firstWhere((x) => x.label == 'start').t, 15);
    expect(t.firstWhere((x) => x.label == 'start').important, isTrue);
    expect(t.where((x) => x.important).length, 1);
    expect(t.last.label, '+25 s');
    expect(t.last.t, 40);
  });

  group('liveTraceData', () {
    LiveSnapshot snapshot({int ch = 2, bool withImu = true}) {
      final b = LiveSignalBuffer()..configure(_info());
      for (var i = 0; i < 2500; i += 10) {
        b.pushEeg(eeg(i, 10, ch: ch));
        if (withImu && i % 25 == 0) b.pushImu(imu(i, (i * 100 / 250).round()));
      }
      return b.snapshot(seconds: 10);
    }

    test('an empty snapshot has no lanes', () {
      final d = liveTraceData(LiveSignalBuffer().snapshot());
      expect(d.lanes, isEmpty);
      expect(d.durationSec, 0);
    });

    test('two channels and motion make four lanes, EEG taller and baseline-corrected', () {
      final d = liveTraceData(snapshot());
      expect(d.lanes.map((l) => l.label), ['Ch1', 'Ch2', 'Accel', 'Gyro']);
      expect(d.lanes[0].removeBaseline, isTrue);
      expect(d.lanes[2].removeBaseline, isFalse, reason: 'gravity is not a baseline');
      expect(d.lanes[0].weight, greaterThan(d.lanes[2].weight));
      expect(d.lanes[2].series.length, 3);
      expect(d.lanes[2].seriesNames, ['x', 'y', 'z']);
      expect(d.durationSec, closeTo(10, 0.01));
    });

    test('up to four channels, each in its own colour', () {
      final d = liveTraceData(snapshot(ch: 4));
      expect(d.lanes.where((l) => l.label.startsWith('Ch')).length, 4);
      expect(d.lanes[3].colors.single, AppColors.channel[3]);
    });

    test('motion can be hidden', () {
      final d = liveTraceData(snapshot(), showMotion: false);
      expect(d.lanes.map((l) => l.label), ['Ch1', 'Ch2']);
    });

    test('the EEG scale is the one asked for, in µV; the motion scales are fixed', () {
      final d = liveTraceData(snapshot(), eegScaleUv: 1000);
      expect(d.lanes[0].scale, 1000);
      expect(d.lanes[0].unit, 'µV');
      expect(d.lanes[2].scale, kAccelScaleG);
      expect(d.lanes[3].scale, kGyroScaleDps);
      expect(kEegScalesUv.last, 1000);
      expect(kEegScalesUv, contains(kDefaultEegScaleUv));
    });

    test('markers are passed through, and the view is labelled up to now', () {
      final d = liveTraceData(snapshot(), markers: const [TraceMarker(4, label: 'button', color: AppColors.warning)]);
      expect(d.markers.single.label, 'button');
      expect(d.ticks.last.label, 'now');
    });
  });

  group('windowTraceData', () {
    late StaticRecordingSource src;
    setUpAll(() async {
      src = StaticRecordingSource(DirectoryDatasetReader('test/fixtures/mini_recording'));
      await src.load();
    });

    test('marks the start, shades the event, and labels around it', () async {
      final e = src.events().first;
      final w = await src.eventWindow(e.id);
      final d = windowTraceData(w, eventDurationSec: 11);
      expect(d.markers.first.label, 'start');
      expect(d.markers.first.t, w.preSec);
      expect(d.spans.single.start, w.preSec);
      expect(d.spans.single.end, w.preSec + 11 < w.durationSec ? w.preSec + 11 : w.durationSec);
      expect(d.durationSec, w.durationSec);
      expect(d.lanes.length, 2 + 2, reason: 'two EEG channels plus accel and gyro');
      expect(d.ticks.any((t) => t.label == 'start'), isTrue);
    });

    test('an event with no length (a patient marker) has no shaded stretch', () async {
      final w = await src.eventWindow(src.events().first.id);
      expect(windowTraceData(w, eventDurationSec: 0).spans, isEmpty);
    });

    test('the shaded stretch never runs past the window', () async {
      final w = await src.eventWindow(src.events().first.id);
      final d = windowTraceData(w, eventDurationSec: 9999);
      expect(d.spans.single.end, w.durationSec);
    });
  });
}

NeoInfo _info() => NeoInfo(
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
      eegRateHz: 250,
      eegChannels: 2,
      eegFormat: 1,
      eegGain: const [6, 6],
      eegVrefUv: 2420000,
      uvPerCount: const [0.5, 0.5],
      imuRateHz: 100,
      imuGPerLsb: 0.001,
      imuDpsPerLsb: 0.1,
      podPresent: 0,
    );
