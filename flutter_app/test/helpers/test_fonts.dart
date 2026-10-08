import 'dart:io';

import 'package:flutter/services.dart';

/// Widget tests draw every letter as a full-width block unless a real font is
/// loaded, which makes ordinary text overflow. Load Flutter's own Roboto.
Future<void> loadTestFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final fonts = '$root/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final file = File('$fonts/$f');
      if (!file.existsSync()) return;
      loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }

  await load('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
}
