import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../app/app_services.dart';
import '../../config/app_config.dart';
import '../../data/review_event.dart';
import '../format.dart';
import '../shell/app_shell.dart';
import '../shell/tab_scope.dart';
import '../theme/app_theme.dart';
import '../widgets/brand_logo.dart';
import '../widgets/destination_tile.dart';
import '../widgets/device_pill.dart';
import '../widgets/live_data_card.dart';
import 'recordings_sheet.dart';

/// What the start page says about the recording in use.
class _RecordingLine {
  final String chip; // the text of the recording chip
  final String review; // the Review tile's line
  final String? notice; // a warning to show under the chip

  const _RecordingLine({required this.chip, required this.review, this.notice});

  static const loading = _RecordingLine(chip: 'Loading the recording…', review: unknownText);
}

/// The Home tab: the branded start page with the device, the other pages, and the recording in use.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  AppServices? _services;
  late Future<_RecordingLine> _recording;
  bool _active = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = AppScope.of(context);
    final active = TabScope.activeOf(context);
    if (!identical(s, _services)) {
      _services = s;
      _recording = _readRecording(s);
    } else if (active && !_active) {
      // Back from another tab: decisions or the recording may have changed.
      _recording = _readRecording(s);
    }
    _active = active;
  }

  static Future<_RecordingLine> _readRecording(AppServices s) async {
    try {
      await s.loadReview();
      final events = s.reviewEvents();
      final reviewed = events.where((e) => e.status != ReviewStatus.candidate).length;
      final info = s.recording.info;
      return _RecordingLine(
        chip: [
          s.currentDataset ?? 'Demo recording',
          if (info.synthetic) 'synthetic',
          durationText(info.durationSec),
          plural(events.length, 'event'),
        ].join(' · '),
        review: '${plural(events.length, 'event')} · $reviewed reviewed',
        notice: s.datasetNotice,
      );
    } on StateError {
      // The platform has no app storage (the web preview).
      return const _RecordingLine(chip: "Recordings aren't available on this device", review: 'Unavailable');
    } catch (_) {
      return _RecordingLine(
        chip: 'No recording loaded · tap to choose one',
        review: 'Recording unavailable',
        notice: s.datasetNotice,
      );
    }
  }

  void _reload() {
    final next = _readRecording(_services!);
    setState(() {
      _recording = next;
    });
  }

  void _open(int tab) => TabScope.goTo(context, tab);

  Future<void> _chooseRecording() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => RecordingsSheet(services: _services!),
    );
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = _services!;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Center(child: BrandLogo(width: 190)),
            if (kTagline.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text(kTagline,
                  textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary, fontSize: 15)),
            ],
            const SizedBox(height: 16),
            Center(child: DevicePill(status: s.status, loss: () => s.loss)),
            const SizedBox(height: 22),
            LiveDataCard(status: s.status, buffer: s.live, onTap: () => _open(ShellTab.live)),
            const SizedBox(height: 12),
            FutureBuilder<_RecordingLine>(
              future: _recording,
              initialData: _RecordingLine.loading,
              builder: (context, snap) {
                final line = snap.data!;
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  IntrinsicHeight(
                    child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(
                        child: DestinationTile(
                          icon: AppShell.tabs[ShellTab.history].icon,
                          label: 'History',
                          line: line.review,
                          onTap: () => _open(ShellTab.history),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DestinationTile(
                          icon: AppShell.tabs[ShellTab.reports].icon,
                          label: 'Reports',
                          line: 'PDF and CSV',
                          onTap: () => _open(ShellTab.reports),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  _RecordingChip(text: line.chip, onTap: _chooseRecording),
                  if (line.notice != null) ...[
                    const SizedBox(height: 8),
                    Text(line.notice!, style: const TextStyle(color: AppColors.warning, fontSize: 12)),
                  ],
                ]);
              },
            ),
            const SizedBox(height: 22),
            const Text(
              'Research prototype, not a medical device.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ]),
        ),
      ),
    );
  }
}

class _RecordingChip extends StatelessWidget {
  final String text;
  final VoidCallback onTap;

  const _RecordingChip({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            const Icon(Icons.folder_open_outlined, size: 18, color: AppColors.textSecondary),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
            const Icon(Icons.chevron_right, size: 18, color: AppColors.textSecondary),
          ]),
        ),
      ),
    );
  }
}
