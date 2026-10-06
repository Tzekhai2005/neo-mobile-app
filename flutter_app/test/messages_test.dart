import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/protocol/neo_messages.dart';
import 'package:neo_companion/protocol/neo_proto.dart';

Uint8List _hex(String h) =>
    Uint8List.fromList(List.generate(h.length ~/ 2, (i) => int.parse(h.substring(2 * i, 2 * i + 2), radix: 16)));

void main() {
  final doc = jsonDecode(File('test/vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final vectors = {for (final v in (doc['vectors'] as List)) v['name'] as String: v as Map<String, dynamic>};

  NeoMessage? decodeVector(String name) {
    final pkt = NeoProto.parsePacket(_hex(vectors[name]!['packet'] as String));
    expect(pkt, isNotNull, reason: name);
    return NeoDecoder.decode(pkt!);
  }

  Map<String, dynamic> fieldsOf(String name) => vectors[name]!['fields'] as Map<String, dynamic>;

  group('spec vectors', () {
    test('EEG', () {
      final m = decodeVector('eeg_10') as NeoEegPacket;
      final f = fieldsOf('eeg_10');
      expect(m.samples.length, f['n_samples']);
      expect(m.channels, f['n_ch']);
      expect(m.header.sampleIdx, 250);
      expect(m.header.seq, 42);
      final loff = (f['loff'] as List).cast<int>();
      final ch = (f['ch'] as List).map((r) => (r as List).cast<int>()).toList();
      for (var i = 0; i < m.samples.length; i++) {
        expect(m.samples[i].loff, loff[i], reason: 'loff[$i]');
        expect(m.samples[i].counts, ch[i], reason: 'ch[$i]');
      }
      expect(m.samples[2].leadOff, isTrue); // loff 3 = IN1P + IN1N off
      expect(m.samples[0].leadOff, isFalse);
      expect(m.samples[9].rldFault, isTrue); // loff 31 includes RLD
      expect(m.indexOf(3), 253);
    });

    test('IMU', () {
      final m = decodeVector('imu_10') as NeoImuPacket;
      final want = (fieldsOf('imu_10')['samples'] as List).map((r) => (r as List).cast<int>()).toList();
      expect(m.samples.length, want.length);
      for (var i = 0; i < want.length; i++) {
        final s = m.samples[i];
        expect([s.ax, s.ay, s.az, s.gx, s.gy, s.gz], want[i], reason: 'imu[$i]');
      }
    });

    test('STATUS', () {
      final m = decodeVector('status') as NeoStatus;
      final f = fieldsOf('status');
      expect(m.stateCode, f['state']);
      expect(m.state, NeoDeviceState.streaming);
      expect(m.flags, f['flags']);
      expect(m.batteryPct, f['battery_pct']);
      expect(m.batteryMv, f['battery_mv']);
      expect(m.rssiDbm, f['rssi_dbm']); // signed: -52
      expect(m.pktsSent, f['pkts_sent']);
      expect(m.pktsDropped, f['pkts_dropped']);
      expect(m.eegOverruns, f['eeg_overruns']);
      expect(m.podPresent, f['pod_present']);
      // flags 164 = 0b10100100: wifi, streaming, imu
      expect([m.usbConnected, m.charging, m.wifiConnected, m.sdPresent, m.sdRecording, m.streaming, m.errorFlag, m.imuOn],
          [false, false, true, false, false, true, false, true]);
    });

    test('EVENT', () {
      final m = decodeVector('event_marker') as NeoEvent;
      expect(m.eventId, fieldsOf('event_marker')['event_id']);
      expect(m.arg, fieldsOf('event_marker')['arg']);
      expect(m.kind, NeoEventKind.marker);
      expect(m.header.sampleIdx, 777);
    });

    test('LOG', () {
      final m = decodeVector('log') as NeoLog;
      expect(m.levelCode, fieldsOf('log')['level']);
      expect(m.level, NeoLogLevel.info);
      expect(m.text, fieldsOf('log')['text']);
    });

    test('HELLO', () {
      final m = decodeVector('hello') as NeoHello;
      expect(m.serial, 'A0B1C2D3E4F5');
      expect(m.name, 'neo-A');
      expect(m.ctrlPort, 5001);
      expect(m.protoMajor, 0);
      expect(m.protoMinor, 1);
    });

    test('ACK carrying INFO', () {
      final r = decodeVector('ack_info') as NeoReply;
      expect(r.ok, isTrue);
      final i = NeoInfo.decode(r.data)!;
      final f = fieldsOf('ack_info');
      expect(i.serial, f['serial']);
      expect(i.name, f['name']);
      expect(i.eegRateHz, f['eeg_rate_hz']);
      expect(i.eegGain, (f['eeg_gain'] as List).cast<int>());
      expect(i.uvPerCount[0], closeTo((f['eeg_uv_per_count'] as List)[0] as double, 1e-7));
      expect(i.eegChannels, 2);
      expect(i.eegFormat, 1);
      expect(i.firmware, '0.1.0');
      expect(i.hwRev, 0x0100);
      expect(i.eegVrefUv, 2420000);
      expect(i.imuRateHz, 100);
      expect(i.imuGPerLsb, closeTo(0.00048828125, 1e-9));
      expect(i.imuDpsPerLsb, closeTo(0.0609756, 1e-6));
      expect(i.features, 31);
      expect([i.hasImu, i.hasSd, i.hasPod, i.hasWifi, i.hasUsb], everyElement(isTrue));
    });

    test('NACK', () {
      final r = decodeVector('nack_gain_busy') as NeoReply;
      expect(r.ok, isFalse);
      expect(r.status, 3);
      expect(r.cmdSeq, 3);
      expect(r.cmdId, 0x14);
    });

    test('host CMD packets are not device messages', () {
      expect(decodeVector('cmd_ping'), isNull);
      expect(decodeVector('cmd_start'), isNull);
    });
  });

  group('rules from the spec', () {
    test('reserved pod types and unknown types decode to null', () {
      for (final t in [0x05, 0x06, 0x0A, 0x7E]) {
        final pkt = NeoPacket(type: t, module: 0, seq: 0, sampleIdx: 0, tUs: 0, payload: Uint8List(8));
        expect(NeoDecoder.decode(pkt), isNull, reason: 'type $t');
      }
    });

    test('too-short payloads are rejected, longer ones accepted', () {
      final status = _hex('02a4570d10ccd2040000020000000000000015');
      expect(NeoStatus.decode(status), isNotNull);
      expect(NeoStatus.decode(status.sublist(0, 18)), isNull);
      expect(NeoStatus.decode(Uint8List.fromList([...status, 1, 2, 3])), isNotNull); // appended fields

      expect(NeoEvent.decode(Uint8List.fromList([1])), isNull);
      expect(NeoLog.decode(Uint8List(0)), isNull);
      expect(NeoError.decode(Uint8List.fromList([1])), isNull);
      expect(NeoImuPacket.decode(Uint8List.fromList([10, 0, 1, 2])), isNull); // claims 10 samples
      expect(NeoInfo.decode(Uint8List(68)), isNull);
    });

    test('ERROR decodes code, fatal flag and text', () {
      final e = NeoError.decode(Uint8List.fromList([0x07, 1, ...utf8.encode('wifi gone')]))!;
      expect(e.codeValue, 0x07);
      expect(e.code, NeoErrorCode.wifiDisconnected);
      expect(e.fatal, isTrue);
      expect(e.text, 'wifi gone');
      expect(NeoError.decode(Uint8List.fromList([0x7F, 0]))!.code, isNull); // unknown code kept, not dropped
    });

    test('EVENT button long press and unknown event id', () {
      expect(NeoEvent.decode(Uint8List.fromList([0x02, 1]))!.isLongPress, isTrue);
      expect(NeoEvent.decode(Uint8List.fromList([0x02, 0]))!.isLongPress, isFalse);
      final unknown = NeoEvent.decode(Uint8List.fromList([0x55, 0, 9]))!;
      expect(unknown.kind, isNull);
      expect(unknown.data, [9]);
    });
  });

  group('EEG channel counts', () {
    Uint8List eeg(int nSamples, int nCh, {int format = 1}) {
      final b = BytesBuilder();
      b.add([nSamples, nCh, format, 0]);
      for (var s = 0; s < nSamples; s++) {
        b.addByte(0);
        for (var c = 0; c < nCh; c++) {
          final v = ByteData(4)..setInt32(0, (s + 1) * 100 + c, Endian.little);
          b.add(v.buffer.asUint8List());
        }
      }
      return b.toBytes();
    }

    for (final n in [1, 2, 3, 4]) {
      test('$n channels decode without invented channels', () {
        final m = NeoEegPacket.decode(eeg(3, n))!;
        expect(m.channels, n);
        for (var s = 0; s < 3; s++) {
          expect(m.samples[s].counts.length, n);
          expect(m.samples[s].counts, List.generate(n, (c) => (s + 1) * 100 + c));
        }
      });
    }

    test('0 or 5 channels, unknown format and truncation are rejected', () {
      expect(NeoEegPacket.decode(eeg(2, 0)), isNull);
      expect(NeoEegPacket.decode(eeg(2, 5)), isNull);
      expect(NeoEegPacket.decode(eeg(2, 2, format: 2)), isNull);
      final whole = eeg(4, 2);
      expect(NeoEegPacket.decode(whole.sublist(0, whole.length - 1)), isNull);
      expect(NeoEegPacket.decode(Uint8List.fromList([...whole, 0xAA, 0xBB])), isNotNull); // trailing bytes ignored
    });

    test('negative 24-bit counts sign-extend', () {
      final m = NeoEegPacket.decode(_hex('01020100' '00' '78ecffff' '00000000'))!;
      expect(m.samples.first.counts, [-5000, 0]);
    });
  });
}
