import 'dart:typed_data';

/// Neo Protocol v0 Constants & Packet Definitions
class NeoProto {
  static const int magic0 = 0x4E; // 'N'
  static const int magic1 = 0x56; // 'V'
  static const int version = 0;

  static const int hdrSize = 22;
  static const int minPktSize = 24; // 22 hdr + 2 crc
  static const int maxPktSize = 1400;

  // Packet Types
  static const int typeEeg = 0x01;
  static const int typeImu = 0x03;
  static const int typeStatus = 0x10;
  static const int typeEvent = 0x11;
  static const int typeLog = 0x14;
  static const int typeCmd = 0x20;
  static const int typeAck = 0x21;
  static const int typeNack = 0x22;
  static const int typeHello = 0xFE;
  static const int typeError = 0xFF;

  // Commands
  static const int cmdPing = 0x00;
  static const int cmdGetInfo = 0x01;
  static const int cmdGetStatus = 0x02;
  static const int cmdStart = 0x10;
  static const int cmdStop = 0x11;
  static const int cmdSetGain = 0x14;
  static const int cmdSetTransport = 0x50;

  // Module Roles
  static const int roleA = 0;
  static const int roleB = 1;
  static const int roleUnset = 0xFE;
  static const int roleHost = 0xFF;

  /// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, check "123456789" -> 0x29B1)
  static int crc16(Uint8List data, [int offset = 0, int length = -1]) {
    int crc = 0xFFFF;
    final end = (length < 0) ? data.length : offset + length;
    for (int i = offset; i < end; i++) {
      crc ^= (data[i] << 8) & 0xFFFF;
      for (int bit = 0; bit < 8; bit++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }
    return crc;
  }

  /// Builds a command frame [len u16 LE][hdr 22 bytes][payload][crc16 LE]
  static Uint8List buildCommandFrame({
    required int cmdId,
    required Uint8List params,
    int seq = 1,
  }) {
    final payloadLen = 1 + params.length; // 1 byte cmdId + params
    final pktLen = hdrSize + payloadLen + 2; // + 2 for crc16
    final totalLen = 2 + pktLen; // + 2 for stream framing len

    final buf = Uint8List(totalLen);
    final bd = ByteData.sublistView(buf);

    // Stream Framing Length
    bd.setUint16(0, pktLen, Endian.little);

    // 22-byte Header
    buf[2] = magic0;
    buf[3] = magic1;
    buf[4] = version;
    buf[5] = typeCmd;
    buf[6] = roleHost;
    buf[7] = 0; // flags
    bd.setUint32(8, seq, Endian.little);
    bd.setUint32(12, 0, Endian.little); // sample_idx = 0 for host
    bd.setUint64(16, 0, Endian.little); // t_us = 0 for host

    // Payload
    buf[24] = cmdId;
    if (params.isNotEmpty) {
      buf.setRange(25, 25 + params.length, params);
    }

    // CRC16 over Header + Payload (bytes 2 to 24 + payloadLen)
    final crc = crc16(buf, 2, hdrSize + payloadLen);
    bd.setUint16(2 + hdrSize + payloadLen, crc, Endian.little);

    return buf;
  }
}

/// Parsed EEG Sample
class EegSample {
  final int sampleIdx;
  final int loff;
  final double ch1Uv;
  final double ch2Uv;
  final double ch3Uv;
  final double ch4Uv;

  EegSample({
    required this.sampleIdx,
    required this.loff,
    required this.ch1Uv,
    required this.ch2Uv,
    this.ch3Uv = 0.0,
    this.ch4Uv = 0.0,
  });
}
