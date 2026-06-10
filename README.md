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
- **AccessPort datalog import** — pick `.csv` / `.csv.gz` datalogs from the
  Files app (USB-C flash drive, iCloud Drive, Dropbox…), gunzip on-device,
  and upload for instant analysis.

## Device support

iOS **16.0+** (iPhone 8 and later) and watchOS **9.0+**. Dual-camera capture
additionally needs an iPhone XS or newer (`AVCaptureMultiCamSession`); older
phones record one camera at a time. iOS 15 was considered and rejected: it
only adds 2015–16 hardware that can't sustain capture + encode + GPS, and
HaishinKit's floor is 15 anyway.

### Why no direct AccessPort USB connection?

The AP3 is a vendor-specific bulk USB device (VID `0x1A84`, WinUSB, custom
framing) — **not** a mass-storage drive. iPhones expose no user-space USB API
for such devices (DriverKit is iPad-only and entitlement-gated), so no iPhone
app can speak the AP protocol over a cable. The supported flow: export
datalogs with the AP Manager desktop app or cobbvision.grio.co/connect-ap
(Chromium WebUSB), then import them here from any Files location — including
a USB-C flash drive plugged straight into the phone.

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
