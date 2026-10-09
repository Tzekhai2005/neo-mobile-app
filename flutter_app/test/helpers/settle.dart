import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Futures that wait on real file reads need real time, one step at a time, and a
/// busy spinner never lets pumpAndSettle finish. So give real time and pump in
/// small steps until nothing is spinning.
Future<void> settle(WidgetTester t, [int ms = 80]) async {
  await t.pump();
  final steps = ms;
  for (var i = 0; i < steps; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 4)));
    await t.pump(const Duration(milliseconds: 20));
    if (i >= steps ~/ 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await t.pumpAndSettle();
}
