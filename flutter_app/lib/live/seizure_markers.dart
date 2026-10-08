import 'package:flutter/foundation.dart';

/// A moment the wearer or a carer marked on the live view with "Seizure now".
class SeizureMarker {
  final int id;

  /// The stream the sample index was read under: an index only means something
  /// together with its stream (it starts over on every restart).
  final int streamId;
  final int sampleIdx;
  final DateTime at;

  const SeizureMarker({required this.id, required this.streamId, required this.sampleIdx, required this.at});
}

/// The markers made on the Data page, kept for as long as the app is open. They
/// are not saved to storage and do not reach the Review page.
class SeizureMarkerStore extends ChangeNotifier {
  final List<SeizureMarker> _markers = [];
  int _nextId = 1;

  List<SeizureMarker> get markers => List.unmodifiable(_markers);
  int get count => _markers.length;

  SeizureMarker add({required int streamId, required int sampleIdx, required DateTime at}) {
    final m = SeizureMarker(id: _nextId++, streamId: streamId, sampleIdx: sampleIdx, at: at);
    _markers.add(m);
    notifyListeners();
    return m;
  }

  void clear() {
    if (_markers.isEmpty) return;
    _markers.clear();
    notifyListeners();
  }
}
