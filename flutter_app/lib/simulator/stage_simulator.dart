import 'dart:async';
import 'dart:math' as math;
import '../protocol/neo_proto.dart';

/// Standalone Offline Stage Simulator for Demo Day Pitch
class StageSimulator {
  Timer? _timer;
  final StreamController<EegSample> _eegCtrl = StreamController<EegSample>.broadcast();
  Stream<EegSample> get eegStream => _eegCtrl.stream;

  bool _isSeizureActive = false;
  double _seizureTime = 0.0;
  int _sampleIdx = 0;
  double _t = 0.0;
  final math.Random _rng = math.Random();

  bool get isSeizureActive => _isSeizureActive;

  void start() {
    _timer?.cancel();
    // 25 batches/sec (every 40ms, send 10 samples = 250 SPS)
    _timer = Timer.periodic(const Duration(milliseconds: 40), (timer) {
      for (int i = 0; i < 10; i++) {
        _t += 0.004; // 1/250s
        double ch1;
        double ch2;

        if (_isSeizureActive) {
          _seizureTime += 0.004;
          // 3.2 Hz Generalized Spike-and-Wave Discharge (80 to 140 µV)
          final phase = 2.0 * math.pi * 3.2 * _t;
          final spike = 110.0 * math.pow(math.sin(phase), 9).toDouble();
          final slowWave = 55.0 * math.sin(phase - 0.7);
          final seizureWave = spike + slowWave + (_rng.nextDouble() - 0.5) * 12.0;

          ch1 = seizureWave;
          ch2 = seizureWave * 0.90 + (_rng.nextDouble() - 0.5) * 8.0;

          if (_seizureTime > 20.0) {
            _isSeizureActive = false;
          }
        } else {
          // Normal Baseline: 10 Hz Alpha Rhythm (14 µV) + Noise
          final alpha = 14.0 * math.sin(2.0 * math.pi * 10.0 * _t);
          final noise1 = (_rng.nextDouble() - 0.5) * 7.0;
          final noise2 = (_rng.nextDouble() - 0.5) * 6.5;

          ch1 = alpha + noise1;
          ch2 = (alpha * 0.85) + noise2 + 3.0 * math.sin(_t * 1.5);
        }

        _eegCtrl.add(EegSample(
          sampleIdx: _sampleIdx++,
          loff: 0,
          ch1Uv: ch1,
          ch2Uv: ch2,
          ch3Uv: ch1 * 0.75,
          ch4Uv: ch2 * 0.80,
        ));
      }
    });
  }

  void triggerSeizure() {
    _isSeizureActive = true;
    _seizureTime = 0.0;
  }

  void resetSeizure() {
    _isSeizureActive = false;
    _seizureTime = 0.0;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    stop();
    _eegCtrl.close();
  }
}
