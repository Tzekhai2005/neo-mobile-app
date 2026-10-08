import 'dart:math' as math;
import 'dart:typed_data';

import '../protocol/neo_messages.dart';

/// A copy of the most recent seconds of every live signal, in physical units.
/// Missing samples (lost packets, IMU not yet arrived) are NaN, so a graph can
/// draw a gap instead of squashing the trace.
class LiveSnapshot {
  /// EEG sample index of `eeg[c][0]`, the protocol's clock. Index 0 is the
  /// first sample after the last START.
  final int startIdx;

  /// EEG sample index of the newest sample, or -1 when nothing arrived yet.
  final int endIdx;
  final int eegRateHz;
  final int imuRateHz;
  final List<Float32List> eeg; // per channel, µV
  final Float32List accelX, accelY, accelZ; // g
  final Float32List gyroX, gyroY, gyroZ; // °/s

  const LiveSnapshot({
    required this.startIdx,
    required this.endIdx,
    required this.eegRateHz,
    required this.imuRateHz,
    required this.eeg,
    required this.accelX,
    required this.accelY,
    required this.accelZ,
    required this.gyroX,
    required this.gyroY,
    required this.gyroZ,
  });

  bool get isEmpty => endIdx < 0;
  int get channels => eeg.length;
  double get durationSec => eeg.isEmpty ? 0 : eeg.first.length / eegRateHz;
}

/// Rolling store of the last [maxWindowSec] seconds of EEG (2–4 channels),
/// accelerometer and gyro. The decoder writes packets as they arrive; the graph
/// reads a [snapshot] whenever it draws.
///
/// The EEG sample index is the clock (README §3). IMU samples are placed on it
/// from the packet header, so both signals share one time axis. A jump forward
/// in the index means samples were lost and leaves a NaN gap; a late packet
/// fills the gap in place; a jump back by more than a second means the stream
/// restarted, and the buffer starts over.
class LiveSignalBuffer {
  static const int maxChannels = 4;
  static const int imuAxes = 6; // ax, ay, az, gx, gy, gz

  final int maxWindowSec;

  int _eegRate = 250;
  int _imuRate = 100;
  List<double> _uvPerCount = const [0.04808, 0.04808];
  double _gPerLsb = 16.0 / 32768.0;
  double _dpsPerLsb = 2000.0 / 32768.0;

  late int _eegCap;
  late int _imuCap;
  late List<Float32List> _eeg;
  late List<Float32List> _imu;

  int _channels = 0;
  int _latestEeg = -1;
  int _latestImu = -1;
  int _eegReceived = 0;
  int _eegLostLink = 0;
  int _eegLostDevice = 0;
  int _imuReceived = 0;
  int _imuLostLink = 0;
  int _imuLostDevice = 0;
  int _leadOffMask = 0;

  // Packets lost on the link that no EEG (or IMU) packet has accounted for yet.
  // A `seq` gap shows up on whatever packet arrives first after the loss, which
  // is often not the next EEG packet.
  int _linkPendingEeg = 0;
  int _linkPendingImu = 0;

  LiveSignalBuffer({this.maxWindowSec = 30}) {
    _allocate();
  }

  // ── configuration ───────────────────────────────────────────────────────────

  int get eegRateHz => _eegRate;
  int get imuRateHz => _imuRate;

  /// Take rates and scale factors from the device INFO, then start over.
  void configure(NeoInfo info) {
    _eegRate = info.eegRateHz > 0 ? info.eegRateHz : _eegRate;
    _imuRate = info.imuRateHz > 0 ? info.imuRateHz : _imuRate;
    if (info.uvPerCount.every((v) => v > 0)) _uvPerCount = List.of(info.uvPerCount);
    if (info.imuGPerLsb > 0) _gPerLsb = info.imuGPerLsb;
    if (info.imuDpsPerLsb > 0) _dpsPerLsb = info.imuDpsPerLsb;
    _allocate();
  }

  void _allocate() {
    _eegCap = maxWindowSec * _eegRate;
    _imuCap = maxWindowSec * _imuRate;
    _eeg = [for (var c = 0; c < maxChannels; c++) _nanList(_eegCap)];
    _imu = [for (var a = 0; a < imuAxes; a++) _nanList(_imuCap)];
    _resetCounters();
  }

  static Float32List _nanList(int n) => Float32List(n)..fillRange(0, n, double.nan);

  void _resetCounters() {
    _channels = 0;
    _latestEeg = -1;
    _latestImu = -1;
    _eegReceived = _eegLostLink = _eegLostDevice = 0;
    _imuReceived = _imuLostLink = _imuLostDevice = 0;
    _leadOffMask = 0;
    _linkPendingEeg = _linkPendingImu = 0;
  }

  /// Forget everything (a new stream starts at index 0).
  void reset() {
    for (final r in _eeg) {
      r.fillRange(0, r.length, double.nan);
    }
    for (final r in _imu) {
      r.fillRange(0, r.length, double.nan);
    }
    _resetCounters();
  }

  // ── status ──────────────────────────────────────────────────────────────────

  bool get hasData => _latestEeg >= 0;

  /// Channels in the current stream (2–4); 0 before the first packet.
  int get channels => _channels;

  /// Newest EEG sample index, or -1.
  int get latestEegIndex => _latestEeg;

  int get eegSamplesReceived => _eegReceived;
  /// All EEG samples missing from the stream: [eegSamplesLostLink] plus
  /// [eegSamplesLostDevice].
  int get eegSamplesLost => _eegLostLink + _eegLostDevice;

  /// Missing EEG samples that went with packets lost on the Wi-Fi link (a `seq`
  /// gap, README §2). An estimate: it assumes every lost packet was an EEG
  /// packet of the same size as the one after the gap, so it can overcount when
  /// IMU or STATUS packets were the ones lost; the rest is counted as device loss.
  int get eegSamplesLostLink => _eegLostLink;

  /// Missing EEG samples with no `seq` gap, so the device never sent them (ring
  /// overrun, bad ADC frames; README §3).
  int get eegSamplesLostDevice => _eegLostDevice;

  int get imuSamplesReceived => _imuReceived;
  int get imuSamplesLost => _imuLostLink + _imuLostDevice;
  int get imuSamplesLostLink => _imuLostLink;
  int get imuSamplesLostDevice => _imuLostDevice;

  /// ADS1292R lead-off bits of the newest sample (bit 0–3 electrodes, 4 RLD).
  int get leadOffMask => _leadOffMask;
  bool get leadOff => (_leadOffMask & 0x0F) != 0;

  // ── writing ─────────────────────────────────────────────────────────────────

  /// Tell the buffer that [packets] data packets went missing on the link right
  /// before a packet that is not EEG or IMU (STATUS, EVENT). The EEG and IMU
  /// writers read their own packets' gaps from the header.
  void noteLinkGap(int packets) {
    if (packets <= 0) return;
    _linkPendingEeg += packets;
    _linkPendingImu += packets;
  }

  void pushEeg(NeoEegPacket p) {
    final n = p.samples.length;
    if (n == 0) return;
    noteLinkGap(p.header.linkGap);
    if (p.channels != _channels) {
      reset(); // a different channel count is a different stream
      _channels = p.channels;
    }
    final start = p.header.sampleIdx;
    if (_latestEeg >= 0 && start + n - 1 < _latestEeg - _eegRate) reset(); // index went back: restart
    if (_channels == 0) _channels = p.channels;

    if (_latestEeg < 0) {
      _latestEeg = start - 1; // first packet: nothing before it counts as lost
    } else if (start > _latestEeg + 1) {
      final gap = start - _latestEeg - 1;
      final link = math.min(gap, _linkPendingEeg * n);
      _eegLostLink += link;
      _eegLostDevice += gap - link;
      for (var i = math.max(_latestEeg + 1, start - _eegCap); i < start; i++) {
        for (var c = 0; c < maxChannels; c++) {
          _eeg[c][i % _eegCap] = double.nan;
        }
      }
    }

    for (var k = 0; k < n; k++) {
      final idx = start + k;
      if (idx <= _latestEeg - _eegCap) continue; // older than the ring
      final pos = idx % _eegCap;
      final fresh = idx > _latestEeg || _eeg[0][pos].isNaN;
      final counts = p.samples[k].counts;
      for (var c = 0; c < _channels; c++) {
        _eeg[c][pos] = counts[c] * _uvPerCount[math.min(c, _uvPerCount.length - 1)];
      }
      if (fresh) {
        _eegReceived++;
        if (idx <= _latestEeg) {
          // A late packet filled a counted gap. Reordering is a link effect, so
          // take it back from the link count first.
          if (_eegLostLink > 0) {
            _eegLostLink--;
          } else {
            _eegLostDevice--;
          }
        }
      }
    }
    _latestEeg = math.max(_latestEeg, start + n - 1);
    _linkPendingEeg = 0;
    _leadOffMask = p.samples.last.loff;
  }

  void pushImu(NeoImuPacket p) {
    final n = p.samples.length;
    if (n == 0) return;
    noteLinkGap(p.header.linkGap);
    // The header carries the EEG index of the first IMU sample (README §3).
    final start = (p.header.sampleIdx * _imuRate / _eegRate).round();
    if (_latestImu >= 0 && start + n - 1 < _latestImu - _imuRate) {
      // Index went back: the EEG side restarts too; clear IMU only.
      for (final r in _imu) {
        r.fillRange(0, r.length, double.nan);
      }
      _latestImu = -1;
      _imuReceived = _imuLostLink = _imuLostDevice = 0;
    }

    if (_latestImu < 0) {
      _latestImu = start - 1;
    } else if (start > _latestImu + 1) {
      final gap = start - _latestImu - 1;
      final link = math.min(gap, _linkPendingImu * n);
      _imuLostLink += link;
      _imuLostDevice += gap - link;
      for (var i = math.max(_latestImu + 1, start - _imuCap); i < start; i++) {
        for (var a = 0; a < imuAxes; a++) {
          _imu[a][i % _imuCap] = double.nan;
        }
      }
    }

    for (var k = 0; k < n; k++) {
      final idx = start + k;
      if (idx <= _latestImu - _imuCap) continue;
      final pos = idx % _imuCap;
      final fresh = idx > _latestImu || _imu[0][pos].isNaN;
      final s = p.samples[k];
      _imu[0][pos] = s.ax * _gPerLsb;
      _imu[1][pos] = s.ay * _gPerLsb;
      _imu[2][pos] = s.az * _gPerLsb;
      _imu[3][pos] = s.gx * _dpsPerLsb;
      _imu[4][pos] = s.gy * _dpsPerLsb;
      _imu[5][pos] = s.gz * _dpsPerLsb;
      if (fresh) {
        _imuReceived++;
        if (idx <= _latestImu) {
          if (_imuLostLink > 0) {
            _imuLostLink--;
          } else {
            _imuLostDevice--;
          }
        }
      }
    }
    _latestImu = math.max(_latestImu, start + n - 1);
    _linkPendingImu = 0;
  }

  // ── reading ─────────────────────────────────────────────────────────────────

  /// The newest `seconds` (at most [maxWindowSec]) of every signal, copied so a
  /// graph can keep it (pause) while new data keeps arriving.
  LiveSnapshot snapshot({double seconds = 10}) {
    if (_latestEeg < 0) {
      return LiveSnapshot(
        startIdx: 0,
        endIdx: -1,
        eegRateHz: _eegRate,
        imuRateHz: _imuRate,
        eeg: [for (var c = 0; c < _channels; c++) Float32List(0)],
        accelX: Float32List(0),
        accelY: Float32List(0),
        accelZ: Float32List(0),
        gyroX: Float32List(0),
        gyroY: Float32List(0),
        gyroZ: Float32List(0),
      );
    }
    final secs = seconds.clamp(0.1, maxWindowSec.toDouble());
    final n = (secs * _eegRate).round();
    final endIdx = _latestEeg;
    final startIdx = endIdx - n + 1;

    final eeg = <Float32List>[];
    for (var c = 0; c < _channels; c++) {
      final out = Float32List(n);
      for (var i = 0; i < n; i++) {
        final idx = startIdx + i;
        out[i] = idx < 0 ? double.nan : _eeg[c][idx % _eegCap];
      }
      eeg.add(out);
    }

    // The same time span on the IMU clock, aligned on the window's left edge.
    final nImu = (secs * _imuRate).round();
    final startImu = (startIdx * _imuRate / _eegRate).round();
    Float32List imu(int axis) {
      final out = Float32List(nImu);
      for (var i = 0; i < nImu; i++) {
        final idx = startImu + i;
        out[i] = (idx < 0 || idx > _latestImu) ? double.nan : _imu[axis][idx % _imuCap];
      }
      return out;
    }

    return LiveSnapshot(
      startIdx: startIdx,
      endIdx: endIdx,
      eegRateHz: _eegRate,
      imuRateHz: _imuRate,
      eeg: eeg,
      accelX: imu(0),
      accelY: imu(1),
      accelZ: imu(2),
      gyroX: imu(3),
      gyroY: imu(4),
      gyroZ: imu(5),
    );
  }
}
