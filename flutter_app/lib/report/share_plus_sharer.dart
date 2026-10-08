import 'dart:io';

import 'package:share_plus/share_plus.dart';

import 'report_exporter.dart';

/// Opens the phone's share sheet through the share_plus plugin. This is the only
/// code that touches the plugin; everything else uses [FileSharer].
class SharePlusFileSharer implements FileSharer {
  const SharePlusFileSharer();

  static String _mimeType(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.pdf')) return 'application/pdf';
    if (p.endsWith('.zip')) return 'application/zip';
    if (p.endsWith('.csv')) return 'text/csv';
    return 'application/octet-stream';
  }

  @override
  Future<void> share(List<File> files, {String? subject}) async {
    await SharePlus.instance.share(ShareParams(
      files: [for (final f in files) XFile(f.path, mimeType: _mimeType(f.path))],
      subject: subject,
      title: subject,
    ));
  }
}
