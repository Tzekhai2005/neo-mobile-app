import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/ui/trace/trace_layout.dart';
import 'package:neo_companion/ui/trace/trace_math.dart';

Float32List sine(int n, double hz, int rate, {double amp = 10, double offset = 0}) =>
    Float32List.fromList([for (var i = 0; i < n; i++) offset + amp * math.sin(2 * math.pi * hz * i / rate)]);

double peak(Float32List x, {int from = 0}) {
  var p = 0.0;
  for (var i = from; i < x.length; i++) {
    if (!x[i].isNaN) p = math.max(p, x[i].abs());
  }
  return p;
}

void main() {
  group('removeBaseline', () {
    test('a large offset is taken out, so the trace sits in its lane', () {
      final out = removeBaseline(sine(2500, 10, 250, amp: 30, offset: 400000), 250);
      expect(out.length, 2500);
      expect(peak(out), lessThan(35), reason: 'no trace of the 400 000 µV offset, even at the start');
      final mean = out.fold<double>(0, (a, b) => a + b) / out.length;
      expect(mean.abs(), lessThan(1));
    });

    test('a rhythm well above the cut-off keeps its size', () {
      final out = removeBaseline(sine(2500, 10, 250, amp: 50), 250);
      expect(peak(out, from: 500), closeTo(50, 3));
    });

    test('a slow drift is mostly removed', () {
      final drift = Float32List.fromList([for (var i = 0; i < 2500; i++) i * 2.0]); // 500 µV per second
      final out = removeBaseline(drift, 250);
      expect(peak(out, from: 500), lessThan(500 * 0.7));
    });

    test('missing samples stay missing, and the baseline carries across them', () {
      final x = sine(1000, 10, 250, amp: 20, offset: 5000);
      for (var i = 400; i < 500; i++) {
        x[i] = double.nan;
      }
      final out = removeBaseline(x, 250);
      expect(out.sublist(400, 500).every((v) => v.isNaN), isTrue);
      expect(out.sublist(0, 400).any((v) => v.isNaN), isFalse);
      expect(peak(out), lessThan(40), reason: 'no jump after the gap');
    });

    test('a signal that starts with gaps still works', () {
      final x = Float32List.fromList([double.nan, double.nan, 7000, 7001, 7002]);
      final out = removeBaseline(x, 250);
      expect(out[0].isNaN, isTrue);
      expect(out[2], 0);
    });

    test('empty and unusable rates do not crash', () {
      expect(removeBaseline(Float32List(0), 250), isEmpty);
      expect(removeBaseline(Float32List.fromList([1, 2, 3]), 0), [1, 2, 3]);
    });

    test('the recorded data is not changed', () {
      final x = sine(100, 5, 250, offset: 100);
      final copy = Float32List.fromList(x);
      removeBaseline(x, 250);
      expect(x, copy);
    });
  });

  group('columnRanges', () {
    test('keeps a one-sample spike that averaging would lose', () {
      final x = Float32List(1000);
      x[503] = 900;
      final r = columnRanges(x, 100);
      expect(r.length, 100);
      expect(r[50].max, 900);
      expect(r.where((c) => c.max == 900).length, 1);
    });

    test('a column with only missing samples has no data', () {
      final x = Float32List.fromList(List.filled(100, 1.0));
      for (var i = 20; i < 40; i++) {
        x[i] = double.nan;
      }
      final r = columnRanges(x, 10);
      expect(r[2].hasData, isFalse);
      expect(r[3].hasData, isFalse);
      expect(r[0].hasData, isTrue);
    });

    test('fewer samples than columns still gives every column a range or a gap', () {
      final r = columnRanges(Float32List.fromList([1, 2, 3]), 10);
      expect(r.length, 10);
      expect(r.where((c) => c.hasData).isNotEmpty, isTrue);
    });

    test('no columns or no samples', () {
      expect(columnRanges(Float32List(5), 0), isEmpty);
      expect(columnRanges(Float32List(0), 4).every((c) => !c.hasData), isTrue);
    });
  });

  test('laneFraction holds a value at the edge', () {
    expect(laneFraction(0, 100), 0);
    expect(laneFraction(50, 100), 0.5);
    expect(laneFraction(100, 100), 1);
    expect(laneFraction(5000, 100), 1);
    expect(laneFraction(-5000, 100), -1);
  });

  group('overflowRuns', () {
    test('finds the stretches beyond the scale, above and below', () {
      final x = Float32List.fromList([0, 10, 150, 160, 20, -120, -130, -140, 5, 200]);
      final o = overflowRuns(x, 100);
      expect(o.above.map((r) => [r.from, r.to]), [
        [2, 4],
        [9, 10]
      ]);
      expect(o.below.map((r) => [r.from, r.to]), [
        [5, 8]
      ]);
    });

    test('exactly at the scale is not overflow, and missing samples are not either', () {
      final o = overflowRuns(Float32List.fromList([100, -100, double.nan, 99]), 100);
      expect(o.above, isEmpty);
      expect(o.below, isEmpty);
    });

    test('a trace that stays inside has none', () {
      final o = overflowRuns(sine(500, 5, 250, amp: 40), 100);
      expect(o.above, isEmpty);
      expect(o.below, isEmpty);
    });
  });

  group('lost samples', () {
    test('a gap is where every series is missing', () {
      final a = Float32List.fromList([1, double.nan, double.nan, 4, double.nan]);
      final b = Float32List.fromList([1, 2, double.nan, 4, double.nan]);
      final g = gapRuns([a, b]);
      expect(g.map((r) => [r.from, r.to]), [
        [2, 3],
        [4, 5]
      ]);
    });

    test('one series alone', () {
      final g = gapRuns([Float32List.fromList([double.nan, double.nan, 3, double.nan])]);
      expect(g.map((r) => [r.from, r.to]), [
        [0, 2],
        [3, 4]
      ]);
    });

    test('no series, or a signal with no gaps', () {
      expect(gapRuns(const []), isEmpty);
      expect(gapRuns([sine(50, 1, 50)]), isEmpty);
    });

    test('nearby runs merge', () {
      final m = mergeRuns(const [Run(0, 5), Run(7, 9), Run(30, 35)], 3);
      expect(m.map((r) => [r.from, r.to]), [
        [0, 9],
        [30, 35]
      ]);
      expect(mergeRuns(const [], 3), isEmpty);
    });
  });

  test('relative times read plainly', () {
    expect(relativeSeconds(-10), '−10 s');
    expect(relativeSeconds(25), '+25 s');
    expect(relativeSeconds(0), 'now');
    expect(relativeSeconds(0, zero: 'start'), 'start');
    expect(relativeSeconds(-0.4), 'now');
  });

  group('TraceLayout', () {
    test('lanes share the height by weight, with a gap, and leave room for the axis', () {
      final l = TraceLayout.compute(const Size(300, 200), [2, 2, 1], gap: 6, axisHeight: 18);
      expect(l.lanes.length, 3);
      final usable = 200 - 18 - 12;
      expect(l.lanes[0].height, closeTo(usable * 2 / 5, 1e-9));
      expect(l.lanes[2].height, closeTo(usable / 5, 1e-9));
      expect(l.lanes[1].top, closeTo(l.lanes[0].bottom + 6, 1e-9));
      expect(l.lanes.last.bottom, closeTo(200 - 18, 1e-9));
      expect(l.axis.top, 182);
      expect(l.lanes.every((r) => r.width == 300), isTrue);
    });

    test('finds the lane under a tap, and nothing between lanes or on the axis', () {
      final l = TraceLayout.compute(const Size(300, 200), [1, 1]);
      expect(l.laneAt(const Offset(10, 10)), 0);
      expect(l.laneAt(Offset(10, l.lanes[1].center.dy)), 1);
      expect(l.laneAt(Offset(10, l.lanes[0].bottom + 3)), isNull);
      expect(l.laneAt(const Offset(10, 195)), isNull);
    });

    test('no lanes is fine', () {
      final l = TraceLayout.compute(const Size(300, 200), const []);
      expect(l.lanes, isEmpty);
      expect(l.laneAt(const Offset(1, 1)), isNull);
    });

    test('time positions stay inside the view', () {
      final l = TraceLayout.compute(const Size(300, 200), [1]);
      expect(l.xOf(5, 10, 300), 150);
      expect(l.xOf(-3, 10, 300), 0);
      expect(l.xOf(99, 10, 300), 300);
      expect(l.xOf(1, 0, 300), 0);
    });
  });

  group('stackLabelRows', () {
    test('labels that fit side by side share a row', () {
      expect(stackLabelRows([(left: 0, width: 40), (left: 60, width: 40), (left: 120, width: 40)]), [0, 0, 0]);
    });

    test('a label that would overlap goes down a row', () {
      expect(stackLabelRows([(left: 0, width: 50), (left: 30, width: 50)]), [0, 1]);
    });

    test('a later label drops back to the first free row', () {
      expect(stackLabelRows([(left: 0, width: 50), (left: 30, width: 50), (left: 70, width: 20)]), [0, 1, 0]);
    });

    test('labels need a little room between them', () {
      expect(stackLabelRows([(left: 0, width: 50), (left: 52, width: 20)]), [0, 1]);
      expect(stackLabelRows([(left: 0, width: 50), (left: 54, width: 20)]), [0, 0]);
    });

    test('none, or one', () {
      expect(stackLabelRows(const []), isEmpty);
      expect(stackLabelRows([(left: 10, width: 5)]), [0]);
    });
  });

  group('visibleLabels', () {
    test('labels with room all stay', () {
      expect(visibleLabels([(left: 0, width: 30, important: false), (left: 60, width: 30, important: false)]), [0, 1]);
    });

    test('a label that crowds the one before it is dropped', () {
      final v = visibleLabels([
        (left: 0, width: 40, important: false),
        (left: 42, width: 40, important: false),
        (left: 100, width: 40, important: false),
      ]);
      expect(v, [0, 2]);
    });

    test('an important label is kept, and the ordinary one beside it gives way', () {
      final v = visibleLabels([
        (left: 0, width: 40, important: false),
        (left: 38, width: 40, important: true),
        (left: 100, width: 40, important: false),
      ]);
      expect(v, [1, 2]);
    });

    test('none, or one', () {
      expect(visibleLabels(const []), isEmpty);
      expect(visibleLabels([(left: 5, width: 5, important: false)]), [0]);
    });
  });
}
