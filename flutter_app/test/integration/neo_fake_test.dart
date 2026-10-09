// End-to-end check of NeoClient against a real `neo-fake` process (loopback).
// Needs `neo-fake` on PATH (pip package neoproto) and UDP 5000 / TCP 5001 free.
// Not part of CI. Run the integration tests ONE AT A TIME (they share the ports):
//   flutter test --concurrency=1 test/integration
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/protocol/neo_client.dart';
import 'package:neo_companion/protocol/neo_messages.dart';

Future<bool> _until(bool Function() cond, Duration limit) async {
  final end = DateTime.now().add(limit);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return cond();
}

void main() {
  final exe = Platform.environment['NEO_FAKE'] ?? 'neo-fake';
  final available = Process.runSync('which', [exe]).exitCode == 0;

  test('discover, handshake, stream, stall flag, 3 s drop, reconnect', () async {
    final fake = await Process.start(exe, ['--name', 'neo-test']);
    fake.stdout.drain<void>();
    fake.stderr.drain<void>();
    final client = NeoClient();
    final samples = <({int idx, int channels})>[]; // one entry per EEG sample, from the packets
    final stallChanges = <bool>[];
    StreamSubscription<NeoDeviceInfo>? autoConnect;
    try {
      client.messages.listen((m) {
        if (m is NeoEegPacket) {
          for (var i = 0; i < m.samples.length; i++) {
            samples.add((idx: m.indexOf(i), channels: m.channels));
          }
        }
      });
      client.onDataStalledChanged.listen(stallChanges.add);
      await client.startDiscovery();

      // 1. discovery + handshake
      final dev = await client.onDeviceDiscovered.first.timeout(const Duration(seconds: 6));
      expect(dev.name, 'neo-test');
      expect(dev.ctrlPort, 5001);
      final ok = await client.connectAndStart(dev);
      expect(ok, isTrue, reason: 'GET_INFO + START must both be ACKed');
      expect(client.state, NeoConnState.connected);
      expect(client.info!.uvPerCount.first, closeTo(0.04808, 1e-4), reason: 'scale comes from INFO');

      // 2. steady stream
      await Future<void>.delayed(const Duration(seconds: 2));
      final n = samples.length;
      // ignore: avoid_print
      print('after 2 s: $n samples (expect ~500 at 250 SPS)');
      expect(n, inInclusiveRange(380, 620));
      expect(samples.first.channels, 2);
      for (var i = 1; i < samples.length; i++) {
        expect(samples[i].idx - samples[i - 1].idx, 1, reason: 'contiguous index at $i');
      }
      expect(client.badPackets, 0);

      // 3. pause the device: stall flag at ~0.9 s, drop at ~3 s
      autoConnect = client.onDeviceDiscovered.listen((d) => client.connectAndStart(d));
      final t0 = DateTime.now();
      Process.killPid(fake.pid, ProcessSignal.sigstop);
      final stalled = await _until(() => client.dataStalled, const Duration(seconds: 2));
      final tStall = DateTime.now().difference(t0).inMilliseconds;
      expect(stalled, isTrue);
      expect(client.state, NeoConnState.connected, reason: 'stall alone must not drop the link');
      final dropped = await _until(() => client.state == NeoConnState.searching, const Duration(seconds: 5));
      final tDrop = DateTime.now().difference(t0).inMilliseconds;
      // ignore: avoid_print
      print('stall flag after $tStall ms, dropped after $tDrop ms');
      expect(dropped, isTrue);
      expect(tStall, inInclusiveRange(800, 1500));
      expect(tDrop, inInclusiveRange(2900, 3800));

      // 4. resume the device: HELLO returns, the client reconnects
      final before = samples.length;
      Process.killPid(fake.pid, ProcessSignal.sigcont);
      final back = await _until(() => client.state == NeoConnState.connected, const Duration(seconds: 8));
      expect(back, isTrue, reason: 'client must reconnect once HELLO reappears');
      await Future<void>.delayed(const Duration(seconds: 1));
      // ignore: avoid_print
      print('after reconnect: ${samples.length - before} new samples, stall changes: $stallChanges');
      expect(samples.length - before, greaterThan(100));
      expect(client.dataStalled, isFalse);
      expect(stallChanges, [true, false], reason: 'flag raised on stall, cleared when the link is dropped');
    } finally {
      await autoConnect?.cancel();
      Process.killPid(fake.pid, ProcessSignal.sigcont);
      client.dispose();
      fake.kill();
    }
  }, skip: available ? false : 'neo-fake not on PATH', timeout: const Timeout(Duration(seconds: 90)));
}
