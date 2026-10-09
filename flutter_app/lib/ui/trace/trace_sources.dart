import 'dart:math' as math;
import 'dart:typed_data';


import '../../data/recording_source.dart';
import '../../live/live_signal_buffer.dart';
import '../theme/app_theme.dart';
import 'trace_math.dart';
import 'trace_models.dart';

/// The EEG scales to choose from, in µV from the middle of a lane to its edge.
const List<double> kEegScalesUv = [25, 50, 100, 200, 500, 1000];
const double kDefaultEegScaleUv = 100;

/// Motion scales: the accelerometer in g, the gyro in °/s.
const double kAccelScaleG = 2;
const double kGyroScaleDps = 250;

List<TraceLane> _lanes({
  required List<Float32List> eeg,
  required int eegRateHz,
  required Float32List accelX,
  required Float32List accelY,
  required Float32List accelZ,
  required Float32List gyroX,
  required Float32List gyroY,
  required Float32List gyroZ,
  required int imuRateHz,
  required double eegScaleUv,
  required bool showMotion,
  bool showEeg = true,
}) =>
    [
      if (showEeg)
        for (var c = 0; c < eeg.length; c++)
        TraceLane(
          label: 'Ch${c + 1}',
          series: [eeg[c]],
          colors: [AppColors.channel[c % AppColors.channel.length]],
          scale: eegScaleUv,
          unit: 'µV',
          rateHz: eegRateHz,
          removeBaseline: true,
          weight: 2,
        ),
      if (showMotion) ...[
        TraceLane(
          label: 'Accel',
          series: [accelX, accelY, accelZ],
          colors: AppColors.axis,
          scale: kAccelScaleG,
          unit: 'g',
          rateHz: imuRateHz,
          seriesNames: const ['x', 'y', 'z'],
        ),
        TraceLane(
          label: 'Gyro',
          series: [gyroX, gyroY, gyroZ],
          colors: AppColors.axis,
          scale: kGyroScaleDps,
          unit: '°/s',
          rateHz: imuRateHz,
          seriesNames: const ['x', 'y', 'z'],
        ),
      ],
    ];

/// Time labels for a view that ends "now": "−10 s", "−5 s", "now". The step is
/// 1, 2, 5, 10 or 30 seconds, whichever gives at most six labels.
///
/// When the view looks back in time ([backSec] seconds before now) the labels say
/// how far back each point is, and the right edge is no longer "now".
List<TraceTick> liveTicks(double durationSec, {double backSec = 0, String nowLabel = 'now'}) {
  if (durationSec <= 0) return const [];
  final step = [1.0, 2.0, 5.0, 10.0, 30.0].firstWhere((s) => durationSec / s <= 6, orElse: () => 30.0);
  final atNow = backSec < 0.5;
  return [
    for (var back = (durationSec / step).floor() * step; back > 0; back -= step)
      TraceTick(durationSec - back, relativeSeconds(-(back + backSec))),
    TraceTick(durationSec, atNow ? nowLabel : relativeSeconds(-backSec), important: true),
  ];
}

/// The live view: the newest seconds of every signal. An empty snapshot (no
/// packet yet) gives no lanes.
TraceData liveTraceData(
  LiveSnapshot s, {
  double eegScaleUv = kDefaultEegScaleUv,
  bool showMotion = true,
  bool showEeg = true,
  List<TraceMarker> markers = const [],
  double backSec = 0,
  String nowLabel = 'now',
}) {
  if (s.isEmpty || s.eeg.isEmpty) return const TraceData(lanes: [], durationSec: 0);
  final duration = s.durationSec;
  return TraceData(
    lanes: _lanes(
      eeg: s.eeg,
      eegRateHz: s.eegRateHz,
      accelX: s.accelX,
      accelY: s.accelY,
      accelZ: s.accelZ,
      gyroX: s.gyroX,
      gyroY: s.gyroY,
      gyroZ: s.gyroZ,
      imuRateHz: s.imuRateHz,
      eegScaleUv: eegScaleUv,
      showMotion: showMotion,
      showEeg: showEeg,
    ),
    durationSec: duration,
    markers: markers,
    ticks: liveTicks(duration, backSec: backSec, nowLabel: nowLabel),
  );
}

/// Time labels every 5 seconds around an event: "−15 s", "−10 s", "−5 s",
/// "start", "+5 s", ...
List<TraceTick> eventTicks(double durationSec, double preSec) => [
      for (var t = -(preSec / 5).floor() * 5.0; t <= durationSec - preSec + 1e-6; t += 5)
        TraceTick(preSec + t, relativeSeconds(t, zero: 'start'), important: t.abs() < 1e-9),
    ];

/// The review view: the stored window around one event, with the event's own
/// stretch shaded and its start marked.
TraceData windowTraceData(
  SignalWindow w, {
  required double eventDurationSec,
  double eegScaleUv = kDefaultEegScaleUv,
  bool showMotion = true,
  bool showEeg = true,
  List<TraceMarker> markers = const [],
}) {
  final duration = w.durationSec;
  return TraceData(
    lanes: _lanes(
      eeg: w.eeg,
      eegRateHz: w.eegRateHz,
      accelX: w.accelX,
      accelY: w.accelY,
      accelZ: w.accelZ,
      gyroX: w.gyroX,
      gyroY: w.gyroY,
      gyroZ: w.gyroZ,
      imuRateHz: w.imuRateHz,
      eegScaleUv: eegScaleUv,
      showMotion: showMotion,
      showEeg: showEeg,
    ),
    durationSec: duration,
    markers: [TraceMarker(w.preSec, label: 'start', color: AppColors.navy), ...markers],
    spans: eventDurationSec > 0
        ? [TraceSpan(w.preSec, math.min(duration, w.preSec + eventDurationSec), AppColors.accent.withValues(alpha: 0.14))]
        : const [],
    ticks: eventTicks(duration, w.preSec),
  );
}
