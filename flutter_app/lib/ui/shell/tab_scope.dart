import 'package:flutter/widgets.dart';

/// Tells a page in the shell whether its tab is the one on show. The tabs are kept
/// alive (so a page keeps its place when you leave and come back), which means a page
/// cannot tell from the framework that it is hidden; this does.
///
/// Outside a shell there is no scope, and a page counts as active.
class TabScope extends InheritedWidget {
  final int index;
  final int selected;

  const TabScope({super.key, required this.index, required this.selected, required super.child});

  bool get active => index == selected;

  /// Whether the page below is on show. Rebuilds the caller when that changes.
  static bool activeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TabScope>()?.active ?? true;

  @override
  bool updateShouldNotify(TabScope old) => old.active != active;
}
