"""Pure-Python geometry for the face tracker.

The camera pans with the turret but is FIXED in vertical orientation.
That means:
  - Pan can be a closed-loop visual servo (horizontal pixel offset is feedback).
  - Tilt is open-loop: tilting the barrel does not move the camera, so we
    have to compute the tilt angle geometrically from an estimated 3D
    position of the face.

All functions here are unit-tested on the dev machine (no hardware).
"""

from __future__ import annotations

import math
from dataclasses import dataclass


@dataclass(frozen=True)
class CameraModel:
    """Pinhole camera with horizontal/vertical FOV.

    focal_px is the calibrated focal length in pixels, derived from one
    sample: focal_px = bbox_width_px * known_distance_m / real_face_width_m.
    """

    width_px: int
    height_px: int
    hfov_deg: float
    vfov_deg: float
    focal_px: float


@dataclass(frozen=True)
class MountGeometry:
    """How the camera sits relative to the barrel's tilt pivot.

    All distances in metres. The camera is fixed level (its optical axis
    is horizontal in the turret's pan plane).

    - camera_height_above_pivot: camera optical center is this far ABOVE
      the barrel's tilt-pivot point (positive = above).
    - camera_forward_offset: camera optical center is this far FORWARD of
      the tilt pivot along the barrel's pointing direction (positive =
      ahead of pivot).
    """

    camera_height_above_pivot: float
    camera_forward_offset: float


def pixel_offset_to_angle(offset_px: float, fov_deg: float, dim_px: int) -> float:
    """Convert a pixel offset from frame center into an angle, in degrees.

    Uses the linearized focal-length form (offset / (dim/2) * fov/2). Good
    enough for the small/moderate offsets we see in tracking; full
    atan(offset/focal_px) is also fine and used in tilt below.
    """
    if dim_px <= 0:
        raise ValueError("dim_px must be positive")
    half = dim_px / 2.0
    return offset_px / half * (fov_deg / 2.0)


def pan_error_deg(face_cx_px: float, cam: CameraModel) -> float:
    """Horizontal angular error: positive = face is right of frame center."""
    offset = face_cx_px - cam.width_px / 2.0
    return pixel_offset_to_angle(offset, cam.hfov_deg, cam.width_px)


def estimate_distance_m(bbox_width_px: float, real_face_width_m: float, cam: CameraModel) -> float:
    """Pinhole distance estimate. Returns +inf for zero-width input."""
    if bbox_width_px <= 0:
        return float("inf")
    return real_face_width_m * cam.focal_px / bbox_width_px


def face_height_above_camera_m(face_cy_px: float, distance_m: float, cam: CameraModel) -> float:
    """Vertical position of the face relative to the camera's optical axis.

    Positive = face is ABOVE the camera. Uses atan via focal_px (more
    accurate than the linearized form near the frame edges).
    """
    if not math.isfinite(distance_m):
        return 0.0
    # In image coords y increases downward; "above camera" means y < cy_center.
    pixel_y_offset = (cam.height_px / 2.0) - face_cy_px
    angle_rad = math.atan2(pixel_y_offset, cam.focal_px)
    return distance_m * math.tan(angle_rad)


def tilt_angle_deg(
    face_cy_px: float,
    bbox_width_px: float,
    real_face_width_m: float,
    cam: CameraModel,
    mount: MountGeometry,
) -> float:
    """Compute the barrel tilt angle to aim at the face.

    Returns degrees, where 0 = barrel pointing horizontally forward,
    positive = barrel tilted up.

    Geometry: the camera sits at (forward_offset, height_above_pivot)
    relative to the tilt pivot, looking along +x (forward). The face is
    at (distance, face_height_above_camera) in the camera's frame, which
    is (distance + forward_offset, face_height_above_camera + height_above_pivot)
    relative to the pivot. The barrel needs to point from the pivot at
    that point.
    """
    distance = estimate_distance_m(bbox_width_px, real_face_width_m, cam)
    if not math.isfinite(distance):
        return 0.0
    face_h = face_height_above_camera_m(face_cy_px, distance, cam)

    target_x = distance + mount.camera_forward_offset
    target_y = face_h + mount.camera_height_above_pivot
    return math.degrees(math.atan2(target_y, target_x))


def rate_limit(current: float, target: float, max_step: float) -> float:
    """Clamp |target - current| to max_step. Used to limit servo slew."""
    if max_step <= 0:
        raise ValueError("max_step must be positive")
    delta = target - current
    if delta > max_step:
        return current + max_step
    if delta < -max_step:
        return current - max_step
    return target


def ema(prev: float, sample: float, alpha: float) -> float:
    """Exponential moving average. alpha in (0, 1]; higher = less smoothing."""
    if not 0.0 < alpha <= 1.0:
        raise ValueError("alpha must be in (0, 1]")
    return prev + alpha * (sample - prev)
