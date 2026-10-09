import '../data/review_event.dart';
import '../data/score_band.dart';

/// Which events the Review list shows.
enum ReviewFilter { all, unreviewed, confirmed, dismissed }

/// How the list is ordered: by score (the default), or by time.
enum ReviewSort { score, newest, oldest }

/// What an event is called on screen. The three automatic kinds are the three score
/// bands under friendlier names; a patient button press is its own kind.
enum EventCategory { possibleSeizure, unusual, normal, marked }

String categoryName(EventCategory c) => switch (c) {
      EventCategory.possibleSeizure => 'Possible seizure',
      EventCategory.unusual => 'Unusual activity',
      EventCategory.normal => 'Normal activity',
      EventCategory.marked => 'Marked by you',
    };

EventCategory categoryOfBand(ScoreBand b) => switch (b) {
      ScoreBand.high => EventCategory.possibleSeizure,
      ScoreBand.medium => EventCategory.unusual,
      ScoreBand.low => EventCategory.normal,
    };

extension ReviewEventView on ReviewEvent {
  /// A patient button press: a person flagged it, no algorithm scored it.
  bool get isMarker => event.source == EventSource.patientButton;

  /// High, Medium or Low for an automatic event; null for a patient marker.
  ScoreBand? get band => scoreBandOf(event.confidence);

  EventCategory get category => isMarker ? EventCategory.marked : categoryOfBand(band ?? ScoreBand.low);

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

int _byTime(ReviewEvent a, ReviewEvent b) => a.event.startSample.compareTo(b.event.startSample);

/// What the list shows: the patient markers pinned at the top (in time order), then
/// the candidates in the chosen order.
class ReviewLists {
  final List<ReviewEvent> markers;
  final List<ReviewEvent> candidates;

  const ReviewLists(this.markers, this.candidates);

  /// The order Next and Previous walk through: markers, then candidates.
  List<ReviewEvent> get ordered => [...markers, ...candidates];

  bool get isEmpty => markers.isEmpty && candidates.isEmpty;
}

ReviewLists buildLists(Iterable<ReviewEvent> events, ReviewFilter filter, {ReviewSort sort = ReviewSort.score}) {
  final kept = [
    for (final e in events)
      if (passesFilter(e, filter)) e
  ];
  final newestFirst = sort == ReviewSort.newest;
  int byTime(ReviewEvent a, ReviewEvent b) => newestFirst ? _byTime(b, a) : _byTime(a, b);
  return ReviewLists(
    [
      for (final e in kept)
        if (e.isMarker) e
    ]..sort(byTime),
    [
      for (final e in kept)
        if (!e.isMarker) e
    ]..sort(sort == ReviewSort.score ? compareCandidates : byTime),
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
    return ReviewCounts(
        total: total, confirmed: confirmed, dismissed: dismissed, unreviewed: unreviewed, markers: markers);
  }
}
