import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/ui/shell/tab_scope.dart';

class _Probe extends StatefulWidget {
  final List<bool> seen;
  const _Probe(this.seen);
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) {
    widget.seen.add(TabScope.activeOf(context));
    return const SizedBox();
  }
}

void main() {
  testWidgets('a page outside any shell counts as active', (t) async {
    final seen = <bool>[];
    await t.pumpWidget(Directionality(textDirection: TextDirection.ltr, child: _Probe(seen)));
    expect(seen.single, isTrue);
  });

  testWidgets('is active only when its tab is the selected one', (t) async {
    final seen = <bool>[];
    Widget app(int selected) => Directionality(
          textDirection: TextDirection.ltr,
          child: TabScope(index: 1, selected: selected, child: _Probe(seen)),
        );
    await t.pumpWidget(app(0));
    expect(seen.last, isFalse);
    await t.pumpWidget(app(1));
    expect(seen.last, isTrue);
    await t.pumpWidget(app(2));
    expect(seen.last, isFalse);
  });

  testWidgets('rebuilds its page when the tab changes, and not when something else does', (t) async {
    final seen = <bool>[];
    final probe = _Probe(seen); // one instance, so only a change in the scope can rebuild it
    Widget app(int selected) => Directionality(
          textDirection: TextDirection.ltr,
          child: TabScope(index: 0, selected: selected, child: probe),
        );
    await t.pumpWidget(app(0));
    final built = seen.length;
    await t.pumpWidget(app(0));
    expect(seen.length, built, reason: 'nothing changed for this page');
    await t.pumpWidget(app(1)); // another tab became selected: this page went inactive
    expect(seen.length, built + 1);
    await t.pumpWidget(app(2)); // still inactive: no change for this page
    expect(seen.length, built + 1);
  });
}
