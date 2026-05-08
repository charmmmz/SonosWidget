# Apple Music Handoff to Sonos Design

## Goal

Add a Home-screen `TRANSFER` action that moves the song currently playing in
Apple Music on the iPhone to the currently selected Sonos speaker or group.
The experience should feel like a handoff: the same track starts on Sonos near
the same playback position, then playback on the iPhone pauses.

## Scope

Version 1 supports only Apple Music through the system Music app. It does not
try to read arbitrary system Now Playing data from Spotify, YouTube Music,
podcast apps, browsers, or other audio sources. iOS exposes the Music app state
through `MPMusicPlayerController.systemMusicPlayer`, but third-party apps do
not get a general-purpose global Now Playing API.

The transfer target is the app's current Sonos control target:

- the selected Home speaker or group
- the resolved Sonos Cloud group for that selected target when remote mode is
  active
- the selected LAN coordinator when local control is active

If no selected Sonos target exists, the action fails with a clear message.

## User Experience

The Home screen adds a single `TRANSFER` control above `UNGROUP`. It is not
repeated on each speaker card. The label is uppercase to match the surrounding
Home controls.

When tapped, `TRANSFER` enters a short loading state and performs the transfer.
On success, the Home screen shows a brief confirmation such as "Transferred to
Living Room". On failure, it shows a specific non-destructive error and does
not start Sonos playback.

Expected user-visible errors:

- Apple Music access is not authorized.
- Nothing is currently playing in Apple Music.
- The current Apple Music item cannot be identified.
- The app is not connected to Sonos Cloud.
- Apple Music is not linked in the Sonos household.
- The current song could not be matched confidently on Sonos.
- The selected Sonos speaker or group is unavailable.

## Data Flow

1. Request or check media library authorization with MediaPlayer.
2. Read `MPMusicPlayerController.systemMusicPlayer`:
   - `nowPlayingItem`
   - `currentPlaybackTime`
   - `playbackState`
3. Extract a normalized handoff candidate:
   - title
   - artist
   - album
   - duration
   - playback position
4. Confirm Sonos Cloud auth and household state using existing `SonosAuth`.
5. Find the linked Sonos Apple Music account from `SearchManager.linkedAccounts`.
6. Search Apple Music through the existing Sonos content search endpoint.
7. Score track candidates and require a confidence threshold.
8. Convert the winning Sonos result to a `BrowseItem`.
9. Play the item on the current selected Sonos target.
10. Seek Sonos to the captured iPhone playback position when possible.
11. After Sonos playback starts successfully, pause the iPhone Music player.
12. Refresh the Sonos manager state so the Home card and mini-player update.

## Matching Rules

The matcher should be strict enough to avoid wrong playback.

Inputs are normalized by trimming whitespace, lowercasing, removing common
punctuation noise, and comparing folded diacritics.

Candidate scoring:

- title match is required
- artist match carries the highest weight after title
- album match improves confidence but is not required
- duration should be within a small tolerance when both durations are known
- exact Apple Music object IDs are preferred if available in both source and
  Sonos search result data

If no candidate crosses the threshold, the transfer fails instead of playing
the nearest weak match. Candidate picker UI is intentionally out of scope for
v1.

## Components

### AppleMusicHandoffManager

A new focused service that owns the iPhone-side capture flow. It should use
MediaPlayer and expose one main async operation:

```swift
func currentAppleMusicTrack() async throws -> AppleMusicHandoffTrack
```

`AppleMusicHandoffTrack` contains the title, artist, album, duration, playback
position, and any available store or persistent identifiers. The service also
owns pausing the system Music player after Sonos playback succeeds.

### SearchManager Extensions

`SearchManager` already knows linked accounts, Sonos Cloud search, Cloud to
local service ID mapping, and playback conversion. Add a small handoff-facing
method rather than duplicating that logic in the view:

```swift
func transferAppleMusicTrack(
    _ track: AppleMusicHandoffTrack,
    manager: SonosManager
) async -> HandoffResult
```

This method should:

- ensure linked service probing has run
- locate the linked Apple Music account
- search only Apple Music when possible
- score candidates
- play the selected match using existing playback paths
- seek through `SonosControl.seek` or the existing manager backend

### PlayerView

`PlayerView` owns the Home controls. Add local UI state for handoff progress
and render `TRANSFER` above `UNGROUP`. The view should call the handoff method
and surface toast or manager error text, following existing Home UI patterns.

## Playback Strategy

Use the existing Sonos playback path for v1 instead of implementing a custom
Sonos Cloud Queue service. The project already has URI/DIDL construction and
Sonos search result playback. Reusing it keeps the feature small and avoids
running a queue endpoint that Sonos players would need to call back.

After playback starts, seek to the captured iPhone position. The seek should be
best effort:

- clamp to the track duration when known
- skip seeking if the captured position is near zero
- do not fail the whole transfer if seek fails after playback started

Pause the iPhone Music player only after Sonos playback has been started. This
prevents a failed transfer from stopping the user's current music.

## Permissions

Add `NSAppleMusicUsageDescription` to the app Info.plist if it is not already
present. The copy should explain that the app reads the currently playing Apple
Music track to transfer it to Sonos.

If authorization is denied or restricted, show a clear error. Do not repeatedly
prompt in a loop.

## Error Handling

Errors should be typed where practical so the UI can show concise messages.
Important cases:

- `mediaAccessDenied`
- `notPlayingAppleMusic`
- `missingTrackMetadata`
- `sonosCloudDisconnected`
- `appleMusicNotLinkedOnSonos`
- `noConfidentMatch`
- `sonosPlaybackFailed`

The implementation should log enough detail for debugging while keeping user
messages short.

## Testing

Recommended checks:

- Unit-test the matcher with exact matches, remastered titles, punctuation
  differences, wrong artists, and close-duration mismatches.
- Test authorization handling with allowed and denied media library access.
- Test transfer failure when no Sonos Apple Music account is linked.
- Test the happy path on a physical iPhone with Apple Music playing.
- Verify that iPhone playback pauses only after Sonos playback succeeds.
- Verify that the generic iOS build succeeds.

## Non-Goals

- Reading Now Playing from arbitrary third-party audio apps.
- AirPlay-style audio stream capture or rebroadcast.
- A candidate selection UI for ambiguous matches.
- A custom Sonos Cloud Queue service.
- Background automatic transfer without a user tap.

## References

- Apple `MPMusicPlayerController` and `systemMusicPlayer` documentation.
- Apple Media Player authorization and `NSAppleMusicUsageDescription`
  requirements.
- Sonos Control API playback objects and playback session documentation.
