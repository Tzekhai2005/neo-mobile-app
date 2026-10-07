import 'dart:io';
import 'dart:typed_data';

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
