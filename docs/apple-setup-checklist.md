# Apple setup checklist (do these now — some have weeks of lead time)

Everything below happens in the Apple Developer portal / App Store Connect and
takes ~30 minutes except the CarPlay request. CI cannot do these for you.

## 1. App Store Connect API key (needed before the first release build)

1. https://appstoreconnect.apple.com → Users and Access → Integrations → App Store Connect API → Team Keys.
2. Generate a key with **App Manager** role. Note the **Key ID** and **Issuer ID**, download the `.p8` (one chance only).
3. Add GitHub repo secrets (repo → Settings → Secrets and variables → Actions):
   - `ASC_KEY_ID` — the Key ID
   - `ASC_ISSUER_ID` — the Issuer ID
   - `ASC_KEY_P8_BASE64` — base64 of the `.p8` file. PowerShell:
     `[Convert]::ToBase64String([IO.File]::ReadAllBytes("AuthKey_XXXX.p8")) | Set-Clipboard`
   - `MATCH_PASSWORD` — invent a strong passphrase (encrypts certs in the certs repo)
   - `KEYCHAIN_PASSWORD` — any random string (ephemeral CI keychain)
   - `MATCH_GIT_BASIC_AUTHORIZATION` — base64 of `grioghar:<personal-access-token>`
     where the PAT has `repo` scope on the certs repo (step 2). PowerShell:
     `[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("grioghar:ghp_..."))`

## 2. Certificates repo

Create a **private** GitHub repo `grioghar/cobbvision-certs` (empty). fastlane
match stores encrypted signing certificates and provisioning profiles there.

## 3. App IDs (identifiers)

https://developer.apple.com/account/resources/identifiers — create two App IDs:

1. **`co.grio.cobbvision`** (iOS app)
   - Capabilities: enable **Hotspot Configuration** (GoPro WiFi control).
   - CarPlay appears here only after the entitlement is granted (step 5).
2. **`co.grio.cobbvision.watchkitapp`** (watch app) — no extra capabilities.

## 4. App Store Connect app record

1. ASC → My Apps → "+" → New App: platform iOS, bundle ID `co.grio.cobbvision`,
   name "CobbVision" (or pick a unique one if taken), SKU `cobbvision-ios`.
   The watch app is embedded — it does not get its own app record.
2. TestFlight → Internal Testing → create a group, add **thegrio@gmail.com**.

## 5. CarPlay driving-task entitlement (longest lead time — submit today)

1. https://developer.apple.com/contact/carplay/
2. Describe the app honestly: *"Driving telemetry and dashcam companion app.
   The CarPlay experience is template-only: start/stop a recording session,
   choose a preset, and view recording status. No video is displayed in
   CarPlay."* Request the **CarPlay driving task** entitlement.
3. Approval typically takes 2–6 weeks. Until then the app builds and ships to
   TestFlight without CarPlay (the entitlement is commented out in
   `project.yml`).
4. After the grant: enable CarPlay on the `co.grio.cobbvision` App ID,
   uncomment `com.apple.developer.carplay-driving-task` in `project.yml`,
   then run the Release workflow once with `MATCH_FORCE=true` (workflow
   dispatch) so match regenerates profiles with the new entitlement.

## 6. First release build

1. Run the **Release (TestFlight)** workflow manually (Actions → Release →
   Run workflow) with `readonly_match` set to **false** — this first run mints
   the distribution certificate and provisioning profiles into the certs repo.
2. Every later release: push a `v*` tag or run the workflow with defaults.
3. The build appears in TestFlight ~10 minutes after upload; install it on
   your iPhone via the TestFlight app.

## 7. Insta360 SDK (optional, when you want real Insta360 control)

Apply at https://www.insta360.com/developer — request the mobile SDK for iOS.
The app's camera-control abstraction has Insta360 stubbed; once you have the
SDK we wire it in behind the existing `CameraController` protocol.
