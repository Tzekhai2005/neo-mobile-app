import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../config/app_config.dart';
import '../../live/activity_risk.dart';
import '../format.dart';
import '../theme/app_theme.dart';

/// What the readout says about its own state, in a few words.
String riskStatusText(ActivityRisk r) => switch (r.state) {
      RiskState.ok => 'Compared with your normal signal',
      RiskState.calibrating => 'Learning your normal signal…',
      RiskState.movement => 'Moving, so the number is held down',
      RiskState.noContact => 'Check the electrodes',
      RiskState.noData => 'Waiting for data',
    };

/// The number to show: whole percent, or a dash.
String riskValueText(ActivityRisk r) => r.percent == null ? unknownText : '${r.percent!.round()} %';

Color _barColor(double p) => p >= 50 ? AppColors.warning : AppColors.accent;

/// EXPERIMENTAL activity-risk readout, wide (portrait). Remove it by setting
/// `kShowExperimentalRisk` to false; hide only the small print with an empty
/// `kRiskExperimentalNote`.
class ActivityRiskCard extends StatelessWidget {
  final ValueListenable<ActivityRisk> risk;

  const ActivityRiskCard({super.key, required this.risk});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ActivityRisk>(
      valueListenable: risk,
      builder: (context, r, _) {
        return Container(
          key: const ValueKey('risk-card'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('Activity risk', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(riskValueText(r), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 8),
            _Bar(percent: r.percent),
            const SizedBox(height: 8),
            Text(riskStatusText(r), style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            if (kRiskExperimentalNote.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Text(kRiskExperimentalNote, style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
              ),
          ]),
        );
      },
    );
  }
}

/// The same readout as a narrow panel for landscape: it sits beside the lanes, so
/// it never covers a trace.
class ActivityRiskPanel extends StatelessWidget {
  final ValueListenable<ActivityRisk> risk;

  const ActivityRiskPanel({super.key, required this.risk});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ActivityRisk>(
      valueListenable: risk,
      builder: (context, r, _) {
        return Container(
          key: const ValueKey('risk-panel'),
          width: 100,
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(children: [
            const Text('Risk', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(height: 4),
            Text(riskValueText(r), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Expanded(child: _VerticalBar(percent: r.percent)),
            const SizedBox(height: 8),
            Text(
              switch (r.state) {
                RiskState.ok => '',
                RiskState.calibrating => 'Learning…',
                RiskState.movement => 'Moving',
                RiskState.noContact => 'Check electrodes',
                RiskState.noData => 'No data',
              },
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
            if (kRiskExperimentalNote.isNotEmpty)
              const Text('Experimental', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
          ]),
        );
      },
    );
  }
}

/// A horizontal bar filled to [percent]. Built from two flexible halves, so it
/// always spans the width it is given, whatever its parent allows.
class _Bar extends StatelessWidget {
  final double? percent;
  const _Bar({required this.percent});

  @override
  Widget build(BuildContext context) {
    final p = percent;
    final fill = p == null ? 0 : (p.clamp(0, 100)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        width: double.infinity,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (fill > 0) Expanded(flex: fill, child: ColoredBox(color: _barColor(p!))),
          if (fill < 100) Expanded(flex: 100 - fill, child: const ColoredBox(color: AppColors.surfaceHigh)),
        ]),
      ),
    );
  }
}

/// The same, standing up: it fills from the bottom and takes all the height it is given.
class _VerticalBar extends StatelessWidget {
  final double? percent;
  const _VerticalBar({required this.percent});

  @override
  Widget build(BuildContext context) {
    final p = percent;
    final fill = p == null ? 0 : (p.clamp(0, 100)).round();
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: SizedBox(
          width: 14,
          height: double.infinity,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (fill < 100) Expanded(flex: 100 - fill, child: const ColoredBox(color: AppColors.surfaceHigh)),
            if (fill > 0) Expanded(flex: fill, child: ColoredBox(color: _barColor(p!))),
          ]),
        ),
      ),
    );
  }
}
