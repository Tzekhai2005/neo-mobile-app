import 'dart:typed_data';

import 'review_event.dart';

/// A span of recording time, in seconds from the recording start.
class TimeRange {
  final double startSec;
  final double endSec;
  const TimeRange(this.startSec, this.endSec);

  double get lengthSec => endSec - startSec;
  bool contains(double sec) => sec >= startSec && sec < endSec;
}

/// What the Review and Report pages need to know about the recording as a whole.
class RecordingInfo {
  final DateTime startUtc;
  final int utcOffsetMinutes;
  final int durationSec;
  final int eegRateHz;
  final int eegChannels;
  final int imuRateHz;
  final bool synthetic;
  final String generator;
  final String datasetKey;

  const RecordingInfo({
    required this.startUtc,
    required this.utcOffsetMinutes,
    required this.durationSec,
    required this.eegRateHz,
    required this.eegChannels,
    required this.imuRateHz,
    required this.synthetic,
    required this.generator,
    required this.datasetKey,
  });

  /// Wall-clock time (local to the recording site) at `sec` after the start.
  DateTime localTimeAt(double sec) =>
      startUtc.add(Duration(minutes: utcOffsetMinutes, milliseconds: (sec * 1000).round()));

  /// Night is 23:00–07:00 local.
  bool isNight(double sec) {
    final h = localTimeAt(sec).hour;
    return h >= 23 || h < 7;
  }
}

/// A view of the recording's overview, merged down to at most `maxBins` bins.
class OverviewBins {
  final double binSec;
  final double startSec;
  final int count;
  final List<Float32List> eegMin; // per channel, µV
  final List<Float32List> eegMax;
  final Float32List activity; // mean, 0..1
  final Float32List quality; // worst bin in the group, 0..1

  const OverviewBins({
    required this.binSec,
    required this.startSec,
    required this.count,
    required this.eegMin,
    required this.eegMax,
    required this.activity,
    required this.quality,
  });
}

/// The full-rate signals around one event, in physical units.
class SignalWindow {
  final String eventId;
  final int startSample; // EEG sample index of the first sample
  final int eegRateHz;
  final int imuRateHz;
  final double preSec; // the event starts this far into the window
  final List<Float32List> eeg; // per channel, µV
  final Float32List accelX, accelY, accelZ; // g
  final Float32List gyroX, gyroY, gyroZ; // °/s

  const SignalWindow({
    required this.eventId,
    required this.startSample,
    required this.eegRateHz,
    required this.imuRateHz,
    required this.preSec,
    required this.eeg,
    required this.accelX,
    required this.accelY,
    required this.accelZ,
    required this.gyroX,
    required this.gyroY,
    required this.gyroZ,
  });

  int get channels => eeg.length;
  double get durationSec => eeg.first.length / eegRateHz;
}

/// Where Review and Report get their data. The bundled demo recording implements
/// it today; a live recorder can implement it later without touching the pages.
abstract class RecordingSource {
  /// Must complete before any other member is used.
  Future<void> load();

  RecordingInfo get info;

  /// The overview for `range`, merged to at most `maxBins` bins.
  OverviewBins overview(TimeRange range, int maxBins);

  /// Events starting inside `range` (all, when null), oldest first.
  /// `minConfidence` filters automatic events only; patient markers always pass.
  List<RecordedEvent> events({TimeRange? range, double minConfidence = 0});

  Future<SignalWindow> eventWindow(String eventId);
}
