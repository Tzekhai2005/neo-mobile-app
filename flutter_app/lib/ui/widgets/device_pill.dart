import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../device/device_status.dart';
import '../../live/signal_loss.dart';
import '../format.dart';
import '../theme/app_theme.dart';

Color linkColor(LinkState l) => switch (l) {
      LinkState.connected => AppColors.success,
      LinkState.connecting || LinkState.stalled => AppColors.warning,
      LinkState.searching => AppColors.textMuted,
    };

/// The device in one line: "Connected · Neo-4F2A · 48 %". Tapped, it opens the
/// full details. While no device is found it says what to do about it.
class DevicePill extends StatelessWidget {
  final ValueListenable<DeviceStatus> status;
  final SignalLoss Function() loss;

  const DevicePill({super.key, required this.status, required this.loss});

  /// The text of the pill, from what the device has reported.
  static String summary(DeviceStatus s) => [
        linkLabel(s.link),
        if (s.name != null) s.name!,
        if (s.batteryPct != null) batteryText(s).split(',').first,
      ].join(' · ');

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DeviceStatus>(
      valueListenable: status,
      builder: (context, s, _) {
        return Column(mainAxisSize: MainAxisSize.min, children: [
          Material(
            color: AppColors.surface,
            shape: StadiumBorder(side: BorderSide(color: AppColors.border)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => showDeviceDetails(context, status, loss),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(color: linkColor(s.link), shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 9),
                  Flexible(
                    child: Text(
                      summary(s),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.keyboard_arrow_down, size: 18, color: AppColors.textSecondary),
                ]),
              ),
            ),
          ),
          if (s.name == null && s.link == LinkState.searching)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                searchingHint,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ),
        ]);
      },
    );
  }
}

Future<void> showDeviceDetails(BuildContext context, ValueListenable<DeviceStatus> status, SignalLoss Function() loss) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => DeviceDetailsSheet(status: status, loss: loss),
  );
}

/// Everything the device has reported, with a dash for what it has not.
class DeviceDetailsSheet extends StatelessWidget {
  final ValueListenable<DeviceStatus> status;
  final SignalLoss Function() loss;

  const DeviceDetailsSheet({super.key, required this.status, required this.loss});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ValueListenableBuilder<DeviceStatus>(
        valueListenable: status,
        builder: (context, s, _) {
          final l = loss();
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 10, height: 10, decoration: BoxDecoration(color: linkColor(s.link), shape: BoxShape.circle)),
                const SizedBox(width: 10),
                Text(linkLabel(s.link), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              ]),
              const SizedBox(height: 12),
              _Row('Device', s.name ?? unknownText),
              _Row('Serial', s.serial ?? unknownText),
              _Row('Firmware', s.firmware ?? unknownText),
              _Row('Battery', batteryText(s)),
              _Row('Battery voltage', s.batteryMv == null ? unknownText : '${s.batteryMv} mV'),
              _Row('Wi-Fi signal', wifiText(s.rssiDbm)),
              _Row('Recording', streamText(s)),
              _Row('Electrode contact', contactText(s.leadOff)),
              _Row('Lost on Wi-Fi', percentText(l.eegLinkLossPercent)),
              _Row('Lost on the device', percentText(l.eegDeviceLossPercent)),
              if (s.lastIssue != null) _Row('Last warning', s.lastIssue!),
            ]),
          );
        },
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label, value;
  const _Row(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 14))),
          Flexible(child: Text(value, textAlign: TextAlign.end, style: const TextStyle(fontSize: 14))),
        ]),
      );
}
