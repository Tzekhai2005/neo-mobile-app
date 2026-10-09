import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../device/device_status.dart';
import '../../live/activity_risk.dart';
import '../format.dart';
import '../theme/app_theme.dart';

/// What one chip says: a short state and its colour.
typedef ChipState = ({String text, Color color});

/// The electrodes, from what the device reports. A dash while it has not said.
ChipState eegChipState(DeviceStatus s) {
  if (s.link == LinkState.stalled) return (text: 'No data', color: AppColors.warning);
  if (s.link != LinkState.connected || s.leadOff == null) return (text: unknownText, color: AppColors.textMuted);
  return s.leadOff!
      ? (text: 'Check the ear piece', color: AppColors.warning)
      : (text: 'Good signal', color: AppColors.success);
}

/// Whether the wearer is moving, from the activity monitor. A dash when it cannot tell.
ChipState movementChipState(DeviceStatus s, ActivityRisk? risk) {
  if (s.link != LinkState.connected || risk == null) return (text: unknownText, color: AppColors.textMuted);
  return switch (risk.state) {
    RiskState.movement => (text: 'Active', color: AppColors.accent),
    RiskState.ok || RiskState.calibrating => (text: 'Still', color: AppColors.success),
    RiskState.noData || RiskState.noContact => (text: unknownText, color: AppColors.textMuted),
  };
}

/// The two small status cards on the start page: EEG and Movement.
class StatusChips extends StatelessWidget {
  final ValueListenable<DeviceStatus> status;

  /// Null when the activity readout is switched off; Movement then shows a dash.
  final ValueListenable<ActivityRisk>? risk;

  const StatusChips({super.key, required this.status, this.risk});

  @override
  Widget build(BuildContext context) {
    final merged = Listenable.merge([status, if (risk != null) risk!]);
    return ListenableBuilder(
      listenable: merged,
      builder: (context, _) => Row(children: [
        Expanded(child: _Chip(icon: Icons.show_chart, label: 'EEG', state: eegChipState(status.value))),
        const SizedBox(width: 12),
        Expanded(
          child: _Chip(
            icon: Icons.directions_walk,
            label: 'Movement',
            state: movementChipState(status.value, risk?.value),
          ),
        ),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final ChipState state;

  const _Chip({required this.icon, required this.label, required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        Icon(icon, size: 22, color: AppColors.navy),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: state.color, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(state.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}
