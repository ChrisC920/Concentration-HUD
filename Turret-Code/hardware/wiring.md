# Wiring

## Pinout

| Signal | Pi 5 GPIO (BCM) | Pin # |
|---|---|---|
| Pan servo PWM (horizontal) | GPIO 12 | 32 |
| Tilt servo PWM (vertical) | GPIO 13 | 33 |
| Servo GND (common) | GND | any GND pin |

GPIO 12 and 13 are hardware-PWM-capable on the Pi 5. If those pins conflict with the AI HAT's pin usage on your stack, fall back to GPIO 18 / 19 and update both `config.json` and the `dtoverlay` line below.

## Enable the PWM overlay (one-time, on the Pi)

The code uses `rpi-hardware-pwm` which talks to a sysfs PWM chip (chip 0 on kernel ≥ 6.12, chip 2 on older Pi 5 kernels). That sysfs interface is only exposed once you enable the PWM device-tree overlay. Edit `/boot/firmware/config.txt` and add the line **under the `[all]` section** (NOT `[cm5]`, which only applies to Compute Module 5):

```
dtoverlay=pwm-2chan,pin=12,func=4,pin2=13,func2=4
```

Then `sudo reboot`. Verify after reboot:

```bash
sudo cat /sys/kernel/debug/pwm
# Find the chip whose pwm-0 and pwm-1 are claimed by "(sysfs ...)" —
# that's the chip number to use. Kernel ≥ 6.12 → chip 0; older Pi 5
# kernels → chip 2. Set PWM_CHIP in src/servo.py accordingly.
ls /sys/class/pwm/pwmchip0/   # or pwmchip2 on older kernels
# should list export, npwm, etc.
```

If you're using GPIO 18/19 instead, the line is `dtoverlay=pwm-2chan,pin=18,func=2,pin2=19,func2=2`.

## Power — read this before plugging in

**Do not power the MG996R servos from the Raspberry Pi.** Each one draws ~600 mA at stall and the inrush will brown out the Pi.

```
                 ┌──────────────┐
   5–6V PSU  ────┤ V+   Servo 1 ├── PWM ←─── Pi GPIO 12
   (≥3A)        │              │
                 └──────┬───────┘
                        │ GND
                        ├───────────── Pi GND  (common ground required)
                 ┌──────┴───────┐
                 │ V+   Servo 2 ├── PWM ←─── Pi GPIO 13
                 │              │
                 └──────────────┘
```

- Servo V+ → external 5–6 V supply
- Servo GND → external supply GND **and** Pi GND (tied together)
- Servo PWM → Pi GPIO 12 / 13
- Add a 470–1000 µF electrolytic across the servo V+/GND rail close to the servos to absorb stall surges

## Camera

CSI ribbon to either CAM port. The camera is mounted on the pan plane and **does not tilt** with the barrel — keep that in mind when assembling, the camera should always look horizontally forward regardless of where the barrel is aimed.
