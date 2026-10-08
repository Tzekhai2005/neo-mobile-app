import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'data_view_controller.dart';

/// The row of controls above the lanes: the time window, the µV scale, the
/// motion lanes and pause. It reads and changes only the [controller].
class DataControls extends StatelessWidget {
  final DataViewController controller;

  /// Leave out the motion switch (the expanded lane view has no motion lanes).
  final bool showMotionSwitch;

  const DataControls({super.key, required this.controller, this.showMotionSwitch = true});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final scale = controller.eegScaleUv;
        return Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _Segments(
              labels: [for (final s in DataViewController.windowChoices) '$s s'],
              selected: DataViewController.windowChoices.indexOf(controller.windowSec),
              keyPrefix: 'window',
              onSelect: (i) => controller.setWindow(DataViewController.windowChoices[i]),
            ),
            PillButton(
              key: const ValueKey('scale'),
              label: '±${scale == scale.roundToDouble() ? scale.round() : scale} µV',
              tooltip: 'Change the scale',
              onTap: controller.nextScale,
            ),
            if (showMotionSwitch)
              PillButton(
                key: const ValueKey('motion'),
                label: 'Motion',
                selected: controller.showMotion,
                tooltip: controller.showMotion ? 'Hide the motion lanes' : 'Show the motion lanes',
                onTap: controller.toggleMotion,
              ),
            PillButton(
              key: const ValueKey('pause'),
              label: controller.paused ? 'Resume' : 'Pause',
              icon: controller.paused ? Icons.play_arrow : Icons.pause,
              showLabel: false,
              selected: controller.paused,
              tooltip: controller.paused ? 'Resume the live view' : 'Freeze the view',
              onTap: controller.togglePause,
            ),
          ],
        );
      },
    );
  }
}

/// A small rounded button.
class PillButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final String? tooltip;
  final VoidCallback onTap;

  /// False shows only the icon; the label then serves as the spoken name.
  final bool showLabel;

  const PillButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.selected = false,
    this.tooltip,
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.navy : AppColors.textSecondary;
    return Tooltip(
      message: tooltip ?? label,
      child: Material(
        color: selected ? AppColors.accentSoft : AppColors.surface,
        shape: StadiumBorder(side: BorderSide(color: selected ? AppColors.accent : AppColors.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: showLabel ? 12 : 10, vertical: 7),
            child: Semantics(
              label: label,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) Icon(icon, size: showLabel ? 15 : 18, color: fg),
                if (icon != null && showLabel) const SizedBox(width: 5),
                if (showLabel) Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: fg)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Segments extends StatelessWidget {
  final List<String> labels;
  final int selected;
  final String keyPrefix;
  final ValueChanged<int> onSelect;

  const _Segments({required this.labels, required this.selected, required this.keyPrefix, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: AppColors.surface,
        shape: StadiumBorder(side: BorderSide(color: AppColors.border)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < labels.length; i++)
          GestureDetector(
            key: ValueKey('$keyPrefix-${labels[i].split(' ').first}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => onSelect(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: ShapeDecoration(
                color: i == selected ? AppColors.accentSoft : Colors.transparent,
                shape: const StadiumBorder(),
              ),
              child: Text(
                labels[i],
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: i == selected ? FontWeight.w600 : FontWeight.w400,
                  color: i == selected ? AppColors.navy : AppColors.textSecondary,
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// The "Seizure now" button.
class SeizureNowButton extends StatelessWidget {
  final VoidCallback onPressed;
  final bool compact;

  const SeizureNowButton({super.key, required this.onPressed, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      backgroundColor: AppColors.danger.withValues(alpha: 0.10),
      foregroundColor: AppColors.danger,
      side: const BorderSide(color: AppColors.danger),
      padding: EdgeInsets.symmetric(horizontal: 18, vertical: compact ? 8 : 14),
      minimumSize: Size(0, compact ? 34 : 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(compact ? 18 : 14)),
    );
    return FilledButton(
      key: const ValueKey('seizure-now'),
      style: style,
      onPressed: onPressed,
      child: Text('Seizure now', style: TextStyle(fontSize: compact ? 13 : 15, fontWeight: FontWeight.w600)),
    );
  }
}
