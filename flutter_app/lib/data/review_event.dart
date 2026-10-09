/// Where an event came from.
enum EventSource { auto, patientButton, manual }

/// What the reviewer decided about an event.
enum ReviewStatus { candidate, confirmed, dismissed, unsure }

/// Where an event's full-rate signal window sits inside `windows.bin`.
class EventWindowRef {
  final int offset; // bytes
  final int length; // bytes
  final double preSec; // stored before the event start
  final double postSec; // stored after the event start

  const EventWindowRef({
    required this.offset,
    required this.length,
    required this.preSec,
    required this.postSec,
  });

  double get durationSec => preSec + postSec;
}

/// An event as stored in the dataset. Immutable; reviewer decisions live in
/// [ReviewDecision], never here.
class RecordedEvent {
  final String id;
  final EventSource source;

  /// EEG sample index of the event start (the protocol's clock).
  final int startSample;
  final int durationSamples;

  /// 0..1 for automatic candidates; null for patient button presses.
  final double? confidence;

  /// EEG channels involved; empty for a patient marker.
  final List<int> channels;

  /// 0..1 signal quality around the event.
  final double quality;

  /// Generator ground truth of a synthetic dataset. Never present it as a detection.
  final String? truth;

  final EventWindowRef window;

  const RecordedEvent({
    required this.id,
    required this.source,
    required this.startSample,
    required this.durationSamples,
    required this.confidence,
    required this.channels,
    required this.quality,
    required this.window,
    this.truth,
  });

  double startSec(int eegRateHz) => startSample / eegRateHz;
  double durationSec(int eegRateHz) => durationSamples / eegRateHz;
}

/// A reviewer's decision about one event.
class ReviewDecision {
  final String eventId;
  final ReviewStatus status;
  final String? note;
  final DateTime updatedAt; // UTC

  const ReviewDecision({
    required this.eventId,
    required this.status,
    required this.updatedAt,
    this.note,
  });

  Map<String, dynamic> toJson() => {
        'eventId': eventId,
        'status': status.name,
        'note': note,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  static ReviewDecision fromJson(Map<String, dynamic> j) => ReviewDecision(
        eventId: j['eventId'] as String,
        status: ReviewStatus.values.byName(j['status'] as String),
        note: j['note'] as String?,
        updatedAt: DateTime.parse(j['updatedAt'] as String).toUtc(),
      );
}

/// An event together with the reviewer's decision, if any.
class ReviewEvent {
  final RecordedEvent event;
  final ReviewDecision? decision;

  const ReviewEvent(this.event, this.decision);

  ReviewStatus get status => decision?.status ?? ReviewStatus.candidate;
  String? get note => decision?.note;
}
