import Foundation

enum HandoffDirection: Equatable, Sendable {
    case phoneToSonos
    case sonosToPhone
}

enum HandoffDirectionResolver {
    static func direction(forSonosState state: TransportState) -> HandoffDirection {
        state == .playing ? .sonosToPhone : .phoneToSonos
    }
}
