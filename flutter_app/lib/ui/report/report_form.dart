import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/review_event.dart';
import '../../report/report_choice.dart';
import '../../report/report_controller.dart';
import '../../review/review_models.dart';
import '../../review/timeline_model.dart';
import '../data/data_controls.dart';
import '../review/review_widgets.dart';
import '../theme/app_theme.dart';

/// Choosing what goes into the report: the summary, the patient label, the days, a
/// one-tap preset, and a tick box for every event, grouped by band.
class ReportForm extends StatelessWidget {
  final ReportController controller;
  const ReportForm({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final g = c.groups;
    final preset = c.preset;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      children: [
        _Summary(controller: c),
        const SizedBox(height: 14),
        LabelField(controller: c),
        if (c.dayCount > 1) ...[const SizedBox(height: 14), _Days(controller: c)],
        const SizedBox(height: 18),
        Row(children: [
          const Text('Include in report', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const Spacer(),
          Text('${c.selectedCount} selected', key: const ValueKey('selected-count'), style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final (p, label) in [
            (ReportPreset.confirmed, 'Confirmed'),
            (ReportPreset.allCandidates, 'All candidates'),
            (ReportPreset.markers, 'Markers'),
          ])
            PillButton(
              key: ValueKey('preset-${p.name}'),
              label: label,
              selected: preset == p,
              onTap: () => c.applyPreset(p),
            ),
          TextButton(key: const ValueKey('clear'), onPressed: c.clearSelection, child: const Text('Clear')),
        ]),
        if (c.isFallback)
          Container(
            key: const ValueKey('fallback-notice'),
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.surfaceSoft, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
            child: const Text(
              'Nothing is confirmed yet, so the report will include the highest-scoring unreviewed candidates. '
              'Tick the events you want to change that.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ),
        if (c.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(c.error!, key: const ValueKey('report-error'), style: const TextStyle(color: AppColors.danger, fontSize: 13)),
          ),
        const SizedBox(height: 6),
        if (c.groups.all.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text('There are no events in these days.', key: ValueKey('no-events'), style: TextStyle(color: AppColors.textSecondary)),
            ),
          ),
        if (g.markers.isNotEmpty) ..._group('markers', 'Patient markers', g.markers),
        if (g.high.isNotEmpty) ..._group('high', 'High', g.high),
        if (g.medium.isNotEmpty) ..._group('medium', 'Medium', g.medium),
        if (g.low.isNotEmpty) ..._group('low', 'Low', g.low),
      ],
    );
  }

  List<Widget> _group(String id, String title, List<ReviewEvent> events) {
    final check = groupCheck(controller.selection, events);
    final n = events.where((e) => controller.selection.contains(e.event.id)).length;
    return [
      Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Row(children: [
          Checkbox(
            key: ValueKey('group-$id'),
            tristate: true,
            value: switch (check) { GroupCheck.all => true, GroupCheck.none => false, GroupCheck.some => null },
            onChanged: (_) => controller.setGroup(events, on: check != GroupCheck.all),
            visualDensity: VisualDensity.compact,
          ),
          Expanded(child: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
          Text('$n of ${events.length}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ]),
      ),
      for (final e in events) _EventTick(controller: controller, review: e),
    ];
  }
}

class _Summary extends StatelessWidget {
  final ReportController controller;
  const _Summary({required this.controller});

  @override
  Widget build(BuildContext context) {
    final n = controller.counts;
    Widget metric(int v, String label) => Expanded(
          child: Column(children: [
            Text('$v', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ]),
        );
    return Container(
      key: const ValueKey('summary'),
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
      child: Row(children: [metric(n.total, 'events'), metric(n.confirmed, 'confirmed'), metric(n.unreviewed, 'unreviewed')]),
    );
  }
}

/// The patient label. It is saved a moment after typing stops, and when the field
/// loses focus, and it is there again next time.
class LabelField extends StatefulWidget {
  final ReportController controller;
  const LabelField({super.key, required this.controller});

  @override
  State<LabelField> createState() => _LabelFieldState();
}

class _LabelFieldState extends State<LabelField> {
  late final TextEditingController _text = TextEditingController(text: widget.controller.patientLabel);
  final FocusNode _focus = FocusNode();
  Timer? _debounce;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _flush();
    });
  }

  void _changed(String text) {
    widget.controller.editLabel(text); // applies to the next report at once
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _flush);
  }

  void _flush() {
    _debounce?.cancel();
    if (!_dirty) return;
    _dirty = false;
    widget.controller.saveLabel();
  }

  @override
  void dispose() {
    _flush();
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const ValueKey('label-field'),
      controller: _text,
      focusNode: _focus,
      onChanged: _changed,
      textInputAction: TextInputAction.done,
      decoration: InputDecoration(
        labelText: 'Patient label (optional)',
        floatingLabelBehavior: FloatingLabelBehavior.always, // the label never sits on the text
        hintText: 'For example, Subject 4092',
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
      ),
    );
  }
}

class _Days extends StatelessWidget {
  final ReportController controller;
  const _Days({required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    List<DropdownMenuItem<int>> items() => [
          for (var d = 0; d < c.dayCount; d++)
            DropdownMenuItem(value: d, child: Text('Day ${d + 1} · ${dateLabel(c.info.localTimeAt(d * 86400.0))}', style: const TextStyle(fontSize: 14))),
        ];
    Widget box(String key, int value, ValueChanged<int> onChanged) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(key: ValueKey(key), isExpanded: true, value: value, items: items(), onChanged: (v) => v == null ? null : onChanged(v)),
            ),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Days to cover', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
      const SizedBox(height: 6),
      Row(children: [
        box('day-from', c.firstDay, (v) => c.setDays(v, c.lastDay)),
        const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('to')),
        box('day-to', c.lastDay, (v) => c.setDays(c.firstDay, v)),
      ]),
    ]);
  }
}

/// One event with a tick box.
class _EventTick extends StatelessWidget {
  final ReportController controller;
  final ReviewEvent review;
  const _EventTick({required this.controller, required this.review});

  @override
  Widget build(BuildContext context) {
    final e = review;
    final rate = controller.info.eegRateHz;
    final local = controller.info.localTimeAt(e.event.startSec(rate));
    final on = controller.selection.contains(e.event.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: on ? AppColors.accent : AppColors.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('report-row-${e.event.id}'),
          onTap: () => controller.toggle(e.event.id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
            child: Row(children: [
              Checkbox(value: on, onChanged: (_) => controller.toggle(e.event.id), visualDensity: VisualDensity.compact),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(dateTimeLabel(local), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  Text(
                    [if (!e.isMarker) durationShort(e.event.durationSec(rate)), channelsText(e)].join(' · '),
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ]),
              ),
              if (e.status != ReviewStatus.candidate)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(statusName(e.status), style: TextStyle(fontSize: 12, color: statusColor(e.status), fontWeight: FontWeight.w500)),
                ),
              if (e.band != null) BandChip(band: e.band!),
            ]),
          ),
        ),
      ),
    );
  }
}
