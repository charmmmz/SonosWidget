# Apple Music Forward Album Queue Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Apple Music -> Sonos HANDOFF so a matched album can be loaded into the Sonos queue, then playback jumps to the iPhone's current track and position.

**Architecture:** Keep the risky matching and queue math in a pure `AppleMusicForwardAlbumQueuePlanner` with focused unit tests. Let `SearchManager` orchestrate Sonos Cloud search/album browse and LAN queue mutation, with the current single-track handoff path as the fallback whenever album queue sync is unavailable.

**Tech Stack:** Swift, SwiftUI, XCTest, MediaPlayer, Sonos Cloud content APIs, Sonos LAN UPnP/SOAP queue APIs.

---

## File Structure

- Create: `SonosWidget/AppleMusicForwardAlbumQueuePlanner.swift`
  - Pure planning unit. Takes converted album track candidates plus the already matched current track, returns Sonos queue items and the one-based target track number for `Seek TRACK_NR`.
- Create: `SonosWidgetTests/AppleMusicForwardAlbumQueuePlannerTests.swift`
  - Unit tests for album ordering, target matching, unsupported item skipping, ambiguity rejection, and max item limiting.
- Modify: `SonosWidget/SearchManager.swift`
  - Extend `HandoffResult` to report album queue details.
  - Preserve Cloud search candidate resources so album/container ids can be resolved.
  - Add private helpers for album id resolution, album browse conversion, LAN album queue playback, and position seeking.
  - Prefer album queue handoff in LAN mode; fall back to existing single-track handoff for Cloud mode or soft album failures.
- Modify: `SonosWidget/PlayerView.swift`
  - Show album-aware success copy and soft fallback warnings.
  - Keep pausing iPhone playback only after `SearchManager.transferAppleMusicTrack` succeeds.
- Modify: `docs/implementation-notes/apple-music-handoff.md`
  - Document the forward album queue behavior and its limitations.
- No change expected: `SonosWidget.xcodeproj/project.pbxproj`
  - The project uses `PBXFileSystemSynchronizedRootGroup`, so new Swift files under `SonosWidget/` and `SonosWidgetTests/` are picked up by the folder-synced targets.

## Current Constraints

- Do not try to read the real Music app Up Next queue. Public APIs expose `SystemMusicPlayer.queue.currentEntry`, not enumerable entries.
- Sonos queue mutation remains LAN-only in this project. Cloud/remote mode must continue the current single-track transfer.
- The selected speaker must stay locked through the handoff, matching the existing `lockedTarget` behavior.
- If album queue sync fails, current-song handoff is still the success path.
- The iPhone should be paused only after Sonos playback starts successfully.

### Task 1: Add Forward Album Queue Planner Tests

**Files:**
- Create: `SonosWidgetTests/AppleMusicForwardAlbumQueuePlannerTests.swift`

- [ ] **Step 1: Create failing planner tests**

Create `SonosWidgetTests/AppleMusicForwardAlbumQueuePlannerTests.swift` with this content:

```swift
import XCTest
@testable import SonosWidget

final class AppleMusicForwardAlbumQueuePlannerTests: XCTestCase {
    func testPlanKeepsWholeAlbumOrderAndTargetsMatchedTrackNumber() {
        let albumTracks = [
            makeCandidate(id: "track-1", title: "Before"),
            makeCandidate(id: "track-2", title: "Current"),
            makeCandidate(id: "track-3", title: "After")
        ]
        let source = makeSourceTrack(title: "Current")

        let plan = AppleMusicForwardAlbumQueuePlanner.makePlan(
            albumTracks: albumTracks,
            matchedItem: albumTracks[1].item,
            sourceTrack: source)

        XCTAssertEqual(plan?.items.map(\.title), ["Before", "Current", "After"])
        XCTAssertEqual(plan?.targetTrackNumber, 2)
        XCTAssertEqual(plan?.transferredTrackCount, 3)
        XCTAssertEqual(plan?.skippedUnsupportedItemCount, 0)
    }

    func testPlanMatchesTargetByStoreIDWhenObjectIDsDiffer() {
        let albumTracks = [
            makeCandidate(id: "album-1", title: "Before", storeID: "111"),
            makeCandidate(id: "album-2", title: "Current", storeID: "222"),
            makeCandidate(id: "album-3", title: "After", storeID: "333")
        ]
        let matched = makeItem(id: "search-result", title: "Current", storeID: "222")
        let source = makeSourceTrack(title: "Current")

        let plan = AppleMusicForwardAlbumQueuePlanner.makePlan(
            albumTracks: albumTracks,
            matchedItem: matched,
            sourceTrack: source)

        XCTAssertEqual(plan?.targetTrackNumber, 2)
        XCTAssertEqual(plan?.items.map(\.id), ["album-1", "album-2", "album-3"])
    }

    func testPlanFallsBackToUniqueMetadataMatch() {
        let albumTracks = [
            makeCandidate(id: "track-1", title: "Intro", duration: 60),
            makeCandidate(id: "track-2", title: "Current", duration: 181),
            makeCandidate(id: "track-3", title: "Outro", duration: 200)
        ]
        let matched = makeItem(id: "search-result", title: "Current", storeID: nil, duration: 181)
        let source = makeSourceTrack(title: "Current", duration: 180)

        let plan = AppleMusicForwardAlbumQueuePlanner.makePlan(
            albumTracks: albumTracks,
            matchedItem: matched,
            sourceTrack: source)

        XCTAssertEqual(plan?.targetTrackNumber, 2)
    }

    func testPlanRejectsAmbiguousMetadataMatch() {
        let albumTracks = [
            makeCandidate(id: "track-1", title: "Interlude", duration: 90),
            makeCandidate(id: "track-2", title: "Interlude", duration: 92),
            makeCandidate(id: "track-3", title: "Outro", duration: 200)
        ]
        let matched = makeItem(id: "search-result", title: "Interlude", storeID: nil, duration: 91)
        let source = makeSourceTrack(title: "Interlude", duration: 91)

        let plan = AppleMusicForwardAlbumQueuePlanner.makePlan(
            albumTracks: albumTracks,
            matchedItem: matched,
            sourceTrack: source)

        XCTAssertNil(plan)
    }

    func testPlanSkipsUnsupportedItemsAndAdjustsTargetTrackNumber() {
        let albumTracks = [
            makeCandidate(id: "track-1", title: "Playable Before", storeID: "111"),
            makeCandidate(id: "track-2", title: "Unavailable Before", playable: false),
            makeCandidate(id: "track-3", title: "Current", storeID: "333"),
            makeCandidate(id: "track-4", title: "Unavailable After", playable: false),
            makeCandidate(id: "track-5", title: "Playable After", storeID: "555")
        ]
        let source = makeSourceTrack(title: "Current")

        let plan = AppleMusicForwardAlbumQueuePlanner.makePlan(
            albumTracks: albumTracks,
            matchedItem: albumTracks[2].item,
            sourceTrack: source)

        XCTAssertEqual(plan?.items.map(\.title), ["Playable Before", "Current", "Playable After"])
        XCTAssertEqual(plan?.targetTrackNumber, 2)
        XCTAssertEqual(plan?.skippedUnsupportedItemCount, 2)
    }

    func testPlanReturnsNilWhenMatchedTrackIsUnsupported() {
        let albumTracks = [
            makeCandidate(id: "track-1", title: "Before", storeID: "111"),
            makeCandidate(id: "track-2", title: "Current", playable: false),
            makeCandidate(id: "track-3", title: "After", storeID: "333")
        ]
        let source = makeSourceTrack(title: "Current")

        let plan = AppleMusicForwardAlbumQueuePlanner.makePlan(
            albumTracks: albumTracks,
            matchedItem: albumTracks[1].item,
            sourceTrack: source)

        XCTAssertNil(plan)
    }

    func testPlanHonorsMaxItemsBeforePlanningTarget() {
        let albumTracks = [
            makeCandidate(id: "track-1", title: "One"),
            makeCandidate(id: "track-2", title: "Two"),
            makeCandidate(id: "track-3", title: "Three")
        ]
        let source = makeSourceTrack(title: "Three")

        let plan = AppleMusicForwardAlbumQueuePlanner.makePlan(
            albumTracks: albumTracks,
            matchedItem: albumTracks[2].item,
            sourceTrack: source,
            maxItems: 2)

        XCTAssertNil(plan)
    }

    private func makeCandidate(
        id: String,
        title: String,
        artist: String = "Artist",
        album: String = "Album",
        storeID: String? = nil,
        duration: TimeInterval = 180,
        playable: Bool = true,
        ordinal: Int? = nil
    ) -> AppleMusicForwardAlbumTrackCandidate {
        AppleMusicForwardAlbumTrackCandidate(
            item: makeItem(
                id: id,
                title: title,
                artist: artist,
                album: album,
                storeID: storeID ?? id,
                duration: duration,
                playable: playable),
            ordinal: ordinal)
    }

    private func makeItem(
        id: String,
        title: String,
        artist: String = "Artist",
        album: String = "Album",
        storeID: String? = nil,
        duration: TimeInterval = 180,
        playable: Bool = true
    ) -> BrowseItem {
        let uri = playable
            ? "x-sonos-http:10032020\(storeID ?? id).mp4?sid=204&flags=8232&sn=2"
            : nil
        return BrowseItem(
            id: id,
            title: title,
            artist: artist,
            album: album,
            albumArtURL: nil,
            uri: uri,
            metaXML: nil,
            duration: duration,
            resMD: nil,
            isContainer: false,
            serviceId: playable ? 204 : nil,
            cloudType: playable ? "TRACK" : nil,
            cloudFavoriteId: nil)
    }

    private func makeSourceTrack(
        title: String,
        artist: String = "Artist",
        album: String? = "Album",
        duration: TimeInterval? = 180
    ) -> AppleMusicHandoffTrack {
        AppleMusicHandoffTrack(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            position: 42,
            playbackStoreID: nil,
            persistentID: nil)
    }
}
```

- [ ] **Step 2: Run tests and verify they fail because the planner does not exist**

Run:

```bash
xcodebuild test \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SonosWidgetTests/AppleMusicForwardAlbumQueuePlannerTests
```

Expected: build fails with errors like `cannot find 'AppleMusicForwardAlbumQueuePlanner' in scope` and `cannot find 'AppleMusicForwardAlbumTrackCandidate' in scope`.

- [ ] **Step 3: Commit the failing tests**

Run:

```bash
git add SonosWidgetTests/AppleMusicForwardAlbumQueuePlannerTests.swift
git commit -m "test: cover forward album handoff planner"
```

### Task 2: Implement Forward Album Queue Planner

**Files:**
- Create: `SonosWidget/AppleMusicForwardAlbumQueuePlanner.swift`
- Test: `SonosWidgetTests/AppleMusicForwardAlbumQueuePlannerTests.swift`

- [ ] **Step 1: Add the planner implementation**

Create `SonosWidget/AppleMusicForwardAlbumQueuePlanner.swift` with this content:

```swift
import Foundation

struct AppleMusicForwardAlbumTrackCandidate: Equatable, Sendable {
    let item: BrowseItem
    let ordinal: Int?
}

struct AppleMusicForwardAlbumQueuePlan: Equatable, Sendable {
    let items: [BrowseItem]
    let targetTrackNumber: Int
    let skippedUnsupportedItemCount: Int

    var transferredTrackCount: Int { items.count }
}

enum AppleMusicForwardAlbumQueuePlanner {
    static let defaultMaxItems = 50

    static func makePlan(
        albumTracks: [AppleMusicForwardAlbumTrackCandidate],
        matchedItem: BrowseItem,
        sourceTrack: AppleMusicHandoffTrack,
        matchedOrdinal: Int? = nil,
        maxItems: Int = defaultMaxItems
    ) -> AppleMusicForwardAlbumQueuePlan? {
        guard maxItems > 0 else { return nil }
        let limitedTracks = Array(albumTracks.prefix(maxItems))
        guard !limitedTracks.isEmpty else { return nil }

        guard let targetOriginalIndex = targetIndex(
            in: limitedTracks,
            matchedItem: matchedItem,
            sourceTrack: sourceTrack,
            matchedOrdinal: matchedOrdinal)
        else { return nil }

        var playable: [(originalIndex: Int, item: BrowseItem)] = []
        var skipped = 0
        for (index, candidate) in limitedTracks.enumerated() {
            if isPlayable(candidate.item) {
                playable.append((index, candidate.item))
            } else {
                skipped += 1
            }
        }

        guard let targetPlayableIndex = playable.firstIndex(where: { $0.originalIndex == targetOriginalIndex }) else {
            return nil
        }

        return AppleMusicForwardAlbumQueuePlan(
            items: playable.map(\.item),
            targetTrackNumber: targetPlayableIndex + 1,
            skippedUnsupportedItemCount: skipped)
    }

    private static func targetIndex(
        in tracks: [AppleMusicForwardAlbumTrackCandidate],
        matchedItem: BrowseItem,
        sourceTrack: AppleMusicHandoffTrack,
        matchedOrdinal: Int?
    ) -> Int? {
        let matchedID = trimmed(matchedItem.id)
        if !matchedID.isEmpty,
           let index = tracks.firstIndex(where: { trimmed($0.item.id) == matchedID }) {
            return index
        }

        if let matchedStoreID = storeID(from: matchedItem),
           let index = tracks.firstIndex(where: { storeID(from: $0.item) == matchedStoreID }) {
            return index
        }

        let metadataMatches = tracks.indices.filter {
            metadataMatches(tracks[$0].item, sourceTrack: sourceTrack)
        }
        if metadataMatches.count == 1 {
            return metadataMatches[0]
        }

        if let matchedOrdinal {
            let ordinalMatches = tracks.indices.filter { tracks[$0].ordinal == matchedOrdinal }
            if ordinalMatches.count == 1 {
                return ordinalMatches[0]
            }
        }

        return nil
    }

    private static func metadataMatches(
        _ item: BrowseItem,
        sourceTrack: AppleMusicHandoffTrack
    ) -> Bool {
        let itemTitle = HandoffMatcher.normalized(item.title)
        let sourceTitle = HandoffMatcher.normalized(sourceTrack.title)
        guard !itemTitle.isEmpty, itemTitle == sourceTitle else { return false }

        let itemArtist = HandoffMatcher.normalized(item.artist)
        let sourceArtist = HandoffMatcher.normalized(sourceTrack.artist)
        guard sourceArtist.isEmpty || itemArtist.isEmpty || itemArtist == sourceArtist else {
            return false
        }

        if let sourceDuration = sourceTrack.duration,
           sourceDuration > 0,
           item.duration > 0 {
            return abs(sourceDuration - item.duration) <= 8
        }

        return true
    }

    private static func isPlayable(_ item: BrowseItem) -> Bool {
        guard let uri = item.uri?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uri.isEmpty else { return false }
        return item.cloudType == "TRACK"
    }

    private static func storeID(from item: BrowseItem) -> String? {
        SonosAppleMusicTrackResolver.storeID(fromTrackURI: item.uri)
            ?? SonosAppleMusicTrackResolver.storeID(fromObjectID: item.id)
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 2: Run the planner tests and verify they pass**

Run:

```bash
xcodebuild test \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SonosWidgetTests/AppleMusicForwardAlbumQueuePlannerTests
```

Expected: test action succeeds and the new planner test class passes.

- [ ] **Step 3: Commit the planner implementation**

Run:

```bash
git add SonosWidget/AppleMusicForwardAlbumQueuePlanner.swift SonosWidgetTests/AppleMusicForwardAlbumQueuePlannerTests.swift
git commit -m "feat: add forward album handoff planner"
```

### Task 3: Extend Forward Handoff Result Copy Surface

**Files:**
- Modify: `SonosWidget/SearchManager.swift`
- Modify: `SonosWidget/PlayerView.swift`

- [ ] **Step 1: Extend `HandoffResult`**

In `SonosWidget/SearchManager.swift`, replace the current `HandoffResult` with:

```swift
struct HandoffResult: Equatable {
    let matchedTitle: String
    let targetName: String
    let seeked: Bool
    let transferredTrackCount: Int
    let skippedUnsupportedItemCount: Int
    let warningMessage: String?

    var usedAlbumQueue: Bool { transferredTrackCount > 1 }
}
```

- [ ] **Step 2: Update the existing single-track return**

In `transferAppleMusicTrack(_:manager:)`, replace the existing return block:

```swift
return HandoffResult(
    matchedTitle: match.item.title,
    targetName: selectedSpeaker.name,
    seeked: didSeek)
```

with:

```swift
return HandoffResult(
    matchedTitle: match.item.title,
    targetName: selectedSpeaker.name,
    seeked: didSeek,
    transferredTrackCount: 1,
    skippedUnsupportedItemCount: 0,
    warningMessage: nil)
```

- [ ] **Step 3: Add forward handoff success copy**

In `SonosWidget/PlayerView.swift`, replace:

```swift
$homeToastMessage.showToast("Transferred to \(result.targetName)")
```

with:

```swift
var messages = [forwardHandoffSuccessMessage(for: result)]
if result.skippedUnsupportedItemCount > 0 {
    messages.append("Skipped \(result.skippedUnsupportedItemCount) unavailable album tracks")
}
if let warning = result.warningMessage {
    manager.errorMessage = warning
    messages.append(warning)
}
$homeToastMessage.showToast(messages.joined(separator: ". "))
```

Add this helper below `transferAppleMusicToSonos()` and above `handoffPlayback()`:

```swift
private func forwardHandoffSuccessMessage(for result: HandoffResult) -> String {
    if result.usedAlbumQueue {
        return "Transferred album to \(result.targetName)"
    }
    if result.warningMessage != nil {
        return "Transferred current song"
    }
    return "Transferred to \(result.targetName)"
}
```

- [ ] **Step 4: Build to catch call-site regressions**

Run:

```bash
xcodebuild build \
  -scheme SonosWidget \
  -destination 'generic/platform=iOS'
```

Expected: build succeeds.

- [ ] **Step 5: Commit result surface changes**

Run:

```bash
git add SonosWidget/SearchManager.swift SonosWidget/PlayerView.swift
git commit -m "feat: show album handoff results"
```

### Task 4: Preserve Matched Cloud Resource and Resolve Album Tracks

**Files:**
- Modify: `SonosWidget/SearchManager.swift`
- Test manually by building; network-dependent album browse is verified on device in Task 7.

- [ ] **Step 1: Add forward album helper types inside `SearchManager`**

Inside `final class SearchManager`, near the existing `RadioStationOption`, add:

```swift
private struct ForwardAlbumQueueAttempt {
    let plan: AppleMusicForwardAlbumQueuePlan
}

private struct ForwardCloudTrackCandidate {
    let resource: SonosCloudAPI.CloudResource
    let item: BrowseItem
}
```

- [ ] **Step 2: Preserve resources during Cloud search conversion**

In `transferAppleMusicTrack(_:manager:)`, replace:

```swift
let candidates = response.allResources.compactMap { resource -> BrowseItem? in
    guard resource.type == "TRACK" else { return nil }
    return convertToBrowseItem(resource, serviceId: serviceId, accountId: accountId)
}

guard !candidates.isEmpty else {
    throw HandoffTransferError.noConfidentMatch
}

guard let match = HandoffMatcher.bestMatch(for: track, candidates: candidates) else {
    throw HandoffTransferError.noConfidentMatch
}
```

with:

```swift
let cloudCandidates = response.allResources.compactMap { resource -> ForwardCloudTrackCandidate? in
    guard resource.type == "TRACK",
          let item = convertToBrowseItem(resource, serviceId: serviceId, accountId: accountId) else {
        return nil
    }
    return ForwardCloudTrackCandidate(resource: resource, item: item)
}
let candidates = cloudCandidates.map(\.item)

guard !candidates.isEmpty else {
    throw HandoffTransferError.noConfidentMatch
}

guard let match = HandoffMatcher.bestMatch(for: track, candidates: candidates),
      let matchedCloudCandidate = cloudCandidates.first(where: { $0.item == match.item }) else {
    throw HandoffTransferError.noConfidentMatch
}
```

- [ ] **Step 3: Add album id resolution helper**

Add these private helpers near the reverse handoff helpers in `SearchManager.swift`:

```swift
private func forwardAlbumId(
    from matchedResource: SonosCloudAPI.CloudResource,
    matchedItem: BrowseItem,
    token: String,
    householdId: String,
    serviceId: String,
    accountId: String
) async -> String? {
    if let containerId = browseAlbumId(from: matchedResource.container?.id?.objectId),
       !containerId.isEmpty {
        return containerId
    }

    let trackObjectId = SonosAppleMusicTrackResolver
        .cloudTrackObjectIDForNowPlaying(fromTrackURI: matchedItem.uri)
        ?? matchedResource.id?.objectId
        ?? matchedItem.id
    let cleanedTrackObjectId = browseTrackId(from: trackObjectId)
    guard !cleanedTrackObjectId.isEmpty else { return nil }

    do {
        let response = try await SonosCloudAPI.nowPlaying(
            token: token,
            householdId: householdId,
            serviceId: serviceId,
            accountId: accountId,
            trackObjectId: cleanedTrackObjectId)
        return browseAlbumId(from: response.item?.albumId)
    } catch {
        SonosLog.error(.nowPlaying, "Forward handoff album lookup failed: \(error)")
        return nil
    }
}

private func browseAlbumId(from rawId: String?) -> String? {
    guard let rawId else { return nil }
    let trimmed = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let base = trimmed.firstIndex(of: "#").map { String(trimmed[..<$0]) } ?? trimmed
    let parts = base.components(separatedBy: ":")
    guard let albumIndex = parts.firstIndex(where: { $0.caseInsensitiveCompare("album") == .orderedSame }),
          albumIndex < parts.index(before: parts.endIndex) else {
        return base
    }
    return parts[albumIndex...].joined(separator: ":")
}

private func browseTrackId(from rawId: String?) -> String {
    guard let rawId else { return "" }
    let trimmed = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let base = trimmed.firstIndex(of: "#").map { String(trimmed[..<$0]) } ?? trimmed
    let parts = base.components(separatedBy: ":")
    guard let trackIndex = parts.firstIndex(where: { $0.caseInsensitiveCompare("track") == .orderedSame }),
          trackIndex < parts.index(before: parts.endIndex) else {
        return base
    }
    return parts[trackIndex...].joined(separator: ":")
}
```

- [ ] **Step 4: Add album track conversion helper**

Add this private helper near `convertToBrowseItem`:

```swift
private func forwardAlbumCandidate(
    from albumTrack: SonosCloudAPI.AlbumTrackItem,
    fallbackAlbumTitle: String,
    fallbackArtURL: String?,
    serviceId: String,
    accountId: String
) -> AppleMusicForwardAlbumTrackCandidate? {
    if let type = albumTrack.type?.uppercased(), type != "TRACK" {
        return nil
    }
    let objectId = albumTrack.resource?.id?.objectId ?? albumTrack.id ?? ""
    let cleanedObjectId = browseTrackId(from: objectId)
    guard !cleanedObjectId.isEmpty,
          let title = albumTrack.title?.trimmingCharacters(in: .whitespacesAndNewlines),
          !title.isEmpty else {
        return nil
    }

    let cloudServiceId = albumTrack.resource?.id?.serviceId ?? serviceId
    let cloudAccountId = albumTrack.resource?.id?.accountId ?? accountId
    let artist = albumTrack.artists?.first?.name ?? albumTrack.subtitle ?? ""
    let artURL = albumTrack.images?.tile1x1 ?? fallbackArtURL
    let mimeType = albumTrack.resource?.defaults.flatMap { decodeMimeType(from: $0) }
    let duration = albumTrack.duration.flatMap(TimeInterval.init) ?? 0

    var item = makeTrackItem(
        objectId: cleanedObjectId,
        title: title,
        artist: artist,
        album: fallbackAlbumTitle,
        artURL: artURL,
        mimeType: mimeType,
        cloudServiceId: cloudServiceId,
        accountId: cloudAccountId)
    item.duration = duration

    return AppleMusicForwardAlbumTrackCandidate(
        item: item,
        ordinal: albumTrack.ordinal)
}
```

- [ ] **Step 5: Build to verify helper types compile**

Run:

```bash
xcodebuild build \
  -scheme SonosWidget \
  -destination 'generic/platform=iOS'
```

Expected: build succeeds.

- [ ] **Step 6: Commit Cloud resource and album conversion helpers**

Run:

```bash
git add SonosWidget/SearchManager.swift
git commit -m "feat: resolve Apple Music album handoff context"
```

### Task 5: Add LAN Album Queue Playback Path

**Files:**
- Modify: `SonosWidget/SearchManager.swift`

- [ ] **Step 1: Add album attempt orchestration helper**

Add this private helper in `SearchManager.swift` near `transferAppleMusicTrack(_:manager:)`:

```swift
private func forwardAlbumQueueAttempt(
    sourceTrack: AppleMusicHandoffTrack,
    matchedCandidate: ForwardCloudTrackCandidate,
    token: String,
    householdId: String,
    serviceId: String,
    accountId: String,
    manager: SonosManager
) async -> ForwardAlbumQueueAttempt? {
    guard manager.transportBackend != .cloud else { return nil }

    guard let albumId = await forwardAlbumId(
        from: matchedCandidate.resource,
        matchedItem: matchedCandidate.item,
        token: token,
        householdId: householdId,
        serviceId: serviceId,
        accountId: accountId) else {
        return nil
    }

    do {
        let response = try await SonosCloudAPI.browseAlbum(
            token: token,
            householdId: householdId,
            serviceId: serviceId,
            accountId: accountId,
            albumId: albumId,
            count: AppleMusicForwardAlbumQueuePlanner.defaultMaxItems)
        let albumTitle = response.title ?? matchedCandidate.item.album
        let fallbackArtURL = response.images?.tile1x1
            ?? matchedCandidate.item.albumArtURL
            ?? matchedCandidate.resource.container?.images?.first?.url
            ?? matchedCandidate.resource.images?.first?.url
        let albumTracks = response.tracks?.items ?? response.section?.items ?? []
        let candidates = albumTracks.compactMap {
            forwardAlbumCandidate(
                from: $0,
                fallbackAlbumTitle: albumTitle,
                fallbackArtURL: fallbackArtURL,
                serviceId: serviceId,
                accountId: accountId)
        }

        guard let plan = AppleMusicForwardAlbumQueuePlanner.makePlan(
            albumTracks: candidates,
            matchedItem: matchedCandidate.item,
            sourceTrack: sourceTrack) else {
            return nil
        }

        return ForwardAlbumQueueAttempt(plan: plan)
    } catch {
        SonosLog.error(.cloudAPI, "Forward handoff album browse failed: \(error)")
        return nil
    }
}
```

- [ ] **Step 2: Add LAN queue playback helper**

Add this private helper below `forwardAlbumQueueAttempt`:

```swift
private func playForwardAlbumQueue(
    _ plan: AppleMusicForwardAlbumQueuePlan,
    sourceTrack: AppleMusicHandoffTrack,
    selectedSpeaker: SonosPlayer,
    manager: SonosManager
) async -> (played: Bool, seeked: Bool) {
    guard manager.transportBackend != .cloud else { return (false, false) }

    do {
        try await SonosAPI.removeAllTracksFromQueue(ip: selectedSpeaker.playbackIP)

        for item in plan.items {
            guard let uri = item.uri, !uri.isEmpty else { continue }
            _ = try await SonosAPI.addURIToQueue(
                ip: selectedSpeaker.playbackIP,
                uri: uri,
                metadata: playbackMetadata(for: item))
        }

        try await SonosAPI.setAVTransportToQueue(
            ip: selectedSpeaker.playbackIP,
            speakerUUID: selectedSpeaker.id)
        try await SonosAPI.seekToTrack(
            ip: selectedSpeaker.playbackIP,
            trackNumber: plan.targetTrackNumber)
        try await SonosAPI.play(ip: selectedSpeaker.playbackIP)

        var didSeek = false
        if sourceTrack.position > 3 {
            let maxPosition = sourceTrack.duration.map {
                max(0, min(sourceTrack.position, $0 - 2))
            } ?? sourceTrack.position
            try? await SonosAPI.seek(
                ip: selectedSpeaker.playbackIP,
                position: SonosTime.apiFormat(maxPosition))
            didSeek = true
        }

        try? await Task.sleep(for: .milliseconds(playbackSettleDelayMs))
        await manager.refreshState()
        await manager.loadQueue()
        return (true, didSeek)
    } catch {
        SonosLog.error(.playback, "Forward album queue handoff failed: \(error)")
        errorMessage = error.localizedDescription
        return (false, false)
    }
}
```

- [ ] **Step 3: Wire album queue attempt into `transferAppleMusicTrack`**

In `transferAppleMusicTrack(_:manager:)`, after:

```swift
let previousError = errorMessage
errorMessage = nil
let transferBackend = manager.transportBackend
let transferCloudGroupId = manager.currentCloudGroupId
```

insert:

```swift
if let albumAttempt = await forwardAlbumQueueAttempt(
    sourceTrack: track,
    matchedCandidate: matchedCloudCandidate,
    token: token,
    householdId: householdId,
    serviceId: serviceId,
    accountId: accountId,
    manager: manager) {
    let albumPlayback = await playForwardAlbumQueue(
        albumAttempt.plan,
        sourceTrack: track,
        selectedSpeaker: selectedSpeaker,
        manager: manager)
    if albumPlayback.played {
        return HandoffResult(
            matchedTitle: match.item.title,
            targetName: selectedSpeaker.name,
            seeked: albumPlayback.seeked,
            transferredTrackCount: albumAttempt.plan.transferredTrackCount,
            skippedUnsupportedItemCount: albumAttempt.plan.skippedUnsupportedItemCount,
            warningMessage: nil)
    }
}
```

Leave the existing `playNowInternal(item:match.item...)` block immediately after this insertion so it remains the fallback.

- [ ] **Step 4: Add Cloud/remote warning to single-track fallback**

In the existing single-track return at the end of `transferAppleMusicTrack`, set `warningMessage` based on the backend captured before fallback playback:

```swift
let warningMessage = transferBackend == .cloud
    ? "Queue sync requires the same network"
    : nil

return HandoffResult(
    matchedTitle: match.item.title,
    targetName: selectedSpeaker.name,
    seeked: didSeek,
    transferredTrackCount: 1,
    skippedUnsupportedItemCount: 0,
    warningMessage: warningMessage)
```

- [ ] **Step 5: Build and run planner tests**

Run:

```bash
xcodebuild test \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SonosWidgetTests/AppleMusicForwardAlbumQueuePlannerTests
```

Expected: build succeeds and planner tests pass.

- [ ] **Step 6: Commit LAN album queue playback**

Run:

```bash
git add SonosWidget/SearchManager.swift
git commit -m "feat: hand off Apple Music albums to Sonos queue"
```

### Task 6: Document Forward Album Queue Handoff

**Files:**
- Modify: `docs/implementation-notes/apple-music-handoff.md`

- [ ] **Step 1: Add implementation note**

Open `docs/implementation-notes/apple-music-handoff.md` and add this section:

```markdown
## Forward HANDOFF: Apple Music iPhone -> Sonos

Forward HANDOFF still starts from the currently playing Apple Music item on the
iPhone. The app uses Sonos Cloud search to match that current item against the
linked Apple Music account, then attempts a best-effort album context upgrade:

1. Resolve the matched Sonos Cloud track's album/container id.
2. Browse the album through Sonos Cloud.
3. Convert playable album tracks into Sonos `BrowseItem` values.
4. Replace the selected Sonos target's LAN queue with the whole album.
5. Seek the Sonos queue to the matched album track.
6. Seek by time near the iPhone playback position.

The real Apple Music Up Next queue is not used because public iOS APIs do not
expose enumerable entries from the system Music app queue. This feature syncs
album context only. Playlists, stations, radio, and manually edited Up Next
continue to transfer as the current song.

Sonos queue mutation is LAN-only in this app. If the selected target is in
Cloud/remote mode, forward HANDOFF falls back to current-song transfer and
shows `Queue sync requires the same network`.
```

- [ ] **Step 2: Commit docs**

Run:

```bash
git add docs/implementation-notes/apple-music-handoff.md
git commit -m "docs: describe Apple Music album handoff"
```

### Task 7: Verify Build, Unit Tests, and Physical Device Flow

**Files:**
- No source edits unless verification exposes a bug.

- [ ] **Step 1: Run focused planner tests**

Run:

```bash
xcodebuild test \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SonosWidgetTests/AppleMusicForwardAlbumQueuePlannerTests
```

Expected: tests pass.

- [ ] **Step 2: Run the full test suite**

Run:

```bash
xcodebuild test \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: tests pass. If the simulator name is unavailable, run `xcrun simctl list devices available | rg "iPhone"` and rerun with an available iPhone simulator.

- [ ] **Step 3: Build for iOS**

Run:

```bash
xcodebuild build \
  -scheme SonosWidget \
  -destination 'generic/platform=iOS'
```

Expected: build succeeds.

- [ ] **Step 4: Deploy to the connected iPhone**

Use the local `ios-device-deploy` skill. The expected deployed behavior is:

- App installs and launches on the connected iPhone.
- Starting a song in the middle of an Apple Music album, then tapping `HANDOFF` on a LAN-selected idle Sonos speaker, loads the whole album queue.
- Sonos starts on the same album track.
- Sonos seeks near the captured iPhone playback position.
- The iPhone pauses after Sonos starts.
- Previous and next on Sonos move within the album queue.

- [ ] **Step 5: Verify fallback cases on device**

Manual checks:

- In remote/cloud mode, tap `HANDOFF` while Apple Music is playing.
  - Expected toast: `Transferred current song. Queue sync requires the same network`
  - Expected behavior: the single current song starts on Sonos.
- Play an Apple Music station or a non-album item, then tap `HANDOFF`.
  - Expected behavior: current-song handoff succeeds, no album queue is required.
- Pick a target whose album has an unavailable track.
  - Expected behavior: playable tracks are queued, skipped count appears in the toast, and target track numbering still lands on the current track when the current track is playable.

- [ ] **Step 6: Commit verification fixes only if needed**

If verification required a source fix, run focused tests again, then:

```bash
git add SonosWidget SonosWidgetTests docs/implementation-notes/apple-music-handoff.md
git commit -m "fix: stabilize Apple Music album handoff"
```

If no fix was required, do not create an empty commit.

## Final Verification Commands

Run these before merging:

```bash
xcodebuild test \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SonosWidgetTests/AppleMusicForwardAlbumQueuePlannerTests

xcodebuild test \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17'

xcodebuild build \
  -scheme SonosWidget \
  -destination 'generic/platform=iOS'
```

## Expected User-Visible Behavior

- Idle selected Sonos target + iPhone Apple Music album track: `HANDOFF` queues the album on Sonos, jumps to the current song, seeks near the iPhone position, and pauses the iPhone.
- Selected Sonos target already playing: existing reverse HANDOFF continues moving Sonos Apple Music playback to iPhone.
- Remote/cloud mode: forward HANDOFF transfers the current song only and explains that queue sync requires the same network.
- Unresolvable album context: forward HANDOFF transfers the current song only with no scary album-sync error.
