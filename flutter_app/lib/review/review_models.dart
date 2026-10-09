import '../data/review_event.dart';
import '../data/score_band.dart';

/// Which events the Review list shows.
enum ReviewFilter { all, unreviewed, confirmed, dismissed }

extension ReviewEventView on ReviewEvent {
  /// A patient button press: a person flagged it, no algorithm scored it.
  bool get isMarker => event.source == EventSource.patientButton;

  /// High, Medium or Low for an automatic event; null for a patient marker.
  ScoreBand? get band => scoreBandOf(event.confidence);

  /// An event the reviewer has decided about, either way.
  bool get isReviewed => status != ReviewStatus.candidate;
}

bool passesFilter(ReviewEvent e, ReviewFilter f) => switch (f) {
      ReviewFilter.all => true,
      ReviewFilter.unreviewed => e.status == ReviewStatus.candidate,
      ReviewFilter.confirmed => e.status == ReviewStatus.confirmed,
      ReviewFilter.dismissed => e.status == ReviewStatus.dismissed,
    };

/// The order of the candidate list: highest score first, and events with the same
/// score in time order. Patient markers have no score and are listed on their own.
int compareCandidates(ReviewEvent a, ReviewEvent b) {
  final byScore = (b.event.confidence ?? 0).compareTo(a.event.confidence ?? 0);
  return byScore != 0 ? byScore : a.event.startSample.compareTo(b.event.startSample);
}

/// What the list shows: the patient markers pinned at the top (in time order), then
/// the candidates ranked by score.
class ReviewLists {
  final List<ReviewEvent> markers;
  final List<ReviewEvent> candidates;

  const ReviewLists(this.markers, this.candidates);

  /// The order Next and Previous walk through: markers, then candidates.
  List<ReviewEvent> get ordered => [...markers, ...candidates];

  bool get isEmpty => markers.isEmpty && candidates.isEmpty;
}

ReviewLists buildLists(Iterable<ReviewEvent> events, ReviewFilter filter) {
  final kept = [for (final e in events) if (passesFilter(e, filter)) e];
  return ReviewLists(
    [for (final e in kept) if (e.isMarker) e]..sort((a, b) => a.event.startSample.compareTo(b.event.startSample)),
    [for (final e in kept) if (!e.isMarker) e]..sort(compareCandidates),
  );
}

/// How far the review has got, over every event of the recording.
class ReviewCounts {
  final int total, confirmed, dismissed, unreviewed, markers;

  const ReviewCounts({
    required this.total,
    required this.confirmed,
    required this.dismissed,
    required this.unreviewed,
    required this.markers,
  });

  int get reviewed => confirmed + dismissed;

  factory ReviewCounts.of(Iterable<ReviewEvent> events) {
    var total = 0, confirmed = 0, dismissed = 0, unreviewed = 0, markers = 0;
    for (final e in events) {
      total++;
      if (e.isMarker) markers++;
      switch (e.status) {
        case ReviewStatus.confirmed:
          confirmed++;
        case ReviewStatus.dismissed:
          dismissed++;
        case ReviewStatus.candidate:
          unreviewed++;
      }
    }
    return ReviewCounts(total: total, confirmed: confirmed, dismissed: dismissed, unreviewed: unreviewed, markers: markers);
  }
}
