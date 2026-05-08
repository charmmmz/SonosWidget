# Charm for Sonos

> A personal iOS control surface for Sonos: Dynamic Island, Live Activities, Home Screen widgets, Apple Music HANDOFF, and optional NAS-backed updates.

[![iOS 18+](https://img.shields.io/badge/iOS-18%2B-111111?style=flat-square&logo=apple)](#requirements)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-0A84FF?style=flat-square&logo=swift&logoColor=white)](#tech-stack)
[![Sonos LAN + Cloud](https://img.shields.io/badge/Sonos-LAN%20%2B%20Cloud-000000?style=flat-square)](#architecture)
[![NAS Relay](https://img.shields.io/badge/NAS%20Relay-Optional-3A7D44?style=flat-square)](#optional-live-activity-relay-nas--home-server)

Charm for Sonos fills a very specific gap: the official Sonos app is great for setup, but it does not expose Sonos playback as deeply into iOS system surfaces. The iOS app is named Charm Player, and it brings Sonos controls closer to where music already lives on an iPhone.

## At A Glance

| Area | What Charm for Sonos adds |
| --- | --- |
| iOS surfaces | Dynamic Island, Live Activity, Lock Screen controls, and Home Screen widgets |
| Playback | Play/pause, skip, shuffle, repeat, volume, seek, queue edits, and speaker grouping |
| Apple Music | HANDOFF from iPhone to Sonos, Sonos to iPhone, and queue-aware reverse handoff |
| Network paths | Local LAN control first, Sonos Cloud fallback when available |
| Background updates | Optional NAS relay sends APNs updates so Live Activities stay fresh |

## Screenshots

Screenshots will live here once added. Good slots to capture:

- Home speaker cards with the mini-player
- Apple Music HANDOFF control
- Browse/search results
- Dynamic Island and Lock Screen Live Activity
- Settings with Sonos Cloud, Music Services, and NAS relay/agent options

## Highlights

### Apple Music HANDOFF

- Single Home-screen `HANDOFF` control above `UNGROUP`.
- If the selected Sonos target is playing, HANDOFF moves Apple Music playback from Sonos back to the iPhone.
- If Sonos is idle, paused, stopped, or unknown, HANDOFF moves the currently playing iPhone Apple Music track to the selected Sonos speaker or group.
- Reverse handoff can rebuild the remaining Sonos queue in Apple Music when the queue items resolve to Apple Music store IDs.
- Unsupported queue items, radio streams, and non-Apple-Music sources fail safely or are skipped with a clear toast.

### Sonos Control Surfaces

- Dynamic Island and Live Activity now playing views.
- Home Screen widget with album art, track info, audio-quality hints, and AppIntent quick actions.
- In-app Home dashboard for multiple speakers and groups.
- Mini-player that follows the current selected Sonos target.

### Speaker And Queue Management

- SSDP discovery and manual IP entry for local speakers.
- Local-network grouping and ungrouping.
- Drag speaker cards to group speakers; drop near the top or bottom edge to reorder cards.
- Persisted Home speaker order via shared app-group storage.
- Queue view, reorder, and edit over the local Sonos path.

### Remote And Background Support

- Sonos Cloud sign-in for remote control and cloud-powered music search/browse.
- LAN-first command routing with Cloud fallback where Sonos exposes an equivalent operation.
- Optional NAS relay for Live Activity push updates when the iOS app is suspended.
- Optional FastAPI NAS agent for LLM-assisted relay control.

## Architecture

| Area | Role |
| --- | --- |
| `SonosWidget/` | Main SwiftUI app, Home UI, browse/search UI, `SonosManager`, handoff orchestration, speaker grouping, Live Activity lifecycle |
| `Shared/` | App Group storage, LAN Sonos UPnP/SOAP, Sonos Cloud API, OAuth, `SonosControl`, Apple Music handoff helpers, relay client |
| `TheWidget/` | WidgetKit timelines, Live Activity layouts, playback AppIntents |
| `nas-relay/` | Optional Node.js relay: LAN Sonos UPnP events to APNs Live Activity pushes |
| `nas-agent/` | Optional Python/FastAPI agent: authenticated HTTP tools that call relay `/internal/sonos/*` endpoints |
| `docs/implementation-notes/` | Human-readable notes distilled from implementation plans and design decisions |
| `docs/superpowers/` | Agent working specs/plans; useful as history, but not the primary docs surface |

Control commands go through `SonosControl`, which routes to either:

- `LAN` - SOAP to speakers on port `1400` through `SonosAPI`
- `Cloud` - Sonos Control API and content APIs through `SonosCloudAPI` after OAuth sign-in

The app probes reachability and can fall back from LAN to Cloud when you leave the home network. Operations with no Cloud equivalent, such as queue edits and LAN-only grouping shortcuts, surface a clear same-network requirement instead of pretending the operation succeeded.

## Tech Stack

- Swift / SwiftUI / Observation
- ActivityKit for Live Activities and Dynamic Island
- WidgetKit for Home Screen widgets
- AppIntents for widget and Live Activity controls
- MediaPlayer for Apple Music HANDOFF through the system Music player
- App Group storage through `SharedStorage`
- `BGAppRefresh` for periodic widget timeline nudges
- SSDP discovery, Sonos LAN UPnP/SOAP, Sonos Cloud OAuth and APIs
- Optional Express + TypeScript relay with `@svrooij/sonos` and `@parse/node-apn`
- Optional FastAPI agent, deployable with the relay through `compose.yml`

## Requirements

- iOS 18+
- A Sonos system on your account
- Same-network access for LAN-only features such as queue mutation and grouping
- Sonos Cloud developer credentials for sign-in, cloud search/browse, and remote paths
- Apple Music permission for HANDOFF features
- Apple Developer capabilities for ActivityKit and APNs if you use the optional relay

## Setup

1. Clone the repo.
2. Open `SonosWidget.xcodeproj` in Xcode.
3. Build and run on a physical device. Widgets and Live Activities are not fully represented on Simulator.
4. Grant Local Network access when prompted so discovery and SOAP calls can reach your speakers.
5. Configure Sonos Cloud sign-in:
   - Register an integration at the [Sonos integration portal](https://integration.sonos.com).
   - Copy `Config/SonosSecrets.example.xcconfig` to `Config/SonosSecrets.xcconfig`.
   - Set `SONOS_OAUTH_CLIENT_ID`, `SONOS_OAUTH_CLIENT_SECRET`, and `SONOS_OAUTH_REDIRECT_URI`.
   - Keep `SonosSecrets.xcconfig` private; it is gitignored for a reason.

> [!NOTE]
> Apple Music HANDOFF requires iOS Media Library permission, a Sonos Cloud session, and Apple Music linked as a music service in the target Sonos household.

## Optional: Live Activity Relay (NAS / Home Server)

When the iOS app is not running, Live Activities only update if the system delivers push updates. The `nas-relay/` service subscribes to Sonos UPnP events on your LAN and forwards Live Activity pushes through APNs.

- Full design, environment variables, Docker/Portainer flow, and API docs: [nas-relay/README.md](nas-relay/README.md)
- The iOS app stores a relay base URL in App Group settings.
- `RelayManager` probes health and registers push tokens when a Live Activity uses the relay path.

## Optional: Relay + LLM Agent Stack

Run both `nas-relay` and `nas-agent` with host networking:

1. Copy [`.env.stack.example`](.env.stack.example) to `.env` at the repo root. Do not commit `.env`.
2. Set `INTERNAL_API_TOKEN`, `SONOS_SEED_IP`, `OPENAI_API_KEY`, `AGENT_USER_TOKEN`, and APNs variables as needed.
3. Run `docker compose up -d --build`.

The agent listens on `AGENT_PORT`, defaulting to `8790`. In the app, open Settings -> NAS Agent, enter that URL, and use the same `AGENT_USER_TOKEN`.

## Project Docs

Implementation notes are the canonical place for feature-level design decisions after a plan has turned into code:

- [Apple Music HANDOFF](docs/implementation-notes/apple-music-handoff.md)
- [Home speaker ordering](docs/implementation-notes/home-speaker-ordering.md)

Working plans under `docs/superpowers/plans/` are agent execution notes. Before new plans are committed, distill them into human-readable notes under `docs/implementation-notes/` so the repo keeps the useful decisions without the temporary scaffolding.

## License

This is a personal project. Feel free to reference or learn from the code.
