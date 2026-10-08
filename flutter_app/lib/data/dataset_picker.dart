import 'dart:io';

/// Lets the user choose a recording zip. The real one opens the phone's file
/// chooser; tests use a fake.
abstract class DatasetPicker {
  /// The chosen zip as a readable local file, or null if the user cancelled.
  Future<File?> pickZip();
}
