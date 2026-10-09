import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/config/app_config.dart';
import 'package:neo_companion/ui/theme/app_theme.dart';
import 'package:neo_companion/ui/widgets/brand_logo.dart';

void main() {
  test('the product is Epile-X by NeuraVance Labs', () {
    expect(kBrandName, 'Epile-X');
    expect(kBrandByline, 'by NeuraVance Labs');
  });

  test('the name on the phone\'s launcher is the brand name', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:label="$kBrandName"'));
  });

  test('the app\'s description names the product', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('Epile-X'));
  });

  group('the logo', () {
    Future<void> pump(WidgetTester t, Widget w) =>
        t.pumpWidget(MaterialApp(theme: buildAppTheme(), home: Scaffold(body: Center(child: w))));

    testWidgets('with no logo file it shows the name and the company line as text', (t) async {
      await pump(t, const BrandLogo(asset: ''));
      expect(find.text('Epile-X'), findsOneWidget);
      expect(find.text('by NeuraVance Labs'), findsOneWidget);
    });

    testWidgets('a logo that is missing falls back to the same text, not a broken picture', (t) async {
      await pump(t, const BrandLogo(asset: 'assets/brand/does_not_exist.png'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(find.text('Epile-X'), findsOneWidget);
      expect(find.text('by NeuraVance Labs'), findsOneWidget);
    });

    testWidgets('the real logo is announced by its name and company', (t) async {
      final handle = t.ensureSemantics();
      await pump(t, const BrandLogo());
      expect(find.bySemanticsLabel('Epile-X by NeuraVance Labs'), findsOneWidget);
      handle.dispose();
    });
  });
}
