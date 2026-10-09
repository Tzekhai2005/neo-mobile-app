# Epile-X by NeuraVance Labs: companion app

Epile-X is a Flutter app (Android first) for the **Neo ear-EEG** device. It finds the device on Wi-Fi,
streams EEG and motion data, lets a reviewer go through the events found in a long
recording, and produces a clinic-style PDF report with CSV data. This is a **research
prototype, not a medical device**.

## Where things stand

| | |
|---|---|
| **Built and tested** (on a Mac, against the `neo-fake` simulator) | Finding the device and talking the Neo protocol; every device packet decoded; automatic reconnect and a no-data flag; live buffers for 2 to 4 EEG channels plus accelerometer and gyro; device status (battery, signal, button, warnings); the recording format and its importer; review decisions (confirm, dismiss, note); the report (summary, PDF in Noto Sans, CSV zip) and its export |
| **Built, never tried on a phone** | The Android build with the share and file-picker plugins (CI compiles it first); the share sheet; the file chooser; whether the phone hears the device's broadcast announcements |
| **Built, tested on a Mac** | The start page, the three tabs, and the **Data page**: live EEG (2 to 4 channels), accelerometer and gyro, a 5, 10 or 15 s window, scales to 1000 µV, pause and scroll back through 30 s, tap a lane to expand it, landscape, "Seizure now" markers, and an experimental activity-risk readout |
| **Built, tested on a Mac** | The **Review page**: a compressed timeline of one or three days (an event mark at its real time, as tall as its score band, patient presses in a row above, optional EEG and movement behind), pinch to zoom, ranked candidates with the patient markers kept apart, filters, and a half-screen sheet for any event with its stored signal, a note, and Confirm or Dismiss |
| **Built, tested on a Mac** | The **Report page**: choose events by preset or tick box (grouped by band, with a box for each whole band), choose which days to cover, a patient label that is remembered, then Create report, look at the real PDF pages in the app, and Share |
| **Not built** | A PDF preview that has been tried on a phone (it uses the platform's PDF renderer, which only a phone can check); recording a live session to storage; link-loss and lead-off percentages in the report (they need that recorder); background recording; non-Latin text beyond Greek and Cyrillic in the PDF |

The demo recording is **synthetic** (made up by a script), and says so in every report. The
product name and the company line ("Epile-X", "by NeuraVance Labs") are set in
`flutter_app/lib/config/app_config.dart`; the name on the phone's launcher is in
`flutter_app/android/app/src/main/AndroidManifest.xml`, and a test keeps the two the same.

## Documentation

* [docs/architecture.md](docs/architecture.md): the layers, the one object that owns the
  connection, timings, storage, and the tests.
* [docs/recording-format.md](docs/recording-format.md): the **recording zip** you can import
  (`manifest.json`, `overview.json`, `windows.bin`), field by field, and how to make one.
* [docs/report-and-quality.md](docs/report-and-quality.md): what the report and the CSV
  files contain, and **where every number comes from**, including link loss and lead-off.

## Quick start

You need Flutter (3.47 or newer) and Python 3. Everything below runs from the repository root.

```bash
cd flutter_app
flutter pub get
flutter analyze
flutter test --concurrency=1 test        # all tests (the end-to-end ones need neo-fake, see below)
```

Tests that need no hardware and no simulator are the ones CI runs; see
[docs/architecture.md](docs/architecture.md#tests) for the exact list.

### Without hardware: the simulator

The Neuravance repository has `neo-fake`, a device simulator that speaks the real protocol
over real sockets. Install its Python package (`software/protocol/python`, `pip install -e`),
make sure UDP 5000 and TCP 5001 are free, then:

```bash
cd flutter_app
flutter test --concurrency=1 test/integration
```

These runs connect the real client to `neo-fake` and check the live data, packet loss,
reconnecting, battery and button events, and exporting a report while streaming.

### A sample report

```bash
cd flutter_app
dart --packages=.dart_tool/package_config.json tool/make_sample_report.dart \
     assets/demo_recording build/sample_report --demo-review
```

writes a PDF and a folder of CSV files into `build/sample_report/`. `--demo-review`
confirms a few events and adds example notes first (made up); leave it off to see the
"unreviewed candidates" report. `--builtin-fonts` uses the standard PDF fonts instead of Noto Sans.

### Your own recording

A recording is one zip. Make one from your own data with
[`tools/write_recording_example.py`](tools/write_recording_example.py), or a synthetic one:

```bash
python3 tools/make_demo_dataset.py --hours 24 --events 40 --out /tmp/rec --zip my_recording.zip
```

In the app, the recording picker imports the zip into the app's own storage and remembers
the choice. The format and the importer's safety rules are in
[docs/recording-format.md](docs/recording-format.md).

### On a phone

There is no Android SDK on the development Mac, so the APK is built by CI: push to GitHub
and take `neo-companion-android-apk` from the workflow run
(`.github/workflows/build_apk.yml`: it runs the unit tests first, then builds).

To look at the screen without a phone, run it as a web app from a *copy* of `flutter_app`
(`flutter create --platforms=web .`, then `flutter run -d web-server`). A browser cannot
open the raw network sockets the device needs, so it will always show "Disconnected".

## Repository map

```
flutter_app/
  lib/protocol/   the Neo protocol: framing, decoders, the client
  lib/live/       live signal buffers          lib/device/   device status
  lib/data/       recording format, importer, review decisions
  lib/report/     report model, CSV, PDF, export, fonts
  lib/app/        AppServices (the one owner) and AppScope
  lib/review/     the Review page's logic       lib/ui/   every page, the theme and the shared signal view
  assets/         demo_recording/ (synthetic), fonts/ (Noto Sans) and brand/ (the logo)
  test/           unit tests; test/integration/ needs neo-fake
  tool/           make_sample_report.dart
tools/            make_demo_dataset.py, write_recording_example.py
docs/             the documents above
stage_companion/  OLD Python web companion; not used by the app, not maintained
```

## Third-party

The report is set in **Noto Sans** (`flutter_app/assets/fonts/`), licensed under the SIL
Open Font License 1.1; the licence text is `flutter_app/assets/fonts/OFL.txt`.
