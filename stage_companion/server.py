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
        self.manual_override = False
        self.source_mode = "DISCONNECTED"  # "DISCONNECTED", "NEO_FAKE", "HARDWARE", "INTERNAL_SIM"
        self.neo_fake_connected = False
        self.hardware_connected = False
        self.last_eeg_packet_ts = 0.0
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

    @property
    def is_live_connected(self):
        return self.last_eeg_packet_ts > 0 and (time.time() - self.last_eeg_packet_ts) < 0.9

    @property
    def live_source_name(self):
        return "DISCONNECTED" if not self.is_live_connected else self.source_mode

    @property
    def live_neo_fake_connected(self):
        return self.neo_fake_connected and self.is_live_connected

    @property
    def live_hardware_connected(self):
        return self.hardware_connected and self.is_live_connected

    @property
    def source_meta(self):
        if not self.is_live_connected:
            return {
                "id": "DISCONNECTED",
                "label": "DISCONNECTED",
                "badge": "DISCONNECTED",
                "color": "#64748b",
                "detail": "Awaiting live raw EEG packets",
                "icon": "disconnected"
            }
        if self.source_mode == "HARDWARE":
            return {
                "id": "HARDWARE",
                "label": "LIVE PHYSICAL HARDWARE",
                "badge": "HARDWARE",
                "color": "#10b981", # Emerald green
                "detail": "ESP32-S3 + ADS1292R Live Ear-EEG (250 SPS)",
                "icon": "hardware"
            }
        elif self.source_mode == "NEO_FAKE":
            return {
                "id": "NEO_FAKE",
                "label": "NEO-FAKE TEST BENCH",
                "badge": "NEO-FAKE",
                "color": "#f59e0b", # Amber
                "detail": "Bridged to macOS neo-fake daemon (TCP 5001)",
                "icon": "bridge"
            }
        elif self.source_mode == "INTERNAL_SIM":
            return {
                "id": "INTERNAL_SIM",
                "label": "INTERNAL STAGE SIMULATOR",
                "badge": "INTERNAL SIM",
                "color": "#a855f7", # Violet / Purple
                "detail": "Autonomous 250 SPS Synthetic Rhythm (Pitch Mode)",
                "icon": "simulator"
            }
        return {
            "id": "DISCONNECTED",
            "label": "DISCONNECTED",
            "badge": "DISCONNECTED",
            "color": "#64748b",
            "detail": "Awaiting live raw EEG packets",
            "icon": "disconnected"
        }

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
    """Monitors and connects to neo-fake on TCP 5001 / UDP 5000 or real hardware."""
    def __init__(self):
        super().__init__(daemon=True)

    def run(self):
        while True:
            # Check if neo-fake (or hardware TCP bridge) is listening on localhost:5001
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(0.9)
                sock.connect(("127.0.0.1", PORT_TCP_CTRL))
                print("\n[+] SUCCESS: Connected to neo-fake / hardware on TCP port 5001!")
                state.neo_fake_connected = True
                state.last_eeg_packet_ts = time.time()
                if not state.manual_override:
                    state.source_mode = "NEO_FAKE"

                # Setup UDP socket to receive EEG packets
                udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                try:
                    udp.bind(("127.0.0.1", PORT_UDP_DATA))
                except Exception:
                    pass
                udp.settimeout(0.75)

                # Send GET_INFO
                sock.sendall(make_cmd_frame(CMD_GET_INFO, b"", seq=1))
                time.sleep(0.05)

                # Send START: udp_port = 5000 (0x1388), streams = 0x07 (EEG+IMU+STATUS)
                start_params = struct.pack("<HB", PORT_UDP_DATA, 0x07)
                sock.sendall(make_cmd_frame(CMD_START, start_params, seq=2))
                print("[+] Stream START sent! Data actively forwarding to mobile display.")

                # Ingest UDP data
                while True:
                    try:
                        data, _ = udp.recvfrom(1400)
                        if len(data) >= 24 and data[:2] == MAGIC:
                            pkt_type = data[3]
                            if pkt_type == TYPE_EEG and state.source_mode in ("NEO_FAKE", "HARDWARE"):
                                self.parse_eeg(data)
                            elif pkt_type == TYPE_EVENT:
                                ev_id = data[22] if len(data) > 22 else 0
                                print(f"[!] Event packet received: {ev_id}")
                    except socket.timeout:
                        # Check TCP liveness
                        r, _, _ = select.select([sock], [], [], 0.0)
                        if r and not sock.recv(1):
                            break
                    except Exception:
                        break

                print("[-] Disconnected from external source. Waiting for live EEG packets.")
                state.neo_fake_connected = False
                state.last_eeg_packet_ts = 0.0
                if not state.manual_override:
                    state.source_mode = "DISCONNECTED"
                sock.close()
                udp.close()
            except Exception:
                state.neo_fake_connected = False
                state.last_eeg_packet_ts = 0.0
                if not state.manual_override and state.source_mode == "NEO_FAKE":
                    state.source_mode = "DISCONNECTED"

            time.sleep(0.75)

    def parse_eeg(self, data: bytes):
        state.last_eeg_packet_ts = time.time()
        state.neo_fake_connected = True
        state.hardware_connected = False
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

            raw_channels = []
            for _ in range(n_ch):
                if offset + 4 > len(payload):
                    break
                raw = struct.unpack("<i", payload[offset:offset+4])[0]
                offset += 4
                raw_channels.append(raw * state.uv_per_count)

            ch1 = raw_channels[0] if len(raw_channels) > 0 else 0.0
            ch2 = raw_channels[1] if len(raw_channels) > 1 else 0.0
            ch3 = raw_channels[2] if len(raw_channels) > 2 else ch1 * 0.75
            ch4 = raw_channels[3] if len(raw_channels) > 3 else ch2 * 0.80

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
                    ch3 = ch1 * 0.75
                    ch4 = ch2 * 0.80
                    state.seizure_risk = min(96, 88 + int(elapsed * 0.5))
                else:
                    state.seizure_active = False
                    state.seizure_risk = 7

            batch.append({
                "idx": state.sample_idx,
                "ch1": round(ch1, 1),
                "ch2": round(ch2, 1),
                "ch3": round(ch3, 1),
                "ch4": round(ch4, 1),
                "channels": [round(v, 1) for v in raw_channels[:4]],
                "channel_count": min(len(raw_channels), 4),
            })
            state.sample_idx += 1
            state.lead_off = loff

        meta = state.source_meta
        broadcast_sse("eeg", {
            "samples": batch,
            "risk": state.seizure_risk,
            "seizure_active": state.seizure_active,
            "duration": round(state.seizure_duration, 1),
            "spikes": state.spikes_detected,
            "battery": state.battery_pct,
            "battery_mv": state.battery_mv,
            "lead_off": state.lead_off,
            "source": state.live_source_name,
            "source_meta": meta,
            "connected": state.is_live_connected,
            "neo_fake_connected": state.live_neo_fake_connected,
            "hardware_connected": state.live_hardware_connected
        })

class StageSimulator(threading.Thread):
    """Fallback generator when neo-fake or hardware is not active."""
    def __init__(self):
        super().__init__(daemon=True)
        self.t = 0.0
        self.dt = 1.0 / 250.0

    def run(self):
        while True:
            if state.source_mode == "INTERNAL_SIM":
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

                meta = state.source_meta
                state.last_eeg_packet_ts = time.time()
                broadcast_sse("eeg", {
                    "samples": batch,
                    "risk": state.seizure_risk,
                    "seizure_active": state.seizure_active,
                    "duration": round(state.seizure_duration, 1),
                    "spikes": state.spikes_detected,
                    "battery": state.battery_pct,
                    "battery_mv": state.battery_mv,
                    "lead_off": state.lead_off,
                    "source": state.live_source_name,
                    "source_meta": meta,
                    "connected": state.is_live_connected,
                    "neo_fake_connected": state.live_neo_fake_connected,
                    "hardware_connected": state.live_hardware_connected
                })
                elapsed = time.time() - t0
                time.sleep(max(0.002, 0.040 - elapsed))
            else:
                time.sleep(0.05)

class RequestHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        web_dir = os.path.join(os.path.dirname(__file__), "web")
        super().__init__(*args, directory=web_dir, **kwargs)

    def end_headers(self):
        # Strict cache-busting headers so mobile browsers never serve stale pages
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def do_GET(self):
        if self.path == "/stream":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
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
        elif self.path == "/api/status":
            meta = state.source_meta
            self.send_json({
                "status": "online",
                "source": state.live_source_name,
                "source_meta": meta,
                "connected": state.is_live_connected,
                "neo_fake_connected": state.live_neo_fake_connected,
                "hardware_connected": state.live_hardware_connected,
                "seizure_active": state.seizure_active,
                "battery": state.battery_pct
            })
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
        elif self.path == "/api/set-source":
            try:
                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length).decode("utf-8") if length > 0 else "{}"
                req = json.loads(body)
                requested = req.get("source", "AUTO")
                if requested == "AUTO":
                    state.manual_override = False
                    state.source_mode = "NEO_FAKE" if state.neo_fake_connected else "DISCONNECTED"
                elif requested in ("DISCONNECTED", "INTERNAL_SIM", "NEO_FAKE", "HARDWARE"):
                    state.manual_override = True
                    state.source_mode = requested
                print(f"[!] Source mode changed to: {state.source_mode} (manual={state.manual_override})")
                self.send_json({"status": "ok", "source": state.source_mode, "source_meta": state.source_meta})
            except Exception as e:
                self.send_json({"status": "error", "message": str(e)})
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
