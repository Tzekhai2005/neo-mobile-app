import 'package:flutter/services.dart';

/// Which way the phone may be turned.
enum OrientationMode { portraitOnly, any, landscapeOnly }

typedef OrientationSetter = Future<void> Function(List<DeviceOrientation> orientations);

/// How the app tells the system which orientations are allowed. Tests replace it.
OrientationSetter setPreferredOrientations = SystemChrome.setPreferredOrientations;

List<DeviceOrientation> orientationsFor(OrientationMode m) => switch (m) {
      OrientationMode.portraitOnly => const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
      OrientationMode.any => DeviceOrientation.values,
      OrientationMode.landscapeOnly => const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
    };

Future<void> applyOrientationMode(OrientationMode m) => setPreferredOrientations(orientationsFor(m));
