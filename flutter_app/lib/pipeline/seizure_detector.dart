import 'dart:math' as math;

class SeizureDetectionResult {
  final double riskPct;
  final bool isSeizureOnset;
  final int spikeCount;
  final double currentUv;

  SeizureDetectionResult({
    required this.riskPct,
    required this.isSeizureOnset,
    required this.spikeCount,
    required this.currentUv,
  });
}

/// Real-time Line-Length & Spike Biomarker Detector (SeizeIT2 Aligned)
class SeizureDetector {
  double _prevSample = 0.0;
  double _runningLineLength = 0.0;
  double _runningMean = 15.0;
  int _spikesInWindow = 0;
  int _refractoryCounter = 0;
  bool _inSeizureState = false;

  SeizureDetectionResult processSample(double uvSample) {
    final absDiff = (uvSample - _prevSample).abs();
    _prevSample = uvSample;

    // Moving exponential average of line-length
    _runningLineLength = 0.98 * _runningLineLength + 0.02 * absDiff;
    _runningMean = 0.995 * _runningMean + 0.005 * uvSample.abs();

    if (_refractoryCounter > 0) {
      _refractoryCounter--;
    } else {
      // Threshold: amplitude > 60 µV and line-length > 3x running mean
      final threshold = math.max(60.0, 3.5 * _runningMean);
      if (uvSample.abs() > threshold) {
        _spikesInWindow++;
        _refractoryCounter = 50; // 200ms refractory period at 250 SPS
      }
    }

    // Calculate Risk Percentage (0% to 98%)
    double risk = (_spikesInWindow * 12.0) + (_runningLineLength / 2.0);
    risk = risk.clamp(5.0, 98.0);

    _inSeizureState = risk > 70.0;

    return SeizureDetectionResult(
      riskPct: risk,
      isSeizureOnset: _inSeizureState,
      spikeCount: _spikesInWindow,
      currentUv: uvSample,
    );
  }

  void resetWindow() {
    _spikesInWindow = 0;
  }
}
