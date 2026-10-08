# Recording format

A **recording** is what the Review page shows and what the Report is made from: a long
stretch of EEG and motion data with a list of events found in it. The app can import
one as a single **zip file**; this page describes that zip and the three files in it.

The demo recording bundled with the app uses exactly this format
(`flutter_app/assets/demo_recording/`), and it is **synthetic**: made up by
`tools/make_demo_dataset.py`, not a real person. Its manifest says so.

## The zip

```
my_recording.zip
├── manifest.json      what the recording is, and its events
├── overview.json      one summary bin per minute, for the long timeline
└── windows.bin        full-rate signals around every event
```

The three files may sit at the top of the zip or inside **one** folder. Anything else in
the zip (a readme, `__MACOSX/`, `._*` files) is ignored.

What the importer enforces (`flutter_app/lib/data/dataset_library.dart`):

| Rule | Why |
|---|---|
| Only these three file names are ever written to disk, under names the app chooses | A zip cannot place a file anywhere else |
| An entry whose path contains `..` makes the whole zip refused | That is corruption or an attack |
| The zip, and the unpacked files together, are at most 256 MB | Keeps a phone from running out of memory |
| All three files must be present, once each, in the same folder | Prevents mixing two recordings |
| The recording must load with the app's real loader (below) | A bad recording is refused at import, not when you open it |
| A failed import leaves nothing behind | No half-imported folders |

An imported recording is kept in the app's own storage, `datasets/<name>/`, where `<name>`
is the zip's file name made safe (`My Study (1).zip` becomes `my-study-1`; a repeat gets
`-2`, `-3`). The recording in use is remembered across restarts. If the saved recording
later cannot be opened, the app falls back to the demo and shows a notice.

### Making a recording zip

* **From your own signals:** `tools/write_recording_example.py` has a
  `write_recording()` function that takes full-rate arrays and an event list and writes the
  three files. Run the script as it is for a tiny working example:
  `python3 tools/write_recording_example.py --out /tmp/example --zip /tmp/example.zip`.
  The test suite imports its output with the app's real importer.
* **Synthetic, for demos:** `python3 tools/make_demo_dataset.py --out /tmp/rec --zip my.zip`
  (see `--help`; `--hours`, `--events`, `--channels`, `--seed`).
* **Check a folder:** `python3 tools/make_demo_dataset.py --verify-only --out /tmp/rec`.

## manifest.json

```json
{
  "formatVersion": 1,
  "synthetic": true,
  "generator": "tools/make_demo_dataset.py",
  "seed": 7,
  "startUtc": "2026-10-05T00:00:00Z",
  "utcOffsetMinutes": 480,
  "durationSec": 259200,
  "eeg": { "rateHz": 250, "channels": 2, "uvPerCount": 0.1 },
  "imu": { "rateHz": 100, "gPerCount": 0.00048828125, "dpsPerCount": 0.06103515625 },
  "events": [ ... ]
}
```

| Field | Meaning |
|---|---|
| `formatVersion` | Must be `1`. The app refuses any other version, so a future format cannot be misread |
| `synthetic` | `true` for made-up data. The report then carries a "sample recording" banner on every page |
| `generator`, `seed` | Free text and a number. With `startUtc`, `durationSec` and the event count they identify the recording (see "Review decisions") |
| `startUtc` | When sample 0 was recorded, in UTC, `YYYY-MM-DDTHH:MM:SSZ` |
| `utcOffsetMinutes` | Local time at the recording site relative to UTC (`480` = UTC+08:00). Used to show clock times and to decide what is "night" (23:00 to 07:00 local) |
| `durationSec` | Length of the recording in whole seconds |
| `eeg.rateHz` | EEG samples per second (the device sends 250) |
| `eeg.channels` | **2 to 4** EEG channels |
| `eeg.uvPerCount` | Microvolts per stored count in `windows.bin` |
| `imu.rateHz` | Accelerometer and gyro samples per second (the device sends 100) |
| `imu.gPerCount`, `imu.dpsPerCount` | g per count (accelerometer) and degrees per second per count (gyro) |
| `events` | The event list (below). The app sorts it by start |

### An event

```json
{
  "id": "e0001",
  "source": "auto",
  "startSample": 20114,
  "durationSamples": 663,
  "confidence": 0.329,
  "channels": [0, 1],
  "quality": 0.904,
  "truth": "head-shake",
  "window": { "offset": 0, "length": 88000, "preSec": 15, "postSec": 25 }
}
```

| Field | Meaning |
|---|---|
| `id` | Unique within the recording |
| `source` | `auto` (found by software), `patientButton` (the wearer pressed the button) or `manual` |
| `startSample` | EEG sample index of the event start, counted from the start of the recording. Seconds = `startSample / eeg.rateHz` |
| `durationSamples` | Length in EEG samples; `0` for a button press |
| `confidence` | `0` to `1` for `auto`; `null` for the other sources. It ranks events; it is a score, not a probability |
| `channels` | EEG channels involved, **0-based**; `[]` for a button press |
| `quality` | `0` to `1`, signal quality around the event |
| `truth` | Optional. Ground truth of **synthetic** data (what the generator drew). Ignored by the app and never shown as a detection |
| `window` | Where this event's signals sit in `windows.bin` (below) |

## overview.json

One bin per `binSec` seconds (60 in the demo), covering the whole recording. This is what
the compressed 1-day and 3-day views draw.

```json
{ "binSec": 60, "bins": 4320,
  "eegMin": [[...], [...]], "eegMax": [[...], [...]],
  "activity": [...], "quality": [...] }
```

| Field | Meaning |
|---|---|
| `bins` | Must equal `durationSec` divided by `binSec` (rounded down) |
| `eegMin`, `eegMax` | One list per EEG channel, `bins` long: the lowest and highest EEG value in the bin, in microvolts |
| `activity` | `bins` long, `0` to `1`: how much the head moved. The app only draws it |
| `quality` | `bins` long, `0` to `1`: signal quality. **Below 0.5 counts as unusable** and is shown as a low-quality stretch on the report's overview figure; the report's "usable signal" percentage is the share of bins at or above 0.5 |

`quality` and `activity` are **supplied by whoever made the recording**; the app does not
compute them from the signal.

## windows.bin

For every event, in the order they appear in the manifest, a block of 16-bit signed
integers, **little-endian**, laid out **one signal after another**:

```
EEG channel 0   ( eegN samples )
EEG channel 1   ( eegN samples )     … up to channel 3
accel x         ( imuN samples )
accel y
accel z
gyro x
gyro y
gyro z
```

where `eegN = rateHz × (preSec + postSec)` for EEG and `imuN` is the same with the motion
rate. The window starts `preSec` seconds before the event start, so the event begins
`preSec` seconds into the block.

Values are stored as counts and converted with the scales in the manifest:
microvolts = count × `eeg.uvPerCount`; g = count × `imu.gPerCount`; degrees per second =
count × `imu.dpsPerCount`. With the demo's `0.1 µV` per count the EEG range is
±3276.8 µV.

The block length is fixed by the manifest, so `window.length` must equal
`(channels × eegN + 6 × imuN) × 2` bytes. For the demo, 2 channels, 250 Hz and 100 Hz, a
15 s + 25 s window: `eegN = 10000`, `imuN = 4000`, so `(2 × 10000 + 6 × 4000) × 2 =
88,000` bytes per event. Blocks follow each other, so each `window.offset` is the sum of
the lengths before it.

## What the app checks when it opens a recording

`Dataset.load` (`flutter_app/lib/data/dataset.dart`) refuses a recording unless:

* `formatVersion` is `1` and `eeg.channels` is 2 to 4;
* `overview.json` has `bins = durationSec ÷ binSec`, one `eegMin`/`eegMax` list per
  channel, and `activity` and `quality` of exactly `bins` values;
* event ids are unique;
* every `window.length` matches the formula above, and every window lies inside `windows.bin`.

The importer runs the same check, so a recording that imports will open.

## Review decisions

A reviewer's confirm, dismiss and note decisions are saved apart from the recording, per
recording, keyed by `generator | seed | startUtc | durationSec | event count`. Importing the
same recording again brings its decisions back; a different recording, even one that reuses
the event ids `e0001`, `e0002`…, never inherits them.

## Limits to know

* Only the event windows are stored at full rate. You can zoom from the overview into an
  event; you cannot zoom to an arbitrary time.
* A recording holds one continuous stretch of time.
* Roughly 88 KB per event at the demo's rates; a 3-day recording with about 120 events is
  about 10 MB.
