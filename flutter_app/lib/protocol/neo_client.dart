import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'neo_messages.dart';
import 'neo_proto.dart';

class NeoDeviceInfo {
  final String ip;
  final int ctrlPort;
  final String name;
  final int role;
  double uvPerCountCh1;
  double uvPerCountCh2;
  int batteryPct;
  int batteryMv;

  NeoDeviceInfo({
    required this.ip,
    required this.ctrlPort,
    required this.name,
    required this.role,
    this.uvPerCountCh1 = 0.04808,
    this.uvPerCountCh2 = 0.04808,
    this.batteryPct = 100,
    this.batteryMv = 4200,
  });
}

/// Where the client is in the README §7.2 session.
///  searching  – listening for HELLO, no control connection
///  connecting – TCP open / handshake (GET_INFO, START) in flight
///  connected  – START was ACKed; data is expected on UDP
enum NeoConnState { searching, connecting, connected }

class NeoClient {
  static const int _udpPort = 5000;
  static const Duration _tcpConnectTimeout = Duration(seconds: 3);
  static const Duration _cmdTimeout = Duration(seconds: 1);
  /// No data for this long: raise the `dataStalled` flag (UI warning only).
  static const Duration _stallAfter = Duration(milliseconds: 900);
  /// No data for this long: the link is dead. Close TCP and rediscover. The
  /// spec (§5.3) declares the device lost after 3 s.
  static const Duration _lostAfter = Duration(seconds: 3);

  RawDatagramSocket? _udpSocket;
  Socket? _tcpSocket;
  NeoDeframer _deframer = NeoDeframer();
  final Map<int, Completer<NeoReply>> _pending = {};

  NeoDeviceInfo? connectedDevice;
  bool isStreaming = false;
  NeoConnState _state = NeoConnState.searching;
  NeoConnState get state => _state;

  /// True while connected but no data has arrived for [_stallAfter]. Clears as
  /// soon as a packet arrives; after [_lostAfter] the connection is dropped.
  bool get dataStalled => _stalled;

  /// Inbound packets rejected for bad size/magic/version/CRC.
  int badPackets = 0;

  int _cmdSeq = 1;
  bool _streamArmed = false; // accept data packets from the device
  bool _stalled = false;
  DateTime _lastDataAt = DateTime.now();
  Timer? _watchdog;
  bool _disposed = false;

  final StreamController<EegSample> _eegStreamCtrl = StreamController<EegSample>.broadcast();
  Stream<EegSample> get eegStream => _eegStreamCtrl.stream;

  final StreamController<NeoDeviceInfo> _deviceDiscoveryCtrl = StreamController<NeoDeviceInfo>.broadcast();
  Stream<NeoDeviceInfo> get onDeviceDiscovered => _deviceDiscoveryCtrl.stream;

  final StreamController<String> _statusCtrl = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusCtrl.stream;

  final StreamController<bool> _connectionStateCtrl = StreamController<bool>.broadcast();
  Stream<bool> get onConnectionStateChanged => _connectionStateCtrl.stream;

  final StreamController<bool> _stalledCtrl = StreamController<bool>.broadcast();
  Stream<bool> get onDataStalledChanged => _stalledCtrl.stream;

  void _setStalled(bool v) {
    if (_stalled == v) return;
    _stalled = v;
    _emit(_stalledCtrl, v);
  }

  void _emit<T>(StreamController<T> ctrl, T value) {
    if (!_disposed && !ctrl.isClosed) ctrl.add(value);
  }

  /// Bind UDP 5000: one socket carries HELLO beacons and, after START, data.
  Future<void> startDiscovery() async {
    if (_udpSocket != null) return;
    try {
      final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _udpPort, reuseAddress: true);
      sock.broadcastEnabled = true;
      sock.listen((RawSocketEvent event) {
        if (event != RawSocketEvent.read) return;
        final dg = sock.receive();
        if (dg != null) _handleDatagram(dg.data, dg.address.address);
      });
      _udpSocket = sock;
      _emit(_statusCtrl, "Listening for Neo HELLO on UDP $_udpPort...");
    } catch (e) {
      _emit(_statusCtrl, "Discovery socket error: $e");
    }
  }

  void _handleDatagram(Uint8List data, String senderIp) {
    final pkt = NeoProto.parsePacket(data);
    if (pkt == null) {
      badPackets++;
      return;
    }

    if (pkt.type == NeoProto.typeHello) {
      // Only offer devices while idle; HELLO repeats every second and must not
      // start overlapping connects.
      if (_state != NeoConnState.searching) return;
      final hello = NeoHello.decode(pkt.payload);
      if (hello == null || hello.protoMajor != NeoProto.version) return;
      _emit(
        _deviceDiscoveryCtrl,
        NeoDeviceInfo(
          ip: senderIp,
          ctrlPort: hello.ctrlPort == 0 ? 5001 : hello.ctrlPort,
          name: hello.name.isEmpty ? "Neo Module" : hello.name,
          role: hello.role,
        ),
      );
      return;
    }

    // Data packets: only from the device we hold the control connection to.
    if (!_streamArmed || senderIp != connectedDevice?.ip) return;
    _lastDataAt = DateTime.now();
    _setStalled(false);
    if (pkt.type == NeoProto.typeEeg) _parseEegPacket(pkt);
  }

  void _setState(NeoConnState s) {
    _state = s;
  }

  /// Run the README §7.2 handshake: TCP connect, GET_INFO, START. Returns true
  /// only once the device has ACKed START.
  Future<bool> connectAndStart(NeoDeviceInfo dev) async {
    if (_state != NeoConnState.searching) return false;
    _setState(NeoConnState.connecting);

    try {
      _emit(_statusCtrl, "Connecting to ${dev.ip}:${dev.ctrlPort}...");
      final sock = await Socket.connect(dev.ip, dev.ctrlPort, timeout: _tcpConnectTimeout);
      sock.setOption(SocketOption.tcpNoDelay, true);
      _tcpSocket = sock;
      _deframer = NeoDeframer();
      _cmdSeq = 1;
      connectedDevice = dev;

      sock.listen((chunk) {
        for (final pkt in _deframer.feed(chunk)) {
          _onControlPacket(pkt);
        }
      }, onDone: () {
        if (identical(sock, _tcpSocket)) _dropConnection("TCP connection closed.");
      }, onError: (e) {
        if (identical(sock, _tcpSocket)) _dropConnection("TCP error: $e");
      });

      final infoReply = await _request(NeoProto.cmdGetInfo, Uint8List(0));
      if (infoReply == null || !infoReply.ok) {
        _dropConnection("GET_INFO failed");
        return false;
      }
      final info = NeoInfo.decode(infoReply.data);
      if (info != null && info.uvPerCount.every((v) => v > 0)) {
        dev.uvPerCountCh1 = info.uvPerCount[0];
        dev.uvPerCountCh2 = info.uvPerCount[1];
      }

      // Arm data reception before START so the first packets are not lost.
      _lastDataAt = DateTime.now();
      _streamArmed = true;

      // START: udp_port = 5000, streams = 0x07 (EEG + IMU + STATUS)
      final startParams = Uint8List(3);
      ByteData.sublistView(startParams).setUint16(0, _udpPort, Endian.little);
      startParams[2] = 0x07;
      final startReply = await _request(NeoProto.cmdStart, startParams);
      if (startReply == null || !startReply.ok) {
        _dropConnection(startReply == null ? "START timed out" : "START refused (status ${startReply.status})");
        return false;
      }

      isStreaming = true;
      _setState(NeoConnState.connected);
      _watchdog?.cancel();
      _watchdog = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (_state != NeoConnState.connected) return;
        final silent = DateTime.now().difference(_lastDataAt);
        if (silent > _lostAfter) {
          _dropConnection("Connection lost — no data for ${_lostAfter.inSeconds} s.");
        } else if (silent > _stallAfter) {
          _setStalled(true);
        }
      });
      _emit(_connectionStateCtrl, true);
      _emit(_statusCtrl, "Streaming active from ${dev.name}!");
      return true;
    } catch (e) {
      _dropConnection("Connection failed: $e");
      return false;
    }
  }

  /// Send a command on the control link and wait for the ACK/NACK carrying the
  /// same cmd_seq. Returns null on timeout or a broken link.
  Future<NeoReply?> _request(int cmdId, Uint8List params) async {
    final sock = _tcpSocket;
    if (sock == null) return null;
    final seq = _cmdSeq++;
    final waiter = Completer<NeoReply>();
    _pending[seq] = waiter;
    try {
      sock.add(NeoProto.buildCommandFrame(cmdId: cmdId, params: params, seq: seq));
      await sock.flush();
      return await waiter.future.timeout(_cmdTimeout);
    } catch (_) {
      return null;
    } finally {
      _pending.remove(seq);
    }
  }

  void _onControlPacket(NeoPacket pkt) {
    if (pkt.type == NeoProto.typeAck || pkt.type == NeoProto.typeNack) {
      final reply = NeoReply.decode(pkt.payload);
      if (reply == null) return;
      final waiter = _pending[reply.cmdSeq];
      if (waiter != null && !waiter.isCompleted) waiter.complete(reply);
    } else if (pkt.type == NeoProto.typeError && pkt.payload.length >= 2) {
      _emit(_statusCtrl, "Device error 0x${pkt.payload[0].toRadixString(16)}");
    }
  }

  /// Tear down the control link and return to `searching`. Closing TCP makes
  /// the device stop streaming and resume HELLO (§7.2), which lets discovery
  /// start a fresh connect.
  void _dropConnection(String reason) {
    if (_disposed) return;
    final wasActive = _state != NeoConnState.searching;
    _watchdog?.cancel();
    _watchdog = null;
    _streamArmed = false;
    isStreaming = false;
    _setStalled(false);

    final sock = _tcpSocket;
    _tcpSocket = null;
    connectedDevice = null;
    for (final w in _pending.values.toList()) {
      if (!w.isCompleted) w.completeError(StateError(reason));
    }
    _pending.clear();
    _deframer = NeoDeframer();
    sock?.destroy();

    _setState(NeoConnState.searching);
    _emit(_statusCtrl, reason);
    if (wasActive) _emit(_connectionStateCtrl, false);
  }

  /// Decode an EEG packet (§5.1): n_samples | n_ch | format | reserved, then
  /// per sample `loff u8 | ch[n_ch] i32`.
  void _parseEegPacket(NeoPacket pkt) {
    final payload = pkt.payload;
    if (payload.length < 4) return;
    final nSamples = payload[0];
    final nCh = payload[1];
    final format = payload[2];
    if (format != 1 || nCh < 1 || nCh > 4) return; // unknown format: do not guess
    final bd = ByteData.sublistView(payload);

    final dev = connectedDevice;
    final scale = <double>[
      dev?.uvPerCountCh1 ?? 0.04808,
      dev?.uvPerCountCh2 ?? 0.04808,
    ];

    final recordSize = 1 + nCh * 4;
    var offset = 4;
    for (var i = 0; i < nSamples; i++) {
      if (offset + recordSize > payload.length) break;
      final loff = payload[offset];
      offset += 1;

      final channels = <double>[];
      for (var ch = 0; ch < nCh; ch++) {
        final raw = bd.getInt32(offset, Endian.little);
        offset += 4;
        channels.add(raw * scale[ch < scale.length ? ch : scale.length - 1]);
      }

      _emit(
        _eegStreamCtrl,
        EegSample(
          sampleIdx: pkt.sampleIdx + i,
          loff: loff,
          ch1Uv: channels[0],
          ch2Uv: channels.length > 1 ? channels[1] : 0.0,
          ch3Uv: channels.length > 2 ? channels[2] : 0.0,
          ch4Uv: channels.length > 3 ? channels[3] : 0.0,
          channelsUv: channels,
          source: EegSource.rawUdp,
        ),
      );
    }
  }

  Future<void> stop() async {
    if (_state == NeoConnState.searching) return;
    final sock = _tcpSocket;
    if (sock != null && isStreaming) {
      await _request(NeoProto.cmdStop, Uint8List(0));
    }
    _dropConnection("Stream stopped.");
  }

  void dispose() {
    _disposed = true;
    _watchdog?.cancel();
    _tcpSocket?.destroy(); // closing TCP stops the stream (§7.2)
    _tcpSocket = null;
    _udpSocket?.close();
    _eegStreamCtrl.close();
    _deviceDiscoveryCtrl.close();
    _statusCtrl.close();
    _connectionStateCtrl.close();
    _stalledCtrl.close();
  }
}
