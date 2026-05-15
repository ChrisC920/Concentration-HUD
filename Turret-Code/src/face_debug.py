"""Face detection diagnostic without servo control."""

from __future__ import annotations

import os
import sys
import time

from tracker import CONFIG_PATH, load_config
from face_source import FaceSource


def main() -> int:
    cfg = load_config(CONFIG_PATH)
    cfg.setdefault("display", {})["show_window"] = True

    with FaceSource(cfg) as faces:
        while True:
            print(f"faces: {len(faces.latest())}", end="\r", flush=True)
            time.sleep(0.2)


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    raise SystemExit(main())
