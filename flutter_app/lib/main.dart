import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app_scope.dart';
import 'app/app_services.dart';
import 'config/app_config.dart';
import 'ui/home/home_page.dart';
import 'ui/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: AppColors.background,
    statusBarIconBrightness: Brightness.dark,
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
  const NeoCompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kBrandName,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const HomePage(),
    );
  }
}
