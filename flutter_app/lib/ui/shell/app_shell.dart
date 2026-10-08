import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../pages/placeholder_page.dart';
import '../widgets/status_strip.dart';

/// The three pages behind the start page, with the device strip on top and the
/// tabs below. The start page opens it on the tab that was tapped; the home icon
/// (or the name in the strip) goes back.
class AppShell extends StatefulWidget {
  final int initialTab;

  /// The pages, in tab order. Defaults to placeholders until each page is built.
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
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final pages = widget.pages ??
        [for (final t in AppShell.tabs) PlaceholderPage(title: t.label, icon: t.icon)];
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          StatusStrip(
            status: services.status,
            onHome: () => Navigator.of(context).popUntil((r) => r.isFirst),
          ),
          Expanded(child: IndexedStack(index: _tab, children: pages)),
        ]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          for (final t in AppShell.tabs) NavigationDestination(icon: Icon(t.icon), label: t.label),
        ],
      ),
    );
  }
}
