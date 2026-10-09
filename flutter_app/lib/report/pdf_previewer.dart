import 'dart:typed_data';

import 'package:printing/printing.dart';

import 'report_choice.dart';

/// One page of a PDF as a picture.
class PreviewPage {
  final Uint8List png;
  final double aspect; // width / height
  const PreviewPage(this.png, this.aspect);
}

/// Turns a finished PDF into pictures of its pages, so the report can be looked at
/// inside the app before it is shared. Behind an interface so tests need no phone.
abstract class PdfPreviewer {
  /// At most [maxPages] pages, from the first.
  Future<List<PreviewPage>> render(Uint8List pdf, {int maxPages = 24});
}

/// Uses the platform's own PDF renderer, through the `printing` package.
class PrintingPdfPreviewer implements PdfPreviewer {
  /// Pixels per inch of the pictures: enough to read the page on a phone.
  final double dpi;

  const PrintingPdfPreviewer({this.dpi = 96});

  @override
  Future<List<PreviewPage>> render(Uint8List pdf, {int maxPages = 24}) async {
    final count = countPdfPages(pdf);
    final take = count == 0 ? maxPages : (count < maxPages ? count : maxPages);
    final out = <PreviewPage>[];
    await for (final page in Printing.raster(pdf, pages: [for (var i = 0; i < take; i++) i], dpi: dpi)) {
      out.add(PreviewPage(await page.toPng(), page.width / page.height));
    }
    return out;
  }
}
