# NAS Relay Hue Ambience Design

## Goal

Move Music Ambience from an app-only Hue controller into a hybrid setup where
the iOS app still owns Hue onboarding and assignments, while `nas-relay` can run
the selected lighting effect continuously from Docker on the home LAN.

## Selected Approach

The selected approach is **iOS-owned setup with relay runtime**.

- iOS remains the user-facing place to pair the Hue Bridge, refresh Hue
  resources, choose Entertainment Areas, and override individual task or
  decorative lights.
- `nas-relay` receives a sanitized runtime config from iOS over the existing
  LAN relay URL, stores it under `DATA_DIR`, and uses it when Sonos playback
  changes.
- Docker keeps a JSON fallback so advanced users can seed or recover the Hue
  config without the app.

This avoids duplicating Hue setup UI in Docker while still making the lighting
effect available when the iOS app is suspended.

## API Contract

Add relay endpoints under `/api/hue-ambience`:

- `GET /api/hue-ambience/status` returns whether the relay has Hue config,
  whether the Bridge is reachable, resource counts, the last sync error, and
  the last active Sonos group.
- `PUT /api/hue-ambience/config` accepts one complete config document from iOS.
  The payload includes Bridge metadata, the Hue application key, Hue resource
  snapshots, Sonos-to-Hue mappings, group strategy, motion style, stop behavior,
  and feature enabled state.
- `DELETE /api/hue-ambience/config` removes the stored Hue config and stops any
  active relay-driven ambience.

The endpoints use the same no-proxy LAN behavior on iOS as existing relay
calls. The Hue application key is only sent to the relay URL selected by the
user and is never exposed in health responses.

## Relay Runtime

`nas-relay` loads Hue config at startup from:

1. `${DATA_DIR}/hue-ambience-config.json`
2. `HUE_AMBIENCE_CONFIG_PATH`, if provided

The relay listens to existing `SonosBridge` snapshots. When a mapped group is
playing, it resolves the target Entertainment Area, filters lights using the
same rules as the app, builds an album palette, and sends Hue CLIP v2 REST
updates. The first relay implementation keeps the same tasteful REST-based
`flowing` and `still` behavior as the app. True Entertainment DTLS streaming
remains a later enhancement because the current repo has no Hue EDK/DTLS
runtime.

## Color Source

The relay should try album-art palette extraction first when Sonos exposes
artwork. If artwork is unavailable, it falls back to a stable palette derived
from track title, artist, and album. The fallback is deterministic so lights do
not flicker on every poll, and it keeps Docker useful before a fuller artwork
pipeline lands.

## Light Filtering

The relay must match the app's current safety behavior:

- Functional/task lights are excluded by default.
- Lights with unresolved function metadata are excluded until resources are
  refreshed.
- `includedLightIDs` can manually include a task or unresolved light.
- `excludedLightIDs` always win over included/default participation.
- Gradient-capable lights receive multi-point gradient updates; basic color
  lights receive one color.

## iOS Integration

Music Ambience settings gains a relay sync action/status. After the user has a
relay URL and a paired Hue Bridge, the app can upload the current runtime config
to `nas-relay`. The upload uses the existing `RelayClient` pattern and does not
change app-only mode; app-only rendering remains the fallback for users without
NAS.

## Docker Configuration

Document these optional settings:

- `DATA_DIR=/app/data`
- `HUE_AMBIENCE_CONFIG_PATH=/app/data/hue-ambience-config.json`
- `HUE_AMBIENCE_ENABLED=true`

The existing host networking remains required because both Sonos and Hue are
local-network devices.

## Out Of Scope

- Rebuilding Hue pairing inside the relay.
- A web setup UI for Docker.
- Real beat detection or audio-frequency analysis.
- True Hue Entertainment DTLS streaming.
- Multi-Bridge orchestration.

## Verification

Tests should cover TypeScript config validation/persistence, light filtering,
gradient/basic Hue request bodies, flowing motion rotation, and Swift payload
encoding from the current app store state. Build verification must include
`npm run build` in `nas-relay` and a focused iOS build/test pass for the new
RelayClient integration.
