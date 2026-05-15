"""Keyboard-driven servo control.

Verifies that pan and tilt move smoothly and independently before any
vision is wired up. Arrow keys nudge each axis; space recenters; q quits.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from servo import Servo, ServoSpec, clamp_angle


CONFIG_PATH = Path(__file__).resolve().parent.parent / "config.json"
STEP_DEG = 2.0
SPEED_DEG_PER_S = 180.0


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        # Sensible defaults if user hasn't run calibrate.py yet.
        return {
            "pan": {"gpio": 12, "min_angle": 10, "max_angle": 170, "center": 90},
            "tilt": {"gpio": 13, "min_angle": 10, "max_angle": 170, "center": 90},
            "servo": {"min_us": 500, "max_us": 2500, "freq_hz": 50},
        }
    with CONFIG_PATH.open() as f:
        return json.load(f)


def make_spec(axis_cfg: dict, servo_cfg: dict) -> ServoSpec:
    return ServoSpec(
        gpio=axis_cfg["gpio"],
        min_us=servo_cfg["min_us"],
        max_us=servo_cfg["max_us"],
        freq_hz=servo_cfg["freq_hz"],
        min_angle=axis_cfg["min_angle"],
        max_angle=axis_cfg["max_angle"],
    )


def main() -> int:
    import readchar

    cfg = load_config()
    pan_spec = make_spec(cfg["pan"], cfg["servo"])
    tilt_spec = make_spec(cfg["tilt"], cfg["servo"])
    pan_center = cfg["pan"]["center"]
    tilt_center = cfg["tilt"]["center"]

    print("Manual control — arrows to move, space to recenter, q to quit.")
    print(f"  pan   GPIO {pan_spec.gpio}  range {pan_spec.min_angle}..{pan_spec.max_angle}")
    print(f"  tilt  GPIO {tilt_spec.gpio}  range {tilt_spec.min_angle}..{tilt_spec.max_angle}")

    with Servo(pan_spec) as pan, Servo(tilt_spec) as tilt:
        pan.move_to(pan_center, SPEED_DEG_PER_S)
        tilt.move_to(tilt_center, SPEED_DEG_PER_S)

        while True:
            key = readchar.readkey()
            pan_target = pan.current_angle
            tilt_target = tilt.current_angle

            if key == readchar.key.LEFT:
                pan_target -= STEP_DEG
            elif key == readchar.key.RIGHT:
                pan_target += STEP_DEG
            elif key == readchar.key.UP:
                tilt_target += STEP_DEG
            elif key == readchar.key.DOWN:
                tilt_target -= STEP_DEG
            elif key == " ":
                pan_target = pan_center
                tilt_target = tilt_center
            elif key in ("q", "Q", readchar.key.CTRL_C):
                break
            else:
                continue

            pan_target = clamp_angle(pan_spec, pan_target)
            tilt_target = clamp_angle(tilt_spec, tilt_target)
            if pan_target != pan.current_angle:
                pan.move_to(pan_target, SPEED_DEG_PER_S)
            if tilt_target != tilt.current_angle:
                tilt.move_to(tilt_target, SPEED_DEG_PER_S)

    return 0


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    raise SystemExit(main())
