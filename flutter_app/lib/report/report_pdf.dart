import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/recording_source.dart';
import '../data/review_event.dart';
import 'report_fonts.dart';
import 'report_models.dart';

// ── Palette (print-friendly; change here) ──────────────────────────────────────
const _ink = PdfColor.fromInt(0xFF1B1F23);
const _muted = PdfColor.fromInt(0xFF5F6B76);
const _rule = PdfColor.fromInt(0xFFC9CFD6);
const _grid = PdfColor.fromInt(0xFFE3E7EB);
const _envelope = PdfColor.fromInt(0xFF9AA5B1);
const _night = PdfColor.fromInt(0xFFE4E8F1);
const _lowQuality = PdfColor.fromInt(0xFFF3E3B8);
const _high = PdfColor.fromInt(0xFFC62828);
const _bar = PdfColor.fromInt(0xFF6B7682);
const _barDim = PdfColor.fromInt(0xFFB7BFC7);
const _marker = PdfColor.fromInt(0xFF1F5FA8);
const _span = PdfColor.fromInt(0xFFEEF1F5);

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// The standard PDF fonts only cover Latin-1. Anything else (for example a note
/// typed in another script) becomes "?" instead of silently disappearing.
String pdfSafe(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    b.writeCharCode(r == 0x0D ? 0x0A : (r > 0xFF ? 0x3F : r));
  }
  return b.toString();
}

String _two(int n) => n.toString().padLeft(2, '0');
String _clock(DateTime l) => '${_two(l.hour)}:${_two(l.minute)}';
String _day(DateTime l) => '${_weekdays[l.weekday - 1]} ${_two(l.day)} ${_months[l.month - 1]} ${l.year}';
String _dateTime(DateTime l) => '${_day(l)}, ${_clock(l)}:${_two(l.second)}';

String _duration(num sec) {
  final s = sec.round();
  if (s >= 86400) {
    final h = (s % 86400) ~/ 3600;
    return h == 0 ? '${s ~/ 86400} d' : '${s ~/ 86400} d $h h';
  }
  if (s >= 3600) {
    final m = (s % 3600) ~/ 60;
    return m == 0 ? '${s ~/ 3600} h' : '${s ~/ 3600} h $m min';
  }
  if (s >= 60) return s % 60 == 0 ? '${s ~/ 60} min' : '${s ~/ 60} min ${s % 60} s';
  return '$s s';
}

/// Draws a [ReportData] as an A4 PDF.
class ReportPdf {
  static const double _margin = 36;
  static const double _contentWidth = 595.28 - 2 * _margin;
  static const double _gutter = 38; // left of every signal chart: channel labels

  /// A file name that is safe on every platform, e.g. `epile-x-eeg-report-20261005.pdf`.
  static String suggestedFileName(ReportData data) {
    final brand = data.header.brand.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final d = data.header.recordingStartLocal;
    return '${brand.isEmpty ? 'report' : brand}-eeg-report-${d.year}${_two(d.month)}${_two(d.day)}.pdf';
  }

  /// `compress: false` leaves page text readable in the raw bytes (standard fonts only).
  /// With `fonts` the report is set in Noto Sans and any character the font lacks
  /// becomes "?"; without them the standard PDF fonts are used (Latin-1 only).
  static Future<Uint8List> build(ReportData data, {bool compress = true, ReportFonts? fonts}) =>
      ReportPdf._(fonts)._render(data, compress);

  /// The filter applied to every piece of text: characters the fonts cannot draw
  /// become "?". Exposed so tests can check it directly.
  static String Function(String) textFilter(ReportFonts? fonts) {
    if (fonts == null) return pdfSafe;
    final glyphs = TtfParser(ByteData.sublistView(fonts.regular)).charToGlyphIndexMap.keys.toSet();
    return (String s) {
      final b = StringBuffer();
      for (var r in s.runes) {
        if (r == 0x0D) r = 0x0A;
        b.writeCharCode(r == 0x0A || glyphs.contains(r) ? r : 0x3F);
      }
      return b.toString();
    };
  }

  static pw.ThemeData _themeFor(ReportFonts? f) {
    if (f == null) {
      return pw.ThemeData.withFont(
        base: pw.Font.helvetica(),
        bold: pw.Font.helveticaBold(),
        italic: pw.Font.helveticaOblique(),
        boldItalic: pw.Font.helveticaBoldOblique(),
      );
    }
    pw.Font ttf(Uint8List b) => pw.Font.ttf(ByteData.sublistView(b));
    return pw.ThemeData.withFont(base: ttf(f.regular), bold: ttf(f.bold), italic: ttf(f.italic), boldItalic: ttf(f.boldItalic));
  }

  final String Function(String) _safe;
  final pw.ThemeData _theme;

  ReportPdf._(ReportFonts? fonts)
      : _safe = textFilter(fonts),
        _theme = _themeFor(fonts);

  static String _brandLine(ReportHeader h) => h.byline.isEmpty ? h.brand : '${h.brand} ${h.byline}';

  Future<Uint8List> _render(ReportData data, bool compress) async {
    final doc = pw.Document(
      compress: compress,
      title: _safe('EEG review report'),
      author: _safe(_brandLine(data.header)),
      creator: _safe(_brandLine(data.header)),
      subject: _safe(data.header.synthetic ? 'Sample recording (synthetic data)' : 'EEG review report'),
    );
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(_margin),
      theme: _theme,
      header: (c) => _pageHeader(data),
      footer: (c) => _pageFooter(c, data),
      build: (c) => [
        _title(data),
        _facts(data),
        _figures(data.summary),
        _perDay(data.summary),
        _quality(data.summary.quality, data.header.recordingStartLocal),
        _section('Recording overview'),
        pw.Inseparable(child: _timeline(data)), // the figure and its legend stay together
        pw.NewPage(),
        _section('Events in this report (${data.entries.length})'),
        if (data.selectionIsFallback && data.entries.isNotEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 8),
            child: _text('No event had been confirmed, so these are the highest-confidence unreviewed candidates.',
                size: 8.5, italic: true, color: _muted),
          ),
        if (data.entries.isEmpty) _text('No events were selected for this report.', size: 9, color: _muted),
        for (var i = 0; i < data.entries.length; i++) ...[
          pw.Inseparable(child: _entry(data, data.entries[i])),
          pw.SizedBox(height: 10),
        ],
        pw.Inseparable(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            _section('Method and limitations'),
            _method(data),
            pw.SizedBox(height: 28),
            _signOff(),
          ]),
        ),
      ],
    ));
    return doc.save();
  }

  // ── text helpers ────────────────────────────────────────────────────────────

  pw.Widget _text(
    String s, {
    double size = 9,
    bool bold = false,
    bool italic = false,
    PdfColor color = _ink,
    int? maxLines,
    pw.TextAlign? align,
  }) =>
      pw.Text(
        _safe(s),
        maxLines: maxLines,
        textAlign: align,
        style: pw.TextStyle(
          fontSize: size,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          fontStyle: italic ? pw.FontStyle.italic : pw.FontStyle.normal,
          color: color,
          lineSpacing: 1.0,
        ),
      );

  pw.Widget _section(String title) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 16, bottom: 6),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          _text(title, size: 12, bold: true),
          pw.SizedBox(height: 3),
          pw.Container(height: 0.6, color: _rule),
        ]),
      );

  // ── page furniture ──────────────────────────────────────────────────────────

  pw.Widget _pageHeader(ReportData d) => pw.Container(
        padding: const pw.EdgeInsets.only(bottom: 6),
        margin: const pw.EdgeInsets.only(bottom: 10),
        decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _rule, width: 0.6))),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Row(children: [
            _text(d.header.brand, size: 10, bold: true),
            if (d.header.byline.isNotEmpty) ...[pw.SizedBox(width: 5), _text(d.header.byline, size: 9, color: _muted)],
            pw.Spacer(),
            _text('EEG review report', size: 9, color: _muted),
          ]),
          if (d.header.synthetic) ...[
            pw.SizedBox(height: 4),
            _text('SAMPLE RECORDING: synthetic demonstration data, not a real patient.',
                size: 8, bold: true, color: _high),
          ],
        ]),
      );

  pw.Widget _pageFooter(pw.Context c, ReportData d) => pw.Container(
        padding: const pw.EdgeInsets.only(top: 6),
        margin: const pw.EdgeInsets.only(top: 8),
        decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _rule, width: 0.6))),
        child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Expanded(child: _text(d.disclaimer, size: 7, color: _muted)),
          pw.SizedBox(width: 12),
          _text('Page ${c.pageNumber} / ${c.pagesCount}', size: 7.5, color: _muted),
        ]),
      );

  // ── first page ──────────────────────────────────────────────────────────────

  pw.Widget _title(ReportData d) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        _text('EEG review report', size: 24, bold: true),
        pw.SizedBox(height: 4),
        _text('${_dateTime(d.header.recordingStartLocal)}  to  ${_dateTime(d.header.recordingEndLocal)}',
            size: 10, color: _muted),
        pw.SizedBox(height: 12),
      ]);

  pw.Widget _facts(ReportData d) {
    final h = d.header;
    final dev = h.device;
    String orNot(String? s) => (s == null || s.isEmpty) ? 'not recorded' : s;
    final rows = <List<String>>[
      ['Patient', orNot(h.patientLabel)],
      ['Recording', '${_duration(h.durationSec)}, local time (UTC${_offset(h.utcOffsetMinutes)})'],
      if (h.isPartial)
        [
          'Days covered',
          h.firstDay == h.lastDay
              ? 'Day ${h.firstDay! + 1} of ${h.recordingDays}'
              : 'Days ${h.firstDay! + 1} to ${h.lastDay! + 1} of ${h.recordingDays}',
        ],
      [
        'Device',
        dev == null
            ? 'not recorded'
            : [orNot(dev.name), 'serial ${orNot(dev.serial)}', 'firmware ${orNot(dev.firmware)}'].join(', ')
      ],
      ['Signals', '${h.eegChannels} EEG channels at ${h.eegRateHz} Hz; accelerometer and gyro at ${h.imuRateHz} Hz'],
      ['Report generated', '${_dateTime(h.generatedAtUtc)} UTC'],
    ];
    return pw.Table(
      columnWidths: const {0: pw.FixedColumnWidth(96), 1: pw.FlexColumnWidth()},
      border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: _grid, width: 0.5)),
      children: [
        for (final r in rows)
          pw.TableRow(children: [
            pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 3), child: _text(r[0], size: 8.5, color: _muted)),
            pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 3), child: _text(r[1], size: 9)),
          ]),
      ],
    );
  }

  String _offset(int minutes) {
    final sign = minutes < 0 ? '-' : '+';
    final m = minutes.abs();
    return '$sign${_two(m ~/ 60)}:${_two(m % 60)}';
  }

  pw.Widget _figures(ReportSummary s) {
    pw.Widget stat(String value, String label) => pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            decoration: const pw.BoxDecoration(border: pw.Border(left: pw.BorderSide(color: _rule, width: 0.6))),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              _text(value, size: 17, bold: true),
              pw.SizedBox(height: 2),
              _text(label, size: 8, color: _muted),
            ]),
          ),
        );
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 14),
      child: pw.Column(children: [
        pw.Row(children: [
          stat(_duration(s.durationSec), 'recorded'),
          stat('${s.quality.usablePercent.toStringAsFixed(1)} %', 'usable signal'),
          stat('${s.candidates}', 'candidate events'),
          stat('${s.confirmed}', 'confirmed by reviewer'),
        ]),
        pw.SizedBox(height: 6),
        pw.Row(children: [
          stat('${s.highConfidence}', 'possible seizures (score 0.80 or more)'),
          stat('${s.unreviewed}', 'not yet reviewed'),
          stat('${s.dismissed}', 'dismissed'),
          if (s.unsure > 0) stat('${s.unsure}', 'marked not sure'),
          stat('${s.patientMarkers}', 'patient button presses'),
        ]),
      ]),
    );
  }

  pw.Widget _perDay(ReportSummary s) {
    pw.Widget cell(String t, {bool head = false, bool right = false}) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 2),
          child: _text(t, size: 8.5, bold: head, color: head ? _muted : _ink, align: right ? pw.TextAlign.right : null),
        );
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 14),
      child: pw.Table(
        columnWidths: const {
          0: pw.FixedColumnWidth(40),
          1: pw.FlexColumnWidth(2.2),
          2: pw.FlexColumnWidth(1),
          3: pw.FlexColumnWidth(1),
          4: pw.FlexColumnWidth(1),
          5: pw.FlexColumnWidth(1.2),
        },
        border: const pw.TableBorder(
          horizontalInside: pw.BorderSide(color: _grid, width: 0.5),
          bottom: pw.BorderSide(color: _rule, width: 0.6),
          top: pw.BorderSide(color: _rule, width: 0.6),
        ),
        children: [
          pw.TableRow(children: [
            cell('Day', head: true),
            cell('Starts (local)', head: true),
            cell('Candidates', head: true, right: true),
            cell('Confirmed', head: true, right: true),
            cell('At night', head: true, right: true),
            cell('Patient presses', head: true, right: true),
          ]),
          for (final d in s.perDay)
            pw.TableRow(children: [
              cell('${d.index + 1}'),
              cell(_dateTime(d.startLocal).replaceAll(RegExp(r':\d\d$'), '')),
              cell('${d.candidates}', right: true),
              cell('${d.confirmed}', right: true),
              cell('${d.nightCandidates}', right: true),
              cell('${d.patientMarkers}', right: true),
            ]),
        ],
      ),
    );
  }

  pw.Widget _quality(SignalQualitySummary q, DateTime recordingStart) {
    const maxListed = 4;
    final stretches = q.lowQualityStretches;
    final lines = <String>[
      'Usable signal: ${q.usablePercent.toStringAsFixed(1)} % (${_duration(q.usableSec)}). '
          'Stretches of poor signal quality are marked on the overview figure.',
      if (stretches.isEmpty) 'No low-quality stretches were found.',
      if (stretches.isNotEmpty) '${stretches.length} low-quality stretch${stretches.length == 1 ? '' : 'es'}:',
      for (final s in stretches.take(maxListed))
        '    ${_dateTime(recordingStart.add(Duration(seconds: s.startSec.round()))).replaceAll(RegExp(r':\d\d$'), '')}, lasting ${_duration(s.durationSec)}',
      if (stretches.length > maxListed) '    and ${stretches.length - maxListed} more',
      if (q.linkLossPercent == null && q.leadOffPercent == null)
        'Link loss and electrode lead-off were not measured for this recording.',
      if (q.linkLossPercent != null) 'Link loss: ${q.linkLossPercent!.toStringAsFixed(2)} % of samples.',
      if (q.leadOffPercent != null) 'Electrode lead-off: ${q.leadOffPercent!.toStringAsFixed(1)} % of the time.',
    ];
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 12),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        _text('Signal quality', size: 10, bold: true),
        pw.SizedBox(height: 3),
        for (final l in lines) _text(l, size: 8.5, color: l.startsWith('    ') ? _muted : _ink),
      ]),
    );
  }

  // ── overview figure ─────────────────────────────────────────────────────────

  static const double _timelineHeight = 126;

  pw.Widget _timeline(ReportData d) {
    final dur = d.header.durationSec.toDouble();
    final start = d.header.recordingStartLocal;
    final sod0 = start.hour * 3600 + start.minute * 60 + start.second;
    const six = 6 * 3600;
    final first = (six - sod0 % six) % six;
    final ticks = <double>[for (var t = first.toDouble(); t < dur; t += six) t];

    pw.Widget swatch(PdfColor c, String label, {bool line = false, bool diamond = false, bool dot = false}) =>
        pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
          if (dot)
            pw.Container(width: 6, height: 6, decoration: pw.BoxDecoration(color: c, shape: pw.BoxShape.circle))
          else if (diamond)
            pw.Transform.rotate(angle: math.pi / 4, child: pw.Container(width: 5, height: 5, color: c))
          else
            pw.Container(width: line ? 2 : 9, height: line ? 9 : 7, color: c),
          pw.SizedBox(width: 4),
          _text(label, size: 7.5, color: _muted),
        ]);

    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.SizedBox(
        width: _contentWidth,
        height: _timelineHeight,
        child: pw.CustomPaint(
          size: const PdfPoint(_contentWidth, _timelineHeight),
          painter: (g, size) => _paintTimeline(g, size, d),
        ),
      ),
      pw.SizedBox(
        width: _contentWidth,
        height: 12,
        child: pw.Stack(children: [
          for (final t in ticks)
            pw.Positioned(
              left: math.min(_contentWidth - 22, math.max(0, t / dur * _contentWidth - 11)),
              top: 2,
              child: _text(_clock(start.add(Duration(seconds: t.round()))), size: 7, color: _muted),
            ),
        ]),
      ),
      pw.SizedBox(height: 4),
      pw.Wrap(spacing: 12, runSpacing: 3, children: [
        swatch(_bar, 'candidate (bar height = confidence)', line: true),
        swatch(_high, 'possible seizure, score 0.80 or more', line: true),
        swatch(_ink, 'included in this report', dot: true),
        swatch(_marker, 'patient button press', diamond: true),
        swatch(_night, 'night, 23:00 to 07:00'),
        swatch(_lowQuality, 'low-quality signal'),
      ]),
    ]);
  }

  void _paintTimeline(PdfGraphics g, PdfPoint size, ReportData d) {
    final w = size.x, h = size.y;
    final dur = d.header.durationSec.toDouble();
    if (dur <= 0) return;
    double x(double t) => t / dur * w;
    const yBase = 8.0;
    final yTop = h - 4;
    final ph = yTop - yBase;

    // Night bands.
    final start = d.header.recordingStartLocal;
    final sod0 = start.hour * 3600 + start.minute * 60 + start.second;
    g.setFillColor(_night);
    for (var k = -1; k <= d.summary.days; k++) {
      final a = (23 * 3600 - sod0 + k * 86400).toDouble();
      final lo = math.max(0.0, a), hi = math.min(dur, a + 8 * 3600);
      if (hi > lo) {
        g.drawRect(x(lo), yBase, x(hi) - x(lo), ph);
        g.fillPath();
      }
    }

    // Low-quality stretches.
    g.setFillColor(_lowQuality);
    for (final s in d.summary.quality.lowQualityStretches) {
      g.drawRect(x(s.startSec), yBase, math.max(0.8, x(s.startSec + s.durationSec) - x(s.startSec)), ph);
      g.fillPath();
    }

    // Day boundaries.
    g.setStrokeColor(_rule);
    g.setLineWidth(0.4);
    for (var t = 86400.0; t < dur; t += 86400) {
      g.drawLine(x(t), yBase, x(t), yTop);
    }
    g.strokePath();

    // EEG envelope: the quietest-to-loudest range of every bin, over all channels.
    final ov = d.overview;
    if (ov.count > 0) {
      final tops = <double>[], bottoms = <double>[];
      for (var i = 0; i < ov.count; i++) {
        var hi = -double.infinity, lo = double.infinity;
        for (var c = 0; c < ov.eegMax.length; c++) {
          hi = math.max(hi, ov.eegMax[c][i]);
          lo = math.min(lo, ov.eegMin[c][i]);
        }
        tops.add(hi);
        bottoms.add(lo);
      }
      final sorted = [...tops]..sort();
      final ref = math.max(1.0, sorted[sorted.length ~/ 2] * 1.8); // events clip instead of flattening the rest
      final mid = yBase + ph * 0.42;
      final half = ph * 0.2;
      double yOf(double v) => mid + (v / ref).clamp(-1.0, 1.0) * half;
      g.setFillColor(_envelope);
      g.moveTo(x(ov.startSec), yOf(tops[0]));
      for (var i = 0; i < ov.count; i++) {
        g.lineTo(x(ov.startSec + (i + 0.5) * ov.binSec), yOf(tops[i]));
      }
      for (var i = ov.count - 1; i >= 0; i--) {
        g.lineTo(x(ov.startSec + (i + 0.5) * ov.binSec), yOf(bottoms[i]));
      }
      g.closePath();
      g.fillPath();
    }

    // Events: dim ones first so the strong ones are never hidden.
    final barMax = ph * 0.64;
    List<TimelineEvent> pick(bool Function(TimelineEvent) f) => d.timeline.where(f).toList();
    bool isAuto(TimelineEvent e) => e.source == EventSource.auto;
    final passes = <(List<TimelineEvent>, PdfColor, double)>[
      (pick((e) => isAuto(e) && e.status == ReviewStatus.dismissed), _barDim, 0.8),
      (pick((e) => isAuto(e) && e.status != ReviewStatus.dismissed && (e.confidence ?? 0) < kHighConfidence), _bar, 0.9),
      (pick((e) => isAuto(e) && e.status != ReviewStatus.dismissed && (e.confidence ?? 0) >= kHighConfidence), _high, 1.5),
    ];
    for (final (events, color, width) in passes) {
      g.setStrokeColor(color);
      g.setLineWidth(width);
      for (final e in events) {
        g.drawLine(x(e.startSec), yBase, x(e.startSec), yBase + (e.confidence ?? 0) * barMax);
      }
      g.strokePath();
    }
    g.setFillColor(_ink);
    for (final e in d.timeline.where((e) => isAuto(e) && e.selected)) {
      g.drawEllipse(x(e.startSec), yBase + (e.confidence ?? 0) * barMax + 3, 1.8, 1.8);
      g.fillPath();
    }

    // Patient button presses: a diamond near the top.
    g.setFillColor(_marker);
    for (final e in d.timeline.where((e) => e.source == EventSource.patientButton)) {
      final cx = x(e.startSec), cy = yTop - 5;
      g.moveTo(cx, cy + 3.2);
      g.lineTo(cx + 3.2, cy);
      g.lineTo(cx, cy - 3.2);
      g.lineTo(cx - 3.2, cy);
      g.closePath();
      g.fillPath();
    }

    // Axis.
    g.setStrokeColor(_ink);
    g.setLineWidth(0.6);
    g.drawLine(0, yBase, w, yBase);
    g.strokePath();
  }

  // ── one event ───────────────────────────────────────────────────────────────

  static const double _headBase = 52; // title, time and details lines
  static const double _headNote = 32; // plus room for a three-line reviewer note
  static const double _eegRow = 46;
  static const double _motionHeight = 50;

  String _statusLabel(ReviewStatus s) => switch (s) {
        ReviewStatus.confirmed => 'Confirmed by reviewer',
        ReviewStatus.dismissed => 'Dismissed by reviewer',
        ReviewStatus.candidate => 'Not yet reviewed',
        ReviewStatus.unsure => 'Marked not sure by reviewer',
      };

  pw.Widget _entry(ReportData d, ReportEntry e) {
    final w = e.window;
    final eegHeight = _eegRow * w.channels;
    final hasNote = e.review.note != null;
    final headHeight = _headBase + (hasNote ? _headNote : 0);
    final total = headHeight + eegHeight + 5 + _motionHeight + 5 + _motionHeight + 18 + 6;
    final ev = e.event;
    final auto = ev.source == EventSource.auto;
    final note = e.review.note;
    const noteLimit = 230; // what three lines hold; the full note is always in events.csv
    final noteText = note == null ? null : (note.length > noteLimit ? '${note.substring(0, noteLimit - 3)}... (shortened, full note in events.csv)' : note);

    // EEG scale shared by all channels, so amplitudes compare by eye.
    var peak = 1.0;
    for (final ch in w.eeg) {
      for (final v in ch) {
        if (!v.isNaN) peak = math.max(peak, v.abs());
      }
    }
    final half = [25.0, 50.0, 100.0, 200.0, 400.0, 800.0, 1600.0].firstWhere((r) => r >= peak * 1.05, orElse: () => peak * 1.1);
    final barUv = half / 2; // the scale bar spans half of a row's half-range

    final accel = [w.accelX, w.accelY, w.accelZ];
    final gyro = [w.gyroX, w.gyroY, w.gyroZ];
    var aLo = double.infinity, aHi = -double.infinity;
    for (final s in accel) {
      for (final v in s) {
        if (!v.isNaN) {
          aLo = math.min(aLo, v);
          aHi = math.max(aHi, v);
        }
      }
    }
    if (!aLo.isFinite) {
      aLo = -1;
      aHi = 1;
    }
    final aPad = math.max(0.05, (aHi - aLo) * 0.1);
    aLo -= aPad;
    aHi += aPad;
    var gPeak = 5.0;
    for (final s in gyro) {
      for (final v in s) {
        if (!v.isNaN) gPeak = math.max(gPeak, v.abs());
      }
    }
    final gRange = [10.0, 25.0, 50.0, 100.0, 250.0, 500.0, 1000.0, 2000.0].firstWhere((r) => r >= gPeak * 1.05, orElse: () => gPeak * 1.1);

    final chartW = _contentWidth - _gutter;
    pw.Widget gutterLabel(String text, double top, {bool small = false}) =>
        pw.Positioned(left: 0, top: top, child: _text(text, size: small ? 6.5 : 7.5, color: _muted));

    pw.Widget chart({
      required double height,
      required void Function(PdfGraphics, PdfPoint) painter,
      required List<pw.Widget> gutter,
      List<pw.Widget> overlay = const [],
      List<pw.Widget> gutterExtra = const [],
    }) =>
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.SizedBox(width: _gutter, height: height, child: pw.Stack(children: [...gutter, ...gutterExtra])),
          pw.SizedBox(
            width: chartW,
            height: height,
            child: pw.Stack(children: [
              pw.CustomPaint(size: PdfPoint(chartW, height), painter: painter),
              ...overlay,
            ]),
          ),
        ]);

    // Which colour is which axis.
    pw.Widget xyzKey() => pw.Positioned(
          left: 0,
          top: 8,
          child: pw.RichText(
            text: pw.TextSpan(style: const pw.TextStyle(fontSize: 7), children: [
              const pw.TextSpan(text: 'x   ', style: pw.TextStyle(color: _ink)),
              const pw.TextSpan(text: 'y   ', style: pw.TextStyle(color: _marker)),
              const pw.TextSpan(text: 'z', style: pw.TextStyle(color: _high)),
            ]),
          ),
        );

    final axisLabels = <pw.Widget>[
      for (var s = -w.preSec.round(); s <= (w.durationSec - w.preSec).round(); s += 5)
        pw.Positioned(
          left: math.min(chartW - 14.0, math.max(0, (s + w.preSec) / w.durationSec * chartW - 6)),
          top: 1,
          child: _text(s == 0 ? '0' : (s > 0 ? '+$s' : '$s'), size: 6.5, color: s == 0 ? _ink : _muted),
        ),
      pw.Positioned(right: 0, top: 9, child: _text('seconds from event start', size: 6.5, color: _muted)),
    ];

    return pw.SizedBox(
      height: total,
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.SizedBox(
          height: headHeight,
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Container(height: 0.6, color: _rule),
            pw.SizedBox(height: 4),
            pw.Row(children: [
              _text('${ev.id}   ${auto ? 'Automatic candidate' : 'Patient button press'}', size: 10, bold: true),
              pw.Spacer(),
              _text(_statusLabel(e.review.status), size: 9, bold: true, color: e.review.status == ReviewStatus.dismissed ? _muted : _ink),
            ]),
            pw.SizedBox(height: 2),
            _text(
              '${_dateTime(e.startLocal)}   ${e.night ? 'night' : 'daytime'}'
              '${e.durationSec > 0 ? '   lasting ${e.durationSec.toStringAsFixed(1)} s' : ''}',
              size: 8.5,
            ),
            _text(
              [
                if (ev.confidence != null) 'confidence ${ev.confidence!.toStringAsFixed(2)}',
                'signal quality ${(ev.quality * 100).round()} %',
                if (ev.channels.isNotEmpty) 'channels ${ev.channels.map((c) => c + 1).join(', ')}',
              ].join('   '),
              size: 8.5,
              color: _muted,
            ),
            if (noteText != null) ...[
              pw.SizedBox(height: 2),
              _text('Reviewer note: $noteText', size: 8.5, italic: true, maxLines: 3),
            ],
          ]),
        ),
        // EEG, all channels stacked, one scale.
        chart(
          height: eegHeight,
          painter: (g, size) => _paintEeg(g, size, w, e.durationSec, half, barUv),
          gutter: [
            for (var c = 0; c < w.channels; c++) gutterLabel('EEG ${c + 1}', _eegRow * c + _eegRow / 2 - 4),
          ],
          overlay: [
            pw.Positioned(right: 10, top: 2, child: _text('${barUv.round()} µV', size: 6.5, color: _muted)),
          ],
        ),
        pw.SizedBox(height: 5),
        chart(
          height: _motionHeight,
          painter: (g, size) => _paintMotion(g, size, w, accel, aLo, aHi, const [_ink, _marker, _high]),
          gutter: [
            gutterLabel('Accel', _motionHeight / 2 - 9),
            gutterLabel('g', _motionHeight / 2 + 1, small: true),
            gutterLabel(aHi.toStringAsFixed(1), 0, small: true),
            gutterLabel(aLo.toStringAsFixed(1), _motionHeight - 8, small: true),
          ],
          gutterExtra: [xyzKey()],
        ),
        pw.SizedBox(height: 5),
        chart(
          height: _motionHeight,
          painter: (g, size) => _paintMotion(g, size, w, gyro, -gRange, gRange, const [_ink, _marker, _high]),
          gutter: [
            gutterLabel('Gyro', _motionHeight / 2 - 9),
            gutterLabel('deg/s', _motionHeight / 2 + 1, small: true),
            gutterLabel('+${gRange.round()}', 0, small: true),
            gutterLabel('-${gRange.round()}', _motionHeight - 8, small: true),
          ],
          gutterExtra: [xyzKey()],
        ),
        pw.Row(children: [
          pw.SizedBox(width: _gutter),
          pw.SizedBox(width: chartW, height: 18, child: pw.Stack(children: axisLabels)),
        ]),
      ]),
    );
  }

  /// The frame every signal chart shares: event span, 5 s grid, event-start line.
  void _paintFrame(PdfGraphics g, double wd, double ht, SignalWindow w, double eventSec) {
    double x(double sec) => sec / w.durationSec * wd;
    g.setFillColor(_span);
    g.drawRect(x(w.preSec), 0, math.max(1.2, x(w.preSec + eventSec) - x(w.preSec)), ht);
    g.fillPath();
    g.setStrokeColor(_grid);
    g.setLineWidth(0.4);
    for (var s = 0.0; s <= w.durationSec + 1e-6; s += 5) {
      g.drawLine(x(s), 0, x(s), ht);
    }
    g.strokePath();
    g.setStrokeColor(_ink);
    g.setLineWidth(0.6);
    g.drawLine(x(w.preSec), 0, x(w.preSec), ht);
    g.strokePath();
    g.setStrokeColor(_rule);
    g.setLineWidth(0.5);
    g.drawRect(0, 0, wd, ht);
    g.strokePath();
  }

  void _paintEeg(PdfGraphics g, PdfPoint size, SignalWindow w, double eventSec, double halfUv, double barUv) {
    final wd = size.x, ht = size.y;
    _paintFrame(g, wd, ht, w, eventSec);
    final rowH = ht / w.channels;
    final k = (rowH / 2 * 0.92) / halfUv; // points per µV
    g.setStrokeColor(_rule);
    g.setLineWidth(0.3);
    for (var c = 1; c < w.channels; c++) {
      g.drawLine(0, ht - rowH * c, wd, ht - rowH * c);
    }
    g.strokePath();
    g.setStrokeColor(_ink);
    g.setLineWidth(0.45);
    for (var c = 0; c < w.channels; c++) {
      _trace(g, w.eeg[c], wd, ht - rowH * (c + 0.5), k, rowH / 2);
    }
    // Scale bar, top right of the first row.
    g.setStrokeColor(_ink);
    g.setLineWidth(1.2);
    final bx = wd - 4, byTop = ht - 3, byBottom = byTop - barUv * k;
    g.drawLine(bx, byTop, bx, byBottom);
    g.strokePath();
  }

  void _paintMotion(PdfGraphics g, PdfPoint size, SignalWindow w, List<Float32List> series, double lo, double hi,
      List<PdfColor> colors) {
    final wd = size.x, ht = size.y;
    _paintFrame(g, wd, ht, w, 0);
    final span = hi - lo;
    if (span <= 0) return;
    if (lo < 0 && hi > 0) {
      g.setStrokeColor(_rule);
      g.setLineWidth(0.3);
      final y0 = (0 - lo) / span * ht;
      g.drawLine(0, y0, wd, y0);
      g.strokePath();
    }
    for (var i = 0; i < series.length; i++) {
      g.setStrokeColor(colors[i % colors.length]);
      g.setLineWidth(0.5);
      // y = (value - lo) / span * height, so the data range fills the chart.
      _trace(g, series[i], wd, -lo / span * ht, ht / span, double.infinity);
    }
  }

  /// Min/max-per-column polyline of `v` across `width` points. A value `s` is drawn at
  /// `yCenter + s * k`, limited to `±limit` around the centre; NaN breaks the line.
  void _trace(PdfGraphics g, Float32List v, double width, double yCenter, double k, double limit) {
    final n = v.length;
    if (n == 0) return;
    final cols = math.max(1, width.floor());
    var open = false;
    for (var col = 0; col < cols; col++) {
      final i0 = (col * n / cols).floor();
      final i1 = math.max(i0 + 1, ((col + 1) * n / cols).floor());
      var lo = double.infinity, hi = -double.infinity;
      var iLo = -1, iHi = -1;
      for (var i = i0; i < i1 && i < n; i++) {
        final s = v[i];
        if (s.isNaN) continue;
        if (s < lo) {
          lo = s;
          iLo = i;
        }
        if (s > hi) {
          hi = s;
          iHi = i;
        }
      }
      if (iLo < 0) {
        if (open) {
          g.strokePath();
          open = false;
        }
        continue;
      }
      final x = (col + 0.5) * width / cols;
      final first = iLo < iHi ? lo : hi;
      final second = iLo < iHi ? hi : lo;
      double y(double s) => yCenter + (s * k).clamp(-limit, limit);
      if (!open) {
        g.moveTo(x, y(first));
        open = true;
      } else {
        g.lineTo(x, y(first));
      }
      if (second != first) g.lineTo(x, y(second));
    }
    if (open) g.strokePath();
  }

  // ── last page ───────────────────────────────────────────────────────────────

  pw.Widget _method(ReportData d) {
    final lines = <String>[
      'Candidate events are found automatically and ranked by a confidence score. The score is a ranking aid, not a probability, and it has not been validated against clinician-scored recordings.',
      'A clinician decides what each event is. Events marked "Confirmed" were confirmed by the reviewer; the rest are suggestions.',
      'Signals are shown as recorded, in microvolts (EEG), g (accelerometer) and degrees per second (gyro), without filtering. Time zero in each event chart is the start of the event.',
      'Stretches of poor signal quality are marked on the overview figure. Link loss and electrode lead-off are reported only when the recording measured them.',
      if (d.header.synthetic) 'This report was made from a synthetic sample recording to demonstrate the report format. It does not describe a real person.',
    ];
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      for (final l in lines)
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 4),
          child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.SizedBox(width: 10, child: _text('-', size: 8.5, color: _muted)),
            pw.Expanded(child: _text(l, size: 8.5)),
          ]),
        ),
      pw.SizedBox(height: 6),
      _text(d.disclaimer, size: 8.5, bold: true),
    ]);
  }

  pw.Widget _signOff() => pw.Row(children: [
        pw.Expanded(child: _line('Reviewed by')),
        pw.SizedBox(width: 24),
        pw.SizedBox(width: 120, child: _line('Date')),
      ]);

  pw.Widget _line(String label) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Container(height: 0.6, color: _ink),
        pw.SizedBox(height: 3),
        _text(label, size: 8, color: _muted),
      ]);
}
