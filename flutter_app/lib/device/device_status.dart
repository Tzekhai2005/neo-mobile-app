import 'dart:async';

import 'package:flutter/foundation.dart';

import '../protocol/neo_client.dart';
import '../protocol/neo_messages.dart';

/// Where the link to the device stands.
///  searching  – listening for the device's HELLO, not connected
///  connecting – handshake in progress
///  connected  – streaming, data arriving
///  stalled    – connected, but no data for about a second
enum LinkState { searching, connecting, connected, stalled }

/// One event the device sent (a button press, a stream restart, ...).
class DeviceEventRecord {
  final int eventId;
  final NeoEventKind? kind; // null for an event id this version does not know
  final int arg;
  final int sampleIdx;
  final DateTime at;

  const DeviceEventRecord({
    required this.eventId,
    required this.kind,
    required this.arg,
    required this.sampleIdx,
    required this.at,
  });
}

/// Everything a device widget can show, in one immutable snapshot. A field the
/// device has not reported is null; it is never given a placeholder value.
class DeviceStatus {
  static const int lowBatteryPercent = 15;

  final LinkState link;

  // Identity, from INFO. Kept after a disconnect as "last known".
  final String? name;
  final String? serial;
  final String? firmware;
  final int? eegChannels;
  final int? eegRateHz;
  final int? imuRateHz;

  // Latest STATUS packet (about once a second).
  final int? batteryPct;
  final int? batteryMv;
  final bool? charging;
  final int? rssiDbm; // null when the device is not on Wi-Fi
  final bool? wifiConnected;
  final bool? streaming;
  final NeoDeviceState? deviceState;
  final int? pktsSent;
  final int? pktsDropped; // dropped on the device
  final int? eegOverruns; // EEG samples lost on the device
  final DateTime? statusAt; // when the last STATUS arrived

  /// Start of the current connection; null when not connected.
  final DateTime? connectedAt;

  /// Any electrode reports lead-off; null until the first EEG packet of this connection.
  final bool? leadOff;

  /// Button presses (short and long) on this connection.
  final int buttonPresses;

  /// Latest device error or low-battery warning of this connection.
  final String? lastIssue;

  /// The last 20 device events of this connection, oldest first.
  final List<DeviceEventRecord> recentEvents;

  const DeviceStatus({
    this.link = LinkState.searching,
    this.name,
    this.serial,
    this.firmware,
    this.eegChannels,
    this.eegRateHz,
    this.imuRateHz,
    this.batteryPct,
    this.batteryMv,
    this.charging,
    this.rssiDbm,
    this.wifiConnected,
    this.streaming,
    this.deviceState,
    this.pktsSent,
    this.pktsDropped,
    this.eegOverruns,
    this.statusAt,
    this.connectedAt,
    this.leadOff,
    this.buttonPresses = 0,
    this.lastIssue,
    this.recentEvents = const [],
  });

  bool get isConnected => link == LinkState.connected || link == LinkState.stalled;
  bool get lowBattery => batteryPct != null && batteryPct! <= lowBatteryPercent;

  /// How long ago the last STATUS arrived, or null if none did.
  Duration? statusAge(DateTime now) => statusAt == null ? null : now.difference(statusAt!);
}

/// Builds a [DeviceStatus] from the client's streams and publishes a new one on
/// every real change. Use it as a `ValueListenable<DeviceStatus>`.
class DeviceStatusTracker extends ValueNotifier<DeviceStatus> {
  static const int _maxRecentEvents = 20;

  final DeviceEventSource _source;
  final DateTime Function() _now;
  final List<StreamSubscription<Object?>> _subs = [];
  final StreamController<NeoEvent> _events = StreamController<NeoEvent>.broadcast();

  // The working copy; `_publish` turns it into the immutable value.
  late NeoConnState _conn;
  late bool _stalled;
  String? _name, _serial, _firmware;
  int? _eegChannels, _eegRateHz, _imuRateHz;
  int? _batteryPct, _batteryMv, _rssiDbm, _pktsSent, _pktsDropped, _eegOverruns;
  bool? _charging, _wifi, _streaming, _leadOff;
  NeoDeviceState? _deviceState;
  DateTime? _statusAt, _connectedAt;
  int _buttonPresses = 0;
  String? _lastIssue;
  final List<DeviceEventRecord> _recent = [];

  DeviceStatusTracker(this._source, {DateTime Function()? now})
      : _now = now ?? DateTime.now,
        super(const DeviceStatus()) {
    _conn = _source.state;
    _stalled = _source.dataStalled;
    if (_conn == NeoConnState.connected) _connectedAt = _now();
    _subs
      ..add(_source.onStateChanged.listen(_onState))
      ..add(_source.onDataStalledChanged.listen(_onStalled))
      ..add(_source.onInfo.listen(_onInfo))
      ..add(_source.messages.listen(_onMessage));
    _publish();
  }

  /// Device events (button presses, markers, ...) as they arrive, for the diary.
  Stream<NeoEvent> get events => _events.stream;

  LinkState get _link => switch (_conn) {
        NeoConnState.searching => LinkState.searching,
        NeoConnState.connecting => LinkState.connecting,
        NeoConnState.connected => _stalled ? LinkState.stalled : LinkState.connected,
      };

  void _onState(NeoConnState s) {
    _conn = s;
    if (s == NeoConnState.connecting) {
      // A new connection: its counters and warnings start over.
      _buttonPresses = 0;
      _recent.clear();
      _lastIssue = null;
      _leadOff = null;
      _connectedAt = null;
    } else if (s == NeoConnState.connected) {
      _connectedAt = _now();
    } else {
      _connectedAt = null; // back to searching: identity and battery stay as last known
      _leadOff = null;
    }
    if (s != NeoConnState.connected) _stalled = false;
    _publish();
  }

  void _onStalled(bool stalled) {
    if (_stalled == stalled) return;
    _stalled = stalled;
    _publish();
  }

  void _onInfo(NeoInfo info) {
    _name = info.name.isEmpty ? null : info.name;
    _serial = info.serial.isEmpty ? null : info.serial;
    _firmware = info.firmware;
    _eegChannels = info.eegChannels;
    _eegRateHz = info.eegRateHz;
    _imuRateHz = info.imuRateHz > 0 ? info.imuRateHz : null; // 0 means the IMU is off
    _publish();
  }

  void _onMessage(NeoMessage m) {
    if (m is NeoStatus) {
      _batteryPct = m.batteryPct;
      _batteryMv = m.batteryMv;
      _charging = m.charging;
      _wifi = m.wifiConnected;
      _rssiDbm = m.wifiConnected && m.rssiDbm != 0 ? m.rssiDbm : null;
      _streaming = m.streaming;
      _deviceState = m.state;
      _pktsSent = m.pktsSent;
      _pktsDropped = m.pktsDropped;
      _eegOverruns = m.eegOverruns;
      _statusAt = _now();
      _publish();
    } else if (m is NeoEvent) {
      _recent.add(DeviceEventRecord(
        eventId: m.eventId,
        kind: m.kind,
        arg: m.arg,
        sampleIdx: m.header.sampleIdx,
        at: _now(),
      ));
      if (_recent.length > _maxRecentEvents) _recent.removeAt(0);
      if (m.kind == NeoEventKind.button) _buttonPresses++;
      if (m.kind == NeoEventKind.lowBattery) _lastIssue = 'Battery low (${m.arg} %)';
      if (!_events.isClosed) _events.add(m);
      _publish();
    } else if (m is NeoError) {
      final name = m.code?.name ?? 'error 0x${m.codeValue.toRadixString(16)}';
      _lastIssue = '$name${m.text.isEmpty ? '' : ': ${m.text}'}${m.fatal ? ' (fatal)' : ''}';
      _publish();
    } else if (m is NeoEegPacket) {
      final off = m.samples.isNotEmpty && m.samples.last.leadOff;
      if (_leadOff != off) {
        _leadOff = off;
        _publish(); // only on a change: EEG packets arrive 25 times a second
      }
    }
  }

  void _publish() {
    value = DeviceStatus(
      link: _link,
      name: _name,
      serial: _serial,
      firmware: _firmware,
      eegChannels: _eegChannels,
      eegRateHz: _eegRateHz,
      imuRateHz: _imuRateHz,
      batteryPct: _batteryPct,
      batteryMv: _batteryMv,
      charging: _charging,
      rssiDbm: _rssiDbm,
      wifiConnected: _wifi,
      streaming: _streaming,
      deviceState: _deviceState,
      pktsSent: _pktsSent,
      pktsDropped: _pktsDropped,
      eegOverruns: _eegOverruns,
      statusAt: _statusAt,
      connectedAt: _connectedAt,
      leadOff: _leadOff,
      buttonPresses: _buttonPresses,
      lastIssue: _lastIssue,
      recentEvents: List.unmodifiable(_recent),
    );
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _events.close();
    super.dispose();
  }
}
