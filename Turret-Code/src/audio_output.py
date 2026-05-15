"""Bluetooth speaker selection and sound-effect playback helpers."""

from __future__ import annotations

import json
import os
import re
import signal
import shlex
import shutil
import subprocess
import threading
import time
from pathlib import Path


DEVICE_RE = re.compile(r"^Device\s+([0-9A-Fa-f:]{17})\s+(.+)$")
MAC_RE = re.compile(r"^[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}$")

PROJECT_DIR = Path(__file__).resolve().parents[1]
CONFIG_PATH = PROJECT_DIR / "config.json"
DEFAULT_SOUND_PATH = PROJECT_DIR / "sound" / "LockInAudio3.mp3"


def _run(args: list[str], timeout_s: float = 8.0) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout_s,
    )


def _ok_result(**extra: object) -> dict:
    return {"ok": True, **extra}


def _error_result(message: str, **extra: object) -> dict:
    return {"ok": False, "error": message, **extra}


def bluetooth_available() -> bool:
    return shutil.which("bluetoothctl") is not None


def list_bluetooth_devices() -> dict:
    """Return Bluetooth devices known to BlueZ.

    Devices appear here after they have been paired before or after a scan has
    seen them. Connection status is best-effort because each `info` call can
    fail for stale devices.
    """
    if not bluetooth_available():
        return _error_result("bluetoothctl is not installed. Install the bluez package.")

    result = _run(["bluetoothctl", "devices"])
    if result.returncode != 0:
        return _error_result("Unable to list Bluetooth devices.", details=result.stderr.strip())

    devices = []
    for line in result.stdout.splitlines():
        match = DEVICE_RE.match(line.strip())
        if not match:
            continue
        address, name = match.groups()
        info = _run(["bluetoothctl", "info", address], timeout_s=4.0)
        devices.append(
            {
                "address": address.upper(),
                "name": name,
                "connected": "Connected: yes" in info.stdout,
                "paired": "Paired: yes" in info.stdout,
                "trusted": "Trusted: yes" in info.stdout,
            }
        )

    return _ok_result(devices=devices)


def scan_bluetooth_devices(timeout_s: float = 8.0) -> dict:
    """Scan briefly, then return the discovered/known devices."""
    if not bluetooth_available():
        return _error_result("bluetoothctl is not installed. Install the bluez package.")

    try:
        _run(["bluetoothctl", "power", "on"], timeout_s=4.0)
        started_at = time.monotonic()
        _run(["bluetoothctl", "scan", "on"], timeout_s=timeout_s)
        remaining_s = timeout_s - (time.monotonic() - started_at)
        if remaining_s > 0:
            time.sleep(remaining_s)
    except subprocess.TimeoutExpired:
        pass
    finally:
        _run(["bluetoothctl", "scan", "off"], timeout_s=4.0)

    return list_bluetooth_devices()


def connect_bluetooth_device(address: str) -> dict:
    address = address.strip().upper()
    if not MAC_RE.match(address):
        return _error_result("Invalid Bluetooth MAC address.")
    if not bluetooth_available():
        return _error_result("bluetoothctl is not installed. Install the bluez package.")

    _run(["bluetoothctl", "power", "on"], timeout_s=4.0)
    _run(["bluetoothctl", "pair", address], timeout_s=20.0)
    _run(["bluetoothctl", "trust", address], timeout_s=8.0)
    result = _run(["bluetoothctl", "connect", address], timeout_s=20.0)

    combined_output = f"{result.stdout}\n{result.stderr}".strip()
    if result.returncode == 0 and "Connection successful" in combined_output:
        return _ok_result(address=address, output=combined_output)
    return _error_result("Unable to connect Bluetooth device.", address=address, details=combined_output)


def _player_command(sound_path: Path) -> list[str] | None:
    override = os.environ.get("TURRET_SOUND_PLAYER")
    if override:
        return [*shlex.split(override), str(sound_path)]

    candidates = (
        ("mpg123", ["mpg123", "-q", str(sound_path)]),
        ("ffplay", ["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", str(sound_path)]),
        ("mpv", ["mpv", "--really-quiet", "--no-video", str(sound_path)]),
        ("cvlc", ["cvlc", "--play-and-exit", "--quiet", str(sound_path)]),
    )
    for executable, command in candidates:
        if shutil.which(executable):
            return command
    return None


def _configured_play_duration_s() -> float | None:
    try:
        with CONFIG_PATH.open() as f:
            cfg = json.load(f)
    except (OSError, json.JSONDecodeError):
        return None

    raw_duration = cfg.get("sound", {}).get("play_duration_s")
    if raw_duration is None:
        return None
    try:
        duration_s = float(raw_duration)
    except (TypeError, ValueError):
        return None
    if duration_s <= 0:
        return None
    return duration_s


def _stop_after(process: subprocess.Popen, duration_s: float) -> None:
    def stop_process() -> None:
        if process.poll() is not None:
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        except OSError:
            process.terminate()

    timer = threading.Timer(duration_s, stop_process)
    timer.daemon = True
    timer.start()


def play_sound_effect() -> dict:
    """Start the configured sound effect and return immediately."""
    sound_path = Path(os.environ.get("TURRET_SOUND_PATH", DEFAULT_SOUND_PATH)).expanduser()
    if not sound_path.exists():
        return _error_result("Sound file does not exist.", path=str(sound_path))

    command = _player_command(sound_path)
    if command is None:
        return _error_result(
            "No supported audio player found. Install mpg123, ffmpeg, mpv, or vlc.",
            path=str(sound_path),
        )

    try:
        process = subprocess.Popen(
            command,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as exc:
        return _error_result("Unable to start audio player.", details=str(exc), command=command)

    duration_s = _configured_play_duration_s()
    if duration_s is not None:
        _stop_after(process, duration_s)

    return _ok_result(player=command[0], path=str(sound_path), duration_s=duration_s)
