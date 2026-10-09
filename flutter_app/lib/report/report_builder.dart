import 'dart:math' as math;

import '../config/app_config.dart';
import '../data/recording_source.dart';
import '../data/review_event.dart';
import 'report_models.dart';
import 'report_selection.dart';

/// Turns a recording plus the reviewer's decisions into [ReportData].
class ReportBuilder {
  /// `events` are the recording's events with the reviewer's decisions applied
  /// (`ReviewStore.merge(source.events())`). Only the selected ones become
  /// entries (each with its full-rate signals); the summary and the timeline
  /// always cover the whole recording, or only the days in [days] when it is given.
  ///
  /// A partial report is cut at whole days. Everything in it (summary, quality,
  /// overview figure, event list) describes just those days, and times in the
  /// figure count from the start of the first day. Events outside the days are
  /// left out even when they are in [selection].
  static Future<ReportData> build({
    required RecordingSource source,
    required List<ReviewEvent> events,
    required ReportSelection selection,
    required DateTime generatedAtUtc,
    ReportDevice? device,
    String? patientLabel,
    DayRange? days,
    int overviewBins = 720,
  }) async {
    final info = source.info;
    final rate = info.eegRateHz;
    final recordingDays = math.max(1, (info.durationSec / 86400).ceil());
    if (days != null && !days.fits(recordingDays)) {
      throw ArgumentError.value(days, 'days', 'must lie inside the recording (day 1 to day $recordingDays)');
    }
    if (days != null && days.first == 0 && days.last == recordingDays - 1) days = null; // every day is the whole recording
    // Whole recording, or the chosen run of days.
    final t0 = days?.startSec ?? 0.0;
    final t1 = days == null ? info.durationSec.toDouble() : math.min((days.last + 1) * 86400.0, info.durationSec.toDouble());
    final span = TimeRange(t0, t1);
    bool inSpan(ReviewEvent r) => span.contains(r.event.startSec(rate));

    final sorted = [
      for (final r in events)
        if (days == null || inSpan(r)) r
    ]..sort((a, b) => a.event.startSample.compareTo(b.event.startSample));

    // maxBins >= bins keeps every bin, so quality is judged at the dataset's resolution.
    final fine = _fromOrigin(source.overview(span, math.max(1, (t1 - t0).round())), t0);
    final summary = summarize(info, sorted, fine, firstDay: days?.first ?? 0, lastDay: days?.last ?? recordingDays - 1);

    final entries = <ReportEntry>[];
    for (final r in sorted) {
      if (!selection.contains(r.event.id)) continue;
      final start = r.event.startSec(rate);
      entries.add(ReportEntry(
        review: r,
        startSec: start,
        durationSec: r.event.durationSec(rate),
        startLocal: info.localTimeAt(start),
        night: info.isNight(start),
        window: await source.eventWindow(r.event.id),
      ));
    }

    return ReportData(
      header: ReportHeader(
        brand: kBrandName,
        byline: kBrandByline,
        generatedAtUtc: generatedAtUtc,
        recordingStartLocal: info.localTimeAt(t0),
        recordingEndLocal: info.localTimeAt(t1),
        utcOffsetMinutes: info.utcOffsetMinutes,
        durationSec: (t1 - t0).round(),
        eegRateHz: rate,
        eegChannels: info.eegChannels,
        imuRateHz: info.imuRateHz,
        synthetic: info.synthetic,
        generator: info.generator,
        datasetKey: info.datasetKey,
        device: device,
        patientLabel: patientLabel,
        firstDay: days?.first,
        lastDay: days?.last,
        recordingDays: days == null ? null : recordingDays,
      ),
      summary: summary,
      entries: entries,
      selectionIsFallback: selection.isFallback,
      overview: _fromOrigin(source.overview(span, overviewBins), t0),
      timeline: [
        for (final r in sorted)
          TimelineEvent(
            id: r.event.id,
            startSec: r.event.startSec(rate) - t0,
            source: r.event.source,
            confidence: r.event.confidence,
            status: r.status,
            selected: selection.contains(r.event.id),
          ),
      ],
    );
  }

  /// The numbers in the report, computed only from the data. `fine` is the
  /// overview at full resolution (one bin per dataset bin).
  ///
  /// [firstDay] and [lastDay] (0-based, inclusive) are the days covered; `events`
  /// must already lie inside them, and `fine` must start at the first of them.
  static ReportSummary summarize(
    RecordingInfo info,
    List<ReviewEvent> events,
    OverviewBins fine, {
    int firstDay = 0,
    int lastDay = -1,
  }) {
    final rate = info.eegRateHz;
    final recordingDays = math.max(1, (info.durationSec / 86400).ceil());
    if (lastDay < 0) lastDay = recordingDays - 1;
    final days = recordingDays; // arrays are indexed by the day of the recording

    var candidates = 0, high = 0, confirmed = 0, dismissed = 0, unreviewed = 0;
    var night = 0, markers = 0;
    final dayCandidates = List<int>.filled(days, 0);
    final dayConfirmed = List<int>.filled(days, 0);
    final dayNight = List<int>.filled(days, 0);
    final dayMarkers = List<int>.filled(days, 0);

    for (final r in events) {
      final start = r.event.startSec(rate);
      final d = math.min(days - 1, (start / 86400).floor());
      if (r.event.source == EventSource.patientButton) {
        markers++;
        dayMarkers[d]++;
        continue;
      }
      if (r.event.source != EventSource.auto) continue;
      candidates++;
      dayCandidates[d]++;
      if ((r.event.confidence ?? 0) >= kHighConfidence) high++;
      final isNight = info.isNight(start);
      if (isNight) {
        night++;
        dayNight[d]++;
      }
      switch (r.status) {
        case ReviewStatus.confirmed:
          confirmed++;
          dayConfirmed[d]++;
        case ReviewStatus.dismissed:
          dismissed++;
        case ReviewStatus.candidate:
          unreviewed++;
      }
    }

    final covered = lastDay - firstDay + 1;
    final coveredSec = math.min((lastDay + 1) * 86400, info.durationSec) - firstDay * 86400;
    return ReportSummary(
      durationSec: coveredSec,
      days: covered,
      candidates: candidates,
      highConfidence: high,
      confirmed: confirmed,
      dismissed: dismissed,
      unreviewed: unreviewed,
      nightCandidates: night,
      dayCandidates: candidates - night,
      patientMarkers: markers,
      quality: _quality(fine),
      perDay: [
        for (var d = firstDay; d <= lastDay; d++)
          DaySummary(
            index: d,
            startLocal: info.localTimeAt(d * 86400.0),
            candidates: dayCandidates[d],
            confirmed: dayConfirmed[d],
            nightCandidates: dayNight[d],
            patientMarkers: dayMarkers[d],
          ),
      ],
    );
  }

  /// The same bins with times counted from [originSec] instead of the start of
  /// the recording, so a figure of a partial report starts at its left edge.
  static OverviewBins _fromOrigin(OverviewBins o, double originSec) => originSec == 0
      ? o
      : OverviewBins(
          binSec: o.binSec,
          startSec: o.startSec - originSec,
          count: o.count,
          eegMin: o.eegMin,
          eegMax: o.eegMax,
          activity: o.activity,
          quality: o.quality,
        );

  static SignalQualitySummary _quality(OverviewBins fine) {
    final stretches = <QualityStretch>[];
    var bad = 0;
    int? runStart;
    for (var i = 0; i <= fine.count; i++) {
      final isBad = i < fine.count && fine.quality[i] < kUsableQuality;
      if (isBad) {
        bad++;
        runStart ??= i;
      } else if (runStart != null) {
        stretches.add(QualityStretch(fine.startSec + runStart * fine.binSec, (i - runStart) * fine.binSec));
        runStart = null;
      }
    }
    final totalSec = fine.count * fine.binSec;
    final usableSec = totalSec - bad * fine.binSec;
    return SignalQualitySummary(
      usableSec: usableSec,
      usablePercent: totalSec == 0 ? 0 : 100.0 * usableSec / totalSec,
      lowQualityStretches: stretches,
    );
  }
}
