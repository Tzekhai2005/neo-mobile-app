import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../device/device_status.dart';
import '../../live/live_signal_buffer.dart';
import '../../live/seizure_markers.dart';
import '../../protocol/neo_messages.dart';
import '../theme/app_theme.dart';
import '../trace/trace_models.dart';
import '../trace/trace_sources.dart';

/// What the Data page shows and how: the time window, the µV scale, whether the
/// motion lanes are open, a paused view that can be scrolled back through the
/// last 30 seconds, and which lane (if any) is expanded. It turns the live buffer
/// into a [TraceData] each time [tick] is called; the page calls that a few times
/// a second while it is visible.
class DataViewController extends ChangeNotifier {
  static const windowChoices = [5, 10, 15];

  final LiveSignalBuffer buffer;
  final SeizureMarkerStore seizureMarkers;
  final ValueListenable<DeviceStatus> status;

  DataViewController({required this.buffer, required this.seizureMarkers, required this.status});

  int _windowSec = 10;
  double _eegScaleUv = kDefaultEegScaleUv;
  bool _showMotion = true;
  int? _expandedLane;

  /// While paused: the newest sample at the moment of pausing, the stream it was
  /// in, and how far back the view has been scrolled (seconds).
  int? _pausedEnd;
  int _pausedStream = -1;
  double _backSec = 0;

  TraceData _data = const TraceData(lanes: [], durationSec: 0);

  int get windowSec => _windowSec;
  double get eegScaleUv => _eegScaleUv;
  bool get showMotion => _showMotion;
  bool get paused => _pausedEnd != null;
  int? get expandedLane => _expandedLane;
  double get backSec => _backSec;

  /// What to draw. Empty (no lanes) until the first sample arrives.
  TraceData get data => _data;

  /// The expanded lane on its own, or null when none is expanded.
  TraceData? get expandedData {
    final i = _expandedLane;
    if (i == null || i >= _data.lanes.length) return null;
    return TraceData(
      lanes: [_data.lanes[i]],
      durationSec: _data.durationSec,
      markers: _data.markers,
      ticks: _data.ticks,
    );
  }

  /// How far back the view can be scrolled right now, in seconds.
  double get maxBackSec {
    final end = _pausedEnd;
    if (end == null || !buffer.hasData) return 0;
    final windowSamples = _windowSec * buffer.eegRateHz;
    final room = end - buffer.oldestEegIndex - (windowSamples - 1);
    return math.max(0, room) / buffer.eegRateHz;
  }

  // ── from the page ───────────────────────────────────────────────────────────

  /// Refresh from the live buffer. Does nothing while paused: a paused view does
  /// not move.
  void tick() {
    if (paused) {
      if (buffer.streamId != _pausedStream) {
        resume(); // the sample index started over: the frozen view no longer means anything
      }
      return;
    }
    if (!buffer.hasData) {
      if (_data.lanes.isNotEmpty) {
        _data = const TraceData(lanes: [], durationSec: 0);
        _expandedLane = null;
        notifyListeners();
      }
      return;
    }
    _rebuild();
  }

  void setWindow(int seconds) {
    if (!windowChoices.contains(seconds) || seconds == _windowSec) return;
    _windowSec = seconds;
    if (paused) _backSec = math.min(_backSec, maxBackSec);
    _rebuild();
  }

  /// The next scale in [kEegScalesUv], from the biggest back to the smallest.
  void nextScale() {
    final i = kEegScalesUv.indexOf(_eegScaleUv);
    _eegScaleUv = kEegScalesUv[(i + 1) % kEegScalesUv.length];
    _rebuild();
  }

  /// One step bigger (+1) or smaller (-1), stopping at the ends.
  void stepScale(int direction) {
    final i = kEegScalesUv.indexOf(_eegScaleUv);
    final next = (i + direction).clamp(0, kEegScalesUv.length - 1);
    if (next == i) return;
    _eegScaleUv = kEegScalesUv[next];
    _rebuild();
  }

  void toggleMotion() {
    _showMotion = !_showMotion;
    _rebuild();
  }

  void togglePause() => paused ? resume() : pause();

  void pause() {
    if (paused || !buffer.hasData) return;
    _pausedEnd = buffer.latestEegIndex;
    _pausedStream = buffer.streamId;
    _backSec = 0;
    _rebuild();
  }

  void resume() {
    if (!paused) return;
    _pausedEnd = null;
    _backSec = 0;
    _rebuild();
  }

  /// Scroll a paused view: positive [seconds] go back in time. Ignored when live.
  void scrollBy(double seconds) {
    if (!paused) return;
    final next = (_backSec + seconds).clamp(0.0, maxBackSec).toDouble();
    if (next == _backSec) return;
    _backSec = next;
    _rebuild();
  }

  void expand(int lane) {
    if (lane < 0 || lane >= _data.lanes.length) return;
    _expandedLane = lane;
    notifyListeners();
  }

  void collapse() {
    if (_expandedLane == null) return;
    _expandedLane = null;
    notifyListeners();
  }

  // ── building the view ───────────────────────────────────────────────────────

  void _rebuild() {
    if (!buffer.hasData) {
      return;
    }
    final rate = buffer.eegRateHz;
    final end = paused ? _pausedEnd! - (_backSec * rate).round() : null;
    final snap = buffer.snapshot(seconds: _windowSec.toDouble(), endIdx: end);
    final markers = _markersFor(snap);
    _data = liveTraceData(
      snap,
      eegScaleUv: _eegScaleUv,
      showMotion: _showMotion,
      markers: markers,
      backSec: _backSec,
      nowLabel: paused ? 'paused' : 'now',
    );
    final lane = _expandedLane;
    if (lane != null && lane >= _data.lanes.length) _expandedLane = null;
    notifyListeners();
  }

  List<TraceMarker> _markersFor(LiveSnapshot snap) {
    if (snap.isEmpty) return const [];
    final rate = snap.eegRateHz.toDouble();
    double? at(int idx) => (idx < snap.startIdx || idx > snap.endIdx) ? null : (idx - snap.startIdx) / rate;
    final out = <TraceMarker>[];
    for (final e in status.value.recentEvents) {
      if (e.kind != NeoEventKind.button) continue;
      final t = at(e.sampleIdx);
      if (t != null) out.add(TraceMarker(t, label: 'button', color: AppColors.warning));
    }
    for (final m in seizureMarkers.markers) {
      if (m.streamId != buffer.streamId) continue; // made in an earlier stream
      final t = at(m.sampleIdx);
      if (t != null) out.add(TraceMarker(t, label: 'Seizure now', color: AppColors.danger));
    }
    return out;
  }
}
