import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/recording_source.dart';
import '../../config/app_config.dart';
import '../../data/review_event.dart';
import '../../review/event_similarity.dart';
import '../../review/review_controller.dart';
import '../../review/review_models.dart';
import '../../review/timeline_model.dart';
import '../data/data_controls.dart';
import '../data/data_view_controller.dart' show LaneSet;
import '../format.dart';
import '../theme/app_theme.dart';
import '../trace/signal_lanes.dart';
import '../trace/trace_sources.dart';
import 'review_widgets.dart';

/// What the half-screen sheet shows for the selected event: where it is in the list,
/// what kind of event it is and when, whether it looks like events already confirmed,
/// the stored signal around it with a playback bar, and a note. The decision buttons
/// are in [EventSheetFooter].
class EventSheetBody extends StatefulWidget {
  final ReviewController controller;

  const EventSheetBody({super.key, required this.controller});

  @override
  State<EventSheetBody> createState() => _EventSheetBodyState();
}

class _EventSheetBodyState extends State<EventSheetBody> {
  double _scaleUv = kDefaultEegScaleUv;
  LaneSet _lanes = LaneSet.all;
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
        final confirmedCount = c.events.where((e) => e.status == ReviewStatus.confirmed).length;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              IconButton(key: const ValueKey('previous'), tooltip: 'Previous event', icon: const Icon(Icons.chevron_left), onPressed: c.previous),
              Expanded(
                child: Text(pos == null ? 'Event' : 'Event $pos of ${c.positionCount}',
                    key: const ValueKey('position'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              IconButton(key: const ValueKey('next'), tooltip: 'Next event', icon: const Icon(Icons.chevron_right), onPressed: c.next),
              IconButton(key: const ValueKey('close-sheet'), tooltip: 'Close', icon: const Icon(Icons.close), onPressed: c.clearSelection),
            ]),
            const SizedBox(height: 4),
            _KindBanner(event: sel, when: dateTimeLabel(start), durationSec: sel.event.durationSec(rate), channels: channelsText(sel)),
            if (!sel.isMarker) ...[
              const SizedBox(height: 8),
              FutureBuilder<SimilarEvents>(
                key: ValueKey('similar-${sel.event.id}-$confirmedCount'),
                future: c.similarTo(sel.event.id),
                builder: (context, snap) => _SimilarNote(result: snap.data),
              ),
            ],
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _LaneSegments(value: _lanes, onChanged: (v) => setState(() => _lanes = v))),
              const SizedBox(width: 8),
              if (_lanes != LaneSet.movement)
                PillButton(
                  key: const ValueKey('sheet-scale'),
                  label: '±${_scaleUv.round()} µV',
                  tooltip: 'Change the scale',
                  onTap: _nextScale,
                ),
            ]),
            const SizedBox(height: 10),
            _SignalPlayer(
              key: ValueKey('player-${sel.event.id}'),
              future: _windowFor(sel.event.id),
              onRetry: () => setState(() => _window = null),
              eventDurationSec: sel.event.durationSec(rate),
              scaleUv: _scaleUv,
              lanes: _lanes,
            ),
            const SizedBox(height: 14),
            const Text('Your note', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            NoteField(key: ValueKey('note-${sel.event.id}'), controller: c, eventId: sel.event.id, initial: sel.note),
            const SizedBox(height: 8),
          ]),
        );
      },
    );
  }
}

/// What kind of event this is, in its own colour, with when and for how long.
class _KindBanner extends StatelessWidget {
  final ReviewEvent event;
  final String when;
  final double durationSec;
  final String channels;

  const _KindBanner({required this.event, required this.when, required this.durationSec, required this.channels});

  @override
  Widget build(BuildContext context) {
    final cat = event.category;
    final color = categoryColor(cat);
    return Container(
      key: const ValueKey('kind-banner'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(children: [
        CategoryDot(category: cat, size: 16),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(categoryName(cat), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: color)),
            const SizedBox(height: 2),
            Text(
              [when, if (!event.isMarker) durationShort(durationSec)].join(' · '),
              style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            if (!event.isMarker) Text(channels, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
          ]),
        ),
      ]),
    );
  }
}

/// Whether the event looks like ones already confirmed, in plain words. Experimental:
/// it compares a few simple measures of the signal, not a trained model.
class _SimilarNote extends StatelessWidget {
  final SimilarEvents? result;
  const _SimilarNote({required this.result});

  static String text(SimilarEvents r) {
    if (r.compared == 0) return 'Confirm a few events and this page will show which ones look alike.';
    if (r.similar == 0) return 'Does not look like any of your ${plural(r.compared, 'confirmed event')}.';
    return 'Looks similar to ${r.similar} of your ${plural(r.compared, 'confirmed event')}.';
  }

  @override
  Widget build(BuildContext context) {
    final r = result;
    return Container(
      key: const ValueKey('similar-note'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: AppColors.surfaceSoft, borderRadius: BorderRadius.circular(12)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.info_outline, size: 18, color: AppColors.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r == null ? 'Comparing with your confirmed events…' : text(r), style: const TextStyle(fontSize: 13)),
            if (kRiskExperimentalNote.isNotEmpty)
              const Text(kRiskExperimentalNote, style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
          ]),
        ),
      ]),
    );
  }
}

/// All, EEG or Movement.
class _LaneSegments extends StatelessWidget {
  final LaneSet value;
  final ValueChanged<LaneSet> onChanged;
  const _LaneSegments({required this.value, required this.onChanged});

  static const _labels = {LaneSet.all: 'All', LaneSet.eeg: 'EEG', LaneSet.movement: 'Movement'};

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        for (final e in _labels.entries)
          Expanded(
            child: GestureDetector(
              key: ValueKey('sheet-lanes-${e.key.name}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(e.key),
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 7),
                decoration: BoxDecoration(color: value == e.key ? AppColors.navy : Colors.transparent, borderRadius: BorderRadius.circular(8)),
                child: Text(e.value,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: value == e.key ? AppColors.onNavy : AppColors.textSecondary)),
              ),
            ),
          ),
      ]),
    );
  }
}

/// "0:12".
String clockMinutes(double sec) {
  final s = sec.floor();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// The stored signal, a cursor that plays through it in real time, and the bar to
/// play, pause and seek. Its state (the position) starts again for every event.
class _SignalPlayer extends StatefulWidget {
  final Future<SignalWindow> future;
  final VoidCallback onRetry;
  final double eventDurationSec;
  final double scaleUv;
  final LaneSet lanes;

  const _SignalPlayer({
    super.key,
    required this.future,
    required this.onRetry,
    required this.eventDurationSec,
    required this.scaleUv,
    required this.lanes,
  });

  @override
  State<_SignalPlayer> createState() => _SignalPlayerState();
}

class _SignalPlayerState extends State<_SignalPlayer> with SingleTickerProviderStateMixin {
  late final AnimationController _play = AnimationController(vsync: this, duration: const Duration(seconds: 40));

  @override
  void initState() {
    super.initState();
    _play.addStatusListener((_) {
      if (mounted) setState(() {}); // the button follows playing, paused and finished
    });
  }

  @override
  void dispose() {
    _play.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_play.isAnimating) {
      _play.stop();
    } else {
      if (_play.value >= 1) _play.value = 0;
      _play.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SignalWindow>(
      future: widget.future,
      builder: (context, snap) {
        if (snap.hasError) return SizedBox(height: 320, child: _SignalError(onRetry: widget.onRetry));
        final w = snap.data;
        if (w == null) return const SizedBox(height: 320, child: Center(child: CircularProgressIndicator()));
        final duration = w.durationSec;
        _play.duration = Duration(milliseconds: (duration * 1000).round());
        return Column(children: [
          SizedBox(
            height: 320,
            child: Stack(children: [
              Positioned.fill(
                child: SignalLanes(
                  data: windowTraceData(
                    w,
                    eventDurationSec: widget.eventDurationSec,
                    eegScaleUv: widget.scaleUv,
                    showMotion: widget.lanes != LaneSet.eeg,
                    showEeg: widget.lanes != LaneSet.movement,
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _play,
                      builder: (context, _) => CustomPaint(
                        key: const ValueKey('playhead'),
                        painter: _PlayheadPainter(_play.value, show: _play.value > 0),
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          ),
          AnimatedBuilder(
            animation: _play,
            builder: (context, _) => Row(children: [
              IconButton.filled(
                key: const ValueKey('play'),
                tooltip: _play.isAnimating ? 'Pause' : 'Play through the event',
                style: IconButton.styleFrom(backgroundColor: AppColors.navy, foregroundColor: AppColors.onNavy),
                icon: Icon(_play.isAnimating ? Icons.pause : Icons.play_arrow),
                onPressed: _toggle,
              ),
              Expanded(
                child: Slider(
                  key: const ValueKey('playback'),
                  value: _play.value.clamp(0.0, 1.0),
                  onChanged: (v) => _play.value = v,
                ),
              ),
              Text('${clockMinutes(_play.value * duration)} / ${clockMinutes(duration)}',
                  key: const ValueKey('playback-time'), style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
            ]),
          ),
        ]);
      },
    );
  }
}

class _PlayheadPainter extends CustomPainter {
  final double fraction;
  final bool show;
  _PlayheadPainter(this.fraction, {required this.show});

  @override
  void paint(Canvas canvas, Size size) {
    if (!show) return;
    final x = fraction.clamp(0.0, 1.0) * size.width;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height - 18), Paint()..color = AppColors.accent..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant _PlayheadPainter old) => old.fraction != fraction || old.show != show;
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
                  Expanded(child: _DecisionButton(key: const ValueKey('confirm'), label: 'This was a seizure', color: AppColors.danger, active: sel.status == ReviewStatus.confirmed, onPressed: c.confirm)),
                  const SizedBox(width: 8),
                  Expanded(child: _DecisionButton(key: const ValueKey('dismiss'), label: 'Not a seizure', color: AppColors.textSecondary, active: sel.status == ReviewStatus.dismissed, onPressed: c.dismiss)),
                  const SizedBox(width: 8),
                  Expanded(child: _DecisionButton(key: const ValueKey('unsure'), label: 'Not sure', color: AppColors.accent, active: sel.status == ReviewStatus.unsure, onPressed: c.markUnsure)),
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
        minimumSize: const Size(0, 52),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onPressed: onPressed,
      child: Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
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
