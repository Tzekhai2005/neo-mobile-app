import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/data/static_recording_source.dart';
import 'package:neo_companion/report/report_builder.dart';
import 'package:neo_companion/report/report_csv.dart';
import 'package:neo_companion/report/report_exporter.dart';
import 'package:neo_companion/report/report_models.dart';
import 'package:neo_companion/report/report_selection.dart';
import 'package:neo_companion/data/review_store.dart';

const mini = 'test/fixtures/mini_recording';

Future<ReportData> sampleReport({DateTime? at, bool empty = false}) async {
  final src = StaticRecordingSource(DirectoryDatasetReader(mini));
  await src.load();
  final tmp = Directory.systemTemp.createTempSync('neo_exp_src_');
  addTearDown(() => tmp.deleteSync(recursive: true));
  final store = ReviewStore(File('${tmp.path}/d.json'), datasetKey: src.info.datasetKey);
  await store.load();
  final events = store.merge(src.events());
  return ReportBuilder.build(
    source: src,
    events: events,
    selection: empty ? const ReportSelection({}) : ReportSelection.defaultFor(events),
    generatedAtUtc: at ?? DateTime.utc(2026, 10, 7, 9, 30),
  );
}

class FakeSharer implements FileSharer {
  final calls = <(List<String>, String?)>[];
  @override
  Future<void> share(List<File> files, {String? subject}) async =>
      calls.add(([for (final f in files) f.path], subject));
}

void main() {
  late Directory out;
  setUp(() => out = Directory.systemTemp.createTempSync('neo_exp_out_'));
  tearDown(() => out.deleteSync(recursive: true));

  test('the folder is named from the time the report was generated', () {
    expect(ReportExporter.folderName(DateTime.utc(2026, 10, 7, 9, 30, 5)), 'report-20261007-093005');
    expect(ReportExporter.folderName(DateTime.utc(2026, 1, 2, 3, 4, 5)), 'report-20260102-030405');
  });

  test('writes a PDF and a zip holding exactly the CSV files', () async {
    final data = await sampleReport();
    final r = await ReportExporter(outputDir: out).export(data);

    expect(r.dir.path, endsWith('report-20261007-093000'));
    expect(r.pdf.path, endsWith('epile-x-eeg-report-20261005.pdf'));
    expect(r.csvZip.path, endsWith('epile-x-eeg-report-20261005-data.zip'));
    expect(r.pdf.parent.path, r.dir.path);
    expect(r.csvZip.parent.path, r.dir.path);

    final pdf = await r.pdf.readAsBytes();
    expect(latin1.decode(pdf.sublist(0, 5)), '%PDF-');
    expect(pdf.length, greaterThan(10 * 1024));

    final want = reportCsvFiles(data);
    expect(r.csvFileCount, want.length);
    final zip = ZipDecoder().decodeBytes(await r.csvZip.readAsBytes());
    final got = {for (final f in zip.files.where((f) => f.isFile)) f.name: utf8.decode(f.content)};
    expect(got.keys.toSet(), {for (final k in want.keys) 'csv/$k'});
    for (final e in want.entries) {
      expect(got['csv/${e.key}'], e.value, reason: e.key);
    }
    expect(got['csv/events.csv'], eventsCsv(data));
  });

  test('a report with no events still exports, with only events.csv in the zip', () async {
    final r = await ReportExporter(outputDir: out).export(await sampleReport(empty: true));
    expect(r.csvFileCount, 1);
    final zip = ZipDecoder().decodeBytes(await r.csvZip.readAsBytes());
    expect(zip.files.map((f) => f.name), ['csv/events.csv']);
  });

  test('different exports go to different folders; the output folder is created if missing', () async {
    final exporter = ReportExporter(outputDir: Directory('${out.path}/deep/reports'));
    final a = await exporter.export(await sampleReport(at: DateTime.utc(2026, 10, 7, 9, 30, 0)));
    final b = await exporter.export(await sampleReport(at: DateTime.utc(2026, 10, 7, 9, 30, 1)));
    expect(a.dir.path, isNot(b.dir.path));
    expect(a.pdf.existsSync() && b.pdf.existsSync(), isTrue, reason: 'the second export did not touch the first');
  });

  test('sharing hands over the PDF and the zip, once, with a subject', () async {
    final sharer = FakeSharer();
    final data = await sampleReport();
    final r = await ReportExporter(outputDir: out, sharer: sharer).export(data, share: true);
    expect(sharer.calls.length, 1);
    expect(sharer.calls.single.$1, [r.pdf.path, r.csvZip.path]);
    expect(sharer.calls.single.$2, 'Epile-X EEG review report');
  });

  test('without share: true nothing is shared', () async {
    final sharer = FakeSharer();
    await ReportExporter(outputDir: out, sharer: sharer).export(await sampleReport());
    expect(sharer.calls, isEmpty);
  });

  test('asking to share with no sharer is a programming error, caught before anything is written', () async {
    final data = await sampleReport();
    await expectLater(ReportExporter(outputDir: out).export(data, share: true), throwsStateError);
    expect(out.listSync(), isEmpty);
  });

  test('a storage problem becomes a ReportExportException', () async {
    final notADirectory = File('${out.path}/a_file')..writeAsStringSync('x');
    final exporter = ReportExporter(outputDir: Directory(notADirectory.path));
    await expectLater(exporter.export(await sampleReport()), throwsA(isA<ReportExportException>()));
  });
}
