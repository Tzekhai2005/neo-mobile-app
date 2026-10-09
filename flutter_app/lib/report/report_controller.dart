import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../app/app_services.dart';
import '../data/recording_source.dart';
import '../data/review_event.dart';
import '../review/review_models.dart';
import 'pdf_previewer.dart';
import 'report_choice.dart';
import 'report_exporter.dart';
import 'report_selection.dart';
import 'report_settings.dart';

enum ReportStage {
  loading,

  /// Nothing to report from: no storage, or the recording would not open.
  unavailable,

  /// Choosing what goes in.
  editing,

  /// Writing the files.
  building,

  /// The report exists; its pages are on show and it can be shared.
  ready,
}

/// The state of the Report page: which events and days go in, the patient label,
/// and the one-click flow from Create to a preview to Share.
class ReportController extends ChangeNotifier {
  final AppServices _s;

  ReportController(this._s);

  ReportStage _stage = ReportStage.loading;
  String? _message; // why unavailable
  String? _error; // the last thing that went wrong while building or sharing

  List<ReviewEvent> _events = const [];
  RecordingInfo? _info;
  ReportSettings? _settings;

  int _firstDay = 0;
  int _lastDay = 0;
  ReportSelection _selection = const ReportSelection({});
  String _label = '';

  ExportedReport? _exported;
  List<PreviewPage> _pages = const [];
  int _pageCount = 0;
  bool _previewFailed = false;
  int _eventsInReport = 0;
  DayRange? _builtDays;
  bool _sharing = false;
  bool _disposed = false;
  Future<void> _labelWrites = Future.value();

  // ── what the page reads ─────────────────────────────────────────────────────

  ReportStage get stage => _stage;
  String? get message => _message;
  String? get error => _error;
  RecordingInfo get info => _info!;
  ReportSelection get selection => _selection;
  String get patientLabel => _label;
  int get firstDay => _firstDay;
  int get lastDay => _lastDay;
  int get dayCount => math.max(1, (info.durationSec / 86400).ceil());

  /// The days the report covers, or null for the whole recording.
  DayRange? get days => (_firstDay == 0 && _lastDay == dayCount - 1) ? null : DayRange(_firstDay, _lastDay);

  /// Progress over every event of the recording.
  ReviewCounts get counts => ReviewCounts.of(_events);

  /// The events in the days the report covers.
  List<ReviewEvent> get inDays {
    final rate = info.eegRateHz;
    final from = _firstDay * 86400.0, to = (_lastDay + 1) * 86400.0;
    return [
      for (final e in _events)
        if (e.event.startSec(rate) >= from && e.event.startSec(rate) < to) e
    ];
  }

  ReportGroups get groups => buildGroups(inDays);

  /// How many of the chosen events are in the days covered (the others are left out).
  int get selectedCount => inDays.where((e) => _selection.contains(e.event.id)).length;

  /// The preset the choice is exactly equal to, or null for a custom choice.
  ReportPreset? get preset => presetOf(_selection, inDays);

  /// True when nothing is confirmed, so the choice fell back to the top candidates.
  bool get isFallback => _selection.isFallback;

  ExportedReport? get exported => _exported;
  List<PreviewPage> get pages => _pages;
  int get pageCount => _pageCount;
  bool get previewFailed => _previewFailed;
  int get eventsInReport => _eventsInReport;
  DayRange? get builtDays => _builtDays;
  bool get isSharing => _sharing;

  // ── loading ─────────────────────────────────────────────────────────────────

  Future<void> load() async {
    _stage = ReportStage.loading;
    notifyListeners();
    try {
      await _s.loadReview();
      _info = _s.recording.info;
      _events = _s.reviewEvents();
      _settings = await _s.reportSettings();
      _label = _settings!.patientLabel;
      _firstDay = 0;
      _lastDay = dayCount - 1;
      _selection = selectionFor(ReportPreset.confirmed, inDays);
      _stage = ReportStage.editing;
    } on StateError {
      _stage = ReportStage.unavailable;
      _message = "Reports aren't available on this device, because it has no app storage.";
    } catch (_) {
      _stage = ReportStage.unavailable;
      _message = 'The recording could not be opened. Choose another from the start page.';
    }
    notifyListeners();
  }

  /// Read the decisions again, for when the reviewer has been on the Review page.
  void refreshEvents() {
    if (_stage == ReportStage.loading || _stage == ReportStage.unavailable) return;
    _events = _s.reviewEvents();
    // An untouched choice follows the decisions; a hand-made one stays as it is.
    if (_stage == ReportStage.editing && _selection.isFallback) {
      _selection = selectionFor(ReportPreset.confirmed, inDays);
    }
    notifyListeners();
  }

  // ── choosing ────────────────────────────────────────────────────────────────

  void applyPreset(ReportPreset p) {
    _selection = selectionFor(p, inDays);
    notifyListeners();
  }

  void clearSelection() {
    _selection = const ReportSelection({});
    notifyListeners();
  }

  void toggle(String id) {
    _selection = _selection.toggled(id);
    notifyListeners();
  }

  void setGroup(List<ReviewEvent> group, {required bool on}) {
    _selection = withGroup(_selection, group, on: on);
    notifyListeners();
  }

  /// Cover Day [first] to Day [last] (0-based, both included). Reordered if they cross.
  /// A choice that was exactly a preset follows the new days.
  void setDays(int first, int last) {
    final a = first.clamp(0, dayCount - 1), b = last.clamp(0, dayCount - 1);
    final lo = math.min(a, b), hi = math.max(a, b);
    if (lo == _firstDay && hi == _lastDay) return;
    final was = preset;
    _firstDay = lo;
    _lastDay = hi;
    if (was != null) _selection = selectionFor(was, inDays);
    notifyListeners();
  }

  /// The label as typed so far. It applies to the next report at once; saving it for
  /// next time is [saveLabel], which can wait for a pause in the typing. Nothing is
  /// announced to listeners, so it is safe to call from a text field.
  void editLabel(String text) => _label = text.trim();

  /// Saves the current label for next time, without announcing anything (so it is safe
  /// to call as a page goes away). If it cannot be saved the label still holds for this
  /// session; only remembering it failed.
  Future<void> saveLabel() {
    final settings = _settings;
    if (settings == null) return Future.value();
    final text = _label;
    return _labelWrites = _labelWrites.then((_) async {
      try {
        await settings.setPatientLabel(text);
      } catch (_) {}
    });
  }

  /// Sets the patient label and saves it.
  Future<void> setPatientLabel(String text) {
    editLabel(text);
    notifyListeners();
    return saveLabel();
  }

  // ── creating, previewing, sharing ───────────────────────────────────────────

  /// Writes the PDF and the CSV zip, then pictures of the PDF's pages.
  Future<void> create() async {
    if (_stage != ReportStage.editing) return;
    _error = null;
    _stage = ReportStage.building;
    notifyListeners();
    try {
      final days = this.days;
      final chosen = selectedCount;
      final out = await _s.exportReport(
        selection: _selection,
        patientLabel: _label.isEmpty ? null : _label,
        days: days,
        share: false,
      );
      _exported = out;
      _eventsInReport = chosen;
      _builtDays = days;
      _pages = const [];
      _pageCount = 0;
      _previewFailed = false;
      try {
        final bytes = await out.pdf.readAsBytes();
        _pageCount = countPdfPages(bytes);
        _pages = await _s.previewer.render(bytes);
        if (_pages.isEmpty) _previewFailed = true;
      } catch (_) {
        _previewFailed = true; // the report is fine; only the picture of it is missing
      }
      _stage = ReportStage.ready;
    } on ReportExportException catch (e) {
      _error = e.message;
      _stage = ReportStage.editing;
    } catch (_) {
      _error = 'The report could not be created. Try again.';
      _stage = ReportStage.editing;
    }
    notifyListeners();
  }

  /// Opens the share sheet with the report's two files.
  Future<void> share() async {
    final out = _exported;
    if (out == null || _sharing) return;
    _error = null;
    _sharing = true;
    notifyListeners();
    try {
      await _s.shareReport(out);
    } catch (_) {
      _error = 'The share sheet could not be opened. The files are saved on the phone.';
    }
    _sharing = false;
    notifyListeners();
  }

  /// Back to choosing, keeping the choice, to make another report.
  void createAnother() {
    if (_stage != ReportStage.ready) return;
    _exported = null;
    _pages = const [];
    _error = null;
    _stage = ReportStage.editing;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
