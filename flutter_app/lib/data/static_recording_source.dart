import 'dart:math' as math;
import 'dart:typed_data';

import 'dataset.dart';
import 'recording_source.dart';
import 'review_event.dart';

/// A [RecordingSource] over a dataset folder (see tools/make_demo_dataset.py).
class StaticRecordingSource implements RecordingSource {
  final DatasetReader _reader;
  Dataset? _dataset;

  StaticRecordingSource(this._reader);

  Dataset get _ds {
    final d = _dataset;
    if (d == null) throw StateError('call load() first');
    return d;
  }

  @override
  Future<void> load() async {
    _dataset = await Dataset.load(_reader);
  }

  @override
  RecordingInfo get info {
    final m = _ds.manifest;
    return RecordingInfo(
      startUtc: m.startUtc,
      utcOffsetMinutes: m.utcOffsetMinutes,
      durationSec: m.durationSec,
      eegRateHz: m.eeg.rateHz,
      eegChannels: m.eeg.channels,
      imuRateHz: m.imu.rateHz,
      synthetic: m.synthetic,
      generator: m.generator,
      datasetKey: m.key,
    );
  }

  @override
  OverviewBins overview(TimeRange range, int maxBins) {
    if (maxBins < 1) throw ArgumentError.value(maxBins, 'maxBins', 'must be >= 1');
    final o = _ds.overview;
    final first = (range.startSec / o.binSec).floor().clamp(0, o.bins);
    final last = (range.endSec / o.binSec).ceil().clamp(first, o.bins);
    final n = last - first;
    final group = n <= maxBins ? 1 : (n / maxBins).ceil();
    final count = n == 0 ? 0 : (n / group).ceil();
    final channels = o.eegMin.length;

    final eegMin = [for (var c = 0; c < channels; c++) Float32List(count)];
    final eegMax = [for (var c = 0; c < channels; c++) Float32List(count)];
    final activity = Float32List(count);
    final quality = Float32List(count);

    for (var i = 0; i < count; i++) {
      final from = first + i * group;
      final to = math.min(from + group, last);
      for (var c = 0; c < channels; c++) {
        var lo = o.eegMin[c][from];
        var hi = o.eegMax[c][from];
        for (var b = from + 1; b < to; b++) {
          lo = math.min(lo, o.eegMin[c][b]);
          hi = math.max(hi, o.eegMax[c][b]);
        }
        eegMin[c][i] = lo;
        eegMax[c][i] = hi;
      }
      var act = 0.0;
      var worst = 1.0;
      for (var b = from; b < to; b++) {
        act += o.activity[b];
        worst = math.min(worst, o.quality[b]); // keep low-quality stretches visible
      }
      activity[i] = act / (to - from);
      quality[i] = worst;
    }

    return OverviewBins(
      binSec: (o.binSec * group).toDouble(),
      startSec: (first * o.binSec).toDouble(),
      count: count,
      eegMin: eegMin,
      eegMax: eegMax,
      activity: activity,
      quality: quality,
    );
  }

  @override
  List<RecordedEvent> events({TimeRange? range, double minConfidence = 0}) {
    final rate = _ds.manifest.eeg.rateHz;
    return [
      for (final e in _ds.manifest.events)
        if ((range == null || range.contains(e.startSec(rate))) &&
            (e.confidence == null || e.confidence! >= minConfidence))
          e,
    ];
  }

  @override
  Future<SignalWindow> eventWindow(String eventId) async {
    final m = _ds.manifest;
    final event = m.events.where((e) => e.id == eventId).firstOrNull;
    if (event == null) throw ArgumentError.value(eventId, 'eventId', 'unknown event');
    final w = event.window;
    final bytes = await _reader.readRange(Dataset.windowsFile, w.offset, w.length);
    final bd = ByteData.sublistView(bytes);

    final eegN = m.eegWindowSamples(w);
    final imuN = m.imuWindowSamples(w);
    var pos = 0;
    Float32List take(int n, double scale) {
      final out = Float32List(n);
      for (var i = 0; i < n; i++) {
        out[i] = bd.getInt16(pos, Endian.little) * scale;
        pos += 2;
      }
      return out;
    }

    final eeg = [for (var c = 0; c < m.eeg.channels; c++) take(eegN, m.eeg.uvPerCount)];
    return SignalWindow(
      eventId: eventId,
      startSample: event.startSample - (w.preSec * m.eeg.rateHz).round(),
      eegRateHz: m.eeg.rateHz,
      imuRateHz: m.imu.rateHz,
      preSec: w.preSec,
      eeg: eeg,
      accelX: take(imuN, m.imu.gPerCount),
      accelY: take(imuN, m.imu.gPerCount),
      accelZ: take(imuN, m.imu.gPerCount),
      gyroX: take(imuN, m.imu.dpsPerCount),
      gyroY: take(imuN, m.imu.dpsPerCount),
      gyroZ: take(imuN, m.imu.dpsPerCount),
    );
  }
}
