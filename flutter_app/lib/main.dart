import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ui/webview_shell.dart';

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
        scaffoldBackgroundColor: const Color(0xFF090c15),
        primaryColor: const Color(0xFF00b4d8),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00b4d8),
          secondary: Color(0xFFA855F7),
          surface: Color(0xFF0f1422),
        ),
      ),
      home: const WebViewShell(),
    );
  }
}
