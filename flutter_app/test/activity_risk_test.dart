import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/device/device_status.dart';
import 'package:neo_companion/live/activity_risk.dart';
import 'package:neo_companion/live/live_signal_buffer.dart';
import 'package:neo_companion/protocol/neo_messages.dart';

Float32List sine(int n, {double amp = 20, double offset = 0, double hz = 10, int rate = 250}) =>
    Float32List.fromList([for (var i = 0; i < n; i++) offset + amp * math.sin(2 * math.pi * hz * i / rate)]);

/// A repeatable stand-in for ordinary variation: ±[spread] around 1.
double wobble(int i, {double spread = 0.25}) => 1 + spread * math.sin(i * 1.7) * math.cos(i * 0.37);

void main() {
  group('riskFromRatio', () {
    test('normal and quieter than normal sit on the floor', () {
      expect(riskFromRatio(0.1), 6);
      expect(riskFromRatio(0.8), 6);
      expect(riskFromRatio(double.nan), 6);
    });

    test('ordinary variation moves it a little, between 6 and 16', () {
      for (final r in [0.9, 1.0, 1.2, 1.5, 2.0]) {
        expect(riskFromRatio(r), inInclusiveRange(6, 16), reason: 'ratio $r');
      }
      expect(riskFromRatio(2), closeTo(16, 1e-9));
    });

    test('a clearly busier signal climbs, to 98 at most, and never 100', () {
      expect(riskFromRatio(4), closeTo(16 + 41, 1e-9));
      expect(riskFromRatio(6), 98);
      expect(riskFromRatio(60), 98);
    });

    test('never goes down as the signal gets busier', () {
      var last = 0.0;
      for (var r = 0.0; r < 10; r += 0.05) {
        final v = riskFromRatio(r);
        expect(v, greaterThanOrEqualTo(last));
        last = v;
      }
    });
  });

  group('meanLineLength', () {
    test('a large electrode offset makes no difference', () {
      final a = meanLineLength([sine(500)], 250)!;
      final b = meanLineLength([sine(500, offset: 400000)], 250)!;
      expect(b, closeTo(a, a * 0.05));
    });

    test('a bigger or faster signal reads busier', () {
      final base = meanLineLength([sine(500)], 250)!;
      expect(meanLineLength([sine(500, amp: 80)], 250)!, greaterThan(base * 3));
      expect(meanLineLength([sine(500, hz: 25)], 250)!, greaterThan(base * 2));
    });

    test('channels are averaged', () {
      final a = meanLineLength([sine(500, amp: 10)], 250)!;
      final b = meanLineLength([sine(500, amp: 30)], 250)!;
      expect(meanLineLength([sine(500, amp: 10), sine(500, amp: 30)], 250)!, closeTo((a + b) / 2, (a + b) * 0.02));
    });

    test('missing samples are skipped, and too many make it unknown', () {
      final some = sine(500);
      for (var i = 100; i < 140; i++) {
        some[i] = double.nan; // 8 % missing
      }
      expect(meanLineLength([some], 250), isNotNull);
      final most = sine(500);
      for (var i = 0; i < 200; i++) {
        most[i] = double.nan; // 40 % missing
      }
      expect(meanLineLength([most], 250), isNull);
    });

    test('nothing to measure', () {
      expect(meanLineLength(const [], 250), isNull);
      expect(meanLineLength([Float32List(1)], 250), isNull);
    });
  });

  group('isMoving', () {
    Float32List flat(double v) => Float32List.fromList(List.filled(200, v));
    Float32List shaking(double amp) => Float32List.fromList([for (var i = 0; i < 200; i++) amp * math.sin(i * 0.5)]);

    test('lying still is not movement, even tilted (gravity is steady)', () {
      expect(isMoving(flat(0.3), flat(0.2), flat(0.9), flat(0), flat(0), flat(0)), isFalse);
    });

    test('shaking the accelerometer is movement', () {
      expect(isMoving(shaking(0.8), flat(0), flat(1), flat(0), flat(0), flat(0)), isTrue);
    });

    test('turning fast is movement', () {
      expect(isMoving(flat(0), flat(0), flat(1), shaking(120), flat(0), flat(0)), isTrue);
    });

    test('no motion data is not movement', () {
      final none = Float32List.fromList(List.filled(200, double.nan));
      expect(isMoving(none, none, none, none, none, none), isFalse);
    });
  });

  group('ActivityRiskEngine', () {
    ActivityRisk feed(ActivityRiskEngine e, double ll, {bool movement = false, bool contact = true, bool hasData = true}) =>
        e.update(lineLength: ll, movement: movement, contact: contact, hasData: hasData);

    test('shows nothing while it learns the wearer\'s baseline', () {
      final e = ActivityRiskEngine(minSeconds: 20);
      for (var i = 0; i < 19; i++) {
        final r = feed(e, 1);
        expect(r.state, RiskState.calibrating);
        expect(r.percent, isNull);
      }
      expect(feed(e, 1).state, RiskState.ok);
    });

    test('ordinary wear stays low and drifts a little; it never triggers by itself', () {
      final e = ActivityRiskEngine();
      var maxP = 0.0, minP = 100.0;
      for (var i = 0; i < 2000; i++) {
        final r = feed(e, 5 * wobble(i, spread: 0.3));
        if (r.state == RiskState.ok) {
          maxP = math.max(maxP, r.percent!);
          minP = math.min(minP, r.percent!);
        }
      }
      expect(maxP, lessThan(20), reason: 'a normal hour must not look like an event');
      expect(minP, greaterThanOrEqualTo(6));
      expect(maxP - minP, greaterThan(0.5), reason: 'it should move a little, not sit dead still');
    });

    test('a real, sustained change in the signal raises it, and it comes back down', () {
      final e = ActivityRiskEngine();
      for (var i = 0; i < 120; i++) {
        feed(e, 5 * wobble(i));
      }
      var peak = 0.0;
      for (var i = 0; i < 30; i++) {
        peak = math.max(peak, feed(e, 20).percent!); // four times the baseline
      }
      expect(peak, greaterThan(50));
      expect(peak, lessThan(60), reason: 'four times busier reads about 57');
      for (var i = 0; i < 30; i++) {
        peak = math.max(peak, feed(e, 35).percent!); // seven times the baseline
      }
      expect(peak, greaterThan(90));
      expect(peak, lessThanOrEqualTo(98));
      late ActivityRisk after;
      for (var i = 0; i < 40; i++) {
        after = feed(e, 5 * wobble(i));
      }
      expect(after.percent, lessThan(20));
    });

    test('one odd second does not swing it far', () {
      final e = ActivityRiskEngine();
      for (var i = 0; i < 60; i++) {
        feed(e, 5 * wobble(i));
      }
      final spike = feed(e, 25).percent!; // five times normal for one second
      expect(spike, lessThan(40));
    });

    test('movement holds it down, and does not teach the baseline that busy is normal', () {
      final e = ActivityRiskEngine();
      for (var i = 0; i < 60; i++) {
        feed(e, 5 * wobble(i));
      }
      for (var i = 0; i < 300; i++) {
        final r = feed(e, 50, movement: true); // very busy, but the wearer is moving
        expect(r.state, RiskState.movement);
        expect(r.percent!, lessThan(20));
      }
      // The baseline is still the quiet one: the same busy signal, once still, reads high.
      late ActivityRisk r;
      for (var i = 0; i < 20; i++) {
        r = feed(e, 25);
      }
      expect(r.percent, greaterThan(50));
    });

    test('movement before any number has been shown shows no number', () {
      final e = ActivityRiskEngine();
      final r = feed(e, 5, movement: true);
      expect(r.state, RiskState.movement);
      expect(r.percent, isNull);
    });

    test('a poor electrode shows nothing, with its own reason', () {
      final e = ActivityRiskEngine();
      for (var i = 0; i < 60; i++) {
        feed(e, 5 * wobble(i));
      }
      final r = feed(e, 5, contact: false);
      expect(r.state, RiskState.noContact);
      expect(r.percent, isNull);
    });

    test('no data shows nothing, and the baseline is kept for when it returns', () {
      final e = ActivityRiskEngine();
      for (var i = 0; i < 60; i++) {
        feed(e, 5 * wobble(i));
      }
      expect(e.update(lineLength: null, movement: false, contact: true, hasData: false).state, RiskState.noData);
      expect(feed(e, 5).state, RiskState.ok, reason: 'no need to learn again');
    });

    test('reset forgets the wearer', () {
      final e = ActivityRiskEngine();
      for (var i = 0; i < 60; i++) {
        feed(e, 5);
      }
      e.reset();
      expect(feed(e, 5).state, RiskState.calibrating);
    });

    test('the baseline follows a slow change in what is normal', () {
      final e = ActivityRiskEngine(historySeconds: 100);
      for (var i = 0; i < 100; i++) {
        feed(e, 5);
      }
      late ActivityRisk r;
      for (var i = 0; i < 300; i++) {
        r = feed(e, 10); // twice as busy for good: the new normal
      }
      expect(r.percent, lessThan(20));
    });
  });

  group('ActivityRiskMonitor', () {
    NeoEegPacket eeg(int idx, int n, {double amp = 600}) => NeoEegPacket(
          NeoHeader(sampleIdx: idx),
          2,
          1,
          [for (var k = 0; k < n; k++) NeoEegSample(0, [(5000 + amp * math.sin((idx + k) * 0.5)).round(), 0])],
        );

    late LiveSignalBuffer buffer;
    late ValueNotifier<DeviceStatus> status;
    late ActivityRiskMonitor monitor;
    var idx = 0;

    void push(int n, {double amp = 600}) {
      for (var i = 0; i < n; i += 10) {
        buffer.pushEeg(eeg(idx, 10, amp: amp));
        idx += 10;
      }
    }

    setUp(() {
      buffer = LiveSignalBuffer();
      status = ValueNotifier(const DeviceStatus(link: LinkState.connected, leadOff: false));
      monitor = ActivityRiskMonitor(buffer: buffer, status: status);
      idx = 0;
    });
    tearDown(() => monitor.dispose());

    test('nothing until data arrives', () {
      monitor.step();
      expect(monitor.value.state, RiskState.noData);
    });

    test('learns, then reads steady wear as low', () {
      for (var s = 0; s < 30; s++) {
        push(250);
        monitor.step();
      }
      expect(monitor.value.state, RiskState.ok);
      expect(monitor.value.percent, lessThan(20));
    });

    test('a device that is not connected shows nothing', () {
      push(500);
      status.value = const DeviceStatus(link: LinkState.searching);
      monitor.step();
      expect(monitor.value.state, RiskState.noData);
    });

    test('an electrode off the skin shows nothing', () {
      push(500);
      status.value = const DeviceStatus(link: LinkState.connected, leadOff: true);
      monitor.step();
      expect(monitor.value.state, RiskState.noContact);
    });

    test('a new stream starts learning again', () {
      for (var s = 0; s < 30; s++) {
        push(250);
        monitor.step();
      }
      expect(monitor.value.state, RiskState.ok);
      buffer.reset();
      idx = 0;
      push(500);
      monitor.step();
      expect(monitor.value.state, RiskState.calibrating);
    });

    test('a signal far busier than the wearer\'s own raises it', () {
      for (var s = 0; s < 60; s++) {
        push(250);
        monitor.step();
      }
      late ActivityRisk r;
      for (var s = 0; s < 20; s++) {
        push(250, amp: 6000);
        monitor.step();
        r = monitor.value;
      }
      expect(r.percent, greaterThan(40));
    });

    test('start and dispose leave no timer running', () async {
      monitor.start();
      monitor.start(); // twice is harmless
    });
  });
}
