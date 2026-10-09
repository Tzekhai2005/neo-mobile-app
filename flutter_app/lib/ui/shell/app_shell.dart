import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../data/data_page.dart';
import '../home/home_page.dart';
import '../orientation.dart';
import '../report/report_page.dart';
import 'tab_scope.dart';
import '../review/review_page.dart';
import '../widgets/status_strip.dart';

/// The app's one screen: Home, Live, History and Reports, with the tabs below and
/// (on every tab but Home, which has its own device card) the device strip on top.
///
/// The Live tab may be turned to landscape, where the strip and the tabs give way
/// to the lanes; every other page stays portrait.
class AppShell extends StatefulWidget {
  final int initialTab;

  /// The pages, in tab order. Defaults to the real pages, with a placeholder for
  /// any that is not built yet.
  final List<Widget>? pages;

  const AppShell({super.key, this.initialTab = 0, this.pages});

  static const tabs = [
    (label: 'Home', icon: Icons.home_outlined, selectedIcon: Icons.home),
    (label: 'Live', icon: Icons.monitor_heart_outlined, selectedIcon: Icons.monitor_heart),
    (label: 'History', icon: Icons.fact_check_outlined, selectedIcon: Icons.fact_check),
    (label: 'Reports', icon: Icons.description_outlined, selectedIcon: Icons.description),
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
    // Whatever replaces the shell starts upright.
    applyOrientationMode(OrientationMode.portraitOnly);
    super.dispose();
  }

  void _applyOrientation() =>
      applyOrientationMode(_tab == ShellTab.live ? OrientationMode.any : OrientationMode.portraitOnly);

  void _select(int i) {
    setState(() => _tab = i);
    _applyOrientation();
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final pages = widget.pages ??
        [
          HomePage(),
          const DataPage(),
          const ReviewPage(),
          const ReportPage(),
        ];
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape && _tab == ShellTab.live;
    final body = IndexedStack(
      index: _tab,
      children: [
        for (var i = 0; i < pages.length; i++) TabScope(index: i, selected: _tab, select: _select, child: pages[i]),
      ],
    );
    if (landscape) {
      // The lanes get the whole screen; the page carries its own way back.
      return Scaffold(body: SafeArea(child: body));
    }
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          if (_tab != ShellTab.home) StatusStrip(status: services.status),
          Expanded(child: body),
        ]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _select,
        destinations: [
          for (final t in AppShell.tabs)
            NavigationDestination(icon: Icon(t.icon), selectedIcon: Icon(t.selectedIcon), label: t.label),
        ],
      ),
    );
  }
}
