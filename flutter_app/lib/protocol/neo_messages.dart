import 'dart:convert';
import 'dart:typed_data';

import 'neo_proto.dart';

// Typed decoders for every device→host packet in the Neo protocol v0
// (README §4–§6). Pure functions: validated bytes in, immutable objects out.
//
// Spec rules honoured here:
//  - a payload shorter than the documented size is rejected (null); a longer
//    one is accepted and the extra bytes ignored (minor versions append fields)
//  - unknown or reserved packet types (e.g. pod streams 0x05–0x0A) decode to null
//  - strings are NUL-padded UTF-8

String _cstr(Uint8List b) => utf8.decode(b.takeWhile((c) => c != 0).toList(), allowMalformed: true);

String _text(Uint8List b) => utf8.decode(b, allowMalformed: true);

/// Header fields every packet carries (README §2).
class NeoHeader {
  final int module;
  final int seq;
  final int sampleIdx;
  final int tUs;

  const NeoHeader({this.module = 0, this.seq = 0, this.sampleIdx = 0, this.tUs = 0});

  static const NeoHeader empty = NeoHeader();

  factory NeoHeader.of(NeoPacket p) =>
      NeoHeader(module: p.module, seq: p.seq, sampleIdx: p.sampleIdx, tUs: p.tUs);
}

/// A decoded packet. One subclass per packet type.
sealed class NeoMessage {
  final NeoHeader header;
  const NeoMessage(this.header);
}

// ── EEG (0x01) ────────────────────────────────────────────────────────────────

class NeoEegSample {
  /// ADS1292R LOFF_STAT[4:0]: bit 0 IN1P_OFF, 1 IN1N_OFF, 2 IN2P_OFF, 3 IN2N_OFF, 4 RLD_STAT.
  final int loff;

  /// Raw ADC counts, one per channel (multiply by INFO `uvPerCount`).
  final List<int> counts;

  const NeoEegSample(this.loff, this.counts);

  /// Any electrode reports lead-off.
  bool get leadOff => (loff & 0x0F) != 0;
  bool get rldFault => (loff & 0x10) != 0;
}

class NeoEegPacket extends NeoMessage {
  final int channels;
  final int format;
  final List<NeoEegSample> samples;

  const NeoEegPacket(super.header, this.channels, this.format, this.samples);

  /// Sample k in this packet has index `header.sampleIdx + k` (§3).
  int indexOf(int k) => header.sampleIdx + k;

  static const int supportedFormat = 1; // ADS1292R: loff u8 + n_ch × i32
  static const int maxChannels = 4;

  static NeoEegPacket? decode(Uint8List p, [NeoHeader header = NeoHeader.empty]) {
    if (p.length < 4) return null;
    final nSamples = p[0];
    final nCh = p[1];
    final format = p[2];
    if (format != supportedFormat || nCh < 1 || nCh > maxChannels) return null;
    final record = 1 + nCh * 4;
    if (p.length < 4 + nSamples * record) return null; // never partially parsed

    final bd = ByteData.sublistView(p);
    final samples = <NeoEegSample>[];
    var off = 4;
    for (var i = 0; i < nSamples; i++) {
      final loff = p[off];
      off += 1;
      final counts = List<int>.generate(nCh, (c) => bd.getInt32(off + c * 4, Endian.little), growable: false);
      off += nCh * 4;
      samples.add(NeoEegSample(loff, counts));
    }
    return NeoEegPacket(header, nCh, format, samples);
  }
}

// ── IMU (0x03) ────────────────────────────────────────────────────────────────

class NeoImuSample {
  final int ax, ay, az, gx, gy, gz; // raw ICM-42670 counts (scale from INFO)
  const NeoImuSample(this.ax, this.ay, this.az, this.gx, this.gy, this.gz);
}

class NeoImuPacket extends NeoMessage {
  final List<NeoImuSample> samples;
  const NeoImuPacket(super.header, this.samples);

  static NeoImuPacket? decode(Uint8List p, [NeoHeader header = NeoHeader.empty]) {
    if (p.length < 2) return null;
    final n = p[0];
    if (p.length < 2 + n * 12) return null;
    final bd = ByteData.sublistView(p);
    final samples = <NeoImuSample>[];
    for (var i = 0; i < n; i++) {
      final o = 2 + i * 12;
      samples.add(NeoImuSample(
        bd.getInt16(o, Endian.little),
        bd.getInt16(o + 2, Endian.little),
        bd.getInt16(o + 4, Endian.little),
        bd.getInt16(o + 6, Endian.little),
        bd.getInt16(o + 8, Endian.little),
        bd.getInt16(o + 10, Endian.little),
      ));
    }
    return NeoImuPacket(header, samples);
  }
}

// ── STATUS (0x10, also the ACK data of GET_STATUS) ────────────────────────────

enum NeoDeviceState { boot, idle, streaming, recording, error, provision }

class NeoStatus extends NeoMessage {
  final int stateCode;
  final int flags;
  final int batteryPct;
  final int batteryMv;
  final int rssiDbm; // 0 when not on Wi-Fi
  final int pktsSent;
  final int pktsDropped; // dropped on the device (TX queue full)
  final int eegOverruns; // EEG samples lost before packing
  final int podPresent;

  const NeoStatus(super.header, this.stateCode, this.flags, this.batteryPct, this.batteryMv, this.rssiDbm,
      this.pktsSent, this.pktsDropped, this.eegOverruns, this.podPresent);

  NeoDeviceState? get state =>
      stateCode >= 0 && stateCode < NeoDeviceState.values.length ? NeoDeviceState.values[stateCode] : null;

  bool get usbConnected => (flags & 0x01) != 0;
  bool get charging => (flags & 0x02) != 0;
  bool get wifiConnected => (flags & 0x04) != 0;
  bool get sdPresent => (flags & 0x08) != 0;
  bool get sdRecording => (flags & 0x10) != 0;
  bool get streaming => (flags & 0x20) != 0;
  bool get errorFlag => (flags & 0x40) != 0;
  bool get imuOn => (flags & 0x80) != 0;

  static const int size = 19;

  static NeoStatus? decode(Uint8List p, [NeoHeader header = NeoHeader.empty]) {
    if (p.length < size) return null;
    final bd = ByteData.sublistView(p);
    return NeoStatus(
      header,
      p[0],
      p[1],
      p[2],
      bd.getUint16(3, Endian.little),
      bd.getInt8(5),
      bd.getUint32(6, Endian.little),
      bd.getUint32(10, Endian.little),
      bd.getUint32(14, Endian.little),
      p[18],
    );
  }
}

// ── EVENT (0x11) ──────────────────────────────────────────────────────────────

enum NeoEventKind {
  marker(0x01),
  button(0x02),
  syncRestart(0x03),
  streamStarted(0x04),
  streamStopped(0x05),
  lowBattery(0x06),
  stateChange(0x07);

  final int id;
  const NeoEventKind(this.id);

  static NeoEventKind? fromId(int id) {
    for (final k in values) {
      if (k.id == id) return k;
    }
    return null;
  }
}

class NeoEvent extends NeoMessage {
  final int eventId;
  final int arg;
  final Uint8List data;

  const NeoEvent(super.header, this.eventId, this.arg, this.data);

  /// Null for an event id this version does not know.
  NeoEventKind? get kind => NeoEventKind.fromId(eventId);

  /// BUTTON with arg 1 is a long press.
  bool get isLongPress => kind == NeoEventKind.button && arg == 1;

  static NeoEvent? decode(Uint8List p, [NeoHeader header = NeoHeader.empty]) {
    if (p.length < 2) return null;
    return NeoEvent(header, p[0], p[1], Uint8List.sublistView(p, 2));
  }
}

// ── LOG (0x14) and ERROR (0xFF) ───────────────────────────────────────────────

enum NeoLogLevel { error, warn, info, debug }

class NeoLog extends NeoMessage {
  final int levelCode;
  final String text;
  const NeoLog(super.header, this.levelCode, this.text);

  NeoLogLevel? get level =>
      levelCode >= 0 && levelCode < NeoLogLevel.values.length ? NeoLogLevel.values[levelCode] : null;

  static NeoLog? decode(Uint8List p, [NeoHeader header = NeoHeader.empty]) {
    if (p.isEmpty) return null;
    return NeoLog(header, p[0], _text(Uint8List.sublistView(p, 1)));
  }
}

enum NeoErrorCode {
  adcInitFailed(0x01),
  adcTimeout(0x02),
  bufferOverflow(0x03),
  sdMountFailed(0x04),
  sdWriteFailed(0x05),
  sdFull(0x06),
  wifiDisconnected(0x07),
  lowBattery(0x08),
  invalidCommand(0x0A),
  crcMismatch(0x0B);

  final int code;
  const NeoErrorCode(this.code);

  static NeoErrorCode? fromCode(int code) {
    for (final e in values) {
      if (e.code == code) return e;
    }
    return null;
  }
}

class NeoError extends NeoMessage {
  final int codeValue;
  final bool fatal;
  final String text;
  const NeoError(super.header, this.codeValue, this.fatal, this.text);

  NeoErrorCode? get code => NeoErrorCode.fromCode(codeValue);

  static NeoError? decode(Uint8List p, [NeoHeader header = NeoHeader.empty]) {
    if (p.length < 2) return null;
    return NeoError(header, p[0], p[1] != 0, _text(Uint8List.sublistView(p, 2)));
  }
}

// ── ACK (0x21) / NACK (0x22) ──────────────────────────────────────────────────

/// `cmd_id u8 | status u8 | cmd_seq u32 | data[...]` (§5.7).
class NeoReply extends NeoMessage {
  final int cmdId;
  final int status;
  final int cmdSeq;
  final Uint8List data;

  const NeoReply(this.cmdId, this.status, this.cmdSeq, this.data, [super.header = NeoHeader.empty]);

  bool get ok => status == 0;

  static NeoReply? decode(Uint8List p, [NeoHeader header = NeoHeader.empty]) {
    if (p.length < 6) return null;
    final bd = ByteData.sublistView(p);
    return NeoReply(p[0], p[1], bd.getUint32(2, Endian.little), Uint8List.sublistView(p, 6), header);
  }
}

// ── HELLO (0xFE) ──────────────────────────────────────────────────────────────

class NeoHello extends NeoMessage {
  final int protoMajor;
  final int protoMinor;
  final int role;
  final int ctrlPort;
  final String serial;
  final String name;

  const NeoHello(this.protoMajor, this.protoMinor, this.role, this.ctrlPort, this.serial, this.name,
      [super.header = NeoHeader.empty]);

  static const int size = 33;

  static NeoHello? decode(Uint8List p, [NeoHeader header = NeoHeader.empty]) {
    if (p.length < size) return null;
    final bd = ByteData.sublistView(p);
    return NeoHello(
      p[0],
      p[1],
      p[2],
      bd.getUint16(3, Endian.little),
      _cstr(Uint8List.sublistView(p, 5, 17)),
      _cstr(Uint8List.sublistView(p, 17, 33)),
      header,
    );
  }
}

// ── INFO (ACK data of GET_INFO, §6.2) ─────────────────────────────────────────

/// Not a packet of its own: it travels inside the ACK to GET_INFO.
class NeoInfo {
  final int protoMajor;
  final int protoMinor;
  final int fwMajor, fwMinor, fwPatch;
  final int hwRev;
  final String serial;
  final String name;
  final int role;
  final int features;
  final int eegRateHz;
  final int eegChannels;
  final int eegFormat;
  final List<int> eegGain;
  final int eegVrefUv;
  final List<double> uvPerCount;
  final int imuRateHz;
  final double imuGPerLsb;
  final double imuDpsPerLsb;
  final int podPresent;

  const NeoInfo({
    required this.protoMajor,
    required this.protoMinor,
    required this.fwMajor,
    required this.fwMinor,
    required this.fwPatch,
    required this.hwRev,
    required this.serial,
    required this.name,
    required this.role,
    required this.features,
    required this.eegRateHz,
    required this.eegChannels,
    required this.eegFormat,
    required this.eegGain,
    required this.eegVrefUv,
    required this.uvPerCount,
    required this.imuRateHz,
    required this.imuGPerLsb,
    required this.imuDpsPerLsb,
    required this.podPresent,
  });

  bool get hasImu => (features & 0x01) != 0;
  bool get hasSd => (features & 0x02) != 0;
  bool get hasPod => (features & 0x04) != 0;
  bool get hasWifi => (features & 0x08) != 0;
  bool get hasUsb => (features & 0x10) != 0;

  String get firmware => '$fwMajor.$fwMinor.$fwPatch';

  static const int size = 69;

  static NeoInfo? decode(Uint8List p) {
    if (p.length < size) return null;
    final bd = ByteData.sublistView(p);
    return NeoInfo(
      protoMajor: p[0],
      protoMinor: p[1],
      fwMajor: p[2],
      fwMinor: p[3],
      fwPatch: p[4],
      hwRev: bd.getUint16(5, Endian.little),
      serial: _cstr(Uint8List.sublistView(p, 7, 19)),
      name: _cstr(Uint8List.sublistView(p, 19, 35)),
      role: p[35],
      features: bd.getUint32(36, Endian.little),
      eegRateHz: bd.getUint16(40, Endian.little),
      eegChannels: p[42],
      eegFormat: p[43],
      eegGain: [p[44], p[45]],
      eegVrefUv: bd.getUint32(46, Endian.little),
      uvPerCount: [bd.getFloat32(50, Endian.little), bd.getFloat32(54, Endian.little)],
      imuRateHz: bd.getUint16(58, Endian.little),
      imuGPerLsb: bd.getFloat32(60, Endian.little),
      imuDpsPerLsb: bd.getFloat32(64, Endian.little),
      podPresent: p[68],
    );
  }
}

// ── Dispatcher ────────────────────────────────────────────────────────────────

class NeoDecoder {
  /// Decode a validated packet. Returns null for unknown or reserved types
  /// (pod streams 0x05–0x0A, host CMD) and for payloads that are too short.
  static NeoMessage? decode(NeoPacket p) {
    final h = NeoHeader.of(p);
    switch (p.type) {
      case NeoProto.typeEeg:
        return NeoEegPacket.decode(p.payload, h);
      case NeoProto.typeImu:
        return NeoImuPacket.decode(p.payload, h);
      case NeoProto.typeStatus:
        return NeoStatus.decode(p.payload, h);
      case NeoProto.typeEvent:
        return NeoEvent.decode(p.payload, h);
      case NeoProto.typeLog:
        return NeoLog.decode(p.payload, h);
      case NeoProto.typeAck:
      case NeoProto.typeNack:
        return NeoReply.decode(p.payload, h);
      case NeoProto.typeHello:
        return NeoHello.decode(p.payload, h);
      case NeoProto.typeError:
        return NeoError.decode(p.payload, h);
      default:
        return null;
    }
  }
}
