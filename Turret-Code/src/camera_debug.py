"""Camera/display-only diagnostic for the turret.

This deliberately avoids Hailo and servo imports. Use it to confirm the
Pi camera and OpenCV window are live before debugging inference.
"""

from __future__ import annotations

import site
import sys
import time


def _drop_user_site_packages() -> None:
    """Prefer Raspberry Pi apt/venv packages over ~/.local binary wheels."""
    user_site = site.getusersitepackages()
    if isinstance(user_site, str):
        user_sites = {user_site}
    else:
        user_sites = set(user_site)
    sys.path[:] = [
        path
        for path in sys.path
        if path not in user_sites
        and "/.local/lib/python" not in path
    ]


_drop_user_site_packages()

import cv2
from picamera2 import Picamera2


CAMERA_INDEX = 0
CAPTURE_SIZE = (1280, 720)


def main() -> int:
    picam2 = Picamera2(camera_num=CAMERA_INDEX)
    config = picam2.create_preview_configuration(
        main={"size": CAPTURE_SIZE, "format": "BGR888"}
    )
    picam2.configure(config)
    picam2.start()

    window_name = "Camera debug"
    last = time.monotonic()
    fps = 0.0
    try:
        while True:
            frame = picam2.capture_array("main")
            frame = cv2.rotate(frame, cv2.ROTATE_90_CLOCKWISE)

            now = time.monotonic()
            if now > last:
                fps = 1.0 / (now - last)
            last = now

            cv2.putText(
                frame,
                f"Camera only  FPS: {fps:.1f}",
                (10, 30),
                cv2.FONT_HERSHEY_SIMPLEX,
                1.0,
                (0, 255, 0),
                2,
            )
            cv2.imshow(window_name, frame)
            if cv2.waitKey(1) & 0xFF == ord("q"):
                break
    finally:
        picam2.stop()
        cv2.destroyAllWindows()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
