"""Face-tracking turret main loop.

Runs on the Raspberry Pi 5 with the Hailo AI HAT. The vision pipeline
follows the structure of hailo-ai/hailo-rpi5-examples — clone that repo
and use one of its detection apps as the source of face bounding boxes.
This module focuses on the control side: turning a detected face into
smooth pan/tilt servo commands.

Pan = closed-loop visual servo (camera pans with the barrel).
Tilt = open-loop geometric (camera does NOT tilt with the barrel).
"""

from __future__ import annotations

import json
import os
import pwd
import socket
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from geometry import (
    CameraModel,
    MountGeometry,
    ema,
    pan_error_deg,
    rate_limit,
    tilt_angle_deg,
)
from servo import Servo, ServoSpec, clamp_angle


CONFIG_PATH = Path(__file__).resolve().parent.parent / "config.json"
CONTROL_HZ = 30.0
CLIP_SOCKET_PATH = "/tmp/turret_clip.sock"
LAST_CLIP_PATH = Path(__file__).resolve().parent.parent / "last_clip.mp4"


def _serve_clip_requests(faces) -> None:
    """Unix-socket RPC: api_server asks tracker to dump the rolling clip."""
    try:
        os.unlink(CLIP_SOCKET_PATH)
    except FileNotFoundError:
        pass
    except OSError as exc:
        print(f"Tracker: cannot clear stale clip socket: {exc}")
        return

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.bind(CLIP_SOCKET_PATH)
        os.chmod(CLIP_SOCKET_PATH, 0o666)
        sock.listen(4)
    except OSError as exc:
        print(f"Tracker: clip socket bind failed: {exc}")
        sock.close()
        return

    print(f"Tracker: clip socket listening on {CLIP_SOCKET_PATH}")
    while True:
        try:
            conn, _ = sock.accept()
        except OSError:
            break
        with conn:
            conn.settimeout(15.0)
            try:
                data = b""
                while b"\n" not in data and len(data) < 4096:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                req = json.loads(data.decode("utf-8")) if data.strip() else {}
                action = req.get("action")
                if action == "save_clip":
                    result = faces.save_clip(LAST_CLIP_PATH)
                else:
                    result = {"ok": False, "error": "unknown_action"}
            except Exception as exc:
                result = {"ok": False, "error": "request_failed", "details": str(exc)}
            try:
                conn.sendall((json.dumps(result) + "\n").encode("utf-8"))
            except OSError:
                pass


@dataclass
class Detection:
    """Bounding box of the face we are tracking, in image pixels."""
    cx: float
    cy: float
    width: float
    height: float


def load_config(path: Path = CONFIG_PATH) -> dict:
    with path.open() as f:
        return json.load(f)


def make_camera_model(cfg: dict) -> CameraModel:
    c = cfg["camera"]
    return CameraModel(
        width_px=c["width_px"],
        height_px=c["height_px"],
        hfov_deg=c["hfov_deg"],
        vfov_deg=c["vfov_deg"],
        focal_px=c["focal_px"],
    )


def make_mount(cfg: dict) -> MountGeometry:
    m = cfg["mount"]
    return MountGeometry(
        camera_height_above_pivot=m["camera_height_above_pivot_m"],
        camera_forward_offset=m["camera_forward_offset_m"],
    )


def make_servo_spec(axis_cfg: dict, servo_cfg: dict) -> ServoSpec:
    return ServoSpec(
        gpio=axis_cfg["gpio"],
        min_us=servo_cfg["min_us"],
        max_us=servo_cfg["max_us"],
        freq_hz=servo_cfg["freq_hz"],
        min_angle=axis_cfg["min_angle"],
        max_angle=axis_cfg["max_angle"],
    )


def pick_target(detections: list[Detection]) -> Optional[Detection]:
    """Pick the largest face in frame as the tracked target."""
    if not detections:
        return None
    return max(detections, key=lambda d: d.width * d.height)


def sudo_target_user() -> tuple[int, int, str] | None:
    uid = os.environ.get("SUDO_UID")
    gid = os.environ.get("SUDO_GID")
    user = os.environ.get("SUDO_USER")
    if uid is None or gid is None or user is None:
        return None
    return int(uid), int(gid), user


def drop_from_sudo_for_display() -> bool:
    """Drop root after PWM setup so camera/OpenCV run as the desktop user."""
    if os.geteuid() != 0:
        return False

    target = sudo_target_user()
    if target is None:
        return False

    uid, gid, user = target
    pw = pwd.getpwnam(user)
    runtime_dir = f"/run/user/{uid}"

    os.environ["HOME"] = pw.pw_dir
    os.environ["USER"] = user
    os.environ["LOGNAME"] = user
    if os.path.isdir(runtime_dir):
        os.environ["XDG_RUNTIME_DIR"] = runtime_dir

    os.initgroups(user, gid)
    os.setgid(gid)
    os.setuid(uid)
    print(f"Tracker: dropped privileges to {user} for camera/display")
    return True


class TurretController:
    """Translates detections + current servo state into the next servo angles.

    Stateless w.r.t. hardware so it's testable in isolation; the run loop
    in main() does the actual servo I/O.
    """

    def __init__(self, cfg: dict):
        self.cam = make_camera_model(cfg)
        self.mount = make_mount(cfg)
        self.pan_center = cfg["pan"]["center"]
        self.tilt_center = cfg["tilt"]["center"]
        t = cfg["tracker"]
        self.real_face_width = t["real_face_width_m"]
        self.pan_p = t["pan_p_gain"]
        self.tilt_alpha = t["tilt_smoothing_alpha"]
        self.max_step = t["max_servo_step_deg"]
        self.deadband = t["deadband_deg"]
        self.lost_hold_s = t["lost_face_hold_s"]
        self.lost_recenter_s = t["lost_face_recenter_s"]

        self._tilt_smoothed: Optional[float] = None
        self._last_seen: float = time.monotonic()

    def step(
        self,
        detection: Optional[Detection],
        pan_angle: float,
        tilt_angle: float,
    ) -> tuple[float, float]:
        now = time.monotonic()

        if detection is None:
            since = now - self._last_seen
            if since < self.lost_hold_s:
                return pan_angle, tilt_angle
            if since < self.lost_recenter_s:
                return pan_angle, tilt_angle
            # slowly drift to center
            pan_target = rate_limit(pan_angle, self.pan_center, self.max_step / 2)
            tilt_target = rate_limit(tilt_angle, self.tilt_center, self.max_step / 2)
            return pan_target, tilt_target

        self._last_seen = now

        # Pan: visual feedback. Convention: positive pan_error means face is
        # right of frame center, so the barrel should rotate right. Whether
        # that means + or − degrees on YOUR servo depends on mounting; flip
        # the sign of pan_p_gain in config.json if it tracks backwards.
        pan_err = pan_error_deg(detection.cx, self.cam)
        if abs(pan_err) < self.deadband:
            pan_target = pan_angle
        else:
            pan_target = pan_angle + self.pan_p * pan_err

        # Tilt: open-loop geometric.
        tilt_raw = tilt_angle_deg(
            face_cy_px=detection.cy,
            bbox_width_px=detection.width,
            real_face_width_m=self.real_face_width,
            cam=self.cam,
            mount=self.mount,
        )
        # tilt_raw is "barrel tilt above horizontal". Convert to servo angle
        # by adding the tilt_center (which is whatever servo angle = level).
        tilt_servo_target = self.tilt_center + tilt_raw
        if self._tilt_smoothed is None:
            self._tilt_smoothed = tilt_servo_target
        else:
            self._tilt_smoothed = ema(self._tilt_smoothed, tilt_servo_target, self.tilt_alpha)

        pan_target = rate_limit(pan_angle, pan_target, self.max_step)
        tilt_target = rate_limit(tilt_angle, self._tilt_smoothed, self.max_step)
        return pan_target, tilt_target


def main() -> int:
    """Run the live tracker. Pi-only (needs picamera2 + Hailo + lgpio)."""
    cfg = load_config()
    controller = TurretController(cfg)
    pan_spec = make_servo_spec(cfg["pan"], cfg["servo"])
    tilt_spec = make_servo_spec(cfg["tilt"], cfg["servo"])

    # Lazy imports — these only exist on the Pi.
    from face_source import FaceSource  # noqa: E402

    period = 1.0 / CONTROL_HZ
    print("Tracker: opening pan servo")
    with Servo(pan_spec) as pan_servo:
        print("Tracker: opening tilt servo")
        with Servo(tilt_spec) as tilt_servo:
            if cfg.get("display", {}).get("show_window", False) and os.geteuid() == 0:
                target = sudo_target_user()
                if target is None:
                    print("Tracker: no sudo target user; disabling OpenCV window")
                    cfg.setdefault("display", {})["show_window"] = False
                else:
                    uid, gid, _user = target
                    pan_servo.grant_user_access(uid, gid)
                    tilt_servo.grant_user_access(uid, gid)
                    drop_from_sudo_for_display()

            print("Tracker: starting face source")
            with FaceSource(cfg) as faces:
                threading.Thread(
                    target=_serve_clip_requests, args=(faces,), daemon=True
                ).start()
                print("Tracker: moving servos to center")
                pan_servo.move_to(cfg["pan"]["center"], speed_deg_per_s=120)
                tilt_servo.move_to(cfg["tilt"]["center"], speed_deg_per_s=120)

                print("Tracker: running")
                while True:
                    t0 = time.monotonic()
                    target = pick_target(faces.latest())
                    pan_next, tilt_next = controller.step(
                        target, pan_servo.current_angle, tilt_servo.current_angle
                    )
                    pan_next = clamp_angle(pan_spec, pan_next)
                    tilt_next = clamp_angle(tilt_spec, tilt_next)
                    if pan_next != pan_servo.current_angle:
                        pan_servo.set_angle(pan_next)
                    if tilt_next != tilt_servo.current_angle:
                        tilt_servo.set_angle(tilt_next)

                    elapsed = time.monotonic() - t0
                    if elapsed < period:
                        time.sleep(period - elapsed)

    return 0


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    raise SystemExit(main())
