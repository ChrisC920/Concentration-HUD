"""Face detection source (Pi-only).

Runs a Hailo SCRFD face detector on Pi camera frames in a background
thread and exposes a `latest()` method that returns a list of
`tracker.Detection` objects in the (post-rotation) image-pixel frame
that the tracker / config.json describes.

Pipeline mirrors the standalone detect.py reference:
  picamera2 (CAM0, 1280x720, BGR888)
    → rotate 90° CW → frame is 720 wide × 1280 tall
    → resize to 640x640 → Hailo SCRFD (UINT8 in, FLOAT32 out)
    → decode 3 detection heads (strides 8, 16, 32) → cv2.dnn.NMSBoxes
    → publish boxes in pixel coords of the rotated frame.

Tracker uses config.json's camera.width_px/height_px to interpret the
returned cx,cy,width,height — they must match the rotated frame
(720 × 1280) for pan_error_deg / tilt geometry to be correct.
"""

from __future__ import annotations

import collections
import site
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import TYPE_CHECKING


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
import numpy as np

print(f"FaceSource: numpy {np.__version__} from {np.__file__}")
print(f"FaceSource: cv2 {cv2.__version__} from {cv2.__file__}")

if TYPE_CHECKING:
    from tracker import Detection


HEF_PATH = "/usr/share/hailo-models/scrfd_2.5g_h8l.hef"
CAMERA_INDEX = 0
CAPTURE_SIZE = (1280, 720)  # picamera2 main stream; rotated 90 CW → 720x1280
CONF_THRESH = 0.55
NMS_IOU_THRESH = 0.4
INPUT_SIZE = 640
VSTREAM_TIMEOUT_MS = 60_000

# (cls_key, bbox_key, stride) — SCRFD 2.5g head names from the HEF.
_HEADS = [
    ("scrfd_2_5g/conv42", "scrfd_2_5g/conv43", 8),
    ("scrfd_2_5g/conv49", "scrfd_2_5g/conv50", 16),
    ("scrfd_2_5g/conv55", "scrfd_2_5g/conv56", 32),
]


def _make_vstream_params(factory, network_group, format_type):
    try:
        return factory.make(
            network_group,
            format_type=format_type,
            timeout_ms=VSTREAM_TIMEOUT_MS,
        )
    except TypeError:
        # Older pyHailoRT wheels may not expose timeout_ms as a Python kwarg.
        return factory.make(network_group, format_type=format_type)


def _preprocess(frame: np.ndarray, input_w: int = INPUT_SIZE, input_h: int = INPUT_SIZE) -> np.ndarray:
    resized = cv2.resize(frame, (input_w, input_h))
    return np.ascontiguousarray(resized[None, :, :, :], dtype=np.uint8)


def _decode_outputs(
    raw_outputs,
    conf_thresh: float,
    input_w: int = INPUT_SIZE,
    input_h: int = INPUT_SIZE,
):
    boxes_out = []
    scores_out = []

    for cls_key, bbox_key, stride in _HEADS:
        cls_raw = raw_outputs[cls_key][0]
        bbox_raw = raw_outputs[bbox_key][0]
        feat_h, feat_w = cls_raw.shape[:2]

        gy, gx = np.meshgrid(np.arange(feat_h), np.arange(feat_w), indexing="ij")
        cx = (gx + 0.5) * stride
        cy = (gy + 0.5) * stride

        bbox = bbox_raw.reshape(feat_h, feat_w, 2, 4)
        for a in range(2):
            score = cls_raw[:, :, a]
            mask = score >= conf_thresh
            if not mask.any():
                continue

            l = bbox[:, :, a, 0] * stride
            t = bbox[:, :, a, 1] * stride
            r = bbox[:, :, a, 2] * stride
            b = bbox[:, :, a, 3] * stride

            x1 = np.clip((cx - l) / input_w, 0, 1)
            y1 = np.clip((cy - t) / input_h, 0, 1)
            x2 = np.clip((cx + r) / input_w, 0, 1)
            y2 = np.clip((cy + b) / input_h, 0, 1)

            valid = (
                mask
                & (x2 > x1 + 0.01)
                & (y2 > y1 + 0.01)
                & ((x2 - x1) < 0.95)
                & ((y2 - y1) < 0.95)
            )
            if not valid.any():
                continue

            boxes_out.append(np.stack([x1[valid], y1[valid], x2[valid], y2[valid]], axis=1))
            scores_out.append(score[valid])

    if not boxes_out:
        return []

    boxes = np.concatenate(boxes_out, axis=0)
    scores = np.concatenate(scores_out, axis=0)

    x1, y1, x2, y2 = boxes[:, 0], boxes[:, 1], boxes[:, 2], boxes[:, 3]
    indices = cv2.dnn.NMSBoxes(
        bboxes=np.stack([x1, y1, x2 - x1, y2 - y1], axis=1).tolist(),
        scores=scores.tolist(),
        score_threshold=conf_thresh,
        nms_threshold=NMS_IOU_THRESH,
    )
    if len(indices) == 0:
        return []
    indices = indices.flatten()
    return [
        (boxes[i, 0], boxes[i, 1], boxes[i, 2], boxes[i, 3], scores[i])
        for i in indices
    ]


def _apply_mirror(frame: np.ndarray, mirror_horizontal: bool) -> np.ndarray:
    if not mirror_horizontal:
        return frame
    return cv2.flip(frame, 1)


class FaceSource:
    def __init__(self, cfg: dict, show_window: bool | None = None):
        self.cfg = cfg
        # Headless is the safest default for sudo/SSH turret runs. Add
        # {"display": {"show_window": true}} to config.json for debug video.
        if show_window is None:
            show_window = cfg.get("display", {}).get("show_window", False)
        self.show_window = show_window
        self.mirror_horizontal = cfg.get("camera", {}).get("mirror_horizontal", False)
        self._latest: list = []
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._frame_ready = threading.Condition()
        self._pending_input: np.ndarray | None = None
        self._pending_seq = 0
        self._debug_dets = []
        self._clip_duration_s = float(cfg.get("web", {}).get("clip_duration_s", 5.0))
        self._clip_jpeg_quality = int(cfg.get("web", {}).get("clip_jpeg_quality", 80))
        self._clip_buffer: "collections.deque[tuple[float, bytes]]" = collections.deque()
        self._clip_buffer_lock = threading.Lock()

    def __enter__(self) -> "FaceSource":
        self._thread = threading.Thread(target=self._run_pipeline, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2.0)

    def latest(self) -> list:
        with self._lock:
            return list(self._latest)

    def _publish(self, detections: list) -> None:
        with self._lock:
            self._latest = detections

    def _record_clip_frame(self, frame: np.ndarray) -> None:
        ok, jpg = cv2.imencode(
            ".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), self._clip_jpeg_quality]
        )
        if not ok:
            return
        now = time.monotonic()
        cutoff = now - self._clip_duration_s
        with self._clip_buffer_lock:
            self._clip_buffer.append((now, jpg.tobytes()))
            while self._clip_buffer and self._clip_buffer[0][0] < cutoff:
                self._clip_buffer.popleft()

    def save_clip(self, path: Path) -> dict:
        # Wait for the rolling buffer to refill with frames captured AFTER
        # this call, so the clip covers the post-trigger window.
        time.sleep(self._clip_duration_s)
        with self._clip_buffer_lock:
            frames = list(self._clip_buffer)
        if len(frames) < 2:
            return {"ok": False, "error": "buffer_empty", "frames": len(frames)}

        duration = frames[-1][0] - frames[0][0]
        fps = max(1.0, len(frames) / max(duration, 1e-3))

        path = Path(path)
        tmp = path.with_name(path.name + ".tmp")
        try:
            if tmp.exists():
                tmp.unlink()
        except OSError:
            pass

        # Pipe the existing JPEG buffer into ffmpeg's mjpeg demuxer; it
        # transcodes once to H.264. Avoids cv2.VideoWriter, which on
        # Debian's headless opencv silently produces 0-byte mp4s.
        cmd = [
            "ffmpeg",
            "-y",
            "-loglevel", "error",
            "-f", "mjpeg",
            "-framerate", f"{fps:.3f}",
            "-i", "-",
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-pix_fmt", "yuv420p",
            "-movflags", "+faststart",
            "-f", "mp4",
            str(tmp),
        ]
        try:
            proc = subprocess.Popen(
                cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE
            )
        except FileNotFoundError:
            return {"ok": False, "error": "ffmpeg_not_found"}

        try:
            for _, jpg in frames:
                proc.stdin.write(jpg)
            proc.stdin.close()
        except BrokenPipeError:
            pass
        try:
            stderr = proc.stderr.read().decode("utf-8", "replace")
        finally:
            rc = proc.wait()

        if rc != 0 or not tmp.exists() or tmp.stat().st_size == 0:
            return {
                "ok": False,
                "error": "ffmpeg_failed",
                "rc": rc,
                "stderr": stderr.strip()[:500],
            }

        try:
            tmp.chmod(0o644)
            tmp.replace(path)
        except OSError as exc:
            return {"ok": False, "error": "rename_failed", "details": str(exc)}
        return {
            "ok": True,
            "path": "/last_clip.mp4",
            "bytes": path.stat().st_size,
            "duration_s": duration,
            "fps": fps,
            "frames": len(frames),
        }

    def _submit_frame(self, model_input: np.ndarray) -> None:
        with self._frame_ready:
            # Keep only the freshest frame so slow inference does not build lag.
            self._pending_input = model_input
            self._pending_seq += 1
            self._frame_ready.notify()

    def _draw_debug(self, frame: np.ndarray, window_name: str) -> None:
        fh, fw = frame.shape[:2]
        for x1, y1, x2, y2, score in self._debug_dets:
            pt1 = (int(x1 * fw), int(y1 * fh))
            pt2 = (int(x2 * fw), int(y2 * fh))
            cv2.rectangle(frame, pt1, pt2, (0, 255, 0), 2)
            cv2.putText(
                frame,
                f"{score:.2f}",
                (pt1[0], max(pt1[1] - 6, 10)),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.55,
                (0, 255, 0),
                2,
            )
        cv2.putText(
            frame,
            f"Faces: {len(self._debug_dets)}",
            (10, 30),
            cv2.FONT_HERSHEY_SIMPLEX,
            1.0,
            (0, 255, 0),
            2,
        )
        cv2.imshow(window_name, frame)
        if cv2.waitKey(1) & 0xFF == ord("q"):
            self._stop.set()

    def _run_inference_loop(
        self,
        network_group,
        network_group_params,
        input_params,
        output_params,
        input_name: str,
        input_w: int,
        input_h: int,
        cam_w: int,
        cam_h: int,
        detection_cls,
    ) -> None:
        from hailo_platform import InferVStreams

        last_seq = 0
        try:
            with InferVStreams(network_group, input_params, output_params) as pipeline:
                with network_group.activate(network_group_params):
                    while not self._stop.is_set():
                        with self._frame_ready:
                            self._frame_ready.wait_for(
                                lambda: self._stop.is_set() or self._pending_seq != last_seq,
                                timeout=0.5,
                            )
                            if self._stop.is_set():
                                break
                            model_input = self._pending_input
                            last_seq = self._pending_seq

                        if model_input is None:
                            continue

                        try:
                            raw = pipeline.infer({input_name: model_input})
                        except Exception as exc:
                            print(f"FaceSource: Hailo inference failed: {exc!r}")
                            self._publish([])
                            self._debug_dets = []
                            self._stop.set()
                            break

                        dets = _decode_outputs(raw, CONF_THRESH, input_w, input_h)
                        out = []
                        for x1, y1, x2, y2, _score in dets:
                            w_px = (x2 - x1) * cam_w
                            h_px = (y2 - y1) * cam_h
                            cx = (x1 + x2) * 0.5 * cam_w
                            cy = (y1 + y2) * 0.5 * cam_h
                            out.append(detection_cls(cx, cy, w_px, h_px))
                        self._debug_dets = dets
                        self._publish(out)
        except Exception as exc:
            print(f"FaceSource: inference worker failed: {exc!r}")
            self._publish([])
            self._debug_dets = []
            self._stop.set()

    def _run_pipeline(self) -> None:
        # Imports are lazy: hailo_platform / picamera2 only exist on the Pi.
        from hailo_platform import (
            HEF,
            VDevice,
            HailoStreamInterface,
            InferVStreams,
            InputVStreamParams,
            OutputVStreamParams,
            FormatType,
            ConfigureParams,
        )
        from picamera2 import Picamera2

        from tracker import Detection

        cam_w = self.cfg["camera"]["width_px"]
        cam_h = self.cfg["camera"]["height_px"]

        hef = HEF(HEF_PATH)
        with VDevice() as target:
            configure_params = ConfigureParams.create_from_hef(
                hef, interface=HailoStreamInterface.PCIe
            )
            network_groups = target.configure(hef, configure_params)
            network_group = network_groups[0]
            network_group_params = network_group.create_params()

            input_info = hef.get_input_vstream_infos()[0]
            input_h, input_w = input_info.shape[:2]
            print(f"FaceSource: model input {input_w}x{input_h}")

            input_params = _make_vstream_params(
                InputVStreamParams, network_group, FormatType.UINT8
            )
            output_params = _make_vstream_params(
                OutputVStreamParams, network_group, FormatType.FLOAT32
            )

            picam2 = Picamera2(camera_num=CAMERA_INDEX)
            cam_cfg = picam2.create_preview_configuration(
                main={"size": CAPTURE_SIZE, "format": "BGR888"}
            )
            picam2.configure(cam_cfg)
            picam2.start()

            window_name = "Turret face tracking"
            infer_thread = threading.Thread(
                target=self._run_inference_loop,
                args=(
                    network_group,
                    network_group_params,
                    input_params,
                    output_params,
                    input_info.name,
                    input_w,
                    input_h,
                    cam_w,
                    cam_h,
                    Detection,
                ),
                daemon=True,
            )
            infer_thread.start()
            try:
                while not self._stop.is_set():
                    frame = picam2.capture_array("main")
                    if frame is None:
                        continue
                    frame = cv2.rotate(frame, cv2.ROTATE_90_CLOCKWISE)
                    frame = _apply_mirror(frame, self.mirror_horizontal)
                    self._record_clip_frame(frame)
                    self._submit_frame(_preprocess(frame, input_w, input_h))

                    if self.show_window:
                        self._draw_debug(frame, window_name)
            finally:
                self._stop.set()
                with self._frame_ready:
                    self._frame_ready.notify_all()
                infer_thread.join(timeout=2.0)
                picam2.stop()
                if self.show_window:
                    cv2.destroyAllWindows()
