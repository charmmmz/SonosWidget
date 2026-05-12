# Sonos Live Activity Relay

A small Node.js + TypeScript service that subscribes to Sonos UPnP events on
your LAN, pushes the corresponding Live Activity updates to the Charm for
Sonos iOS app via Apple's APNs HTTP/2 endpoint, and can run Hue Ambience
while the iPhone app is suspended.

The point: keep the iPhone Lock Screen Live Activity fresh **without** the
iOS app needing to run in the background. UPnP eventing means we don't poll
Sonos — the speakers themselves push state changes (track / play / pause /
group changes) to the relay within ~100 ms, the relay forwards them through
APNs, and the Live Activity updates within another ~1–3 s.

## Phase 1 scope

- LAN-only HTTP (no auth, no TLS — fine for inside a tailnet / home LAN).
- Pushes the basic ContentState fields used by the Lock Screen widget:
  track / artist / album / isPlaying / startedAt / endsAt / groupMemberCount.
- Album art is **not** delivered via push yet (`albumArtThumbnail = nil`)
  — the widget falls back to its on-device cache, same path it uses today
  for the local-update flow. Phase 2 will fetch and downsample art on the
  relay and embed it.
- Hue Ambience config is uploaded from the iOS app. The relay stores the
  Hue app key and assignments in `DATA_DIR/hue-ambience-config.json`, then
  applies album-palette transitions on Sonos play/track changes.
  The iOS Light Motion Speed setting controls the flow interval; set
  `HUE_FLOW_INTERVAL_SECONDS` only when the NAS should override that value.
  Mapped Entertainment Areas use Hue Entertainment DTLS streaming when the
  Bridge provides a streaming client key, with CLIP v2 as a fallback.
- Counter-Strike 2 Game State Integration payloads can be posted directly to
  the relay. When Hue Ambience config has CS2 sync enabled and at least one
  mapped Entertainment Area, the relay renders low-latency game lighting from
  the latest local-player state. Competitive and deathmatch use separate
  strategies; competitive spectator/death state falls back to low-brightness
  ambience.

External access (DDNS IPv6 / Cloudflare Tunnel / Tailscale) is intentionally
out of scope here; bring up the LAN path first, then layer on whichever
external transport once Phase 1 is verified.

## Quick start (QNAP + Portainer)

1. **Pick an always-on Sonos speaker IP** from the official Sonos app
   (Settings → System → About) — say `192.168.50.251`.
2. **Copy `.env.example` → `.env`** and set `SONOS_SEED_IP`. Leave the APNs
   keys blank for now; the relay starts in *dry-run* mode.
3. **Deploy via Portainer** — Stacks → Add stack, paste the contents of
   `docker-compose.yml`, attach `.env` under "Environment variables", deploy.
   The stack pulls `ghcr.io/charmmmz/charm-for-sonos/nas-relay:latest`.
   If the GHCR package is private, log in first with a GitHub personal access
   token that can read packages.
4. **Verify**:
   ```bash
   curl http://<qnap-ip>:8787/api/health
   ```
   Should return JSON with at least one entry under `groups[]`. The first
   sample takes a few seconds while the relay enumerates speakers.
5. **Watch logs** (Portainer → Containers → relay → Logs). Play / pause
   / change track on Sonos and you should see lines like:
   ```
   [DRY-RUN] would push Live Activity update { trackTitle: …, isPlaying: true, … }
   ```
   This means everything is wired up correctly except APNs itself.

## Going live (after Apple Developer account is in)

1. Apple Developer Portal → Certificates → Keys → Create a new "Apple Push
   Notifications service (APNs)" key. Download the `.p8` file (one-time —
   you cannot re-download).
2. Note the **Key ID** (10-char string shown next to the key) and the
   **Team ID** (top right of any developer portal page).
3. Drop the `.p8` into the mounted volume:
   ```bash
   ssh admin@<qnap>
   cp ~/AuthKey_ABCDEF1234.p8 /share/Container/sonos-live-activity-relay/data/apns.p8
   chmod 600 /share/Container/.../data/apns.p8
   ```
4. Update `.env`:
   ```
   APNS_KEY_ID=ABCDEF1234
   APNS_TEAM_ID=XXXXXXXXXX
   APNS_PRODUCTION=false   # leave false until you ship via TestFlight
   ```
5. Restart the stack. Relay log will print `APNs provider ready` instead of
   `running in DRY-RUN mode`.

The bundle ID defaults to `com.charm.SonosWidget` (matches your iOS
project); change `APNS_BUNDLE_ID` if you renamed it. The APNs topic is
automatically suffixed with `.push-type.liveactivity`, which is what Apple
requires for Live Activity pushes.

## API

| Method | Path                                  | Body / Params                                                   | Description                                              |
|--------|---------------------------------------|-----------------------------------------------------------------|----------------------------------------------------------|
| GET    | `/api/health`                         | —                                                               | Liveness + current group snapshots                       |
| POST   | `/api/register-activity`              | `{ groupId, token, attributes? }`                               | Called by iOS on every push-token rotation               |
| DELETE | `/api/register-activity/:token`       | path: `:token`                                                  | Called by iOS when the Live Activity ends                |
| GET    | `/api/hue-ambience/status`            | —                                                               | Hue runtime status without exposing the Hue app key      |
| PUT    | `/api/hue-ambience/config`            | complete config uploaded by iOS                                 | Stores Bridge key, resources, assignments, and settings  |
| DELETE | `/api/hue-ambience/config`            | —                                                               | Removes stored Hue config and stops active ambience      |
| POST   | `/api/cs2/gamestate`                  | Valve CS2 Game State Integration JSON                           | Receives and caches the latest CS2 state per SteamID     |
| GET    | `/api/cs2/status`                     | —                                                               | Summarized latest CS2 state for each connected SteamID   |
| GET    | `/api/cs2/debug/recent`               | —                                                               | Recent raw CS2 payload samples for field inspection      |
| DELETE | `/api/cs2/debug/recent`               | —                                                               | Clears recent CS2 debug samples                          |
| GET    | `/api/cs2/debug/stream`               | —                                                               | SSE stream of raw CS2 payload samples as they arrive     |

### Counter-Strike 2 Game State Integration

Create this file on the gaming PC:

```
C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive\game\csgo\cfg\gamestate_integration_charm.cfg
```

Use the relay host or NAS IP in the `uri`:

```text
"Charm Sonos Relay"
{
 "uri" "http://<relay-ip-or-hostname>:8787/api/cs2/gamestate"
 "timeout" "5.0"
 "buffer" "0.1"
 "throttle" "0.1"
 "heartbeat" "5.0"
 "data"
 {
   "provider" "1"
   "map" "1"
   "round" "1"
   "player_id" "1"
   "player_state" "1"
   "player_match_stats" "1"
 }
}
```

After launching CS2 and joining a match, verify ingestion:

```bash
curl http://<relay-ip-or-hostname>:8787/api/cs2/status
```

You should see a `providers[]` entry with the provider SteamID, player name,
team, health, flash/burning values, bomb state, and map name.

For field research, clear existing samples and then listen to the live debug
stream while performing one action at a time in game:

```bash
curl -X DELETE http://<relay-ip-or-hostname>:8787/api/cs2/debug/recent
curl -N http://<relay-ip-or-hostname>:8787/api/cs2/debug/stream
```

Each `event: state` message contains the raw Valve GSI payload plus relay
metadata such as the provider SteamID, receive time, and request source IP.

### Internal Sonos API (for `nas-agent`)

All routes require header **`X-Internal-Token: $INTERNAL_API_TOKEN`**. If `INTERNAL_API_TOKEN` is unset, these routes return **503**.

| Method | Path | Body / Params | Description |
|--------|------|---------------|-------------|
| GET | `/internal/sonos/groups` | — | Cached snapshots for all discovered coordinators (`groupId` = coordinator LAN IP). |
| GET | `/internal/sonos/state` | `?groupId=` | Refresh AVTransport snapshot for one group. |
| POST | `/internal/sonos/play` | `{ groupId }` | Play / resume. |
| POST | `/internal/sonos/pause` | `{ groupId }` | Pause. |
| POST | `/internal/sonos/next` | `{ groupId }` | Next track. |
| POST | `/internal/sonos/previous` | `{ groupId }` | Previous track. |
| POST | `/internal/sonos/volume` | `{ groupId, volume }` | Group volume 0–100. |

`groupId` is whatever string the iOS app assigns to a Sonos coordinator —
it doesn't have to match Sonos's internal `RINCON_…` UUID, the only
requirement is that the same value is used both in `register-activity`
and inside the relay (it does today via the bridge's `groupName ?? uuid`).

## Layout

```
nas-relay/
├── docker-compose.yml      # Portainer stack
├── Dockerfile              # multi-stage Node 24 alpine build
├── .env.example
├── package.json / tsconfig.json
├── data/                   # mounted volume — tokens.json, apns.p8 live here
└── src/
    ├── index.ts            # Express + wire-up
    ├── cs2GameState.ts     # CS2 GSI state cache and event emitter
    ├── cs2Routes.ts        # /api/cs2/*
    ├── cs2Types.ts         # CS2 GSI payload models
    ├── hueAmbienceService.ts # Sonos snapshots → Hue ambience runtime
    ├── hueClient.ts        # Hue CLIP v2 client
    ├── hueConfigStore.ts   # disk-backed Hue config
    ├── huePalette.ts       # deterministic fallback palettes
    ├── hueRenderer.ts      # basic/gradient light update bodies
    ├── hueRoutes.ts        # /api/hue-ambience/*
    ├── hueTypes.ts         # Hue config/resource models
    ├── internalSonosRoutes.ts  # /internal/sonos/* for Python agent
    ├── sonos.ts            # @svrooij/sonos bridge
    ├── apns.ts             # @parse/node-apn wrapper + dry-run
    ├── tokenStore.ts       # disk-backed token registry
    └── types.ts            # mirrors iOS ContentState shape
```

## Future phases

- Phase 2 polish: external access (Tailscale / DDNS IPv6), token rotation
  edge cases, album-art forwarding via APNs, multi-group iOS UI.
- Auth: shared-secret header on register/unregister once we leave the LAN.
- Observability: Prometheus `/metrics` if it ever feels needed.
