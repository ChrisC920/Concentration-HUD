# Concentration HUD

A focus-monitoring system that streams first-person video from **Ray-Ban Meta smart glasses** to a Mac, infers whether the wearer is paying attention to their task, and triggers a real-world intervention when they get distracted.

Built for CMSC 730 (Interactive Tangible Computing) at the University of Maryland.

---

## What it does

You give the system a goal in plain English ("study for compilers exam", "finish CMSC 730 writeup", "stop scrolling Twitter"). While you wear the glasses and work at your Mac:

1. The **iPhone** receives the glasses' video feed over Bluetooth via Meta's DAT SDK.
2. It re-encodes the stream and sends it to the **Mac** over WebRTC on the LAN.
3. The Mac runs two parallel detectors:
   - **Gaze analyzer** — a YOLOv8 model on the glasses' camera frames classifies what the wearer is looking at (laptop, monitor, phone, bed, person, …).
   - **Screen relevance checker** — periodically fingerprints the Mac's own screen and asks Google Gemini whether the on-screen content matches the stated goal.
4. A **focus state machine** combines both signals into one of: `On task`, `Looking away`, `Off topic`, or `Unknown`.
5. When the wearer goes off task for too long, the Mac fires an HTTP call to a **turret** on the local network (a Raspberry Pi controlling a servo-mounted Nerf launcher). The turret retrieves a video clip of the offense and physically intervenes.

The "everything a user may want to know" version: it shoots foam darts at you when you look at your phone instead of your textbook.

---

## Repo layout

```
.
├── iOS/DATStreamiOS/             # iPhone app: DAT SDK → WebRTC sender
├── macOS/DATStreamMac/           # Mac app: WebRTC receiver + focus engine
├── Packages/DATSignaling/        # Shared SPM package: Bonjour signaling protocol
├── datstream-aasa/               # GitHub Pages site hosting the AASA file
│                                   for Universal Link callback from Meta AI
├── DATStream.xcworkspace         # Xcode workspace tying it all together
└── .claude/                      # Project-local Claude Code skills + rules
```

---

## System architecture

```
┌─────────────────┐   BT video    ┌──────────────┐   WebRTC (LAN)   ┌────────────────┐   HTTP   ┌──────────┐
│ Ray-Ban Meta    │ ────────────▶ │  iPhone      │ ───────────────▶ │  Mac           │ ───────▶ │  Turret  │
│ glasses         │               │  DATStreamiOS│                  │  DATStreamMac  │          │  (Pi)    │
└─────────────────┘               └──────────────┘                  └────────────────┘          └──────────┘
                                         │                                  │
                                         │       Bonjour signaling          │
                                         └──────────────────────────────────┘
                                                _dat-stream._tcp

                                                                              ┌────────┐
                                                                  ScreenCapture │ Gemini │
                                                                              └────────┘
                                                                              YOLOv8 (CoreML)
```

### iOS side (`iOS/DATStreamiOS`)

- **`Capture/`** — `DATSessionController` owns the DAT SDK lifecycle: registration → DeviceSession → camera permission → StreamSession → frame publisher. Supports both real glasses and `MockDeviceKit` (iPhone back camera) for testing.
- **`RTC/`** — `RTCConnection`, `RTCFactoryHost`, `SDPMunger`. Re-encodes DAT frames into a WebRTC video track.
- **`Signaling/`** — Bonjour browser + signaling channel. iPhone is the offerer.

### macOS side (`macOS/DATStreamMac`)

- **`RTC/`** — WebRTC answerer.
- **`Render/MetalVideoView.swift`** — Metal-backed view for the remote video track.
- **`Signaling/BonjourAdvertiser.swift`** — Advertises `_dat-stream._tcp` for the iPhone to discover.
- **`Focus/`** — the brain:
  - `GazeAnalyzer.swift` — YOLOv8n CoreML model classifies what's in the camera frame. Vote-based smoothing across the last N frames.
  - `ScreenHashStore.swift` — periodic screen capture + hash for "is the screen actually different" gating.
  - `ScreenRelevanceChecker.swift` + `GeminiClient.swift` — sends JPEG of the current screen + the goal to Gemini, parses "on-task / off-task" verdict.
  - `FocusCoordinator.swift` — combines gaze + screen signals through a grace-period state machine. Configurable presets: Relaxed / Moderate / Strict / Custom.
  - `FocusNotifier.swift` — surfaces state to the UI + triggers the turret.
  - `TurretClipFetcher.swift` + `TurretConfig.swift` — pulls intervention clips and fires the turret over HTTP.

### Shared

- **`Packages/DATSignaling`** — `SignalMessage` enum (offer/answer/ICE/clock-sync/bye) + length-prefixed framing codec. Used by both apps.

---

## Setup

### Prerequisites

- macOS with Xcode 16+
- An iPhone with iOS 17+
- An Apple Developer account (free tier works for personal use)
- A pair of Ray-Ban Meta glasses, paired with the Meta AI app on the iPhone, Developer Mode enabled
- (Optional) Google AI Studio API key for Gemini — without it, only gaze monitoring runs
- (Optional) A turret endpoint reachable on the LAN

### Configuring secrets

`iOS/DATStreamiOS/DATStreamiOS/Info.plist` ships with placeholder values:

```xml
<key>MetaAppID</key>
<string>YOUR_META_APP_ID</string>
<key>ClientToken</key>
<string>YOUR_CLIENT_TOKEN</string>
```

Replace them with values from the [Wearables Developer Center](https://wearables.developer.meta.com/) for your own app registration.

The Gemini API key is entered at runtime in the Mac app's UI (stored in `UserDefaults` at `gemini.apiKey`).

### AASA hosting

The Universal Link callback from Meta AI registration requires an `apple-app-site-association` file on HTTPS. The `datstream-aasa/` directory is a self-contained Jekyll site for GitHub Pages. See its [README](datstream-aasa/README.md) for deployment.

The shipped AASA references App ID `N3MGA953Q6.chris.cho.DATStreamiOS`. If you fork this project, update the Team ID + bundle ID in both:

- `datstream-aasa/.well-known/apple-app-site-association`
- `iOS/DATStreamiOS/DATStreamiOS.xcodeproj/project.pbxproj` (`DEVELOPMENT_TEAM` + `PRODUCT_BUNDLE_IDENTIFIER`)

### Build + run

```bash
open DATStream.xcworkspace
```

1. Select the `DATStreamiOS` scheme → your iPhone → Run.
2. Select the `DATStreamMac` scheme → My Mac → Run.
3. On the iPhone, tap **Register with Meta AI**. Approve the Universal Link bounce. Once `regState = .registered`, the Mac will appear via Bonjour and the WebRTC handshake fires automatically.
4. On the Mac, enter your goal, paste your Gemini API key, hit **Start**.

For development without hardware, the iPhone app has a **Mock device** source toggle that routes the iPhone's back camera through `MWDATMockDevice` — the rest of the pipeline is identical.

---

## DAT SDK conventions

Project-local Claude Code skills under `.claude/skills/` document the DAT SDK 0.6.x patterns we rely on:

- `getting-started` — `Wearables.configure()`, Info.plist keys
- `permissions-registration` — registration state stream, URL callback handling
- `camera-streaming` — `StreamSession`, `VideoFrame`, photo capture
- `session-lifecycle` — RUNNING/PAUSED/STOPPED, hinge open/close
- `mockdevice-testing` — `MockDeviceKit` for hardware-free testing
- `debugging` — known issues, Developer Mode, firmware compatibility
- `sample-app-guide` — full scaffolding reference

See `.claude/rules/dat-conventions.md` for the iOS coding conventions enforced project-wide.

---

## Known limitations

- WebRTC SPM dependency is pinned to `stasel/WebRTC 138.0.0`. M141+ has a broken macOS slice (umbrella imports iOS-only headers).
- DAT SDK 0.6.x doesn't auto-resume after `.paused` (hinge close, glasses doff) or transient `.waitingForDevice` flaps. `DATSessionController` schedules a backoff-retry tear-down + re-arm.
- Gemini calls are billed per screen check. The configurable `screenCheckIntervalSec` directly controls API spend.
- The turret integration assumes a private HTTP API on the LAN. There is no auth on that hop. Don't expose it.

---

## License

No license file yet — all rights reserved by default. Open an issue if you want to use any of this.

---

## Authors

Chris Cho · CMSC 730, University of Maryland
