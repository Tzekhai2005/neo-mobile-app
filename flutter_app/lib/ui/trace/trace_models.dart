import 'dart:typed_data';

import 'package:flutter/painting.dart';

/// One lane of a signal view: a label, one to three series drawn in it (an EEG
/// channel, or the x, y and z of the accelerometer), and the scale that decides
/// how tall the signal is drawn. All series in a lane share a sample rate.
class TraceLane {
  final String label;
  final List<Float32List> series;
  final List<Color> colors;

  /// What the lane's edge is worth: the signal is drawn from -[scale] to +[scale]
  /// and clipped there.
  final double scale;
  final String unit; // "µV", "g", "°/s"
  final int rateHz;

  /// Subtract the slow baseline before drawing (EEG). Off for motion, where the
  /// steady part (gravity) means something.
  final bool removeBaseline;

  /// Relative height of the lane.
  final double weight;

  /// Names of the series ("x", "y", "z") shown as a small legend; empty for one series.
  final List<String> seriesNames;

  const TraceLane({
    required this.label,
    required this.series,
    required this.colors,
    required this.scale,
    required this.unit,
    required this.rateHz,
    this.removeBaseline = false,
    this.weight = 1,
    this.seriesNames = const [],
  });
}

/// A vertical line across every lane, at [t] seconds from the left edge.
class TraceMarker {
  final double t;
  final String? label;
  final Color color;
  const TraceMarker(this.t, {this.label, required this.color});
}

/// A shaded stretch across every lane, from [start] to [end] seconds.
class TraceSpan {
  final double start, end;
  final Color color;
  const TraceSpan(this.start, this.end, this.color);
}

/// A label under the lanes, at [t] seconds from the left edge.
class TraceTick {
  final double t;
  final String label;

  /// Kept even when it crowds a neighbour ("now", "start"); the others are
  /// dropped first when labels would overlap.
  final bool important;
  const TraceTick(this.t, this.label, {this.important = false});
}

/// Everything [SignalLanes] draws.
class TraceData {
  final List<TraceLane> lanes;

  /// How many seconds the lanes cover, left edge to right edge.
  final double durationSec;
  final List<TraceMarker> markers;
  final List<TraceSpan> spans;
  final List<TraceTick> ticks;

  const TraceData({
    required this.lanes,
    required this.durationSec,
    this.markers = const [],
    this.spans = const [],
    this.ticks = const [],
  });
}
