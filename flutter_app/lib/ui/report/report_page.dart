import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../report/report_controller.dart';
import '../shell/tab_scope.dart';
import '../theme/app_theme.dart';
import 'report_form.dart';
import 'report_preview.dart';

/// One-tap report: choose the events and days, create, look at the pages, share.
class ReportPage extends StatefulWidget {
  const ReportPage({super.key});

  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  ReportController? _c;
  bool _wasActive = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c == null) {
      _c = ReportController(AppScope.of(context))..load();
    }
    // The tabs are kept alive; when this one comes back to the front the decisions
    // made on the Review page in the meantime are read again.
    final active = TabScope.activeOf(context);
    if (active && !_wasActive) _c!.refreshEvents();
    _wasActive = active;
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c!;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => switch (c.stage) {
        ReportStage.loading => const Center(child: CircularProgressIndicator()),
        ReportStage.unavailable => Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.description_outlined, size: 40, color: AppColors.textMuted),
                const SizedBox(height: 12),
                Text(c.message ?? '', key: const ValueKey('report-message'), textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textSecondary)),
              ]),
            ),
          ),
        ReportStage.editing => _Editing(controller: c),
        ReportStage.building => const _Building(),
        ReportStage.ready => ReportPreview(controller: c),
      },
    );
  }
}

class _Editing extends StatelessWidget {
  final ReportController controller;
  const _Editing({required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Column(children: [
      Expanded(child: ReportForm(controller: c)),
      DecoratedBox(
        decoration: const BoxDecoration(color: AppColors.background, border: Border(top: BorderSide(color: AppColors.border))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('create-report'),
                style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: AppColors.onAccent, minimumSize: const Size(0, 50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                onPressed: c.create,
                child: const Text('Create report', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              c.selectedCount == 0
                  ? 'Nothing is chosen, so the report will hold only the summary.'
                  : (c.info.synthetic ? 'PDF and CSV data. This recording is synthetic, and the report says so.' : 'PDF and CSV data, ready to share.'),
              key: const ValueKey('create-hint'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ]),
        ),
      ),
    ]);
  }
}

class _Building extends StatelessWidget {
  const _Building();

  @override
  Widget build(BuildContext context) => const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Building the report…', key: ValueKey('building'), style: TextStyle(fontSize: 15)),
        ]),
      );
}
