"""Servo/PWM diagnostic without camera or Hailo."""

from __future__ import annotations

import os
import sys
import time

from tracker import load_config, make_servo_spec
from servo import PWM_CHIP, Servo


def main() -> int:
    cfg = load_config()
    pan_spec = make_servo_spec(cfg["pan"], cfg["servo"])
    tilt_spec = make_servo_spec(cfg["tilt"], cfg["servo"])

    print(f"Opening pan GPIO {pan_spec.gpio} on pwmchip{PWM_CHIP}")
    with Servo(pan_spec) as pan:
        print(f"Opening tilt GPIO {tilt_spec.gpio} on pwmchip{PWM_CHIP}")
        with Servo(tilt_spec) as tilt:
            print("Moving to configured centers")
            pan.move_to(cfg["pan"]["center"], speed_deg_per_s=60)
            tilt.move_to(cfg["tilt"]["center"], speed_deg_per_s=60)
            time.sleep(0.5)

            print("Sweeping pan")
            pan.move_to(cfg["pan"]["min_angle"], speed_deg_per_s=45)
            pan.move_to(cfg["pan"]["max_angle"], speed_deg_per_s=45)
            pan.move_to(cfg["pan"]["center"], speed_deg_per_s=45)

            print("Sweeping tilt")
            tilt.move_to(cfg["tilt"]["min_angle"], speed_deg_per_s=45)
            tilt.move_to(cfg["tilt"]["max_angle"], speed_deg_per_s=45)
            tilt.move_to(cfg["tilt"]["center"], speed_deg_per_s=45)

    print("Done")
    return 0


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    raise SystemExit(main())
