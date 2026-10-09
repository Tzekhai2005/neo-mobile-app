import 'dart:async';
import 'dart:io';

import '../config/app_config.dart';
import '../data/dataset.dart';
import '../data/dataset_library.dart';
import '../data/dataset_picker.dart';
import '../data/dataset_readers.dart';
import '../data/file_picker_dataset_picker.dart';
import '../data/review_event.dart';
import '../data/review_store.dart';
import '../data/static_recording_source.dart';
import '../device/device_status.dart';
import '../live/activity_risk.dart';
import '../live/live_feed.dart';
import '../live/live_signal_buffer.dart';
import '../live/seizure_markers.dart';
import '../live/signal_loss.dart';
import '../protocol/neo_client.dart';
import '../report/report_builder.dart';
import '../report/report_exporter.dart';
import '../report/report_fonts.dart';
import '../report/report_fonts_assets.dart';
import '../report/pdf_previewer.dart';
import '../report/report_models.dart';
import '../report/report_settings.dart';
import '../report/report_selection.dart';
import '../report/share_plus_sharer.dart';

/// The one owner of everything that must outlive a single page: the device
/// connection, the live signal buffers, the device status, the review data and
/// the report export. Pages ask for these; they never create their own.
///
/// The device accepts a single control connection, so there must be exactly one
/// [NeoClient]; and the live stream must keep running while the user moves
/// between pages.
class AppServices {
  final NeoClient client;
  final LiveSignalBuffer live;
  final DeviceStatusTracker status;

  /// Where review decisions and exported reports are kept; null where the
  /// platform has no app storage (then review and report calls throw).
  final Directory? dataDir;

  final FileSharer _sharer;
  final DateTime Function() _now;
  late final LiveFeed _feed;
  StreamSubscription<NeoDeviceInfo>? _autoConnect;
  bool _started = false;
  bool _disposed = false;

  final DatasetPicker _picker;
  ReportFonts? _fonts; // given by the caller, or loaded from the app's assets on first export
  DatasetReader? _readerOverride; // tests, or an explicit source; wins over the saved choice
  String? _currentDataset; // null = the bundled demo
  Future<void>? _loading;
  StaticRecordingSource? _recording;
  ReviewStore? _reviews;

  AppServices({
    NeoClient? client,
    Directory? dataDir,
    DatasetReader? reader,
    FileSharer sharer = const SharePlusFileSharer(),
    DatasetPicker picker = const FilePickerDatasetPicker(),
    PdfPreviewer previewer = const PrintingPdfPreviewer(),
    ReportFonts? fonts,
    DateTime Function()? now,
  }) : this._(client ?? NeoClient(), dataDir, reader, sharer, picker, previewer, fonts, now ?? DateTime.now);

  // One client for everything: the tracker and the feed must watch the same one.
  AppServices._(this.client, this.dataDir, this._readerOverride, this._sharer, this._picker, this.previewer, this._fonts, this._now)
      : live = LiveSignalBuffer(),
        status = DeviceStatusTracker(client),
        library = dataDir == null ? null : DatasetLibrary(Directory('${dataDir.path}/datasets')) {
    _feed = LiveFeed(client, live);
    activityRisk = kShowExperimentalRisk ? ActivityRiskMonitor(buffer: live, status: status) : null;
  }

  /// "Seizure now" markers made on the Data page; kept while the app is open.
  final SeizureMarkerStore seizureMarkers = SeizureMarkerStore();

  /// The experimental activity-risk readout; null when [kShowExperimentalRisk] is off.
  late final ActivityRiskMonitor? activityRisk;

  /// Marks the newest sample of the live stream as "Seizure now". Returns null,
  /// and marks nothing, when no sample has arrived yet: a marker needs a place on
  /// the signal.
  SeizureMarker? markSeizure() {
    if (!live.hasData) return null;
    return seizureMarkers.add(streamId: live.streamId, sampleIdx: live.latestEegIndex, at: _now());
  }

  /// The recordings imported by the user; null where the platform has no app storage.
  final DatasetLibrary? library;

  /// Set when the saved recording could not be opened and the demo is shown instead.
  String? datasetNotice;

  // ── device ──────────────────────────────────────────────────────────────────

  /// Starts looking for the device and connects to the first one found, then
  /// reconnects whenever the link drops. Safe to call more than once.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    // Listen before the socket opens: a HELLO can arrive immediately.
    _autoConnect = client.onDeviceDiscovered.listen((dev) => client.connectAndStart(dev));
    activityRisk?.start();
    await client.startDiscovery();
  }

  // ── review ──────────────────────────────────────────────────────────────────

  Directory _requireDataDir() {
    final d = dataDir;
    if (d == null) {
      throw StateError('This platform has no app storage folder, so review decisions and reports are unavailable.');
    }
    return d;
  }

  /// Loads the recording and the saved review decisions. Cached; a failed load
  /// can be retried by calling it again.
  Future<void> loadReview() => _loading ??= _loadReview().catchError((Object e) {
        _loading = null;
        throw e;
      });

  Future<void> _loadReview() async {
    final dir = _requireDataDir();
    datasetNotice = null;

    String? chosen; // the imported recording in use; null = the bundled demo
    var src = StaticRecordingSource(_readerOverride ?? readerFor(kDatasetLocation));
    if (_readerOverride == null) {
      chosen = await library!.selected();
      if (chosen != null) src = StaticRecordingSource(readerFor(library!.locationFor(chosen)));
    }
    try {
      await src.load();
    } on DatasetFormatException catch (e) {
      if (chosen == null) rethrow;
      // The saved recording is broken or gone: say so, and fall back to the demo
      // instead of leaving the app without a recording.
      datasetNotice = 'The recording "$chosen" could not be opened (${e.message}), so the demo recording is shown instead.';
      await library!.select(null);
      chosen = null;
      src = StaticRecordingSource(readerFor(kDatasetLocation));
      await src.load();
    }

    final store = ReviewStore(File('${dir.path}/review_decisions.json'), datasetKey: src.info.datasetKey);
    await store.load();
    _recording = src;
    _reviews = store;
    _currentDataset = chosen;
  }

  /// Use another recording source, or (with no argument) go back to the saved choice.
  Future<void> reloadRecording({DatasetReader? reader}) {
    _readerOverride = reader;
    _loading = null;
    _recording = null;
    _reviews = null;
    return loadReview();
  }

  // ── recordings (the dataset picker) ─────────────────────────────────────────

  DatasetLibrary get _library =>
      library ?? (throw StateError('This platform has no app storage folder, so recordings cannot be imported.'));

  /// The imported recording in use; null means the bundled demo. Call [loadReview] first.
  String? get currentDataset => _currentDataset;

  /// Loss of the current live stream, split into link and device (a snapshot).
  SignalLoss get loss => SignalLoss.read(client: client, buffer: live, status: status.value);

  Future<List<DatasetSummary>> listDatasets() async => _library.list();

  /// Opens the file chooser, imports the chosen zip and switches to it. Returns
  /// null if the user cancelled. Throws [DatasetImportException] with a plain
  /// explanation if the zip is not a usable recording; the current one stays.
  Future<DatasetSummary?> pickAndImportDataset() async {
    _library; // fail before the chooser opens if there is nowhere to import to
    final zip = await _picker.pickZip();
    if (zip == null) return null;
    try {
      return await importDataset(zip);
    } finally {
      // The picker made a cache copy of the zip; it is no longer needed.
      try {
        if (await zip.exists()) await zip.delete();
      } catch (_) {}
    }
  }

  /// Imports a recording zip and switches to it.
  Future<DatasetSummary> importDataset(File zip, {String? name}) async {
    final summary = await _library.importZip(zip, name: name);
    await useDataset(summary.name);
    return summary;
  }

  /// Switch to an imported recording, or the bundled demo when null.
  Future<void> useDataset(String? name) async {
    await _library.select(name);
    await reloadRecording();
  }

  /// Delete an imported recording; the demo is used if it was in use.
  Future<void> removeDataset(String name) async {
    final wasInUse = await _library.selected() == name;
    await _library.remove(name);
    if (wasInUse) await reloadRecording();
  }

  /// The loaded recording. Call [loadReview] first.
  StaticRecordingSource get recording => _recording ?? (throw StateError('call loadReview() first'));

  /// The saved confirm / dismiss / note decisions. Call [loadReview] first.
  ReviewStore get reviews => _reviews ?? (throw StateError('call loadReview() first'));

  /// The recording's events with the reviewer's decisions applied.
  List<ReviewEvent> reviewEvents() => reviews.merge(recording.events());

  // ── report ──────────────────────────────────────────────────────────────────

  /// The report for the current recording and decisions. `selection` defaults to
  /// the one-click choice (confirmed events, or the top candidates if none).
  /// The device named in the report is the one that made the recording, so it is
  /// passed in, never taken from the live connection.
  ///
  /// `days` limits the report to a run of whole days (null = the whole recording).
  /// The default selection is then made from the events of those days only.
  Future<ReportData> buildReport({
    ReportSelection? selection,
    ReportDevice? device,
    String? patientLabel,
    DayRange? days,
  }) async {
    await loadReview();
    final events = reviewEvents();
    final rate = recording.info.eegRateHz;
    final inDays = days == null
        ? events
        : [
            for (final r in events)
              if (r.event.startSec(rate) >= days.startSec && r.event.startSec(rate) < (days.last + 1) * 86400.0) r
          ];
    return ReportBuilder.build(
      source: recording,
      events: events,
      selection: selection ?? ReportSelection.defaultFor(inDays),
      generatedAtUtc: _now().toUtc(),
      device: device,
      patientLabel: patientLabel,
      days: days,
    );
  }

  /// Shows a finished report's pages inside the app before it is shared.
  final PdfPreviewer previewer;

  ReportSettings? _reportSettings;

  /// The patient label and the other settings that outlast a run of the app. Read
  /// once from the app's storage; throws where the platform has none.
  Future<ReportSettings> reportSettings() async {
    final existing = _reportSettings;
    if (existing != null) return existing;
    final s = ReportSettings(File('${_requireDataDir().path}/report_settings.json'));
    await s.load();
    return _reportSettings = s;
  }

  /// Opens the share sheet with the files of a report that was already written.
  Future<void> shareReport(ExportedReport report, {String? subject}) =>
      _sharer.share([report.pdf, report.csvZip], subject: subject ?? 'EEG review report');

  /// One click: build the report, write the PDF and CSV zip, and (by default)
  /// open the share sheet.
  Future<ExportedReport> exportReport({
    ReportSelection? selection,
    ReportDevice? device,
    String? patientLabel,
    DayRange? days,
    bool share = true,
  }) async {
    final dir = _requireDataDir();
    final data = await buildReport(selection: selection, device: device, patientLabel: patientLabel, days: days);
    _fonts ??= await loadReportFontsFromAssets();
    return ReportExporter(outputDir: Directory('${dir.path}/reports'), sharer: _sharer, fonts: _fonts)
        .export(data, share: share);
  }

  // ── lifetime ────────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _autoConnect?.cancel();
    await _feed.dispose();
    activityRisk?.dispose();
    seizureMarkers.dispose();
    status.dispose();
    client.dispose();
  }
}
