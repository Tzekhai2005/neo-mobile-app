# The report, its exports, and where every number comes from

The report is built from a **recording** (see [recording-format.md](recording-format.md))
plus the reviewer's decisions. Every number in it is computed from that data; none is
typed in. Where a number cannot be known, the report says "not measured" instead of
guessing.

## What one export produces

`AppServices.exportReport()` writes a new folder in the app's storage and, by default,
opens the phone's share sheet with the two files in it:

```
reports/report-20261007-093000/            (named from the time it was generated)
├── neuravance-eeg-report-20261005.pdf     the report (dated by the recording start)
└── neuravance-eeg-report-20261005-data.zip
    └── csv/
        ├── events.csv                     one row per event in the report
        ├── e0009_eeg.csv                  full-rate EEG around that event
        ├── e0009_motion.csv               accelerometer and gyro around that event
        └── …                              two files for every event in the report
```

### Which events go in

The default, "one click" selection is **every confirmed event**. If nothing has been
confirmed yet, it is the **five highest-confidence automatic candidates that were not
dismissed**, and the report says so ("No event had been confirmed, so these are the
highest-confidence unreviewed candidates"). A reviewer can change the selection by hand.
The summary and the overview figure always describe the **whole** recording, whatever is
selected.

## The PDF

A4, four pages for a typical report:

1. **Page 1: the summary.** Title and period; patient, recording length and time zone,
   device, signals and generation time; eight figures (recorded, usable signal, candidate
   events, confirmed, high confidence, not yet reviewed, dismissed, patient button
   presses); a per-day table; signal quality; and the **overview figure**: the whole
   recording on one time axis, showing the EEG's quietest-to-loudest range, night bands
   (23:00 to 07:00 local), low-quality stretches, one bar per candidate (height =
   confidence, red from 0.80), a dot on the ones included in the report, and a diamond
   for each patient button press.
2. **Event pages, two to a page.** One block per event, kept together: time, confidence,
   quality, the reviewer's note, EEG for every channel on one shared scale (with a scale
   bar), accelerometer, gyro, and a shared time axis in seconds from the event start.
3. **Last page: method and limitations**, the disclaimer, and a "Reviewed by / Date" line.

Every page carries the disclaimer ("Research prototype. Not a medical device and not for
clinical use…"). A synthetic recording adds a red **SAMPLE RECORDING** banner to every
page. Signals are shown as recorded, in microvolts, g and degrees per second, with no
filtering.

**Fonts.** Text is set in **Noto Sans** (SIL Open Font Licence; the licence is
`flutter_app/assets/fonts/OFL.txt`), embedded in the PDF so it looks the same in every
viewer. Noto Sans covers Latin (including Malay and Vietnamese), Greek and Cyrillic, so
accents, `µ` and `°` are fine. It does **not** cover Chinese, Japanese, Korean, Arabic,
Tamil or Thai: a character the font lacks prints as `?` rather than vanishing. A note is
cut at 230 characters in the PDF, with "(shortened, full note in events.csv)"; the CSV
always has the full text.

## The CSV files

`events.csv`

| Column | Meaning |
|---|---|
| `event_id` | The event's id |
| `source` | `auto`, `patientButton` or `manual` |
| `status` | `candidate` (not reviewed), `confirmed` or `dismissed` |
| `start_local` | Local clock time with its offset, e.g. `2026-10-05T08:03:12+08:00` |
| `start_sec`, `duration_sec` | Seconds from the start of the recording |
| `confidence` | `0` to `1` for automatic events; empty for a button press |
| `night` | `yes` if the start is between 23:00 and 07:00 local |
| `quality` | `0` to `1`, signal quality around the event |
| `channels` | EEG channels involved, **numbered from 1**, separated by spaces (the recording format counts from 0) |
| `note` | The reviewer's note, quoted correctly if it has commas, quotes or line breaks |

`<id>_eeg.csv`: `sample_index`, `t_rel_s`, `ch1_uV`, `ch2_uV` … (as many channels as the
recording has), one row per EEG sample. `<id>_motion.csv`: `imu_index`, `t_rel_s`, `ax_g`,
`ay_g`, `az_g`, `gx_dps`, `gy_dps`, `gz_dps`, one row per motion sample. In both,
`t_rel_s` is seconds **relative to the event start** (negative before it, `0` at the
start). The two sensors run at different rates, so they get separate files.

## Where each number comes from

| In the report | Comes from |
|---|---|
| Recording length, start and end, time zone | `manifest.json`: `durationSec`, `startUtc`, `utcOffsetMinutes` |
| Candidate events, high-confidence (≥ 0.80) | Events with `source: auto` in the manifest; `confidence` is **supplied with the recording** |
| Confirmed, dismissed, not yet reviewed, notes | The reviewer's decisions in the app (stored apart from the recording) |
| Day and night counts | The event's local start time; night is 23:00 to 07:00 |
| Per-day table | Consecutive 24-hour blocks counted from the recording start |
| Usable signal %, low-quality stretches | The overview's `quality` bins: below 0.5 is unusable. **Supplied with the recording**; the app does not measure it from the signal |
| Patient button presses | Events with `source: patientButton` |
| Event signals | `windows.bin`, converted to physical units with the manifest's scales |
| Device name, serial, firmware | Only when the caller passes them in. A stored recording does not carry them, so the demo report shows "not recorded" |
| Patient | Only when the caller passes a label; otherwise "not recorded" |
| Link loss %, electrode lead-off % | **Not measured for a stored recording.** See below |

## Link loss and lead-off: what is measured, and what is not yet

**For a stored recording these two numbers do not exist**, so the report says "Link loss
and electrode lead-off were not measured for this recording." The report model has the
two fields, but nothing fills them yet, because no part of the app records a whole live
session to storage. Below is what the live side already knows and how it knows it.

### Lost samples: calculated from real packets, not simulated

While streaming, `LiveSignalBuffer` (`flutter_app/lib/live/live_signal_buffer.dart`)
compares the **sample index in the header of each EEG packet that actually arrived**. The
device counts every sample it takes, so if packet N ends at index 499 and the next one
starts at 520, 20 samples are missing. The buffer counts them (`eegSamplesLost`), leaves a
gap in the graph, and takes them back off the count if a late packet fills the gap.
`eegSamplesLost ÷ (eegSamplesReceived + eegSamplesLost)` is the share of missing samples.

That is arithmetic on received packets; the app simulates nothing. (In tests, the device
simulator `neo-fake` has a `drop N` cue that builds N packets and then does not send
them. That simulates a lost network packet so the counting can be tested; the counting
itself is the same for real hardware.)

### Link loss and device loss, told apart

The protocol (README section 3) says: a gap in the sample index means samples were lost
**on the device** (its buffer overran), and a gap in the packet counter `seq` means
packets were lost **on the network link**. A lost network packet leaves both gaps; a
device overrun leaves only the index gap.

The app uses both:

* `NeoClient` follows `seq` on every UDP data packet (`SeqTracker`, restarted at each
  START) and tags each packet with how many packets went missing just before it. The
  total is `linkPacketsLost`, and it is exact.
* `LiveSignalBuffer` sorts each missing-sample gap by cause. Samples missing **with** a
  `seq` gap are link loss (`eegSamplesLostLink`); samples missing **with no** `seq` gap
  are device loss (`eegSamplesLostDevice`). The same holds for the IMU. The first packet
  after a loss is often a STATUS or IMU packet, not the next EEG one, so the buffer
  carries the `seq` gap forward until the next EEG packet.
* `SignalLoss` (`AppServices.loss`) gathers all of it in one place, with percentages
  that are `null` (not 0) before anything was expected. It also carries the device's own
  `pkts_dropped` and `eeg_overruns` from STATUS, which are totals since boot and so are
  not comparable with the per-stream counts.

The split is an **estimate**, with one known limit: `seq` counts packets of every type,
so when a gap exists the buffer cannot know whether the lost packets were EEG. It assumes
they could have been and caps the link share at the number of missing samples; whatever
is left is device loss. If only IMU packets are lost, no EEG sample is missing and
nothing is counted as EEG link loss. The exact numbers are `linkPacketsLost` (packets)
and the sample counts in total (`eegSamplesLost`).

`neo-fake`'s `drop N` spends a `seq` number on each dropped packet, so it exercises link
loss. It has no cue for a device-side overrun, so device loss is covered by unit tests.

### Lead-off

Each EEG sample carries a lead-off byte from the device's front end: bits 0 to 3 are the
four electrode inputs, bit 4 the reference electrode. `DeviceStatus.leadOff` is `true`
while any electrode input reports off the skin. A **percentage over time** needs a
session recorder to accumulate it, which does not exist yet.

### To get these numbers into a report

1. Add a recorder that stores a live session in the recording format.
2. Accumulate `SignalLoss` (link and device loss) and lead-off time during the session.
3. Write them into the manifest as optional fields, and let the report read them.

An imported real recording could carry the same optional fields if its converter wrote
them.
