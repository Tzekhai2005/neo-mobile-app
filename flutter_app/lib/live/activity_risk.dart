import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../device/device_status.dart';
import 'baseline.dart';
import 'live_signal_buffer.dart';

// EXPERIMENTAL. A demonstration of an "activity risk" readout, not a validated
// seizure detector. It measures how busy the EEG is compared with the wearer's
// own recent normal, and shows that as a number. It has no alarm, never raises
// an event on its own, and movement or a poor electrode can raise it just as a
// real change in the signal can.

/// Accelerometer / gyro variation (over two seconds) above which the wearer is
/// counted as moving. While moving the readout is held down, not raised.
const double kMovementAccelStdG = 0.12;
const double kMovementGyroStdDps = 30;

/// Why the readout shows what it shows.
enum RiskState { noData, noContact, calibrating, ok, movement }

class ActivityRisk {
  /// 0 to 98, or null when there is nothing honest to show.
  final double? percent;
  final RiskState state;

  const ActivityRisk(this.percent, this.state);

  static const none = ActivityRisk(null, RiskState.noData);

  @override
  bool operator ==(Object other) => other is ActivityRisk && other.percent == percent && other.state == state;

  @override
  int get hashCode => Object.hash(percent, state);
}

/// What a signal [ratio] times busier than the wearer's normal reads as, from 6
/// to 98. About normal (up to 0.8 times) is the floor; up to twice normal drifts
/// from 6 to 16, so ordinary variation moves the number a little; beyond that it
/// climbs, reaching its top at six times normal. It never reaches 100.
double riskFromRatio(double ratio) {
  if (ratio.isNaN || ratio <= 0.8) return 6;
  if (ratio <= 2) return 6 + 10 * (ratio - 0.8) / 1.2;
  return 16 + 82 * math.min(1.0, (ratio - 2) / 4);
}

/// How busy the signal is: the mean size of the step from one sample to the next
/// (its "line length"), after the slow baseline is removed, averaged over the
/// channels. Null when too few samples are real (under 80 %) to say.
double? meanLineLength(List<Float32List> channels, int rateHz) {
  if (channels.isEmpty) return null;
  final per = <double>[];
  for (final ch in channels) {
    if (ch.length < 2) continue;
    final v = removeBaseline(ch, rateHz);
    var sum = 0.0;
    var pairs = 0;
    for (var i = 1; i < v.length; i++) {
      if (v[i].isNaN || v[i - 1].isNaN) continue;
      sum += (v[i] - v[i - 1]).abs();
      pairs++;
    }
    if (pairs < (v.length - 1) * 0.8) continue;
    per.add(sum / pairs);
  }
  return per.isEmpty ? null : per.reduce((a, b) => a + b) / per.length;
}

/// How much three axes vary together over the window: the square root of the
/// summed variances. Steady values (gravity, a still device) give about zero; any
/// shaking or turning gives a clear number. Null with too few real samples.
double? _spread(Float32List x, Float32List y, Float32List z) {
  final n = x.length;
  final idx = [for (var i = 0; i < n; i++) if (!x[i].isNaN && !y[i].isNaN && !z[i].isNaN) i];
  if (idx.length < 20) return null;
  double variance(Float32List a) {
    final mean = idx.fold<double>(0, (s, i) => s + a[i]) / idx.length;
    return idx.fold<double>(0, (s, i) => s + (a[i] - mean) * (a[i] - mean)) / idx.length;
  }

  return math.sqrt(variance(x) + variance(y) + variance(z));
}

/// Whether the accelerometer or gyro varied enough to call it movement.
bool isMoving(Float32List ax, Float32List ay, Float32List az, Float32List gx, Float32List gy, Float32List gz) {
  final a = _spread(ax, ay, az);
  final g = _spread(gx, gy, gz);
  return (a != null && a > kMovementAccelStdG) || (g != null && g > kMovementGyroStdDps);
}

/// Turns one line-length value a second into the readout. Pure, so it can be
/// tested without a device or a clock.
class ActivityRiskEngine {
  /// How many seconds of history the baseline is taken from.
  final int historySeconds;

  /// Seconds of history needed before a number is shown.
  final int minSeconds;

  /// Seconds the number takes to follow a change.
  final double smoothingSec;

  final List<double> _history = [];
  double? _shown;

  ActivityRiskEngine({this.historySeconds = 300, this.minSeconds = 20, this.smoothingSec = 3});

  double get _alpha => 1 - math.exp(-1 / smoothingSec);

  /// Call once a second.
  ActivityRisk update({
    required double? lineLength,
    required bool movement,
    required bool contact,
    required bool hasData,
  }) {
    if (!hasData || lineLength == null) return const ActivityRisk(null, RiskState.noData);
    if (!contact) return const ActivityRisk(null, RiskState.noContact);

    if (movement) {
      // Movement makes the EEG look busy for a reason that is not the brain: the
      // number is eased back toward the floor and the baseline is not touched.
      final s = _shown;
      if (s == null) return const ActivityRisk(null, RiskState.movement);
      _shown = s + (6 - s) * _alpha;
      return ActivityRisk(_shown, RiskState.movement);
    }

    _history.add(lineLength);
    if (_history.length > historySeconds) _history.removeAt(0);
    if (_history.length < minSeconds) return const ActivityRisk(null, RiskState.calibrating);

    final sorted = [..._history]..sort();
    final median = sorted[sorted.length ~/ 2];
    if (median <= 0) return const ActivityRisk(null, RiskState.calibrating);
    final target = riskFromRatio(lineLength / median);
    final s = _shown;
    _shown = s == null ? target : s + (target - s) * _alpha;
    return ActivityRisk(_shown, RiskState.ok);
  }

  /// Forget everything (a new wearer, or a new session).
  void reset() {
    _history.clear();
    _shown = null;
  }
}

/// Runs the engine once a second on the live buffer, for as long as the app lives,
/// so the baseline keeps learning while another page is open.
class ActivityRiskMonitor extends ValueNotifier<ActivityRisk> {
  final LiveSignalBuffer _buffer;
  final ValueListenable<DeviceStatus> _status;
  final ActivityRiskEngine _engine;
  Timer? _timer;
  int _streamId = -1;

  ActivityRiskMonitor({
    required LiveSignalBuffer buffer,
    required ValueListenable<DeviceStatus> status,
    ActivityRiskEngine? engine,
  })  : _buffer = buffer,
        _status = status,
        _engine = engine ?? ActivityRiskEngine(),
        super(ActivityRisk.none);

  void start() => _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => step());

  /// One reading. Public so tests can drive it without waiting.
  void step() {
    final s = _status.value;
    if (_buffer.streamId != _streamId) {
      // A new stream is a new session: learn the baseline again.
      _streamId = _buffer.streamId;
      _engine.reset();
    }
    if (s.link != LinkState.connected || !_buffer.hasData) {
      value = _engine.update(lineLength: null, movement: false, contact: true, hasData: false);
      return;
    }
    final snap = _buffer.snapshot(seconds: 2);
    value = _engine.update(
      lineLength: meanLineLength(snap.eeg, snap.eegRateHz),
      movement: isMoving(snap.accelX, snap.accelY, snap.accelZ, snap.gyroX, snap.gyroY, snap.gyroZ),
      contact: s.leadOff != true,
      hasData: true,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
