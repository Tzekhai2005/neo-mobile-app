import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show compute;

import 'report_csv.dart';
import 'report_models.dart';
import 'report_pdf.dart';

/// Hands finished files to the platform (the phone's share sheet).
abstract class FileSharer {
  Future<void> share(List<File> files, {String? subject});
}

/// The report could not be written to storage.
class ReportExportException implements Exception {
  final String message;
  const ReportExportException(this.message);

  @override
  String toString() => 'ReportExportException: $message';
}

/// Files written by one export.
class ExportedReport {
  final Directory dir;
  final File pdf;
  final File csvZip;

  /// Number of CSV files inside [csvZip].
  final int csvFileCount;

  const ExportedReport({required this.dir, required this.pdf, required this.csvZip, required this.csvFileCount});
}

/// Top-level so `compute` can run it in another isolate.
Future<Uint8List> _drawPdf(ReportData data) => ReportPdf.build(data);

/// Writes a report as a PDF plus one zip of CSV files, and optionally shares both.
class ReportExporter {
  final Directory outputDir;
  final FileSharer? sharer;

  const ReportExporter({required this.outputDir, this.sharer});

  /// `report-20261007-093000`: from the time the report was generated, so two
  /// exports never overwrite each other.
  static String folderName(DateTime generatedAtUtc) {
    String two(int n) => n.toString().padLeft(2, '0');
    final t = generatedAtUtc.toUtc();
    return 'report-${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  /// Writes `<outputDir>/report-YYYYMMDD-HHMMSS/` with the PDF and the CSV zip.
  /// With `share: true` it then opens the share sheet with both files (a
  /// [sharer] must have been given); the files stay on disk either way.
  Future<ExportedReport> export(ReportData data, {bool share = false}) async {
    if (share && sharer == null) {
      throw StateError('share was requested but this exporter has no FileSharer');
    }
    final dir = Directory('${outputDir.path}/${folderName(data.header.generatedAtUtc)}');
    final File pdf;
    final File zip;
    final int csvCount;
    try {
      await dir.create(recursive: true);

      // Drawing the pages is the slow part, so it runs off the UI isolate.
      final pdfBytes = await compute(_drawPdf, data);
      final pdfName = ReportPdf.suggestedFileName(data);
      pdf = File('${dir.path}/$pdfName');
      await pdf.writeAsBytes(pdfBytes, flush: true);

      final csv = reportCsvFiles(data);
      csvCount = csv.length;
      final archive = Archive();
      csv.forEach((name, text) => archive.add(ArchiveFile.string('csv/$name', text)));
      zip = File('${dir.path}/${pdfName.replaceAll(RegExp(r'\.pdf$'), '')}-data.zip');
      await zip.writeAsBytes(ZipEncoder().encodeBytes(archive), flush: true);
    } on FileSystemException catch (e) {
      throw ReportExportException('Could not write the report to ${e.path ?? outputDir.path}: ${e.message}');
    }

    if (share) {
      await sharer!.share([pdf, zip], subject: '${data.header.brand} EEG review report');
    }
    return ExportedReport(dir: dir, pdf: pdf, csvZip: zip, csvFileCount: csvCount);
  }
}
