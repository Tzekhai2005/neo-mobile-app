import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../app/app_services.dart';
import '../data/recording_source.dart';
import '../data/review_event.dart';
import '../report/report_models.dart';
import 'review_models.dart';
import 'timeline_model.dart';

enum RangeMode { oneDay, threeDays }

enum ReviewLoad { loading, ready, unavailable, failed }

/// The state of the Review page: which days are shown and how far they are zoomed,
/// the filter, the selected event, and the reviewer's decisions. It reads and writes
/// the recording and the decisions only through [AppServices].
class ReviewController extends ChangeNotifier {
  static const _secPerDay = 86400.0;

  /// The most zoomed-in view is ten minutes wide.
  static const minViewSec = 600.0;

  final AppServices _s;

  ReviewController(this._s);

  ReviewLoad _load = ReviewLoad.loading;
  String? _loadMessage;
  String? _saveError;
  List<ReviewEvent> _events = const [];
  RecordingInfo? _info;

  RangeMode _mode = RangeMode.oneDay;
  int _firstDay = 0;
  TimeRange _visible = const TimeRange(0, 0);

  ReviewFilter _filter = ReviewFilter.all;
  String? _selectedId;
  bool _showSignal = false;

  int _version = 0; // bumped whenever the events change, so cached drawings are rebuilt
  TimelineSnapshot? _snap;
  String _snapKey = '';
  ReviewLists? _lists;
  String _listsKey = '';

  Future<void> _writes = Future.value();
  final Map<String, Future<SignalWindow>> _windows = {};

  // ── what the page reads ─────────────────────────────────────────────────────

  ReviewLoad get loadState => _load;

  /// Plain words for why there is nothing to show, when [loadState] says so.
  String? get loadMessage => _loadMessage;

  /// Set when a decision could not be saved; cleared by the next one that is.
  String? get saveError => _saveError;

  RecordingInfo get info => _info!;
  RangeMode get mode => _mode;
  ReviewFilter get filter => _filter;
  bool get showSignal => _showSignal;
  String? get selectedId => _selectedId;
  List<ReviewEvent> get events => _events;
  TimeRange get visible => _visible;

  int get dayCount => math.max(1, (info.durationSec / _secPerDay).ceil());
  int get windowDays => math.min(_mode == RangeMode.oneDay ? 1 : 3, dayCount);
  int get firstDay => _firstDay;
  int get lastDay => _firstDay + windowDays - 1;

  /// The days on show, before any zoom.
  TimeRange get bounds => TimeRange(_firstDay * _secPerDay, math.min((_firstDay + windowDays) * _secPerDay, info.durationSec.toDouble()));

  bool get isZoomed => _visible.lengthSec < bounds.lengthSec - 1e-6;

  bool canPage(int delta) => windowDays < dayCount && (_firstDay + delta) >= 0 && (_firstDay + delta) <= dayCount - windowDays;

  /// "Mon 5 Oct" for one day, "Mon 5 Oct to Wed 7 Oct" for several.
  String get rangeLabel {
    // Days are named by the date they start on, as everywhere else in the app.
    final a = dateLabel(info.localTimeAt(firstDay * _secPerDay));
    if (windowDays == 1) return a;
    return '$a to ${dateLabel(info.localTimeAt(lastDay * _secPerDay))}';
  }

  /// The events in the days on show, in the filter, as the list shows them.
  ReviewLists get lists {
    final key = '$_version|$_firstDay|$windowDays|${_filter.index}';
    if (_lists == null || _listsKey != key) {
      final rate = info.eegRateHz;
      final b = bounds;
      _lists = buildLists([for (final e in _events) if (b.contains(e.event.startSec(rate))) e], _filter);
      _listsKey = key;
    }
    return _lists!;
  }

  /// Progress over every event of the recording, not just the days on show.
  ReviewCounts get counts => ReviewCounts.of(_events);

  ReviewEvent? get selected {
    final id = _selectedId;
    if (id == null) return null;
    for (final e in _events) {
      if (e.event.id == id) return e;
    }
    return null;
  }

  /// Where the selected event is in the list that Next and Previous walk through
  /// (1-based), or null when it is not in that list (a filter hides it).
  int? get position {
    final i = lists.ordered.indexWhere((e) => e.event.id == _selectedId);
    return i < 0 ? null : i + 1;
  }

  int get positionCount => lists.ordered.length;

  // ── loading ─────────────────────────────────────────────────────────────────

  Future<void> load() async {
    _load = ReviewLoad.loading;
    notifyListeners();
    try {
      await _s.loadReview();
      _info = _s.recording.info;
      _events = _s.reviewEvents();
      _windows.clear();
      _firstDay = 0;
      _selectedId = null;
      _version++;
      _visible = bounds;
      _load = ReviewLoad.ready;
    } on StateError {
      _load = ReviewLoad.unavailable;
      _loadMessage = "Review isn't available on this device, because it has no app storage for decisions.";
    } catch (_) {
      _load = ReviewLoad.failed;
      _loadMessage = 'The recording could not be opened. Choose another from the start page.';
    }
    notifyListeners();
  }

  /// Read the decisions again from the store, so what is shown is what is saved.
  void _refresh() {
    if (_disposed) return;
    _events = _s.reviewEvents();
    _version++;
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // ── days and zoom ───────────────────────────────────────────────────────────

  void setMode(RangeMode m) {
    if (m == _mode) return;
    _mode = m;
    _firstDay = _firstDay.clamp(0, dayCount - windowDays);
    resetZoom();
  }

  /// Move the days on show earlier (-1) or later (+1) by a day.
  void pageDays(int delta) {
    if (!canPage(delta)) return;
    _firstDay += delta;
    resetZoom();
  }

  void resetZoom() {
    _visible = bounds;
    _version++;
    notifyListeners();
  }

  /// Zoom by [factor] (above 1 zooms in) around the point [focal] (0 to 1) across the view.
  void zoom(double factor, double focal) {
    if (factor <= 0 || factor.isNaN) return;
    final b = bounds;
    final len = _visible.lengthSec;
    final newLen = (len / factor).clamp(math.min(minViewSec, b.lengthSec), b.lengthSec).toDouble();
    final f = focal.clamp(0.0, 1.0);
    final focalSec = _visible.startSec + f * len;
    _setVisible(focalSec - f * newLen, newLen);
  }

  /// Slide the view by [seconds] (positive goes later).
  void pan(double seconds) => _setVisible(_visible.startSec + seconds, _visible.lengthSec);

  void _setVisible(double start, double len) {
    final b = bounds;
    final s = start.clamp(b.startSec, math.max(b.startSec, b.endSec - len)).toDouble();
    final next = TimeRange(s, s + len);
    if (next.startSec == _visible.startSec && next.endSec == _visible.endSec) return;
    _visible = next;
    notifyListeners();
  }

  /// Bring the moment [sec] into view, centred if it was off to the side.
  void ensureVisible(double sec) {
    if (_visible.contains(sec)) return;
    _setVisible(sec - _visible.lengthSec / 2, _visible.lengthSec);
  }

  // ── the list and the selection ──────────────────────────────────────────────

  void setFilter(ReviewFilter f) {
    if (f == _filter) return;
    _filter = f;
    notifyListeners();
  }

  void toggleShowSignal() {
    _showSignal = !_showSignal;
    notifyListeners();
  }

  void select(String id) {
    final e = _events.where((e) => e.event.id == id);
    if (e.isEmpty) return;
    _selectedId = id;
    ensureVisible(e.first.event.startSec(info.eegRateHz));
    notifyListeners();
  }

  void clearSelection() {
    if (_selectedId == null) return;
    _selectedId = null;
    notifyListeners();
  }

  void next() => _step(1);
  void previous() => _step(-1);

  void _step(int delta) {
    final ordered = lists.ordered;
    if (ordered.isEmpty) return;
    final i = ordered.indexWhere((e) => e.event.id == _selectedId);
    final j = i < 0 ? (delta > 0 ? 0 : ordered.length - 1) : (i + delta).clamp(0, ordered.length - 1);
    select(ordered[j].event.id);
  }

  // ── decisions ───────────────────────────────────────────────────────────────

  Future<void> confirm() => _decide(ReviewStatus.confirmed);
  Future<void> dismiss() => _decide(ReviewStatus.dismissed);

  /// Back to unreviewed. A note is kept.
  Future<void> undo() => _decide(ReviewStatus.candidate);

  Future<void> _decide(ReviewStatus status) {
    final id = _selectedId;
    if (id == null) return Future.value();
    return _write(() => _s.reviews.setStatus(id, status));
  }

  /// Set the note of the selected event; blank clears it.
  Future<void> setNote(String text) {
    final id = _selectedId;
    return id == null ? Future.value() : setNoteFor(id, text);
  }

  /// Set the note of a particular event, which need not be the selected one: a note
  /// typed on an event is saved to it even if the reviewer has already moved on.
  Future<void> setNoteFor(String id, String text) => _write(() => _s.reviews.setNote(id, text));

  /// Writes happen one after another, so a quick Confirm then Note cannot cross.
  Future<void> _write(Future<void> Function() action) {
    return _writes = _writes.then((_) async {
      try {
        await action();
        _saveError = null;
      } catch (_) {
        _saveError = 'That could not be saved. Try again.';
      }
      _refresh(); // whatever happened, show what is actually saved
    });
  }

  // ── what the timeline and the sheet draw ────────────────────────────────────

  /// The stored signal around an event. Kept for the last few events looked at, so
  /// stepping back and forth is quick.
  Future<SignalWindow> windowFor(String id) {
    final f = _windows.remove(id) ?? _s.recording.eventWindow(id);
    _windows[id] = f; // most recent last
    while (_windows.length > 4) {
      _windows.remove(_windows.keys.first);
    }
    // A failure is not worth keeping: the next look tries again.
    f.then((_) {}, onError: (Object _) {
      if (identical(_windows[id], f)) _windows.remove(id);
    });
    return f;
  }

  /// The timeline at the current zoom for a view [width] pixels wide.
  TimelineSnapshot snapshotFor(double width) {
    final key = '$_version|${_visible.startSec}|${_visible.endSec}|${width.round()}';
    if (_snap != null && _snapKey == key) return _snap!;
    final rate = info.eegRateHz;
    final v = _visible;
    double xOf(double sec) => (sec - v.startSec) / v.lengthSec * width;
    final inView = [
      for (final e in _events)
        if (e.event.startSec(rate) < v.endSec && e.event.startSec(rate) + e.event.durationSec(rate) >= v.startSec) e
    ];
    final ov = _s.recording.overview(v, math.max(1, width.floor()));
    _snap = TimelineSnapshot(
      visible: v,
      overview: ov,
      bars: clusterEvents([for (final e in inView) if (!e.isMarker) e], xOf: xOf, eegRateHz: rate),
      markers: clusterEvents([for (final e in inView) if (e.isMarker) e], xOf: xOf, eegRateHz: rate, minGapPx: 4, minWidthPx: 10),
      ticks: axisTicks(v, info),
      poor: poorStretches(ov, kUsableQuality),
    );
    _snapKey = key;
    return _snap!;
  }
}
