"""Minimal local API server and web UI for turret control.

Endpoints:
  GET  /
  GET  /last_clip.mp4
  POST /shoot
  GET  /api/bluetooth/devices
  POST /api/bluetooth/scan
  POST /api/bluetooth/connect
  GET  /api/config
  PUT  /api/config
  GET  /api/camera/stream
"""

from __future__ import annotations

import json
import os
import socket
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

from action_hooks import shoot
from audio_output import (
    connect_bluetooth_device,
    list_bluetooth_devices,
    play_sound_effect,
    scan_bluetooth_devices,
)

PROJECT_DIR = Path(__file__).resolve().parents[1]
CONFIG_PATH = PROJECT_DIR / "config.json"
LAST_CLIP_PATH = PROJECT_DIR / "last_clip.mp4"
LAST_CLIP_LOCK = threading.Lock()
CLIP_SOCKET_PATH = "/tmp/turret_clip.sock"
CLIP_RPC_TIMEOUT_S = 30.0


def load_config() -> dict:
    with CONFIG_PATH.open() as f:
        return json.load(f)


def save_config(config: dict) -> None:
    tmp_path = CONFIG_PATH.with_suffix(".json.tmp")
    with tmp_path.open("w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    tmp_path.replace(CONFIG_PATH)


def record_last_clip() -> dict:
    """Ask the tracker process (which owns the camera) to dump its rolling buffer."""
    if not LAST_CLIP_LOCK.acquire(blocking=False):
        return {"ok": False, "error": "clip_in_progress"}
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CLIP_RPC_TIMEOUT_S)
        try:
            sock.connect(CLIP_SOCKET_PATH)
        except (FileNotFoundError, ConnectionRefusedError, OSError) as exc:
            sock.close()
            return {
                "ok": False,
                "error": "tracker_unavailable",
                "details": f"clip socket {CLIP_SOCKET_PATH}: {exc}",
            }
        try:
            sock.sendall(b'{"action": "save_clip"}\n')
            data = b""
            while b"\n" not in data and len(data) < 65536:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                data += chunk
        except (socket.timeout, OSError) as exc:
            return {"ok": False, "error": "rpc_failed", "details": str(exc)}
        finally:
            sock.close()

        try:
            return json.loads(data.decode("utf-8").strip())
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            return {"ok": False, "error": "bad_response", "details": str(exc)}
    finally:
        LAST_CLIP_LOCK.release()


INDEX_HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Turret Control</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f6f7f9;
      --panel: #ffffff;
      --text: #15181c;
      --muted: #5f6975;
      --line: #d8dde5;
      --accent: #0b766d;
      --danger: #b42318;
      --shadow: 0 14px 32px rgb(19 27 37 / 10%);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      background: var(--bg);
      color: var(--text);
      font: 16px/1.45 system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    main {
      width: min(960px, calc(100vw - 32px));
      margin: 0 auto;
      padding: 32px 0;
    }
    header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      margin-bottom: 20px;
    }
    h1 { margin: 0; font-size: clamp(1.8rem, 4vw, 2.5rem); letter-spacing: 0; }
    .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      box-shadow: var(--shadow);
      padding: 18px;
      margin-bottom: 16px;
    }
    .row {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      align-items: center;
    }
    button, select, textarea {
      min-height: 42px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #fff;
      color: var(--text);
      padding: 0 14px;
      font: inherit;
    }
    .link-button {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-height: 42px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #fff;
      color: var(--text);
      padding: 0 14px;
      font: inherit;
      font-weight: 650;
      text-decoration: none;
      cursor: pointer;
      white-space: nowrap;
    }
    .link-button.disabled {
      pointer-events: none;
      opacity: .62;
      cursor: not-allowed;
    }
    textarea {
      width: 100%;
      min-height: 360px;
      padding: 12px;
      resize: vertical;
      font: 14px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      tab-size: 2;
    }
    select { flex: 1 1 260px; min-width: 0; }
    button {
      cursor: pointer;
      font-weight: 650;
      white-space: nowrap;
    }
    button.primary {
      background: var(--accent);
      border-color: var(--accent);
      color: #fff;
    }
    button.shoot {
      min-width: 150px;
      background: var(--danger);
      border-color: var(--danger);
      color: #fff;
    }
    button:disabled { cursor: wait; opacity: .62; }
    .status {
      margin-top: 12px;
      min-height: 24px;
      color: var(--muted);
      overflow-wrap: anywhere;
    }
    .status.error { color: var(--danger); }
    .device-meta {
      margin-top: 10px;
      color: var(--muted);
      font-size: .94rem;
    }
    .stream-frame {
      width: min(100%, 420px);
      aspect-ratio: 9 / 16;
      background: #111;
      border: 1px solid var(--line);
      border-radius: 8px;
      display: grid;
      place-items: center;
      overflow: hidden;
    }
    .stream-frame img {
      width: 100%;
      height: 100%;
      object-fit: contain;
      display: block;
    }
    .stream-placeholder {
      color: #d8dde5;
      padding: 18px;
      text-align: center;
    }
    @media (max-width: 520px) {
      main { width: min(100vw - 24px, 760px); padding-top: 20px; }
      header, .row { align-items: stretch; flex-direction: column; }
      button, select { width: 100%; }
    }
  </style>
</head>
<body>
  <main>
    <header>
      <h1>Turret Control</h1>
      <button class="shoot" id="shootButton" type="button">Shoot</button>
    </header>

    <section class="panel" aria-labelledby="speakerHeading">
      <h2 id="speakerHeading">Bluetooth Speaker</h2>
      <div class="row">
        <select id="speakerSelect" aria-label="Bluetooth speaker"></select>
        <button id="refreshButton" type="button">Refresh</button>
        <button id="scanButton" type="button">Scan</button>
        <button class="primary" id="connectButton" type="button">Connect</button>
      </div>
      <div class="device-meta" id="deviceMeta"></div>
      <div class="status" id="speakerStatus"></div>
    </section>

    <section class="panel" aria-labelledby="shootHeading">
      <h2 id="shootHeading">API Shoot</h2>
      <div class="row">
        <button class="shoot" id="shootButtonPanel" type="button">Shoot + Sound</button>
        <a class="link-button disabled" id="clipLink" href="/last_clip.mp4" download aria-disabled="true">Download last clip</a>
      </div>
      <div class="status" id="shootStatus"></div>
    </section>

    <section class="panel" aria-labelledby="cameraHeading">
      <h2 id="cameraHeading">Camera Stream</h2>
      <div class="row">
        <button class="primary" id="streamButton" type="button">Start Stream</button>
        <button id="stopStreamButton" type="button">Stop Stream</button>
      </div>
      <div class="status" id="streamStatus"></div>
      <div class="stream-frame" id="streamFrame">
        <div class="stream-placeholder">Stream stopped</div>
      </div>
    </section>

    <section class="panel" aria-labelledby="configHeading">
      <h2 id="configHeading">Config</h2>
      <textarea id="configEditor" spellcheck="false" aria-label="config.json editor"></textarea>
      <div class="row">
        <button id="reloadConfigButton" type="button">Reload</button>
        <button class="primary" id="saveConfigButton" type="button">Save Config</button>
      </div>
      <div class="status" id="configStatus"></div>
    </section>
  </main>

  <script>
    const speakerSelect = document.querySelector('#speakerSelect');
    const deviceMeta = document.querySelector('#deviceMeta');
    const speakerStatus = document.querySelector('#speakerStatus');
    const shootStatus = document.querySelector('#shootStatus');
    const clipLink = document.querySelector('#clipLink');
    const streamStatus = document.querySelector('#streamStatus');
    const streamFrame = document.querySelector('#streamFrame');
    const configEditor = document.querySelector('#configEditor');
    const configStatus = document.querySelector('#configStatus');
    const buttons = [...document.querySelectorAll('button')];

    function setBusy(isBusy) {
      buttons.forEach((button) => { button.disabled = isBusy; });
    }

    function setStatus(el, message, isError = false) {
      el.textContent = message || '';
      el.classList.toggle('error', isError);
    }

    function setClipLinkReady(isReady) {
      clipLink.classList.toggle('disabled', !isReady);
      clipLink.setAttribute('aria-disabled', String(!isReady));
    }

    function updateClipLink() {
      clipLink.href = `/last_clip.mp4?ts=${Date.now()}`;
      setClipLinkReady(true);
    }

    async function requestJSON(url, options = {}) {
      const response = await fetch(url, {
        headers: { 'Content-Type': 'application/json' },
        ...options,
      });
      const body = await response.json();
      if (!response.ok || body.ok === false) {
        throw new Error(body.error || body.details || response.statusText);
      }
      return body;
    }

    async function loadConfig(message = 'Config loaded.') {
      const body = await requestJSON('/api/config');
      configEditor.value = JSON.stringify(body.config, null, 2);
      setStatus(configStatus, message);
    }

    async function saveConfig() {
      let config;
      try {
        config = JSON.parse(configEditor.value);
      } catch (err) {
        throw new Error(`Invalid JSON: ${err.message}`);
      }
      await requestJSON('/api/config', {
        method: 'PUT',
        body: JSON.stringify({ config }),
      });
      configEditor.value = JSON.stringify(config, null, 2);
      setStatus(configStatus, 'Config saved.');
    }

    function renderDevices(devices) {
      speakerSelect.innerHTML = '';
      if (!devices.length) {
        speakerSelect.append(new Option('No Bluetooth devices found', ''));
        deviceMeta.textContent = '';
        return;
      }
      devices.forEach((device) => {
        const state = device.connected ? 'connected' : device.paired ? 'paired' : 'seen';
        speakerSelect.append(new Option(`${device.name} (${state})`, device.address));
      });
      updateSelectedDeviceMeta(devices);
    }

    function updateSelectedDeviceMeta(devices) {
      const selected = devices.find((device) => device.address === speakerSelect.value);
      deviceMeta.textContent = selected
        ? `${selected.address} - paired: ${selected.paired ? 'yes' : 'no'} - trusted: ${selected.trusted ? 'yes' : 'no'}`
        : '';
    }

    let currentDevices = [];
    async function loadDevices(message = 'Loaded Bluetooth devices.') {
      const body = await requestJSON('/api/bluetooth/devices');
      currentDevices = body.devices || [];
      renderDevices(currentDevices);
      setStatus(speakerStatus, message);
    }

    async function withBusy(fn) {
      setBusy(true);
      try {
        await fn();
      } finally {
        setBusy(false);
      }
    }

    document.querySelector('#refreshButton').addEventListener('click', () => withBusy(async () => {
      await loadDevices();
    }).catch((err) => setStatus(speakerStatus, err.message, true)));

    document.querySelector('#scanButton').addEventListener('click', () => withBusy(async () => {
      setStatus(speakerStatus, 'Scanning for nearby Bluetooth speakers...');
      const body = await requestJSON('/api/bluetooth/scan', { method: 'POST', body: '{}' });
      currentDevices = body.devices || [];
      renderDevices(currentDevices);
      setStatus(speakerStatus, 'Scan complete.');
    }).catch((err) => setStatus(speakerStatus, err.message, true)));

    document.querySelector('#connectButton').addEventListener('click', () => withBusy(async () => {
      const address = speakerSelect.value;
      if (!address) throw new Error('Select a Bluetooth device first.');
      setStatus(speakerStatus, 'Connecting...');
      await requestJSON('/api/bluetooth/connect', { method: 'POST', body: JSON.stringify({ address }) });
      await loadDevices('Connected. The next shoot sound should play through the selected speaker.');
    }).catch((err) => setStatus(speakerStatus, err.message, true)));

    async function shootNow() {
      await withBusy(async () => {
        setStatus(shootStatus, 'Sending shoot API request...');
        const body = await requestJSON('/shoot', { method: 'POST', body: '{}' });
        const sound = body.sound;
        const clip = body.clip;
        const soundText = sound?.ok ? ` Sound started with ${sound.player}.` : ` Sound issue: ${sound?.error || 'unknown'}.`;
        const clipText = clip?.ok ? ' Clip ready.' : ` Clip issue: ${clip?.error || 'unknown'}.`;
        if (clip?.ok) {
          updateClipLink();
        } else {
          setClipLinkReady(false);
        }
        setStatus(
          shootStatus,
          `${body.action?.message || 'Shoot sent.'}${soundText}${clipText}`,
          !sound?.ok || !clip?.ok,
        );
      });
    }

    document.querySelector('#shootButton').addEventListener('click', () => shootNow().catch((err) => setStatus(shootStatus, err.message, true)));
    document.querySelector('#shootButtonPanel').addEventListener('click', () => shootNow().catch((err) => setStatus(shootStatus, err.message, true)));
    speakerSelect.addEventListener('change', () => updateSelectedDeviceMeta(currentDevices));

    document.querySelector('#streamButton').addEventListener('click', () => {
      streamFrame.innerHTML = '';
      const img = document.createElement('img');
      img.alt = 'Camera stream';
      img.src = `/api/camera/stream?ts=${Date.now()}`;
      img.addEventListener('load', () => setStatus(streamStatus, 'Streaming.'));
      img.addEventListener('error', () => setStatus(streamStatus, 'Stream unavailable. Enable web.camera_stream.enabled in config.', true));
      streamFrame.append(img);
      setStatus(streamStatus, 'Opening stream...');
    });

    document.querySelector('#stopStreamButton').addEventListener('click', () => {
      streamFrame.innerHTML = '<div class="stream-placeholder">Stream stopped</div>';
      setStatus(streamStatus, 'Stream stopped.');
    });

    document.querySelector('#reloadConfigButton').addEventListener('click', () => withBusy(async () => {
      await loadConfig();
    }).catch((err) => setStatus(configStatus, err.message, true)));

    document.querySelector('#saveConfigButton').addEventListener('click', () => withBusy(async () => {
      await saveConfig();
    }).catch((err) => setStatus(configStatus, err.message, true)));

    loadDevices('Ready.').catch((err) => setStatus(speakerStatus, err.message, true));
    loadConfig().catch((err) => setStatus(configStatus, err.message, true));
    setClipLinkReady(false);
  </script>
</body>
</html>
"""


class TurretAPIHandler(BaseHTTPRequestHandler):
    server_version = "TurretAPI/1.0"

    def _write_json(self, status: int, body: dict) -> None:
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _write_html(self, status: int, body: str) -> None:
        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _write_mjpeg_stream(self) -> None:
        cfg = load_config()
        stream_cfg = cfg.get("web", {}).get("camera_stream", {})
        if not stream_cfg.get("enabled", False):
            self._write_json(
                HTTPStatus.FORBIDDEN,
                {"ok": False, "error": "camera_stream_disabled"},
            )
            return

        width = max(1, int(stream_cfg.get("width_px", 360)))
        height = max(1, int(stream_cfg.get("height_px", 640)))
        fps = min(30.0, max(1.0, float(stream_cfg.get("fps", 8))))
        quality = min(95, max(25, int(stream_cfg.get("jpeg_quality", 70))))
        mirror_horizontal = cfg.get("camera", {}).get("mirror_horizontal", False)

        try:
            import cv2
            from picamera2 import Picamera2
        except Exception as exc:
            self._write_json(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                {"ok": False, "error": "camera_dependencies_unavailable", "details": str(exc)},
            )
            return

        picam2 = None
        try:
            picam2 = Picamera2(camera_num=0)
            cam_cfg = picam2.create_preview_configuration(
                main={"size": (1280, 720), "format": "BGR888"}
            )
            picam2.configure(cam_cfg)
            picam2.start()
        except Exception as exc:
            if picam2 is not None:
                try:
                    picam2.stop()
                except Exception:
                    pass
            self._write_json(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                {"ok": False, "error": "camera_unavailable", "details": str(exc)},
            )
            return

        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Pragma", "no-cache")
        self.end_headers()

        period_s = 1.0 / fps
        encode_params = [int(cv2.IMWRITE_JPEG_QUALITY), quality]
        try:
            while True:
                started_at = time.monotonic()
                frame = picam2.capture_array("main")
                if frame is None:
                    continue
                frame = cv2.rotate(frame, cv2.ROTATE_90_CLOCKWISE)
                if mirror_horizontal:
                    frame = cv2.flip(frame, 1)
                frame = cv2.resize(frame, (width, height), interpolation=cv2.INTER_AREA)
                ok, encoded = cv2.imencode(".jpg", frame, encode_params)
                if not ok:
                    continue
                payload = encoded.tobytes()
                self.wfile.write(b"--frame\r\n")
                self.wfile.write(b"Content-Type: image/jpeg\r\n")
                self.wfile.write(f"Content-Length: {len(payload)}\r\n\r\n".encode("ascii"))
                self.wfile.write(payload)
                self.wfile.write(b"\r\n")
                self.wfile.flush()

                elapsed = time.monotonic() - started_at
                if elapsed < period_s:
                    time.sleep(period_s - elapsed)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            picam2.stop()

    def _read_json(self) -> dict:
        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length <= 0:
            return {}
        raw_body = self.rfile.read(content_length)
        try:
            return json.loads(raw_body.decode("utf-8"))
        except json.JSONDecodeError:
            return {}

    def log_message(self, fmt: str, *args) -> None:
        # Keep logs in journald without default noisy stderr format.
        print(f"api: {self.address_string()} - {fmt % args}")

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/":
            self._write_html(HTTPStatus.OK, INDEX_HTML)
            return
        if path == "/last_clip.mp4":
            if not LAST_CLIP_PATH.exists():
                self._write_json(
                    HTTPStatus.NOT_FOUND,
                    {"ok": False, "error": "clip_not_found"},
                )
                return
            try:
                size = LAST_CLIP_PATH.stat().st_size
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "video/mp4")
                self.send_header("Content-Length", str(size))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                with LAST_CLIP_PATH.open("rb") as f:
                    while True:
                        chunk = f.read(64 * 1024)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                return
            except OSError as exc:
                self._write_json(
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                    {"ok": False, "error": "clip_unavailable", "details": str(exc)},
                )
                return
        if path == "/api/bluetooth/devices":
            result = list_bluetooth_devices()
            status = HTTPStatus.OK if result.get("ok") else HTTPStatus.INTERNAL_SERVER_ERROR
            self._write_json(status, result)
            return
        if path == "/api/config":
            self._write_json(HTTPStatus.OK, {"ok": True, "config": load_config()})
            return
        if path == "/api/camera/stream":
            self._write_mjpeg_stream()
            return
        self._write_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def do_PUT(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/api/config":
            body = self._read_json()
            config = body.get("config")
            if not isinstance(config, dict):
                self._write_json(
                    HTTPStatus.BAD_REQUEST,
                    {"ok": False, "error": "config must be a JSON object"},
                )
                return
            try:
                save_config(config)
            except OSError as exc:
                self._write_json(
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                    {"ok": False, "error": "unable to save config", "details": str(exc)},
                )
                return
            self._write_json(HTTPStatus.OK, {"ok": True, "config": config})
            return
        self._write_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/shoot":
            result = shoot()
            sound_result = play_sound_effect()
            clip_result = record_last_clip()
            self._write_json(
                HTTPStatus.OK,
                {"ok": True, "action": result, "sound": sound_result, "clip": clip_result},
            )
            return
        if path == "/api/bluetooth/scan":
            result = scan_bluetooth_devices()
            status = HTTPStatus.OK if result.get("ok") else HTTPStatus.INTERNAL_SERVER_ERROR
            self._write_json(status, result)
            return
        if path == "/api/bluetooth/connect":
            body = self._read_json()
            result = connect_bluetooth_device(str(body.get("address", "")))
            status = HTTPStatus.OK if result.get("ok") else HTTPStatus.BAD_REQUEST
            self._write_json(status, result)
            return
        self._write_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})


def main() -> int:
    host = os.environ.get("TURRET_API_HOST", "0.0.0.0")
    port = int(os.environ.get("TURRET_API_PORT", "8787"))
    server = ThreadingHTTPServer((host, port), TurretAPIHandler)
    print(f"api: serving on http://{host}:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
