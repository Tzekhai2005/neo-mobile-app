import 'package:flutter/services.dart' show rootBundle;

import 'report_fonts.dart';

/// Where the fonts are bundled (declared under `assets:` in pubspec.yaml).
const String kReportFontAssetDir = 'assets/fonts';

/// Loads the report fonts bundled with the app.
Future<ReportFonts> loadReportFontsFromAssets() async {
  final b = [
    for (final n in ReportFonts.fileNames)
      (await rootBundle.load('$kReportFontAssetDir/$n')).buffer.asUint8List(),
  ];
  return ReportFonts(regular: b[0], bold: b[1], italic: b[2], boldItalic: b[3]);
}
