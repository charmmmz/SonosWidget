# Apple Music Forward Album Queue Handoff Design

## Goal

Enhance iPhone-to-Sonos Apple Music HANDOFF so it can carry album context, not
only the currently playing song. When the user hands off from the iPhone Music
app to a selected Sonos target, the app should build the full album queue on
Sonos, jump to the current track inside that queue, seek near the iPhone
playback position, and pause the iPhone only after Sonos starts successfully.

## Scope

This feature is a best-effort album-context handoff for Apple Music. It does
not read the Music app's real Up Next queue because Apple's public system music
player APIs do not expose an enumerable queue for the Music app state.

The supported v1 path is:

- Apple Music is playing in the system Music app on the iPhone.
- The current track can be matched confidently to an Apple Music track in Sonos
  Cloud search.
- The matched Sonos Apple Music track exposes or can resolve an album/container
  id.
- The selected Sonos target is reachable over LAN, because Sonos queue mutation
  is LAN-only in this project.

If any of those requirements are not met, the app falls back to the existing
single-track handoff behavior.

## User Experience

The Home screen keeps the existing single `HANDOFF` control. There is no new
button and no direction picker.

When the selected Sonos target is not playing, tapping `HANDOFF` continues to
mean "move iPhone Apple Music to Sonos." If the app can infer album context,
Sonos receives the whole album queue and starts at the current iPhone track. If
album context cannot be inferred, the current single song transfers exactly as
it does today.

Expected success messages:

- Full album queue: `Transferred album to <speaker>`
- Single-track fallback: existing single-track success copy
- Cloud/remote mode fallback: `Transferred current song. Queue sync requires
  the same network.`

The feature should never show a scary error just because album queue sync is
unavailable. Album queue sync is an enhancement; current-song handoff remains
the primary safe behavior.

## Accepted Queue Semantics

The accepted behavior is to load the entire album into the Sonos queue, then
jump to the current target song:

1. Add every playable album track to the Sonos queue in album order.
2. Set AVTransport to the Sonos queue.
3. Seek by `TRACK_NR` to the current track's album position.
4. Start playback.
5. Seek by time to the iPhone's captured playback position.

This is better than enqueueing only the current track and later tracks because
Sonos previous-track behavior can still move to earlier album songs, and the
queue view presents the full album context.

## API Findings

Option 3, reading the real Music app queue, was investigated and rejected for
the formal feature path:

- `MusicKit.SystemMusicPlayer.queue` returns `MusicPlayer.Queue`.
- `MusicPlayer.Queue` exposes `currentEntry` but not `entries`.
- `ApplicationMusicPlayer.Queue` exposes `entries`, but it is the app-owned
  queue, not the Music app's system queue.
- `MPMusicPlayerController.systemMusicPlayer` exposes now-playing state,
  playback state, repeat mode, and shuffle mode, but Apple's documentation says
  other Music app state is not shared.
- `MPMusicPlayerApplicationController.applicationQueuePlayer` can return a
  queue through queue transactions, but that queue belongs to the app player,
  not the user's current Music app Up Next queue.

Therefore the project should not depend on hidden or reflective access to the
Music app queue.

## Data Flow

1. Capture the current iPhone Apple Music track with
   `AppleMusicHandoffManager.currentAppleMusicTrack()`.
2. Confirm Sonos Cloud auth and linked Apple Music account.
3. Search the linked Sonos Apple Music account for the captured title and
   artist.
4. Use `HandoffMatcher` to pick a confident current-track match.
5. Resolve album context from the matched Sonos resource:
   - prefer the resource's container or album id when present
   - otherwise call Sonos now-playing metadata for the track when enough service
     ids are available
   - otherwise do not attempt album queue sync
6. Call `SonosCloudAPI.browseAlbum(...)` to fetch the full album track list.
7. Convert each playable album track to a Sonos `BrowseItem`, reusing the
   existing Cloud-to-local SID mapping and `SearchManager.makeTrackItem` style
   URI/DIDL construction.
8. Identify the target album track:
   - first by object id or store id
   - then by normalized title, artist, and duration
   - then by ordinal only when the current match exposes an unambiguous ordinal
9. If album planning succeeds and the selected target is LAN-controllable,
   replace the Sonos queue with the album queue and jump to the target track.
10. If album planning fails or the target is cloud-only, use the existing
    single-track handoff path.
11. Pause the iPhone only after Sonos playback has started successfully.
12. Refresh `SonosManager` state and queue so Home, mini-player, and queue UI
    reflect the new Sonos playback context.

## Components

### AppleMusicForwardAlbumQueuePlanner

A new pure planner that receives:

- album tracks converted to lightweight candidates
- the matched current track
- the captured iPhone track
- a max item count

It returns:

- ordered Sonos `BrowseItem` values for the whole album
- the one-based target track number for `Seek TRACK_NR`
- counts for skipped unsupported album items
- a reason when planning fails

This component should be unit-tested without MediaPlayer, MusicKit, Sonos Cloud,
or LAN calls.

### SearchManager

`SearchManager.transferAppleMusicTrack(_:manager:)` should become the
orchestration point:

- continue to find the current Sonos Apple Music match
- ask the album queue planner for a plan
- choose full-album LAN queue handoff when possible
- otherwise use the existing single-track playback path

The single-track path should stay intact and small so fallback behavior remains
reliable.

### SonosManager / SonosControl

No Cloud queue mutation should be added. Album queue sync should use existing
LAN queue operations:

- `RemoveAllTracksFromQueue`
- `AddURIToQueue`
- `SetAVTransportURI` to `x-rincon-queue`
- `Seek TRACK_NR`
- `Play`
- time seek to the captured iPhone position

If the selected target is in Cloud mode, the album queue path is skipped.

## Error Handling

Album queue sync failures should be soft failures unless the current-song
handoff also fails.

Soft fallback cases:

- no album id can be resolved
- album browse fails
- album browse returns no playable tracks
- current track cannot be identified in the album
- target is cloud-only or otherwise not LAN-controllable
- one or more album tracks cannot be converted to Sonos playable URIs

Hard failures remain the existing handoff failures:

- Apple Music media access is denied
- the iPhone is not playing Apple Music
- Sonos Cloud is disconnected before the current track can be matched
- Apple Music is not linked in the Sonos household
- no confident current-track match exists
- Sonos cannot start even the fallback single track

## Testing

Automated tests should cover:

- planner returns full album order and target track number
- planner matches current track by object/store id
- planner falls back to title, artist, and duration matching
- planner rejects ambiguous current-track matches
- planner skips unsupported album tracks but preserves target track numbering
  when possible
- orchestration chooses album queue only for LAN mode
- orchestration falls back to single-track handoff in Cloud mode
- iPhone pause is still called only after Sonos playback succeeds

Manual checks should use a physical iPhone and a LAN-reachable Sonos target:

- start a track in the middle of an Apple Music album on iPhone
- tap `HANDOFF`
- verify Sonos queue contains the full album
- verify Sonos starts at the same album track
- verify Sonos seeks near the iPhone playback position
- verify previous/next track navigation moves within the album
- verify iPhone playback pauses only after Sonos starts

## Non-Goals

- Reading the Music app's actual Up Next queue.
- Syncing Apple Music playlists, stations, algorithmic radio, or manually
  edited Up Next.
- Supporting non-Apple-Music sources.
- Mutating Sonos queues while the selected target is cloud-only.
- Using private or reflective APIs to inspect Music app state.

## References

- Apple `SystemMusicPlayer` documentation:
  https://developer.apple.com/documentation/musickit/systemmusicplayer
- Apple `MusicPlayer.Queue` documentation:
  https://developer.apple.com/documentation/musickit/musicplayer/queue
- Apple `ApplicationMusicPlayer.Queue` documentation:
  https://developer.apple.com/documentation/musickit/applicationmusicplayer/queue-swift.class
- Apple `MPMusicPlayerController` documentation:
  https://developer.apple.com/documentation/mediaplayer/mpmusicplayercontroller
