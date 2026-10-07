import '../data/review_event.dart';

/// Which events go into the report. Immutable: every change returns a new one.
class ReportSelection {
  final Set<String> ids;

  /// True when this is the unreviewed-candidates fallback of [defaultFor].
  final bool isFallback;

  const ReportSelection(this.ids, {this.isFallback = false});

  bool contains(String id) => ids.contains(id);

  /// Add the event, or remove it if it is already selected.
  ReportSelection toggled(String id) {
    final next = {...ids};
    if (!next.remove(id)) next.add(id);
    return ReportSelection(next); // an edited selection is the reviewer's own
  }

  ReportSelection withAdded(Iterable<String> add) => ReportSelection({...ids, ...add});

  /// The selection for "one click": every confirmed event. When nothing is
  /// confirmed yet, the [fallbackTop] highest-confidence automatic candidates
  /// that were not dismissed, so the report is never empty by accident.
  static ReportSelection defaultFor(List<ReviewEvent> events, {int fallbackTop = 5}) {
    final confirmed = [
      for (final e in events)
        if (e.status == ReviewStatus.confirmed) e.event.id,
    ];
    if (confirmed.isNotEmpty) return ReportSelection(confirmed.toSet());

    final candidates = [
      for (final e in events)
        if (e.event.source == EventSource.auto && e.status == ReviewStatus.candidate) e,
    ]..sort((a, b) {
        final byConfidence = (b.event.confidence ?? 0).compareTo(a.event.confidence ?? 0);
        return byConfidence != 0 ? byConfidence : a.event.startSample.compareTo(b.event.startSample);
      });
    return ReportSelection({for (final e in candidates.take(fallbackTop)) e.event.id}, isFallback: true);
  }
}
