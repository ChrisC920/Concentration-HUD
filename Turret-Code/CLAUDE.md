# CLAUDE.md — face-tracking branch

You are helping the user bring up a Raspberry Pi 5 face-tracking turret. The repo is already scaffolded; your job is to get it running on their specific hardware. Read this whole file before doing anything.

## What this branch does

Live face tracking. Pi camera → Hailo NPU face detection → pan/tilt servo control. Pan is closed-loop (camera pans with the barrel, so horizontal pixel offset is direct feedback). Tilt is **open-loop geometric** because the camera is fixed level and does NOT tilt with the barrel — vertical pixel offset is *not* feedback for tilt.

## Hardware assumptions

- Raspberry Pi 5 with Pi camera (CSI) and AI HAT (Hailo-8 / 8L)
- 2× MG996R servos: pan on GPIO 12, tilt on GPIO 13 (both hardware-PWM-capable)
- External 5–6 V / ≥3 A supply for servos. Servos NEVER powered from Pi 5V. Common ground.
- See `hardware/wiring.md` for the wiring diagram.

## What the code looks like

```
src/
  servo.py        # rpi-hardware-pwm sysfs wrapper with smooth move_to()
  geometry.py     # pure-python: pixel→angle, bbox→distance, tilt geometry
  face_source.py  # Hailo detection thread → list[Detection]   ← STUB, you must wire this up
  tracker.py      # main control loop
  calibrate.py    # interactive servo limit finder (from servo-test branch)
  manual_control.py
config.json       # camera intrinsics, mount geometry, mechanical limits, gains
tests/            # Mac-runnable unit tests for servo math + geometry
```

## What's already done

- Servo math + smooth motion: implemented and unit-tested.
- Geometry math (pinhole distance, tilt-from-mount-offsets): implemented and unit-tested.
- Tracker control loop: implemented. Reads detections, runs pan P-controller, runs open-loop tilt geometry, rate-limits and clamps, drives servos.
- All unit tests pass on a dev machine: `pytest tests/`.

## What's NOT done — your job

### 1. Hailo detection wiring (`src/face_source.py`)

The `FaceSource._run_pipeline` method is a STUB. It must be replaced with a real Hailo pipeline call that emits `tracker.Detection` instances via `self._publish([...])`. The file's docstring contains a pseudocode template. Use `~/hailo-rpi5-examples` as the reference; the most common setup is the `detection.py` GStreamer app with a YOLOv8-face HEF.

Steps to wire it up:
1. Confirm `hailo-all` is installed (`hailorun --version` should work).
2. `git clone https://github.com/hailo-ai/hailo-rpi5-examples ~/hailo-rpi5-examples` and follow its install steps.
3. Either run `tracker.py` from inside that repo's venv, or copy the relevant helper imports.
4. Implement `_run_pipeline` to:
   - Build the `GStreamerDetectionApp` with a face/person model.
   - In the per-frame callback, extract bounding boxes, filter to faces, and call `self._publish(list_of_Detection)`.
5. Test with `python src/tracker.py` — the turret should track. If it doesn't, see "Debugging" below.

### 2. Mount geometry calibration (`config.json`)

Defaults are placeholders. Tilt aim WILL be wrong until the user measures their build:

- `mount.camera_height_above_pivot_m` — from the tilt-pivot point up to the camera lens.
- `mount.camera_forward_offset_m` — from the tilt-pivot horizontally forward to the camera lens.
- `camera.focal_px` — calibrate by holding a face at a known distance (default real width = 0.16 m) and reading bounding-box pixel width: `focal_px = bbox_width_px * distance_m / 0.16`.

These values live in `config.json`. Don't change the code; change the config.

### 3. Verify mechanical limits

If the user hasn't yet run `src/calibrate.py` from the servo-test branch, recommend they do so before running `tracker.py`. Otherwise the servos may try to drive past their stops and stall/buzz.

## Run order on a freshly-cloned repo

```bash
# 0) One-time: enable PWM overlay in /boot/firmware/config.txt and reboot.
echo 'dtoverlay=pwm-2chan,pin=12,func=4,pin2=13,func2=4' | sudo tee -a /boot/firmware/config.txt
sudo apt install -y hailo-all python3-picamera2
sudo reboot
# After reboot:
git clone https://github.com/ChrisC920/turret.git
cd turret
python3 -m venv --system-site-packages .venv
source .venv/bin/activate
pip install -r requirements.txt

git checkout servo-test
sudo .venv/bin/python src/calibrate.py        # writes config.json
sudo .venv/bin/python src/manual_control.py   # confirm smooth motion

git checkout face-tracking
# Edit config.json: set mount.* and camera.focal_px from measurements.
# Edit src/face_source.py: replace _run_pipeline stub with a Hailo pipeline.
sudo .venv/bin/python src/tracker.py
```

`sudo` is needed because `rpi-hardware-pwm` writes to `/sys/class/pwm/pwmchip0/export` which is root-owned by default. Add a udev rule (see the rpi-hardware-pwm README) if you want to drop sudo.

The sysfs chip number is kernel-dependent: kernel ≥ 6.12 (Bookworm with current updates) puts the RP1 PWM block at `pwmchip0`; older Pi 5 kernels put it at `pwmchip2`. Confirm with `sudo cat /sys/kernel/debug/pwm` — the chip whose `pwm-0`/`pwm-1` are claimed by `sysfs` after the overlay loads is the one to use, and that's the value of `PWM_CHIP` in `src/servo.py`.

## Tuning playbook

| Symptom | Knob in `config.json` |
|---|---|
| Pan oscillates around the face | lower `tracker.pan_p_gain` |
| Pan lags behind a moving face | raise `tracker.pan_p_gain` |
| Pan moves the wrong direction | flip the sign of `tracker.pan_p_gain` (mounting-dependent) |
| Pan jitters when face is centered | raise `tracker.deadband_deg` |
| Tilt aim is off by a constant amount | adjust `mount.camera_height_above_pivot_m` (or recalibrate `camera.focal_px`) |
| Tilt jitters | lower `tracker.tilt_smoothing_alpha` (more smoothing) |
| Servos buzz at extremes | tighten `pan.min_angle` / `pan.max_angle` and same for tilt |

## Debugging

- **Servos move but no detection**: print `len(faces.latest())` in the control loop. If always 0, the Hailo pipeline isn't publishing; debug `face_source.py` first.
- **Pi browns out / reboots when servos move**: the servos are powered from the Pi. Stop everything and fix the wiring. See `hardware/wiring.md`.
- **`FileNotFoundError: /sys/class/pwm/pwmchipN`**: either the PWM overlay isn't enabled, or `PWM_CHIP` in `src/servo.py` doesn't match this kernel's numbering. First confirm the dtoverlay line is in `/boot/firmware/config.txt` under `[all]` (NOT `[cm5]`), reboot, then `sudo cat /sys/kernel/debug/pwm` and use the chip whose `pwm-0`/`pwm-1` are claimed by `sysfs`. Kernel ≥ 6.12 → chip 0; older Pi 5 kernels → chip 2.
- **`PermissionError` on `/sys/class/pwm/...`**: run with `sudo` or add a udev rule.
- **PWM channel `Device or resource busy`**: previous run didn't release. `sudo bash -c 'echo 0 > /sys/class/pwm/pwmchip0/unexport; echo 1 > /sys/class/pwm/pwmchip0/unexport'` (substitute the correct chip number), or reboot.
- **Tilt always points up/down**: check sign of `mount.camera_height_above_pivot_m`. Positive = camera ABOVE the pivot.
- **Tracker tracks the wrong face in a crowd**: `pick_target` in `tracker.py` selects the largest bounding box. Change to "closest to current aim" if needed.

## Constraints when modifying code

- Don't power servos from the Pi. Don't suggest configurations that do.
- The camera is FIXED level. Do not write tilt control that treats vertical pixel offset as direct error feedback — it isn't. Tilt must remain geometric.
- Use `rpi-hardware-pwm` only. Do NOT switch to `lgpio`, `pigpio`, `RPi.GPIO`, or `gpiozero` — the user has explicitly ruled those out.
- Pure-math functions stay in `geometry.py` / `servo.py` so unit tests run on the dev machine. Don't move math into the I/O layers.
- Run `pytest tests/` after any edit to math or control logic.
