# Apple Music Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Home-screen `TRANSFER` action that moves the currently playing Apple Music track from the iPhone to the currently selected Sonos speaker or group.

**Architecture:** Capture Apple Music state in a small MediaPlayer service, match the captured track against Sonos-linked Apple Music search results, then reuse the existing Sonos playback and seek paths. Keep iPhone capture, candidate matching, Sonos transfer orchestration, and Home UI as separate pieces so failures are readable and testable.

**Tech Stack:** SwiftUI, Observation, MediaPlayer, Sonos Cloud content search, existing `SearchManager`, `SonosManager`, `SonosControl`, and `ToastModifier`.

---

## File Structure

- Create `Shared/AppleMusicHandoff.swift`
  - Owns `AppleMusicHandoffTrack`, `AppleMusicHandoffError`, and `AppleMusicHandoffManager`.
  - Imports `MediaPlayer`.
  - Reads `MPMusicPlayerController.systemMusicPlayer` and pauses it after Sonos playback succeeds.
- Create `Shared/HandoffMatcher.swift`
  - Pure Swift matcher for comparing an iPhone Apple Music track against Sonos `BrowseItem` candidates.
  - No app, network, or MediaPlayer dependencies.
- Modify `Shared/Models.swift`
  - Add `BrowseItem.duration` as a seconds-based value with a default of `0` so matching can reject wrong-duration candidates without forcing every existing initializer to change.
- Create `SonosWidgetTests/HandoffMatcherTests.swift`
  - Unit tests for exact, punctuation, remaster, wrong-artist, and duration mismatch cases.
- Modify `SonosWidget.xcodeproj/project.pbxproj`
  - Add `AppleMusicHandoff.swift` and `HandoffMatcher.swift` to the `SonosWidget` app target compile sources.
  - Add `HandoffMatcher.swift` and `HandoffMatcherTests.swift` to the `SonosWidgetTests` target compile sources.
  - Add a `SonosWidgetTests` XCTest target if the project still has no test target.
- Modify `SonosWidget/Info.plist`
  - Add `NSAppleMusicUsageDescription`.
- Modify `SonosWidget/SearchManager.swift`
  - Add transfer orchestration and refactor playback to return success for the handoff path.
- Modify `SonosWidget/PlayerView.swift`
  - Add the Home `TRANSFER` control above `UNGROUP`, loading state, and toast/error presentation.

---

### Task 1: Add Apple Music Capture Service

**Files:**
- Create: `Shared/AppleMusicHandoff.swift`
- Modify: `SonosWidget/Info.plist`
- Modify: `SonosWidget.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add the MediaPlayer usage description**

Add this key near the other privacy strings in `SonosWidget/Info.plist`:

```xml
<key>NSAppleMusicUsageDescription</key>
<string>SonosWidget reads the Apple Music track currently playing on this iPhone so it can transfer playback to your selected Sonos speaker.</string>
```

- [ ] **Step 2: Create the handoff service file**

Create `Shared/AppleMusicHandoff.swift`:

```swift
import Foundation
import MediaPlayer

struct AppleMusicHandoffTrack: Equatable, Sendable {
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval?
    let position: TimeInterval
    let playbackStoreID: String?
    let persistentID: UInt64?
}

enum AppleMusicHandoffError: LocalizedError, Equatable {
    case mediaAccessDenied
    case notPlayingAppleMusic
    case missingTrackMetadata

    var errorDescription: String? {
        switch self {
        case .mediaAccessDenied:
            return "Apple Music access is not allowed."
        case .notPlayingAppleMusic:
            return "Nothing is currently playing in Apple Music."
        case .missingTrackMetadata:
            return "The current Apple Music track could not be identified."
        }
    }
}

@MainActor
final class AppleMusicHandoffManager {
    static let shared = AppleMusicHandoffManager()

    private let player = MPMusicPlayerController.systemMusicPlayer

    private init() {}

    func currentAppleMusicTrack() async throws -> AppleMusicHandoffTrack {
        let status = await mediaLibraryAuthorizationStatus()
        guard status == .authorized else {
            throw AppleMusicHandoffError.mediaAccessDenied
        }

        guard player.playbackState == .playing || player.playbackState == .paused else {
            throw AppleMusicHandoffError.notPlayingAppleMusic
        }
        guard let item = player.nowPlayingItem else {
            throw AppleMusicHandoffError.notPlayingAppleMusic
        }

        let title = trimmed(item.title)
        let artist = trimmed(item.artist)
        guard !title.isEmpty, !artist.isEmpty else {
            throw AppleMusicHandoffError.missingTrackMetadata
        }

        let duration = item.playbackDuration > 0 ? item.playbackDuration : nil
        return AppleMusicHandoffTrack(
            title: title,
            artist: artist,
            album: trimmed(item.albumTitle).isEmpty ? nil : trimmed(item.albumTitle),
            duration: duration,
            position: max(0, player.currentPlaybackTime),
            playbackStoreID: item.playbackStoreID.isEmpty ? nil : item.playbackStoreID,
            persistentID: item.persistentID == 0 ? nil : item.persistentID
        )
    }

    func pausePhonePlayback() {
        player.pause()
    }

    private func mediaLibraryAuthorizationStatus() async -> MPMediaLibraryAuthorizationStatus {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized:
            return .authorized
        case .notDetermined:
            return await MPMediaLibrary.requestAuthorization()
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .denied
        }
    }

    private func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
```

- [ ] **Step 3: Add the file to the Xcode project**

Add `Shared/AppleMusicHandoff.swift` to the app target's compile sources. If shared files are already included by explicit PBX entries, mirror the existing `Shared/SonosAuth.swift` or `Shared/SonosCloudAPI.swift` project references.

- [ ] **Step 4: Build to verify the new service compiles**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Shared/AppleMusicHandoff.swift SonosWidget/Info.plist SonosWidget.xcodeproj/project.pbxproj
git commit -m "Add Apple Music handoff capture"
```

---

### Task 2: Add Track Matching Logic and Tests

**Files:**
- Create: `Shared/HandoffMatcher.swift`
- Modify: `Shared/Models.swift`
- Create: `SonosWidgetTests/HandoffMatcherTests.swift`
- Modify: `SonosWidget.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add duration to BrowseItem**

In `Shared/Models.swift`, add a defaulted duration field to `BrowseItem`:

```swift
/// Track duration in seconds when known. Search-result based items use this
/// for Apple Music handoff matching; legacy/local browse items default to 0.
var duration: TimeInterval = 0
```

Place it after `metaXML` and before `resMD` so it stays close to playback
metadata. The default value keeps existing memberwise initializers source
compatible.

- [ ] **Step 2: Add matcher tests first**

Create `SonosWidgetTests/HandoffMatcherTests.swift`:

```swift
import XCTest
@testable import SonosWidget

final class HandoffMatcherTests: XCTestCase {
    func testExactTitleArtistAlbumAndDurationMatchWins() {
        let source = AppleMusicHandoffTrack(
            title: "Dark Dune",
            artist: "Demuja",
            album: "Dark Dune",
            duration: 241,
            position: 81,
            playbackStoreID: nil,
            persistentID: nil
        )
        let candidates = [
            makeItem(title: "Dark Dune", artist: "Demuja", album: "Dark Dune", duration: 240),
            makeItem(title: "Dark Dune", artist: "Someone Else", album: "Dark Dune", duration: 240)
        ]

        let match = HandoffMatcher.bestMatch(for: source, candidates: candidates)

        XCTAssertEqual(match?.item.artist, "Demuja")
        XCTAssertGreaterThanOrEqual(match?.score ?? 0, HandoffMatcher.minimumConfidence)
    }

    func testPunctuationAndCaseDoNotPreventMatch() {
        let source = AppleMusicHandoffTrack(
            title: "Josephine (feat. Lisa Hannigan)",
            artist: "RITUAL",
            album: nil,
            duration: 190,
            position: 30,
            playbackStoreID: nil,
            persistentID: nil
        )
        let candidates = [
            makeItem(title: "josephine feat lisa hannigan", artist: "Ritual", album: "", duration: 191)
        ]

        let match = HandoffMatcher.bestMatch(for: source, candidates: candidates)

        XCTAssertNotNil(match)
    }

    func testRemasterSuffixCanStillMatchWhenArtistAndDurationMatch() {
        let source = AppleMusicHandoffTrack(
            title: "Blue Monday",
            artist: "New Order",
            album: "Power Corruption & Lies",
            duration: 449,
            position: 12,
            playbackStoreID: nil,
            persistentID: nil
        )
        let candidates = [
            makeItem(title: "Blue Monday - 2015 Remaster", artist: "New Order", album: "Power Corruption & Lies", duration: 450)
        ]

        let match = HandoffMatcher.bestMatch(for: source, candidates: candidates)

        XCTAssertNotNil(match)
    }

    func testWrongArtistDoesNotCrossThreshold() {
        let source = AppleMusicHandoffTrack(
            title: "Intro",
            artist: "The xx",
            album: "xx",
            duration: 127,
            position: 4,
            playbackStoreID: nil,
            persistentID: nil
        )
        let candidates = [
            makeItem(title: "Intro", artist: "M83", album: "Hurry Up, We're Dreaming", duration: 127)
        ]

        let match = HandoffMatcher.bestMatch(for: source, candidates: candidates)

        XCTAssertNil(match)
    }

    func testLargeDurationMismatchDoesNotCrossThreshold() {
        let source = AppleMusicHandoffTrack(
            title: "Nights",
            artist: "Frank Ocean",
            album: "Blonde",
            duration: 307,
            position: 64,
            playbackStoreID: nil,
            persistentID: nil
        )
        let candidates = [
            makeItem(title: "Nights", artist: "Frank Ocean", album: "Blonde", duration: 90)
        ]

        let match = HandoffMatcher.bestMatch(for: source, candidates: candidates)

        XCTAssertNil(match)
    }

    private func makeItem(title: String, artist: String, album: String, duration: TimeInterval) -> BrowseItem {
        BrowseItem(
            id: UUID().uuidString,
            title: title,
            artist: artist,
            album: album,
            albumArtURL: nil,
            uri: "x-sonos-http:test.mp4?sid=204&flags=8232&sn=1",
            metaXML: nil,
            duration: duration,
            isContainer: false,
            serviceId: 204,
            cloudType: "TRACK"
        )
    }
}
```

If the project does not yet have a test target, add a `SonosWidgetTests` XCTest target that builds for iOS and includes `HandoffMatcherTests.swift`.

- [ ] **Step 3: Run the matcher tests and verify they fail**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SonosWidgetTests/HandoffMatcherTests test
```

Expected before implementation: failure because `HandoffMatcher` is not defined.

- [ ] **Step 4: Add the matcher implementation**

Create `Shared/HandoffMatcher.swift`:

```swift
import Foundation

enum HandoffMatcher {
    struct Match: Equatable {
        let item: BrowseItem
        let score: Int
    }

    static let minimumConfidence = 80

    static func bestMatch(
        for source: AppleMusicHandoffTrack,
        candidates: [BrowseItem]
    ) -> Match? {
        candidates
            .compactMap { candidate -> Match? in
                let score = score(source: source, candidate: candidate)
                guard score >= minimumConfidence else { return nil }
                return Match(item: candidate, score: score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.item.title.count < rhs.item.title.count
            }
            .first
    }

    static func score(source: AppleMusicHandoffTrack, candidate: BrowseItem) -> Int {
        let sourceTitle = normalized(source.title)
        let candidateTitle = normalized(candidate.title)
        guard titleMatches(sourceTitle, candidateTitle) else { return 0 }

        var score = sourceTitle == candidateTitle ? 45 : 35

        let sourceArtist = normalized(source.artist)
        let candidateArtist = normalized(candidate.artist)
        if !sourceArtist.isEmpty, !candidateArtist.isEmpty {
            if sourceArtist == candidateArtist {
                score += 35
            } else if candidateArtist.contains(sourceArtist) || sourceArtist.contains(candidateArtist) {
                score += 25
            } else {
                score -= 35
            }
        }

        if let album = source.album {
            let sourceAlbum = normalized(album)
            let candidateAlbum = normalized(candidate.album)
            if !sourceAlbum.isEmpty, !candidateAlbum.isEmpty {
                if sourceAlbum == candidateAlbum {
                    score += 12
                } else if candidateAlbum.contains(sourceAlbum) || sourceAlbum.contains(candidateAlbum) {
                    score += 6
                }
            }
        }

        if let sourceDuration = source.duration, sourceDuration > 0, candidate.duration > 0 {
            let delta = abs(sourceDuration - candidate.duration)
            switch delta {
            case 0...3: score += 10
            case 3...8: score += 5
            case 8...20: score -= 10
            default: score -= 40
            }
        }

        return score
    }

    static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"\b(remaster(ed)?|deluxe|explicit|clean|single version)\b"#,
                                  with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#,
                                  with: " ",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func titleMatches(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs == rhs || lhs.contains(rhs) || rhs.contains(lhs)
    }
}
```

- [ ] **Step 5: Add the matcher file to the project**

Add `Shared/HandoffMatcher.swift` to the app target and the test target. Mirror how other `Shared/*.swift` files are referenced in `SonosWidget.xcodeproj/project.pbxproj`.

- [ ] **Step 6: Run matcher tests and verify they pass**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SonosWidgetTests/HandoffMatcherTests test
```

Expected: all `HandoffMatcherTests` pass.

- [ ] **Step 7: Commit**

```bash
git add Shared/HandoffMatcher.swift Shared/Models.swift SonosWidgetTests/HandoffMatcherTests.swift SonosWidget.xcodeproj/project.pbxproj
git commit -m "Add Apple Music handoff matcher"
```

---

### Task 3: Add Sonos Transfer Orchestration

**Files:**
- Modify: `SonosWidget/SearchManager.swift`

- [ ] **Step 1: Add handoff result and errors near the SearchManager type**

Add these types near the top of `SonosWidget/SearchManager.swift`, outside `SearchManager`:

```swift
struct HandoffResult: Equatable {
    let matchedTitle: String
    let targetName: String
    let seeked: Bool
}

enum HandoffTransferError: LocalizedError, Equatable {
    case noSelectedSpeaker
    case sonosCloudDisconnected
    case appleMusicNotLinkedOnSonos
    case noConfidentMatch
    case sonosPlaybackFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSelectedSpeaker:
            return "Select a Sonos speaker first."
        case .sonosCloudDisconnected:
            return "Connect your Sonos account before transferring Apple Music."
        case .appleMusicNotLinkedOnSonos:
            return "Apple Music is not linked in this Sonos household."
        case .noConfidentMatch:
            return "Couldn’t match this song on Sonos."
        case .sonosPlaybackFailed(let message):
            return message
        }
    }
}
```

- [ ] **Step 2: Refactor `playNow` to return success internally**

Keep the public API used by existing callers:

```swift
func playNow(item: BrowseItem, manager: SonosManager) async {
    _ = await playNowInternal(item: item, manager: manager)
}
```

Move the current body of `playNow(item:manager:)` into:

```swift
@discardableResult
private func playNowInternal(item: BrowseItem, manager: SonosManager) async -> Bool {
    // Existing playNow body goes here.
    // Return true after remote loadFavorite succeeds.
    // Return true after LAN SetAVTransportURI/AddURIToQueue/Play succeeds.
    // Return false for all early exits and catches that currently set errorMessage.
}
```

When moving the body, use these explicit returns:

```swift
// After remote loadFavorite + refreshState:
return true

// When manager.transportBackend == .cloud and item is not cloud-playable:
return false

// After successful LAN radio or queue playback + refreshState:
return true

// In catch blocks:
return false
```

- [ ] **Step 3: Add the transfer method**

Before adding the transfer method, update `convertToBrowseItem(_:serviceId:accountId:)`
so Cloud search results preserve track duration for matching:

```swift
let duration = resource.durationMs.map { TimeInterval($0) / 1000.0 } ?? 0

return BrowseItem(
    id: objectId, title: name, artist: artistName, album: albumName,
    albumArtURL: artURL, uri: uri, metaXML: nil,
    duration: duration,
    isContainer: isContainer, serviceId: localSid, cloudType: type)
```

Keep the default `0` for resources where Sonos Cloud does not return duration.

Add this method inside `SearchManager`:

```swift
@discardableResult
func transferAppleMusicTrack(
    _ track: AppleMusicHandoffTrack,
    manager: SonosManager
) async throws -> HandoffResult {
    guard let selected = manager.selectedSpeaker else {
        throw HandoffTransferError.noSelectedSpeaker
    }
    guard let token = await SonosAuth.shared.validAccessToken(),
          let householdId = SonosAuth.shared.householdId else {
        throw HandoffTransferError.sonosCloudDisconnected
    }

    if !hasProbed {
        await probeLinkedServices()
    }

    guard let appleMusicAccount = linkedAccounts.first(where: {
        PlaybackSource.from(serviceName: $0.displayName) == .appleMusic
            || $0.displayName.localizedCaseInsensitiveContains("Apple Music")
    }),
          let serviceId = appleMusicAccount.serviceId,
          let accountId = appleMusicAccount.accountId else {
        throw HandoffTransferError.appleMusicNotLinkedOnSonos
    }

    let response = try await searchServiceWithTokenRefresh(
        token: token,
        householdId: householdId,
        serviceId: serviceId,
        accountId: accountId,
        term: "\(track.title) \(track.artist)"
    )

    let candidates = (response.resources ?? [])
        .filter { ($0.type ?? "") == "TRACK" }
        .compactMap { convertToBrowseItem($0, serviceId: serviceId, accountId: accountId) }

    guard let match = HandoffMatcher.bestMatch(for: track, candidates: candidates) else {
        throw HandoffTransferError.noConfidentMatch
    }

    let previousError = errorMessage
    errorMessage = nil
    let played = await playNowInternal(item: match.item, manager: manager)
    guard played else {
        throw HandoffTransferError.sonosPlaybackFailed(
            errorMessage ?? previousError ?? "Couldn’t start playback on Sonos."
        )
    }

    var didSeek = false
    if track.position > 3 {
        let maxPosition = track.duration.map { max(0, min(track.position, $0 - 2)) } ?? track.position
        await manager.seekTo(maxPosition)
        didSeek = true
    }

    await manager.refreshState()
    return HandoffResult(
        matchedTitle: match.item.title,
        targetName: selected.name,
        seeked: didSeek
    )
}
```

- [ ] **Step 4: Build after orchestration changes**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add SonosWidget/SearchManager.swift
git commit -m "Add Sonos Apple Music transfer orchestration"
```

---

### Task 4: Add Home TRANSFER Control

**Files:**
- Modify: `SonosWidget/PlayerView.swift`

- [ ] **Step 1: Add Home state**

Near the existing Home drag/drop state in `PlayerView`:

```swift
@State private var isTransferringAppleMusic = false
@State private var homeToastMessage: String?
```

- [ ] **Step 2: Replace the bottom-right overlay content**

Change the `.overlay(alignment: .bottomTrailing)` content in `speakersHomeView` from a single `ungroupZone` to:

```swift
homeActionZone
    .padding(.trailing, 20)
    .padding(.bottom, 16)
```

Add `.toast($homeToastMessage)` to `speakersHomeView` after the overlays.

- [ ] **Step 3: Add the combined Home action zone**

Add this view near `ungroupZone`:

```swift
private var homeActionZone: some View {
    VStack(spacing: 14) {
        transferZone
        ungroupZone
            .dropDestination(for: String.self) { items, _ in
                guard let groupID = items.first else { return false }
                Task { await manager.separateGroup(groupID: groupID) }
                return true
            } isTargeted: { targeted in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    isSeparateZoneTargeted = targeted
                }
            }
    }
}
```

- [ ] **Step 4: Add the TRANSFER control**

Add this view near `ungroupZone`:

```swift
private var transferZone: some View {
    Button {
        transferAppleMusicToSonos()
    } label: {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(isTransferringAppleMusic ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                Circle()
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1.5)
                if isTransferringAppleMusic {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "iphone.and.arrow.forward")
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
    .disabled(isTransferringAppleMusic || !manager.isConfigured)
    .accessibilityLabel("Transfer Apple Music to selected Sonos speaker")
}
```

- [ ] **Step 5: Add the action handler**

Add this method to `PlayerView`:

```swift
private func transferAppleMusicToSonos() {
    guard !isTransferringAppleMusic else { return }
    isTransferringAppleMusic = true

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
        isTransferringAppleMusic = false
    }
}
```

- [ ] **Step 6: Build after UI changes**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add SonosWidget/PlayerView.swift
git commit -m "Add Home Apple Music transfer control"
```

---

### Task 5: Device Verification

**Files:**
- No new files.

- [ ] **Step 1: Run all available automated checks**

Run matcher tests if the test target was added:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:SonosWidgetTests/HandoffMatcherTests test
```

Expected: tests pass.

Run generic build:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project SonosWidget.xcodeproj \
  -scheme SonosWidget \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Deploy to the connected iPhone**

Run:

```bash
/Users/charm/.codex/skills/ios-device-deploy/scripts/deploy_ios_device.sh --scheme SonosWidget
```

Expected: build, install, and launch succeed.

- [ ] **Step 3: Verify permission failure path**

On a device or fresh install where Apple Music permission is not granted:

1. Open Home.
2. Tap `TRANSFER`.
3. Deny Apple Music permission.

Expected: the app shows "Apple Music access is not allowed." and Sonos does not start playback.

- [ ] **Step 4: Verify no-current-track failure path**

1. Ensure Apple Music is stopped.
2. Open Home.
3. Tap `TRANSFER`.

Expected: the app shows "Nothing is currently playing in Apple Music." and Sonos does not start playback.

- [ ] **Step 5: Verify happy path**

1. Start an Apple Music song on the iPhone.
2. Let it play for at least 30 seconds.
3. Open SonosWidget Home.
4. Select the desired Sonos speaker or group.
5. Tap `TRANSFER`.

Expected:

- `TRANSFER` shows a spinner while working.
- The selected Sonos target starts the same song.
- Sonos seeks near the original iPhone playback position.
- iPhone Apple Music pauses after Sonos playback starts.
- Home shows a success toast.
- Mini-player/Home card refresh to the transferred track.

- [ ] **Step 6: Commit any verification fixes**

If verification required code changes, commit them:

```bash
git add Shared/AppleMusicHandoff.swift Shared/HandoffMatcher.swift SonosWidget/SearchManager.swift SonosWidget/PlayerView.swift SonosWidget/Info.plist SonosWidget.xcodeproj/project.pbxproj SonosWidgetTests/HandoffMatcherTests.swift
git commit -m "Stabilize Apple Music handoff"
```

If no changes were required, do not create an empty commit.

---

## Self-Review

- Spec coverage: The plan covers Apple Music-only capture, Home `TRANSFER`, current selected Sonos target, strict matching, playback, seek, pause-after-success, explicit errors, permission handling, tests, and physical-device verification.
- Completion scan: No unfinished items or unspecified test steps remain.
- Type consistency: `AppleMusicHandoffTrack`, `AppleMusicHandoffManager`, `HandoffMatcher`, `HandoffResult`, and `transferAppleMusicTrack(_:manager:)` are introduced before later tasks reference them.
