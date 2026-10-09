import 'dart:math' as math;

import '../data/recording_source.dart';

/// A few plain measures of an event's first EEG channel, used to say whether two
/// events look alike. This is a simple, experimental comparison (how big, how
/// jagged, how fast it swings, how long), not a classifier and not a diagnosis.
class EventFeatures {
  /// Spread of the signal around its own middle, µV.
  final double rmsUv;

  /// Mean size of the step from one sample to the next, µV.
  final double stepUv;

  /// How many times a second the signal crosses its own middle.
  final double crossingsHz;

  final double durationSec;

  const EventFeatures(this.rmsUv, this.stepUv, this.crossingsHz, this.durationSec);

  List<double> get _logs => [rmsUv, stepUv, crossingsHz, durationSec].map((v) => math.log(v + 1)).toList();
}

/// How far apart two events are, in units where about 1 is "clearly different
/// in one respect". Zero means identical.
double featureDistance(EventFeatures a, EventFeatures b) {
  const scale = [0.55, 0.55, 0.55, 0.7];
  final x = a._logs, y = b._logs;
  var sum = 0.0;
  for (var i = 0; i < x.length; i++) {
    final d = (x[i] - y[i]) / scale[i];
    sum += d * d;
  }
  return math.sqrt(sum);
}

/// Two events closer than this count as looking similar.
const double kSimilarDistance = 1.6;

/// The measures for the stretch of the event (with a little before and after) in [w].
EventFeatures featuresOf(SignalWindow w, double eventDurationSec) {
  if (w.eeg.isEmpty || w.eeg.first.length < 2) return EventFeatures(0, 0, 0, eventDurationSec);
  final x = w.eeg.first;
  final rate = w.eegRateHz;
  final span = math.max(eventDurationSec, 2.0);
  final from = ((w.preSec - 1) * rate).floor().clamp(0, x.length - 2);
  final to = ((w.preSec + span + 1) * rate).ceil().clamp(from + 2, x.length);
  var sum = 0.0;
  var n = 0;
  for (var i = from; i < to; i++) {
    if (!x[i].isNaN) {
      sum += x[i];
      n++;
    }
  }
  if (n < 2) return EventFeatures(0, 0, 0, eventDurationSec);
  final mean = sum / n;
  var sq = 0.0, steps = 0.0, crossings = 0, stepN = 0;
  double? prev;
  for (var i = from; i < to; i++) {
    final v = x[i];
    if (v.isNaN) {
      prev = null;
      continue;
    }
    final d = v - mean;
    sq += d * d;
    if (prev != null) {
      steps += (d - prev).abs();
      stepN++;
      if ((d >= 0) != (prev >= 0)) crossings++;
    }
    prev = d;
  }
  final seconds = (to - from) / rate;
  return EventFeatures(
    math.sqrt(sq / n),
    stepN == 0 ? 0 : steps / stepN,
    crossings / seconds,
    eventDurationSec,
  );
}

/// How many of the confirmed events an event looks like.
class SimilarEvents {
  final int similar;
  final int compared;
  const SimilarEvents(this.similar, this.compared);
}
