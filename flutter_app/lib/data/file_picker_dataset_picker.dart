import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'dataset_picker.dart';

/// Opens the phone's file chooser through the file_picker plugin. This is the
/// only code that touches the plugin.
class FilePickerDatasetPicker implements DatasetPicker {
  const FilePickerDatasetPicker();

  @override
  Future<File?> pickZip() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Choose a recording (.zip)',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (picked == null) return null;

    // Android hands over a content address, not always a path, so copy the bytes
    // into the app's cache and read from there.
    final copy = File('${Directory.systemTemp.path}/picked-${DateTime.now().microsecondsSinceEpoch}.zip');
    final sink = copy.openWrite();
    try {
      await sink.addStream(picked.readAsByteStream());
    } finally {
      await sink.close();
    }
    return copy;
  }
}
