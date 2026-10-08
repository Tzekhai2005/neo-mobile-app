import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/ui/theme/app_theme.dart';
import 'package:neo_companion/ui/trace/signal_lanes.dart';
import 'package:neo_companion/ui/trace/trace_models.dart';

Float32List wave(int n, {double amp = 30, double offset = 0, int rate = 250}) =>
    Float32List.fromList([for (var i = 0; i < n; i++) offset + amp * math.sin(i * 0.2)]);

TraceLane lane(String label, Float32List s, {double scale = 100, double weight = 2, bool baseline = true}) => TraceLane(
      label: label,
      series: [s],
      colors: [AppColors.channel[0]],
      scale: scale,
      unit: 'µV',
      rateHz: 250,
      removeBaseline: baseline,
      weight: weight,
    );

Future<void> pump(WidgetTester t, Widget child, {Size size = const Size(360, 400)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: buildAppTheme(), home: Scaffold(body: child)));
}

void main() {
  testWidgets('draws every kind of thing at once without a problem', (t) async {
    final gappy = wave(2500, offset: 300000);
    for (var i = 1000; i < 1300; i++) {
      gappy[i] = double.nan;
    }
    final data = TraceData(
      lanes: [
        lane('Ch1', gappy),
        lane('Ch2', wave(2500, amp: 4000), scale: 25), // far beyond its lane
        TraceLane(
          label: 'Accel',
          series: [wave(1000, amp: 0.5), wave(1000, amp: 0.3), wave(1000, amp: 1)],
          colors: AppColors.axis,
          scale: 2,
          unit: 'g',
          rateHz: 100,
          weight: 1,
          seriesNames: const ['x', 'y', 'z'],
        ),
      ],
      durationSec: 10,
      markers: const [TraceMarker(4, label: 'button', color: AppColors.warning), TraceMarker(9.9, label: 'Seizure now', color: AppColors.danger)],
      spans: [TraceSpan(2, 3, AppColors.accent.withValues(alpha: 0.14))],
      ticks: const [TraceTick(0, '−10 s'), TraceTick(5, '−5 s'), TraceTick(10, 'now')],
    );
    await pump(t, SizedBox(height: 380, child: SignalLanes(data: data)));
    expect(tester(t), isNull, reason: 'no exception while painting');
  });

  testWidgets('no lanes draws nothing and does not fail', (t) async {
    await pump(t, const SizedBox(height: 200, child: SignalLanes(data: TraceData(lanes: [], durationSec: 0))));
    expect(tester(t), isNull);
  });

  testWidgets('unbounded height still works', (t) async {
    final data = TraceData(lanes: [lane('Ch1', wave(500)), lane('Ch2', wave(500))], durationSec: 2);
    await pump(t, SingleChildScrollView(child: SignalLanes(data: data)));
    expect(tester(t), isNull);
    expect(t.getSize(find.byType(CustomPaint).last).height, greaterThan(100));
  });

  testWidgets('a single sample or an empty series does not fail', (t) async {
    final data = TraceData(
      lanes: [lane('Ch1', Float32List.fromList([5])), lane('Ch2', Float32List(0)), lane('Ch3', Float32List.fromList([double.nan, double.nan]))],
      durationSec: 1,
    );
    await pump(t, SizedBox(height: 300, child: SignalLanes(data: data)));
    expect(tester(t), isNull);
  });

  group('tapping a lane', () {
    final data = TraceData(
      lanes: [lane('Ch1', wave(500)), lane('Ch2', wave(500)), lane('Accel', wave(200), weight: 1)],
      durationSec: 2,
      ticks: const [TraceTick(0, 'a')],
    );

    testWidgets('reports which lane', (t) async {
      final tapped = <int>[];
      await pump(t, SizedBox(height: 400, child: SignalLanes(data: data, onLaneTap: tapped.add)));
      final box = t.getRect(find.byType(SignalLanes));
      // 400 high: axis 18, two gaps of 6; lanes share 370 as 2:2:1
      await t.tapAt(Offset(box.left + 50, box.top + 30));
      await t.tapAt(Offset(box.left + 50, box.top + 6 + 148 + 6 + 40));
      await t.tapAt(Offset(box.left + 50, box.top + 400 - 18 - 20));
      expect(tapped, [0, 1, 2]);
    });

    testWidgets('a tap between lanes or on the time labels is ignored', (t) async {
      final tapped = <int>[];
      await pump(t, SizedBox(height: 400, child: SignalLanes(data: data, onLaneTap: tapped.add)));
      final box = t.getRect(find.byType(SignalLanes));
      await t.tapAt(Offset(box.left + 50, box.top + 148 + 3)); // in the gap
      await t.tapAt(Offset(box.left + 50, box.top + 395)); // on the axis
      expect(tapped, isEmpty);
    });

    testWidgets('without a callback a tap does nothing', (t) async {
      await pump(t, SizedBox(height: 400, child: SignalLanes(data: data)));
      await t.tapAt(const Offset(50, 30));
      expect(tester(t), isNull);
    });
  });
}

Object? tester(WidgetTester t) => t.takeException();
