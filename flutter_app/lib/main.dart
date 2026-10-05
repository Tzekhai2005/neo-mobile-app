import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ui/monitor_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const NeoCompanionApp());
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
        scaffoldBackgroundColor: const Color(0xFF070A12),
        primaryColor: const Color(0xFF00F2FE),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00F2FE),
          secondary: Color(0xFFA855F7),
          surface: Color(0xFF0D121E),
        ),
      ),
      home: const MonitorScreen(),
    );
  }
}
