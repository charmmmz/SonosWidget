import Foundation
#if SONOSWIDGET_TEST_TARGET
@testable import SonosWidget
#endif

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
