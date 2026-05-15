import math

import pytest

from servo import ServoSpec, angle_to_duty_pct, angle_to_pulse_us, clamp_angle, plan_steps


SPEC = ServoSpec(gpio=12)  # defaults: 500–2500us, 50Hz, 0–180°


def test_clamp_below_min():
    assert clamp_angle(SPEC, -10) == 0


def test_clamp_above_max():
    assert clamp_angle(SPEC, 999) == 180


def test_clamp_in_range():
    assert clamp_angle(SPEC, 45) == 45


def test_pulse_endpoints():
    assert angle_to_pulse_us(SPEC, 0) == 500
    assert angle_to_pulse_us(SPEC, 180) == 2500


def test_pulse_midpoint():
    assert angle_to_pulse_us(SPEC, 90) == pytest.approx(1500.0)


def test_pulse_clamps_out_of_range():
    assert angle_to_pulse_us(SPEC, -50) == 500
    assert angle_to_pulse_us(SPEC, 250) == 2500


def test_duty_at_center_is_7_5_percent():
    # 1500us / 20000us period = 7.5%
    assert angle_to_duty_pct(SPEC, 90) == pytest.approx(7.5)


def test_duty_at_min():
    assert angle_to_duty_pct(SPEC, 0) == pytest.approx(2.5)


def test_duty_at_max():
    assert angle_to_duty_pct(SPEC, 180) == pytest.approx(12.5)


def test_plan_steps_zero_delta_yields_endpoint_only():
    out = list(plan_steps(45, 45, speed_deg_per_s=60))
    assert out == [45]


def test_plan_steps_increasing_ends_exactly_at_target():
    out = list(plan_steps(0, 90, speed_deg_per_s=180, tick_hz=50))
    # step size = 180/50 = 3.6 deg per tick → 25 steps + final correction
    assert out[-1] == 90
    assert all(out[i] < out[i + 1] for i in range(len(out) - 1))


def test_plan_steps_decreasing():
    out = list(plan_steps(90, 0, speed_deg_per_s=180, tick_hz=50))
    assert out[-1] == 0
    assert all(out[i] > out[i + 1] for i in range(len(out) - 1))


def test_plan_steps_speed_respected():
    # at 60 deg/s with 60 Hz tick, step = 1 deg → 30 increments to span 30 deg
    out = list(plan_steps(0, 30, speed_deg_per_s=60, tick_hz=60))
    assert out[-1] == 30
    # Each intermediate step should be ~1 degree apart
    for i in range(len(out) - 2):
        assert math.isclose(out[i + 1] - out[i], 1.0, abs_tol=1e-9)


def test_plan_steps_rejects_zero_speed():
    with pytest.raises(ValueError):
        list(plan_steps(0, 90, speed_deg_per_s=0))


def test_custom_range_and_pulses():
    spec = ServoSpec(
        gpio=12,
        min_us=1000,
        max_us=2000,
        min_angle=-45,
        max_angle=45,
        physical_min_angle=-45,
        physical_max_angle=45,
    )
    assert angle_to_pulse_us(spec, -45) == 1000
    assert angle_to_pulse_us(spec, 45) == 2000
    assert angle_to_pulse_us(spec, 0) == pytest.approx(1500)


def test_logical_limits_do_not_rescale_pulse_span():
    spec = ServoSpec(
        gpio=12,
        min_us=500,
        max_us=2500,
        min_angle=120,
        max_angle=130,
        physical_min_angle=0,
        physical_max_angle=180,
    )
    # 120..130 is a narrow command window, so pulses should only move a little.
    assert angle_to_pulse_us(spec, 120) == pytest.approx(1833.3333333)
    assert angle_to_pulse_us(spec, 130) == pytest.approx(1944.4444444)
