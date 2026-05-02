# SonosWidget

An iOS app that brings **Dynamic Island**, **Live Activity**, and **Home Screen Widget** support to Sonos speakers.

Built as a personal project to fill the gap — the official Sonos app doesn't support these iOS features.

## Features

- **Dynamic Island** — glanceable now playing, with playback controls
- **Live Activity** — track info and controls on the Lock Screen; optional **NAS relay + APNs** keeps updates fresh when the app is fully suspended (see below)
- **Home Screen Widget** — album art, track info, audio-quality hints, and quick actions (AppIntents)
- **Playback control** — play/pause, skip, shuffle, repeat, volume, seek (LAN and cloud where supported)
- **Speaker management** — SSDP discovery; grouping on the local network
- **Queue management** — view, reorder, and edit the queue (**local network path** — Sonos Cloud has no equivalent for per-track queue edits)
- **Music search & browse** — linked services via local SMAPI and/or Sonos Cloud / `play.sonos.com` APIs when signed in
- **Adaptive UI** — accent color derived from album art

## Architecture

| Area | Role |
|------|------|
| `SonosWidget/` | Main SwiftUI app, discovery, playback UI, `SonosManager` (state + transport routing + Live Activity lifecycle) |
| `Shared/` | App Group storage (`SharedStorage`), `SonosAPI` (LAN UPnP/SOAP), `SonosCloudAPI`, OAuth (`SonosAuth`), `SonosControl` façade, optional **Relay** client |
| `TheWidget/` | WidgetKit timelines, Live Activity layouts, playback AppIntents |
| `nas-relay/` | Optional Node.js relay: LAN Sonos UPnP events → APNs push for Live Activity updates |

Control commands go through **`SonosControl`**, which routes to either:

- **LAN** — SOAP to speakers on port **1400** (`SonosAPI`)
- **Cloud** — Sonos Control API + content APIs (`SonosCloudAPI`) using an OAuth bearer token after you sign in

The app probes reachability and can fall back **LAN → Cloud** when you leave the home network. Operations with no cloud equivalent (queue edits, LAN-only grouping shortcuts, etc.) surface a clear “needs same network” error when you're in cloud-only mode.

## Tech

- Swift / SwiftUI
- ActivityKit (Live Activities & Dynamic Island)
- WidgetKit (Home Screen widgets)
- AppIntents (widget / Live Activity controls)
- **App Group + `SharedStorage`** — shared prefs and on-disk artwork for the widget extension  
- **`BGAppRefresh`** — periodic refresh hook to bump widget timelines when playback changes
- SSDP discovery, Sonos LAN UPnP/SOAP, Sonos Cloud OAuth + APIs
- Optional **Express + TypeScript relay** (`nas-relay/`) with `@svrooij/sonos` and APNs (`@parse/node-apn`)

## Requirements

- **iOS 18+**
- **Sonos** on your account; for LAN features, speakers on the **same network** as the phone
- **Apple Developer** capabilities for ActivityKit / push if you use the optional Live Activity relay with APNs

## Setup

1. Clone the repo
2. Open `SonosWidget.xcodeproj` in Xcode
3. Build and run on a **physical device** (widgets and Live Activities are not fully represented on Simulator)
4. Grant local-network access when prompted so discovery and SOAP calls can reach your speakers
5. **Sonos Cloud sign-in** — register an integration at [Sonos integration portal](https://integration.sonos.com). Copy `Config/SonosSecrets.example.xcconfig` to `Config/SonosSecrets.xcconfig` and set **`SONOS_OAUTH_CLIENT_ID`**, **`SONOS_OAUTH_CLIENT_SECRET`**, and **`SONOS_OAUTH_REDIRECT_URI`** to match your app and hosted callback. `SonosSecrets.xcconfig` is gitignored — do not commit real credentials.

## Optional: Live Activity relay (NAS / home server)

When the iOS app is not running, Live Activities only update if the system delivers **push** updates. The `nas-relay/` service subscribes to Sonos UPnP events on your LAN and forwards **Live Activity** pushes via **APNs**.

- Full design, env vars, Docker/Portainer flow, and API (`/api/health`, `/api/register-activity`) → **[nas-relay/README.md](nas-relay/README.md)**
- The iOS app stores a relay **base URL** in App Group settings; `RelayManager` probes health and registers push tokens when a Live Activity uses the relay path.

## License

This is a personal project. Feel free to reference or learn from the code.
