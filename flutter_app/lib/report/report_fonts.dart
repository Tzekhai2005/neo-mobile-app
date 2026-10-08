import 'dart:io';
import 'dart:typed_data';

/// The four font faces the report is set in (Noto Sans, SIL Open Font Licence;
/// the licence text ships in assets/fonts/OFL.txt). Plain bytes, so they can be
/// handed to another isolate.
///
/// Noto Sans covers Latin (including Malay, Vietnamese and accented European
/// letters), Greek and Cyrillic. It does not cover Chinese, Japanese, Korean,
/// Arabic, Tamil or Thai; the report prints "?" for those.
class ReportFonts {
  final Uint8List regular;
  final Uint8List bold;
  final Uint8List italic;
  final Uint8List boldItalic;

  const ReportFonts({
    required this.regular,
    required this.bold,
    required this.italic,
    required this.boldItalic,
  });

  /// File names inside the font folder, in the order regular, bold, italic, bold italic.
  static const List<String> fileNames = [
    'NotoSans-Regular.ttf',
    'NotoSans-Bold.ttf',
    'NotoSans-Italic.ttf',
    'NotoSans-BoldItalic.ttf',
  ];

  /// Reads the four faces from a folder (used by tests and command-line tools).
  static Future<ReportFonts> fromDirectory(String dir) async {
    final b = [for (final n in fileNames) await File('$dir/$n').readAsBytes()];
    return ReportFonts(regular: b[0], bold: b[1], italic: b[2], boldItalic: b[3]);
  }
}
