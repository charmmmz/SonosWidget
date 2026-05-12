# Hue EDK Sidecar Design

## Goal

Add an optional Hue EDK renderer path without placing Hue EDK source, headers,
documentation, or compiled artifacts in the public SonosWidget repository. The
existing TypeScript Hue Entertainment streaming renderer remains the default
renderer and fallback path.

## Decision

Create a private sibling repository at:

```text
/Users/charm/Documents/workspace/HueEdkSidecar
```

That repository will contain the sidecar service, private EDK integration, and
private Docker image build. The SonosWidget repository will contain only the
public sidecar contract and a `nas-relay` client that can call a configured
sidecar URL.

This keeps the licensing and deployment boundary clear:

- `SonosWidget` can remain buildable without Hue EDK access.
- EDK materials never enter the public repo or public image.
- The sidecar can be packaged as a private image for local testing.
- If EDK binary redistribution is approved later, the same sidecar can become
  the commercial companion service.

## Architecture

```text
CS2 Game State Integration
        |
        v
nas-relay TypeScript service
  - receives GSI payloads
  - stores Hue bridge config
  - chooses CS2 lighting state/effects
  - selects renderer
        |
        | HUE_RENDERER=edk-sidecar
        v
HueEdkSidecar private service
  - owns Hue EDK runtime
  - connects to Hue Bridge
  - selects Entertainment Area
  - maps commands to EDK effects
  - streams frames to Hue Bridge
        |
        v
Hue Bridge Entertainment Area
```

`nas-relay` remains the source of truth for game state, config, and app-facing
status. The sidecar is intentionally dumb about CS2: it receives normalized
lighting commands such as "set CT ambience" or "play flash" rather than raw
Valve GSI payloads.

## Sidecar MVP API

The first sidecar version exposes a small local HTTP API.

```text
GET  /health
POST /configure
POST /session/start
POST /session/stop
POST /ambient/team
POST /effect/flash
POST /effect/kill
```

`/configure` accepts the existing Hue runtime values that the iOS app already
uploads to `nas-relay`:

- bridge IP address
- bridge display name
- application key, used as the Hue username
- streaming client key
- selected Entertainment Area ID
- optional renderer settings such as target FPS and session override policy

`/health` reports at least:

- sidecar version
- configured / unconfigured
- connected / disconnected
- streaming / stopped
- selected area ID
- current renderer mode
- last error, if any

The MVP deliberately excludes C4, burning, damage, and music ambience. Those
effects should be added only after CT/T ambience, flash, and kill burst prove
that the sidecar can connect, select the correct area, and render visibly better
than the built-in renderer.

## Relay Integration

`nas-relay` gains an optional sidecar renderer implementation that conforms to
the existing Hue ambience renderer boundary. Configuration is environment based:

```text
HUE_RENDERER=builtin
HUE_RENDERER=edk-sidecar
HUE_EDK_SIDECAR_URL=http://hue-edk-sidecar:8787
```

Default behavior remains `builtin`.

For CS2, the relay converts current lighting decisions into sidecar commands:

- `ambient`, `roundFreeze`, `roundOver`, and observer ambience call
  `/ambient/team`.
- `flash` calls `/effect/flash`.
- `kill` calls `/effect/kill`.

If the sidecar is unreachable, returns an error, or reports unconfigured state,
the relay reports that status and uses the existing built-in Hue Entertainment
streaming renderer. CS2 must still refuse CLIP fallback because the CS2 path is
only useful when it is real-time.

## Private Sidecar Responsibilities

The sidecar service owns all EDK-specific behavior:

- Build and link Hue EDK in the private repository.
- Translate `/configure` into a Hue EDK runtime configuration.
- Use existing bridge credentials instead of forcing a second bridge pairing.
- Select the configured Entertainment Area.
- Start and stop the streaming session on demand.
- Map normalized commands to EDK effects.
- Expose concise health and error status to `nas-relay`.
- Shut down cleanly and release the streaming session on process exit.

The initial effect mapping is:

- Team ambience: low-layer full-area effect with CT/T color.
- Flash: high-layer full-area white effect with quick attack and slow release.
- Kill: short warm burst effect with a fast decay.

The sidecar must not expose EDK source files, headers, examples, docs, or
private repository paths through its public API, logs, or container filesystem
mounts.

## Deployment Model

Initial deployment is private:

```yaml
services:
  nas-relay:
    image: ghcr.io/charmmmz/charm-for-sonos/nas-relay:latest
    environment:
      HUE_RENDERER: edk-sidecar
      HUE_EDK_SIDECAR_URL: http://hue-edk-sidecar:8787

  hue-edk-sidecar:
    image: ghcr.io/charmmmz/charm-for-sonos/hue-edk-sidecar:latest
    network_mode: host
    volumes:
      - ./data/hue-edk-sidecar:/data
```

The sidecar image stays private until Hue/Signify confirms whether distributing
compiled EDK-linked binaries in a Docker image is permitted for the intended
commercial product. The public relay image does not depend on the sidecar image.

## Security

The sidecar should listen only on localhost or a Docker-internal network by
default. If LAN access is required later, it must require a shared token header.
The relay already holds Hue bridge credentials, so the sidecar API must be
treated as sensitive.

Logs should include operation status and effect names, but not application keys,
streaming client keys, or raw credentials.

## Testing

Testing is split between repositories.

In `SonosWidget`:

- Unit-test the sidecar HTTP client with a mock server.
- Unit-test renderer selection from environment variables.
- Unit-test fallback to built-in streaming when the sidecar is unavailable.
- Unit-test that CS2 still rejects CLIP fallback.

In `HueEdkSidecar`:

- Unit-test request validation and command routing using a fake EDK backend.
- Unit-test session lifecycle: configure, start, stop, reconfigure.
- Unit-test effect command translation without requiring a real Hue Bridge.
- Keep real bridge tests as manual integration tests.

## Open Questions

Before external distribution, ask Hue/Signify whether a closed-source companion
service or Docker image may include compiled EDK-linked binaries without EDK
source, headers, documentation, or examples.

Before broadening the MVP, compare real-world output between the built-in
renderer and EDK sidecar for CT ambience, flash, and kill burst on the same
Entertainment Area.
