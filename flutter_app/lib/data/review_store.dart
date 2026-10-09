import 'dart:convert';
import 'dart:io';

import 'review_event.dart';

/// The decisions file exists but cannot be read. Never replaced silently:
/// the decisions in it are the reviewer's work.
class ReviewStoreException implements Exception {
  final String message;
  const ReviewStoreException(this.message);

  @override
  String toString() => 'ReviewStoreException: $message';
}

/// Saves confirm / dismiss / note decisions in a JSON file, separate from the
/// dataset, so swapping the dataset never erases them.
///
/// Decisions are kept per dataset ([datasetKey]) because event ids such as
/// `e0001` repeat across datasets. Decisions for events the current dataset
/// does not contain are kept in the file but not merged into the results.
class ReviewStore {
  static const int version = 1;

  final File file;
  final String datasetKey;
  final DateTime Function() _now;

  /// dataset key -> event id -> decision, for every dataset in the file.
  final Map<String, Map<String, ReviewDecision>> _all = {};

  ReviewStore(this.file, {required this.datasetKey, DateTime Function()? now})
      : _now = now ?? (() => DateTime.now().toUtc());

  Map<String, ReviewDecision> get _mine => _all.putIfAbsent(datasetKey, () => {});

  /// A missing file is an empty store. A corrupt one throws.
  Future<void> load() async {
    _all.clear();
    if (!await file.exists()) return;
    try {
      final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (j['version'] != version) throw ReviewStoreException('unsupported version ${j['version']}');
      for (final entry in (j['datasets'] as Map<String, dynamic>).entries) {
        _all[entry.key] = {
          for (final d in entry.value as List<dynamic>)
            (d as Map<String, dynamic>)['eventId'] as String: ReviewDecision.fromJson(d),
        };
      }
    } on ReviewStoreException {
      rethrow;
    } catch (e) {
      throw ReviewStoreException('${file.path} is unreadable ($e)');
    }
  }

  ReviewDecision? decisionFor(String eventId) => _mine[eventId];

  /// Confirm, dismiss, or reset to candidate. Keeps an existing note.
  Future<void> setStatus(String eventId, ReviewStatus status) =>
      _write(eventId, status: status, note: _mine[eventId]?.note);

  /// Set or clear (blank) the note. Keeps the status.
  Future<void> setNote(String eventId, String? note) {
    final trimmed = note?.trim();
    return _write(eventId,
        status: _mine[eventId]?.status ?? ReviewStatus.candidate,
        note: (trimmed == null || trimmed.isEmpty) ? null : trimmed);
  }

  /// Changes one decision and saves. If the file cannot be written, the change is
  /// undone in memory too and the error is thrown, so what the store holds is
  /// never more than what is on disk.
  Future<void> _write(String eventId, {required ReviewStatus status, required String? note}) async {
    final previous = _mine[eventId];
    if (status == ReviewStatus.candidate && note == null) {
      _mine.remove(eventId); // back to the default: nothing to remember
    } else {
      _mine[eventId] = ReviewDecision(eventId: eventId, status: status, note: note, updatedAt: _now());
    }
    try {
      await _save();
    } catch (_) {
      if (previous == null) {
        _mine.remove(eventId);
      } else {
        _mine[eventId] = previous;
      }
      rethrow;
    }
  }

  /// Events with this dataset's decisions applied. Unknown ids are ignored.
  List<ReviewEvent> merge(List<RecordedEvent> events) =>
      [for (final e in events) ReviewEvent(e, _mine[e.id])];

  Future<void> _save() async {
    final body = jsonEncode({
      'version': version,
      'datasets': {
        for (final entry in _all.entries)
          if (entry.value.isNotEmpty) entry.key: [for (final d in entry.value.values) d.toJson()],
      },
    });
    // Write beside the file, then rename, so a crash never leaves half a file.
    final tmp = File('${file.path}.tmp');
    await file.parent.create(recursive: true);
    await tmp.writeAsString(body, flush: true);
    await tmp.rename(file.path);
  }
}
