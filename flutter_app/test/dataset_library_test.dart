import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/config/app_config.dart';
import 'package:neo_companion/data/dataset_library.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/data/static_recording_source.dart';

const mini = 'test/fixtures/mini_recording';
const mini4 = 'test/fixtures/mini_recording_4ch';

Map<String, List<int>> filesOf(String dir) => {
      for (final f in DatasetLibrary.requiredFiles) f: File('$dir/$f').readAsBytesSync(),
    };

Uint8List zipOf(Map<String, List<int>> entries) {
  final a = Archive();
  entries.forEach((name, bytes) => a.add(ArchiveFile.bytes(name, bytes)));
  return ZipEncoder().encodeBytes(a);
}

void main() {
  late Directory sandbox; // holds the library root and the zips, so "outside the library" is checkable
  late Directory root;
  late DatasetLibrary lib;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('neo_lib_');
    root = Directory('${sandbox.path}/datasets');
    lib = DatasetLibrary(root);
  });
  tearDown(() => sandbox.deleteSync(recursive: true));

  File writeZip(String name, Map<String, List<int>> entries) =>
      File('${sandbox.path}/$name')..writeAsBytesSync(zipOf(entries));

  Matcher importError(Matcher message) =>
      throwsA(isA<DatasetImportException>().having((e) => e.message, 'message', message));

  List<String> rootEntries() => root.existsSync() ? [for (final e in root.listSync()) e.uri.pathSegments.where((s) => s.isNotEmpty).last] : [];

  group('importing', () {
    test('a zip with the three files at the top', () async {
      final s = await lib.importZip(writeZip('Night Study.zip', filesOf(mini)));
      expect(s.name, 'night-study');
      expect(s.dir.path, '${root.path}/night-study');
      expect(s.eventCount, 5);
      expect(s.durationSec, 3600);
      expect(s.eegChannels, 2);
      expect(s.synthetic, isTrue);
      expect(s.sizeBytes, greaterThan(400 * 1024));
      expect((await lib.list()).map((d) => d.name), ['night-study']);
    });

    test('the imported recording really loads and matches the original', () async {
      final s = await lib.importZip(writeZip('r.zip', filesOf(mini4)));
      final src = StaticRecordingSource(DirectoryDatasetReader(s.dir.path));
      await src.load();
      expect(src.info.eegChannels, 4);
      expect(src.events().length, 4);
    });

    test('a zip with everything inside one folder', () async {
      final inFolder = {for (final e in filesOf(mini).entries) 'my recording/${e.key}': e.value};
      expect((await lib.importZip(writeZip('r.zip', inFolder))).eventCount, 5);
    });

    test('other files in the zip, and macOS junk, are ignored', () async {
      final entries = {
        ...filesOf(mini),
        'readme.txt': utf8.encode('hello'),
        '__MACOSX/._manifest.json': utf8.encode('junk'),
        '._windows.bin': utf8.encode('junk'),
        'deep/er/than/one/manifest.json': utf8.encode('{}'),
      };
      final s = await lib.importZip(writeZip('r.zip', entries));
      expect(s.dir.listSync().map((e) => e.uri.pathSegments.last).toSet(), DatasetLibrary.requiredFiles.toSet());
    });

    test('importing the same file twice keeps both under different names', () async {
      final zip = writeZip('same.zip', filesOf(mini));
      expect((await lib.importZip(zip)).name, 'same');
      expect((await lib.importZip(zip)).name, 'same-2');
      expect((await lib.importZip(zip)).name, 'same-3');
      expect((await lib.list()).map((d) => d.name), ['same', 'same-2', 'same-3']);
    });

    test('an explicit name wins, and unsafe names are cleaned', () async {
      final s = await lib.importZip(writeZip('x.zip', filesOf(mini)), name: '  ../../My Recording (1)!  ');
      expect(s.name, 'my-recording-1');
      expect(DatasetLibrary.safeName('日本語'), 'recording');
      expect(DatasetLibrary.safeName('A' * 100).length, lessThanOrEqualTo(60));
    });
  });

  group('the generator tool', () {
    final python = Process.runSync('which', ['python3']).exitCode == 0;

    test('a zip written by tools/make_demo_dataset.py imports and loads', () async {
      final folder = Directory('${sandbox.path}/generated');
      final zip = File('${sandbox.path}/generated.zip');
      final r = Process.runSync('python3', [
        '../tools/make_demo_dataset.py', '--hours', '2', '--events', '6', '--out', folder.path, '--zip', zip.path,
      ]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(zip.existsSync(), isTrue);

      final s = await lib.importZip(zip);
      expect(s.name, 'generated');
      expect(s.durationSec, 2 * 3600);
      expect(s.eventCount, 7); // 6 automatic candidates and 1 patient press
      final src = StaticRecordingSource(DirectoryDatasetReader(s.dir.path));
      await src.load();
      final window = await src.eventWindow(src.events().first.id);
      expect(window.eeg[0].length, 250 * 40);
    }, skip: python ? false : 'python3 not available');

    test('a recording written by tools/write_recording_example.py (the documented converter) imports and loads', () async {
      final folder = Directory('${sandbox.path}/example');
      final zip = File('${sandbox.path}/example.zip');
      final r = Process.runSync('python3', ['../tools/write_recording_example.py', '--out', folder.path, '--zip', zip.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');

      final s = await lib.importZip(zip);
      expect(s.durationSec, 600);
      expect(s.eventCount, 2);
      expect(s.eegChannels, 2);
      expect(s.synthetic, isTrue);
      final src = StaticRecordingSource(DirectoryDatasetReader(s.dir.path));
      await src.load();
      final events = src.events();
      expect(events.map((e) => e.id), ['e0001', 'e0002']);
      expect(events[0].confidence, 0.91);
      expect(events[1].confidence, isNull, reason: 'a button press has no confidence');
      expect(events[0].startSec(250), 120);
      final w = await src.eventWindow('e0001');
      expect(w.eeg.length, 2);
      expect(w.eeg[0].length, 250 * 40);
      expect(w.accelZ[0], closeTo(1.0, 0.02), reason: 'gravity on z, in g');
      // the 10 Hz, 14 µV sine and 3 µV noise written by the example come back in µV
      final peak = w.eeg[0].map((v) => v.abs()).reduce((a, b) => a > b ? a : b);
      expect(peak, inInclusiveRange(10, 30));
    }, skip: python ? false : 'python3 not available');
  });

  group('rejecting bad zips, leaving nothing behind', () {
    Future<void> expectClean() async {
      expect(rootEntries().where((n) => n.startsWith('.import-')), isEmpty, reason: 'no half-imported folder');
      expect(await lib.list(), isEmpty);
    }

    test('not a zip', () async {
      final f = File('${sandbox.path}/x.zip')..writeAsBytesSync(utf8.encode('this is plainly not a zip file at all'));
      await expectLater(lib.importZip(f), importError(contains('not a valid zip')));
      await expectClean();
    });

    test('empty file and missing file', () async {
      await expectLater(lib.importZip(File('${sandbox.path}/e.zip')..writeAsBytesSync([])), importError(contains('empty')));
      await expectLater(lib.importZip(File('${sandbox.path}/nope.zip')), importError(contains('could not be found')));
    });

    test('a file missing from the zip is named', () async {
      final entries = filesOf(mini)..remove(DatasetLibrary.requiredFiles[1]);
      await expectLater(lib.importZip(writeZip('r.zip', entries)), importError(allOf(contains('overview.json'), contains('windows.bin'))));
      await expectClean();
    });

    test('a manifest this app does not understand', () async {
      final manifest = jsonDecode(utf8.decode(filesOf(mini)['manifest.json']!)) as Map<String, dynamic>;
      manifest['formatVersion'] = 9;
      final entries = {...filesOf(mini), 'manifest.json': utf8.encode(jsonEncode(manifest))};
      await expectLater(lib.importZip(writeZip('r.zip', entries)), importError(allOf(contains('can open'), contains('formatVersion 9'))));
      await expectClean();
    });

    test('a manifest that is not JSON', () async {
      final entries = {...filesOf(mini), 'manifest.json': utf8.encode('{ nope')};
      await expectLater(lib.importZip(writeZip('r.zip', entries)), importError(contains('can open')));
      await expectClean();
    });

    test('signal data that is cut short', () async {
      final entries = {...filesOf(mini), 'windows.bin': filesOf(mini)['windows.bin']!.sublist(0, 5000)};
      await expectLater(lib.importZip(writeZip('r.zip', entries)), importError(contains('can open')));
      await expectClean();
    });

    test('too big, by file size and by unpacked size', () async {
      final small = DatasetLibrary(root, maxBytes: 100 * 1024);
      await expectLater(small.importZip(writeZip('r.zip', filesOf(mini))), importError(contains('limit')));
      // compresses well, so the zip is under the limit but the contents are not
      final squashy = {...filesOf(mini), 'windows.bin': List<int>.filled(3 * 1024 * 1024, 0)};
      final zip = writeZip('squash.zip', squashy);
      expect(zip.lengthSync(), lessThan(300 * 1024));
      await expectLater(DatasetLibrary(root, maxBytes: 1024 * 1024).importZip(zip), importError(contains('unpacked')));
      await expectClean();
    });

    test('files spread over several folders, or repeated', () async {
      final spread = {
        'a/manifest.json': filesOf(mini)['manifest.json']!,
        'b/overview.json': filesOf(mini)['overview.json']!,
        'a/windows.bin': filesOf(mini)['windows.bin']!,
      };
      await expectLater(lib.importZip(writeZip('s.zip', spread)), importError(contains('several folders')));
      final twice = {...filesOf(mini), 'again/manifest.json': filesOf(mini)['manifest.json']!};
      await expectLater(lib.importZip(writeZip('t.zip', twice)), importError(contains('more than once')));
      await expectClean();
    });

    test('a zip with paths that climb out of it is refused and writes nothing anywhere', () async {
      for (final evilName in ['../../evil.json', '../manifest.json', r'..\..\evil-backslash.json', 'a/../../evil.json']) {
        final evil = {...filesOf(mini), evilName: utf8.encode('pwned')};
        await expectLater(lib.importZip(writeZip('evil.zip', evil)), importError(contains('unsafe')), reason: evilName);
      }
      expect(File('${sandbox.parent.path}/evil.json').existsSync(), isFalse);
      expect(File('${sandbox.path}/evil.json').existsSync(), isFalse);
      await expectClean();
    });

    test('absolute-looking entry names cannot place a file either; they are just ignored', () async {
      final odd = {...filesOf(mini), '/tmp/neo-evil-absolute.txt': utf8.encode('pwned'), '/manifest.json.bak': utf8.encode('x')};
      final s = await lib.importZip(writeZip('odd.zip', odd));
      expect(File('/tmp/neo-evil-absolute.txt').existsSync(), isFalse);
      expect(s.dir.listSync().length, 3);
      expect(sandbox.listSync().map((e) => e.uri.pathSegments.where((p) => p.isNotEmpty).last).toSet(), {'datasets', 'odd.zip'});
    });
  });

  group('selection', () {
    test('nothing selected means the bundled demo', () async {
      expect(await lib.selected(), isNull);
      expect(lib.locationFor(null).isAsset, isTrue);
      expect(lib.locationFor(null).path, kDatasetLocation.path);
    });

    test('is remembered by a new library on the same folder', () async {
      final s = await lib.importZip(writeZip('r.zip', filesOf(mini)));
      await lib.select(s.name);
      expect(await DatasetLibrary(root).selected(), 'r');
      final loc = lib.locationFor('r');
      expect(loc.isAsset, isFalse);
      expect(loc.path, '${root.path}/r');
      await lib.select(null);
      expect(await DatasetLibrary(root).selected(), isNull);
    });

    test('an unknown name is refused, and a vanished recording falls back to the demo', () async {
      await expectLater(lib.select('ghost'), importError(contains('ghost')));
      await expectLater(lib.select('../x'), importError(contains('no imported recording')));
      final s = await lib.importZip(writeZip('r.zip', filesOf(mini)));
      await lib.select(s.name);
      s.dir.deleteSync(recursive: true);
      expect(await lib.selected(), isNull);
    });

    test('a damaged selection file means the demo, not a crash', () async {
      await lib.importZip(writeZip('r.zip', filesOf(mini)));
      File('${root.path}/selected.json').writeAsStringSync('{ not json');
      expect(await lib.selected(), isNull);
    });
  });

  group('listing and removing', () {
    test('list skips folders that are not recordings', () async {
      await lib.importZip(writeZip('good.zip', filesOf(mini)));
      Directory('${root.path}/empty').createSync();
      Directory('${root.path}/Not Plain').createSync();
      Directory('${root.path}/.hidden').createSync();
      File('${root.path}/stray.txt').writeAsStringSync('x');
      Directory('${root.path}/broken').createSync();
      File('${root.path}/broken/manifest.json').writeAsStringSync('{}');
      expect((await lib.list()).map((d) => d.name), ['good']);
    });

    test('an empty library lists nothing, even before the folder exists', () async {
      expect(await lib.list(), isEmpty);
    });

    test('removing deletes the recording, and the demo takes over if it was in use', () async {
      final a = await lib.importZip(writeZip('a.zip', filesOf(mini)));
      final b = await lib.importZip(writeZip('b.zip', filesOf(mini4)));
      await lib.select(a.name);
      await lib.remove(a.name);
      expect(a.dir.existsSync(), isFalse);
      expect(await lib.selected(), isNull);
      expect(b.dir.existsSync(), isTrue, reason: 'the other recording is untouched');
      await expectLater(lib.remove('a'), importError(contains('no imported recording')));
    });

    test('only names inside the library can be removed', () async {
      await lib.importZip(writeZip('r.zip', filesOf(mini)));
      final outside = Directory('${sandbox.path}/precious')..createSync();
      File('${outside.path}/keep.txt').writeAsStringSync('keep');
      for (final bad in ['../precious', 'precious/..', '..', '.', '', '/', 'a/b']) {
        expect(() => lib.remove(bad), throwsArgumentError, reason: bad);
      }
      expect(File('${outside.path}/keep.txt').existsSync(), isTrue);
    });
  });
}
