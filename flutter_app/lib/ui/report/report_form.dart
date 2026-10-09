import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/review_event.dart';
import '../../report/report_choice.dart';
import '../../report/report_controller.dart';
import '../../review/review_models.dart';
import '../../review/timeline_model.dart';
import '../data/data_controls.dart';
import '../format.dart';
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
        Row(children: [
          const Expanded(child: Text('Reports', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700))),
          IconButton(
            key: const ValueKey('report-info'),
            tooltip: 'What is in a report',
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showInfo(context),
          ),
        ]),
        const SizedBox(height: 4),
        const _Intro(),
        const SizedBox(height: 14),
        _Summary(controller: c),
        const SizedBox(height: 14),
        if (c.dayCount > 1) ...[_DateRange(controller: c), const SizedBox(height: 14)],
        LabelField(controller: c),
        const SizedBox(height: 18),
        Row(children: [
          const Text('Include in report', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const Spacer(),
          Text('${c.selectedCount} selected',
              key: const ValueKey('selected-count'),
              style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
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
            decoration: BoxDecoration(
                color: AppColors.surfaceSoft,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border)),
            child: const Text(
              'Nothing is confirmed yet, so the report will include the highest-scoring unreviewed candidates. '
              'Tick the events you want to change that.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ),
        if (c.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(c.error!,
                key: const ValueKey('report-error'), style: const TextStyle(color: AppColors.danger, fontSize: 13)),
          ),
        const SizedBox(height: 6),
        if (c.groups.all.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text('There are no events in these days.',
                  key: ValueKey('no-events'), style: TextStyle(color: AppColors.textSecondary)),
            ),
          ),
        if (g.markers.isNotEmpty)
          _KindGroup(controller: c, id: 'markers', kind: EventCategory.marked, events: g.markers),
        if (g.high.isNotEmpty)
          _KindGroup(controller: c, id: 'high', kind: EventCategory.possibleSeizure, events: g.high),
        if (g.medium.isNotEmpty) _KindGroup(controller: c, id: 'medium', kind: EventCategory.unusual, events: g.medium),
        if (g.low.isNotEmpty) _KindGroup(controller: c, id: 'low', kind: EventCategory.normal, events: g.low),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: AppColors.surfaceSoft, borderRadius: BorderRadius.circular(12)),
          child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline, size: 18, color: AppColors.accent),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'The report includes the EEG and movement around each event you choose, with a summary of the days covered.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ),
          ]),
        ),
      ],
    );
  }

  static void _showInfo(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('What is in a report'),
        content: const Text(
          'A PDF to read or print, and a zip of CSV files with the same data for analysis. '
          'It holds a summary of the days you pick and, for each event you choose, the EEG and movement around it.\n\n'
          'Possible seizure, Unusual activity and Normal activity come from a score given by an automatic detector. '
          'It is a prototype, not a medical device, and its suggestions are for a clinician to review.',
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
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
      decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border)),
      child: Row(
          children: [metric(n.total, 'events'), metric(n.confirmed, 'confirmed'), metric(n.unreviewed, 'unreviewed')]),
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
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppColors.surfaceSoft, borderRadius: BorderRadius.circular(14)),
        child: const Row(children: [
          Icon(Icons.description_outlined, size: 32, color: AppColors.accent),
          SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Create a report', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              SizedBox(height: 2),
              Text('Export your data to share with your clinician or keep for your own records.',
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
            ]),
          ),
        ]),
      );
}

/// The days the report covers, as one card; tapping it opens the choice.
class _DateRange extends StatelessWidget {
  final ReportController controller;
  const _DateRange({required this.controller});

  static String rangeText(ReportController c) {
    String d(int day) => dateLabel(c.info.localTimeAt(day * 86400.0));
    return c.firstDay == c.lastDay ? d(c.firstDay) : '${d(c.firstDay)} to ${d(c.lastDay)}';
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final n = c.lastDay - c.firstDay + 1;
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14), side: const BorderSide(color: AppColors.border)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('date-range'),
        onTap: () => showDateRangeSheet(context, c),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            const Icon(Icons.calendar_today_outlined, size: 22, color: AppColors.textSecondary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Date range', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                const SizedBox(height: 2),
                Text(rangeText(c),
                    key: const ValueKey('date-range-text'),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                Text(plural(n, 'day'), style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ]),
            ),
            const Icon(Icons.chevron_right, color: AppColors.textMuted),
          ]),
        ),
      ),
    );
  }
}

/// Pick the first and last day, or one of the quick ranges.
Future<void> showDateRangeSheet(BuildContext context, ReportController c) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        List<DropdownMenuItem<int>> items() => [
              for (var d = 0; d < c.dayCount; d++)
                DropdownMenuItem(
                    value: d,
                    child: Text('Day ${d + 1} · ${dateLabel(c.info.localTimeAt(d * 86400.0))}',
                        style: const TextStyle(fontSize: 14))),
            ];
        Widget box(String key, int value, ValueChanged<int> onChanged) => Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border)),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                      key: ValueKey(key),
                      isExpanded: true,
                      value: value,
                      items: items(),
                      onChanged: (v) => v == null ? null : onChanged(v)),
                ),
              ),
            );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Days to cover', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                PillButton(
                    key: const ValueKey('range-all'),
                    label: 'All ${c.dayCount} days',
                    selected: c.days == null,
                    onTap: () => c.setDays(0, c.dayCount - 1)),
                if (c.dayCount > 7)
                  PillButton(key: const ValueKey('range-last7'), label: 'Last 7 days', onTap: () => c.setLastDays(7)),
                if (c.dayCount > 3)
                  PillButton(key: const ValueKey('range-last3'), label: 'Last 3 days', onTap: () => c.setLastDays(3)),
                PillButton(key: const ValueKey('range-last1'), label: 'Last day', onTap: () => c.setLastDays(1)),
              ]),
              const SizedBox(height: 14),
              Row(children: [
                box('day-from', c.firstDay, (v) => c.setDays(v, c.lastDay)),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('to')),
                box('day-to', c.lastDay, (v) => c.setDays(c.firstDay, v)),
              ]),
              const SizedBox(height: 14),
              SizedBox(
                  width: double.infinity,
                  child: FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))),
            ]),
          ),
        );
      },
    ),
  );
}

/// One kind of event: a tick box for all of them, how many are chosen, and, opened
/// with the arrow, a tick box for each.
class _KindGroup extends StatefulWidget {
  final ReportController controller;
  final String id;
  final EventCategory kind;
  final List<ReviewEvent> events;
  const _KindGroup({required this.controller, required this.id, required this.kind, required this.events});

  @override
  State<_KindGroup> createState() => _KindGroupState();
}

class _KindGroupState extends State<_KindGroup> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final events = widget.events;
    final check = groupCheck(c.selection, events);
    final n = events.where((e) => c.selection.contains(e.event.id)).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Material(
          color: AppColors.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12), side: const BorderSide(color: AppColors.border)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 2, 4, 2),
            child: Row(children: [
              Checkbox(
                key: ValueKey('group-${widget.id}'),
                tristate: true,
                value: switch (check) { GroupCheck.all => true, GroupCheck.none => false, GroupCheck.some => null },
                onChanged: (_) => c.setGroup(events, on: check != GroupCheck.all),
                visualDensity: VisualDensity.compact,
              ),
              CategoryDot(category: widget.kind, size: 12),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(categoryName(widget.kind),
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
              Text('$n of ${events.length}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              IconButton(
                key: ValueKey('expand-${widget.id}'),
                tooltip: _open ? 'Hide the events' : 'Choose events one by one',
                icon: Icon(_open ? Icons.expand_less : Icons.expand_more),
                onPressed: () => setState(() => _open = !_open),
              ),
            ]),
          ),
        ),
      ),
      if (_open) ...[
        const SizedBox(height: 6),
        for (final e in events) _EventTick(controller: c, review: e),
      ],
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
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12), side: BorderSide(color: on ? AppColors.accent : AppColors.border)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('report-row-${e.event.id}'),
          onTap: () => controller.toggle(e.event.id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
            child: Row(children: [
              Checkbox(
                  value: on, onChanged: (_) => controller.toggle(e.event.id), visualDensity: VisualDensity.compact),
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
                  child: Text(statusName(e.status),
                      style: TextStyle(fontSize: 12, color: statusColor(e.status), fontWeight: FontWeight.w500)),
                ),
              if (e.band != null) BandChip(band: e.band!),
            ]),
          ),
        ),
      ),
    );
  }
}
