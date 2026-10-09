import 'dart:convert';
import 'dart:io';

/// Small settings that belong to the report and outlast a run of the app. Today
/// that is the patient label: it is remembered between sessions, and can be edited.
class ReportSettings {
  final File file;
  String _patientLabel = '';

  ReportSettings(this.file);

  String get patientLabel => _patientLabel;

  /// Reads the file. A missing or unreadable file is no settings, never an error:
  /// the worst result is that the label has to be typed again.
  Future<void> load() async {
    try {
      if (!await file.exists()) return;
      final j = jsonDecode(await file.readAsString());
      if (j is Map<String, dynamic> && j['patientLabel'] is String) _patientLabel = j['patientLabel'] as String;
    } catch (_) {
      _patientLabel = '';
    }
  }

  /// Sets and saves the label, without surrounding spaces. If it cannot be saved the
  /// label still holds for this session and the error is thrown.
  Future<void> setPatientLabel(String label) async {
    _patientLabel = label.trim();
    final tmp = File('${file.path}.tmp');
    await file.parent.create(recursive: true);
    await tmp.writeAsString(jsonEncode({'version': 1, 'patientLabel': _patientLabel}), flush: true);
    await tmp.rename(file.path); // never a half-written file
  }
}
