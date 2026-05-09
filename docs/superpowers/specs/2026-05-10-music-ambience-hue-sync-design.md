# Music Ambience Hue Sync Design

## Goal

Add a Hue light-sync feature named **Music Ambience** that pairs Charm Player
with a user's Philips Hue Bridge, maps Sonos rooms to Hue lighting areas, and
changes lights based on the current song's album-art palette while playback is
active.

This is ambience, not beat detection. The first implementation should feel
musical and responsive to track changes, but it must not imply real audio
analysis unless a future backend can provide reliable audio features.

## Product Direction

Music Ambience is a hybrid feature:

- **App-only mode** works for users without a NAS. It can run while the app is
  foregrounded and may continue briefly in the background, but the UI must be
  honest that iOS limits long-running local-network light streaming.
- **NAS-enhanced mode** is an upgrade path for always-on syncing. The iOS app
  still owns Bridge pairing, user-facing setup, and Sonos-to-Hue mappings, but
  a future relay/agent can run the continuous Hue stream on the home network.

The main lighting unit is a Hue Entertainment Area. Hue Rooms/Zones and
individual lights remain available as a basic fallback, not as the primary
mental model.

## Approaches Considered

### App-only REST control

The app could pair with the Bridge and periodically update selected lights or
Rooms/Zones. This is straightforward and works without a NAS, but it is the
least suitable path for fast continuous effects. It also risks flattening
gradient lights to a single color when the available endpoint cannot address
multiple segments.

### NAS-only streaming

A home server could listen to Sonos state and drive Hue Entertainment streaming
continuously. This is the most reliable technical path for always-on gradient
effects, but it excludes users who cannot run local infrastructure.

### Hybrid Entertainment-first

The selected direction is hybrid. The app ships a complete setup and app-only
sync path, while the data model and UI are ready for a NAS-enhanced runtime.
Entertainment Areas are preferred because they already express which lights
participate in a synchronized experience and provide spatial information that
helps waves and gradients look intentional.

## Hue Bridge Onboarding

Settings gains a **Hue Music Ambience** section. If no Bridge is paired, it
shows a setup entry point. Tapping it opens a guided sheet:

1. **Find Bridge**: discover Hue Bridges on the local network, with manual IP
   entry as fallback.
2. **Pair Bridge**: ask the user to press the physical Bridge link button, then
   create and store the local application key securely.
3. **Load Areas**: fetch Hue Entertainment Areas first, then Rooms/Zones and
   lights for fallback mode.
4. **Assign To Sonos**: map each visible Sonos room/coordinator to one preferred
   Entertainment Area or one fallback Room/Zone.
5. **Choose Behavior**: set group-playback behavior and whether Music Ambience
   starts automatically when playback begins.
6. **Preview And Save**: run a short album-palette preview and confirm restore
   behavior when playback pauses/stops.

After setup, Settings keeps advanced detail pages for Bridge status, mappings,
fallback mode, group behavior, and NAS-enhanced mode.

## Mapping Model

Mappings are stored by stable Sonos identifiers and Hue resource identifiers:

- Sonos target ID: coordinator `SonosPlayer.id` when available, falling back to
  persisted speaker/group IDs already used by home speaker ordering.
- Preferred Hue target: Entertainment Area ID.
- Fallback Hue target: Room or Zone ID.
- Optional exclusions/inclusions for basic fallback mode only.
- Sync capability snapshot: basic color, gradient-capable, entertainment-ready.

Entertainment Area selection is the default UI. If a Sonos room has no matching
Entertainment Area, the setup recommends creating one in the Hue app but allows
the user to continue with basic Room/Zone sync.

## Group Playback

When Sonos rooms are grouped, Music Ambience defaults to syncing every mapped
room in the playing group. Users can override this in Settings:

- **All mapped rooms**: combine the Hue targets for every visible Sonos group
  member.
- **Coordinator only**: sync only the current Sonos coordinator's Hue target.
- **Ask per group**: future-ready option if group-specific behavior becomes
  useful.

If the Hue Bridge/runtime cannot drive all requested Entertainment Areas at
once, the runtime falls back to the coordinator mapping and surfaces that status
non-destructively.

## Color And Effect Design

Music Ambience uses album art as its primary input:

- Extract a palette of 4-6 representative colors from the current artwork.
- Recompute only when the track/artwork changes.
- Use slower, tasteful motion: palette wave, breathing, gradient drift, and
  transition-on-track-change.
- Restore or fade to the user's chosen fallback scene/state when playback
  stops, pauses for long enough, or sync is disabled.

No beat-reactive or frequency-reactive mode ships in the first version.

## Gradient Strategy

Gradient support is capability-based:

- **Basic**: Room/Zone fallback with single-color or low-frequency color changes.
- **Gradient Ready**: gradient lights are detected and can receive multi-color
  album palettes where the available Hue API/runtime supports it.
- **Live Entertainment**: Entertainment Area streaming can drive dynamic
  multi-point gradients while the app is foregrounded; NAS-enhanced mode can
  keep that stream alive continuously.

REST control must not be used for continuous fast effects. If only basic REST
control is available for a target, the UI labels the result as basic ambience
instead of live gradient sync.

## Runtime Architecture

Create focused Hue components rather than folding the feature into
`SonosManager`:

- `HueBridgeDiscovery`: local discovery and manual-IP probing.
- `HueBridgeClient`: V2 Bridge HTTP API client, pairing, resource fetches, and
  basic control commands.
- `HueCredentialStore`: Keychain-backed Bridge app-key storage.
- `HueAmbienceStore`: persisted Bridge metadata, mappings, feature toggles, and
  capability snapshots.
- `AlbumPaletteExtractor`: reusable palette extraction from `UIImage`/artwork
  data. It should build on the existing dominant-color utilities but return a
  multi-color palette.
- `MusicAmbienceManager`: observes Sonos playback state, chooses mapped Hue
  targets, coordinates sync lifecycle, and delegates light writes/streams.
- `MusicAmbienceSettingsView`: guided onboarding and advanced detail UI.

`SonosManager` should expose or call a narrow integration point when track,
playback state, group membership, or album art changes. It should not learn
Hue API details.

## App-Only Behavior

App-only sync starts when all of these are true:

- Music Ambience is enabled.
- A paired Bridge is reachable.
- The currently playing Sonos room/group has a mapping.
- Playback state is playing.
- Album art or a fallback palette is available.

When the app goes to background, the feature should keep the current ambience
state if possible and stop continuous streaming when iOS no longer grants
execution time. Settings and status rows must explain that always-on background
sync requires NAS-enhanced mode.

## NAS-Enhanced Path

The app-facing design should not require a NAS in the first release, but it
should save enough structured configuration for a future home service:

- Bridge IP / Bridge ID, without exposing secrets unnecessarily.
- Sonos-to-Hue mappings.
- Group strategy.
- Effect mode and restore behavior.

The future NAS service receives configuration from the app or a shared local
endpoint, listens to Sonos events, and runs Hue Entertainment streaming even
when the iOS app is suspended.

## Error Handling

The UI should treat Hue failures as recoverable:

- Bridge not found: offer rescan and manual IP.
- Link button not pressed: keep the pairing screen active and retry.
- Bridge certificate / HTTPS issue: surface a clear local-network Bridge error.
- No Entertainment Areas: recommend creating one in Hue, allow basic fallback.
- Target unavailable: disable that mapping row and keep other mappings active.
- Streaming conflict with another Hue app: pause Music Ambience and show status.
- App-only background limit: show "Paused in background" rather than an error.

Disabling Music Ambience stops active effects and restores the configured
fallback scene/state for affected targets.

## Testing Strategy

Unit tests should cover:

- Palette extraction returns multiple stable colors from representative artwork.
- Mapping selection for standalone speakers and grouped Sonos playback.
- Fallback choice when Entertainment Area is unavailable.
- Capability labels for basic, gradient-ready, and live entertainment targets.
- App-only lifecycle decisions when playback starts, pauses, stops, or changes
  track.
- Credential persistence wrappers using injectable storage where possible.

Network clients should be built behind protocols so tests can use fixture JSON
for Bridge resources and avoid real Hue hardware.

## Out Of Scope For First Release

- True beat, loudness, or frequency analysis.
- Per-song effect presets.
- A full lighting-stage editor that duplicates the Hue app's Entertainment Area
  setup.
- Multi-Bridge orchestration beyond pairing one Bridge.
- Guaranteed background streaming without NAS-enhanced runtime.

## References

- Philips Hue Developer Program, "New Hue API": V2 adds gradient entertainment
  technology, Hue V2 uses HTTPS, Entertainment V2 is recommended for gradient
  lights, and REST APIs should not be used for continuous fast light updates:
  https://developers.meethue.com/new-hue-api/
