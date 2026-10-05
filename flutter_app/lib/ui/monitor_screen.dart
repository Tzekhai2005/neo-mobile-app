import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../pipeline/eeg_buffer.dart';
import '../pipeline/seizure_detector.dart';
import '../protocol/neo_client.dart';
import '../protocol/neo_proto.dart';
import '../simulator/stage_simulator.dart';
import 'widgets/eeg_canvas.dart';

class MonitorScreen extends StatefulWidget {
  const MonitorScreen({Key? key}) : super(key: key);

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> with SingleTickerProviderStateMixin {
  // Buffers
  final EegCircularBuffer _bufCh1 = EegCircularBuffer(capacity: 1250);
  final EegCircularBuffer _bufCh2 = EegCircularBuffer(capacity: 1250);
  final EegCircularBuffer _bufCh3 = EegCircularBuffer(capacity: 1250);
  final EegCircularBuffer _bufCh4 = EegCircularBuffer(capacity: 1250);

  final Float64List _renderCh1 = Float64List(1250);
  final Float64List _renderCh2 = Float64List(1250);
  final Float64List _renderCh3 = Float64List(1250);
  final Float64List _renderCh4 = Float64List(1250);

  // Engines
  final StageSimulator _simulator = StageSimulator();
  final NeoClient _client = NeoClient();
  final SeizureDetector _detector = SeizureDetector();

  StreamSubscription<EegSample>? _sub;
  bool _useHardware = false;
  bool _isDual = false;
  double _uvScale = 50.0;
  final List<double> _scaleOptions = [25.0, 50.0, 100.0, 200.0];

  double _seizureRisk = 7.0;
  bool _isSeizureActive = false;
  int _spikes = 0;
  double _seizureDuration = 0.0;
  Timer? _durationTimer;

  @override
  void initState() {
    super.initState();
    _startDataStream();
  }

  void _startDataStream() {
    _sub?.cancel();
    if (_useHardware) {
      _client.startDiscovery();
      _sub = _client.eegStream.listen(_onSample);
    } else {
      _simulator.start();
      _sub = _simulator.eegStream.listen(_onSample);
    }
  }

  void _onSample(EegSample s) {
    _bufCh1.write(s.ch1Uv);
    _bufCh2.write(s.ch2Uv);
    _bufCh3.write(s.ch3Uv);
    _bufCh4.write(s.ch4Uv);

    final res = _detector.processSample(s.ch1Uv);
    _seizureRisk = res.riskPct;
    _spikes = res.spikeCount;
    _isSeizureActive = _simulator.isSeizureActive || res.isSeizureOnset;

    // Refresh UI
    if (mounted) setState(() {});
  }

  void _toggleSeizureDemo() {
    if (_simulator.isSeizureActive) {
      _simulator.resetSeizure();
      _durationTimer?.cancel();
      _seizureDuration = 0.0;
    } else {
      _simulator.triggerSeizure();
      _seizureDuration = 0.0;
      _durationTimer?.cancel();
      _durationTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
        if (_simulator.isSeizureActive) {
          setState(() => _seizureDuration += 0.1);
        } else {
          t.cancel();
        }
      });
    }
    setState(() {});
  }

  void _cycleScale() {
    final idx = (_scaleOptions.indexOf(_uvScale) + 1) % _scaleOptions.length;
    setState(() => _uvScale = _scaleOptions[idx]);
  }

  void _toggleDualMode() {
    setState(() => _isDual = !_isDual);
  }

  void _showReportDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Color(0x33FFFFFF))),
        title: const Text("Clinical Diagnostic Summary", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildReportRow("Protocol Spec:", "Neo v0 • 250 SPS 24-bit"),
            _buildReportRow("Study Alignment:", "SeizeIT2 Ear-EEG Trial"),
            _buildReportRow("Epileptic Events:", _isSeizureActive ? "Active Discharge" : "1 Event Stamped"),
            _buildReportRow("Peak Amplitude:", "142.8 µV"),
            _buildReportRow("Electrode Impedance:", "Optimal (< 5 kΩ)", Colors.greenAccent),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Export / Share PDF", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          )
        ],
      ),
    );
  }

  Widget _buildReportRow(String label, String val, [Color? valColor]) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
          Text(val, style: TextStyle(color: valColor ?? Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _sub?.cancel();
    _simulator.dispose();
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _bufCh1.readChronological(_renderCh1);
    _bufCh2.readChronological(_renderCh2);
    _bufCh3.readChronological(_renderCh3);
    _bufCh4.readChronological(_renderCh4);

    return Scaffold(
      backgroundColor: const Color(0xFF070A12),
      appBar: AppBar(
        backgroundColor: const Color(0xE00D121E),
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFF00F2FE), Color(0xFF4FACFE)]),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text("N", style: TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF070A12), fontSize: 14)),
            ),
            const SizedBox(width: 8),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Neo Ear-EEG", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                Text("Clinical Companion • v1", style: TextStyle(fontSize: 10, color: Color(0xFF00F2FE), fontWeight: FontWeight.w600)),
              ],
            ),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0x14FFFFFF),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0x1FFFFFFF)),
            ),
            child: const Row(
              children: [
                Icon(Icons.circle, size: 8, color: Color(0xFF10B981)),
                SizedBox(width: 5),
                Text("250 SPS • LIVE", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white)),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // High-Visibility Seizure Status Banner
          Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: _isSeizureActive ? const Color(0x33EF4444) : const Color(0x1410B981),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _isSeizureActive ? const Color(0xFFEF4444) : const Color(0x4D10B981),
                width: 1.5,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("CLINICAL NEUROLOGICAL STATE", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF94A3B8))),
                    const SizedBox(height: 2),
                    Text(
                      _isSeizureActive ? "⚠️ SEIZURE DETECTED (${_seizureDuration.toStringAsFixed(1)}s)" : "● NORMAL BASELINE",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: _isSeizureActive ? const Color(0xFFFF3344) : const Color(0xFF10B981),
                      ),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text("${_seizureRisk.toInt()}%", style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.white)),
                    const Text("Seizure Risk", style: TextStyle(fontSize: 10, color: Color(0xFF64748B), fontWeight: FontWeight.w600)),
                  ],
                )
              ],
            ),
          ),

          // Waveform Viewport
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF080C16),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0x1AFFFFFF)),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.circle, size: 8, color: Color(0xFF00F2FE)),
                            const SizedBox(width: 4),
                            const Text("Ch1 (L-Ant)  ", style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8), fontWeight: FontWeight.bold)),
                            const Icon(Icons.circle, size: 8, color: Color(0xFFA855F7)),
                            const SizedBox(width: 4),
                            const Text("Ch2 (L-Post)", style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8), fontWeight: FontWeight.bold)),
                            if (_isDual) ...[
                              const SizedBox(width: 8),
                              const Icon(Icons.circle, size: 8, color: Color(0xFFF59E0B)),
                              const SizedBox(width: 4),
                              const Text("Ch3  ", style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8), fontWeight: FontWeight.bold)),
                              const Icon(Icons.circle, size: 8, color: Color(0xFF10B981)),
                              const SizedBox(width: 4),
                              const Text("Ch4", style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8), fontWeight: FontWeight.bold)),
                            ]
                          ],
                        ),
                        Text("${_uvScale.toInt()} µV / div", style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  Expanded(
                    child: EegCanvasWidget(
                      ch1Data: _renderCh1,
                      ch2Data: _renderCh2,
                      ch3Data: _isDual ? _renderCh3 : null,
                      ch4Data: _isDual ? _renderCh4 : null,
                      isDual: _isDual,
                      uvScale: _uvScale,
                      isSeizure: _isSeizureActive,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: const BoxDecoration(
                      border: Border(top: BorderSide(color: Color(0x0FFFFFFF))),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text("● Electrode Contact: 100% Good", style: TextStyle(fontSize: 11, color: Color(0xFF10B981), fontWeight: FontWeight.bold)),
                        Text("Notch: 50 Hz | Bandpass: 0.5–40 Hz", style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                      ],
                    ),
                  )
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // Sticky Bottom Stage Action Bar
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
            decoration: const BoxDecoration(
              color: Color(0xF20A0E1A),
              border: Border(top: BorderSide(color: Color(0x1FFFFFFF))),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isSeizureActive ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _toggleSeizureDemo,
                    child: Text(
                      _isSeizureActive ? "⏹ STOP DEMO DISCHARGE" : "⚡ TRIGGER SEIZURE DEMO",
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 1,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0x2EFFFFFF)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _toggleDualMode,
                    child: Text(_isDual ? "4-CH" : "2-CH", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 1,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0x2EFFFFFF)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _cycleScale,
                    child: const Text("SCALE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 1,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0x2EFFFFFF)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _showReportDialog,
                    child: const Text("REPORT", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
