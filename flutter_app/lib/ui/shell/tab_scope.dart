import 'package:flutter/widgets.dart';

/// The shell's tabs, in order.
abstract final class ShellTab {
  static const home = 0;
  static const live = 1;
  static const history = 2;
  static const reports = 3;
}

/// Tells a page in the shell whether its tab is the one on show. The tabs are kept
/// alive (so a page keeps its place when you leave and come back), which means a page
/// cannot tell from the framework that it is hidden; this does.
///
/// Outside a shell there is no scope, and a page counts as active.
class TabScope extends InheritedWidget {
  final int index;
  final int selected;

  /// Moves the shell to another tab; null where nothing can (tests).
  final ValueChanged<int>? select;

  const TabScope({super.key, required this.index, required this.selected, this.select, required super.child});

  bool get active => index == selected;

  /// Whether the page below is on show. Rebuilds the caller when that changes.
  static bool activeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<TabScope>()?.active ?? true;

  /// Switches the shell to tab [i]. Does nothing outside a shell.
  static void goTo(BuildContext context, int i) => context.getInheritedWidgetOfExactType<TabScope>()?.select?.call(i);

  @override
  bool updateShouldNotify(TabScope old) => old.active != active;
}
