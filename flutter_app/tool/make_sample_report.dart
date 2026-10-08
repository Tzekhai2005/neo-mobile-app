// Builds a sample report (PDF + CSV files) from a dataset folder.
//
//   dart --packages=.dart_tool/package_config.json tool/make_sample_report.dart [dataset] [out]
//   (defaults: assets/demo_recording  ->  build/sample_report)
//
// Add --raw for an uncompressed PDF, --builtin-fonts for the standard PDF fonts instead of Noto Sans.
// Add --days=2 or --days=2-3 (1-based) to cover only those days of the recording.
// Add --demo-review to confirm the highest-confidence events and add two example
// notes first, so the sample shows a reviewed report. Those decisions are made up.
import 'dart:io';

import 'package:neo_companion/data/dataset_directory_reader.dart';
import 'package:neo_companion/data/review_event.dart';
import 'package:neo_companion/data/review_store.dart';
import 'package:neo_companion/data/static_recording_source.dart';
import 'package:neo_companion/report/report_builder.dart';
import 'package:neo_companion/report/report_csv.dart';
import 'package:neo_companion/report/report_fonts.dart';
import 'package:neo_companion/report/report_models.dart';
import 'package:neo_companion/report/report_pdf.dart';
import 'package:neo_companion/report/report_selection.dart';

Future<void> main(List<String> args) async {
  final demo = args.contains('--demo-review');
  final paths = args.where((a) => !a.startsWith('--')).toList();
  final dataset = paths.isNotEmpty ? paths[0] : 'assets/demo_recording';
  final out = Directory(paths.length > 1 ? paths[1] : 'build/sample_report')..createSync(recursive: true);

  final source = StaticRecordingSource(DirectoryDatasetReader(dataset));
  await source.load();

  final tmp = Directory.systemTemp.createTempSync('neo_sample_');
  final store = ReviewStore(File('${tmp.path}/decisions.json'), datasetKey: source.info.datasetKey);
  await store.load();
  if (demo) {
    final auto = source.events().where((e) => e.source == EventSource.auto).toList()
      ..sort((a, b) => (b.confidence ?? 0).compareTo(a.confidence ?? 0));
    for (final e in auto.take(4)) {
      await store.setStatus(e.id, ReviewStatus.confirmed);
    }
    if (auto.isNotEmpty) {
      await store.setNote(auto[0].id, 'Rhythmic 3 Hz activity, patient unresponsive for about 10 s per carer. Matches clinical description.');
    }
    if (auto.length > 2) {
      await store.setNote(auto[2].id, 'Consistent with the other events, though the carer reports less movement.');
    }
    if (auto.length > 4) await store.setStatus(auto[4].id, ReviewStatus.dismissed);
  }
  final events = store.merge(source.events());

  DayRange? days;
  final daysArg = args.where((a) => a.startsWith('--days=')).firstOrNull?.substring(7);
  if (daysArg != null) {
    final p = daysArg.split('-').map(int.parse).toList();
    days = DayRange(p.first - 1, p.last - 1);
  }
  final rate = source.info.eegRateHz;
  final inDays = days == null
      ? events
      : [
          for (final r in events)
            if (r.event.startSec(rate) >= days.startSec && r.event.startSec(rate) < (days.last + 1) * 86400.0) r
        ];

  final data = await ReportBuilder.build(
    source: source,
    events: events,
    days: days,
    selection: ReportSelection.defaultFor(inDays),
    generatedAtUtc: DateTime.now().toUtc(),
    device: const ReportDevice(name: 'neo-A', serial: 'A0B1C2D3E4F5', firmware: '0.1.0'),
    patientLabel: demo ? 'Demo patient' : null,
  );

  // Noto Sans by default; --builtin-fonts uses the standard PDF fonts (Latin-1 only).
  final fonts = args.contains('--builtin-fonts') ? null : await ReportFonts.fromDirectory('assets/fonts');
  final pdf = await ReportPdf.build(data, compress: !args.contains('--raw'), fonts: fonts);
  final file = File('${out.path}/${ReportPdf.suggestedFileName(data)}')..writeAsBytesSync(pdf);
  stdout.writeln('${file.path}  (${(pdf.length / 1024).round()} KB, ${data.entries.length} events)');
  final csvDir = Directory('${out.path}/csv')..createSync();
  reportCsvFiles(data).forEach((name, text) => File('${csvDir.path}/$name').writeAsStringSync(text));
  stdout.writeln('${csvDir.path}  (${reportCsvFiles(data).length} files)');
  tmp.deleteSync(recursive: true);
}
