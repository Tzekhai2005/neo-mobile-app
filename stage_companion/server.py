#!/usr/bin/env python3
"""
Neo Ear-EEG Stage Companion Server
Connects directly to 'neo-fake' (or real hardware) over TCP 5001 / UDP 5000.
If neo-fake is not running, falls back to the built-in Stage Simulator.
"""

import http.server
import json
import math
import os
import random
import select
import socket
import struct
import subprocess
import sys
import threading
import time

PORT_HTTP = 8080
PORT_UDP_DATA = 5000
PORT_TCP_CTRL = 5001

MAGIC = b"NV"
VERSION = 0

TYPE_EEG = 0x01
TYPE_IMU = 0x03
TYPE_STATUS = 0x10
TYPE_EVENT = 0x11
TYPE_CMD = 0x20
TYPE_ACK = 0x21

CMD_GET_INFO = 0x01
CMD_START = 0x10
CMD_STOP = 0x11

def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= (b << 8)
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc

def make_cmd_frame(cmd_id: int, params: bytes = b"", seq: int = 1) -> bytes:
    payload = bytes([cmd_id]) + params
    hdr = struct.pack("<2sBBBBIIQ", MAGIC, VERSION, TYPE_CMD, 0xFF, 0, seq, 0, 0)
    body = hdr + payload
    crc = crc16(body)
    pkt = body + struct.pack("<H", crc)
    return struct.pack("<H", len(pkt)) + pkt

class SharedState:
    def __init__(self):
        self.lock = threading.Lock()
        self.source_mode = "SIMULATOR"  # "NEO_FAKE" or "SIMULATOR"
        self.sample_idx = 0
        self.battery_pct = 92
        self.battery_mv = 3980
        self.lead_off = 0
        self.uv_per_count = 0.04808
        self.spikes_detected = 0
        
        # Seizure Demo
        self.seizure_active = False
        self.seizure_start_t = 0.0
        self.seizure_duration = 0.0
        self.seizure_risk = 7

state = SharedState()
clients = set()
clients_lock = threading.Lock()

def broadcast_sse(event_type: str, data: dict):
    payload = f"event: {event_type}\ndata: {json.dumps(data)}\n\n".encode("utf-8")
    with clients_lock:
        dead = []
        for wfile in list(clients):
            try:
                wfile.write(payload)
                wfile.flush()
            except Exception:
                dead.append(wfile)
        for d in dead:
            clients.discard(d)

class NeoFakeBridge(threading.Thread):
    """Monitors and connects to neo-fake on TCP 5001 / UDP 5000."""
    def __init__(self):
        super().__init__(daemon=True)

    def run(self):
        while True:
            # Check if neo-fake is listening on localhost:5001
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(1.5)
                sock.connect(("127.0.0.1", PORT_TCP_CTRL))
                print("\n[+] SUCCESS: Connected to neo-fake on TCP port 5001!")
                state.source_mode = "NEO_FAKE"

                # Setup UDP socket to receive EEG packets
                udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                udp.bind(("127.0.0.1", PORT_UDP_DATA))
                udp.settimeout(1.0)

                # Send GET_INFO
                sock.sendall(make_cmd_frame(CMD_GET_INFO, b"", seq=1))
                time.sleep(0.05)

                # Send START: udp_port = 5000 (0x1388), streams = 0x07 (EEG+IMU+STATUS)
                start_params = struct.pack("<HB", PORT_UDP_DATA, 0x07)
                sock.sendall(make_cmd_frame(CMD_START, start_params, seq=2))
                print("[+] Sent START stream to neo-fake. Live hardware simulation streaming to phone!")

                # Ingest UDP data
                while True:
                    try:
                        data, _ = udp.recvfrom(1400)
                        if len(data) >= 24 and data[:2] == MAGIC:
                            pkt_type = data[3]
                            if pkt_type == TYPE_EEG:
                                self.parse_eeg(data)
                            elif pkt_type == TYPE_EVENT:
                                ev_id = data[22] if len(data) > 22 else 0
                                print(f"[!] neo-fake EVENT received: {ev_id}")
                    except socket.timeout:
                        # Check TCP liveness
                        r, _, _ = select.select([sock], [], [], 0.0)
                        if r and not sock.recv(1):
                            break
                    except Exception:
                        break

                print("[-] Disconnected from neo-fake. Falling back to Stage Simulator.")
                state.source_mode = "SIMULATOR"
                sock.close()
                udp.close()
            except Exception:
                # neo-fake not running yet
                pass

            time.sleep(2.0)

    def parse_eeg(self, data: bytes):
        payload = data[22:-2]
        if len(payload) < 4:
            return
        n_samples, n_ch, fmt, _ = struct.unpack("<BBBB", payload[:4])
        offset = 4
        batch = []

        for _ in range(n_samples):
            if offset + 1 + n_ch * 4 > len(payload):
                break
            loff = payload[offset]
            offset += 1
            ch1_raw = struct.unpack("<i", payload[offset:offset+4])[0]
            offset += 4
            ch2_raw = struct.unpack("<i", payload[offset:offset+4])[0]
            offset += 4

            ch1 = ch1_raw * state.uv_per_count
            ch2 = ch2_raw * state.uv_per_count

            # If user triggered seizure demo on phone, inject spike discharges
            if state.seizure_active:
                elapsed = time.time() - state.seizure_start_t
                state.seizure_duration = elapsed
                if elapsed < 20.0:
                    t = time.time()
                    ph = 2.0 * math.pi * 3.2 * t
                    spike = 115.0 * (math.sin(ph) ** 9)
                    ch1 += spike
                    ch2 += spike * 0.9
                    state.seizure_risk = min(96, 88 + int(elapsed * 0.5))
                else:
                    state.seizure_active = False
                    state.seizure_risk = 7

            batch.append({
                "idx": state.sample_idx,
                "ch1": round(ch1, 1),
                "ch2": round(ch2, 1),
                "ch3": round(ch1 * 0.75, 1),
                "ch4": round(ch2 * 0.80, 1),
            })
            state.sample_idx += 1
            state.lead_off = loff

        broadcast_sse("eeg", {
            "samples": batch,
            "risk": state.seizure_risk,
            "seizure_active": state.seizure_active,
            "duration": round(state.seizure_duration, 1),
            "spikes": state.spikes_detected,
            "battery": state.battery_pct,
            "battery_mv": state.battery_mv,
            "lead_off": state.lead_off,
            "source": state.source_mode
        })

class StageSimulator(threading.Thread):
    """Fallback generator when neo-fake is not running."""
    def __init__(self):
        super().__init__(daemon=True)
        self.t = 0.0
        self.dt = 1.0 / 250.0

    def run(self):
        while True:
            if state.source_mode == "SIMULATOR":
                t0 = time.time()
                batch = []
                for _ in range(10):
                    self.t += self.dt
                    state.sample_idx += 1

                    alpha = 14.2 * math.sin(2.0 * math.pi * 10.0 * self.t)
                    theta = 5.2 * math.sin(2.0 * math.pi * 4.2 * self.t)
                    ch1 = alpha + theta + random.gauss(0, 3.2)
                    ch2 = (alpha * 0.88) + (theta * 0.95) + random.gauss(0, 3.0)

                    if state.seizure_active:
                        elapsed = time.time() - state.seizure_start_t
                        state.seizure_duration = elapsed
                        if elapsed < 20.0:
                            ph = 2.0 * math.pi * 3.2 * self.t
                            spike = 115.0 * (math.sin(ph) ** 9)
                            slow = 60.0 * math.sin(ph - 0.7)
                            ch1 = spike + slow + random.gauss(0, 8.0)
                            ch2 = ch1 * 0.92 + random.gauss(0, 7.0)
                            state.seizure_risk = min(96, 85 + int(elapsed * 0.6))
                        else:
                            state.seizure_active = False
                            state.seizure_risk = 8

                    batch.append({
                        "idx": state.sample_idx,
                        "ch1": round(ch1, 1),
                        "ch2": round(ch2, 1),
                        "ch3": round(ch1 * 0.75, 1),
                        "ch4": round(ch2 * 0.80, 1),
                    })

                broadcast_sse("eeg", {
                    "samples": batch,
                    "risk": state.seizure_risk,
                    "seizure_active": state.seizure_active,
                    "duration": round(state.seizure_duration, 1),
                    "spikes": state.spikes_detected,
                    "battery": state.battery_pct,
                    "battery_mv": state.battery_mv,
                    "lead_off": state.lead_off,
                    "source": state.source_mode
                })
                elapsed = time.time() - t0
                time.sleep(max(0.002, 0.040 - elapsed))
            else:
                time.sleep(0.1)

class RequestHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        web_dir = os.path.join(os.path.dirname(__file__), "web")
        super().__init__(*args, directory=web_dir, **kwargs)

    def do_GET(self):
        if self.path == "/stream":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            with clients_lock:
                clients.add(self.wfile)
            try:
                while True:
                    time.sleep(1)
            except Exception:
                pass
            finally:
                with clients_lock:
                    clients.discard(self.wfile)
        else:
            super().do_GET()

    def do_POST(self):
        if self.path == "/api/trigger-seizure":
            state.seizure_active = True
            state.seizure_start_t = time.time()
            state.seizure_duration = 0.0
            self.send_json({"status": "ok", "active": True})
        elif self.path == "/api/reset-seizure":
            state.seizure_active = False
            state.seizure_risk = 7
            self.send_json({"status": "ok", "active": False})
        else:
            self.send_error(404)

    def send_json(self, data):
        body = json.dumps(data).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return

def get_real_wifi_ip():
    try:
        out = subprocess.check_output(["ipconfig", "getifaddr", "en0"], text=True).strip()
        if out:
            return out
    except Exception:
        pass
    return "127.0.0.1"

def main():
    wifi_ip = get_real_wifi_ip()
    print("=" * 64)
    print("🧠 NEO EAR-EEG MOBILE COMPANION (AUTO-BRIDGED TO NEO-FAKE)")
    print("=" * 64)
    print(f"[*] Phone Link (same Wi-Fi):     http://{wifi_ip}:{PORT_HTTP}")
    print(f"[*] Mac Link:                    http://localhost:{PORT_HTTP}")
    print("=" * 64)
    print("[*] Neo-Fake Auto-Bridge active! To connect neo-fake:")
    print("    Open a NEW terminal and type: neo-fake")
    print("=" * 64)

    # Start threads
    NeoFakeBridge().start()
    StageSimulator().start()

    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT_HTTP), RequestHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[*] Stopped.")

if __name__ == "__main__":
    main()
