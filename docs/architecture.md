# How the app is put together

The app is Flutter (Dart), Android first. The data layer, the live data path, the report
and the export are built and tested. **The only screen is the old one** (`lib/ui/`); the
new pages (start page, Data, Review, Report) are not built, and have not been designed yet.

## The layers

```
 Neo device                                         (or the neo-fake simulator)
    │  UDP 5000: HELLO beacons, then EEG / IMU / STATUS / EVENT
    │  TCP 5001: commands and replies
    ▼
 protocol/   neo_proto.dart      packet framing, CRC, validation, stream deframer
             neo_messages.dart   typed decoders for every device→host packet
             neo_client.dart     discovery, handshake, state machine, loss detection
    │  Streams: messages, onInfo, onStateChanged, onDataStalledChanged
    ▼
 live/       LiveSignalBuffer    last 30 s of EEG (2–4 ch), accel, gyro, in µV / g / °/s
             LiveFeed            writes the client's packets into the buffer
 device/     DeviceStatusTracker one snapshot of link, battery, signal, button, warnings
    │
 data/       dataset*.dart       the recording format (docs/recording-format.md)
             StaticRecordingSource   overview + per-event windows from a recording
             ReviewStore         confirm / dismiss / note decisions, per recording
             DatasetLibrary      imports recording zips into the app's storage
 report/     ReportBuilder       recording + decisions → ReportData (numbers computed here)
             report_csv.dart     CSV text          report_pdf.dart   the PDF
             ReportExporter      writes the files and opens the share sheet
    ▲
 app/        AppServices         the one owner of all of the above (below)
             AppScope            hands AppServices to every page
 ui/         standalone_screen.dart   the old screen (reads the shared connection)
```

## One owner: `AppServices`

`AppServices` (`lib/app/app_services.dart`) is created once in `main()` and lives as long
as the app. It owns:

* the **single `NeoClient`**. The device accepts only one control connection, and the
  live stream must keep running while the user moves between pages, so no page may make
  its own. The owner also does the **auto-connect**: it connects to the first device that
  announces itself and reconnects whenever the link drops;
* the live buffers and the device status tracker, both fed from that one client;
* the review side: the loaded recording, the saved decisions, and the recording picker
  (`pickAndImportDataset`, `useDataset`, `removeDataset`);
* the report: `buildReport()` and the one-click `exportReport()`.

Pages ask for what they need with `AppScope.of(context)`. Where the platform has no app
storage folder (the web preview), review and report calls throw a plain `StateError`.

## The connection, in numbers

| Behaviour | Value |
|---|---|
| TCP connect timeout | 3 s |
| Wait for a command's reply (GET_INFO, START) | 1 s |
| "No data" flag raised (`dataStalled`) | after 0.9 s without data; link kept |
| Link dropped, and discovery restarted | after 3 s without data |
| Device announces itself | UDP broadcast once a second while no host is connected |

Closing the TCP connection tells the device to stop streaming and announce itself again,
which is how reconnecting works. The protocol is specified in the Neuravance repository
(`software/protocol/README.md`); the app implements it and is tested against that spec's
own test vectors.

## Where things are stored on the phone

Under the app's documents folder:

```
review_decisions.json     the reviewer's decisions (all recordings, kept apart by key)
datasets/<name>/          imported recordings;  datasets/selected.json = the one in use
reports/report-…/         exported PDFs and CSV zips
```

## Tests

| Command (in `flutter_app/`) | What it runs |
|---|---|
| `flutter test --concurrency=1 test` | everything, including the end-to-end tests below |
| `flutter test test/protocol_test.dart test/messages_test.dart test/data_test.dart test/live_signal_buffer_test.dart test/report_test.dart test/report_pdf_test.dart test/report_exporter_test.dart test/device_status_test.dart test/app_services_test.dart test/dataset_library_test.dart` | the unit tests; this is the list CI runs |
| `flutter test --concurrency=1 test/integration` | end-to-end runs against a real `neo-fake` process |

The integration tests need `neo-fake` on the PATH (`pip install -e` of the Neuravance
`software/protocol/python` package) and ports UDP 5000 and TCP 5001 free. They must run
**one at a time**, which `--concurrency=1` does. They cover discovery, the handshake, a
live stream, real packet loss, the no-data flag, the 3 s drop and automatic reconnect,
battery and button events, and exporting a report while streaming. The old screen is also
tested against live data.

Some tests run the Python tools in `tools/` (`python3` must be installed).

## What has never run

Everything above was tested on a Mac against the simulator. **Nothing has run on a real
phone or on the real hardware.** Not yet verified: the Android build with the share and
file-picker plugins (CI is its first compile), the share sheet, the file chooser, and
whether the phone receives the device's broadcast announcements.
