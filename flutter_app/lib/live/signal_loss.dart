import '../device/device_status.dart';
import '../protocol/neo_client.dart';
import 'live_signal_buffer.dart';

/// Every loss number of the current live stream, kept apart by where the
/// samples were lost (README §3):
///
///  * **link**: packets that left the device but never arrived over Wi-Fi
///    (a gap in the packet `seq`);
///  * **device**: samples the device never sent (a gap in the sample index with
///    no `seq` gap: ring overrun, bad ADC frames).
///
/// A snapshot: read it again for fresh numbers.
class SignalLoss {
  /// UDP data packets (all types) lost on the link, counted from `seq` gaps.
  final int linkPacketsLost;
  final int linkPacketsReceived;

  /// EEG samples that arrived, and the missing ones split by cause. The link
  /// share is an estimate (see [LiveSignalBuffer.eegSamplesLostLink]).
  final int eegReceived;
  final int eegLostLink;
  final int eegLostDevice;

  final int imuReceived;
  final int imuLostLink;
  final int imuLostDevice;

  /// What the device itself reports in STATUS (README §5.3); null until the
  /// first STATUS arrives. Totals since the device booted, not since START, so
  /// compare them with each other and not with the counts above.
  final int? deviceReportedDroppedPackets;
  final int? deviceReportedEegOverruns;

  const SignalLoss({
    this.linkPacketsLost = 0,
    this.linkPacketsReceived = 0,
    this.eegReceived = 0,
    this.eegLostLink = 0,
    this.eegLostDevice = 0,
    this.imuReceived = 0,
    this.imuLostLink = 0,
    this.imuLostDevice = 0,
    this.deviceReportedDroppedPackets,
    this.deviceReportedEegOverruns,
  });

  factory SignalLoss.read({
    required NeoClient client,
    required LiveSignalBuffer buffer,
    required DeviceStatus status,
  }) =>
      SignalLoss(
        linkPacketsLost: client.linkPacketsLost,
        linkPacketsReceived: client.linkPacketsReceived,
        eegReceived: buffer.eegSamplesReceived,
        eegLostLink: buffer.eegSamplesLostLink,
        eegLostDevice: buffer.eegSamplesLostDevice,
        imuReceived: buffer.imuSamplesReceived,
        imuLostLink: buffer.imuSamplesLostLink,
        imuLostDevice: buffer.imuSamplesLostDevice,
        deviceReportedDroppedPackets: status.pktsDropped,
        deviceReportedEegOverruns: status.eegOverruns,
      );

  int get eegExpected => eegReceived + eegLostLink + eegLostDevice;

  /// Percent of EEG samples lost on the link / on the device; null while no
  /// EEG sample has been expected yet (never a made-up 0).
  double? get eegLinkLossPercent => eegExpected == 0 ? null : 100.0 * eegLostLink / eegExpected;
  double? get eegDeviceLossPercent => eegExpected == 0 ? null : 100.0 * eegLostDevice / eegExpected;
  double? get eegTotalLossPercent =>
      eegExpected == 0 ? null : 100.0 * (eegLostLink + eegLostDevice) / eegExpected;

  /// Percent of UDP packets lost on the link, from `seq` alone (independent of
  /// the EEG estimate above).
  double? get packetLinkLossPercent {
    final total = linkPacketsReceived + linkPacketsLost;
    return total == 0 ? null : 100.0 * linkPacketsLost / total;
  }
}
