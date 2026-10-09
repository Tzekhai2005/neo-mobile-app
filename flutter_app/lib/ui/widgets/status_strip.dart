import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import '../../device/device_status.dart';
import '../format.dart';
import '../theme/app_theme.dart';

/// The thin device strip at the top of the Live, History and Reports pages: the
/// device, its electrode contact, battery and Wi-Fi. It only reads [status].
class StatusStrip extends StatelessWidget {
  final ValueListenable<DeviceStatus> status;

  const StatusStrip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: SizedBox(
        height: 48,
        child: ValueListenableBuilder<DeviceStatus>(
          valueListenable: status,
          builder: (context, s, _) {
            final connected = s.isConnected;
            final contact = !connected || s.leadOff == null
                ? AppColors.textMuted
                : (s.leadOff! ? AppColors.warning : AppColors.success);
            return Row(children: [
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  s.name ?? kBrandName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              Flexible(
                flex: 3,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    _Dot(color: connected ? AppColors.success : AppColors.warning),
                    const SizedBox(width: 4),
                    Text(connected ? linkLabel(s.link) : 'Searching', style: _small),
                    const SizedBox(width: 12),
                    Semantics(
                      label: 'Electrode contact',
                      child: _Dot(color: contact),
                    ),
                    const SizedBox(width: 4),
                    const Text('Contact', style: _small),
                    const SizedBox(width: 12),
                    Text(batteryText(s).split(',').first, style: _small),
                    const SizedBox(width: 8),
                    Text(wifiText(s.rssiDbm), style: _small),
                  ]),
                ),
              ),
              const SizedBox(width: 12),
            ]);
          },
        ),
      ),
    );
  }

  static const _small = TextStyle(fontSize: 11, color: AppColors.textSecondary);
}

class _Dot extends StatelessWidget {
  final Color color;
  const _Dot({required this.color});

  @override
  Widget build(BuildContext context) =>
      Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}
