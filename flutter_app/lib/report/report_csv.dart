import 'report_models.dart';

/// One CSV field, quoted when it contains a comma, quote or line break.
String csvField(String s) =>
    (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r')) ? '"${s.replaceAll('"', '""')}"' : s;

String _row(Iterable<Object?> fields) => fields.map((f) => csvField(f?.toString() ?? '')).join(',');

String _two(int n) => n.toString().padLeft(2, '0');

/// Site-local wall-clock time as ISO 8601 with its offset, e.g. 2026-10-05T08:03:12+08:00.
String formatLocalIso(DateTime local, int utcOffsetMinutes) {
  final sign = utcOffsetMinutes < 0 ? '-' : '+';
  final off = utcOffsetMinutes.abs();
  return '${local.year.toString().padLeft(4, '0')}-${_two(local.month)}-${_two(local.day)}'
      'T${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}'
      '$sign${_two(off ~/ 60)}:${_two(off % 60)}';
}

String _num(double v, int digits) => v.isNaN ? '' : v.toStringAsFixed(digits);

/// One row per event in the report: when, what, and what the reviewer decided.
String eventsCsv(ReportData data) {
  final b = StringBuffer(_row([
    'event_id', 'source', 'status', 'start_local', 'start_sec', 'duration_sec',
    'confidence', 'night', 'quality', 'channels', 'note',
  ]))..write('\n');
  for (final e in data.entries) {
    b.write(_row([
      e.event.id,
      e.event.source.name,
      e.review.status.name,
      formatLocalIso(e.startLocal, data.header.utcOffsetMinutes),
      _num(e.startSec, 3),
      _num(e.durationSec, 3),
      e.event.confidence == null ? '' : _num(e.event.confidence!, 3),
      e.night ? 'yes' : 'no',
      _num(e.event.quality, 3),
      e.event.channels.map((c) => c + 1).join(' '),
      e.review.note ?? '',
    ]));
    b.write('\n');
  }
  return b.toString();
}

/// The EEG of one event: a row per sample, time relative to the event start.
String eegCsv(ReportEntry entry) {
  final w = entry.window;
  final b = StringBuffer(_row([
    'sample_index', 't_rel_s',
    for (var c = 0; c < w.channels; c++) 'ch${c + 1}_uV',
  ]))..write('\n');
  final n = w.eeg.first.length;
  for (var i = 0; i < n; i++) {
    b.write(w.startSample + i);
    b.write(',');
    b.write(_num(i / w.eegRateHz - w.preSec, 3));
    for (var c = 0; c < w.channels; c++) {
      b.write(',');
      b.write(_num(w.eeg[c][i], 1));
    }
    b.write('\n');
  }
  return b.toString();
}

/// The accelerometer and gyro of one event, at the motion sensor's own rate.
String motionCsv(ReportEntry entry) {
  final w = entry.window;
  final b = StringBuffer(_row(['imu_index', 't_rel_s', 'ax_g', 'ay_g', 'az_g', 'gx_dps', 'gy_dps', 'gz_dps']))
    ..write('\n');
  final firstImu = (w.startSample * w.imuRateHz / w.eegRateHz).round();
  for (var i = 0; i < w.accelX.length; i++) {
    b
      ..write(firstImu + i)
      ..write(',')
      ..write(_num(i / w.imuRateHz - w.preSec, 3))
      ..write(',')
      ..write(_num(w.accelX[i], 5))
      ..write(',')
      ..write(_num(w.accelY[i], 5))
      ..write(',')
      ..write(_num(w.accelZ[i], 5))
      ..write(',')
      ..write(_num(w.gyroX[i], 2))
      ..write(',')
      ..write(_num(w.gyroY[i], 2))
      ..write(',')
      ..write(_num(w.gyroZ[i], 2))
      ..write('\n');
  }
  return b.toString();
}

/// Every CSV file of the report, by file name: events.csv plus, for each event,
/// `<id>_eeg.csv` and `<id>_motion.csv`.
Map<String, String> reportCsvFiles(ReportData data) => {
      'events.csv': eventsCsv(data),
      for (final e in data.entries) ...{
        '${e.event.id}_eeg.csv': eegCsv(e),
        '${e.event.id}_motion.csv': motionCsv(e),
      },
    };
