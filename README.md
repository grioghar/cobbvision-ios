# CobbVision iOS

Companion app for the [CobbVision controlplane](https://cobbvision.grio.co) —
a driving telemetry and video rig for your pocket:

- **GPS tracking** — high-rate location logging during sessions, uploaded as
  GPX and auto-correlated with your AccessPort datalogs server-side.
- **G-force monitor** — live lateral/longitudinal/vertical gauge with peak
  tracking, calibrated to the vehicle frame regardless of phone mounting.
- **Multi-camera record & stream** — front, rear, or both iPhone cameras
  simultaneously (`AVCaptureMultiCamSession`); record locally with chunked
  upload to the controlplane, and/or live-stream one angle via RTMP/SRT to
  YouTube/Twitch or your own MediaMTX server ([infra/mediamtx](infra/mediamtx)).
- **Presets** — one tap arms cameras, quality, stream destination, telemetry,
  and external cameras. Synced from the controlplane.
- **CarPlay** — start/stop, preset picker, and status via CarPlay templates
  (driving-task entitlement).
- **Apple Watch** — remote start/stop, live g-force and speed, haptic alerts.
- **External cameras** — group start/stop/mode for GoPro (Open GoPro over
  BLE/WiFi); Insta360 stubbed pending SDK access.

## How this repo builds (no Mac required)

Code is authored as plain Swift + [XcodeGen](https://github.com/yonaskolb/XcodeGen)
YAML; the `.xcodeproj` is generated on CI. GitHub Actions (macOS runners)
build, test, sign, and upload to TestFlight:

- [ci.yml](.github/workflows/ci.yml) — every push: generate project, run
  package tests on the macOS host, build iOS + watchOS apps for simulator.
- [release.yml](.github/workflows/release.yml) — `v*` tags / manual: fastlane
  match signing via App Store Connect API key → TestFlight.

One-time Apple paperwork: [docs/apple-setup-checklist.md](docs/apple-setup-checklist.md).

## Layout

| Path | What |
|---|---|
| `App/` | iOS app target — SwiftUI shell, CarPlay scene |
| `WatchApp/` | watchOS app target |
| `Packages/CobbVisionKit/` | All logic, as testable SPM libraries (CVCore, CVAPI, CVTelemetry, CVCapture, CVStreaming, CVExternalCam, CVSession, CVWatchBridge) |
| `infra/mediamtx/` | Self-hosted streaming server deployment |
| `docs/` | Setup checklists, backend API additions, streaming guide |

`CVCore` is platform-pure: `swift build`/`swift test` works with any Swift
toolchain (including Windows) for fast local iteration; Apple-framework
modules compile via CI.

## Backend

Talks to the CobbVision controlplane REST API (Bearer key from
`POST /api/v1/auth/login`). Preset sync requires the `app_presets` endpoints —
see [docs/backend-additions.md](docs/backend-additions.md).
