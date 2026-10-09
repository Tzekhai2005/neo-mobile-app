import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_companion/report/report_settings.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('neo_settings_');
    file = File('${dir.path}/sub/report_settings.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('no file is no label, and no error', () async {
    final s = ReportSettings(file);
    await s.load();
    expect(s.patientLabel, '');
  });

  test('a label is remembered by the next run', () async {
    final a = ReportSettings(file);
    await a.setPatientLabel('Subject 4092');
    final b = ReportSettings(file);
    await b.load();
    expect(b.patientLabel, 'Subject 4092');
  });

  test('it can be edited, and cleared', () async {
    final a = ReportSettings(file);
    await a.setPatientLabel('First');
    await a.setPatientLabel('Second');
    await a.setPatientLabel('');
    final b = ReportSettings(file);
    await b.load();
    expect(b.patientLabel, '');
  });

  test('spaces around it are dropped', () async {
    final a = ReportSettings(file);
    await a.setPatientLabel('   Subject 7  ');
    expect(a.patientLabel, 'Subject 7');
  });

  test('a unicode label survives', () async {
    final a = ReportSettings(file);
    await a.setPatientLabel('患者 ñ — Δ');
    final b = ReportSettings(file);
    await b.load();
    expect(b.patientLabel, '患者 ñ — Δ');
  });

  test('a damaged file is no settings and is not an error', () async {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('{ not json');
    final s = ReportSettings(file);
    await s.load();
    expect(s.patientLabel, '');
  });

  test('a file of the wrong shape is no settings', () async {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('[1, 2, 3]');
    final s = ReportSettings(file);
    await s.load();
    expect(s.patientLabel, '');
    file.writeAsStringSync('{"patientLabel": 5}');
    await s.load();
    expect(s.patientLabel, '');
  });

  test('leaves no half-written file behind', () async {
    final s = ReportSettings(file);
    await s.setPatientLabel('x');
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });

  test('if it cannot be saved the label still holds this session, and the error is thrown', () async {
    file.parent.createSync(recursive: true);
    Directory(file.path).createSync(); // a folder where the file should be
    final s = ReportSettings(file);
    await expectLater(s.setPatientLabel('held'), throwsA(anything));
    expect(s.patientLabel, 'held');
  });
}
