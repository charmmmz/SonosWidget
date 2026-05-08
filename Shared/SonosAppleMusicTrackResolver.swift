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

    private static let numericStoreIDNamespaces: Set<String> = [
        "song",
        "songs",
        "track",
        "tracks"
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

    static func cloudTrackObjectIDForNowPlaying(fromTrackURI uri: String?) -> String? {
        guard let objectID = trackObjectID(from: uri) else { return nil }
        return cloudTrackObjectID(fromObjectID: objectID)
    }

    static func storeID(fromBrowseItem item: BrowseItem) -> String? {
        storeID(fromObjectID: item.id) ?? storeID(fromTrackURI: item.uri)
    }

    static func storeID(fromObjectID rawObjectID: String?) -> String? {
        guard var objectID = normalizedObjectID(rawObjectID) else { return nil }
        let lowercasedObjectID = objectID.lowercased()
        for prefix in appleMusicTrackObjectPrefixes where lowercasedObjectID.hasPrefix(prefix) {
            objectID = String(objectID.dropFirst(prefix.count))
            break
        }

        guard !objectID.isEmpty,
              objectID.allSatisfy({ $0.isNumber }) else {
            return namespacedNumericStoreID(fromObjectID: objectID)
        }
        return objectID
    }

    private static func namespacedNumericStoreID(fromObjectID objectID: String) -> String? {
        let parts = objectID.split(separator: ":").map(String.init)
        guard parts.count >= 2,
              let namespace = parts.dropLast().last?.lowercased(),
              numericStoreIDNamespaces.contains(namespace),
              let suffix = parts.last,
              !suffix.isEmpty,
              suffix.allSatisfy({ $0.isNumber }) else {
            return nil
        }
        return suffix
    }

    private static func cloudTrackObjectID(fromObjectID rawObjectID: String?) -> String? {
        guard var objectID = normalizedObjectID(rawObjectID) else { return nil }
        let lowercasedObjectID = objectID.lowercased()
        if let prefix = appleMusicTrackObjectPrefixes.first(where: {
            lowercasedObjectID.hasPrefix($0)
        }) {
            objectID = String(objectID.dropFirst(prefix.count))
        } else if hasDIDLObjectPrefixBeforeScopedID(objectID) {
            objectID = String(objectID.dropFirst(8))
        }

        return objectID.isEmpty ? nil : objectID
    }

    private static func trackObjectID(from uri: String?) -> String? {
        guard let uri = sanitized(uri) else { return nil }
        let pathPart = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        let rawObjectID: String
        if let colonRange = pathPart.range(of: ":", options: .backwards) {
            rawObjectID = String(pathPart[colonRange.upperBound...])
        } else {
            rawObjectID = pathPart
        }
        return normalizedObjectID(rawObjectID)
    }

    private static func hasDIDLObjectPrefixBeforeScopedID(_ objectID: String) -> Bool {
        guard objectID.count > 8 else { return false }
        let prefixEnd = objectID.index(objectID.startIndex, offsetBy: 8)
        let prefix = objectID[..<prefixEnd]
        let scopedID = objectID[prefixEnd...]
        guard prefix.allSatisfy({ $0.isHexDigit }),
              let firstScopedCharacter = scopedID.first else {
            return false
        }
        return !firstScopedCharacter.isNumber
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
