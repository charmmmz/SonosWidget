enum SettingsHubDestination: String, CaseIterable, Hashable, Identifiable {
    case sonos
    case musicAmbience
    case localServer

    static let primary: [SettingsHubDestination] = [
        .sonos,
        .musicAmbience,
        .localServer,
    ]

    var id: Self { self }

    var title: String {
        switch self {
        case .sonos:
            return "Sonos"
        case .musicAmbience:
            return "Music Ambience"
        case .localServer:
            return "Local Server"
        }
    }

    var subtitle: String {
        switch self {
        case .sonos:
            return "Account, speakers, and music services"
        case .musicAmbience:
            return "Hue Bridge, assignments, and light behavior"
        case .localServer:
            return "Relay, Live Activity, and NAS Agent"
        }
    }

    var systemImage: String {
        switch self {
        case .sonos:
            return "hifispeaker.2.fill"
        case .musicAmbience:
            return "sparkles"
        case .localServer:
            return "server.rack"
        }
    }
}
