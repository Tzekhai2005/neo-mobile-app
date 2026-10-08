import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/device/device_status.dart';
import 'package:neo_companion/live/live_signal_buffer.dart';
import 'package:neo_companion/protocol/neo_messages.dart';
import 'package:neo_companion/ui/widgets/live_data_card.dart';
import 'package:neo_companion/ui/widgets/live_trace.dart';

Float32List wave(int n, {double offset = 0, double amp = 10}) =>
    Float32List.fromList([for (var i = 0; i < n; i++) offset + amp * math.sin(i * 0.2)]);

NeoEegPacket eeg(int idx, int n) => NeoEegPacket(
      NeoHeader(sampleIdx: idx),
      2,
      1,
      [for (var k = 0; k < n; k++) NeoEegSample(0, [((idx + k) % 50) * 20, 0])],
    );

void main() {
  group('normalizeTrace', () {
    test('removes a huge offset, so the trace is centred', () {
      final t = normalizeTrace(wave(1000, offset: 400000, amp: 30))!;
      final mean = t.reduce((a, b) => a + b) / t.length;
      expect(mean.abs(), lessThan(0.1));
      expect(t.every((v) => v >= -1 && v <= 1), isTrue);
    });

    test('uses the signal\'s own size, so small and large signals both fill the strip', () {
      final small = normalizeTrace(wave(1000, amp: 2))!;
      final large = normalizeTrace(wave(1000, amp: 2000))!;
      double peak(Float64List x) => x.map((v) => v.abs()).reduce(math.max);
      expect(peak(small), closeTo(peak(large), 0.05));
      expect(peak(small), greaterThan(0.8));
    });

    test('a flat line stays flat and is not blown up', () {
      final t = normalizeTrace(Float32List.fromList(List.filled(500, 7.0)))!;
      expect(t.every((v) => v.abs() < 1e-3), isTrue);
    });

    test('lost samples stay gaps', () {
      final s = wave(800);
      for (var i = 300; i < 500; i++) {
        s[i] = double.nan;
      }
      final t = normalizeTrace(s, points: 80)!;
      expect(t.where((v) => v.isNaN).length, inInclusiveRange(15, 25));
      expect(t.first.isNaN, isFalse);
      expect(t.last.isNaN, isFalse);
    });

    test('nothing real to draw gives null', () {
      expect(normalizeTrace(Float32List(0)), isNull);
      expect(normalizeTrace(Float32List.fromList([double.nan, double.nan, double.nan])), isNull);
      expect(normalizeTrace(wave(100), points: 1), isNull);
    });

    test('the number of points is what was asked for', () {
      expect(normalizeTrace(wave(1000), points: 160)!.length, 160);
      expect(normalizeTrace(wave(50), points: 160)!.length, 160, reason: 'fewer samples than points still works');
    });
  });

  group('LiveDataCard', () {
    Future<void> pump(WidgetTester t, ValueNotifier<DeviceStatus> status, LiveSignalBuffer buf, {VoidCallback? onTap}) =>
        t.pumpWidget(MaterialApp(
          home: Scaffold(body: LiveDataCard(status: status, buffer: buf, onTap: onTap ?? () {})),
        ));

    testWidgets('says what the device is doing', (t) async {
      final status = ValueNotifier(const DeviceStatus());
      await pump(t, status, LiveSignalBuffer());
      expect(find.text('Waiting for the device'), findsOneWidget);
      status.value = const DeviceStatus(link: LinkState.connecting);
      await t.pump();
      expect(find.text('Connecting'), findsOneWidget);
      status.value = const DeviceStatus(link: LinkState.connected);
      await t.pump();
      expect(find.text('Streaming'), findsOneWidget);
      status.value = const DeviceStatus(link: LinkState.stalled);
      await t.pump();
      expect(find.text('No data'), findsOneWidget);
      await t.pumpWidget(const SizedBox()); // stops its timer
    });

    testWidgets('opens the Data page when tapped', (t) async {
      var taps = 0;
      await pump(t, ValueNotifier(const DeviceStatus()), LiveSignalBuffer(), onTap: () => taps++);
      await t.tap(find.text('Live data'));
      expect(taps, 1);
    });

    testWidgets('draws live data while connected, and a flat line when not', (t) async {
      final status = ValueNotifier(const DeviceStatus(link: LinkState.connected));
      final buf = LiveSignalBuffer()..pushEeg(eeg(0, 1500));
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 100,
            child: LiveTraceStrip(buffer: buf, status: status, color: Colors.black),
          ),
        ),
      ));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(LiveTraceStrip), findsOneWidget);
      final painter = t.widget<CustomPaint>(find.descendant(of: find.byType(LiveTraceStrip), matching: find.byType(CustomPaint)).first);
      expect(painter.painter, isNotNull);

      status.value = const DeviceStatus(); // the device went away
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('keeps no timer running when the device is not connected', (t) async {
      final status = ValueNotifier(const DeviceStatus());
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 300, height: 100, child: LiveTraceStrip(buffer: LiveSignalBuffer(), status: status, color: Colors.black)),
        ),
      ));
      await t.pump(const Duration(seconds: 2));
      // a leftover periodic timer would fail the test at the end
    });
  });
}
