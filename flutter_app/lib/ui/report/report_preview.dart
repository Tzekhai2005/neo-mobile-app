import 'package:flutter/material.dart';

import '../../report/report_controller.dart';
import '../../report/report_selection.dart';
import '../theme/app_theme.dart';

/// A finished report: what it holds, pictures of its pages, and Share.
class ReportPreview extends StatelessWidget {
  final ReportController controller;
  const ReportPreview({super.key, required this.controller});

  static String _name(String path) => path.split(RegExp(r'[\\/]')).last;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final out = c.exported!;
    final covered = c.builtDays == null ? 'All days' : _daysText(c.builtDays!);
    return Column(children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppColors.border)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: const BoxDecoration(color: Color(0xFFDDF3E8), shape: BoxShape.circle),
                  child: const Icon(Icons.check, color: AppColors.success),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Report ready', key: ValueKey('report-ready'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      [
                        '${c.eventsInReport} ${c.eventsInReport == 1 ? 'event' : 'events'}',
                        covered,
                        if (c.pageCount > 0) '${c.pageCount} ${c.pageCount == 1 ? 'page' : 'pages'}',
                      ].join(' · '),
                      key: const ValueKey('report-summary'),
                      style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 8),
                    Text(_name(out.pdf.path), style: const TextStyle(fontSize: 12)),
                    Text('${_name(out.csvZip.path)} · ${out.csvFileCount} CSV files', style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 4),
                    const Text("Saved in the app's reports folder", style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 14),
            if (c.previewFailed)
              Container(
                key: const ValueKey('preview-unavailable'),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: AppColors.surfaceSoft, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.border)),
                child: const Text(
                  "A preview isn't available on this device. The report is saved and can still be shared.",
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              )
            else ...[
              for (var i = 0; i < c.pages.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: GestureDetector(
                    key: ValueKey('page-$i'),
                    onTap: () => _open(context, i),
                    child: Container(
                      decoration: BoxDecoration(color: Colors.white, border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(6)),
                      child: AspectRatio(aspectRatio: c.pages[i].aspect, child: Image.memory(c.pages[i].png, fit: BoxFit.fill, gaplessPlayback: true)),
                    ),
                  ),
                ),
              if (c.pageCount > c.pages.length)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Showing the first ${c.pages.length} of ${c.pageCount} pages. The PDF has all of them.',
                    key: const ValueKey('preview-truncated'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ),
            ],
          ],
        ),
      ),
      DecoratedBox(
        decoration: const BoxDecoration(color: AppColors.background, border: Border(top: BorderSide(color: AppColors.border))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (c.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(c.error!, key: const ValueKey('report-error'), style: const TextStyle(color: AppColors.danger, fontSize: 13)),
              ),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('share'),
                  style: FilledButton.styleFrom(backgroundColor: AppColors.navy, foregroundColor: AppColors.onNavy, minimumSize: const Size(0, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  onPressed: c.isSharing ? null : c.share,
                  icon: c.isSharing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.ios_share, size: 18),
                  label: const Text('Share', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton(
                key: const ValueKey('create-another'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                onPressed: c.createAnother,
                child: const Text('Create another'),
              ),
            ]),
          ]),
        ),
      ),
    ]);
  }

  static String _daysText(DayRange d) => d.first == d.last ? 'Day ${d.first + 1}' : 'Days ${d.first + 1} to ${d.last + 1}';

  void _open(BuildContext context, int i) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog.fullscreen(
        child: Stack(children: [
          Positioned.fill(
            child: InteractiveViewer(
              key: const ValueKey('page-viewer'),
              minScale: 1,
              maxScale: 5,
              child: Center(child: Image.memory(controller.pages[i].png, fit: BoxFit.contain)),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: SafeArea(child: IconButton.filledTonal(key: const ValueKey('close-viewer'), onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close))),
          ),
        ]),
      ),
    );
  }
}
