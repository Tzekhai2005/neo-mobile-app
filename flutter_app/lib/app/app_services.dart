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
import '../live/live_feed.dart';
import '../live/live_signal_buffer.dart';
import '../protocol/neo_client.dart';
import '../report/report_builder.dart';
import '../report/report_exporter.dart';
import '../report/report_fonts.dart';
import '../report/report_fonts_assets.dart';
import '../report/report_models.dart';
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
    ReportFonts? fonts,
    DateTime Function()? now,
  }) : this._(client ?? NeoClient(), dataDir, reader, sharer, picker, fonts, now ?? DateTime.now);

  // One client for everything: the tracker and the feed must watch the same one.
  AppServices._(this.client, this.dataDir, this._readerOverride, this._sharer, this._picker, this._fonts, this._now)
      : live = LiveSignalBuffer(),
        status = DeviceStatusTracker(client),
        library = dataDir == null ? null : DatasetLibrary(Directory('${dataDir.path}/datasets')) {
    _feed = LiveFeed(client, live);
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
  Future<ReportData> buildReport({ReportSelection? selection, ReportDevice? device, String? patientLabel}) async {
    await loadReview();
    final events = reviewEvents();
    return ReportBuilder.build(
      source: recording,
      events: events,
      selection: selection ?? ReportSelection.defaultFor(events),
      generatedAtUtc: _now().toUtc(),
      device: device,
      patientLabel: patientLabel,
    );
  }

  /// One click: build the report, write the PDF and CSV zip, and (by default)
  /// open the share sheet.
  Future<ExportedReport> exportReport({
    ReportSelection? selection,
    ReportDevice? device,
    String? patientLabel,
    bool share = true,
  }) async {
    final dir = _requireDataDir();
    final data = await buildReport(selection: selection, device: device, patientLabel: patientLabel);
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
    status.dispose();
    client.dispose();
  }
}
