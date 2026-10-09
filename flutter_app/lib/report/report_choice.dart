import '../data/review_event.dart';
import '../data/score_band.dart';
import '../review/review_models.dart';
import 'report_selection.dart';

/// A one-tap way to choose events for the report.
enum ReportPreset {
  /// Every confirmed event; if nothing is confirmed yet, the top unreviewed candidates.
  confirmed,

  /// Every automatic event that has not been dismissed.
  allCandidates,

  /// Every patient button press.
  markers,
}

/// The events the report can draw from, in the order the page shows them: the patient
/// markers (in time order), then the candidates by band, highest score first within
/// each band.
class ReportGroups {
  final List<ReviewEvent> markers;
  final List<ReviewEvent> high;
  final List<ReviewEvent> medium;
  final List<ReviewEvent> low;

  const ReportGroups({required this.markers, required this.high, required this.medium, required this.low});

  List<ReviewEvent> get all => [...markers, ...high, ...medium, ...low];
  List<ReviewEvent> forBand(ScoreBand b) => switch (b) { ScoreBand.high => high, ScoreBand.medium => medium, ScoreBand.low => low };
}

ReportGroups buildGroups(Iterable<ReviewEvent> events) {
  final markers = <ReviewEvent>[], high = <ReviewEvent>[], medium = <ReviewEvent>[], low = <ReviewEvent>[];
  for (final e in events) {
    if (e.isMarker) {
      markers.add(e);
    } else {
      switch (e.band!) {
        case ScoreBand.high:
          high.add(e);
        case ScoreBand.medium:
          medium.add(e);
        case ScoreBand.low:
          low.add(e);
      }
    }
  }
  markers.sort((a, b) => a.event.startSample.compareTo(b.event.startSample));
  for (final g in [high, medium, low]) {
    g.sort(compareCandidates);
  }
  return ReportGroups(markers: markers, high: high, medium: medium, low: low);
}

/// What a preset chooses from [inDays] (the events of the days the report covers).
ReportSelection selectionFor(ReportPreset preset, List<ReviewEvent> inDays) => switch (preset) {
      ReportPreset.confirmed => ReportSelection.defaultFor(inDays),
      ReportPreset.allCandidates => ReportSelection({
          for (final e in inDays)
            if (!e.isMarker && e.status != ReviewStatus.dismissed) e.event.id,
        }),
      ReportPreset.markers => ReportSelection({
          for (final e in inDays)
            if (e.isMarker) e.event.id,
        }),
    };

/// The preset that [selection] is exactly equal to, or null when it is a custom
/// choice (the reviewer ticked and unticked by hand).
ReportPreset? presetOf(ReportSelection selection, List<ReviewEvent> inDays) {
  for (final p in ReportPreset.values) {
    final s = selectionFor(p, inDays);
    // The fallback ("nothing is confirmed, so the top candidates") is only ever
    // Confirmed, even if it happens to hold the same events as All candidates.
    if (s.isFallback != selection.isFallback) continue;
    if (s.ids.length == selection.ids.length && s.ids.containsAll(selection.ids)) return p;
  }
  return null;
}

/// The state of a "select all in this group" box.
enum GroupCheck { none, some, all }

GroupCheck groupCheck(ReportSelection selection, List<ReviewEvent> group) {
  if (group.isEmpty) return GroupCheck.none;
  final n = group.where((e) => selection.contains(e.event.id)).length;
  return n == 0 ? GroupCheck.none : (n == group.length ? GroupCheck.all : GroupCheck.some);
}

/// Every event of [group] ticked (or unticked, with [on] false), leaving the rest as it was.
ReportSelection withGroup(ReportSelection selection, List<ReviewEvent> group, {required bool on}) {
  final ids = {...selection.ids};
  for (final e in group) {
    on ? ids.add(e.event.id) : ids.remove(e.event.id);
  }
  return ReportSelection(ids); // an edited selection is the reviewer's own
}

/// The number of pages in a PDF, counted from its page objects. Page dictionaries
/// are stored uncompressed, so this works on the finished file.
int countPdfPages(List<int> pdf) {
  final text = String.fromCharCodes(pdf);
  return RegExp(r'/Type\s*/Page(?![a-zA-Z])').allMatches(text).length;
}
