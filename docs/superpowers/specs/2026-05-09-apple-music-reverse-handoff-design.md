# Apple Music Reverse Handoff Design

## Goal

Add the reverse direction for the existing Home `TRANSFER` feature: move the
currently playing Apple Music track from the selected Sonos speaker or group
back to the iPhone Music app. The experience should mirror the first handoff:
the same track starts on the iPhone near the same playback position, then Sonos
pauses only after iPhone playback starts successfully.

## Scope

Version 1 supports only Sonos tracks whose source is Apple Music. It does not
try to transfer Spotify, radio, local library, TV, line-in, podcasts, or generic
streams to Apple Music. If the current Sonos source is not Apple Music, the app
shows:

```text
Only Apple Music can be transferred to iPhone.
```

The target is always the system Music app on the current iPhone through
`MPMusicPlayerController.systemMusicPlayer`. This keeps behavior consistent
with the existing iPhone-to-Sonos handoff and with the user's expectation that
music continues outside the app.

## User Experience

The Home screen keeps a single `TRANSFER` entry above `UNGROUP`. Tapping it
opens a compact two-option direction picker:

- `iPhone -> Sonos`
- `Sonos -> iPhone`

The existing iPhone-to-Sonos action moves under the first option. The reverse
action lives under the second option. The Home screen should not add a second
permanent button and should not add controls to every speaker card.

While a transfer is running, the `TRANSFER` control shows its existing loading
state and blocks repeated taps. On success it shows a toast such as:

```text
Transferred to iPhone
```

On failure, it shows a specific non-destructive message and leaves the original
Sonos playback alone unless iPhone playback has already started.

## Data Flow

1. Read the current selected Sonos target and lock that target for the operation.
2. Refresh or use `SonosManager.trackInfo` to capture:
   - title
   - artist
   - album
   - duration
   - playback position
   - `trackURI`
   - playback source
3. Require `PlaybackSource.appleMusic`.
4. Resolve an Apple Music playable store id using this priority:
   - parse a usable object id from the Sonos `trackURI`
   - call existing Sonos Cloud nowPlaying metadata when service id/account id
     are available
   - fall back to a Sonos Apple Music service search and `HandoffMatcher`
5. Ask the iPhone Music player to set a queue with that store id.
6. Start iPhone playback.
7. If the Sonos position is greater than 3 seconds, seek the iPhone Music player
   near the same position using `currentPlaybackTime`.
8. Verify the iPhone player has started or has a now-playing item.
9. Pause the locked Sonos target.
10. Refresh Sonos state and show a success toast.

## ID Resolution

The reverse path should be ID-first because playing on iPhone needs an Apple
Music store identifier. The implementation should try to parse the track id
from Sonos URIs shaped like `x-sonos-http:<objectId>...?...sid=...&sn=...`.
It should remove Sonos URI prefixes, service-specific object prefixes, and file
extensions in the same spirit as the existing `fetchNowPlaying(trackURI:)`
helper in `PlayerView`.

When direct parsing does not produce a usable id, the app should use the linked
Sonos Apple Music account and search for `title artist`. Search results are
converted to `BrowseItem` and scored with the existing `HandoffMatcher`. The
matched `BrowseItem.id` or its parsed URI object id becomes the store id for
the iPhone queue.

If no confident Apple Music match is found, the reverse transfer fails rather
than guessing.

## Components

### AppleMusicHandoffManager

Extend the existing MediaPlayer service with an iPhone playback operation:

```swift
func playAppleMusicTrack(
    storeID: String,
    position: TimeInterval?
) async throws
```

The operation should:

- require media library authorization
- call `systemMusicPlayer.setQueue(with: [storeID])`
- call `prepareToPlay` when useful for error reporting
- call `play()`
- set `currentPlaybackTime` after playback is prepared or started when a
  position is provided
- throw a typed error if iPhone playback cannot be started

### SearchManager

Add reverse orchestration near the existing handoff method:

```swift
func transferSonosAppleMusicToPhone(manager: SonosManager) async throws -> ReverseHandoffResult
```

This method should:

- capture and validate the selected Sonos target
- require Apple Music as the current Sonos source
- resolve a store id using ID-first/search-fallback logic
- start playback on the iPhone through `AppleMusicHandoffManager`
- pause the locked Sonos target only after iPhone playback starts
- return a result with the matched title and whether seek was attempted

### PlayerView

Replace the direct `TRANSFER` button action with a small direction picker. The
picker can be a SwiftUI `Menu` or another compact control that fits the current
Home action zone. The first option calls the existing iPhone-to-Sonos handler.
The second option calls a new reverse handler.

Keep `UNGROUP` below the transfer control.

## Error Handling

Important user-facing failures:

- no selected Sonos target
- Sonos is not currently playing Apple Music
- Sonos current track cannot be identified
- Sonos Cloud is disconnected when fallback search or nowPlaying metadata is
  required
- Apple Music is not linked in the Sonos household
- no confident Apple Music match is found
- iPhone Music access is denied
- iPhone playback cannot be started
- Sonos pause fails after iPhone playback starts

The safest rule is: do not pause Sonos until the iPhone playback step returns
success. If pausing Sonos fails after iPhone playback starts, show a warning
toast but leave iPhone playback running.

## Playback and Seek Strategy

The reverse path should use `MPMusicPlayerController.systemMusicPlayer` so the
Music app becomes the system Now Playing app. Apple Media Player supports
setting a queue with store identifiers. `currentPlaybackTime` is writable, so
the app can best-effort seek after setting the queue.

Seeking should be best effort:

- skip seek when Sonos position is 0-3 seconds
- clamp to duration minus 2 seconds when duration is known
- do not fail the whole transfer if seek fails after playback starts

## Testing

Recommended automated checks:

- Unit-test Sonos track URI parsing into Apple Music object/store ids.
- Unit-test source gating: non-Apple-Music `TrackInfo` fails before iPhone
  playback.
- Unit-test fallback matching with existing `HandoffMatcher`, including CJK
  titles.
- Unit-test that Sonos pause is not attempted when iPhone playback fails, using
  a small test seam or focused helper if practical.

Recommended device checks:

- Apple Music track playing on Sonos transfers to iPhone and then Sonos pauses.
- Non-Apple-Music source shows the Apple Music-only message and does not pause.
- Transfer near the middle of a song seeks close to the Sonos position.
- Failure to find a match leaves Sonos playing.

## Non-Goals

- Transferring Spotify, radio, TV, line-in, local library, or podcast playback.
- Adding a full candidate picker for ambiguous Apple Music matches.
- Rebuilding playback queues beyond the single current track.
- Background or automatic transfer without a user tap.
- AirPlay-style audio capture or stream forwarding.

## References

- Apple `MPMusicPlayerController` documentation:
  https://developer.apple.com/documentation/mediaplayer/mpmusicplayercontroller
- Apple `setQueue(with:)` documentation:
  https://developer.apple.com/documentation/mediaplayer/mpmusicplayercontroller/setqueue%28with%3A%29-xlwk
- Apple `playbackStoreID` documentation:
  https://developer.apple.com/documentation/mediaplayer/mpmediaitem/playbackstoreid
- Apple archived Media Player playback guide for writable
  `currentPlaybackTime`:
  https://developer.apple.com/library/archive/documentation/Audio/Conceptual/iPodLibraryAccess_Guide/UsingMediaPlayback/UsingMediaPlayback.html
