#!/usr/bin/env python3
"""Write a recording the app can import, from your own signal arrays.

This is the reference for "how do I make my own recording". The file format is
described in docs/recording-format.md; this script is the same thing as code, and
its output is checked by the app's own importer in the test suite.

Use write_recording() from your own converter (EDF, CSV, a lab export ...):
give it the full-rate signals and your event list, and it writes manifest.json,
overview.json and windows.bin. Run the script as it is to get a tiny example:

    python3 tools/write_recording_example.py --out /tmp/example --zip /tmp/example.zip

Standard library only.
"""
import argparse
import array
import json
import math
import os
import random
import sys
import zipfile


def _int16(values, scale):
    """Physical values -> int16 counts (value / scale), clamped to the int16 range."""
    out = array.array("h", (max(-32768, min(32767, int(round(v / scale)))) for v in values))
    if sys.byteorder == "big":
        out.byteswap()
    return out


def write_recording(
    out_dir,
    *,
    start_utc,              # "2026-10-05T00:00:00Z": when sample 0 was recorded (UTC)
    utc_offset_minutes,     # local time at the recording site, e.g. 480 for UTC+8
    eeg_rate_hz,            # EEG samples per second
    imu_rate_hz,            # accelerometer / gyro samples per second
    eeg_uv,                 # EEG: one list per channel (2 to 4), the whole recording, in microvolts
    accel_g,                # [ax, ay, az]: three lists, the whole recording, in g
    gyro_dps,               # [gx, gy, gz]: three lists, the whole recording, in degrees per second
    events,                 # list of dicts, see below
    quality=None,           # optional list, one value per bin, 0..1 (1 = clean); default all clean
    uv_per_count=0.1,       # storage resolution of the EEG windows (must fit +-3276 uV at the default)
    g_per_count=16.0 / 32768.0,
    dps_per_count=2000.0 / 32768.0,
    pre_sec=15,             # stored before each event start
    post_sec=25,            # stored after each event start
    bin_sec=60,             # overview resolution
    synthetic=False,
    generator="write_recording_example.py",
):
    """Write manifest.json, overview.json and windows.bin into out_dir.

    Each event is a dict with:
        id            unique text, e.g. "e0001"
        source        "auto" (found by software), "patientButton" or "manual"
        start_sec     seconds from the start of the recording
        duration_sec  0 for a button press
        confidence    0..1 for "auto"; None for the other sources
        channels      EEG channels involved, 0-based, e.g. [0, 1]; [] for a button press
        quality       0..1, signal quality around the event
    Every event must lie at least pre_sec after the start and post_sec before the end,
    because a window of signal around it is stored.
    """
    channels = len(eeg_uv)
    if not 2 <= channels <= 4:
        raise ValueError("a recording has 2 to 4 EEG channels")
    n_eeg = len(eeg_uv[0])
    n_imu = len(accel_g[0])
    if any(len(c) != n_eeg for c in eeg_uv) or any(len(c) != n_imu for c in list(accel_g) + list(gyro_dps)):
        raise ValueError("all EEG channels must have the same length, and all motion axes too")
    duration = int(n_eeg / eeg_rate_hz)
    bins = duration // bin_sec
    if bins < 1:
        raise ValueError("the recording is shorter than one overview bin")
    os.makedirs(out_dir, exist_ok=True)

    # overview.json: per bin, the quietest and loudest EEG sample, movement, and quality
    eeg_min = [[0.0] * bins for _ in range(channels)]
    eeg_max = [[0.0] * bins for _ in range(channels)]
    activity = [0.0] * bins
    for b in range(bins):
        lo, hi = b * bin_sec * eeg_rate_hz, (b + 1) * bin_sec * eeg_rate_hz
        for c in range(channels):
            seg = eeg_uv[c][lo:hi]
            eeg_min[c][b], eeg_max[c][b] = round(min(seg), 1), round(max(seg), 1)
        ilo, ihi = b * bin_sec * imu_rate_hz, (b + 1) * bin_sec * imu_rate_hz
        dev = [abs(math.sqrt(accel_g[0][i] ** 2 + accel_g[1][i] ** 2 + accel_g[2][i] ** 2) - 1.0) for i in range(ilo, ihi)]
        activity[b] = round(min(1.0, 2.0 * sum(dev) / len(dev)), 3)  # 0 = still; the app only draws it
    q = list(quality) if quality is not None else [1.0] * bins
    if len(q) != bins:
        raise ValueError("quality needs one value per bin (%d)" % bins)
    overview = {"binSec": bin_sec, "bins": bins, "eegMin": eeg_min, "eegMax": eeg_max,
                "activity": activity, "quality": [round(x, 3) for x in q]}

    # windows.bin: for each event, int16 little-endian and planar:
    # EEG channel 0..N-1, then accel x, y, z, then gyro x, y, z
    eeg_n = int(eeg_rate_hz * (pre_sec + post_sec))
    imu_n = int(imu_rate_hz * (pre_sec + post_sec))
    length = (channels * eeg_n + 6 * imu_n) * 2
    records, offset = [], 0
    with open(os.path.join(out_dir, "windows.bin"), "wb") as f:
        for ev in sorted(events, key=lambda e: e["start_sec"]):
            if ev["start_sec"] < pre_sec or ev["start_sec"] + post_sec > duration:
                raise ValueError("event %s is too close to the start or end of the recording" % ev["id"])
            e0 = int(round((ev["start_sec"] - pre_sec) * eeg_rate_hz))
            i0 = int(round((ev["start_sec"] - pre_sec) * imu_rate_hz))
            for c in range(channels):
                f.write(_int16(eeg_uv[c][e0:e0 + eeg_n], uv_per_count).tobytes())
            for axis in list(accel_g):
                f.write(_int16(axis[i0:i0 + imu_n], g_per_count).tobytes())
            for axis in list(gyro_dps):
                f.write(_int16(axis[i0:i0 + imu_n], dps_per_count).tobytes())
            records.append({
                "id": ev["id"],
                "source": ev["source"],
                "startSample": int(round(ev["start_sec"] * eeg_rate_hz)),
                "durationSamples": int(round(ev["duration_sec"] * eeg_rate_hz)),
                "confidence": ev["confidence"],
                "channels": ev["channels"],
                "quality": ev["quality"],
                "window": {"offset": offset, "length": length, "preSec": pre_sec, "postSec": post_sec},
            })
            offset += length

    manifest = {
        "formatVersion": 1,
        "synthetic": synthetic,
        "generator": generator,
        "seed": 0,
        "startUtc": start_utc,
        "utcOffsetMinutes": utc_offset_minutes,
        "durationSec": duration,
        "eeg": {"rateHz": eeg_rate_hz, "channels": channels, "uvPerCount": uv_per_count},
        "imu": {"rateHz": imu_rate_hz, "gPerCount": g_per_count, "dpsPerCount": dps_per_count},
        "events": records,
    }
    with open(os.path.join(out_dir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    with open(os.path.join(out_dir, "overview.json"), "w") as f:
        json.dump(overview, f, separators=(",", ":"))


def write_zip(folder, zip_path):
    """The three files at the top level of a zip: what the app's recording picker imports."""
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for name in ("manifest.json", "overview.json", "windows.bin"):
            z.write(os.path.join(folder, name), arcname=name)


def _example(minutes=10, eeg_rate=250, imu_rate=100):
    """A tiny made-up recording: two EEG channels, still head, two events."""
    rng = random.Random(1)
    n_eeg, n_imu = minutes * 60 * eeg_rate, minutes * 60 * imu_rate
    eeg = [[14 * math.sin(2 * math.pi * 10 * k / eeg_rate + c) + rng.gauss(0, 3) for k in range(n_eeg)] for c in range(2)]
    accel = [[rng.gauss(0, 0.002) for _ in range(n_imu)], [rng.gauss(0, 0.002) for _ in range(n_imu)],
             [1.0 + rng.gauss(0, 0.002) for _ in range(n_imu)]]
    gyro = [[rng.gauss(0, 0.5) for _ in range(n_imu)] for _ in range(3)]
    events = [
        {"id": "e0001", "source": "auto", "start_sec": 120, "duration_sec": 8, "confidence": 0.91,
         "channels": [0, 1], "quality": 0.97},
        {"id": "e0002", "source": "patientButton", "start_sec": 400, "duration_sec": 0, "confidence": None,
         "channels": [], "quality": 1.0},
    ]
    return dict(start_utc="2026-10-05T00:00:00Z", utc_offset_minutes=480, eeg_rate_hz=eeg_rate, imu_rate_hz=imu_rate,
                eeg_uv=eeg, accel_g=accel, gyro_dps=gyro, events=events, synthetic=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="folder to write the three files into")
    ap.add_argument("--zip", metavar="FILE", help="also write a zip the app's picker can import")
    args = ap.parse_args()
    write_recording(args.out, **_example())
    print("wrote", args.out)
    if args.zip:
        write_zip(args.out, args.zip)
        print("zip:", args.zip)


if __name__ == "__main__":
    main()
