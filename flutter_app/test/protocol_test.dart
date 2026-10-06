import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/protocol/neo_messages.dart';
import 'package:neo_companion/protocol/neo_proto.dart';

// vectors.json is copied from neuravance/software/protocol/test_vectors; the
// spec requires every implementation to reproduce these byte for byte.
Uint8List _hex(String h) => Uint8List.fromList(List.generate(h.length ~/ 2, (i) => int.parse(h.substring(2 * i, 2 * i + 2), radix: 16)));

void main() {
  final doc = jsonDecode(File('test/vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final vectors = {for (final v in (doc['vectors'] as List)) v['name'] as String: v as Map<String, dynamic>};

  test('crc16 check value', () {
    final c = doc['crc_check'] as Map<String, dynamic>;
    expect(NeoProto.crc16(Uint8List.fromList(utf8.encode(c['input'] as String))), c['crc16']);
  });

  test('every vector parses with the right header fields', () {
    for (final v in vectors.values) {
      final pkt = NeoProto.parsePacket(_hex(v['packet'] as String));
      expect(pkt, isNotNull, reason: v['name'] as String);
      expect(pkt!.type, int.parse(v['type'].toString()));
      expect(pkt.module, int.parse(v['module'].toString()));
      expect(pkt.seq, int.parse(v['seq'].toString()));
      expect(pkt.sampleIdx, int.parse(v['sample_idx'].toString()));
      expect(pkt.tUs, int.parse(v['t_us'].toString()));
      expect(pkt.payload, _hex(v['payload'] as String));
    }
  });

  test('corrupted packets are rejected', () {
    final good = _hex(vectors['status']!['packet'] as String);
    final badCrc = Uint8List.fromList(good)..[30] ^= 0xFF;
    final badMagic = Uint8List.fromList(good)..[0] = 0;
    final badVer = Uint8List.fromList(good)..[2] = 1;
    expect(NeoProto.parsePacket(badCrc), isNull);
    expect(NeoProto.parsePacket(badMagic), isNull);
    expect(NeoProto.parsePacket(badVer), isNull);
    expect(NeoProto.parsePacket(good.sublist(0, 10)), isNull);
  });

  test('buildCommandFrame reproduces the command vectors', () {
    expect(
      NeoProto.buildCommandFrame(cmdId: NeoProto.cmdPing, params: Uint8List(0), seq: 1),
      _hex(vectors['cmd_ping']!['framed'] as String),
    );
    expect(
      NeoProto.buildCommandFrame(cmdId: NeoProto.cmdStart, params: _hex('881307'), seq: 2),
      _hex(vectors['cmd_start']!['framed'] as String),
    );
  });

  test('HELLO decodes', () {
    final h = NeoHello.decode(NeoProto.parsePacket(_hex(vectors['hello']!['packet'] as String))!.payload)!;
    expect(h.protoMajor, 0);
    expect(h.role, 0);
    expect(h.ctrlPort, 5001);
    expect(h.serial, 'A0B1C2D3E4F5');
    expect(h.name, 'neo-A');
    expect(NeoHello.decode(Uint8List(32)), isNull); // too short
  });

  test('ACK + INFO decode', () {
    final ack = NeoReply.decode(NeoProto.parsePacket(_hex(vectors['ack_info']!['packet'] as String))!.payload)!;
    expect(ack.ok, isTrue);
    final info = NeoInfo.decode(ack.data)!;
    expect(info.eegRateHz, 250);
    expect(info.eegChannels, 2);
    expect(info.eegFormat, 1);
    expect(info.uvPerCount[0], closeTo(0.04808108, 1e-6));
    expect(info.name, 'neo-A');

    final nack = NeoReply.decode(NeoProto.parsePacket(_hex(vectors['nack_gain_busy']!['packet'] as String))!.payload)!;
    expect(nack.ok, isFalse);
    expect(nack.status, 3);
    expect(nack.cmdSeq, 3);
  });

  group('deframer', () {
    final a = _hex(vectors['ack_ping']!['framed'] as String);
    final b = _hex(vectors['status']!['framed'] as String);

    test('splits merged frames', () {
      final d = NeoDeframer();
      final out = d.feed(Uint8List.fromList([...a, ...b]));
      expect(out.map((p) => p.type), [NeoProto.typeAck, NeoProto.typeStatus]);
    });

    test('reassembles a frame split across chunks', () {
      final d = NeoDeframer();
      expect(d.feed(a.sublist(0, 7)), isEmpty);
      final out = d.feed(a.sublist(7));
      expect(out.length, 1);
      expect(out.first.type, NeoProto.typeAck);
    });

    test('resyncs past garbage', () {
      final d = NeoDeframer();
      final out = d.feed(Uint8List.fromList([0x01, 0x02, 0x03, ...a]));
      expect(out.length, 1);
      expect(d.dropped, greaterThan(0));
    });
  });
}
