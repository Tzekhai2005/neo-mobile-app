import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../device/device_status.dart';
import '../../live/signal_loss.dart';
import '../format.dart';
import '../theme/app_theme.dart';

/// More than this share of EEG samples lost on the Wi-Fi link is called unstable.
const double kStableLinkLossPercent = 1.0;

/// How the link is doing, in one word and a colour. A dash when there is nothing to judge.
({String text, Color color}) connectionState(DeviceStatus s, SignalLoss loss) {
  switch (s.link) {
    case LinkState.searching:
      return (text: 'Searching', color: AppColors.textMuted);
    case LinkState.connecting:
      return (text: 'Connecting', color: AppColors.warning);
    case LinkState.stalled:
      return (text: 'No data', color: AppColors.warning);
    case LinkState.connected:
      final lost = loss.eegLinkLossPercent;
      if (lost == null) return (text: 'Connected', color: AppColors.success);
      return lost <= kStableLinkLossPercent
          ? (text: 'Stable', color: AppColors.success)
          : (text: 'Unstable', color: AppColors.warning);
  }
}

Color _wifiColor(int? rssi) => switch (wifiWord(rssi)) {
      'Good' => AppColors.success,
      'Fair' => AppColors.warning,
      'Weak' => AppColors.danger,
      _ => AppColors.textMuted,
    };

/// The three small tiles under the graph: Wi-Fi signal, battery and connection.
/// Each shows only what the device has reported.
class LiveStatusTiles extends StatelessWidget {
  final ValueListenable<DeviceStatus> status;
  final SignalLoss Function() loss;

  const LiveStatusTiles({super.key, required this.status, required this.loss});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DeviceStatus>(
      valueListenable: status,
      builder: (context, s, _) {
        final conn = connectionState(s, loss());
        final batteryColor =
            s.batteryPct == null ? AppColors.textMuted : (s.lowBattery ? AppColors.warning : AppColors.success);
        return Row(children: [
          Expanded(
              child: _Tile(
                  key: const ValueKey('tile-wifi'),
                  icon: Icons.wifi,
                  label: 'Wi-Fi',
                  value: wifiWord(s.rssiDbm),
                  color: _wifiColor(s.rssiDbm))),
          const SizedBox(width: 10),
          Expanded(
              child: _Tile(
                  key: const ValueKey('tile-battery'),
                  icon: Icons.battery_std,
                  label: 'Battery',
                  value: s.batteryPct == null ? unknownText : '${s.batteryPct} %',
                  color: batteryColor)),
          const SizedBox(width: 10),
          Expanded(
              child: _Tile(
                  key: const ValueKey('tile-connection'),
                  icon: Icons.sync_alt,
                  label: 'Connection',
                  value: conn.text,
                  color: conn.color)),
        ]);
      },
    );
  }
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _Tile({super.key, required this.icon, required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(children: [
        Icon(icon, size: 24, color: color),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        const SizedBox(height: 2),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Flexible(
            child: Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        ]),
      ]),
    );
  }
}

/// "Live  00:12:36": that the device is streaming and for how long. The time is
/// refreshed whenever the device reports (about once a second).
class LiveStatusLine extends StatelessWidget {
  final ValueListenable<DeviceStatus> status;
  final DateTime Function() now;

  const LiveStatusLine({super.key, required this.status, required this.now});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DeviceStatus>(
      valueListenable: status,
      builder: (context, s, _) {
        final live = s.link == LinkState.connected;
        final since = s.connectedAt;
        final text = live ? 'Live' : linkLabel(s.link);
        return Row(children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: live ? AppColors.success : AppColors.warning, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(text,
              key: const ValueKey('live-label'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const Spacer(),
          if (live && since != null)
            Text(elapsedText(now().difference(since)),
                key: const ValueKey('live-elapsed'),
                style: const TextStyle(
                    fontSize: 15, color: AppColors.textSecondary, fontFeatures: [FontFeature.tabularFigures()])),
        ]);
      },
    );
  }
}
