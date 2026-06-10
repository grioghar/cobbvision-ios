# Live streaming guide

The app streams ONE camera angle (chosen per preset via `streamCamera`) over
RTMP or SRT using HaishinKit, while recording any number of angles locally.
Compositing both cameras into a single stream frame is deliberately out of
scope for 1.0.

## Destinations

Configured in Settings → Stream Destinations. The stream key/passphrase is
stored in the iOS Keychain, never synced to the server.

### YouTube Live
- Kind: RTMP
- URL: `rtmp://a.rtmp.youtube.com/live2`
- Stream key: from YouTube Studio → Go Live.

### Twitch
- Kind: RTMP
- URL: `rtmp://live.twitch.tv/app` (or a closer ingest from
  https://help.twitch.tv/s/twitch-ingest-recommendation)
- Stream key: Creator Dashboard → Settings → Stream.

### Self-hosted (MediaMTX)
See [infra/mediamtx/README.md](../infra/mediamtx/README.md). Prefer SRT over
LTE — it tolerates packet loss far better than RTMP.

## Network rules baked into the app

- Streaming over **cellular** is fully supported (SRT recommended).
- If a preset streams over **WiFi**, GoPro control stays **BLE-only** — joining
  a GoPro's WiFi access point would cut the phone's internet. The app checks
  the active path with `NWPathMonitor` and refuses the conflicting combination
  rather than silently killing the stream.

## Behavior under pressure

- Adaptive bitrate: the engine reduces video bitrate when the connection
  degrades, and recovers upward slowly.
- Thermal: at `.serious` thermal state the capture engine steps quality down
  (60→30 fps, 1080→720) before iOS forcibly interrupts the session.
- The stream and the local recording are independent: losing the network
  never stops the recording.
