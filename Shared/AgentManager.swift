import Foundation
import Observation

/// Optional NAS-side LLM agent (`nas-agent/`). Separate from `RelayManager`
/// so Live Activity relay URL and agent URL can differ by port/path.
@MainActor
@Observable
final class AgentManager {

    static let shared = AgentManager()

    enum Status: Equatable {
        case disabled
        case probing
        case connected
        case unreachable(reason: String?)
    }

    private(set) var urlString: String = ""
    private(set) var tokenString: String = ""
    private(set) var status: Status = .disabled

    @ObservationIgnored private var inFlightProbe: Task<Void, Never>?

    var url: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    var isAvailable: Bool {
        if case .connected = status { return true }
        return false
    }

    private init() {
        urlString = SharedStorage.agentURLString ?? ""
        tokenString = SharedStorage.agentTokenString ?? ""
    }

    func setURL(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        urlString = trimmed
        SharedStorage.agentURLString = trimmed.isEmpty ? nil : trimmed
        refreshDisabledState()
    }

    func setToken(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        tokenString = trimmed
        SharedStorage.agentTokenString = trimmed.isEmpty ? nil : trimmed
        refreshDisabledState()
    }

    private func refreshDisabledState() {
        guard url != nil, !tokenString.isEmpty else {
            status = .disabled
            return
        }
        Task { await probeNow() }
    }

    func probeNow() async {
        guard let url else {
            status = .disabled
            return
        }
        guard !tokenString.isEmpty else {
            status = .disabled
            return
        }

        inFlightProbe?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            self.status = .probing
            do {
                let health = try await AgentClient.health(baseURL: url)
                guard !Task.isCancelled else { return }
                if health.ok == true,
                   health.openaiConfigured == true,
                   health.relay?.ok == true {
                    self.status = .connected
                } else if health.relay?.ok == false {
                    let reason = health.relay?.error ?? "Node relay unhealthy"
                    self.status = .unreachable(reason: reason)
                } else {
                    self.status = .unreachable(reason: "Agent not fully configured (OpenAI or relay)")
                }
            } catch is CancellationError {
                // superseded
            } catch {
                guard !Task.isCancelled else { return }
                self.status = .unreachable(reason: error.localizedDescription)
            }
        }
        inFlightProbe = task
        await task.value
    }
}
