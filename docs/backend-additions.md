# Controlplane additions for this app

Implemented in the CobbVision PHP repo on branch `feature/ios-app-presets`
([PR #57](https://github.com/grioghar/cobbvision/pull/57)). The app degrades
gracefully (local default presets) until that PR deploys — `PresetStore`
treats a 404 from these endpoints as "server not upgraded yet".

## What it adds

- **`app_presets` table** (migration v1.81): per-user named presets; `config`
  is an opaque JSON blob owned by the app, carrying its own `schemaVersion`.
- **`GET /api/v1/app/config`** — server-driven config + presets in one call:
  ```json
  {
    "config": {
      "min_app_version": "0.0.0",
      "chunk_size_bytes": 20971520,
      "telemetry_hz": 10,
      "features": {"insta360": false}
    },
    "presets": [ {"id": "…", "name": "…", "sort_order": 0, "is_default": 1, "config": {…}} ]
  }
  ```
  Env overrides on the server: `APP_MIN_VERSION`, `APP_CHUNK_SIZE_BYTES`,
  `APP_TELEMETRY_HZ`, `APP_FEATURE_INSTA360`.
- **`GET /api/v1/app/presets`** — `{"presets": [...]}` ordered by sort_order.
- **`POST /api/v1/app/presets`** — full-set sync: send the complete list;
  rows absent from the payload are deleted, the rest upserted. Returns the
  canonical list.

All three use the existing Bearer `api_key` auth (same as the media API).

## Smoke test

```bash
KEY=$(curl -s -X POST https://cobbvision.grio.co/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@example.com","password":"…"}' | jq -r .api_key)

curl -s -H "Authorization: Bearer $KEY" \
  https://cobbvision.grio.co/api/v1/app/config | jq

curl -s -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"presets":[{"name":"Track day","is_default":true,"config":{"schemaVersion":1,"cameras":"both"}}]}' \
  https://cobbvision.grio.co/api/v1/app/presets | jq
```
