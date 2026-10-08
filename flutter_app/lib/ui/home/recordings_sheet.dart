import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../data/dataset_library.dart';
import '../format.dart';
import '../theme/app_theme.dart';

/// The list behind the recording chip: the built-in demo, the recordings the
/// user imported, and a way to import another zip. Switching changes what Review
/// and Report read; review decisions are kept separately for each recording.
class RecordingsSheet extends StatefulWidget {
  final AppServices services;

  const RecordingsSheet({super.key, required this.services});

  @override
  State<RecordingsSheet> createState() => _RecordingsSheetState();
}

class _RecordingsSheetState extends State<RecordingsSheet> {
  late Future<List<DatasetSummary>> _list;
  String? _error;
  bool _busy = false;

  AppServices get _s => widget.services;
  bool get _canImport => _s.library != null;

  @override
  void initState() {
    super.initState();
    _list = _load();
  }

  Future<List<DatasetSummary>> _load() => _canImport ? _s.listDatasets() : Future.value(const []);

  void _refresh() {
    final next = _load();
    setState(() {
      _list = next;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on DatasetImportException catch (e) {
      _error = e.message;
    } on StateError {
      _error = "Recordings can't be used on this device.";
    } catch (_) {
      _error = 'Something went wrong. Try again.';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _refresh();
  }

  Future<void> _use(String? name) async {
    if (name == _s.currentDataset) return;
    await _run(() => _s.useDataset(name));
  }

  Future<void> _import() => _run(() async {
        await _s.pickAndImportDataset(); // null when the chooser is cancelled
      });

  Future<void> _remove(DatasetSummary d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove ${d.name}?'),
        content: const Text('The recording is deleted from this phone. Your review decisions for it stay saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) await _run(() => _s.removeDataset(d.name));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: FutureBuilder<List<DatasetSummary>>(
          future: _list,
          builder: (context, snap) {
            final imported = snap.data ?? const <DatasetSummary>[];
            final current = _s.currentDataset;
            return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Recordings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              _RecordingRow(
                title: 'Demo recording',
                subtitle: 'Built in · synthetic demonstration data',
                selected: current == null,
                onTap: _busy ? null : () => _use(null),
              ),
              for (final d in imported)
                _RecordingRow(
                  title: d.name,
                  subtitle: [
                    'Imported',
                    if (d.synthetic) 'synthetic',
                    durationText(d.durationSec),
                    plural(d.eventCount, 'event'),
                    sizeText(d.sizeBytes),
                  ].join(' · '),
                  selected: current == d.name,
                  onTap: _busy ? null : () => _use(d.name),
                  onRemove: _busy ? null : () => _remove(d),
                ),
              const SizedBox(height: 8),
              if (_canImport)
                OutlinedButton.icon(
                  onPressed: _busy ? null : _import,
                  icon: _busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.file_upload_outlined),
                  label: const Text('Import a recording zip'),
                )
              else
                const Text("Importing isn't available on this device.",
                    style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
              ],
              const SizedBox(height: 12),
              const Text(
                'Review decisions are kept for each recording, so switching never mixes them up.',
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

class _RecordingRow extends StatelessWidget {
  final String title, subtitle;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  const _RecordingRow({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? AppColors.accent.withValues(alpha: 0.14) : AppColors.surfaceHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: selected ? AppColors.accent : AppColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(children: [
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 20, color: selected ? AppColors.accent : AppColors.textSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ]),
              ),
              if (onRemove != null)
                TextButton(onPressed: onRemove, child: const Text('Remove')),
            ]),
          ),
        ),
      ),
    );
  }
}
