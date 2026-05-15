"""MG996R servo control via sysfs hardware PWM on Raspberry Pi 5.

Uses the `rpi-hardware-pwm` package, which talks directly to
/sys/class/pwm/pwmchip0 — no lgpio, no pigpio. Requires the PWM
overlay to be enabled on the Pi:

    /boot/firmware/config.txt:
        dtoverlay=pwm-2chan,pin=12,func=4,pin2=13,func2=4

then reboot. After that, GPIO 12 → PWM channel 0 and GPIO 13 →
channel 1. Sysfs chip number is kernel-dependent: kernel ≥ 6.12 puts
the RP1 PWM block at chip 0; older Pi 5 kernels used chip 2. Confirm
with `sudo cat /sys/kernel/debug/pwm` — the chip whose pwm-0/pwm-1
are claimed by `sysfs` is the one to use.

The Servo class is split into a pure-python math layer (angle_to_duty,
clamp_angle, plan_steps) and a thin I/O layer so the math is testable
on a Mac without rpi-hardware-pwm installed.
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass
from typing import Iterator, Optional


# On Pi 5 with kernel ≥ 6.12 the GPIO PWM lives on pwmchip0.
PWM_CHIP = 0
# Maps BCM GPIO pin → rpi-hardware-pwm channel index on PWM_CHIP.
GPIO_TO_PWM_CHANNEL = {12: 0, 18: 0, 13: 1, 19: 1}


@dataclass(frozen=True)
class ServoSpec:
    gpio: int
    min_us: int = 500
    max_us: int = 2500
    freq_hz: int = 50
    min_angle: float = 0.0
    max_angle: float = 180.0
    # Physical angle span used for pulse interpolation.
    # Keep this at the servo's real span (typically 0..180). min_angle/max_angle
    # remain logical safety limits for commanded motion.
    physical_min_angle: float = 0.0
    physical_max_angle: float = 180.0


def clamp_angle(spec: ServoSpec, angle: float) -> float:
    if angle < spec.min_angle:
        return spec.min_angle
    if angle > spec.max_angle:
        return spec.max_angle
    return angle


def angle_to_pulse_us(spec: ServoSpec, angle: float) -> float:
    a = clamp_angle(spec, angle)
    span_angle = spec.physical_max_angle - spec.physical_min_angle
    if span_angle <= 0:
        raise ValueError("physical_max_angle must be greater than physical_min_angle")
    span_us = spec.max_us - spec.min_us
    return spec.min_us + (a - spec.physical_min_angle) / span_angle * span_us


def angle_to_duty_pct(spec: ServoSpec, angle: float) -> float:
    period_us = 1_000_000.0 / spec.freq_hz
    return angle_to_pulse_us(spec, angle) / period_us * 100.0


def gpio_to_pwm_channel(gpio: int) -> int:
    if gpio not in GPIO_TO_PWM_CHANNEL:
        raise ValueError(
            f"GPIO {gpio} is not a hardware-PWM pin on Pi 5. "
            f"Use one of: {sorted(GPIO_TO_PWM_CHANNEL)}."
        )
    return GPIO_TO_PWM_CHANNEL[gpio]


def plan_steps(
    start_angle: float,
    end_angle: float,
    speed_deg_per_s: float,
    tick_hz: float = 50.0,
) -> Iterator[float]:
    """Yield intermediate angles for a smooth move at constant angular velocity.

    The final yielded value is exactly end_angle so the caller doesn't have
    to do its own correction.
    """
    if speed_deg_per_s <= 0:
        raise ValueError("speed_deg_per_s must be positive")
    if tick_hz <= 0:
        raise ValueError("tick_hz must be positive")

    delta = end_angle - start_angle
    if delta == 0:
        yield end_angle
        return

    step = speed_deg_per_s / tick_hz
    direction = 1.0 if delta > 0 else -1.0
    n_steps = int(abs(delta) // step)
    current = start_angle
    for _ in range(n_steps):
        current += direction * step
        yield current
    if current != end_angle:
        yield end_angle


class Servo:
    """Hardware-PWM servo on a single GPIO via rpi-hardware-pwm.

    Usage:
        with Servo(ServoSpec(gpio=12)) as s:
            s.move_to(90, speed_deg_per_s=60)
            s.stop()
    """

    def __init__(self, spec: ServoSpec, chip: int = PWM_CHIP):
        self.spec = spec
        self.chip = chip
        self._channel = gpio_to_pwm_channel(spec.gpio)
        self._pwm = None
        self._current_angle: float = (spec.min_angle + spec.max_angle) / 2.0

    def __enter__(self) -> "Servo":
        from rpi_hardware_pwm import HardwarePWM  # imported lazily

        self._pwm = HardwarePWM(
            pwm_channel=self._channel,
            hz=self.spec.freq_hz,
            chip=self.chip,
        )
        # Start with the center duty so the servo doesn't snap on init.
        self._pwm.start(angle_to_duty_pct(self.spec, self._current_angle))
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        try:
            self.stop()
        finally:
            self._pwm = None

    @property
    def current_angle(self) -> float:
        return self._current_angle

    def grant_user_access(self, uid: int, gid: int) -> None:
        """Allow a non-root user to keep driving an already-exported PWM."""
        if self._pwm is None:
            raise RuntimeError("Servo not opened")

        paths = [
            self._pwm.pwm_dir,
            os.path.join(self._pwm.pwm_dir, "period"),
            os.path.join(self._pwm.pwm_dir, "duty_cycle"),
            os.path.join(self._pwm.pwm_dir, "enable"),
        ]
        for path in paths:
            if not os.path.exists(path):
                continue
            os.chown(path, uid, gid)
            if os.path.isdir(path):
                os.chmod(path, 0o755)
            else:
                os.chmod(path, 0o664)

    def set_angle(self, angle: float) -> None:
        """Snap to angle (no smoothing). Most callers want move_to."""
        if self._pwm is None:
            raise RuntimeError("Servo not opened (use 'with Servo(...)')")
        a = clamp_angle(self.spec, angle)
        self._pwm.change_duty_cycle(angle_to_duty_pct(self.spec, a))
        self._current_angle = a

    def move_to(self, angle: float, speed_deg_per_s: float = 90.0, tick_hz: float = 50.0) -> None:
        """Smooth move from current angle to target at constant angular speed.

        Blocks for the duration of the move. MG996Rs jerk hard if you snap
        them; this loop interpolates so the motion looks smooth.
        """
        if self._pwm is None:
            raise RuntimeError("Servo not opened")
        target = clamp_angle(self.spec, angle)
        period = 1.0 / tick_hz
        for step in plan_steps(self._current_angle, target, speed_deg_per_s, tick_hz):
            self.set_angle(step)
            time.sleep(period)

    def stop(self) -> None:
        """Release the PWM line so the servo isn't held against load."""
        if self._pwm is None:
            return
        try:
            self._pwm.stop()
        except Exception:
            pass
