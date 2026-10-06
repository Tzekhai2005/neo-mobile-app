import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../protocol/neo_client.dart';
import '../protocol/neo_proto.dart';
import '../pipeline/eeg_buffer.dart';
import '../pipeline/seizure_detector.dart';
import '../simulator/stage_simulator.dart';
import 'widgets/eeg_canvas.dart';



// ─── Design tokens (matches web index.html) ───────────────────────────────────
const kBg         = Color(0xFF090c15);
const kSurface1   = Color(0xFF0f1422);
const kSurface2   = Color(0xFF151d30);
const kBorder     = Color(0x14FFFFFF);
const kText1      = Color(0xFFF8FAFC);
const kText2      = Color(0xFF94A3B8);
const kText3      = Color(0xFF64748B);
const kCh1        = Color(0xFF00b4d8);
const kCh2        = Color(0xFF818CF8);
const kGreen      = Color(0xFF10B981);
const kAmber      = Color(0xFFF59E0B);
const kRed        = Color(0xFFEF4444);
const kPurple     = Color(0xFFA855F7);
// ──────────────────────────────────────────────────────────────────────────────

/// Fully standalone screen: discovers Neo hardware on Wi-Fi via UDP HELLO,
/// connects directly, streams real EEG — no Mac server required.
class StandaloneScreen extends StatefulWidget {
  const StandaloneScreen({Key? key}) : super(key: key);

  @override
  State<StandaloneScreen> createState() => _StandaloneScreenState();
}

enum _SourceMode { sim, connecting, hardware }
enum _DisplayMode { raw, demo }

class _StandaloneScreenState extends State<StandaloneScreen>
    with SingleTickerProviderStateMixin {

  // ── Data engine ────────────────────────────────────────────────────────────
  final NeoClient   _client    = NeoClient();
  final StageSimulator _sim    = StageSimulator();
  final SeizureDetector _det   = SeizureDetector();

  final EegCircularBuffer _b1 = EegCircularBuffer(capacity: 1250);
  final EegCircularBuffer _b2 = EegCircularBuffer(capacity: 1250);
  final EegCircularBuffer _b3 = EegCircularBuffer(capacity: 1250);
  final EegCircularBuffer _b4 = EegCircularBuffer(capacity: 1250);
  final Float64List _r1 = Float64List(1250);
  final Float64List _r2 = Float64List(1250);
  final Float64List _r3 = Float64List(1250);
  final Float64List _r4 = Float64List(1250);

  StreamSubscription<EegSample>? _eegSub;
  StreamSubscription<NeoDeviceInfo>? _discoverySub;

  // ── State ──────────────────────────────────────────────────────────────────
  _SourceMode _source = _SourceMode.connecting;
  _DisplayMode _displayMode = _DisplayMode.raw;
  NeoDeviceInfo? _device;
  String _statusMsg = 'Scanning for Neo device…';
  bool _seizureActive = false;
  double _seizureDuration = 0.0;
  double _seizureRisk = 7.0;
  int _batteryPct = 92;
  bool _leadOff = false;
  double _uvScale = 50.0;
  bool _isDual = false;
  int _currentTab = 0;
  int _lastChannelCount = 2;
  Timer? _durationTimer;
  Timer? _discoveryTimeoutTimer;

  final List<_DiaryEntry> _diary = [];
  int _ictalCount = 0;
  int _markerCount = 0;

  late TabController _tabController;

  // ── Lifecycle ──────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _startDiscovery();
  }

  void _startDiscovery() {
    setState(() {
      _source = _SourceMode.connecting;
      _statusMsg = 'Scanning for Neo device on Wi-Fi…';
    });

    _discoverySub?.cancel();
    _client.startDiscovery();
    _discoverySub = _client.onDeviceDiscovered.listen(_onDeviceFound);

    // If no device found in 5 s, fall back to simulator
    _discoveryTimeoutTimer?.cancel();
    _discoveryTimeoutTimer = Timer(const Duration(seconds: 5), () {
      if (_source == _SourceMode.connecting) {
        _fallbackToSimulator();
      }
    });
  }

  void _onDeviceFound(NeoDeviceInfo dev) {
    _discoveryTimeoutTimer?.cancel();
    setState(() {
      _device = dev;
      _source = _SourceMode.connecting;
      _statusMsg = 'Found ${dev.name} @ ${dev.ip} — connecting…';
    });
    _connectToDevice(dev);
  }

  Future<void> _connectToDevice(NeoDeviceInfo dev) async {
    _eegSub?.cancel();
    _sim.dispose();

    final ok = await _client.connectAndStart(dev);
    if (!ok) {
      _fallbackToSimulator();
      return;
    }
    setState(() {
      _source = _SourceMode.hardware;
      _batteryPct = dev.batteryPct;
      _statusMsg = 'Streaming from ${dev.name}';
    });
    _eegSub = _client.eegStream.listen(_onSample);
  }

  void _fallbackToSimulator() {
    _eegSub?.cancel();
    _sim.start();
    setState(() {
      _source = _SourceMode.sim;
      _statusMsg = 'No hardware found — Simulator active';
    });
    _eegSub = _sim.eegStream.listen(_onSample);
  }

  void _onSample(EegSample s) {
    final channels = _displayMode == _DisplayMode.raw && s.channelsUv.isNotEmpty
        ? s.channelsUv
        : [s.ch1Uv, s.ch2Uv, s.ch3Uv, s.ch4Uv];
    _lastChannelCount = channels.length;

    if (channels.isNotEmpty) {
      _b1.write(channels[0]);
    }
    if (channels.length > 1) {
      _b2.write(channels[1]);
    }
    if (channels.length > 2) {
      _b3.write(channels[2]);
    }
    if (channels.length > 3) {
      _b4.write(channels[3]);
    }

    final r = _det.processSample(s.ch1Uv);
    _seizureRisk = r.riskPct;
    final nowSeizure = _sim.isSeizureActive || r.isSeizureOnset;
    if (nowSeizure && !_seizureActive) _onSeizureStart();
    if (!nowSeizure && _seizureActive) _onSeizureEnd();
    if (mounted) setState(() {});
  }

  void _onSeizureStart() {
    _seizureActive = true;
    _seizureDuration = 0.0;
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_seizureActive && mounted) setState(() => _seizureDuration += 0.1);
    });
    _ictalCount++;
    _diary.insert(0, _DiaryEntry(
      type: 'ictal',
      time: TimeOfDay.now(),
      heading: 'Generalised 3.2 Hz Spike-Wave Discharge',
      body: 'Automated detection. Peak amplitude: 142.8 µV. Confidence: 94%.',
    ));
  }

  void _onSeizureEnd() {
    _seizureActive = false;
    _durationTimer?.cancel();
  }

  // ── Actions ────────────────────────────────────────────────────────────────
  void _triggerSeizureDemo() {
    _sim.triggerSeizure();
    _showToast('⚡ Ictal Paroxysm Triggered');
  }

  void _resetBaseline() {
    _sim.resetSeizure();
    _showToast('✓ Baseline Restored');
  }

  void _stampMarker() {
    _markerCount++;
    final t = TimeOfDay.now();
    _diary.insert(0, _DiaryEntry(
      type: 'marker',
      time: t,
      heading: 'SW1 Patient Marker',
      body: 'Patient-initiated event tag. Correlates with subjective aura.',
    ));
    _showToast('📍 SW1 Marker @ ${_fmt(t)}');
    setState(() {});
  }

  void _cycleScale() {
    const scales = [25.0, 50.0, 100.0, 200.0];
    final i = (scales.indexOf(_uvScale) + 1) % scales.length;
    setState(() => _uvScale = scales[i]);
    _showToast('Scale: ${scales[i].toInt()} µV / div');
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
      duration: const Duration(seconds: 2),
      backgroundColor: kSurface2,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ));
  }

  String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2,'0')}:${t.minute.toString().padLeft(2,'0')}';

  @override
  void dispose() {
    _durationTimer?.cancel();
    _discoveryTimeoutTimer?.cancel();
    _eegSub?.cancel();
    _discoverySub?.cancel();
    _client.dispose();
    _sim.dispose();
    _tabController.dispose();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    _b1.readChronological(_r1);
    _b2.readChronological(_r2);
    _b3.readChronological(_r3);
    _b4.readChronological(_r4);

    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _buildTelemetryTab(),
                  _buildDiaryTab(),
                  _buildHardwareTab(),
                  _buildBenchTab(),
                ],
              ),
            ),
            _buildBottomNav(),
          ],
        ),
      ),
    );
  }

  // ── Top bar ────────────────────────────────────────────────────────────────
  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xF00f1422),
        border: Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: kSurface2,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kBorder),
              ),
              child: const Icon(Icons.graphic_eq_rounded, color: kCh1, size: 16),
            ),
            const SizedBox(width: 10),
            const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Neo Ear-EEG', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: kText1)),
              Text('SUBJ-4092 • AMBULATORY V2', style: TextStyle(fontSize: 10, color: kText3, fontFamily: 'monospace')),
            ]),
          ]),
          _buildSourcePill(),
        ],
      ),
    );
  }

  Widget _buildSourcePill() {
    Color col;
    String label;
    switch (_source) {
      case _SourceMode.hardware:  col = kGreen;  label = 'LIVE'; break;
      case _SourceMode.connecting: col = kAmber; label = 'SCANNING'; break;
      case _SourceMode.sim:       col = kPurple; label = 'SIM'; break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: col.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: col.withOpacity(0.4)),
      ),
      child: Row(children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(
          color: col, shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: col, blurRadius: 4)],
        )),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: col, fontFamily: 'monospace')),
      ]),
    );
  }

  // ── Telemetry tab ──────────────────────────────────────────────────────────
  Widget _buildTelemetryTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _buildDisplayModeToggle(),
        const SizedBox(height: 10),
        // Source strip
        _buildSourceStrip(),
        const SizedBox(height: 10),
        // Seizure / state banner
        _buildStateBanner(),
        const SizedBox(height: 10),
        // Oscilloscope
        _buildOscilloscope(),
        const SizedBox(height: 10),
        // Vitals grid
        _buildVitalsGrid(),
      ]),
    );
  }

  Widget _buildDisplayModeToggle() {
    final rawActive = _displayMode == _DisplayMode.raw;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: kSurface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Row(children: [
        Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _displayMode = _DisplayMode.raw),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: rawActive ? kCh1.withOpacity(0.14) : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('RAW UDP', textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: rawActive ? kCh1 : kText3)),
            ),
          ),
        ),
        Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _displayMode = _DisplayMode.demo),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: !rawActive ? kPurple.withOpacity(0.14) : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('DEMO', textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: !rawActive ? kPurple : kText3)),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildSourceStrip() {
    Color col; String badge; String title; String detail;
    switch (_source) {
      case _SourceMode.hardware:
        col = kGreen; badge = 'LIVE HARDWARE';
        title = _device?.name ?? 'Neo v1';
        detail = 'ADS1292R • 250 SPS • IP: ${_device?.ip ?? '—'}';
        break;
      case _SourceMode.connecting:
        col = kAmber; badge = 'SCANNING';
        title = 'Searching for Neo device…';
        detail = 'UDP HELLO broadcast on port 5000';
        break;
      case _SourceMode.sim:
        col = kPurple; badge = 'INTERNAL SIM';
        title = 'Autonomous Simulation Engine';
        detail = '250 SPS Synthetic Rhythm • Tap to retry hardware';
        break;
    }
    return GestureDetector(
      onTap: _source == _SourceMode.sim ? _startDiscovery : null,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: col.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: col.withOpacity(0.35)),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(color: col.withOpacity(0.2), borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: col.withOpacity(0.4))),
                child: Text(badge, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: col, fontFamily: 'monospace')),
              ),
              const SizedBox(width: 8),
              Flexible(child: Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: kText1), overflow: TextOverflow.ellipsis)),
            ]),
            const SizedBox(height: 3),
            Text(detail, style: const TextStyle(fontSize: 11, color: kText2)),
          ])),
          if (_source == _SourceMode.sim)
            Icon(Icons.refresh_rounded, color: col.withOpacity(0.6), size: 18),
        ]),
      ),
    );
  }

  Widget _buildStateBanner() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _seizureActive ? kRed.withOpacity(0.1) : kGreen.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _seizureActive ? kRed.withOpacity(0.5) : kGreen.withOpacity(0.3)),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('ELECTROPHYSIOLOGICAL STATE',
              style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: kText3, letterSpacing: 0.6)),
          const SizedBox(height: 3),
          Text(
            _seizureActive
                ? '⚠️  Paroxysmal Discharge (${_seizureDuration.toStringAsFixed(1)}s)'
                : '●  Normal Resting Continuity',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800,
                color: _seizureActive ? kRed : kGreen),
          ),
        ]),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${_seizureRisk.toInt()}%',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: kText1, fontFamily: 'monospace')),
          const Text('Paroxysm Risk',
              style: TextStyle(fontSize: 9, color: kText3, fontWeight: FontWeight.w600)),
        ]),
      ]),
    );
  }

  Widget _buildOscilloscope() {
    final rawChannels = _displayMode == _DisplayMode.raw ? _lastChannelCount : 2;
    final showDual = _displayMode == _DisplayMode.raw ? rawChannels > 2 : _isDual;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF050811),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      child: Column(children: [
        // Header row
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Row(children: [
              _ChipDot(color: kCh1, label: _displayMode == _DisplayMode.raw ? 'Raw Ch1' : 'Ch1 Ant'),
              const SizedBox(width: 10),
              _ChipDot(color: kCh2, label: _displayMode == _DisplayMode.raw ? 'Raw Ch2' : 'Ch2 Post'),
              if (showDual) ...[
                const SizedBox(width: 10),
                _ChipDot(color: const Color(0xFFF59E0B), label: 'Ch3'),
                const SizedBox(width: 10),
                _ChipDot(color: const Color(0xFF10B981), label: 'Ch4'),
              ],
            ]),
            Row(children: [
              _CtrlBtn(label: '${_uvScale.toInt()} µV', onTap: _cycleScale, active: true),
              const SizedBox(width: 6),
              _CtrlBtn(label: showDual ? '4-CH' : '2-CH', onTap: () => setState(() => _isDual = !_isDual), active: showDual),
            ]),
          ]),
        ),
        // Canvas
        SizedBox(
          height: 200,
          child: EegCanvasWidget(
            ch1Data: _r1,
            ch2Data: _r2,
            ch3Data: showDual ? _r3 : null,
            ch4Data: showDual ? _r4 : null,
            isDual: showDual,
            uvScale: _uvScale,
            isSeizure: _seizureActive,
          ),
        ),
        // Footer
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Row(children: [
              Icon(Icons.circle, size: 7,
                  color: _leadOff ? kRed : kGreen),
              const SizedBox(width: 5),
              Text(_leadOff ? 'Lead-Off Fault' : 'Impedance: Optimal (< 5 kΩ)',
                  style: TextStyle(fontSize: 10, color: _leadOff ? kRed : kText3)),
            ]),
            const Text('Notch: 50 Hz  |  BPF: 0.5–40 Hz',
                style: TextStyle(fontSize: 10, color: kText3)),
          ]),
        ),
      ]),
    );
  }

  Widget _buildVitalsGrid() {
    return GridView.count(
      crossAxisCount: 2,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 2.4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        _VitalTile(label: 'Data Source', value:
          _source == _SourceMode.hardware ? 'Live Hardware' :
          _source == _SourceMode.connecting ? 'Scanning…' : 'Simulator',
          note: _device?.ip ?? 'UDP 5000'),
        _VitalTile(label: 'Battery', value: '$_batteryPct%',
            note: 'BQ25180 Power Path'),
        _VitalTile(label: 'Ictal Events', value: '$_ictalCount',
            note: '3.2 Hz Spike Window'),
        _VitalTile(label: 'SW1 Markers', value: '$_markerCount',
            note: 'Patient-Initiated'),
      ],
    );
  }

  // ── Diary tab ──────────────────────────────────────────────────────────────
  Widget _buildDiaryTab() {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Ambulatory Event Diary',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: kText1)),
        const SizedBox(height: 2),
        const Text('SeizeIT2 Clinical Trial Protocol — continuous event record.',
            style: TextStyle(fontSize: 12, color: kText3)),
        const SizedBox(height: 14),
        Row(children: [
          _StatCard(num: '$_ictalCount', label: 'Ictal Events'),
          const SizedBox(width: 8),
          _StatCard(num: '$_markerCount', label: 'SW1 Markers'),
          const SizedBox(width: 8),
          _StatCard(num: '99.8%', label: 'Usable Time', color: kGreen),
        ]),
        const SizedBox(height: 14),
        Expanded(
          child: _diary.isEmpty
            ? Center(child: Text('No events yet.\nEvents appear here automatically.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: kText3, fontSize: 13, height: 1.6)))
            : ListView.separated(
                itemCount: _diary.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _DiaryCard(entry: _diary[i]),
              ),
        ),
      ]),
    );
  }

  // ── Hardware tab ───────────────────────────────────────────────────────────
  Widget _buildHardwareTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Silicon Architecture',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: kText1)),
        const SizedBox(height: 14),
        _SpecGroup(title: 'Processing Unit', items: const [
          ['MCU', 'ESP32-S3 (Xtensa LX7 @ 240 MHz)'],
          ['RAM', '512 KB SRAM + 8 MB PSRAM'],
          ['Flash', '16 MB Quad-SPI NOR'],
          ['Connectivity', 'Wi-Fi 802.11 b/g/n + BLE 5.0'],
        ]),
        const SizedBox(height: 14),
        _SpecGroup(title: 'Biopotential Frontend', items: const [
          ['AFE', 'ADS1292R (Texas Instruments)'],
          ['Resolution', '24-bit delta-sigma ADC'],
          ['Sampling Rate', '250 SPS (configurable to 500 SPS)'],
          ['Gain', '6× (configurable)'],
          ['Input Noise', '4 µVpp (0.5–40 Hz BPF)'],
          ['CMRR', '> 80 dB'],
        ]),
        const SizedBox(height: 14),
        _SpecGroup(title: 'Motion & Inertial', items: const [
          ['IMU', 'ICM-42670-P (InvenSense)'],
          ['Gyroscope', '±2000 dps, 16-bit'],
          ['Accelerometer', '±16 g, 16-bit'],
          ['IMU Rate', '100 Hz'],
        ]),
        const SizedBox(height: 14),
        _SpecGroup(title: 'Power Management', items: const [
          ['PMIC', 'BQ25180 (TI) — USB-C charge path'],
          ['Battery', '120 mAh LiPo (ear-worn form)'],
          ['Runtime', '~12 h continuous recording'],
        ]),
        if (_device != null) ...[
          const SizedBox(height: 14),
          _SpecGroup(title: 'Connected Device', items: [
            ['Device Name', _device!.name],
            ['IP Address', _device!.ip],
            ['Control Port', '${_device!.ctrlPort}'],
            ['Battery', '${_device!.batteryPct}%'],
          ]),
        ],
      ]),
    );
  }

  // ── Bench / Demo tab ───────────────────────────────────────────────────────
  Widget _buildBenchTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Clinical Test Bench',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: kText1)),
        const SizedBox(height: 2),
        const Text('Controlled tools for demo validation and stage demonstration.',
            style: TextStyle(fontSize: 12, color: kText3)),
        const SizedBox(height: 16),
        const _SectionLabel('SIGNAL SIMULATION'),
        const SizedBox(height: 8),
        GridView.count(crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10,
          childAspectRatio: 2.0, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
          children: [
            _BenchBtn(label: 'Trigger Ictal Paroxysm', sub: '3.2 Hz spike-wave',
                color: kRed, onTap: _triggerSeizureDemo),
            _BenchBtn(label: 'Reset Baseline', sub: 'Restore resting alpha',
                color: kText2, onTap: _resetBaseline),
            _BenchBtn(label: 'SW1 Patient Marker', sub: 'Tactile event stamp',
                color: kAmber, onTap: _stampMarker),
            _BenchBtn(label: 'Lead-Off Fault', sub: 'Impedance > 50 kΩ',
                color: kText2, onTap: () {
                  setState(() => _leadOff = true);
                  _showToast('⚠️ Lead-Off on IN1P');
                  Future.delayed(const Duration(seconds: 5), () {
                    if (mounted) setState(() => _leadOff = false);
                    _showToast('✓ Electrode Contact Restored');
                  });
                }),
          ],
        ),
        const SizedBox(height: 20),
        const _SectionLabel('HARDWARE CONNECTION'),
        const SizedBox(height: 8),
        _BenchBtn(label: 'Retry Hardware Discovery', sub: 'Scan UDP 5000 for Neo HELLO beacon',
            color: kGreen, onTap: _startDiscovery),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: kSurface1, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kBorder)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('STATUS', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: kText3, letterSpacing: 0.8)),
            const SizedBox(height: 6),
            Text(_statusMsg, style: const TextStyle(fontSize: 12, color: kText2, fontFamily: 'monospace')),
            if (_device != null) ...[
              const SizedBox(height: 4),
              Text('Device: ${_device!.name}  •  ${_device!.ip}:${_device!.ctrlPort}',
                  style: const TextStyle(fontSize: 11, color: kGreen, fontFamily: 'monospace')),
            ],
          ]),
        ),
        const SizedBox(height: 20),
        const _SectionLabel('REPORTS'),
        const SizedBox(height: 8),
        _BenchBtn(label: 'Generate Study Summary', sub: 'SeizeIT2 clinical trial report',
            color: kCh1, onTap: () => _showReport()),
      ]),
    );
  }

  void _showReport() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kSurface1,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: Container(width: 32, height: 4,
                decoration: BoxDecoration(color: kText3, borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 16),
            const Text('Clinical Diagnostic Summary',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: kText1)),
            const SizedBox(height: 16),
            _ReportRow('Protocol', 'Neo v1 • ADS1292R 250 SPS 24-bit'),
            _ReportRow('Study Alignment', 'SeizeIT2 Ear-EEG Clinical Trial'),
            _ReportRow('Ictal Events', '$_ictalCount confirmed events'),
            _ReportRow('Patient Markers', '$_markerCount SW1 stamps'),
            _ReportRow('Peak Amplitude', '142.8 µV (Ch1)'),
            _ReportRow('Impedance', '< 5 kΩ — Optimal', color: kGreen),
            _ReportRow('Data Source', _source == _SourceMode.hardware ? 'Live Hardware' : 'Simulator'),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(color: kGreen.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: kGreen.withOpacity(0.4))),
                child: const Text('Export / Share PDF',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: kGreen)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Bottom nav ─────────────────────────────────────────────────────────────
  Widget _buildBottomNav() {
    const tabs = [
      (Icons.monitor_heart_outlined, Icons.monitor_heart, 'Telemetry'),
      (Icons.calendar_today_outlined, Icons.calendar_today, 'Diary'),
      (Icons.memory_outlined, Icons.memory, 'Hardware'),
      (Icons.science_outlined, Icons.science, 'Bench'),
    ];
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xF00f1422),
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: List.generate(tabs.length, (i) {
          final active = _tabController.index == i;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _tabController.animateTo(i)),
              child: Container(
                color: Colors.transparent,
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(active ? tabs[i].$2 : tabs[i].$1,
                      size: 22, color: active ? kCh1 : kText3),
                  const SizedBox(height: 3),
                  Text(tabs[i].$3,
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                          color: active ? kCh1 : kText3)),
                ]),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ─── Small reusable widgets ────────────────────────────────────────────────────

class _ChipDot extends StatelessWidget {
  final Color color; final String label;
  const _ChipDot({required this.color, required this.label});
  @override
  Widget build(BuildContext ctx) => Row(children: [
    Icon(Icons.circle, size: 8, color: color),
    const SizedBox(width: 4),
    Text(label, style: const TextStyle(fontSize: 11, color: kText2, fontWeight: FontWeight.w600)),
  ]);
}

class _CtrlBtn extends StatelessWidget {
  final String label; final VoidCallback onTap; final bool active;
  const _CtrlBtn({required this.label, required this.onTap, this.active = false});
  @override
  Widget build(BuildContext ctx) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: active ? kCh1.withOpacity(0.15) : kSurface2,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: active ? kCh1.withOpacity(0.4) : kBorder),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
          color: active ? kCh1 : kText2)),
    ),
  );
}

class _VitalTile extends StatelessWidget {
  final String label, value, note;
  const _VitalTile({required this.label, required this.value, required this.note});
  @override
  Widget build(BuildContext ctx) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(color: kSurface1, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(label.toUpperCase(), style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700,
          color: kText3, letterSpacing: 0.5)),
      const SizedBox(height: 3),
      Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: kText1,
          fontFamily: 'monospace'), overflow: TextOverflow.ellipsis),
      Text(note, style: const TextStyle(fontSize: 10, color: kText2), overflow: TextOverflow.ellipsis),
    ]),
  );
}

class _StatCard extends StatelessWidget {
  final String num, label; final Color? color;
  const _StatCard({required this.num, required this.label, this.color});
  @override
  Widget build(BuildContext ctx) => Expanded(child: Container(
    padding: const EdgeInsets.symmetric(vertical: 10),
    alignment: Alignment.center,
    decoration: BoxDecoration(color: kSurface1, borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kBorder)),
    child: Column(children: [
      Text(num, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800,
          color: color ?? kText1, fontFamily: 'monospace')),
      const SizedBox(height: 2),
      Text(label, style: const TextStyle(fontSize: 10, color: kText3, fontWeight: FontWeight.w600)),
    ]),
  ));
}

class _SpecGroup extends StatelessWidget {
  final String title; final List<List<String>> items;
  const _SpecGroup({required this.title, required this.items});
  @override
  Widget build(BuildContext ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Text(title.toUpperCase(), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
        color: kText3, letterSpacing: 0.6)),
    const SizedBox(height: 6),
    Container(
      decoration: BoxDecoration(color: kSurface1, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorder)),
      child: Column(children: items.map((r) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: kBorder,
            width: r == items.last ? 0 : 1))),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(r[0], style: const TextStyle(fontSize: 12, color: kText3)),
          Text(r[1], style: const TextStyle(fontSize: 12, color: kText1, fontWeight: FontWeight.w600,
              fontFamily: 'monospace')),
        ]),
      )).toList()),
    ),
  ]);
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext ctx) => Text(text,
      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: kText3, letterSpacing: 0.8));
}

class _BenchBtn extends StatelessWidget {
  final String label, sub; final Color color; final VoidCallback onTap;
  const _BenchBtn({required this.label, required this.sub, required this.color, required this.onTap});
  @override
  Widget build(BuildContext ctx) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color)),
        const SizedBox(height: 2),
        Text(sub, style: const TextStyle(fontSize: 11, color: kText3)),
      ]),
    ),
  );
}

class _DiaryEntry {
  final String type, heading, body; final TimeOfDay time;
  _DiaryEntry({required this.type, required this.time, required this.heading, required this.body});
}

class _DiaryCard extends StatelessWidget {
  final _DiaryEntry entry;
  const _DiaryCard({required this.entry});
  @override
  Widget build(BuildContext ctx) {
    final isIctal = entry.type == 'ictal';
    final tagColor = isIctal ? kRed : kAmber;
    final tagLabel = isIctal ? 'ICTAL EVENT' : 'SW1 MARKER';
    final t = entry.time;
    final ts = '${t.hour.toString().padLeft(2,'0')}:${t.minute.toString().padLeft(2,'0')}';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isIctal ? kRed.withOpacity(0.06) : kSurface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isIctal ? kRed.withOpacity(0.35) : kBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(color: tagColor.withOpacity(0.15), borderRadius: BorderRadius.circular(4),
                border: Border.all(color: tagColor.withOpacity(0.4))),
            child: Text(tagLabel, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: tagColor))),
          Text(ts, style: const TextStyle(fontSize: 11, color: kText3, fontFamily: 'monospace')),
        ]),
        const SizedBox(height: 7),
        Text(entry.heading, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: kText1)),
        const SizedBox(height: 4),
        Text(entry.body, style: const TextStyle(fontSize: 12, color: kText2, height: 1.4)),
      ]),
    );
  }
}

class _ReportRow extends StatelessWidget {
  final String label, value; final Color? color;
  const _ReportRow(this.label, this.value, {this.color});
  @override
  Widget build(BuildContext ctx) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(label, style: const TextStyle(fontSize: 12, color: kText2)),
      Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
          color: color ?? kText1)),
    ]),
  );
}
