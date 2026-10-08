import 'dart:async';

import '../protocol/neo_client.dart';
import '../protocol/neo_messages.dart';
import 'live_signal_buffer.dart';

/// Connects a [NeoClient] to a [LiveSignalBuffer]: configures the buffer from
/// the device INFO, then writes every EEG and IMU packet into it.
class LiveFeed {
  final NeoClient client;
  final LiveSignalBuffer buffer;
  late final StreamSubscription<NeoInfo> _infoSub;
  late final StreamSubscription<NeoMessage> _messageSub;

  LiveFeed(this.client, this.buffer) {
    // INFO arrives before START, so scales and rates are set before sample 0.
    _infoSub = client.onInfo.listen(buffer.configure);
    _messageSub = client.messages.listen(_onMessage);
  }

  void _onMessage(NeoMessage m) {
    if (m is NeoEegPacket) {
      buffer.pushEeg(m);
    } else if (m is NeoImuPacket) {
      buffer.pushImu(m);
    } else if (m is NeoEvent && m.kind == NeoEventKind.syncRestart) {
      buffer.reset(); // the sample index starts over at 0 (§3)
    } else {
      buffer.noteLinkGap(m.header.linkGap);
    }
  }

  Future<void> dispose() async {
    await _infoSub.cancel();
    await _messageSub.cancel();
  }
}
