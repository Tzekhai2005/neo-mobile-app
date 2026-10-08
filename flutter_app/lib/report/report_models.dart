import '../data/recording_source.dart';
import '../data/review_event.dart';

export '../data/score_band.dart' show kHighConfidence, kMediumConfidence, ScoreBand, scoreBandOf;

/// Shown on every report. A clinical layout must not imply a validated diagnosis.
const String kReportDisclaimer = 'Research prototype. Not a medical device and not for clinical use. '
    'Candidate events are suggestions for a clinician to review, not diagnoses.';

/// A stretch of recording is usable when its signal quality is at least this.
const double kUsableQuality = 0.5;

/// What identifies the device behind a recording. All optional: a dataset
/// does not record them; a live session takes them from the device INFO.
class ReportDevice {
  final String? name;
  final String? serial;
  final String? firmware;
  const ReportDevice({this.name, this.serial, this.firmware});
}

class ReportHeader {
  final String brand;
  final DateTime generatedAtUtc;
  final DateTime recordingStartLocal; // wall clock at the recording site
  final DateTime recordingEndLocal;
  final int utcOffsetMinutes;
  final int durationSec;
  final int eegRateHz;
  final int eegChannels;
  final int imuRateHz;
  final ReportDevice? device;
  final String? patientLabel;

  /// Set when the report covers only some days of the recording: 0-based,
  /// inclusive, and the number of days in the whole recording. All null for a
  /// report of the whole recording. [durationSec], [recordingStartLocal] and
  /// [recordingEndLocal] describe only the days covered.
  final int? firstDay;
  final int? lastDay;
  final int? recordingDays;

  /// True for generated data: the report must say "sample recording".
  final bool synthetic;
  final String generator;
  final String datasetKey;

  const ReportHeader({
    required this.brand,
    required this.generatedAtUtc,
    required this.recordingStartLocal,
    required this.recordingEndLocal,
    required this.utcOffsetMinutes,
    required this.durationSec,
    required this.eegRateHz,
    required this.eegChannels,
    required this.imuRateHz,
    required this.synthetic,
    required this.generator,
    required this.datasetKey,
    this.device,
    this.patientLabel,
    this.firstDay,
    this.lastDay,
    this.recordingDays,
  });

  bool get isPartial => firstDay != null;
}

/// A stretch where the signal quality was too low to use.
class QualityStretch {
  final double startSec;
  final double durationSec;
  const QualityStretch(this.startSec, this.durationSec);
}

class SignalQualitySummary {
  final double usableSec;
  final double usablePercent;
  final List<QualityStretch> lowQualityStretches;

  /// Not measured for a stored dataset; a live session fills these in.
  final double? linkLossPercent;
  final double? leadOffPercent;

  const SignalQualitySummary({
    required this.usableSec,
    required this.usablePercent,
    required this.lowQualityStretches,
    this.linkLossPercent,
    this.leadOffPercent,
  });
}

/// Counts for one 24 h block of the recording (the Review page's day).
class DaySummary {
  final int index; // 0-based
  final DateTime startLocal;
  final int candidates; // automatic events
  final int confirmed; // automatic events the reviewer confirmed
  final int nightCandidates;
  final int patientMarkers;

  const DaySummary({
    required this.index,
    required this.startLocal,
    required this.candidates,
    required this.confirmed,
    required this.nightCandidates,
    required this.patientMarkers,
  });
}

class ReportSummary {
  final int durationSec;
  final int days;

  /// Automatic candidate events, and what the reviewer did with them.
  final int candidates;
  final int highConfidence;
  final int confirmed;
  final int dismissed;
  final int unreviewed;
  final int nightCandidates;
  final int dayCandidates;

  /// Patient button presses (all of them, whatever their status).
  final int patientMarkers;

  final SignalQualitySummary quality;
  final List<DaySummary> perDay;

  const ReportSummary({
    required this.durationSec,
    required this.days,
    required this.candidates,
    required this.highConfidence,
    required this.confirmed,
    required this.dismissed,
    required this.unreviewed,
    required this.nightCandidates,
    required this.dayCandidates,
    required this.patientMarkers,
    required this.quality,
    required this.perDay,
  });
}

/// One event in the report, with its full-rate signals.
class ReportEntry {
  final ReviewEvent review;
  final double startSec;
  final double durationSec;
  final DateTime startLocal;
  final bool night;
  final SignalWindow window;

  const ReportEntry({
    required this.review,
    required this.startSec,
    required this.durationSec,
    required this.startLocal,
    required this.night,
    required this.window,
  });

  RecordedEvent get event => review.event;
}

/// A dot on the overview figure: every event in the recording, selected or not.
class TimelineEvent {
  final String id;
  final double startSec;
  final EventSource source;
  final double? confidence;
  final ReviewStatus status;
  final bool selected;

  const TimelineEvent({
    required this.id,
    required this.startSec,
    required this.source,
    required this.confidence,
    required this.status,
    required this.selected,
  });
}

/// Everything a report needs, computed from the recording and the reviewer's
/// decisions. Drawing it (PDF) and exporting it (CSV) both start from here.
class ReportData {
  final ReportHeader header;
  final ReportSummary summary;

  /// The events chosen for the report, oldest first.
  final List<ReportEntry> entries;

  /// True when nothing was confirmed and the selection fell back to the top
  /// unreviewed candidates; the report should say so.
  final bool selectionIsFallback;

  /// The recording's overview merged for the timeline figure.
  final OverviewBins overview;
  final List<TimelineEvent> timeline;
  final String disclaimer;

  const ReportData({
    required this.header,
    required this.summary,
    required this.entries,
    required this.selectionIsFallback,
    required this.overview,
    required this.timeline,
    this.disclaimer = kReportDisclaimer,
  });
}
