import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/recording_source.dart';
import '../../data/review_event.dart';
import '../../review/review_controller.dart';
import '../../review/review_models.dart';
import '../../review/timeline_model.dart';
import '../data/data_controls.dart';
import '../theme/app_theme.dart';
import '../trace/signal_lanes.dart';
import '../trace/trace_sources.dart';
import 'review_widgets.dart';

/// What the half-screen sheet shows for the selected event: where it is in the list,
/// when it happened, the stored signal around it, a note, and Confirm or Dismiss.
class EventSheetBody extends StatefulWidget {
  final ReviewController controller;

  const EventSheetBody({super.key, required this.controller});

  @override
  State<EventSheetBody> createState() => _EventSheetBodyState();
}

class _EventSheetBodyState extends State<EventSheetBody> {
  double _scaleUv = kDefaultEegScaleUv;
  bool _showMotion = true;
  String? _windowId;
  Future<SignalWindow>? _window;

  ReviewController get c => widget.controller;

  Future<SignalWindow> _windowFor(String id) {
    if (_windowId != id || _window == null) {
      _windowId = id;
      _window = c.windowFor(id);
    }
    return _window!;
  }

  void _nextScale() => setState(() => _scaleUv = kEegScalesUv[(kEegScalesUv.indexOf(_scaleUv) + 1) % kEegScalesUv.length]);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final sel = c.selected;
        if (sel == null) return const SizedBox.shrink();
        final rate = c.info.eegRateHz;
        final start = c.info.localTimeAt(sel.event.startSec(rate));
        final pos = c.position;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              IconButton(key: const ValueKey('previous'), tooltip: 'Previous event', icon: const Icon(Icons.chevron_left), onPressed: c.previous),
              Expanded(
                child: Column(children: [
                  Text(pos == null ? 'Event' : 'Event $pos of ${c.positionCount}',
                      key: const ValueKey('position'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  Text(dateTimeLabel(start), style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                ]),
              ),
              IconButton(key: const ValueKey('next'), tooltip: 'Next event', icon: const Icon(Icons.chevron_right), onPressed: c.next),
              IconButton(key: const ValueKey('close-sheet'), tooltip: 'Close', icon: const Icon(Icons.close), onPressed: c.clearSelection),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(
                child: Text(
                  [
                    if (!sel.isMarker) durationShort(sel.event.durationSec(rate)),
                    sel.isMarker ? 'Patient button press' : 'Automatic · ${channelsText(sel)}',
                  ].join(' · '),
                  style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                ),
              ),
              if (sel.band != null) BandChip(band: sel.band!),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 6, children: [
              PillButton(
                key: const ValueKey('sheet-scale'),
                label: '±${_scaleUv.round()} µV',
                tooltip: 'Change the scale',
                onTap: _nextScale,
              ),
              PillButton(
                key: const ValueKey('sheet-motion'),
                label: 'Motion',
                selected: _showMotion,
                tooltip: _showMotion ? 'Hide the motion lanes' : 'Show the motion lanes',
                onTap: () => setState(() => _showMotion = !_showMotion),
              ),
            ]),
            const SizedBox(height: 10),
            SizedBox(
              height: 320,
              child: FutureBuilder<SignalWindow>(
                key: ValueKey('signal-${sel.event.id}'),
                future: _windowFor(sel.event.id),
                builder: (context, snap) {
                  if (snap.hasError) {
                    return _SignalError(onRetry: () => setState(() => _window = null));
                  }
                  final w = snap.data;
                  if (w == null) return const Center(child: CircularProgressIndicator());
                  return SignalLanes(
                    data: windowTraceData(
                      w,
                      eventDurationSec: sel.event.durationSec(rate),
                      eegScaleUv: _scaleUv,
                      showMotion: _showMotion,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 14),
            NoteField(key: ValueKey('note-${sel.event.id}'), controller: c, eventId: sel.event.id, initial: sel.note),
            const SizedBox(height: 8),
          ]),
        );
      },
    );
  }
}

/// Confirm and Dismiss, with the status and Undo under them. They stay at the foot
/// of the sheet whatever its height, so the two actions that matter are never
/// scrolled out of reach.
class EventSheetFooter extends StatelessWidget {
  final ReviewController controller;

  const EventSheetFooter({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final sel = c.selected;
        if (sel == null) return const SizedBox.shrink();
        return DecoratedBox(
          decoration: const BoxDecoration(color: AppColors.background, border: Border(top: BorderSide(color: AppColors.border))),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Expanded(child: _DecisionButton(key: const ValueKey('confirm'), label: 'Confirm', color: AppColors.success, active: sel.status == ReviewStatus.confirmed, onPressed: c.confirm)),
                  const SizedBox(width: 10),
                  Expanded(child: _DecisionButton(key: const ValueKey('dismiss'), label: 'Dismiss', color: AppColors.textSecondary, active: sel.status == ReviewStatus.dismissed, onPressed: c.dismiss)),
                ]),
                const SizedBox(height: 4),
                Row(children: [
                  Text('Status: ${statusName(sel.status)}',
                      key: const ValueKey('status'), style: TextStyle(fontSize: 13, color: statusColor(sel.status), fontWeight: FontWeight.w500)),
                  const Spacer(),
                  if (sel.status != ReviewStatus.candidate)
                    TextButton(key: const ValueKey('undo'), onPressed: c.undo, child: const Text('Undo')),
                ]),
                if (c.saveError != null)
                  Text(c.saveError!, key: const ValueKey('save-error'), style: const TextStyle(color: AppColors.danger, fontSize: 13)),
              ]),
            ),
          ),
        );
      },
    );
  }
}

class _SignalError extends StatelessWidget {
  final VoidCallback onRetry;
  const _SignalError({required this.onRetry});

  @override
  Widget build(BuildContext context) => Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('The signal for this event could not be read.', textAlign: TextAlign.center),
          TextButton(key: const ValueKey('retry-signal'), onPressed: onRetry, child: const Text('Try again')),
        ]),
      );
}

class _DecisionButton extends StatelessWidget {
  final String label;
  final Color color;
  final bool active;
  final VoidCallback onPressed;

  const _DecisionButton({super.key, required this.label, required this.color, required this.active, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: active ? color : color.withValues(alpha: 0.10),
        foregroundColor: active ? Colors.white : color,
        side: BorderSide(color: color),
        minimumSize: const Size(0, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onPressed: onPressed,
      child: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
    );
  }
}

/// The note on an event. It is saved a moment after typing stops, when the field
/// loses focus, and when the sheet moves to another event, always to the event it
/// was typed on.
class NoteField extends StatefulWidget {
  final ReviewController controller;
  final String eventId;
  final String? initial;

  const NoteField({super.key, required this.controller, required this.eventId, required this.initial});

  @override
  State<NoteField> createState() => _NoteFieldState();
}

class _NoteFieldState extends State<NoteField> {
  late final TextEditingController _text = TextEditingController(text: widget.initial ?? '');
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

  void _changed(String _) {
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), _flush);
  }

  void _flush() {
    _debounce?.cancel();
    if (!_dirty) return;
    _dirty = false;
    widget.controller.setNoteFor(widget.eventId, _text.text);
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
      key: const ValueKey('note'),
      controller: _text,
      focusNode: _focus,
      onChanged: _changed,
      minLines: 1,
      maxLines: 4,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        hintText: 'Add a note',
        filled: true,
        fillColor: AppColors.surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.border)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }
}
