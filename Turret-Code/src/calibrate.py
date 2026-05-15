"""Interactive servo calibration.

Sweeps each servo through its range and lets the user record the
mechanical limits + center positions, then writes config.json.
Run this once after assembly.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from servo import Servo, ServoSpec, angle_to_pulse_us


CONFIG_PATH = Path(__file__).resolve().parent.parent / "config.json"


def prompt_float(msg: str, default: float) -> float:
    raw = input(f"{msg} [{default}]: ").strip()
    if not raw:
        return default
    return float(raw)


def calibrate_axis(name: str, gpio: int) -> dict:
    print(f"\n=== {name} servo on GPIO {gpio} ===")
    spec = ServoSpec(gpio=gpio)

    with Servo(spec) as s:
        print("Sweeping 0° → 180° slowly. Watch for buzzing or stalling.")
        s.move_to(0, speed_deg_per_s=30)
        s.move_to(180, speed_deg_per_s=30)
        s.move_to(90, speed_deg_per_s=30)

        print("\nNow we'll find your mechanical limits.")
        print("Type an angle to send the servo there. Empty input ends.")
        print("Find the smallest angle that doesn't stall, and the largest.")

        while True:
            raw = input("angle> ").strip()
            if not raw:
                break
            try:
                a = float(raw)
            except ValueError:
                print("not a number")
                continue
            s.move_to(a, speed_deg_per_s=60)
            print(f"  pulse ≈ {angle_to_pulse_us(spec, a):.0f} µs")

        min_a = prompt_float("safe minimum angle", 10.0)
        max_a = prompt_float("safe maximum angle", 170.0)
        center = prompt_float("center angle", (min_a + max_a) / 2)
        s.move_to(center, speed_deg_per_s=60)

    return {"gpio": gpio, "min_angle": min_a, "max_angle": max_a, "center": center}


def main() -> int:
    print("Turret servo calibration")
    print("Make sure the servo power supply is on.\n")

    pan = calibrate_axis("PAN (horizontal)", gpio=12)
    tilt = calibrate_axis("TILT (vertical)", gpio=13)

    config = {
        "pan": pan,
        "tilt": tilt,
        "servo": {"min_us": 500, "max_us": 2500, "freq_hz": 50},
    }
    if CONFIG_PATH.exists():
        with CONFIG_PATH.open() as f:
            existing = json.load(f)
        existing.update(config)
        config = existing

    with CONFIG_PATH.open("w") as f:
        json.dump(config, f, indent=2)
    print(f"\nWrote {CONFIG_PATH}")
    return 0


if __name__ == "__main__":
    # Ensure local imports work when run as a script.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    raise SystemExit(main())
