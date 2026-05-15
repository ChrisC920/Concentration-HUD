# Turret

Face-tracking pan/tilt turret on a Raspberry Pi 5 + AI HAT (Hailo) using two MG996R servos and the Pi camera.

## Hardware

- Raspberry Pi 5
- Raspberry Pi AI HAT (Hailo-8 / 8L)
- Raspberry Pi camera (CSI)
- 2× MG996R servos
- External 5–6 V / ≥3 A power supply for the servos (do **not** power servos from the Pi 5V rail)

See [`hardware/wiring.md`](hardware/wiring.md) for pin map and power notes.

### Mechanical note

The camera is mounted on the turret's pan (horizontal) plane but is **fixed in vertical orientation**: it pans with the barrel but does not tilt with it. Pan tracking is closed-loop visual servoing; tilt is computed open-loop from estimated face distance and the camera-to-pivot geometry in `config.json`.

## Branches

| Branch | What it does |
|---|---|
| `main` | scaffolding only |
| `servo-test` | verify each servo moves independently and smoothly (no vision) |
| `face-tracking` | full Hailo face detection → pan/tilt servo loop |

Start on `servo-test` to confirm the hardware is wired correctly before bringing up vision.

## Install (on the Pi)

```bash
sudo apt install -y python3-picamera2
git clone https://github.com/<you>/turret.git
cd turret
python3 -m venv --system-site-packages .venv
source .venv/bin/activate
pip install -r requirements.txt
```

The servo code uses `rpi-hardware-pwm` (sysfs PWM, no `lgpio`/`pigpio`). You must enable the PWM overlay once: add `dtoverlay=pwm-2chan,pin=12,func=4,pin2=13,func2=4` to `/boot/firmware/config.txt` and reboot. See [`hardware/wiring.md`](hardware/wiring.md). `rpi-hardware-pwm` typically needs root or a udev rule to write to `/sys/class/pwm/pwmchip2`; the simplest path is `sudo python src/...` for the servo scripts.

For the `face-tracking` branch you also need the Hailo runtime and the official examples:

```bash
# Follow https://www.raspberrypi.com/documentation/computers/ai.html for hailo-all
sudo apt install -y hailo-all
git clone https://github.com/hailo-ai/hailo-rpi5-examples.git ~/hailo-rpi5-examples
```

## Run

```bash
# Branch: servo-test
git checkout servo-test
python src/calibrate.py        # find mechanical limits, write config.json
python src/manual_control.py   # arrow keys to nudge each axis

# Branch: face-tracking
git checkout face-tracking
# 1) Measure mount geometry and put it in config.json:
#    - mount.camera_height_above_pivot_m  (m)
#    - mount.camera_forward_offset_m      (m)
# 2) Calibrate camera focal_px:
#    Hold a face at a known distance (e.g. 1.0 m), note bbox width in pixels,
#    set camera.focal_px = bbox_width_px * 1.0 / 0.16 in config.json.
# 3) Wire up the Hailo callback in src/face_source.py (see comments there).
# 4) Run:
python src/tracker.py
```

## Develop on Mac, deploy to Pi

The vision and GPIO code only runs on the Pi. On the Mac you can run the unit tests:

```bash
pip install pytest numpy
pytest tests/
```

## Run On Boot + Local API

This repo includes:
- `turret-tracker.service` (starts the face tracker on boot)
- `turret-api.service` (starts the local HTTP API and web control page on boot)

For Bluetooth speaker control and sound playback, install the Pi packages:

```bash
sudo apt update
sudo apt install -y bluez mpg123
sudo systemctl enable --now bluetooth
```

Install/enable both:

```bash
sudo bash scripts/install_boot_services.sh
```

The web control page is:
- `http://<pi-hostname>.local:8787/`

The API listens on:
- `POST http://<pi-hostname>.local:8787/shoot`

If your Pi hostname is `turret`, the URL is:
- `http://turret.local:8787/`
- `http://turret.local:8787/shoot`

Example:

```bash
curl -X POST http://turret.local:8787/shoot
```

The web page can scan for known/nearby Bluetooth devices, connect to a speaker, and then play `sound/TF2 Natascha Minigun Sound.mp3` whenever `/shoot` is sent. Put the speaker in pairing mode before scanning the first time. If you want a different sound file:

```bash
sudo systemctl edit turret-api.service
```

Add:

```ini
[Service]
Environment=TURRET_SOUND_PATH=/home/pi/turret/sound/your-sound.mp3
```

Then restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart turret-api.service
```

If Bluetooth connects but the service cannot make sound, keep the audio user session available at boot:

```bash
sudo loginctl enable-linger "$USER"
sudo reboot
```

Customize shoot behavior in:
- `src/action_hooks.py` (`shoot()` function)
