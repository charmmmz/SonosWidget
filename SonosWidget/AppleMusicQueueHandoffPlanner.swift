import Foundation

struct AppleMusicQueueHandoffPlan: Equatable, Sendable {
    let storeIDs: [String]
    let skippedUnsupportedItemCount: Int

    var transferredTrackCount: Int { storeIDs.count }
}

enum AppleMusicQueueHandoffPlanner {
    static let defaultMaxItems = 50

    static func makePlan(
        queue: [QueueItem],
        currentTrackNumber: Int?,
        currentTrackInfo: TrackInfo,
        currentStoreID: String,
        maxItems: Int = defaultMaxItems
    ) -> AppleMusicQueueHandoffPlan? {
        let trimmedCurrentStoreID = trimmed(currentStoreID)
        guard !trimmedCurrentStoreID.isEmpty else { return nil }
        guard !queue.isEmpty, maxItems > 0 else {
            return AppleMusicQueueHandoffPlan(
                storeIDs: [trimmedCurrentStoreID],
                skippedUnsupportedItemCount: 0)
        }

        guard let startIndex = startIndex(
            in: queue,
            currentTrackNumber: currentTrackNumber,
            currentTrackInfo: currentTrackInfo,
            currentStoreID: trimmedCurrentStoreID) else {
            return AppleMusicQueueHandoffPlan(
                storeIDs: [trimmedCurrentStoreID],
                skippedUnsupportedItemCount: 0)
        }

        let candidates = queue[startIndex...].prefix(maxItems)
        var storeIDs: [String] = []
        var skipped = 0

        for (offset, item) in candidates.enumerated() {
            if offset == 0 {
                storeIDs.append(trimmedCurrentStoreID)
                continue
            }

            if let storeID = storeID(from: item) {
                storeIDs.append(storeID)
            } else {
                skipped += 1
            }
        }

        return AppleMusicQueueHandoffPlan(
            storeIDs: storeIDs.isEmpty ? [trimmedCurrentStoreID] : storeIDs,
            skippedUnsupportedItemCount: skipped)
    }

    private static func startIndex(
        in queue: [QueueItem],
        currentTrackNumber: Int?,
        currentTrackInfo: TrackInfo,
        currentStoreID: String
    ) -> Int? {
        if let currentTrackNumber,
           queue.indices.contains(currentTrackNumber - 1) {
            return currentTrackNumber - 1
        }

        if let index = queue.firstIndex(where: { storeID(from: $0) == currentStoreID }) {
            return index
        }

        let currentTitle = normalized(currentTrackInfo.title)
        let currentArtist = normalized(currentTrackInfo.artist)
        guard !currentTitle.isEmpty, !currentArtist.isEmpty else { return nil }

        return queue.firstIndex {
            normalized($0.title) == currentTitle &&
            normalized($0.artist) == currentArtist
        }
    }

    private static func storeID(from item: QueueItem) -> String? {
        SonosAppleMusicTrackResolver.storeID(fromTrackURI: item.uri)
            ?? SonosAppleMusicTrackResolver.storeID(fromObjectID: item.objectID)
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
