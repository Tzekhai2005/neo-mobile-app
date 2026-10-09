# How the app is put together

The app is Flutter (Dart), Android first. The data layer, the live data path, the report and the
export are built, and so are all four screens: Home and the Live, History and Reports
tabs. All of it is tested on a Mac; what has run on a real phone is listed at the end.

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
             home/ shell/ widgets/    Home, the four tabs and the device strip
             trace/ data/ review/ report/   the shared signal view and the three tab pages (below)
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
* **Landscape.** The Live tab may be turned; every other page stays upright. In landscape
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

## The Review page (`review/` and `ui/review/`)

Going through the events a recording holds. The logic is in `review/` and has no widgets, so
it is tested on its own; `ReviewController` is the state of the page.

* **Days.** One day or three, paged a day at a time (a day is 24 hours from the start of the
  recording, as in the report). Pinch zooms down to ten minutes, dragging slides, and a Reset
  zoom button returns. There is no double-tap: it would make every single tap wait to see
  whether a second one follows.
* **The timeline.** One mark per event at its real time, at least 4 px wide so a ten second
  event can be seen and tapped, and as tall as its score band (High tallest). Marks that would
  touch at the current zoom become one with a count; tapping it lists them. Patient button
  presses are a row of diamonds above. Hollow amber is unreviewed, green confirmed, grey
  dismissed. Red bands are stretches where the signal quality was too poor to use. "Show
  signal" puts the EEG envelope and the movement behind the marks; it is off by default,
  because a large swing in the signal is not the same as an event (blinks, chewing and a loose
  electrode make them too).
* **The list.** Patient markers are pinned in their own group, then the candidates ranked by
  score (ties in time order). A score is shown only as a band, High from 0.8, Medium from 0.4.
  The list follows the days on show; the "reviewed" progress counts every event.
* **An event.** A half-screen sheet that leaves the timeline above it, with the selected mark
  outlined: where it is in the list, when it happened, the stored 40 s of EEG, accelerometer
  and gyro on the shared signal view with the event's stretch shaded, a note, and Confirm and
  Dismiss pinned at the foot so they are never scrolled out of reach. Previous and Next walk
  the list. Decisions are written one at a time; if a write fails the screen says so and shows
  what is really saved (`ReviewStore` undoes the change in memory when its file cannot be
  written, so it never holds more than is on disk). A note is saved a moment after typing stops,
  when the field loses focus, and when the sheet moves on, always to the event it was typed on.
* The generator's ground-truth labels in the synthetic recording are never shown: they are not
  detections.

## The Report page (`report/` and `ui/report/`)

One tap to a report you have looked at before it leaves the phone.

* **Choosing.** Three presets: *Confirmed* (every confirmed event, or the top unreviewed
  candidates when nothing is confirmed yet, and the page says so), *All candidates* (every
  automatic event not dismissed) and *Markers* (patient presses). A tick box on every event,
  grouped by band (High, Medium, Low) and the patient markers, each group with its own box that
  is empty, half or full. A choice that is exactly a preset is shown as that preset; one made by
  hand is not. The fallback only ever counts as *Confirmed*, even if it happens to hold the same
  events as *All candidates*.
* **Days.** Pick the first and last day to cover (consecutive days, see
  `docs/report-and-quality.md`). A choice that was a preset follows the new days; a hand-made one
  keeps its ticks but only those inside the days count.
* **The patient label.** Remembered between sessions in `report_settings.json` and editable.
  Typing applies to the next report at once; saving it to storage waits for a pause in the typing,
  and happens quietly (it announces nothing) so it is safe as a page goes away.
* **Create, preview, share.** Create writes the PDF and the CSV zip, then pictures of the PDF's
  pages. The pictures come from the platform's own PDF renderer through the `printing` package,
  behind a `PdfPreviewer` interface so tests need no phone. Only the first 24 pages are pictured,
  and the page says so if there are more; if the renderer fails, the report is still saved and can
  be shared. Share opens the phone's share sheet with exactly the two files that were written.
  Nothing is shared until Share is pressed.
* The Report page re-reads the decisions each time its tab comes to the front, so what was
  confirmed on the Review page is there; a choice made by hand is left alone.

## Tabs and what they do when hidden (`ui/shell/tab_scope.dart`)

The four tabs are kept alive so each keeps its place, which means the framework does not tell a
page that it is hidden. `TabScope` does. The Data page does no work while another tab is on top
(it stops redrawing the live signal), and the Report page uses it to know when to re-read the
decisions.

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
battery and button events, exporting a report while streaming, the activity readout, and the
Home tab showing the real connection and battery.

Some tests run the Python tools in `tools/` (`python3` must be installed).

## What has never run

Almost everything was tested on a Mac against the simulator. What has run on a real phone
with the real device: the Android build with the share and file-picker plugins compiles in
CI, and the phone found the device, connected, and drew EEG. **Not yet tried on a phone:**
the share sheet and the file chooser (no page calls them yet), and the new pages.
