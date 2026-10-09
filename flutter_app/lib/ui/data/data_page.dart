import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../app/app_services.dart';
import '../../config/app_config.dart';
import '../../device/device_status.dart';
import '../format.dart';
import '../orientation.dart';
import '../shell/tab_scope.dart';
import '../theme/app_theme.dart';
import '../trace/signal_lanes.dart';
import 'activity_risk_card.dart';
import 'advanced_settings_page.dart';
import 'data_controls.dart';
import 'data_view_controller.dart';
import 'live_status.dart';

/// The Live tab: EEG, accelerometer and gyro, the experimental activity-risk readout,
/// the status tiles, the "Mark an event" button, and a page of advanced settings.
///
/// Portrait stacks everything; landscape gives the lanes the whole screen with the
/// controls in a thin bar and the readout beside them; tapping a lane expands that
/// lane alone, in landscape.
class DataPage extends StatefulWidget {
  const DataPage({super.key});

  @override
  State<DataPage> createState() => _DataPageState();
}

class _DataPageState extends State<DataPage> {
  AppServices? _services;
  DataViewController? _c;
  Timer? _timer;
  bool _wasExpanded = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 80), (_) => _tick());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active = TabScope.activeOf(context);
    final s = AppScope.of(context);
    if (!identical(s, _services)) {
      _c?.removeListener(_onChanged);
      _c?.dispose();
      _services = s;
      _c = DataViewController(buffer: s.live, seizureMarkers: s.seizureMarkers, status: s.status)
        ..addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c?.removeListener(_onChanged);
    _c?.dispose();
    super.dispose();
  }

  /// While another tab is on top this page is kept alive but does no work.
  void _tick() {
    if (!mounted || !_active) return;
    _c?.tick();
  }

  bool _active = true;

  /// An expanded lane is always landscape; otherwise the phone may be turned either way.
  void _onChanged() {
    final expanded = _c?.expandedLane != null;
    if (expanded == _wasExpanded) return;
    _wasExpanded = expanded;
    applyOrientationMode(expanded ? OrientationMode.landscapeOnly : OrientationMode.any);
  }

  void _markSeizure() {
    final m = _services!.markSeizure();
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    if (m == null) {
      messenger.showSnackBar(const SnackBar(content: Text('Waiting for the signal, so there is nothing to mark yet.')));
      return;
    }
    HapticFeedback.mediumImpact();
    messenger
        .showSnackBar(SnackBar(content: Text('Marked at ${clockText(m.at)}'), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final s = _services!;
    final c = _c!;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (c.expandedData != null) return _ExpandedView(controller: c, status: s.status, onSeizure: _markSeizure);
        final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
        return landscape
            ? _Landscape(services: s, controller: c, onSeizure: _markSeizure)
            : _Portrait(services: s, controller: c, onSeizure: _markSeizure);
      },
    );
  }
}

// ── layouts ───────────────────────────────────────────────────────────────────

class _Portrait extends StatelessWidget {
  final AppServices services;
  final DataViewController controller;
  final VoidCallback onSeizure;

  const _Portrait({required this.services, required this.controller, required this.onSeizure});

  void _openSettings(BuildContext context) => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => AdvancedSettingsPage(controller: controller, services: services),
      ));

  @override
  Widget build(BuildContext context) {
    final risk = kShowExperimentalRisk ? services.activityRisk : null;
    final lanes = controller.data.lanes.length;
    // Tall enough for each lane to read, whatever is shown.
    final graphHeight = (lanes * 74.0).clamp(230.0, 380.0);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Expanded(child: Text('Live monitoring', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700))),
          IconButton(
            key: const ValueKey('settings'),
            tooltip: 'Advanced settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _openSettings(context),
          ),
        ]),
        const SizedBox(height: 6),
        _LaneTabs(controller: controller),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: LiveStatusLine(status: services.status, now: services.now)),
          const SizedBox(width: 8),
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) => PillButton(
              key: const ValueKey('pause'),
              label: controller.paused ? 'Resume' : 'Pause',
              icon: controller.paused ? Icons.play_arrow : Icons.pause,
              selected: controller.paused,
              tooltip: controller.paused ? 'Resume the live view' : 'Freeze the view',
              onTap: controller.togglePause,
            ),
          ),
        ]),
        const SizedBox(height: 10),
        SizedBox(height: graphHeight, child: LanesArea(controller: controller, status: services.status)),
        if (risk != null) ...[const SizedBox(height: 12), ActivityRiskCard(risk: risk)],
        const SizedBox(height: 12),
        LiveStatusTiles(status: services.status, loss: () => services.loss),
        const SizedBox(height: 14),
        MarkEventButton(onPressed: onSeizure),
        const SizedBox(height: 10),
        Material(
          color: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: AppColors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            key: const ValueKey('advanced-settings'),
            leading: const Icon(Icons.tune, color: AppColors.textSecondary),
            title: const Text('Advanced settings'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openSettings(context),
          ),
        ),
      ]),
    );
  }
}

/// All, EEG or Movement: which lanes the graph draws.
class _LaneTabs extends StatelessWidget {
  final DataViewController controller;
  const _LaneTabs({required this.controller});

  static const _sets = [LaneSet.all, LaneSet.eeg, LaneSet.movement];
  static const _labels = ['All', 'EEG', 'Movement'];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          for (var i = 0; i < _sets.length; i++)
            Expanded(
              child: GestureDetector(
                key: ValueKey('lanes-${_sets[i].name}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => controller.setLaneSet(_sets[i]),
                child: Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: controller.laneSet == _sets[i] ? AppColors.navy : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    _labels[i],
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: controller.laneSet == _sets[i] ? AppColors.onNavy : AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

class _Landscape extends StatelessWidget {
  final AppServices services;
  final DataViewController controller;
  final VoidCallback onSeizure;

  const _Landscape({required this.services, required this.controller, required this.onSeizure});

  @override
  Widget build(BuildContext context) {
    final risk = kShowExperimentalRisk ? services.activityRisk : null;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
        child: Row(children: [
          IconButton(
            tooltip: 'Home',
            icon: const Icon(Icons.home_outlined, size: 22),
            color: AppColors.textSecondary,
            onPressed: () => TabScope.goTo(context, ShellTab.home),
          ),
          Expanded(child: _DeviceLabel(status: services.status)),
          Flexible(
            flex: 4,
            child: FittedBox(
                fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: DataControls(controller: controller)),
          ),
          const SizedBox(width: 10),
          MarkEventButton(onPressed: onSeizure, compact: true),
        ]),
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: LanesArea(controller: controller, status: services.status)),
            if (risk != null) ...[const SizedBox(width: 10), ActivityRiskPanel(risk: risk)],
          ]),
        ),
      ),
    ]);
  }
}

class _ExpandedView extends StatelessWidget {
  final DataViewController controller;
  final ValueListenable<DeviceStatus> status;
  final VoidCallback onSeizure;

  const _ExpandedView({required this.controller, required this.status, required this.onSeizure});

  @override
  Widget build(BuildContext context) {
    final lane = controller.expandedData!.lanes.single;
    final isEeg = lane.unit == 'µV';
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
        child: Row(children: [
          IconButton(
            key: const ValueKey('collapse'),
            tooltip: 'Back to all lanes',
            icon: const Icon(Icons.close, size: 22),
            color: AppColors.textSecondary,
            onPressed: controller.collapse,
          ),
          Text(lane.label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          if (isEeg) ...[
            IconButton(
              key: const ValueKey('scale-down'),
              tooltip: 'Smaller scale',
              icon: const Icon(Icons.remove_circle_outline, size: 22),
              onPressed: () => controller.stepScale(-1),
            ),
            IconButton(
              key: const ValueKey('scale-up'),
              tooltip: 'Larger scale',
              icon: const Icon(Icons.add_circle_outline, size: 22),
              onPressed: () => controller.stepScale(1),
            ),
          ],
          const Spacer(),
          Flexible(
            flex: 4,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: DataControls(controller: controller, showMotionSwitch: false),
            ),
          ),
          const SizedBox(width: 10),
          MarkEventButton(onPressed: onSeizure, compact: true),
        ]),
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: LanesArea(controller: controller, status: status, expanded: true),
        ),
      ),
    ]);
  }
}

// ── pieces ────────────────────────────────────────────────────────────────────

class _DeviceLabel extends StatelessWidget {
  final ValueListenable<DeviceStatus> status;
  const _DeviceLabel({required this.status});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<DeviceStatus>(
        valueListenable: status,
        builder: (context, s, _) => Text(
          [s.name ?? linkLabel(s.link), if (s.batteryPct != null) batteryText(s).split(',').first].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
      );
}

/// The lanes themselves, or a plain message while there is nothing to draw. A
/// paused view can be dragged sideways to look back through the buffer.
class LanesArea extends StatelessWidget {
  final DataViewController controller;
  final ValueListenable<DeviceStatus> status;
  final bool expanded;

  const LanesArea({super.key, required this.controller, required this.status, this.expanded = false});

  @override
  Widget build(BuildContext context) {
    final data = expanded ? controller.expandedData : controller.data;
    if (data == null || data.lanes.isEmpty) return _Waiting(status: status);
    return LayoutBuilder(builder: (context, box) {
      return Stack(children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Dragging right pulls earlier data into view.
          onHorizontalDragUpdate:
              controller.paused ? (d) => controller.scrollBy(d.delta.dx / box.maxWidth * controller.windowSec) : null,
          child: SizedBox.expand(
            child: SignalLanes(data: data, onLaneTap: expanded ? null : controller.expand),
          ),
        ),
        if (controller.paused)
          Positioned(
            top: 6,
            right: 6,
            child: IgnorePointer(
              child: Container(
                key: const ValueKey('paused-badge'),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: AppColors.navy, borderRadius: BorderRadius.circular(12)),
                child: Text(
                  controller.maxBackSec > 0 ? 'Paused · drag to look back' : 'Paused',
                  style: const TextStyle(fontSize: 11, color: AppColors.onNavy),
                ),
              ),
            ),
          ),
      ]);
    });
  }
}

class _Waiting extends StatelessWidget {
  final ValueListenable<DeviceStatus> status;
  const _Waiting({required this.status});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DeviceStatus>(
      valueListenable: status,
      builder: (context, s, _) {
        final (title, hint) = switch (s.link) {
          LinkState.searching => ('Waiting for the device', searchingHint),
          LinkState.connecting => ('Connecting', ''),
          LinkState.connected => ('Waiting for the first data', ''),
          LinkState.stalled => ('No data', 'The device is connected but has stopped sending.'),
        };
        return Container(
          key: const ValueKey('waiting'),
          alignment: Alignment.center,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.show_chart, size: 36, color: AppColors.textMuted),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            if (hint.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(hint,
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
            ],
          ]),
        );
      },
    );
  }
}
