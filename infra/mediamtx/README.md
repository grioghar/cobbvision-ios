# Self-hosted streaming server (MediaMTX)

Receives live RTMP/SRT streams from the CobbVision iOS app and serves them to
browsers over HLS or WebRTC. Recordings are kept on disk for 7 days.

> DreamHost shared hosting (where the controlplane lives) **cannot** run this —
> it needs a host where you control Docker and open ports. Any $5/mo VPS
> (Hetzner, DigitalOcean, Linode) or a home server with port forwarding works.

## Deploy

```bash
# On the VPS
git clone <this repo> && cd cobbvision-ios/infra/mediamtx
# Set a real publish password (or edit mediamtx.yml)
MTX_PUBLISH_PASS='pick-a-strong-password' docker compose up -d
```

Open the firewall:

```bash
ufw allow 1935/tcp   # RTMP ingest
ufw allow 8890/udp   # SRT ingest
ufw allow 8888/tcp   # HLS playback
ufw allow 8889/tcp   # WebRTC playback
ufw allow 8189/udp   # WebRTC ICE
```

## App configuration

In the app, add a stream destination:

| Field | Value |
|---|---|
| Kind | SRT (preferred over LTE) or RTMP |
| URL (SRT) | `srt://YOUR_HOST:8890` |
| URL (RTMP) | `rtmp://YOUR_HOST:1935/cobbvision` |
| Stream key (SRT) | `publish:cobbvision:cobb:YOUR_PASSWORD` (goes in the streamid) |
| Stream key (RTMP) | appended as `?user=cobb&pass=YOUR_PASSWORD` |

SRT tolerates packet loss far better than RTMP on cellular — use it when
streaming over LTE, with latency ≥ 200 ms.

## Watch the stream

- HLS (any browser, ~3–6 s behind live): `http://YOUR_HOST:8888/cobbvision/`
- WebRTC (sub-second): `http://YOUR_HOST:8889/cobbvision/`

## TLS (optional but recommended)

Put Caddy in front for HTTPS playback:

```
stream.example.com {
    reverse_proxy /cobbvision/* localhost:8888
}
```

Recordings land in `./recordings/cobbvision/` as fragmented MP4, auto-deleted
after 168 h (`recordDeleteAfter` in mediamtx.yml). Upload keepers to the
controlplane from the app, or pull them off the VPS directly.
