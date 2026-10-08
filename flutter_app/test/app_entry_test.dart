import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/app/app_scope.dart';
import 'package:neo_companion/app/app_services.dart';
import 'package:neo_companion/data/dataset_readers.dart';
import 'package:neo_companion/main.dart';
import 'package:neo_companion/protocol/neo_client.dart';
import 'package:neo_companion/ui/home/home_page.dart';
import 'package:neo_companion/ui/standalone_screen.dart';

void main() {
  testWidgets('the app opens on the new start page, not the old screen', (t) async {
    final dir = Directory.systemTemp.createTempSync('neo_entry_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final s = AppServices(client: NeoClient(), dataDir: dir, reader: DirectoryDatasetReader('test/fixtures/mini_recording'));
    addTearDown(s.dispose);
    t.view.physicalSize = const Size(780, 1600);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);

    // The same widget main() hands to runApp.
    await t.pumpWidget(AppScope(services: s, child: const NeoCompanionApp()));
    await t.pump(const Duration(milliseconds: 100));

    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(StandaloneScreen), findsNothing);
    expect(find.text('Live data'), findsOneWidget, reason: 'the new start page\'s main card');
  });
}
