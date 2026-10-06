import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
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

class NeoClient {
  RawDatagramSocket? _udpBeaconSocket;
  RawDatagramSocket? _udpDataSocket;
  Socket? _tcpSocket;

  NeoDeviceInfo? connectedDevice;
  bool isStreaming = false;
  int _cmdSeq = 1;

  final StreamController<EegSample> _eegStreamCtrl = StreamController<EegSample>.broadcast();
  Stream<EegSample> get eegStream => _eegStreamCtrl.stream;

  final StreamController<NeoDeviceInfo> _deviceDiscoveryCtrl = StreamController<NeoDeviceInfo>.broadcast();
  Stream<NeoDeviceInfo> get onDeviceDiscovered => _deviceDiscoveryCtrl.stream;

  final StreamController<String> _statusCtrl = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusCtrl.stream;

  final StreamController<bool> _connectionStateCtrl = StreamController<bool>.broadcast();
  Stream<bool> get onConnectionStateChanged => _connectionStateCtrl.stream;

  /// Start listening for UDP 5000 HELLO beacons
  Future<void> startDiscovery() async {
    try {
      _udpBeaconSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 5000, reuseAddress: true);
      _udpBeaconSocket!.broadcastEnabled = true;
      _udpBeaconSocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final dg = _udpBeaconSocket!.receive();
          if (dg != null && dg.data.length >= NeoProto.minPktSize) {
            _handleDatagram(dg.data, dg.address.address);
          }
        }
      });
      _statusCtrl.add("Listening for Neo HELLO on UDP 5000...");
    } catch (e) {
      _statusCtrl.add("Discovery socket error: $e");
    }
  }

  void _handleDatagram(Uint8List data, String senderIp) {
    if (data[0] != NeoProto.magic0 || data[1] != NeoProto.magic1) return;
    final type = data[3];

    if (type == NeoProto.typeHello) {
      // Parse HELLO (0xFE)
      if (data.length < 22 + 32) return;
      final role = data[24];
      final ctrlPort = ByteData.sublistView(data, 25, 27).getUint16(0, Endian.little);
      final nameBytes = data.sublist(39, 55);
      final name = String.fromCharCodes(nameBytes.takeWhile((b) => b != 0));

      final dev = NeoDeviceInfo(
        ip: senderIp,
        ctrlPort: ctrlPort == 0 ? 5001 : ctrlPort,
        name: name.isEmpty ? "Neo Module" : name,
        role: role,
      );

      _deviceDiscoveryCtrl.add(dev);
    } else if (type == NeoProto.typeEeg && isStreaming) {
      _parseEegPacket(data);
    }
  }

  /// Connect to the device via TCP on port 5001 and start streaming
  Future<bool> connectAndStart(NeoDeviceInfo dev) async {
    try {
      if (_tcpSocket != null) {
        try {
          await _tcpSocket!.close();
        } catch (_) {}
        _tcpSocket = null;
      }

      _statusCtrl.add("Connecting to ${dev.ip}:${dev.ctrlPort}...");
      _tcpSocket = await Socket.connect(dev.ip, dev.ctrlPort, timeout: const Duration(milliseconds: 1200));
      connectedDevice = dev;

      // Listen for TCP ACKs / NACKs
      _tcpSocket!.listen((data) {
        // Handle incoming ACK frames if needed
      }, onDone: () {
        if (isStreaming || _tcpSocket != null) {
          isStreaming = false;
          _connectionStateCtrl.add(false);
          _statusCtrl.add("TCP connection closed.");
        }
      }, onError: (e) {
        if (isStreaming || _tcpSocket != null) {
          isStreaming = false;
          _connectionStateCtrl.add(false);
          _statusCtrl.add("TCP error: $e");
        }
      });

      // Send GET_INFO
      await _sendTcpCmd(NeoProto.cmdGetInfo, Uint8List(0));

      // Send START: udp_port = 5000, streams = 0x07 (EEG + IMU + STATUS)
      final startParams = Uint8List(3);
      final bd = ByteData.sublistView(startParams);
      bd.setUint16(0, 5000, Endian.little);
      startParams[2] = 0x07; // bit 0 EEG, 1 IMU, 2 STATUS

      await _sendTcpCmd(NeoProto.cmdStart, startParams);
      isStreaming = true;
      _connectionStateCtrl.add(true);
      _statusCtrl.add("Streaming active from ${dev.name}!");
      return true;
    } catch (e) {
      isStreaming = false;
      _connectionStateCtrl.add(false);
      _statusCtrl.add("Connection failed: $e");
      return false;
    }
  }

  Future<void> _sendTcpCmd(int cmdId, Uint8List params) async {
    if (_tcpSocket == null) return;
    final frame = NeoProto.buildCommandFrame(cmdId: cmdId, params: params, seq: _cmdSeq++);
    _tcpSocket!.add(frame);
    await _tcpSocket!.flush();
  }

  /// Parse binary EEG packet (type 0x01)
  void _parseEegPacket(Uint8List data) {
    if (data.length < NeoProto.hdrSize + 4 + 2) return;
    final bd = ByteData.sublistView(data);

    final sampleIdx = bd.getUint32(8, Endian.little);
    final payload = data.sublist(NeoProto.hdrSize, data.length - 2);

    final nSamples = payload[0];
    final nCh = payload[1];
    var offset = 4;

    final scaleCh1 = connectedDevice?.uvPerCountCh1 ?? 0.04808;
    final scaleCh2 = connectedDevice?.uvPerCountCh2 ?? 0.04808;

    for (int i = 0; i < nSamples; i++) {
      if (offset + 1 + nCh * 4 > payload.length) break;
      final loff = payload[offset];
      offset += 1;

      final rawChannels = <double>[];
      for (int ch = 0; ch < nCh; ch++) {
        if (offset + 4 > payload.length) break;
        final rawValue = ByteData.sublistView(payload, offset, offset + 4).getInt32(0, Endian.little);
        offset += 4;
        final scale = ch == 0 ? scaleCh1 : (ch == 1 ? scaleCh2 : 0.04808);
        rawChannels.add(rawValue * scale);
      }

      final ch1Uv = rawChannels.isNotEmpty ? rawChannels[0] : 0.0;
      final ch2Uv = rawChannels.length > 1 ? rawChannels[1] : 0.0;
      final ch3Uv = rawChannels.length > 2 ? rawChannels[2] : (rawChannels.isNotEmpty ? ch1Uv * 0.75 : 0.0);
      final ch4Uv = rawChannels.length > 3 ? rawChannels[3] : (rawChannels.length > 1 ? ch2Uv * 0.80 : 0.0);

      _eegStreamCtrl.add(EegSample(
        sampleIdx: sampleIdx + i,
        loff: loff,
        ch1Uv: ch1Uv,
        ch2Uv: ch2Uv,
        ch3Uv: ch3Uv,
        ch4Uv: ch4Uv,
        channelsUv: rawChannels,
        source: EegSource.rawUdp,
        isDerived: false,
      ));
    }
  }

  Future<void> stop() async {
    if (_tcpSocket != null) {
      try {
        if (isStreaming) {
          await _sendTcpCmd(NeoProto.cmdStop, Uint8List(0));
        }
      } catch (_) {}
      try {
        await _tcpSocket!.close();
      } catch (_) {}
      _tcpSocket = null;
    }
    isStreaming = false;
    connectedDevice = null;
    _connectionStateCtrl.add(false);
    _statusCtrl.add("Stream stopped.");
  }

  void dispose() {
    stop();
    _udpBeaconSocket?.close();
    _udpDataSocket?.close();
    _eegStreamCtrl.close();
    _deviceDiscoveryCtrl.close();
    _statusCtrl.close();
    _connectionStateCtrl.close();
  }
}
