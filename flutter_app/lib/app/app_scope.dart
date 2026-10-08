import 'package:flutter/widgets.dart';

import 'app_services.dart';

/// Makes the [AppServices] available to every page below it.
class AppScope extends InheritedWidget {
  final AppServices services;

  const AppScope({super.key, required this.services, required super.child});

  /// The services of the nearest [AppScope]; throws a clear error without one.
  static AppServices of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    if (scope == null) {
      throw FlutterError('AppScope.of() was called with a context that has no AppScope above it.\n'
          'Wrap the app in AppScope(services: ..., child: ...), as lib/main.dart does.');
    }
    return scope.services;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => services != oldWidget.services;
}
