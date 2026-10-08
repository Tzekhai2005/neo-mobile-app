/// An automatic event at or above this score is in the High band, and counts as
/// "high confidence" in the report.
const double kHighConfidence = 0.8;

/// From this score up to [kHighConfidence] is the Medium band; below it, Low.
const double kMediumConfidence = 0.4;

/// How a score is shown to people: three bands, never the raw number alone.
/// The Review page, the Report page and the PDF all use [scoreBandOf], so a
/// band means the same thing everywhere.
enum ScoreBand { high, medium, low }

/// The band for a score; null for events that have none (patient markers).
ScoreBand? scoreBandOf(double? score) {
  if (score == null) return null;
  if (score >= kHighConfidence) return ScoreBand.high;
  if (score >= kMediumConfidence) return ScoreBand.medium;
  return ScoreBand.low;
}
