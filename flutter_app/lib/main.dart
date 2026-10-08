import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app_scope.dart';
import 'app/app_services.dart';
import 'ui/standalone_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Color(0xFF090c15),
    statusBarIconBrightness: Brightness.light,
  ));

  // Review decisions and exported reports live in the app's own folder. Where the
  // platform has none (the web preview), the services still run without it.
  Directory? dataDir;
  try {
    dataDir = await getApplicationDocumentsDirectory();
  } catch (_) {
    dataDir = null;
  }

  // One owner of the device connection, live data, status and review/report for
  // the whole life of the app; pages get it from AppScope.
  final services = AppServices(dataDir: dataDir);
  await services.start();
  runApp(AppScope(services: services, child: const NeoCompanionApp()));
}

class NeoCompanionApp extends StatelessWidget {
  const NeoCompanionApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Neo Ear-EEG',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF090c15),
        primaryColor: const Color(0xFF00b4d8),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00b4d8),
          secondary: Color(0xFFA855F7),
          surface: Color(0xFF0f1422),
        ),
      ),
      home: const StandaloneScreen(),
    );
  }
}
