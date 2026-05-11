# Hue Entertainment Streaming-Ready Design

## Goal

Upgrade NAS-enhanced Music Ambience so it is ready for true Hue Entertainment
streaming without destabilizing the current CLIP v2 lighting sync.

The first implementation should add the architecture, configuration, status
model, and effect engine needed for Entertainment Area based lighting. It should
continue to output through the existing CLIP v2 path until the Hue
Entertainment DTLS/UDP transport details are implemented and verified.

## Selected Approach

The selected approach is **streaming-ready NAS renderer with CLIP fallback**.

- `nas-relay` owns continuous lighting whenever relay mode is enabled and
  reachable, so the iOS app does not fight the NAS for the same Hue resources.
- Entertainment Areas become the preferred target for NAS-enhanced ambience,
  because they already represent a curated set of lights for synchronized
  experiences and expose channel metadata that a future true streaming transport
  can use.
- A shared frame/effect engine computes spatial color frames independent of the
  output transport.
- The existing CLIP v2 renderer consumes those frames for the first version.
- A future DTLS/UDP adapter can consume the same frames without rewriting the
  product behavior or Sonos/Hue state machine.

This keeps today's working relay useful while preparing the codebase for true
Entertainment streaming as a small, isolated transport change.

## Approaches Considered

### Direct true Entertainment streaming

Implement Hue Entertainment DTLS/UDP immediately and bypass CLIP v2 for
Entertainment Areas.

This gives the best long-term technical path for fast spatial updates and
gradient-capable lights, but it carries the highest implementation risk. The
protocol details include session lifecycle, DTLS identity/key handling, packet
format, channel mapping, frame rate, and conflict behavior. Those details should
be verified against Hue's official developer material and a real Bridge before
the app depends on them.

### Effect-only CLIP v2 improvements

Keep the current renderer and only make album-color movement, gradients, and
stop behavior better.

This is the fastest path, but it does not move the architecture closer to true
Entertainment streaming. It would also keep future streaming work tangled with
the existing REST renderer.

### Streaming-ready renderer with fallback

Add the renderer boundary, streaming status, Entertainment Area preference, and
spatial frame engine now, while the initial output remains CLIP v2.

This is the recommended path because it is incremental, testable in the current
Docker setup, and avoids rewriting the lighting behavior when the DTLS transport
is added.

## Runtime Architecture

`nas-relay` should split Music Ambience into three layers:

- `HueAmbienceService`: owns Sonos snapshot handling, enabled checks, group
  strategy, stop behavior, active target ownership, and renderer selection.
- `HueAmbienceEffectEngine`: converts playback state, album palette, elapsed
  time, motion settings, and Hue target metadata into transport-independent
  frames.
- `HueAmbienceRenderer`: applies frames to Hue. The first concrete renderer is
  a CLIP v2 fallback renderer. A future Entertainment streaming renderer uses
  the same interface.

The service must ensure only one renderer controls a target set at a time. If
NAS relay is active for a Sonos group, iOS local rendering remains deferred.

## Frame Model

The frame model should describe the desired light state without assuming REST or
DTLS transport details.

Each frame includes:

- target resource ID and kind
- participating light IDs
- optional Entertainment channel IDs when available
- a timestamp or phase value
- one or more colors per light for gradient-capable devices
- brightness and transition hints
- reason, such as track change, steady playback, pause, stop, or disable

The CLIP renderer maps these frames to ordinary light or gradient requests. A
future streaming renderer maps the same frames to Entertainment packets.

## Effects

The first effect set does not use audio analysis or beat detection. It should
feel musical by using track metadata, album art, and time-based motion.

- **Spatial album palette**: assign album colors across the selected area
  instead of flattening every light to the same color.
- **Slow room flow**: rotate palette positions over time using the configured
  flow speed.
- **Track-change transition**: crossfade from the previous track palette to the
  new track palette so song changes feel intentional.
- **Playback progress evolution**: advance the motion phase from track progress
  when available, falling back to monotonic runtime when progress is missing.
- **Gradient drift**: keep gradient-capable lights on multi-color updates and
  shift gradient points over time.
- **Playback state behavior**: respect configured pause and stop behavior
  without restarting ambience after playback is no longer active.

## Target Selection

Entertainment Area targets are preferred for NAS-enhanced mode. Room, Zone, and
Light targets remain supported through the same frame engine and CLIP fallback.

Target resolution must use stable Hue resource IDs. It must not use display
names as a fallback for light selection, because duplicate names in different
rooms can pull unrelated lights into the effect.

When an Entertainment Area contains incomplete channel metadata, the system
still uses its explicit child light IDs for CLIP fallback. It should surface the
missing metadata in status so future true streaming readiness is visible.

## Config And Status

The iOS app continues to own pairing, resource refresh, assignments, and user
settings. The relay config should remain backward compatible with existing
schema version 1 payloads while adding optional fields for streaming readiness.

New or expanded status should report:

- relay Hue config present or missing
- Bridge reachable or unreachable
- selected render mode: `clipFallback` or `streamingReady`
- whether the selected target is an Entertainment Area
- whether Entertainment channel metadata is complete
- active group and active target IDs
- last frame time
- last renderer error

The settings UI should replace the static unavailable copy for Live
Entertainment with NAS runtime status. It should be honest that the first
implementation is streaming-ready and still using the fallback transport.

## iOS Behavior

The iOS app remains the control surface:

- It syncs enabled state, assignments, flow speed, group behavior, and stop
  behavior to NAS.
- It defers local Hue writes when relay mode is configured, reachable, and
  enabled.
- It shows whether NAS is applying ambience, using fallback rendering, or
  missing data needed for true Entertainment streaming.
- It keeps app-only mode available for users who do not run NAS relay.

The iOS app should not implement true Entertainment streaming in this phase.

## Safety Rules

The implementation must preserve the fixes already made for real-home behavior:

- no phone-versus-NAS renderer fighting
- no name-based fallback that can select same-named lights in other rooms
- no spontaneous restart after pause or stop
- no unrelated group control when the active Sonos group changes
- no default inclusion of task/function lights unless explicitly included
- no stale Hue resource use after the user clears local Music Ambience data

## Future DTLS Transport Boundary

The future true Entertainment renderer should be isolated behind the same
`HueAmbienceRenderer` interface. It will need to implement:

- Entertainment session start and stop
- DTLS/UDP connection setup
- authenticated Bridge identity and key handling
- channel-to-light packet encoding
- frame cadence and timeout handling
- conflict detection when another Hue app owns streaming
- fallback to CLIP rendering when streaming cannot start

Until those transport details are implemented and verified, the product should
label the feature as NAS-enhanced spatial ambience rather than claiming live
Entertainment streaming.

## Out Of Scope

- Beat detection or frequency-reactive lighting.
- iOS background true streaming.
- Rebuilding Hue pairing inside Docker.
- Multi-Bridge orchestration.
- Depending on display names to resolve lights.
- Shipping an unverified DTLS/UDP Entertainment transport.

## Verification

NAS tests should cover renderer selection, frame generation, CLIP fallback frame
application, track-change transitions, stop behavior, duplicate light isolation,
task-light filtering, and status reporting.

iOS tests should cover relay config encoding, relay takeover behavior, local
rendering deferral, and status decoding/display models.

Build verification should include:

- `npm test` in `nas-relay`
- `npm run build` in `nas-relay`
- focused iOS tests for Hue ambience config and relay takeover behavior
