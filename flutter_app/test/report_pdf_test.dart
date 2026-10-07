import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/data/review_event.dart';
import 'package:neo_companion/data/review_store.dart';
import 'package:neo_companion/data/static_recording_source.dart';
import 'package:neo_companion/report/report_builder.dart';
import 'package:neo_companion/report/report_models.dart';
import 'package:neo_companion/report/report_pdf.dart';
import 'package:neo_companion/report/report_selection.dart';

const mini = 'test/fixtures/mini_recording';
const mini4 = 'test/fixtures/mini_recording_4ch';
const bundled = 'assets/demo_recording';
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
      expect(ReportPdf.suggestedFileName(d), 'neuravance-eeg-report-20261005.pdf');
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
      for (final s in ['EEG review report', 'Neuravance', 'SAMPLE RECORDING', 'Not a medical device', 'Demo patient']) {
        expect(text, contains(s), reason: s);
      }
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
}
