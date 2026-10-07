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
  /// always cover the whole recording.
  static Future<ReportData> build({
    required RecordingSource source,
    required List<ReviewEvent> events,
    required ReportSelection selection,
    required DateTime generatedAtUtc,
    ReportDevice? device,
    String? patientLabel,
    int overviewBins = 720,
  }) async {
    final info = source.info;
    final rate = info.eegRateHz;
    final sorted = [...events]..sort((a, b) => a.event.startSample.compareTo(b.event.startSample));
    final whole = TimeRange(0, info.durationSec.toDouble());

    // maxBins >= bins keeps every bin, so quality is judged at the dataset's resolution.
    final fine = source.overview(whole, math.max(1, info.durationSec));
    final summary = summarize(info, sorted, fine);

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
        generatedAtUtc: generatedAtUtc,
        recordingStartLocal: info.localTimeAt(0),
        recordingEndLocal: info.localTimeAt(info.durationSec.toDouble()),
        utcOffsetMinutes: info.utcOffsetMinutes,
        durationSec: info.durationSec,
        eegRateHz: rate,
        eegChannels: info.eegChannels,
        imuRateHz: info.imuRateHz,
        synthetic: info.synthetic,
        generator: info.generator,
        datasetKey: info.datasetKey,
        device: device,
        patientLabel: patientLabel,
      ),
      summary: summary,
      entries: entries,
      selectionIsFallback: selection.isFallback,
      overview: source.overview(whole, overviewBins),
      timeline: [
        for (final r in sorted)
          TimelineEvent(
            id: r.event.id,
            startSec: r.event.startSec(rate),
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
  static ReportSummary summarize(RecordingInfo info, List<ReviewEvent> events, OverviewBins fine) {
    final rate = info.eegRateHz;
    final days = math.max(1, (info.durationSec / 86400).ceil());

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

    return ReportSummary(
      durationSec: info.durationSec,
      days: days,
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
        for (var d = 0; d < days; d++)
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
