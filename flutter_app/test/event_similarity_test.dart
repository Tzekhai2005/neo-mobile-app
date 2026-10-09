import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/data/recording_source.dart';
import 'package:neo_companion/data/static_recording_source.dart';
import 'package:neo_companion/review/event_similarity.dart';

SignalWindow flat(double amp, {double hz = 3}) {
  const rate = 250;
  final x = Float32List(rate * 40);
  for (var i = 0; i < x.length; i++) {
    final t = i / rate;
    x[i] = amp * (((t * hz * 2) % 2) < 1 ? 1 : -1);
  }
  final z = Float32List(100 * 40);
  return SignalWindow(
    eventId: 'x',
    startSample: 0,
    eegRateHz: rate,
    imuRateHz: 100,
    preSec: 15,
    eeg: [x],
    accelX: z,
    accelY: z,
    accelZ: z,
    gyroX: z,
    gyroY: z,
    gyroZ: z,
  );
}

void main() {
  group('features', () {
    test('a bigger swing has a bigger spread, and a faster one crosses more often', () {
      final small = featuresOf(flat(20), 10);
      final big = featuresOf(flat(80), 10);
      expect(big.rmsUv, greaterThan(small.rmsUv * 3));
      final slow = featuresOf(flat(40, hz: 2), 10);
      final fast = featuresOf(flat(40, hz: 8), 10);
      expect(fast.crossingsHz, greaterThan(slow.crossingsHz * 2));
      expect(small.durationSec, 10);
    });

    test('an empty window gives zeros and does not throw', () {
      final w = SignalWindow(
        eventId: 'x',
        startSample: 0,
        eegRateHz: 250,
        imuRateHz: 100,
        preSec: 15,
        eeg: const [],
        accelX: Float32List(0),
        accelY: Float32List(0),
        accelZ: Float32List(0),
        gyroX: Float32List(0),
        gyroY: Float32List(0),
        gyroZ: Float32List(0),
      );
      final f = featuresOf(w, 5);
      expect((f.rmsUv, f.stepUv, f.crossingsHz), (0, 0, 0));
    });
  });

  group('distance', () {
    test('is zero for the same event, symmetric, and grows with the difference', () {
      final a = featuresOf(flat(30), 10), b = featuresOf(flat(60), 10), c = featuresOf(flat(240), 10);
      expect(featureDistance(a, a), 0);
      expect(featureDistance(a, b), closeTo(featureDistance(b, a), 1e-9));
      expect(featureDistance(a, c), greaterThan(featureDistance(a, b)));
    });
  });

  group('on the demo recording', () {
    test('seizure-like events look like each other and not like blinks, clenches or head shakes', () async {
      final s = StaticRecordingSource(DirectoryDatasetReader('test/fixtures/demo_3day'));
      await s.load();
      final rate = s.info.eegRateHz;
      final byKind = <String, List<EventFeatures>>{};
      for (final e in s.events().where((e) => e.truth != 'patient-marker')) {
        final w = await s.eventWindow(e.id);
        byKind.putIfAbsent(e.truth!, () => []).add(featuresOf(w, e.durationSec(rate)));
      }
      double share(String a, String b) {
        var close = 0, total = 0;
        for (final x in byKind[a]!.take(10)) {
          for (final y in byKind[b]!.take(10)) {
            if (identical(x, y)) continue;
            total++;
            if (featureDistance(x, y) <= kSimilarDistance) close++;
          }
        }
        return close / total;
      }

      expect(share('seizure-like', 'seizure-like'), greaterThan(0.9));
      for (final other in ['blink', 'clench', 'head-shake']) {
        expect(share('seizure-like', other), lessThan(0.1), reason: other);
        expect(share(other, 'seizure-like'), lessThan(0.1), reason: other);
      }
    });
  });
}
