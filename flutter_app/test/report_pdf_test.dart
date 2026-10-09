import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/data/review_event.dart';
import 'package:neo_companion/data/review_store.dart';
import 'package:neo_companion/data/static_recording_source.dart';
import 'package:neo_companion/report/report_builder.dart';
import 'package:neo_companion/report/report_exporter.dart';
import 'package:neo_companion/report/report_fonts.dart';
import 'package:neo_companion/report/report_models.dart';
import 'package:neo_companion/report/report_pdf.dart';
import 'package:neo_companion/report/report_selection.dart';

const mini = 'test/fixtures/mini_recording';
const mini4 = 'test/fixtures/mini_recording_4ch';
const bundled = 'test/fixtures/demo_3day';
final now = DateTime.utc(2026, 10, 7, 9, 30);

Future<ReportData> reportFor(
  String dir, {
  int confirmTop = 0,
  Map<String, String> notes = const {},
  ReportSelection? selection,
}) async {
  final src = StaticRecordingSource(DirectoryDatasetReader(dir));
  await src.load();
  final tmp = Directory.systemTemp.createTempSync('neo_pdf_');
  addTearDown(() => tmp.deleteSync(recursive: true));
  final store = ReviewStore(File('${tmp.path}/d.json'), datasetKey: src.info.datasetKey);
  await store.load();
  final auto = src.events().where((e) => e.source == EventSource.auto).toList()
    ..sort((a, b) => b.confidence!.compareTo(a.confidence!));
  for (final e in auto.take(confirmTop)) {
    await store.setStatus(e.id, ReviewStatus.confirmed);
  }
  for (final n in notes.entries) {
    await store.setNote(auto[int.parse(n.key)].id, n.value);
  }
  final events = store.merge(src.events());
  return ReportBuilder.build(
    source: src,
    events: events,
    selection: selection ?? ReportSelection.defaultFor(events),
    generatedAtUtc: now,
    device: const ReportDevice(name: 'neo-A', serial: 'A0B1C2D3E4F5', firmware: '0.1.0'),
    patientLabel: 'Demo patient',
  );
}

/// The PDF library writes every word as its own text object: `[(EEG)]TJ ... [(review)]TJ`.
/// Read them back in order and join with spaces, the way a reader sees the page.
String wordsOf(String rawPdf) {
  String unescape(String s) => s
      .replaceAllMapped(RegExp(r'\\([0-7]{3})'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)))
      .replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);
  return RegExp(r'\[\(((?:\\.|[^\\)])*)\)\]TJ').allMatches(rawPdf).map((m) => unescape(m[1]!)).join(' ');
}

/// Page text of an uncompressed build.
Future<String> readable(ReportData d) async => wordsOf(latin1.decode(await ReportPdf.build(d, compress: false)));

/// The raw uncompressed bytes, for structure checks.
Future<String> rawPdf(ReportData d) async => latin1.decode(await ReportPdf.build(d, compress: false));

int pages(String pdf) => RegExp(r'/Type\s*/Page(?![a-zA-Z])').allMatches(pdf).length;

void main() {
  group('pdfSafe', () {
    test('keeps Latin-1 and turns anything else into ?', () {
      expect(pdfSafe('50 µV, 36 °C, café'), '50 µV, 36 °C, café');
      expect(pdfSafe('日本語 note – dash'), '??? note ? dash');
      expect(pdfSafe('a\r\nb'), 'a\n\nb');
    });
  });

  group('file name', () {
    test('is lower-case, safe and dated by the recording start', () async {
      final d = await reportFor(mini);
      expect(ReportPdf.suggestedFileName(d), 'epile-x-eeg-report-20261005.pdf');
      final h = d.header;
      final odd = ReportData(
        header: ReportHeader(
          brand: ' My Lab: EEG/Review! ',
          generatedAtUtc: h.generatedAtUtc,
          recordingStartLocal: h.recordingStartLocal,
          recordingEndLocal: h.recordingEndLocal,
          utcOffsetMinutes: h.utcOffsetMinutes,
          durationSec: h.durationSec,
          eegRateHz: h.eegRateHz,
          eegChannels: h.eegChannels,
          imuRateHz: h.imuRateHz,
          synthetic: h.synthetic,
          generator: h.generator,
          datasetKey: h.datasetKey,
        ),
        summary: d.summary,
        entries: d.entries,
        selectionIsFallback: d.selectionIsFallback,
        overview: d.overview,
        timeline: d.timeline,
      );
      expect(ReportPdf.suggestedFileName(odd), 'my-lab-eeg-review-eeg-report-20261005.pdf');
    });
  });

  group('the PDF', () {
    test('is a valid A4 document with the report furniture', () async {
      final d = await reportFor(mini, confirmTop: 2, notes: {'0': 'Seen by carer, lasted about ten seconds'});
      final bytes = await ReportPdf.build(d);
      expect(latin1.decode(bytes.sublist(0, 8)), startsWith('%PDF-'));
      expect(latin1.decode(bytes.sublist(bytes.length - 8)), contains('%%EOF'));
      expect(bytes.length, lessThan(1024 * 1024));

      final raw = await rawPdf(d);
      expect(raw, contains('/MediaBox'));
      expect(raw, contains('595.27')); // A4 width in points
      expect(pages(raw), greaterThanOrEqualTo(3), reason: 'summary, events, method');
      final text = wordsOf(raw);
      for (final s in ['EEG review report', 'Epile-X', 'by NeuraVance Labs', 'SAMPLE RECORDING', 'Not a medical device', 'Demo patient']) {
        expect(text, contains(s), reason: s);
      }
    });

    test('with no company line the header is just the product name, and the file name is unchanged', () async {
      final d = await reportFor(mini, confirmTop: 1);
      final h = d.header;
      final bare = ReportData(
        header: ReportHeader(
          brand: h.brand,
          byline: '',
          generatedAtUtc: h.generatedAtUtc,
          recordingStartLocal: h.recordingStartLocal,
          recordingEndLocal: h.recordingEndLocal,
          utcOffsetMinutes: h.utcOffsetMinutes,
          durationSec: h.durationSec,
          eegRateHz: h.eegRateHz,
          eegChannels: h.eegChannels,
          imuRateHz: h.imuRateHz,
          synthetic: h.synthetic,
          generator: h.generator,
          datasetKey: h.datasetKey,
          device: h.device,
          patientLabel: h.patientLabel,
        ),
        summary: d.summary,
        entries: d.entries,
        selectionIsFallback: d.selectionIsFallback,
        overview: d.overview,
        timeline: d.timeline,
      );
      final text = await readable(bare);
      expect(text, contains('Epile-X'));
      expect(text, isNot(contains('by NeuraVance Labs')));
      expect(ReportPdf.suggestedFileName(bare), ReportPdf.suggestedFileName(d));
    });

    test('shows the events, the reviewer note, and what the figures say', () async {
      final d = await reportFor(mini, confirmTop: 2, notes: {'0': 'Seen by carer'});
      final text = await readable(d);
      expect(text, contains('Events in this report (2)'));
      for (final e in d.entries) {
        expect(text, contains(e.event.id), reason: 'event id ${e.event.id}');
      }
      expect(text, contains('Reviewer note: Seen by carer'));
      expect(text, contains('Confirmed by reviewer'));
      expect(text, contains('candidate events'));
      expect(text, contains('usable signal'));
    });

    test('says so when nothing was confirmed and the events are unreviewed candidates', () async {
      final d = await reportFor(mini);
      expect(d.selectionIsFallback, isTrue);
      final text = await readable(d);
      expect(text, contains('highest-confidence unreviewed candidates'));
      expect(text, contains('Not yet reviewed'));
    });

    test('an empty selection still produces a complete report', () async {
      final d = await reportFor(mini, selection: const ReportSelection({}));
      final text = await readable(d);
      expect(text, contains('No events were selected for this report.'));
      expect(text, contains('Method and limitations'));
    });

    test('four EEG channels draw', () async {
      final d = await reportFor(mini4, confirmTop: 1);
      final text = await readable(d);
      expect(d.entries.first.window.channels, 4);
      for (final c in ['EEG 1', 'EEG 2', 'EEG 3', 'EEG 4']) {
        expect(text, contains(c));
      }
    });

    test('a note in another script becomes ? and never breaks the file', () async {
      final d = await reportFor(mini, confirmTop: 1, notes: {'0': '日本語 notes, café'});
      final text = await readable(d);
      expect(text, contains('Reviewer note: ??? notes, café'));
    });

    test('a long note is cut so the block keeps its size', () async {
      final d = await reportFor(mini, confirmTop: 1, notes: {'0': 'word ' * 200});
      final text = await readable(d);
      expect(text, contains('(shortened, full note in events.csv)'), reason: 'a cut note must say so');
      expect(text, isNot(contains('word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word word')));
    });

    test('the full 3-day recording with many events stays compact', () async {
      final d = await reportFor(bundled, confirmTop: 12);
      expect(d.entries.length, 12);
      final bytes = await ReportPdf.build(d);
      expect(pages(await rawPdf(d)), greaterThanOrEqualTo(8), reason: 'summary + 6 event pages + method');
      expect(bytes.length, lessThan(3 * 1024 * 1024), reason: 'vector charts, not images');
    });
  });

  group('Noto Sans', () {
    late ReportFonts fonts;
    setUpAll(() async => fonts = await ReportFonts.fromDirectory('assets/fonts'));

    test('the four faces are real TrueType fonts under the Open Font Licence', () {
      for (final f in [fonts.regular, fonts.bold, fonts.italic, fonts.boldItalic]) {
        expect(f.length, greaterThan(300 * 1024));
        expect(f.sublist(0, 4), anyOf(equals([0, 1, 0, 0]), equals([0x74, 0x72, 0x75, 0x65])), reason: 'TrueType header');
      }
      expect(File('assets/fonts/OFL.txt').readAsStringSync(), contains('SIL Open Font License'));
    });

    test('keeps what the font has and turns the rest into ?', () {
      final keep = ReportPdf.textFilter(fonts);
      for (final ok in ['50 µV, 36 °C', 'café Žluťoučký Müller', 'Привет мир', 'Ελλάδα', 'Tiếng Việt', 'x — y · z']) {
        expect(keep(ok), ok, reason: ok);
      }
      expect(keep('日本語 note'), '??? note');
      expect(keep('தமிழ்'), '?????');
      expect(keep('a\r\nb'), 'a\n\nb');
      expect(keep('line1\nline2'), 'line1\nline2');
    });

    test('without fonts the filter is the Latin-1 one', () {
      final plain = ReportPdf.textFilter(null);
      expect(plain('café µV'), 'café µV');
      expect(plain('Привет'), '??????');
      expect(plain('x — y'), 'x ? y', reason: 'the standard fonts lack the em dash');
    });

    test('embeds the font, and the report stays a reasonable size', () async {
      final d = await reportFor(mini, confirmTop: 2);
      final plain = await ReportPdf.build(d);
      final noto = await ReportPdf.build(d, fonts: fonts);
      expect(latin1.decode(noto.sublist(0, 5)), '%PDF-');
      final raw = await ReportPdf.build(d, compress: false, fonts: fonts);
      expect(latin1.decode(raw), allOf(contains('NotoSans'), contains('/FontFile2')));
      // ignore: avoid_print
      print('PDF size, standard fonts ${(plain.length / 1024).round()} KB, Noto Sans ${(noto.length / 1024).round()} KB');
      expect(noto.length, lessThan(6 * 1024 * 1024));
    });

    test('Cyrillic, accents and a Chinese note: the first two are readable in the file, the last is "?"', () async {
      final d = await reportFor(mini, confirmTop: 1, notes: {'0': 'Привет, café, Žluťoučký, 日本語'});
      final pdf = await ReportPdf.build(d, fonts: fonts);
      final out = Directory('build/font_check')..createSync(recursive: true);
      final file = File('${out.path}/unicode_note.pdf')..writeAsBytesSync(pdf);
      final pdftotext = Process.runSync('which', ['pdftotext']);
      if (pdftotext.exitCode != 0) {
        // ignore: avoid_print
        print('pdftotext not installed: wrote ${file.path} but cannot read it back here');
        return;
      }
      final text = Process.runSync('pdftotext', ['-layout', file.path, '-']).stdout as String;
      expect(text, contains('Привет'));
      expect(text, contains('café'));
      expect(text, contains('Žluťoučký'));
      expect(text, contains('???'), reason: 'the Chinese characters are not in Noto Sans');
      expect(text, isNot(contains('日本語')));
    });

    test('the exporter sets the PDF in Noto Sans when it is given the fonts', () async {
      final out = Directory.systemTemp.createTempSync('neo_font_exp_');
      addTearDown(() => out.deleteSync(recursive: true));
      final d = await reportFor(mini, confirmTop: 1, notes: {'0': 'Привет'});
      final r = await ReportExporter(outputDir: out, fonts: fonts).export(d);
      final raw = latin1.decode(await r.pdf.readAsBytes());
      expect(raw, contains('NotoSans'));
    });
  });
}
