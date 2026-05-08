# Sonos Live Activity Relay

A small Node.js + TypeScript service that subscribes to Sonos UPnP events on
your LAN and pushes the corresponding Live Activity updates to the
Charm for Sonos iOS app via Apple's APNs HTTP/2 endpoint.

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
├── Dockerfile              # multi-stage Node 25 alpine build
├── .env.example
├── package.json / tsconfig.json
├── data/                   # mounted volume — tokens.json, apns.p8 live here
└── src/
    ├── index.ts            # Express + wire-up
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
