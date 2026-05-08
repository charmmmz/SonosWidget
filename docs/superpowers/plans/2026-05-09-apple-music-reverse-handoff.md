# Apple Music Reverse Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a bidirectional Home `TRANSFER` control that can move the currently playing Apple Music track from Sonos back to the iPhone, then pause the selected Sonos target after iPhone playback starts.

**Architecture:** Keep the existing iPhone-to-Sonos handoff path and add the reverse path beside it. Reverse handoff resolves the current Sonos track to an Apple Music playback store ID by parsing the Sonos URI first, then using Sonos Cloud nowPlaying/search fallback, then starts `MPMusicPlayerController.systemMusicPlayer` and pauses the locked Sonos backend only after phone playback is confirmed.

**Tech Stack:** Swift, SwiftUI, MediaPlayer, Sonos LAN UPnP API, Sonos Cloud Control/Content APIs, XCTest, existing `HandoffMatcher`.

---

## File Structure

- Create `Shared/SonosAppleMusicTrackResolver.swift`
  - Pure parsing helpers for Sonos Apple Music track URIs and `BrowseItem` search results.
  - No network calls and no UI. Unit-testable.
- Create `SonosWidgetTests/SonosAppleMusicTrackResolverTests.swift`
  - XCTest coverage for store ID extraction, Sonos object ID extraction, local sid/account parsing, and search-result fallback input.
- Modify `Shared/AppleMusicHandoff.swift`
  - Add phone playback entry point for a resolved Apple Music store ID.
  - Keep current phone-now-playing capture and phone pause behavior unchanged for forward transfer.
- Modify `SonosWidget/SearchManager.swift`
  - Add reverse handoff result/error types.
  - Add Sonos-current-track capture, Apple Music source gate, store-ID resolution, search fallback, and locked-backend Sonos pause.
- Modify `SonosWidget/PlayerView.swift`
  - Change the Home `TRANSFER` control from a single direct button to a compact direction picker with `iPhone -> Sonos` and `Sonos -> iPhone`.
  - Keep it above `UNGROUP`, not per speaker card.

---

### Task 1: Add Apple Music Track URI Resolver

**Files:**
- Create: `Shared/SonosAppleMusicTrackResolver.swift`
- Test: `SonosWidgetTests/SonosAppleMusicTrackResolverTests.swift`

- [ ] **Step 1: Write the failing resolver tests**

Create `SonosWidgetTests/SonosAppleMusicTrackResolverTests.swift` with this complete content:

```swift
import XCTest
@testable import SonosWidget

final class SonosAppleMusicTrackResolverTests: XCTestCase {
    func testParsesStoreIDFromTrackURIWithSonosAppleMusicPrefixAndExtension() {
        let uri = "x-sonos-http:100320201234567890.mp4?sid=204&flags=8224&sn=2"

        let parsed = SonosAppleMusicTrackResolver.parseTrackURI(uri)

        XCTAssertEqual(parsed.storeID, "1234567890")
        XCTAssertEqual(parsed.sonosTrackObjectID, "100320201234567890")
        XCTAssertEqual(parsed.localServiceID, 204)
        XCTAssertEqual(parsed.accountID, "2")
    }

    func testKeepsPureNumericStoreIDWithoutDroppingDigits() {
        let uri = "x-sonos-http:123456789012345.mp4?sid=204&flags=8224&sn=2"

        let parsed = SonosAppleMusicTrackResolver.parseTrackURI(uri)

        XCTAssertEqual(parsed.storeID, "123456789012345")
        XCTAssertEqual(parsed.sonosTrackObjectID, "123456789012345")
    }

    func testDecodesPercentEscapedObjectIDButRejectsNonNumericPlaybackID() {
        let uri = "x-sonos-http:track%3Aabc123.unknown?sid=204&sn=2"

        let parsed = SonosAppleMusicTrackResolver.parseTrackURI(uri)

        XCTAssertNil(parsed.storeID)
        XCTAssertEqual(parsed.sonosTrackObjectID, "track:abc123")
        XCTAssertEqual(parsed.localServiceID, 204)
        XCTAssertEqual(parsed.accountID, "2")
    }

    func testStoreIDFromBrowseItemPrefersItemID() {
        let item = BrowseItem(
            id: "100320209876543210",
            title: "Dark Dune",
            artist: "Demuja",
            album: "Dark Dune",
            uri: "x-sonos-http:100320201234567890.mp4?sid=204&sn=2",
            duration: 241,
            isContainer: false,
            serviceId: 204,
            cloudType: "TRACK")

        let storeID = SonosAppleMusicTrackResolver.storeID(fromBrowseItem: item)

        XCTAssertEqual(storeID, "9876543210")
    }

    func testStoreIDFromBrowseItemFallsBackToURI() {
        let item = BrowseItem(
            id: "track:abc123",
            title: "Dark Dune",
            artist: "Demuja",
            album: "Dark Dune",
            uri: "x-sonos-http:100320201234567890.mp4?sid=204&sn=2",
            duration: 241,
            isContainer: false,
            serviceId: 204,
            cloudType: "TRACK")

        let storeID = SonosAppleMusicTrackResolver.storeID(fromBrowseItem: item)

        XCTAssertEqual(storeID, "1234567890")
    }

    func testEmptyURIProducesEmptyParsedValues() {
        let parsed = SonosAppleMusicTrackResolver.parseTrackURI("   ")

        XCTAssertNil(parsed.storeID)
        XCTAssertNil(parsed.sonosTrackObjectID)
        XCTAssertNil(parsed.localServiceID)
        XCTAssertNil(parsed.accountID)
    }
}
```

- [ ] **Step 2: Run the resolver test to verify it fails**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/SonosAppleMusicTrackResolverTests
```

Expected: the build fails with `Cannot find 'SonosAppleMusicTrackResolver' in scope`.

- [ ] **Step 3: Add the resolver implementation**

Create `Shared/SonosAppleMusicTrackResolver.swift` with this complete content:

```swift
import Foundation

enum SonosAppleMusicTrackResolver {
    struct ParsedTrackURI: Equatable {
        let storeID: String?
        let sonosTrackObjectID: String?
        let localServiceID: Int?
        let accountID: String?
    }

    private static let appleMusicTrackObjectPrefixes: [String] = [
        "10032020",
        "10032064",
        "1003206c"
    ]

    private static let mediaExtensions: Set<String> = [
        ".mp4",
        ".mp3",
        ".flac",
        ".unknown",
        ".m4a",
        ".ogg"
    ]

    static func parseTrackURI(_ uri: String?) -> ParsedTrackURI {
        guard let trimmedURI = sanitized(uri), !trimmedURI.isEmpty else {
            return ParsedTrackURI(
                storeID: nil,
                sonosTrackObjectID: nil,
                localServiceID: nil,
                accountID: nil)
        }

        let objectID = trackObjectID(from: trimmedURI)
        let params = queryParameters(from: trimmedURI)
        return ParsedTrackURI(
            storeID: storeID(fromObjectID: objectID),
            sonosTrackObjectID: objectID,
            localServiceID: params["sid"].flatMap(Int.init),
            accountID: sanitized(params["sn"]))
    }

    static func storeID(fromTrackURI uri: String?) -> String? {
        parseTrackURI(uri).storeID
    }

    static func trackObjectIDForNowPlaying(fromTrackURI uri: String?) -> String? {
        parseTrackURI(uri).sonosTrackObjectID
    }

    static func storeID(fromBrowseItem item: BrowseItem) -> String? {
        storeID(fromObjectID: item.id) ?? storeID(fromTrackURI: item.uri)
    }

    static func storeID(fromObjectID rawObjectID: String?) -> String? {
        guard var objectID = normalizedObjectID(rawObjectID) else { return nil }
        for prefix in appleMusicTrackObjectPrefixes where objectID.hasPrefix(prefix) {
            objectID = String(objectID.dropFirst(prefix.count))
            break
        }

        guard !objectID.isEmpty,
              objectID.allSatisfy({ $0.isNumber }) else {
            return nil
        }
        return objectID
    }

    private static func trackObjectID(from uri: String) -> String? {
        let pathPart = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        let rawObjectID: String
        if let colonRange = pathPart.range(of: ":", options: .backwards) {
            rawObjectID = String(pathPart[colonRange.upperBound...])
        } else {
            rawObjectID = pathPart
        }
        return normalizedObjectID(rawObjectID)
    }

    private static func normalizedObjectID(_ value: String?) -> String? {
        guard var objectID = sanitized(value), !objectID.isEmpty else { return nil }
        objectID = objectID.removingPercentEncoding ?? objectID

        if let dotIndex = objectID.lastIndex(of: "."),
           dotIndex > objectID.startIndex {
            let ext = String(objectID[dotIndex...]).lowercased()
            if mediaExtensions.contains(ext) {
                objectID = String(objectID[..<dotIndex])
            }
        }

        return objectID.isEmpty ? nil : objectID
    }

    private static func queryParameters(from uri: String) -> [String: String] {
        guard let questionMark = uri.firstIndex(of: "?") else { return [:] }
        let query = uri[uri.index(after: questionMark)...]
        var params: [String: String] = [:]
        for part in query.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0])
            let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            params[key] = value
        }
        return params
    }

    private static func sanitized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
```

- [ ] **Step 4: Run the resolver tests to verify they pass**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/SonosAppleMusicTrackResolverTests
```

Expected: `SonosAppleMusicTrackResolverTests` passes.

- [ ] **Step 5: Commit the resolver**

Run:

```bash
git add Shared/SonosAppleMusicTrackResolver.swift SonosWidgetTests/SonosAppleMusicTrackResolverTests.swift
git commit -m "Add Apple Music reverse handoff resolver"
```

Expected: commit succeeds with the two new files.

---

### Task 2: Add iPhone Playback Entry Point

**Files:**
- Modify: `Shared/AppleMusicHandoff.swift`

- [ ] **Step 1: Extend `AppleMusicHandoffError`**

In `Shared/AppleMusicHandoff.swift`, replace the existing `AppleMusicHandoffError` with this complete enum:

```swift
enum AppleMusicHandoffError: LocalizedError, Equatable {
    case mediaAccessDenied
    case notPlayingAppleMusic
    case missingTrackMetadata
    case missingPlaybackStoreID
    case phonePlaybackFailed

    var errorDescription: String? {
        switch self {
        case .mediaAccessDenied:
            return "Apple Music access is not allowed."
        case .notPlayingAppleMusic:
            return "Nothing is currently playing in Apple Music."
        case .missingTrackMetadata:
            return "The current Apple Music track could not be identified."
        case .missingPlaybackStoreID:
            return "The Apple Music track could not be opened on this iPhone."
        case .phonePlaybackFailed:
            return "Apple Music did not start playback on this iPhone."
        }
    }
}
```

- [ ] **Step 2: Add phone playback helpers**

Inside `final class AppleMusicHandoffManager`, add this method immediately before `func pausePhonePlayback()`:

```swift
    func playAppleMusicTrack(storeID: String, position: TimeInterval?) async throws {
        let status = await mediaLibraryAuthorizationStatus()
        guard status == .authorized else {
            throw AppleMusicHandoffError.mediaAccessDenied
        }

        let trimmedStoreID = storeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedStoreID.isEmpty else {
            throw AppleMusicHandoffError.missingPlaybackStoreID
        }

        player.setQueue(with: [trimmedStoreID])
        try await prepareToPlay()
        player.play()

        if let position, position > 3 {
            player.currentPlaybackTime = max(0, position)
        }

        try? await Task.sleep(for: .milliseconds(700))
        guard player.playbackState == .playing || player.nowPlayingItem != nil else {
            throw AppleMusicHandoffError.phonePlaybackFailed
        }
    }
```

Then add this private helper below `pausePhonePlayback()`:

```swift
    private func prepareToPlay() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            player.prepareToPlay { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
```

- [ ] **Step 3: Build to verify MediaPlayer calls compile**

Run:

```bash
xcodebuild build -scheme SonosWidget -destination 'generic/platform=iOS'
```

Expected: build succeeds. If the selected Xcode SDK exposes `prepareToPlay()` without the completion-handler overload, replace the helper body with this exact implementation and rerun the build:

```swift
    private func prepareToPlay() async throws {
        player.prepareToPlay()
    }
```

- [ ] **Step 4: Commit the iPhone playback entry point**

Run:

```bash
git add Shared/AppleMusicHandoff.swift
git commit -m "Add iPhone Apple Music playback handoff"
```

Expected: commit succeeds with only `Shared/AppleMusicHandoff.swift` staged.

---

### Task 3: Add Reverse Handoff Orchestration

**Files:**
- Modify: `SonosWidget/SearchManager.swift`

- [ ] **Step 1: Add reverse result and error types**

In `SonosWidget/SearchManager.swift`, immediately after `enum HandoffTransferError`, add:

```swift
struct ReverseHandoffResult: Equatable {
    let matchedTitle: String
    let targetName: String
    let seeked: Bool
    let sonosPaused: Bool
    let warningMessage: String?
}

enum ReverseHandoffError: LocalizedError, Equatable {
    case noSelectedSpeaker
    case noBackend
    case notAppleMusicSource
    case missingSonosTrackMetadata
    case sonosCloudDisconnected
    case appleMusicNotLinkedOnSonos
    case noConfidentMatch

    var errorDescription: String? {
        switch self {
        case .noSelectedSpeaker:
            return "Select a Sonos speaker before transferring to iPhone."
        case .noBackend:
            return "Speaker unreachable — pull to refresh."
        case .notAppleMusicSource:
            return "Only Apple Music can be transferred to iPhone."
        case .missingSonosTrackMetadata:
            return "The current Sonos track could not be identified."
        case .sonosCloudDisconnected:
            return "Sign in to Sonos Cloud before transferring to iPhone."
        case .appleMusicNotLinkedOnSonos:
            return "Apple Music is not linked to this Sonos household."
        case .noConfidentMatch:
            return "Apple Music could not confidently match the Sonos track."
        }
    }
}
```

- [ ] **Step 2: Add the public reverse transfer method**

In `SearchManager`, add this method immediately after `transferAppleMusicTrack(_:manager:)`:

```swift
    func transferSonosAppleMusicToPhone(
        manager: SonosManager
    ) async throws -> ReverseHandoffResult {
        guard let selectedSpeaker = manager.selectedSpeaker else {
            throw ReverseHandoffError.noSelectedSpeaker
        }
        configure(speakerIP: selectedSpeaker.playbackIP)

        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else {
            throw ReverseHandoffError.sonosCloudDisconnected
        }

        guard let backend = await manager.controlBackendEnsured() else {
            throw ReverseHandoffError.noBackend
        }

        if !hasProbed {
            await probeLinkedServices()
        }
        await refreshServiceIdMappingIfNeeded()
        await manager.refreshState()

        guard let trackInfo = manager.trackInfo else {
            throw ReverseHandoffError.missingSonosTrackMetadata
        }

        guard isAppleMusicTrack(trackInfo) else {
            throw ReverseHandoffError.notAppleMusicSource
        }

        let track = try reverseSourceTrack(from: trackInfo)
        let storeID = try await resolveAppleMusicStoreID(
            for: track,
            trackInfo: trackInfo,
            token: token,
            householdId: householdId)

        try await AppleMusicHandoffManager.shared.playAppleMusicTrack(
            storeID: storeID,
            position: track.position)

        var paused = true
        var warning: String?
        do {
            try await SonosControl.pause(backend)
        } catch {
            paused = false
            warning = "Playing on iPhone. Couldn’t pause Sonos."
            SonosLog.error(.playback, "Reverse handoff Sonos pause failed: \(error)")
        }

        await manager.refreshState()
        return ReverseHandoffResult(
            matchedTitle: track.title,
            targetName: selectedSpeaker.name,
            seeked: track.position > 3,
            sonosPaused: paused,
            warningMessage: warning)
    }
```

- [ ] **Step 3: Add reverse source and ID resolution helpers**

In `SearchManager`, add these private helpers immediately after `isAppleMusicAccount(_:)`:

```swift
    private func reverseSourceTrack(from trackInfo: TrackInfo) throws -> AppleMusicHandoffTrack {
        let title = trackInfo.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = trackInfo.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else {
            throw ReverseHandoffError.missingSonosTrackMetadata
        }

        let album = trackInfo.album.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppleMusicHandoffTrack(
            title: title,
            artist: artist,
            album: album.isEmpty ? nil : album,
            duration: trackInfo.durationSeconds > 0 ? trackInfo.durationSeconds : nil,
            position: max(0, trackInfo.positionSeconds),
            playbackStoreID: SonosAppleMusicTrackResolver.storeID(fromTrackURI: trackInfo.trackURI),
            persistentID: nil)
    }

    private func isAppleMusicTrack(_ trackInfo: TrackInfo) -> Bool {
        if trackInfo.source == .appleMusic {
            return true
        }

        guard let trackURI = trackInfo.trackURI else { return false }
        let parsed = SonosAppleMusicTrackResolver.parseTrackURI(trackURI)
        guard let localServiceID = parsed.localServiceID,
              let cloudServiceID = cloudServiceId(forLocalSid: localServiceID),
              let account = linkedAccounts.first(where: { $0.serviceId == cloudServiceID }) else {
            return false
        }
        return isAppleMusicAccount(account)
    }

    private func resolveAppleMusicStoreID(
        for track: AppleMusicHandoffTrack,
        trackInfo: TrackInfo,
        token: String,
        householdId: String
    ) async throws -> String {
        if let storeID = track.playbackStoreID {
            return storeID
        }

        if let nowPlayingStoreID = try await nowPlayingStoreID(
            trackInfo: trackInfo,
            token: token,
            householdId: householdId) {
            return nowPlayingStoreID
        }

        return try await searchMatchedStoreID(
            for: track,
            token: token,
            householdId: householdId)
    }

    private func nowPlayingStoreID(
        trackInfo: TrackInfo,
        token: String,
        householdId: String
    ) async throws -> String? {
        guard let trackURI = trackInfo.trackURI else { return nil }
        let parsed = SonosAppleMusicTrackResolver.parseTrackURI(trackURI)
        guard let localServiceID = parsed.localServiceID,
              let serviceId = cloudServiceId(forLocalSid: localServiceID),
              let accountId = parsed.accountID,
              let trackObjectID = SonosAppleMusicTrackResolver
                .trackObjectIDForNowPlaying(fromTrackURI: trackURI) else {
            return nil
        }

        do {
            let response = try await SonosCloudAPI.nowPlaying(
                token: token,
                householdId: householdId,
                serviceId: serviceId,
                accountId: accountId,
                trackObjectId: trackObjectID)
            let objectID = response.item?.resource?.id?.objectId ?? response.item?.id
            return SonosAppleMusicTrackResolver.storeID(fromObjectID: objectID)
        } catch {
            SonosLog.error(.nowPlaying, "Reverse handoff nowPlaying lookup failed: \(error)")
            return nil
        }
    }

    private func searchMatchedStoreID(
        for track: AppleMusicHandoffTrack,
        token: String,
        householdId: String
    ) async throws -> String {
        guard let appleMusicAccount = linkedAccounts.first(where: { isAppleMusicAccount($0) }),
              let serviceId = appleMusicAccount.serviceId,
              let accountId = appleMusicAccount.accountId else {
            throw ReverseHandoffError.appleMusicNotLinkedOnSonos
        }

        let term = "\(track.title) \(track.artist)"
        let response = try await searchServiceWithTokenRefresh(
            token: token,
            householdId: householdId,
            serviceId: serviceId,
            accountId: accountId,
            term: term)

        let candidates = response.allResources.compactMap { resource -> BrowseItem? in
            guard resource.type == "TRACK" else { return nil }
            return convertToBrowseItem(resource, serviceId: serviceId, accountId: accountId)
        }

        guard let match = HandoffMatcher.bestMatch(for: track, candidates: candidates),
              let storeID = SonosAppleMusicTrackResolver.storeID(fromBrowseItem: match.item) else {
            throw ReverseHandoffError.noConfidentMatch
        }
        return storeID
    }
```

- [ ] **Step 4: Build to verify orchestration compiles**

Run:

```bash
xcodebuild build -scheme SonosWidget -destination 'generic/platform=iOS'
```

Expected: build succeeds.

- [ ] **Step 5: Commit the reverse orchestration**

Run:

```bash
git add SonosWidget/SearchManager.swift
git commit -m "Add Sonos to iPhone Apple Music transfer orchestration"
```

Expected: commit succeeds with only `SonosWidget/SearchManager.swift` staged.

---

### Task 4: Add Bidirectional Home Transfer Picker

**Files:**
- Modify: `SonosWidget/PlayerView.swift`

- [ ] **Step 1: Rename transfer loading state**

In `SonosWidget/PlayerView.swift`, replace:

```swift
    @State private var isTransferringAppleMusic = false
```

with:

```swift
    @State private var isTransferringPlayback = false
```

Then replace every `isTransferringAppleMusic` reference in the file with `isTransferringPlayback`.

- [ ] **Step 2: Replace the transfer button with a direction menu**

Replace the entire `private var transferZone: some View` with:

```swift
    private var transferZone: some View {
        Menu {
            Button {
                transferAppleMusicToSonos()
            } label: {
                Label("iPhone -> Sonos", systemImage: "iphone.and.arrow.forward")
            }

            Button {
                transferSonosToIPhone()
            } label: {
                Label("Sonos -> iPhone", systemImage: "speaker.wave.2.fill")
            }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(isTransferringPlayback ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                    Circle()
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1.5)
                    if isTransferringPlayback {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .frame(width: 52, height: 52)

                Text("TRANSFER")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .buttonStyle(.plain)
        .disabled(isTransferringPlayback || !manager.isConfigured)
        .accessibilityLabel("Transfer playback")
    }
```

- [ ] **Step 3: Update forward transfer to use the generic state**

Replace `transferAppleMusicToSonos()` with:

```swift
    private func transferAppleMusicToSonos() {
        guard !isTransferringPlayback else { return }
        isTransferringPlayback = true

        Task {
            do {
                let track = try await AppleMusicHandoffManager.shared.currentAppleMusicTrack()
                let result = try await searchManager.transferAppleMusicTrack(track, manager: manager)
                AppleMusicHandoffManager.shared.pausePhonePlayback()
                $homeToastMessage.showToast("Transferred to \(result.targetName)")
            } catch {
                manager.errorMessage = error.localizedDescription
                $homeToastMessage.showToast(error.localizedDescription)
            }
            isTransferringPlayback = false
        }
    }
```

- [ ] **Step 4: Add reverse transfer UI handler**

Add this method immediately after `transferAppleMusicToSonos()`:

```swift
    private func transferSonosToIPhone() {
        guard !isTransferringPlayback else { return }
        isTransferringPlayback = true

        Task {
            do {
                let result = try await searchManager.transferSonosAppleMusicToPhone(manager: manager)
                if let warning = result.warningMessage {
                    manager.errorMessage = warning
                    $homeToastMessage.showToast(warning)
                } else {
                    $homeToastMessage.showToast("Transferred to iPhone")
                }
            } catch {
                manager.errorMessage = error.localizedDescription
                $homeToastMessage.showToast(error.localizedDescription)
            }
            isTransferringPlayback = false
        }
    }
```

- [ ] **Step 5: Build to verify SwiftUI compiles**

Run:

```bash
xcodebuild build -scheme SonosWidget -destination 'generic/platform=iOS'
```

Expected: build succeeds.

- [ ] **Step 6: Commit the Home UI**

Run:

```bash
git add SonosWidget/PlayerView.swift
git commit -m "Add bidirectional Apple Music transfer picker"
```

Expected: commit succeeds with only `SonosWidget/PlayerView.swift` staged.

---

### Task 5: Full Verification and Device Smoke Test

**Files:**
- Verify: full app build, XCTest, and connected iPhone deployment

- [ ] **Step 1: Run all handoff-related unit tests**

Run:

```bash
xcodebuild test -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SonosWidgetTests/HandoffMatcherTests -only-testing:SonosWidgetTests/SonosAppleMusicTrackResolverTests
```

Expected: both test classes pass.

- [ ] **Step 2: Run a full app build**

Run:

```bash
xcodebuild build -scheme SonosWidget -destination 'generic/platform=iOS'
```

Expected: build succeeds with no Swift compiler errors.

- [ ] **Step 3: Deploy to the connected iPhone**

Use the local deploy skill workflow:

```bash
/Users/charm/.codex/skills/ios-device-deploy/scripts/deploy_ios_device.sh
```

Expected: the app installs on the connected iPhone and opens automatically.

- [ ] **Step 4: Smoke-test iPhone to Sonos forward transfer**

On the iPhone:

1. Start an Apple Music track on the phone.
2. Open Home.
3. Tap `TRANSFER`.
4. Choose `iPhone -> Sonos`.

Expected:

- The selected Sonos speaker or group starts playing the same Apple Music track.
- Phone playback pauses after Sonos starts.
- Toast says `Transferred to <speaker name>`.

- [ ] **Step 5: Smoke-test Sonos to iPhone reverse transfer**

On the iPhone:

1. Start an Apple Music track on the selected Sonos speaker or group.
2. Open Home.
3. Tap `TRANSFER`.
4. Choose `Sonos -> iPhone`.

Expected:

- The iPhone Music app starts the same Apple Music track.
- Playback position is close to the Sonos position when the source position is greater than three seconds.
- The selected Sonos speaker or group pauses after iPhone playback starts.
- Toast says `Transferred to iPhone`.

- [ ] **Step 6: Smoke-test non-Apple-Music source gate**

On the iPhone:

1. Play TV, AirPlay, radio, or another non-Apple-Music source on Sonos.
2. Tap `TRANSFER`.
3. Choose `Sonos -> iPhone`.

Expected:

- iPhone playback does not start.
- Sonos playback is not paused.
- Toast says `Only Apple Music can be transferred to iPhone.`

- [ ] **Step 7: Commit verification notes only if code changed during verification**

Run:

```bash
git status --short
```

Expected when verification did not require source changes: no output.

Expected when verification required source changes: output lists only files under `Shared/`, `SonosWidget/`, or `SonosWidgetTests/`. Commit those directories with:

```bash
git add Shared SonosWidget SonosWidgetTests
git commit -m "Fix reverse Apple Music transfer verification issues"
```

Expected: commit succeeds when verification produced source changes; otherwise skip the `git add` and `git commit` commands.

---

## Self-Review

- Spec coverage:
  - Single Home `TRANSFER` entry remains above `UNGROUP`: Task 4.
  - Direction picker with `iPhone -> Sonos` and `Sonos -> iPhone`: Task 4.
  - Apple Music-only reverse gate: Task 3 and Task 5.
  - Store ID direct parse, nowPlaying lookup, and search fallback: Task 1 and Task 3.
  - iPhone playback with seek and post-start Sonos pause: Task 2 and Task 3.
  - Pause warning after iPhone starts: Task 3 and Task 4.
  - Unit tests for parsing behavior: Task 1 and Task 5.
  - Device deployment and smoke testing: Task 5.
- Placeholder scan:
  - The plan contains no unfinished markers and no unexpanded error-handling instructions.
  - Every code-changing step includes concrete Swift code or exact replacement instructions.
- Type consistency:
  - `ReverseHandoffResult`, `ReverseHandoffError`, `SonosAppleMusicTrackResolver`, and `AppleMusicHandoffManager.playAppleMusicTrack(storeID:position:)` are defined before use.
  - Existing project types are used with their current names: `SonosManager`, `TrackInfo`, `PlaybackSource.appleMusic`, `BrowseItem`, `HandoffMatcher`, `SonosControl.pause(_:)`, and `SonosCloudAPI.nowPlaying(...)`.
