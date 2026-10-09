import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/device/device_status.dart';
import 'package:neo_companion/live/live_signal_buffer.dart';
import 'package:neo_companion/live/seizure_markers.dart';
import 'package:neo_companion/protocol/neo_messages.dart';
import 'package:neo_companion/ui/data/data_view_controller.dart';
import 'package:neo_companion/ui/trace/trace_sources.dart';

NeoEegPacket eeg(int idx, int n) => NeoEegPacket(
      NeoHeader(sampleIdx: idx),
      2,
      1,
      [for (var k = 0; k < n; k++) NeoEegSample(0, [(idx + k) % 400, 0])],
    );

NeoImuPacket imu(int eegIdx, int imuStart, {int n = 10}) => NeoImuPacket(
      NeoHeader(sampleIdx: eegIdx),
      [for (var k = 0; k < n; k++) NeoImuSample(imuStart + k, 0, 1000, 0, 0, 0)],
    );

void main() {
  late LiveSignalBuffer buffer;
  late SeizureMarkerStore markers;
  late ValueNotifier<DeviceStatus> status;
  late DataViewController c;
  var next = 0;

  /// [seconds] more of signal, EEG and motion.
  void feed(double seconds) {
    final target = next + (seconds * 250).round();
    while (next < target) {
      buffer.pushEeg(eeg(next, 10));
      if (next % 25 == 0) buffer.pushImu(imu(next, (next * 100 / 250).round()));
      next += 10;
    }
  }

  setUp(() {
    buffer = LiveSignalBuffer();
    markers = SeizureMarkerStore();
    status = ValueNotifier(const DeviceStatus(link: LinkState.connected));
    c = DataViewController(buffer: buffer, seizureMarkers: markers, status: status);
    next = 0;
  });

  tearDown(() {
    c.dispose();
    markers.dispose();
  });

  group('before and after the first sample', () {
    test('starts empty and stays quiet', () {
      var told = 0;
      c.addListener(() => told++);
      c.tick();
      expect(c.data.lanes, isEmpty);
      expect(told, 0);
    });

    test('draws the lanes once data arrives', () {
      feed(12);
      c.tick();
      expect(c.data.lanes.map((l) => l.label), ['Ch1', 'Ch2', 'Accel', 'Gyro']);
      expect(c.data.durationSec, closeTo(10, 0.01));
      expect(c.data.ticks.last.label, 'now');
    });

    test('goes back to empty if the stream disappears', () {
      feed(12);
      c.tick();
      buffer.reset();
      c.tick();
      expect(c.data.lanes, isEmpty);
    });
  });

  group('window and scale', () {
    setUp(() {
      feed(30);
      c.tick();
    });

    test('the window is 5, 10 or 15 seconds', () {
      for (final s in [5, 15, 10]) {
        c.setWindow(s);
        expect(c.windowSec, s);
        expect(c.data.durationSec, closeTo(s.toDouble(), 0.01));
      }
      c.setWindow(7);
      expect(c.windowSec, 10, reason: 'only the three choices');
      expect(DataViewController.windowChoices, [5, 10, 15]);
    });

    test('tapping the scale steps through 25 to 1000 µV and starts again', () {
      expect(c.eegScaleUv, 100);
      final seen = <double>[];
      for (var i = 0; i < 6; i++) {
        c.nextScale();
        seen.add(c.eegScaleUv);
      }
      expect(seen, [200, 500, 1000, 25, 50, 100]);
      expect(c.data.lanes.first.scale, 100);
    });

    test('the scale reaches the lanes, and only the EEG lanes', () {
      c.nextScale();
      expect(c.data.lanes[0].scale, 200);
      expect(c.data.lanes[1].scale, 200);
      expect(c.data.lanes[2].scale, kAccelScaleG);
    });

    test('stepping stops at the ends', () {
      for (var i = 0; i < 10; i++) {
        c.stepScale(1);
      }
      expect(c.eegScaleUv, 1000);
      for (var i = 0; i < 10; i++) {
        c.stepScale(-1);
      }
      expect(c.eegScaleUv, 25);
    });

    test('an unchanged window does not disturb listeners', () {
      var told = 0;
      c.addListener(() => told++);
      c.setWindow(10);
      expect(told, 0);
    });
  });

  group('motion lanes', () {
    test('are open to begin with and can be closed and opened', () {
      feed(12);
      c.tick();
      expect(c.showMotion, isTrue);
      c.toggleMotion();
      expect(c.data.lanes.map((l) => l.label), ['Ch1', 'Ch2']);
      c.toggleMotion();
      expect(c.data.lanes.length, 4);
    });
  });

  group('pausing and looking back', () {
    setUp(() {
      feed(40); // more than the 30 s the buffer holds
      c.tick();
    });

    test('a paused view does not move while the live data does', () {
      c.pause();
      final frozen = c.data;
      feed(5);
      c.tick();
      expect(identical(c.data, frozen), isTrue);
      expect(c.paused, isTrue);
    });

    test('resuming catches up with the live data', () {
      c.pause();
      feed(5);
      c.resume();
      expect(c.paused, isFalse);
      expect(c.data.ticks.last.label, 'now');
    });

    test('a paused view says it is paused, not "now"', () {
      c.pause();
      expect(c.data.ticks.last.label, 'paused');
    });

    test('scrolling back goes earlier in time, and the labels say how far', () {
      c.pause();
      c.scrollBy(8);
      expect(c.backSec, 8);
      expect(c.data.ticks.last.label, '−8 s');
      expect(c.data.ticks.first.label, '−18 s');
    });

    test('scrolling forward again returns to the moment of pausing, and no further', () {
      c.pause();
      c.scrollBy(8);
      c.scrollBy(-3);
      expect(c.backSec, 5);
      c.scrollBy(-100);
      expect(c.backSec, 0);
    });

    test('scrolling back stops where the buffer ends, with the view still full', () {
      c.pause();
      c.scrollBy(1000);
      // 30 s held, a 10 s view: at most 20 s back
      expect(c.backSec, closeTo(20, 0.05));
      expect(c.maxBackSec, closeTo(20, 0.05));
      final lane = c.data.lanes.first.series.first;
      expect(lane.where((v) => v.isNaN), isEmpty, reason: 'no part of the view is outside the buffer');
    });

    test('a longer window leaves less room to scroll back', () {
      c.pause();
      c.setWindow(15);
      expect(c.maxBackSec, closeTo(15, 0.05));
    });

    test('shrinking the room pulls the view back inside it', () {
      c.pause();
      c.scrollBy(1000); // 20 s back with a 10 s window
      c.setWindow(15);
      expect(c.backSec, lessThanOrEqualTo(15.05));
    });

    test('scrolling while live does nothing', () {
      final before = c.data;
      c.scrollBy(5);
      expect(c.backSec, 0);
      expect(identical(c.data, before), isTrue);
    });

    test('nothing to pause before data arrives', () {
      final fresh = DataViewController(buffer: LiveSignalBuffer(), seizureMarkers: markers, status: status);
      fresh.pause();
      expect(fresh.paused, isFalse);
      fresh.dispose();
    });

    test('a restarted stream ends the pause, because the frozen view no longer means anything', () {
      c.pause();
      buffer.reset();
      next = 0;
      feed(3);
      c.tick();
      expect(c.paused, isFalse);
    });

    test('the scale and window can still be changed while paused', () {
      c.pause();
      c.nextScale();
      c.setWindow(5);
      expect(c.paused, isTrue);
      expect(c.data.lanes.first.scale, 200);
      expect(c.data.durationSec, closeTo(5, 0.01));
    });

    test('toggle pauses and resumes', () {
      c.togglePause();
      expect(c.paused, isTrue);
      c.togglePause();
      expect(c.paused, isFalse);
    });
  });

  group('expanding a lane', () {
    setUp(() {
      feed(12);
      c.tick();
    });

    test('shows that lane alone, with the same markers and time labels', () {
      c.expand(1);
      final d = c.expandedData!;
      expect(d.lanes.single.label, 'Ch2');
      expect(d.ticks.length, c.data.ticks.length);
    });

    test('collapsing returns to all of them', () {
      c.expand(0);
      c.collapse();
      expect(c.expandedData, isNull);
      expect(c.expandedLane, isNull);
    });

    test('a lane that does not exist cannot be expanded', () {
      c.expand(9);
      expect(c.expandedLane, isNull);
      c.expand(-1);
      expect(c.expandedLane, isNull);
    });

    test('hiding the motion lanes collapses an expanded motion lane', () {
      c.expand(3); // gyro
      c.toggleMotion();
      expect(c.expandedLane, isNull);
    });

    test('an expanded lane keeps following the live data', () {
      c.expand(0);
      final before = c.expandedData;
      feed(2);
      c.tick();
      expect(identical(c.expandedData, before), isFalse);
    });
  });

  group('markers', () {
    setUp(() {
      feed(20);
      c.tick();
    });

    test('a "Seizure now" marker appears at its place in the view', () {
      final end = buffer.latestEegIndex;
      markers.add(streamId: buffer.streamId, sampleIdx: end - 250, at: DateTime(2026)); // one second before the end
      c.tick();
      final m = c.data.markers.single;
      expect(m.label, 'Marked');
      expect(m.t, closeTo(c.data.durationSec - 1, 0.02));
    });

    test('it moves left as new data arrives, and leaves the view when it is too old', () {
      markers.add(streamId: buffer.streamId, sampleIdx: buffer.latestEegIndex, at: DateTime(2026));
      c.tick();
      final t0 = c.data.markers.single.t;
      feed(2);
      c.tick();
      expect(c.data.markers.single.t, closeTo(t0 - 2, 0.05));
      feed(10);
      c.tick();
      expect(c.data.markers, isEmpty);
    });

    test('a marker from an earlier stream is not drawn at a place that now means something else', () {
      markers.add(streamId: buffer.streamId, sampleIdx: buffer.latestEegIndex - 100, at: DateTime(2026));
      buffer.reset();
      next = 0;
      feed(12);
      c.tick();
      expect(c.data.markers, isEmpty);
    });

    test('a device button press shows as "button"', () {
      status.value = DeviceStatus(link: LinkState.connected, recentEvents: [
        DeviceEventRecord(
          eventId: NeoEventKind.button.id,
          kind: NeoEventKind.button,
          arg: 0,
          sampleIdx: buffer.latestEegIndex - 500,
          at: DateTime(2026),
        ),
        DeviceEventRecord(
          eventId: NeoEventKind.lowBattery.id,
          kind: NeoEventKind.lowBattery,
          arg: 0,
          sampleIdx: buffer.latestEegIndex - 100,
          at: DateTime(2026),
        ),
      ]);
      c.tick();
      expect(c.data.markers.map((m) => m.label), ['button'], reason: 'only button presses are drawn');
    });

    test('markers can be seen when looking back, at their place in that earlier view', () {
      markers.add(streamId: buffer.streamId, sampleIdx: buffer.latestEegIndex - 250 * 12, at: DateTime(2026));
      c.tick();
      expect(c.data.markers, isEmpty, reason: '12 s ago is outside a 10 s view');
      c.pause();
      c.scrollBy(6);
      expect(c.data.markers.single.label, 'Marked');
    });
  });
}
