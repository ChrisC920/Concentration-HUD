import math

import pytest

from geometry import (
    CameraModel,
    MountGeometry,
    ema,
    estimate_distance_m,
    face_height_above_camera_m,
    pan_error_deg,
    pixel_offset_to_angle,
    rate_limit,
    tilt_angle_deg,
)


# Pi camera v2-ish: 640x480, ~62°x48°, focal_px chosen so 0.16m face at 1m → 80px wide.
CAM = CameraModel(width_px=640, height_px=480, hfov_deg=62, vfov_deg=48, focal_px=500.0)


def test_pan_error_centered_is_zero():
    assert pan_error_deg(320, CAM) == 0


def test_pan_error_right_is_positive():
    assert pan_error_deg(640, CAM) == pytest.approx(31.0)  # +half FOV


def test_pan_error_left_is_negative():
    assert pan_error_deg(0, CAM) == pytest.approx(-31.0)


def test_pixel_offset_rejects_zero_dim():
    with pytest.raises(ValueError):
        pixel_offset_to_angle(10, 60, 0)


def test_distance_inverse_in_bbox_width():
    # focal_px=500, real width=0.16m → 80px @ 1m, 40px @ 2m
    assert estimate_distance_m(80, 0.16, CAM) == pytest.approx(1.0)
    assert estimate_distance_m(40, 0.16, CAM) == pytest.approx(2.0)


def test_distance_zero_bbox_returns_inf():
    assert math.isinf(estimate_distance_m(0, 0.16, CAM))


def test_face_height_above_when_above_center():
    # face at y=240 (center) at 2m → 0
    assert face_height_above_camera_m(240, 2.0, CAM) == pytest.approx(0.0)


def test_face_height_positive_when_face_in_upper_half():
    # face at y=120 (upper half) → positive height
    h = face_height_above_camera_m(120, 2.0, CAM)
    assert h > 0


def test_face_height_negative_when_face_in_lower_half():
    h = face_height_above_camera_m(360, 2.0, CAM)
    assert h < 0


def test_tilt_zero_when_face_level_and_pivot_at_camera():
    # No mount offset, face at frame vertical center → tilt 0°
    mount = MountGeometry(0.0, 0.0)
    t = tilt_angle_deg(face_cy_px=240, bbox_width_px=80, real_face_width_m=0.16,
                       cam=CAM, mount=mount)
    assert t == pytest.approx(0.0)


def test_tilt_up_when_face_high_in_frame():
    mount = MountGeometry(0.0, 0.0)
    t = tilt_angle_deg(face_cy_px=120, bbox_width_px=80, real_face_width_m=0.16,
                       cam=CAM, mount=mount)
    assert t > 0


def test_tilt_accounts_for_camera_above_pivot():
    # Face is level with camera at 1m. Camera is 0.10m above pivot, no
    # forward offset → barrel must tilt UP to point through camera-height
    # at the face. atan2(0.10, 1.0) ≈ 5.71°.
    mount = MountGeometry(camera_height_above_pivot=0.10, camera_forward_offset=0.0)
    t = tilt_angle_deg(face_cy_px=240, bbox_width_px=80, real_face_width_m=0.16,
                       cam=CAM, mount=mount)
    assert t == pytest.approx(math.degrees(math.atan2(0.10, 1.0)), abs=0.01)


def test_tilt_handles_no_face():
    mount = MountGeometry(0.05, 0.02)
    assert tilt_angle_deg(240, 0, 0.16, CAM, mount) == 0.0


def test_rate_limit_within_step():
    assert rate_limit(10, 12, max_step=5) == 12


def test_rate_limit_clamps_positive_delta():
    assert rate_limit(10, 100, max_step=5) == 15


def test_rate_limit_clamps_negative_delta():
    assert rate_limit(10, -100, max_step=5) == 5


def test_rate_limit_rejects_zero_step():
    with pytest.raises(ValueError):
        rate_limit(0, 1, 0)


def test_ema_endpoints():
    assert ema(10, 20, alpha=1.0) == 20  # no smoothing
    assert ema(10, 20, alpha=0.5) == 15


def test_ema_rejects_invalid_alpha():
    with pytest.raises(ValueError):
        ema(0, 1, alpha=0)
    with pytest.raises(ValueError):
        ema(0, 1, alpha=1.5)
