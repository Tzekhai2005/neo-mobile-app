import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../theme/app_theme.dart';
import '../trace/trace_sources.dart';
import '../widgets/device_pill.dart';
import 'data_controls.dart';
import 'data_view_controller.dart';

/// The less-used controls of the live view, kept off the main page: how many
/// seconds it shows, the µV scale, pause, and the device's full details.
class AdvancedSettingsPage extends StatelessWidget {
  final DataViewController controller;
  final AppServices services;

  const AdvancedSettingsPage({super.key, required this.controller, required this.services});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Advanced settings')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            const _Heading('Time shown'),
            PillSegments(
              labels: [for (final s in DataViewController.windowChoices) '$s s'],
              selected: DataViewController.windowChoices.indexOf(controller.windowSec),
              keyPrefix: 'window',
              onSelect: (i) => controller.setWindow(DataViewController.windowChoices[i]),
            ),
            const SizedBox(height: 22),
            const _Heading('EEG scale (µV from the middle of a lane to its edge)'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final v in kEegScalesUv)
                PillButton(
                  key: ValueKey('scale-${v.round()}'),
                  label: '±${v.round()} µV',
                  selected: controller.eegScaleUv == v,
                  onTap: () => controller.setScale(v),
                ),
            ]),
            const SizedBox(height: 14),
            SwitchListTile(
              key: const ValueKey('pause-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Freeze the live view'),
              subtitle: const Text('Then drag the graph sideways to look back up to 30 seconds.'),
              value: controller.paused,
              onChanged: (_) => controller.togglePause(),
            ),
            const Divider(height: 28),
            ListTile(
              key: const ValueKey('device-details'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Device details'),
              subtitle: const Text('Serial, firmware, battery voltage and signal loss'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showDeviceDetails(context, services.status, () => services.loss),
            ),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;
  const _Heading(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(text,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
      );
}
