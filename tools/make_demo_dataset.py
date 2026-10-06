#!/usr/bin/env python3
"""Generate the synthetic demo recording used by the Review page.

Output is a folder the app can load (see flutter_app/lib/data/):

    manifest.json   meta + candidate events
    overview.json   one bin per minute: EEG min/max, motion, signal quality
    windows.bin     full-rate signal window around every event (int16 LE, planar)

The data is SYNTHETIC. The manifest says so, and the event list is generator
ground truth with confidence scores, not the output of the app's detector.
To use a real recording instead, write a folder of the same shape and point
the app at it (see kDatasetLocation in lib/config/app_config.dart).

Standard library only. Deterministic for a given --seed.

    python3 tools/make_demo_dataset.py                      # 72 h -> flutter_app/assets/demo_recording
    python3 tools/make_demo_dataset.py --hours 1 --events 4 --out /tmp/mini
    python3 tools/make_demo_dataset.py --verify-only --out flutter_app/assets/demo_recording
"""
import argparse
import array
import datetime as dt
import json
import math
import os
import random
import sys

FORMAT_VERSION = 1
EEG_HZ = 250
IMU_HZ = 100
PRE_S = 15           # seconds stored before an event start
POST_S = 25          # seconds stored after an event start
BIN_S = 60
UV_PER_COUNT = 0.1                    # int16 -> +-3276 uV
G_PER_COUNT = 16.0 / 32768.0          # +-16 g, like the device INFO
DPS_PER_COUNT = 2000.0 / 32768.0      # +-2000 dps
CH_GAIN = [1.0, 0.85, 0.75, 0.65]     # relative amplitude per channel
MIN_GAP_S = 60.0                      # minimum spacing between event starts

# kind -> (duration range s, confidence range, night weight, overview extent uV)
KINDS = {
    "seizure-like": ((8.0, 18.0), (0.82, 0.98), 2.0, 165.0),
    "clench":       ((1.5, 4.0), (0.30, 0.62), 1.2, 85.0),
    "blink":        ((2.0, 2.0), (0.18, 0.40), 0.8, 125.0),
    "head-shake":   ((2.5, 4.0), (0.22, 0.52), 1.0, 65.0),
}
POSTICTAL_S = 6.0


def smoothstep(a, b, x):
    if x <= a:
        return 0.0
    if x >= b:
        return 1.0
    u = (x - a) / (b - a)
    return u * u * (3 - 2 * u)


def sleep_level(h):
    """0 awake .. 1 asleep, as a function of local hour."""
    if h >= 22:
        return smoothstep(22, 23, h)
    if h < 7:
        return 1.0
    if h < 8:
        return 1.0 - smoothstep(7, 8, h)
    return 0.0


def is_night(h):
    return h >= 23 or h < 7


class Clock:
    def __init__(self, start_utc, offset_min):
        local = start_utc + dt.timedelta(minutes=offset_min)
        self.start_local_s = local.hour * 3600 + local.minute * 60 + local.second

    def hour(self, t):
        return ((self.start_local_s + t) / 3600.0) % 24.0


# --------------------------------------------------------------------------- placement

def place_events(rng, clock, hours, n_auto, bad_segments):
    duration = hours * 3600.0
    lo, hi = PRE_S + 5.0, duration - POST_S - 5.0
    starts = []

    def free(t):
        if any(abs(t - s) < MIN_GAP_S for s in starts):
            return False
        return not any(a <= t <= b for a, b in bad_segments)

    def draw(night_weight):
        wmax = max(1.0, night_weight)
        for _ in range(20000):
            t = rng.uniform(lo, hi)
            w = night_weight if is_night(clock.hour(t)) else 1.0
            if rng.random() <= w / wmax and free(t):
                return t
        raise RuntimeError("could not place event; shorten --events or lengthen --hours")

    n_seizure = max(1, round(n_auto * 0.14))
    n_other = max(0, n_auto - n_seizure)
    kinds = ["seizure-like"] * n_seizure
    for i in range(n_other):
        kinds.append(["clench", "blink", "head-shake"][i % 3])
    events = []
    for kind in kinds:
        (dlo, dhi), (clo, chi), nw, _ = KINDS[kind]
        t = draw(nw)
        starts.append(t)
        events.append({
            "source": "auto", "truth": kind, "start_s": t,
            "dur_s": rng.uniform(dlo, dhi),
            "confidence": round(rng.uniform(clo, chi), 3),
        })

    # patient button presses: some right after a seizure-like event, some standalone
    n_markers = max(1, round(hours / 8.0))
    seizures = [e for e in events if e["truth"] == "seizure-like"]
    n_with = min(len(seizures), round(n_markers * 0.45))
    for e in rng.sample(seizures, n_with):
        events.append({"source": "patientButton", "truth": "patient-marker",
                       "start_s": e["start_s"] + rng.uniform(2.0, 8.0),
                       "dur_s": 0.0, "confidence": None})
    for _ in range(n_markers - n_with):
        t = draw(1.0)
        starts.append(t)
        events.append({"source": "patientButton", "truth": "patient-marker",
                       "start_s": t, "dur_s": 0.0, "confidence": None})

    events.sort(key=lambda e: e["start_s"])
    for i, e in enumerate(events):
        e["id"] = "e%04d" % (i + 1)
        e["start_sample"] = int(round(e["start_s"] * EEG_HZ))
        e["dur_samples"] = int(round(e["dur_s"] * EEG_HZ))
    return events


def place_bad_segments(rng, hours):
    duration = hours * 3600.0
    n = max(1, round(hours / 8.0))
    segs = []
    for _ in range(n * 50):
        if len(segs) >= n:
            break
        length = min(rng.uniform(8, 40) * 60.0, duration * 0.12)
        a = rng.uniform(0, duration - length)
        b = a + length
        if all(b + 600 < x or a - 600 > y for x, y in segs):
            segs.append((a, b))
    return sorted(segs)


# --------------------------------------------------------------------------- signals

def bell(x):
    return math.sin(math.pi * x) if 0.0 <= x <= 1.0 else 0.0


def seizure_eeg(tr, dur, amp):
    """3.x Hz spike-and-wave that slows down, then post-ictal slowing."""
    if 0.0 <= tr < dur:
        env = max(0.0, min(1.0, tr / 2.0, (dur - tr) / 2.0))
        phi = 2 * math.pi * (3.6 * tr - 0.4 * tr * tr / dur)
        return env * amp * (110.0 * math.sin(phi) ** 9 + 55.0 * math.sin(phi - 0.7))
    if dur <= tr < dur + POSTICTAL_S:
        k = tr - dur
        return 38.0 * math.exp(-k / 3.0) * math.sin(2 * math.pi * 1.5 * tr)
    return 0.0


def render_window(ev_list, ev, channels, seed, sleep, t0):
    """Planar int16 block for one event. t0 is the window start (absolute s)."""
    rng = random.Random("%s:window:%s" % (seed, ev["id"]))
    n_eeg = EEG_HZ * (PRE_S + POST_S)
    n_imu = IMU_HZ * (PRE_S + POST_S)
    ph = [[rng.uniform(0, 6.283) for _ in range(3)] for _ in range(channels)]
    near = [e for e in ev_list
            if e["truth"] != "patient-marker"
            and e["start_s"] - 5 < t0 + PRE_S + POST_S and e["start_s"] + e["dur_s"] + POSTICTAL_S + 5 > t0]
    for e in near:   # per-event random shape parameters, fixed for the whole run
        er = random.Random("%s:shape:%s" % (seed, e["id"]))
        e["_amp"] = er.uniform(0.8, 1.15)
        e["_emg"] = [[(er.uniform(22, 45), er.uniform(0, 6.283)) for _ in range(6)] for _ in range(4)]
        e["_blinks"] = [er.uniform(0.2, 0.6) for _ in range(3)]
        e["_blink_n"] = er.randint(1, 3)

    eeg = []
    alpha_amp = 14.0 * (1 - sleep) + 5.0 * sleep
    delta_amp = 4.0 * (1 - sleep) + 26.0 * sleep
    for c in range(channels):
        g = CH_GAIN[c]
        out = array.array("h")
        for k in range(n_eeg):
            t = t0 + k / EEG_HZ
            v = (alpha_amp * math.sin(2 * math.pi * 10.0 * t + ph[c][0])
                 + delta_amp * math.sin(2 * math.pi * 1.8 * t + ph[c][1])
                 + 5.0 * math.sin(2 * math.pi * 0.3 * t + ph[c][2])
                 + rng.gauss(0, 2.5))
            for e in near:
                tr = t - e["start_s"]
                d = e["dur_s"]
                kind = e["truth"]
                if kind == "seizure-like":
                    v += seizure_eeg(tr, d, e["_amp"]) * (1.0 if c == 0 else 0.9)
                elif kind == "clench" and 0 <= tr < d:
                    env = bell(tr / d)
                    emg = sum(math.sin(2 * math.pi * f * tr + p) for f, p in e["_emg"][c]) * 9.0
                    v += env * (emg + rng.gauss(0, 14.0)) * e["_amp"]
                elif kind == "blink":
                    for b in range(e["_blink_n"]):
                        tb = 0.4 + b * (0.5 + e["_blinks"][b])
                        v += (120.0 * math.exp(-((tr - tb) / 0.12) ** 2)
                              - 40.0 * math.exp(-((tr - tb - 0.25) / 0.2) ** 2))
                elif kind == "head-shake" and 0 <= tr < d:
                    v += bell(tr / d) * (35.0 * math.sin(2 * math.pi * 2.4 * tr + ph[c][0]) + rng.gauss(0, 6.0))
            out.append(max(-32768, min(32767, int(round(v * g / UV_PER_COUNT)))))
        eeg.append(out)

    imu = [array.array("h") for _ in range(6)]
    pa = [rng.uniform(0, 6.283) for _ in range(4)]
    for k in range(n_imu):
        t = t0 + k / IMU_HZ
        ax = 0.03 * math.sin(2 * math.pi * 0.07 * t + pa[0]) + rng.gauss(0, 0.002)
        ay = 0.02 * math.sin(2 * math.pi * 0.05 * t + pa[1]) + rng.gauss(0, 0.002)
        az = 0.995 + rng.gauss(0, 0.002)
        gx = 0.3 * math.sin(2 * math.pi * 0.2 * t + pa[2]) + rng.gauss(0, 0.5)
        gy = rng.gauss(0, 0.5)
        gz = 0.3 * math.sin(2 * math.pi * 0.15 * t + pa[3]) + rng.gauss(0, 0.5)
        for e in near:
            tr = t - e["start_s"]
            d = e["dur_s"]
            kind = e["truth"]
            if kind == "seizure-like" and 0 <= tr < d:
                env = max(0.0, min(1.0, tr / 2.0, (d - tr) / 2.0))
                w = math.sin(2 * math.pi * 3.2 * tr)
                ax += 0.10 * env * w
                ay += 0.07 * env * math.sin(2 * math.pi * 3.2 * tr + 1.0)
                az += 0.03 * env * w
                gx += 18.0 * env * w
                gy += 12.0 * env * math.sin(2 * math.pi * 3.2 * tr + 0.6)
            elif kind == "head-shake" and 0 <= tr < d:
                env = bell(tr / d)
                s = math.sin(2 * math.pi * 2.4 * tr)
                ax += 0.55 * env * s
                ay += 0.25 * env * math.sin(2 * math.pi * 2.4 * tr + 1.0)
                gx += 140.0 * env * s
                gz += 90.0 * env * math.sin(2 * math.pi * 2.4 * tr + 0.5)
            elif kind == "clench" and 0 <= tr < d:
                ax += rng.gauss(0, 0.01) * bell(tr / d)
        for i, (val, scale) in enumerate(((ax, G_PER_COUNT), (ay, G_PER_COUNT), (az, G_PER_COUNT),
                                          (gx, DPS_PER_COUNT), (gy, DPS_PER_COUNT), (gz, DPS_PER_COUNT))):
            imu[i].append(max(-32768, min(32767, int(round(val / scale)))))
    return eeg + imu


# --------------------------------------------------------------------------- overview

def build_overview(seed, clock, hours, channels, events, bad_segments):
    n = int(hours * 3600 // BIN_S)
    mn = [[0.0] * n for _ in range(channels)]
    mx = [[0.0] * n for _ in range(channels)]
    act = [0.0] * n
    qual = [1.0] * n
    for i in range(n):
        r = random.Random("%s:bin:%d" % (seed, i))
        s = sleep_level(clock.hour((i + 0.5) * BIN_S))
        base = 20.0 * (1 - s) + 46.0 * s
        jit = r.uniform(0.9, 1.12) * (1.5 if r.random() < 0.03 else 1.0)
        for c in range(channels):
            amp = base * jit * CH_GAIN[c] * r.uniform(0.95, 1.05)
            mn[c][i] = -amp * r.uniform(0.9, 1.0)
            mx[c][i] = amp * r.uniform(0.9, 1.0)
        act[i] = r.uniform(0.01, 0.08) if s > 0.5 else r.uniform(0.10, 0.45)
        qual[i] = r.uniform(0.9, 1.0)
    for a, b in bad_segments:
        r = random.Random("%s:bad:%d" % (seed, int(a)))
        flat = r.random() < 0.5
        for i in range(int(a // BIN_S), min(n, int(b // BIN_S) + 1)):
            qual[i] = r.uniform(0.05, 0.3)
            for c in range(channels):
                ext = r.uniform(1, 4) if flat else r.uniform(100, 180)
                mn[c][i], mx[c][i] = -ext, ext
            act[i] = r.uniform(0.0, 0.1)
    for e in events:
        if e["truth"] == "patient-marker":
            continue
        ext = KINDS[e["truth"]][3]
        tail = POSTICTAL_S if e["truth"] == "seizure-like" else 0.0
        for i in range(int(e["start_s"] // BIN_S), min(n, int((e["start_s"] + e["dur_s"] + tail) // BIN_S) + 1)):
            for c in range(channels):
                mx[c][i] = max(mx[c][i], ext * CH_GAIN[c])
                mn[c][i] = min(mn[c][i], -ext * CH_GAIN[c])
            act[i] = max(act[i], {"head-shake": 0.9, "seizure-like": 0.55}.get(e["truth"], act[i]))
    rnd = lambda xs: [round(x, 1) for x in xs]
    return {
        "binSec": BIN_S, "bins": n,
        "eegMin": [rnd(x) for x in mn], "eegMax": [rnd(x) for x in mx],
        "activity": [round(x, 3) for x in act], "quality": [round(x, 3) for x in qual],
    }


# --------------------------------------------------------------------------- generate / verify

def generate(args):
    start_utc = dt.datetime.strptime(args.start_utc, "%Y-%m-%dT%H:%M:%SZ")
    clock = Clock(start_utc, args.utc_offset)
    rng = random.Random(args.seed)
    bad = place_bad_segments(rng, args.hours)
    events = place_events(rng, clock, args.hours, args.events, bad)
    overview = build_overview(args.seed, clock, args.hours, args.channels, events, bad)

    os.makedirs(args.out, exist_ok=True)
    records = []
    offset = 0
    with open(os.path.join(args.out, "windows.bin"), "wb") as f:
        for e in events:
            t0 = e["start_s"] - PRE_S
            sleep = sleep_level(clock.hour(e["start_s"]))
            for block in render_window(events, e, args.channels, args.seed, sleep, t0):
                if sys.byteorder == "big":
                    block.byteswap()
                f.write(block.tobytes())
            length = (args.channels * EEG_HZ + 6 * IMU_HZ) * (PRE_S + POST_S) * 2
            first, last = int(e["start_s"] // BIN_S), int((e["start_s"] + e["dur_s"]) // BIN_S)
            q = sum(overview["quality"][first:last + 1]) / (last - first + 1)
            records.append({
                "id": e["id"],
                "source": e["source"],
                "startSample": e["start_sample"],
                "durationSamples": e["dur_samples"],
                "confidence": e["confidence"],
                "channels": [] if e["source"] == "patientButton" else list(range(args.channels)),
                "quality": round(q, 3),
                "truth": e["truth"],
                "window": {"offset": offset, "length": length, "preSec": PRE_S, "postSec": POST_S},
            })
            offset += length

    manifest = {
        "formatVersion": FORMAT_VERSION,
        "synthetic": True,
        "generator": "tools/make_demo_dataset.py",
        "seed": args.seed,
        "startUtc": args.start_utc,
        "utcOffsetMinutes": args.utc_offset,
        "durationSec": int(args.hours * 3600),
        "eeg": {"rateHz": EEG_HZ, "channels": args.channels, "uvPerCount": UV_PER_COUNT},
        "imu": {"rateHz": IMU_HZ, "gPerCount": G_PER_COUNT, "dpsPerCount": DPS_PER_COUNT},
        "events": records,
    }
    with open(os.path.join(args.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    with open(os.path.join(args.out, "overview.json"), "w") as f:
        json.dump(overview, f, separators=(",", ":"))


def verify(out):
    def check(cond, msg):
        if not cond:
            raise AssertionError(msg)

    with open(os.path.join(out, "manifest.json")) as f:
        m = json.load(f)
    with open(os.path.join(out, "overview.json")) as f:
        ov = json.load(f)
    size = os.path.getsize(os.path.join(out, "windows.bin"))
    ch = m["eeg"]["channels"]
    check(m["formatVersion"] == FORMAT_VERSION, "formatVersion")
    check(2 <= ch <= 4, "channels must be 2..4")
    n_bins = m["durationSec"] // ov["binSec"]
    check(ov["bins"] == n_bins, "overview bins")
    for key in ("activity", "quality"):
        check(len(ov[key]) == n_bins, key + " length")
    for key in ("eegMin", "eegMax"):
        check(len(ov[key]) == ch and all(len(a) == n_bins for a in ov[key]), key + " shape")
    check(all(ov["eegMin"][c][i] <= ov["eegMax"][c][i] for c in range(ch) for i in range(n_bins)), "min<=max")
    check(all(0.0 <= q <= 1.0 for q in ov["quality"]), "quality range")

    ids, last, off = set(), -1, 0
    eeg_n = m["eeg"]["rateHz"] * (PRE_S + POST_S)
    imu_n = m["imu"]["rateHz"] * (PRE_S + POST_S)
    want_len = (ch * eeg_n + 6 * imu_n) * 2
    counts = {}
    night_seizure = [0, 0]
    with open(os.path.join(out, "windows.bin"), "rb") as wf:
        for e in m["events"]:
            check(e["id"] not in ids, "duplicate id " + e["id"])
            ids.add(e["id"])
            check(e["startSample"] >= last, "events not sorted")
            last = e["startSample"]
            check(0 <= e["startSample"] < m["durationSec"] * m["eeg"]["rateHz"], "start out of range")
            w = e["window"]
            check(w["offset"] == off and w["length"] == want_len, "window layout " + e["id"])
            off += w["length"]
            if e["source"] == "auto":
                check(e["confidence"] is not None and 0 <= e["confidence"] <= 1, "confidence " + e["id"])
                b = int(e["startSample"] / m["eeg"]["rateHz"] // ov["binSec"])
                check(ov["quality"][b] >= 0.5, "auto event inside a low-quality segment " + e["id"])
            else:
                check(e["confidence"] is None, "marker confidence " + e["id"])
            counts[e["truth"]] = counts.get(e["truth"], 0) + 1
            if e["truth"] == "seizure-like":
                wf.seek(w["offset"])
                a = array.array("h")
                a.frombytes(wf.read(w["length"]))
                if sys.byteorder == "big":
                    a.byteswap()
                s0 = PRE_S * m["eeg"]["rateHz"]
                seg = a[s0:s0 + max(1, e["durationSamples"])]
                ptp = (max(seg) - min(seg)) * m["eeg"]["uvPerCount"]
                check(ptp > 150.0, "seizure-like window too quiet (%.0f uV) %s" % (ptp, e["id"]))
                local = (start_hour(m) + e["startSample"] / m["eeg"]["rateHz"] / 3600.0) % 24
                night_seizure[1] += 1
                night_seizure[0] += 1 if is_night(local) else 0
    check(off == size, "windows.bin size %d != %d" % (size, off))
    print("OK  %s  %.1f MB windows, %d events %s, %d/%d seizure-like at night"
          % (out, size / 1e6, len(m["events"]), counts, night_seizure[0], night_seizure[1]))


def start_hour(m):
    t = dt.datetime.strptime(m["startUtc"], "%Y-%m-%dT%H:%M:%SZ") + dt.timedelta(minutes=m["utcOffsetMinutes"])
    return t.hour + t.minute / 60.0 + t.second / 3600.0


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=os.path.join(here, "..", "flutter_app", "assets", "demo_recording"))
    ap.add_argument("--hours", type=float, default=72.0)
    ap.add_argument("--events", type=int, default=110, help="number of automatic candidate events")
    ap.add_argument("--channels", type=int, default=2, choices=[2, 3, 4])
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--start-utc", default="2026-10-05T00:00:00Z", help="recording start (UTC)")
    ap.add_argument("--utc-offset", type=int, default=480, help="local offset in minutes (480 = UTC+8)")
    ap.add_argument("--verify-only", action="store_true", help="check an existing folder, generate nothing")
    args = ap.parse_args()
    if not args.verify_only:
        generate(args)
    verify(args.out)


if __name__ == "__main__":
    main()
