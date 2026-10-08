import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/device/device_status.dart';
import 'package:neo_companion/protocol/neo_client.dart';
import 'package:neo_companion/protocol/neo_messages.dart';

class FakeSource implements DeviceEventSource {
  final _messages = StreamController<NeoMessage>.broadcast(sync: true);
  final _info = StreamController<NeoInfo>.broadcast(sync: true);
  final _state = StreamController<NeoConnState>.broadcast(sync: true);
  final _stalledCtl = StreamController<bool>.broadcast(sync: true);
  NeoConnState _current = NeoConnState.searching;
  bool _isStalled = false;

  @override
  Stream<NeoMessage> get messages => _messages.stream;
  @override
  Stream<NeoInfo> get onInfo => _info.stream;
  @override
  Stream<NeoConnState> get onStateChanged => _state.stream;
  @override
  Stream<bool> get onDataStalledChanged => _stalledCtl.stream;
  @override
  NeoConnState get state => _current;
  @override
  bool get dataStalled => _isStalled;

  void setState(NeoConnState s) {
    _current = s;
    _state.add(s);
  }

  void setStalled(bool v) {
    _isStalled = v;
    _stalledCtl.add(v);
  }

  void send(NeoMessage m) => _messages.add(m);
  void announce(NeoInfo i) => _info.add(i);
}

NeoInfo info({String name = 'neo-A', String serial = 'A0B1C2D3E4F5', int imuRate = 100}) => NeoInfo(
      protoMajor: 0,
      protoMinor: 1,
      fwMajor: 0,
      fwMinor: 1,
      fwPatch: 0,
      hwRev: 0x0100,
      serial: serial,
      name: name,
      role: 0,
      features: 31,
      eegRateHz: 250,
      eegChannels: 2,
      eegFormat: 1,
      eegGain: const [6, 6],
      eegVrefUv: 2420000,
      uvPerCount: const [0.048, 0.048],
      imuRateHz: imuRate,
      imuGPerLsb: 0.001,
      imuDpsPerLsb: 0.1,
      podPresent: 0,
    );

// state, flags, battery %, battery mV, rssi, sent, dropped, overruns, pod
NeoStatus status({int flags = 164, int pct = 87, int mv = 4109, int rssi = -52}) =>
    NeoStatus(const NeoHeader(), 2, flags, pct, mv, rssi, 1234, 2, 0, 21);

NeoEvent event(int id, {int arg = 0, int idx = 0}) => NeoEvent(NeoHeader(sampleIdx: idx), id, arg, Uint8List(0));

NeoEegPacket eeg({int loff = 0}) => NeoEegPacket(const NeoHeader(), 2, 1, [
      for (var i = 0; i < 10; i++) NeoEegSample(loff, const [0, 0]),
    ]);

void main() {
  late FakeSource src;
  late DateTime t;
  late DeviceStatusTracker tracker;
  DateTime clock() => t;

  setUp(() {
    src = FakeSource();
    t = DateTime.utc(2026, 10, 7, 9, 0, 0);
    tracker = DeviceStatusTracker(src, now: clock);
  });
  tearDown(() => tracker.dispose());

  DeviceStatus s() => tracker.value;

  test('starts as searching with nothing known and nothing invented', () {
    expect(s().link, LinkState.searching);
    expect(s().isConnected, isFalse);
    expect(s().name, isNull);
    expect(s().batteryPct, isNull);
    expect(s().rssiDbm, isNull);
    expect(s().leadOff, isNull);
    expect(s().statusAt, isNull);
    expect(s().buttonPresses, 0);
    expect(s().recentEvents, isEmpty);
    expect(s().lowBattery, isFalse);
  });

  test('a tracker created while already connected starts connected', () {
    final late = FakeSource().._current = NeoConnState.connected;
    final t2 = DeviceStatusTracker(late, now: clock);
    addTearDown(t2.dispose);
    expect(t2.value.link, LinkState.connected);
    expect(t2.value.connectedAt, t);
  });

  group('link state', () {
    test('follows the client and records when the connection began', () {
      src.setState(NeoConnState.connecting);
      expect(s().link, LinkState.connecting);
      expect(s().connectedAt, isNull);
      t = t.add(const Duration(seconds: 2));
      src.setState(NeoConnState.connected);
      expect(s().link, LinkState.connected);
      expect(s().isConnected, isTrue);
      expect(s().connectedAt, t);
      src.setState(NeoConnState.searching);
      expect(s().link, LinkState.searching);
      expect(s().connectedAt, isNull);
    });

    test('stalled only while connected, and clears again', () {
      src.setState(NeoConnState.connected);
      src.setStalled(true);
      expect(s().link, LinkState.stalled);
      expect(s().isConnected, isTrue, reason: 'a stalled link is still a connection');
      src.setStalled(false);
      expect(s().link, LinkState.connected);
      src.setStalled(true);
      src.setState(NeoConnState.searching);
      expect(s().link, LinkState.searching, reason: 'dropping the link ends the stall');
    });
  });

  group('identity from INFO', () {
    test('is read and kept as last known after a disconnect', () {
      src.setState(NeoConnState.connected);
      src.announce(info());
      expect(s().name, 'neo-A');
      expect(s().serial, 'A0B1C2D3E4F5');
      expect(s().firmware, '0.1.0');
      expect(s().eegChannels, 2);
      expect(s().eegRateHz, 250);
      expect(s().imuRateHz, 100);
      src.setState(NeoConnState.searching);
      expect(s().name, 'neo-A');
      expect(s().firmware, '0.1.0');
    });

    test('an IMU rate of 0 means the IMU is off, not 0 Hz', () {
      src.announce(info(imuRate: 0));
      expect(s().imuRateHz, isNull);
    });

    test('an empty name or serial is unknown', () {
      src.announce(info(name: '', serial: ''));
      expect(s().name, isNull);
      expect(s().serial, isNull);
    });
  });

  group('STATUS', () {
    test('maps every field, with a signed RSSI and the flag bits', () {
      src.setState(NeoConnState.connected);
      src.send(status());
      expect(s().batteryPct, 87);
      expect(s().batteryMv, 4109);
      expect(s().rssiDbm, -52);
      expect(s().wifiConnected, isTrue);
      expect(s().streaming, isTrue);
      expect(s().charging, isFalse); // flags 164 = wifi + streaming + imu
      expect(s().deviceState, NeoDeviceState.streaming);
      expect(s().pktsSent, 1234);
      expect(s().pktsDropped, 2);
      expect(s().eegOverruns, 0);
      expect(s().statusAt, t);
    });

    test('charging comes from flag bit 1', () {
      src.send(status(flags: 164 | 0x02));
      expect(s().charging, isTrue);
    });

    test('no Wi-Fi means no RSSI, not 0 dBm', () {
      src.send(status(flags: 0x20, rssi: 0)); // streaming over USB, Wi-Fi off
      expect(s().wifiConnected, isFalse);
      expect(s().rssiDbm, isNull);
    });

    test('low battery is 15 % or less', () {
      src.send(status(pct: 16));
      expect(s().lowBattery, isFalse);
      src.send(status(pct: 15));
      expect(s().lowBattery, isTrue);
    });

    test('status age counts from the last STATUS', () {
      expect(s().statusAge(t), isNull);
      src.send(status());
      expect(s().statusAge(t.add(const Duration(seconds: 3))), const Duration(seconds: 3));
    });

    test('each STATUS publishes, because the age changes', () {
      var n = 0;
      tracker.addListener(() => n++);
      src.send(status());
      src.send(status());
      expect(n, 2);
    });
  });

  group('events', () {
    test('button presses, short and long, are counted; other events are only recorded', () {
      src.send(event(0x02, arg: 0, idx: 100)); // button, short
      src.send(event(0x02, arg: 1, idx: 200)); // button, long
      src.send(event(0x01, arg: 9, idx: 300)); // marker
      expect(s().buttonPresses, 2);
      expect(s().recentEvents.length, 3);
      expect(s().recentEvents.map((e) => e.kind), [NeoEventKind.button, NeoEventKind.button, NeoEventKind.marker]);
      expect(s().recentEvents.last.arg, 9);
      expect(s().recentEvents.first.sampleIdx, 100);
    });

    test('an event id this version does not know is still recorded', () {
      src.send(event(0x55));
      expect(s().recentEvents.single.kind, isNull);
      expect(s().recentEvents.single.eventId, 0x55);
    });

    test('only the last 20 events are kept', () {
      for (var i = 0; i < 25; i++) {
        src.send(event(0x02, idx: i));
      }
      expect(s().recentEvents.length, 20);
      expect(s().recentEvents.first.sampleIdx, 5);
      expect(s().recentEvents.last.sampleIdx, 24);
      expect(s().buttonPresses, 25, reason: 'the count is not capped');
    });

    test('the events stream carries them for the diary', () async {
      final got = <NeoEvent>[];
      final sub = tracker.events.listen(got.add);
      src.send(event(0x02, arg: 1, idx: 7));
      await pumpEventQueue();
      await sub.cancel();
      expect(got.single.isLongPress, isTrue);
      expect(got.single.header.sampleIdx, 7);
    });

    test('a new connection starts the counters over', () {
      src.setState(NeoConnState.connected);
      src.send(event(0x02));
      src.send(event(0x06, arg: 4));
      expect(s().buttonPresses, 1);
      expect(s().lastIssue, isNotNull);
      src.setState(NeoConnState.searching);
      src.setState(NeoConnState.connecting);
      expect(s().buttonPresses, 0);
      expect(s().recentEvents, isEmpty);
      expect(s().lastIssue, isNull);
    });
  });

  group('problems', () {
    test('LOW_BATTERY becomes a warning with the percentage', () {
      src.send(status(pct: 4));
      src.send(event(0x06, arg: 4));
      expect(s().lastIssue, 'Battery low (4 %)');
      expect(s().lowBattery, isTrue);
    });

    test('a device ERROR is named, with its text and whether it is fatal', () {
      src.send(NeoError(const NeoHeader(), 0x02, true, 'no DRDY'));
      expect(s().lastIssue, 'adcTimeout: no DRDY (fatal)');
      src.send(NeoError(const NeoHeader(), 0x7f, false, ''));
      expect(s().lastIssue, 'error 0x7f');
    });
  });

  group('lead-off', () {
    test('unknown until the first EEG packet, then true or false', () {
      expect(s().leadOff, isNull);
      src.send(eeg());
      expect(s().leadOff, isFalse);
      src.send(eeg(loff: 0x03));
      expect(s().leadOff, isTrue);
      src.send(eeg(loff: 0x10)); // reference electrode only is not an electrode fault
      expect(s().leadOff, isFalse);
    });

    test('EEG packets only publish when lead-off changes', () {
      var n = 0;
      tracker.addListener(() => n++);
      for (var i = 0; i < 30; i++) {
        src.send(eeg());
      }
      expect(n, 1, reason: 'null -> false once, then silence');
      src.send(eeg(loff: 1));
      expect(n, 2);
    });

    test('is unknown again once the link drops', () {
      src.setState(NeoConnState.connected);
      src.send(eeg(loff: 1));
      src.setState(NeoConnState.searching);
      expect(s().leadOff, isNull);
    });
  });

  test('a disconnect keeps the last known battery for display', () {
    src.setState(NeoConnState.connected);
    src.send(status(pct: 63));
    src.setState(NeoConnState.searching);
    expect(s().link, LinkState.searching);
    expect(s().batteryPct, 63);
    expect(s().statusAt, isNotNull);
  });

  test('after dispose nothing updates and the events stream is closed', () async {
    final probe = DeviceStatusTracker(src, now: clock);
    final done = Completer<void>();
    probe.events.listen((_) {}, onDone: done.complete);
    final before = probe.value;
    probe.dispose();
    src.send(status(pct: 1));
    src.setState(NeoConnState.connected);
    expect(probe.value, same(before));
    await done.future.timeout(const Duration(seconds: 1));
  });
}
