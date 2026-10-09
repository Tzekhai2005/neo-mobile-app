import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../data/data_page.dart';
import '../orientation.dart';
import '../report/report_page.dart';
import 'tab_scope.dart';
import '../review/review_page.dart';
import '../widgets/status_strip.dart';

/// The three pages behind the start page, with the device strip on top and the
/// tabs below. The start page opens it on the tab that was tapped; the home icon
/// (or the name in the strip) goes back.
///
/// The Data tab may be turned to landscape, where the strip and the tabs give way
/// to the lanes; every other page stays portrait.
class AppShell extends StatefulWidget {
  final int initialTab;

  /// The pages, in tab order. Defaults to the real pages, with a placeholder for
  /// any that is not built yet.
  final List<Widget>? pages;

  const AppShell({super.key, this.initialTab = 0, this.pages});

  static const tabs = [
    (label: 'Data', icon: Icons.show_chart),
    (label: 'Review', icon: Icons.fact_check_outlined),
    (label: 'Report', icon: Icons.description_outlined),
  ];

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _tab = widget.initialTab;

  @override
  void initState() {
    super.initState();
    _applyOrientation();
  }

  @override
  void dispose() {
    // Back on the start page the phone stays upright.
    applyOrientationMode(OrientationMode.portraitOnly);
    super.dispose();
  }

  void _applyOrientation() =>
      applyOrientationMode(_tab == 0 ? OrientationMode.any : OrientationMode.portraitOnly);

  void _select(int i) {
    setState(() => _tab = i);
    _applyOrientation();
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final pages = widget.pages ??
        [
          const DataPage(),
          const ReviewPage(),
          const ReportPage(),
        ];
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape && _tab == 0;
    final body = IndexedStack(
      index: _tab,
      children: [
        for (var i = 0; i < pages.length; i++) TabScope(index: i, selected: _tab, child: pages[i]),
      ],
    );
    if (landscape) {
      // The lanes get the whole screen; the page carries its own way home.
      return Scaffold(body: SafeArea(child: body));
    }
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          StatusStrip(
            status: services.status,
            onHome: () => Navigator.of(context).popUntil((r) => r.isFirst),
          ),
          Expanded(child: body),
        ]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _select,
        destinations: [
          for (final t in AppShell.tabs) NavigationDestination(icon: Icon(t.icon), label: t.label),
        ],
      ),
    );
  }
}
