enum SettingsHubDestination: String, CaseIterable, Hashable, Identifiable {
    case sonos
    case hueAmbience
    case localServer

    static let primary: [SettingsHubDestination] = [
        .sonos,
        .hueAmbience,
        .localServer,
    ]

    var id: Self { self }

    var title: String {
        switch self {
        case .sonos:
            return "Sonos"
        case .hueAmbience:
            return "Hue Ambience"
        case .localServer:
            return "Local Server"
        }
    }

    var subtitle: String {
        switch self {
        case .sonos:
            return "Account, speakers, and music services"
        case .hueAmbience:
            return "Hue Bridge, sync status, music, and game lighting"
        case .localServer:
            return "Relay, Live Activity, and NAS Agent"
        }
    }

    var systemImage: String {
        switch self {
        case .sonos:
            return "hifispeaker.2.fill"
        case .hueAmbience:
            return "sparkles"
        case .localServer:
            return "server.rack"
        }
    }
}
