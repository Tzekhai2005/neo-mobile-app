import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import '../config/app_config.dart';
import 'dataset.dart';
import 'dataset_directory_reader.dart';

export 'dataset_directory_reader.dart';

/// Reads a dataset bundled as Flutter assets (see pubspec.yaml).
class AssetDatasetReader implements DatasetReader {
  final String basePath;
  Uint8List? _windows; // loaded once: ~10 MB for the demo recording

  AssetDatasetReader(this.basePath);

  @override
  Future<String> readString(String name) => rootBundle.loadString('$basePath/$name');

  Future<Uint8List> _bytes(String name) async {
    final cached = _windows;
    if (name == Dataset.windowsFile && cached != null) return cached;
    final data = await rootBundle.load('$basePath/$name');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    if (name == Dataset.windowsFile) _windows = bytes;
    return bytes;
  }

  @override
  Future<int> length(String name) async => (await _bytes(name)).length;

  @override
  Future<Uint8List> readRange(String name, int offset, int length) async {
    final all = await _bytes(name);
    if (offset < 0 || offset + length > all.length) {
      throw DatasetFormatException('$name ends before offset ${offset + length}');
    }
    return Uint8List.sublistView(all, offset, offset + length);
  }
}

/// The reader for a configured [DatasetLocation].
DatasetReader readerFor(DatasetLocation location) => location.isAsset
    ? AssetDatasetReader(location.path)
    : DirectoryDatasetReader(location.path);
