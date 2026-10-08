import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/live/signal_loss.dart';
import 'package:neo_companion/protocol/neo_messages.dart';
import 'package:neo_companion/protocol/neo_proto.dart';

void main() {
  group('SeqTracker', () {
    test('contiguous packets lose nothing', () {
      final t = SeqTracker();
      for (var s = 0; s < 5; s++) {
        expect(t.update(s), 0);
      }
      expect(t.lost, 0);
      expect(t.received, 5);
    });

    test('a gap is counted and reported for the packet after it', () {
      final t = SeqTracker();
      t.update(0);
      t.update(1);
      expect(t.update(5), 3); // 2, 3, 4 missing
      expect(t.lost, 3);
      expect(t.update(6), 0);
    });

    test('the first packet is never a loss, wherever the stream starts', () {
      final t = SeqTracker();
      expect(t.update(1000), 0);
      expect(t.lost, 0);
    });

    test('seq wraps at 2^32 without a false loss', () {
      final t = SeqTracker();
      t.update(0xFFFFFFFE);
      expect(t.update(0xFFFFFFFF), 0);
      expect(t.update(0), 0);
      expect(t.update(2), 1);
      expect(t.lost, 1);
    });

    test('a late or repeated packet is not a loss and does not move the position back', () {
      final t = SeqTracker();
      t.update(0);
      t.update(5); // 4 lost
      expect(t.update(3), 0); // late
      expect(t.update(5), 0); // duplicate
      expect(t.update(6), 0); // continues from 5, not from 3
      expect(t.lost, 4);
    });

    test('reset forgets the position', () {
      final t = SeqTracker();
      t.update(0);
      t.update(9);
      t.reset();
      expect(t.lost, 0);
      expect(t.update(0), 0);
    });
  });

  group('NeoHeader', () {
    test('carries the link gap from the packet', () {
      final p = NeoPacket(
          type: 1, module: 0, seq: 7, sampleIdx: 0, tUs: 0, payload: Uint8List(0));
      p.linkGap = 3;
      expect(NeoHeader.of(p).linkGap, 3);
      expect(const NeoHeader().linkGap, 0);
    });
  });

  group('SignalLoss percentages', () {
    test('are null, not 0, before anything was expected', () {
      const l = SignalLoss();
      expect(l.eegLinkLossPercent, isNull);
      expect(l.eegDeviceLossPercent, isNull);
      expect(l.eegTotalLossPercent, isNull);
      expect(l.packetLinkLossPercent, isNull);
      expect(l.deviceReportedEegOverruns, isNull);
    });

    test('split by cause and sum to the total', () {
      const l = SignalLoss(eegReceived: 900, eegLostLink: 60, eegLostDevice: 40);
      expect(l.eegExpected, 1000);
      expect(l.eegLinkLossPercent, closeTo(6.0, 1e-9));
      expect(l.eegDeviceLossPercent, closeTo(4.0, 1e-9));
      expect(l.eegTotalLossPercent, closeTo(10.0, 1e-9));
    });

    test('packet loss comes from seq alone', () {
      const l = SignalLoss(linkPacketsReceived: 95, linkPacketsLost: 5);
      expect(l.packetLinkLossPercent, closeTo(5.0, 1e-9));
    });
  });
}