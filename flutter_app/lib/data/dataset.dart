import 'dart:convert';
import 'dart:typed_data';

import 'review_event.dart';

/// A dataset folder is malformed or not a version this app understands.
class DatasetFormatException implements Exception {
  final String message;
  const DatasetFormatException(this.message);

  @override
  String toString() => 'DatasetFormatException: $message';
}

/// Reads the files of one dataset folder. Implementations: a directory on disk
/// and bundled assets (see dataset_readers.dart).
abstract class DatasetReader {
  Future<String> readString(String name);
  Future<int> length(String name);
  Future<Uint8List> readRange(String name, int offset, int length);
}

class EegSpec {
  final int rateHz;
  final int channels;
  final double uvPerCount;
  const EegSpec(this.rateHz, this.channels, this.uvPerCount);
}

class ImuSpec {
  final int rateHz;
  final double gPerCount;
  final double dpsPerCount;
  const ImuSpec(this.rateHz, this.gPerCount, this.dpsPerCount);
}

class DatasetManifest {
  static const int supportedVersion = 1;

  final bool synthetic;
  final String generator;
  final int seed;
  final DateTime startUtc;
  final int utcOffsetMinutes;
  final int durationSec;
  final EegSpec eeg;
  final ImuSpec imu;
  final List<RecordedEvent> events; // sorted by startSample

  const DatasetManifest({
    required this.synthetic,
    required this.generator,
    required this.seed,
    required this.startUtc,
    required this.utcOffsetMinutes,
    required this.durationSec,
    required this.eeg,
    required this.imu,
    required this.events,
  });

  /// Identifies this recording, so reviewer decisions are never applied to a
  /// different dataset that happens to reuse the same event ids.
  String get key => '$generator|$seed|${startUtc.toIso8601String()}|$durationSec|${events.length}';

  /// Samples stored per signal in every event window.
  int eegWindowSamples(EventWindowRef w) => (eeg.rateHz * w.durationSec).round();
  int imuWindowSamples(EventWindowRef w) => (imu.rateHz * w.durationSec).round();

  int expectedWindowBytes(EventWindowRef w) =>
      (eeg.channels * eegWindowSamples(w) + 6 * imuWindowSamples(w)) * 2;

  static DatasetManifest fromJson(Map<String, dynamic> j) {
    T need<T>(Map<String, dynamic> m, String k) {
      final v = m[k];
      if (v is! T) throw DatasetFormatException('manifest: "$k" missing or not a ${T.toString()}');
      return v;
    }

    final version = need<num>(j, 'formatVersion').toInt();
    if (version != supportedVersion) {
      throw DatasetFormatException('formatVersion $version is not supported (expected $supportedVersion)');
    }
    final eegJ = need<Map<String, dynamic>>(j, 'eeg');
    final imuJ = need<Map<String, dynamic>>(j, 'imu');
    final eeg = EegSpec(
      need<num>(eegJ, 'rateHz').toInt(),
      need<num>(eegJ, 'channels').toInt(),
      need<num>(eegJ, 'uvPerCount').toDouble(),
    );
    if (eeg.channels < 2 || eeg.channels > 4) {
      throw DatasetFormatException('eeg.channels must be 2..4, got ${eeg.channels}');
    }
    final imu = ImuSpec(
      need<num>(imuJ, 'rateHz').toInt(),
      need<num>(imuJ, 'gPerCount').toDouble(),
      need<num>(imuJ, 'dpsPerCount').toDouble(),
    );

    final events = <RecordedEvent>[];
    for (final raw in need<List<dynamic>>(j, 'events')) {
      final e = raw as Map<String, dynamic>;
      final w = need<Map<String, dynamic>>(e, 'window');
      final sourceName = need<String>(e, 'source');
      final source = EventSource.values.where((s) => s.name == sourceName).firstOrNull;
      if (source == null) throw DatasetFormatException('event ${e['id']}: unknown source "$sourceName"');
      events.add(RecordedEvent(
        id: need<String>(e, 'id'),
        source: source,
        startSample: need<num>(e, 'startSample').toInt(),
        durationSamples: need<num>(e, 'durationSamples').toInt(),
        confidence: (e['confidence'] as num?)?.toDouble(),
        channels: (need<List<dynamic>>(e, 'channels')).map((c) => (c as num).toInt()).toList(growable: false),
        quality: need<num>(e, 'quality').toDouble(),
        truth: e['truth'] as String?,
        window: EventWindowRef(
          offset: need<num>(w, 'offset').toInt(),
          length: need<num>(w, 'length').toInt(),
          preSec: need<num>(w, 'preSec').toDouble(),
          postSec: need<num>(w, 'postSec').toDouble(),
        ),
      ));
    }
    events.sort((a, b) => a.startSample.compareTo(b.startSample));

    return DatasetManifest(
      synthetic: j['synthetic'] == true,
      generator: (j['generator'] as String?) ?? 'unknown',
      seed: (j['seed'] as num?)?.toInt() ?? 0,
      startUtc: DateTime.parse(need<String>(j, 'startUtc')).toUtc(),
      utcOffsetMinutes: need<num>(j, 'utcOffsetMinutes').toInt(),
      durationSec: need<num>(j, 'durationSec').toInt(),
      eeg: eeg,
      imu: imu,
      events: events,
    );
  }
}

/// One bin per `binSec` seconds: EEG envelope per channel, movement, quality.
class OverviewData {
  final int binSec;
  final int bins;
  final List<Float32List> eegMin; // per channel, µV
  final List<Float32List> eegMax;
  final Float32List activity; // 0..1
  final Float32List quality; // 0..1

  const OverviewData({
    required this.binSec,
    required this.bins,
    required this.eegMin,
    required this.eegMax,
    required this.activity,
    required this.quality,
  });

  static Float32List _floats(Object? v, int expected, String name) {
    if (v is! List || v.length != expected) {
      throw DatasetFormatException('overview: "$name" must be a list of $expected numbers');
    }
    return Float32List.fromList(v.map((e) => (e as num).toDouble()).toList());
  }

  static OverviewData fromJson(Map<String, dynamic> j, int channels, int durationSec) {
    final binSec = (j['binSec'] as num?)?.toInt() ?? 0;
    if (binSec <= 0) throw const DatasetFormatException('overview: binSec missing');
    final bins = durationSec ~/ binSec;
    if ((j['bins'] as num?)?.toInt() != bins) {
      throw DatasetFormatException('overview: bins does not match durationSec / binSec ($bins)');
    }
    List<Float32List> perChannel(String name) {
      final raw = j[name];
      if (raw is! List || raw.length != channels) {
        throw DatasetFormatException('overview: "$name" must have $channels channels');
      }
      return [for (final c in raw) _floats(c, bins, name)];
    }

    return OverviewData(
      binSec: binSec,
      bins: bins,
      eegMin: perChannel('eegMin'),
      eegMax: perChannel('eegMax'),
      activity: _floats(j['activity'], bins, 'activity'),
      quality: _floats(j['quality'], bins, 'quality'),
    );
  }
}

/// A dataset folder, loaded and validated.
class Dataset {
  static const manifestFile = 'manifest.json';
  static const overviewFile = 'overview.json';
  static const windowsFile = 'windows.bin';

  final DatasetManifest manifest;
  final OverviewData overview;
  final DatasetReader reader;

  const Dataset(this.manifest, this.overview, this.reader);

  static Future<Dataset> load(DatasetReader reader) async {
    final Map<String, dynamic> manifestJson;
    final Map<String, dynamic> overviewJson;
    try {
      manifestJson = jsonDecode(await reader.readString(manifestFile)) as Map<String, dynamic>;
      overviewJson = jsonDecode(await reader.readString(overviewFile)) as Map<String, dynamic>;
    } on FormatException catch (e) {
      throw DatasetFormatException('not valid JSON: ${e.message}');
    }
    final manifest = DatasetManifest.fromJson(manifestJson);
    final overview = OverviewData.fromJson(overviewJson, manifest.eeg.channels, manifest.durationSec);

    final size = await reader.length(windowsFile);
    final ids = <String>{};
    for (final e in manifest.events) {
      if (!ids.add(e.id)) throw DatasetFormatException('duplicate event id ${e.id}');
      final w = e.window;
      if (w.length != manifest.expectedWindowBytes(w)) {
        throw DatasetFormatException(
            'event ${e.id}: window is ${w.length} bytes, expected ${manifest.expectedWindowBytes(w)}');
      }
      if (w.offset < 0 || w.offset + w.length > size) {
        throw DatasetFormatException('event ${e.id}: window lies outside $windowsFile');
      }
    }
    return Dataset(manifest, overview, reader);
  }
}
