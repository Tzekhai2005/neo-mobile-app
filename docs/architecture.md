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
 ui/         theme/app_theme.dart     every colour in one place (the Epile-X palette)
             home/ shell/ widgets/    the start page, the three tabs and the device strip
             trace/                   the shared signal view (below)
             standalone_screen.dart   the old screen (no longer reachable; deleted when the new pages are done)
```

## The signal view (`ui/trace/`)

One component draws every signal in the app, so the live Data page and the Review event
view look and behave the same. It holds no state: it draws a `TraceData` it is given.

* `trace_sources.dart` turns a live snapshot (`liveTraceData`) or a stored event window
  (`windowTraceData`) into a `TraceData`: EEG lanes (2 to 4 channels), an accelerometer lane
  and a gyro lane, with the time labels, markers and the shaded event stretch.
* `signal_lanes.dart` draws it. Every trace is **clipped to its own lane** and a small
  arrow marks the edge it crossed; **lost samples are a visible gap** with a red band;
  markers, spans and time labels are laid over all lanes, and labels that would collide
  are stacked or thinned. Tapping a lane reports its index (for "expand this lane").
* `trace_math.dart` has the testable parts: baseline removal, per-pixel min/max so a
  spike never disappears when many samples share a pixel, overflow and gap detection.
* **Baseline removal is display only.** EEG lanes are high-passed at 0.5 Hz so a signal on
  a large electrode offset sits in its lane; motion lanes are not (gravity means something).
  The recorded and live data are never changed.
* EEG scales are 25, 50, 100, 200, 500 and 1000 µV from the middle of a lane to its edge;
  the motion scales are fixed (accelerometer ±2 g, gyro ±250 °/s).

## The Data page (`ui/data/`)

The live view, built on the signal view above. `DataViewController` turns the live buffer
into what is drawn a few times a second: the window (5, 10 or 15 s), the EEG scale (25 to
1000 µV), whether the motion lanes are open, and which lane is expanded.

* **Pause and look back.** Pausing freezes the view at that moment; dragging sideways then
  moves back through the 30 s the buffer holds, and the time labels say how far back. If
  the sample index starts over (a restart), the pause ends, because the frozen view would
  no longer mean anything. The buffer never returns overwritten samples for an old window:
  anything older than it holds reads as missing.
* **Landscape.** The Data tab may be turned; every other page stays upright. In landscape
  the device strip and the tabs give way to the lanes, with the controls in a thin bar and
  the readout beside the lanes, never over a trace. Tapping a lane expands it alone, in
  landscape; the cross brings it back.
* **Markers.** A device button press is drawn as "button". "Seizure now" marks the newest
  sample, together with the stream it belongs to (an index starts over on every restart, so
  a marker from an earlier stream is never drawn at a place that now means something else).
  These markers live in memory while the app is open; they are not saved and do not reach
  the Review page.
* **Experimental activity risk** (`live/activity_risk.dart`). A demonstration, **not a
  validated detector**. Once a second it measures how busy the EEG is (the mean step from one
  sample to the next, after the slow baseline is removed) and compares it with the wearer's own
  median over the last five minutes; that ratio becomes a number from 6 to 98 and is smoothed
  over about three seconds. It shows nothing while it learns the baseline (20 s), and nothing
  with a poor electrode contact or without data. While the wearer is moving (the
  accelerometer or gyro varies) the number is eased down and the baseline is not updated, so
  movement does not teach it that busy is normal. A real change in the signal, a loose
  electrode or a muscle artefact can all raise it. It has no alarm and never raises an event.
  `kShowExperimentalRisk` removes the whole readout, and an empty `kRiskExperimentalNote`
  hides only the small print.

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
| the `flutter test` line in `.github/workflows/build_apk.yml` | the unit and widget tests; this is the list CI runs |
| `flutter test --concurrency=1 test/integration` | end-to-end runs against a real `neo-fake` process |

The integration tests need `neo-fake` on the PATH (`pip install -e` of the Neuravance
`software/protocol/python` package) and ports UDP 5000 and TCP 5001 free. They must run
**one at a time**, which `--concurrency=1` does. They cover discovery, the handshake, a
live stream, real packet loss, the no-data flag, the 3 s drop and automatic reconnect,
battery and button events, and exporting a report while streaming. The old screen is also
tested against live data.

Some tests run the Python tools in `tools/` (`python3` must be installed).

## What has never run

Almost everything was tested on a Mac against the simulator. What has run on a real phone
with the real device: the Android build with the share and file-picker plugins compiles in
CI, and the phone found the device, connected, and drew EEG. **Not yet tried on a phone:**
the share sheet and the file chooser (no page calls them yet), and the new pages.
