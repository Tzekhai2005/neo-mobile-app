import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import '../config/app_config.dart';
import 'dataset.dart';

/// Reads a dataset from a folder on disk (tests, or "point at another folder").
class DirectoryDatasetReader implements DatasetReader {
  final Directory dir;
  DirectoryDatasetReader(String path) : dir = Directory(path);

  File _file(String name) => File('${dir.path}/$name');

  @override
  Future<String> readString(String name) async {
    final f = _file(name);
    if (!await f.exists()) throw DatasetFormatException('missing file $name in ${dir.path}');
    return f.readAsString();
  }

  @override
  Future<int> length(String name) async {
    final f = _file(name);
    if (!await f.exists()) throw DatasetFormatException('missing file $name in ${dir.path}');
    return f.length();
  }

  @override
  Future<Uint8List> readRange(String name, int offset, int length) async {
    final raf = await _file(name).open();
    try {
      await raf.setPosition(offset);
      final bytes = await raf.read(length);
      if (bytes.length != length) throw DatasetFormatException('$name ends before offset ${offset + length}');
      return bytes;
    } finally {
      await raf.close();
    }
  }
}

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
