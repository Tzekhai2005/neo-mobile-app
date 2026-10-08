import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import '../config/app_config.dart';
import 'dataset.dart';
import 'dataset_directory_reader.dart';

/// A zip could not be turned into a recording. The message says what to fix.
class DatasetImportException implements Exception {
  final String message;
  const DatasetImportException(this.message);

  @override
  String toString() => 'DatasetImportException: $message';
}

/// An imported recording, as the picker screen would list it.
class DatasetSummary {
  final String name;
  final Directory dir;
  final int durationSec;
  final int eventCount;
  final int eegChannels;
  final bool synthetic;
  final int sizeBytes;

  const DatasetSummary({
    required this.name,
    required this.dir,
    required this.durationSec,
    required this.eventCount,
    required this.eegChannels,
    required this.synthetic,
    required this.sizeBytes,
  });
}

/// The recordings imported into the app's own storage, and which one is in use.
///
/// A recording is one zip holding `manifest.json`, `overview.json` and
/// `windows.bin` (at the top, or inside a single folder). Importing copies those
/// three files into `<root>/<name>/`; nothing else in the zip is ever written to
/// disk, so a hostile zip cannot write outside the library. The selection is
/// remembered in `<root>/selected.json`; no selection means the bundled demo.
class DatasetLibrary {
  static const List<String> requiredFiles = [Dataset.manifestFile, Dataset.overviewFile, Dataset.windowsFile];
  static final RegExp _plainName = RegExp(r'^[a-z0-9][a-z0-9._-]{0,59}$');

  final Directory root;

  /// Largest zip, and largest total unpacked size, accepted.
  final int maxBytes;

  const DatasetLibrary(this.root, {this.maxBytes = 256 * 1024 * 1024});

  File get _selectedFile => File('${root.path}/selected.json');

  /// A safe folder name: lower case letters, digits, dot, dash, underscore.
  static String safeName(String raw) {
    var s = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9._-]+'), '-');
    s = s.replaceAll(RegExp(r'^[-._]+|[-._]+$'), '');
    if (s.length > 60) s = s.substring(0, 60).replaceAll(RegExp(r'[-._]+$'), '');
    return s.isEmpty ? 'recording' : s;
  }

  static bool _isPlain(String name) => _plainName.hasMatch(name);

  // ── listing ─────────────────────────────────────────────────────────────────

  /// The imported recordings, by name. Folders that are not valid recordings are skipped.
  Future<List<DatasetSummary>> list() async {
    if (!await root.exists()) return [];
    final out = <DatasetSummary>[];
    await for (final e in root.list(followLinks: false)) {
      if (e is! Directory) continue;
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!_isPlain(name)) continue;
      try {
        out.add(await _summaryOf(name, e));
      } catch (_) {
        // not a recording: leave it out
      }
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  Future<DatasetSummary> _summaryOf(String name, Directory dir) async {
    final manifest = DatasetManifest.fromJson(
        jsonDecode(await File('${dir.path}/${Dataset.manifestFile}').readAsString()) as Map<String, dynamic>);
    var size = 0;
    for (final f in requiredFiles) {
      size += await File('${dir.path}/$f').length();
    }
    return DatasetSummary(
      name: name,
      dir: dir,
      durationSec: manifest.durationSec,
      eventCount: manifest.events.length,
      eegChannels: manifest.eeg.channels,
      synthetic: manifest.synthetic,
      sizeBytes: size,
    );
  }

  // ── selection ───────────────────────────────────────────────────────────────

  /// The name in use, or null for the bundled demo (also when the saved choice no longer exists).
  Future<String?> selected() async {
    try {
      final j = jsonDecode(await _selectedFile.readAsString()) as Map<String, dynamic>;
      final name = j['selected'] as String?;
      if (name == null || !_isPlain(name)) return null;
      return await File('${root.path}/$name/${Dataset.manifestFile}').exists() ? name : null;
    } catch (_) {
      return null;
    }
  }

  /// Use the recording `name`, or the bundled demo when null.
  Future<void> select(String? name) async {
    if (name != null && !(_isPlain(name) && await File('${root.path}/$name/${Dataset.manifestFile}').exists())) {
      throw DatasetImportException('There is no imported recording called "$name".');
    }
    await root.create(recursive: true);
    final tmp = File('${_selectedFile.path}.tmp');
    await tmp.writeAsString(jsonEncode({'selected': name}), flush: true);
    await tmp.rename(_selectedFile.path);
  }

  /// Where to read `name` from (the bundled demo when null).
  DatasetLocation locationFor(String? name) =>
      name == null ? kDatasetLocation : DatasetLocation.directory('${root.path}/$name');

  // ── import and remove ───────────────────────────────────────────────────────

  /// Unpacks a recording zip into the library and returns its summary. Throws
  /// [DatasetImportException] with a plain explanation when it is not a usable
  /// recording; nothing is left behind in that case.
  Future<DatasetSummary> importZip(File zip, {String? name}) async {
    if (!await zip.exists()) throw const DatasetImportException('The file could not be found.');
    final size = await zip.length();
    if (size == 0) throw const DatasetImportException('The file is empty.');
    if (size > maxBytes) {
      throw DatasetImportException('The file is ${_mb(size)} MB; the limit is ${_mb(maxBytes)} MB.');
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
    } catch (_) {
      throw const DatasetImportException('This is not a valid zip file.');
    }
    // Some non-zip bytes decode to an empty archive instead of failing.
    if (archive.files.isEmpty) throw const DatasetImportException('This is not a valid zip file.');

    // Take only the three files we know, whatever else the zip holds or says.
    final found = <String, ArchiveFile>{};
    final folders = <String>{};
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final parts = f.name.replaceAll('\\', '/').split('/').where((p) => p.isNotEmpty).toList();
      // Entry names are never used as paths, but a name that climbs out of the
      // zip means the file is corrupt or hostile: refuse it outright.
      if (parts.contains('..')) {
        throw const DatasetImportException('The zip contains unsafe file paths ("..") and was not imported.');
      }
      if (parts.isEmpty || parts.length > 2) continue;
      if (parts.first == '__MACOSX' || parts.last.startsWith('._')) continue;
      final base = parts.last;
      if (!requiredFiles.contains(base)) continue;
      if (found.containsKey(base)) throw DatasetImportException('The zip contains $base more than once.');
      found[base] = f;
      folders.add(parts.length == 2 ? parts.first : '');
    }
    final missing = requiredFiles.where((f) => !found.containsKey(f)).toList();
    if (missing.isNotEmpty) {
      throw DatasetImportException('The zip is missing ${missing.join(', ')}. A recording zip holds '
          '${requiredFiles.join(', ')}, at the top or inside one folder.');
    }
    if (folders.length > 1) {
      throw const DatasetImportException('The recording files are spread over several folders in the zip.');
    }
    final unpacked = found.values.fold<int>(0, (n, f) => n + f.size);
    if (unpacked > maxBytes) {
      throw DatasetImportException('The recording is ${_mb(unpacked)} MB unpacked; the limit is ${_mb(maxBytes)} MB.');
    }

    await root.create(recursive: true);
    final tmp = Directory('${root.path}/.import-${DateTime.now().microsecondsSinceEpoch}');
    var moved = false;
    try {
      await tmp.create();
      for (final entry in found.entries) {
        // The file name comes from our own list, never from the zip.
        await File('${tmp.path}/${entry.key}').writeAsBytes(entry.value.content, flush: true);
      }
      try {
        await Dataset.load(DirectoryDatasetReader(tmp.path));
      } on DatasetFormatException catch (e) {
        throw DatasetImportException('This is not a recording this app can open: ${e.message}');
      } on FormatException catch (e) {
        throw DatasetImportException('This is not a recording this app can open: ${e.message}');
      }

      final base = safeName(name ?? _stem(zip.uri.pathSegments.last));
      var finalName = base;
      for (var n = 2; await Directory('${root.path}/$finalName').exists(); n++) {
        finalName = '$base-$n';
      }
      final dest = Directory('${root.path}/$finalName');
      await tmp.rename(dest.path);
      moved = true;
      return await _summaryOf(finalName, dest);
    } finally {
      if (!moved && await tmp.exists()) await tmp.delete(recursive: true);
    }
  }

  /// Deletes an imported recording. If it was in use, the demo is used again.
  Future<void> remove(String name) async {
    if (!_isPlain(name)) throw ArgumentError.value(name, 'name', 'not a recording name');
    final dir = Directory('${root.path}/$name');
    if (!await dir.exists()) throw DatasetImportException('There is no imported recording called "$name".');
    if (await selected() == name) await select(null);
    await dir.delete(recursive: true);
  }

  static String _stem(String file) => file.replaceAll(RegExp(r'\.[^.]*$'), '');
  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
}
