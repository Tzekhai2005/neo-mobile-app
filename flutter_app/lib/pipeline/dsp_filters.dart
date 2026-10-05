import 'dart:math' as math;

/// Real-time Digital Signal Processing (DSP) Filters for 250 SPS EEG
class BiquadFilter {
  double b0 = 1.0, b1 = 0.0, b2 = 0.0;
  double a1 = 0.0, a2 = 0.0;
  double x1 = 0.0, x2 = 0.0;
  double y1 = 0.0, y2 = 0.0;

  double process(double input) {
    final output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1;
    x1 = input;
    y2 = y1;
    y1 = output;
    return output;
  }

  void reset() {
    x1 = x2 = y1 = y2 = 0.0;
  }

  /// 50 Hz or 60 Hz Notch Filter at 250 SPS (Q = 30)
  static BiquadFilter createNotch({double notchFreq = 50.0, double sampleRate = 250.0, double q = 30.0}) {
    final filter = BiquadFilter();
    final w0 = 2.0 * math.pi * notchFreq / sampleRate;
    final alpha = math.sin(w0) / (2.0 * q);

    final a0 = 1.0 + alpha;
    filter.b0 = 1.0 / a0;
    filter.b1 = (-2.0 * math.cos(w0)) / a0;
    filter.b2 = 1.0 / a0;
    filter.a1 = (-2.0 * math.cos(w0)) / a0;
    filter.a2 = (1.0 - alpha) / a0;
    return filter;
  }

  /// 0.5 - 40 Hz Bandpass approximation for biomedical display
  static BiquadFilter createBandpass({double lowCut = 0.5, double highCut = 40.0, double sampleRate = 250.0}) {
    final filter = BiquadFilter();
    final centerFreq = math.sqrt(lowCut * highCut);
    final bandwidth = highCut - lowCut;
    final q = centerFreq / bandwidth;

    final w0 = 2.0 * math.pi * centerFreq / sampleRate;
    final alpha = math.sin(w0) / (2.0 * q);

    final a0 = 1.0 + alpha;
    filter.b0 = (alpha) / a0;
    filter.b1 = 0.0;
    filter.b2 = (-alpha) / a0;
    filter.a1 = (-2.0 * math.cos(w0)) / a0;
    filter.a2 = (1.0 - alpha) / a0;
    return filter;
  }
}
