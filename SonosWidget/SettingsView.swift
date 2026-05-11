import SwiftUI

/// Consolidated Settings tab. Groups account, speakers, music services, and
/// about-app rows into one place, replacing the two per-tab menus that used
/// to live in `PlayerView` (ellipsis) and `SearchView` (sliders).
struct SettingsView: View {
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager

    @State private var isConnectingSonos = false
    /// Bound to the Live Activity Relay TextField. We only push edits into
    /// `RelayManager` on submit / blur — typing per-character would otherwise
    /// fire a probe with every keystroke.
    @State private var relayURLDraft: String = RelayManager.shared.urlString

    /// Re-read the singleton through @Bindable so SwiftUI subscribes to its
    /// observable changes and re-renders the status row.
    @Bindable private var relay = RelayManager.shared

    @State private var agentURLDraft: String = AgentManager.shared.urlString
    @State private var agentTokenDraft: String = AgentManager.shared.tokenString
    @FocusState private var focusedInputField: SettingsInputField?
    @Bindable private var agent = AgentManager.shared
    @Bindable private var auth = SonosAuth.shared
    @Bindable private var hueStore = HueAmbienceStore.shared
    @Bindable private var musicAmbience = MusicAmbienceManager.shared
    @State private var musicAmbienceSetupPresentation = MusicAmbienceSetupPresentationState()

    var body: some View {
        NavigationStack {
            Form {
                settingsHubSection
                aboutSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .scrollContentBackground(.hidden)
            .background {
                backgroundLayer.ignoresSafeArea()
            }
            .preferredColorScheme(.dark)
            .navigationDestination(for: SettingsHubDestination.self) { destination in
                settingsDestinationView(for: destination)
            }
            .onAppear {
                relayURLDraft = relay.urlString
                agentURLDraft = agent.urlString
                agentTokenDraft = agent.tokenString
                Task { await relay.probeNow() }
                Task { await agent.probeNow() }
                musicAmbience.refreshStatus()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    finishEditingFocusedInput()
                }
            }
        }
        .sheet(isPresented: musicAmbienceSetupBinding) {
            HueAmbienceSetupSheet(
                store: hueStore,
                manager: musicAmbience,
                sonosSpeakers: displayedSpeakers
            )
        }
    }

    // MARK: - Settings Hub

    private var settingsHubSection: some View {
        Section {
            ForEach(SettingsHubDestination.primary) { destination in
                NavigationLink(value: destination) {
                    SettingsHubDestinationRow(
                        destination: destination,
                        status: settingsHubStatus(for: destination)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func settingsDestinationView(for destination: SettingsHubDestination) -> some View {
        switch destination {
        case .sonos:
            settingsDetailForm(title: destination.title) {
                sonosAccountSection
                speakersSection
                musicServicesSection
            }
        case .musicAmbience:
            settingsDetailForm(title: destination.title) {
                MusicAmbienceSettingsView(
                    store: hueStore,
                    manager: musicAmbience,
                    sonosSpeakers: displayedSpeakers,
                    presentSetup: {
                        musicAmbienceSetupPresentation.present()
                    }
                )
            }
        case .localServer:
            settingsDetailForm(title: destination.title) {
                relaySection
                agentSection
            }
        }
    }

    private func settingsDetailForm<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form {
            content()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background {
            backgroundLayer.ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
    }

    private func settingsHubStatus(for destination: SettingsHubDestination) -> String? {
        switch destination {
        case .sonos:
            return "\(sonosAccountStatusSummary) · \(speakersStatusSummary)"
        case .musicAmbience:
            return musicAmbienceStatusSummary
        case .localServer:
            return "Relay \(relayStatusTitle) · Agent \(agentStatusTitle)"
        }
    }

    private var sonosAccountStatusSummary: String {
        switch auth.sessionState {
        case .connected:
            return "Account connected"
        case .expired:
            return "Session expired"
        case .checking:
            return "Checking account"
        case .disconnected:
            return "Account disconnected"
        }
    }

    private var speakersStatusSummary: String {
        let count = displayedSpeakers.count
        switch count {
        case 0:
            return "No speakers"
        case 1:
            return "1 speaker"
        default:
            return "\(count) speakers"
        }
    }

    private var musicAmbienceStatusSummary: String {
        guard hueStore.bridge != nil else {
            return musicAmbience.status.title
        }

        let assignmentCount = hueStore.mappings.count
        let assignments = assignmentCount == 1 ? "1 assignment" : "\(assignmentCount) assignments"
        return "\(musicAmbience.status.title) · \(assignments)"
    }

    private var musicAmbienceSetupBinding: Binding<Bool> {
        Binding {
            musicAmbienceSetupPresentation.isPresented
        } set: { isPresented in
            if isPresented {
                musicAmbienceSetupPresentation.present()
            } else {
                musicAmbienceSetupPresentation.dismiss()
            }
        }
    }

    private var inputDrafts: SettingsInputDrafts {
        SettingsInputDrafts(
            relayURL: relayURLDraft,
            agentURL: agentURLDraft,
            agentToken: agentTokenDraft
        )
    }

    private func finishEditingFocusedInput() {
        finishEditingInput(focusedInputField)
    }

    private func finishEditingInput(_ field: SettingsInputField?) {
        focusedInputField = inputDrafts.commit(
            focusedField: field,
            relayURL: { relay.setURL($0) },
            agentURL: { agent.setURL($0) },
            agentToken: { agent.setToken($0) }
        )
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            if let image = manager.albumArtImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 80)
                    .scaleEffect(1.5)
                Color.black.opacity(0.6)
            } else {
                Color.black
            }
        }
    }

    // MARK: - Sonos Account

    @ViewBuilder
    private var sonosAccountSection: some View {
        Section {
            switch auth.sessionState {
            case .connected:
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected")
                            .font(.subheadline.weight(.semibold))
                        Text("Sonos Cloud session active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Disconnect", role: .destructive) {
                        SonosAuth.shared.logout()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }

            case .expired:
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Session Expired")
                            .font(.subheadline.weight(.semibold))
                        Text("Reconnect your Sonos account")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reconnect") {
                        connectSonos(reconnect: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isConnectingSonos)
                }

            case .checking:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Checking")
                            .font(.subheadline.weight(.semibold))
                        Text("Refreshing Sonos Cloud session")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

            case .disconnected:
                connectSonosButton
            }
        } header: {
            Text("Sonos Account")
        } footer: {
            Text("Sign in with your Sonos account to enable cloud-powered search, artist / album browsing, and richer playback metadata.")
        }
    }

    private var connectSonosButton: some View {
        Button {
            connectSonos()
        } label: {
            HStack {
                Label("Connect Sonos Account",
                      systemImage: "person.crop.circle.badge.plus")
                Spacer()
                if isConnectingSonos {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(isConnectingSonos)
    }

    private func connectSonos(reconnect: Bool = false) {
        isConnectingSonos = true
        Task {
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.windows.first
            let success = if reconnect {
                await auth.reconnect(from: window)
            } else {
                await auth.startLogin(from: window)
            }
            if success {
                await manager.resolveCloudGroupId()
                await manager.refreshState()
                await searchManager.forceReprobe()
            }
            isConnectingSonos = false
        }
    }

    // MARK: - Speakers

    @ViewBuilder
    private var speakersSection: some View {
        Section {
            if displayedSpeakers.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "hifispeaker.slash")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No speakers discovered yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(displayedSpeakers) { speaker in
                    speakerRow(speaker)
                }
            }

            Button {
                manager.showingAddSpeaker = true
            } label: {
                Label("Enter IP Manually", systemImage: "keyboard")
            }
        } header: {
            sectionHeader(title: "Speakers",
                          refresh: { manager.rescan() },
                          isBusy: manager.discovery.isScanning)
        } footer: {
            Text("Tap the refresh icon to rescan your network, or use Enter IP Manually if a speaker can't be found.")
        }
    }

    /// Coordinators only (one row per Sonos room/group) and never invisible
    /// sub/sat satellites. Sorted alphabetically — the Home tab already shows
    /// per-zone playback state, so Settings doesn't need to highlight which
    /// speaker is the "current control target".
    private var displayedSpeakers: [SonosPlayer] {
        let pool = manager.speakers.isEmpty
            ? manager.allSpeakers.filter { $0.isCoordinator && !$0.isInvisible }
            : manager.speakers.filter { !$0.isInvisible }
        return pool.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func speakerRow(_ speaker: SonosPlayer) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "hifispeaker.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(speaker.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(speaker.playbackIP)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
    }

    // MARK: - Music Services

    @ViewBuilder
    private var musicServicesSection: some View {
        Section {
            if searchManager.isProbing {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Detecting linked services…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if searchManager.linkedAccounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("No Music Services Found",
                          systemImage: "music.note.list")
                        .font(.subheadline.weight(.semibold))
                    Text("Link a music service in the official Sonos app, then tap the refresh icon.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(sortedAccounts, id: \.serviceId) { account in
                    serviceRow(account)
                }
            }
        } header: {
            sectionHeader(title: "Music Services",
                          refresh: { Task { await searchManager.forceReprobe() } },
                          isBusy: searchManager.isProbing)
        } footer: {
            Text("Toggle which linked services appear in Browse search results. Sign-in and account management stay in the official Sonos app.")
        }
    }

    // MARK: - Section Header with Inline Refresh

    /// Form `Section` header with an inline refresh glyph on the trailing
    /// edge. Preserves SwiftUI's default header font/casing on the title while
    /// letting the button look like a small affordance next to it.
    private func sectionHeader(title: String,
                                refresh: @escaping () -> Void,
                                isBusy: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Spacer()
            Button(action: refresh) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
            }
            .buttonStyle(.plain)
            .textCase(nil)
            .disabled(isBusy)
        }
    }

    private var sortedAccounts: [SonosCloudAPI.CloudMusicServiceAccount] {
        let pinned: Set<String> = ["3079", "52231", "51463", "42247", "49671"]
        return searchManager.linkedAccounts.sorted { a, b in
            let aPinned = pinned.contains(a.serviceId ?? "")
            let bPinned = pinned.contains(b.serviceId ?? "")
            if aPinned != bPinned { return aPinned }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    private func serviceRow(_ account: SonosCloudAPI.CloudMusicServiceAccount) -> some View {
        let sid = account.serviceId ?? ""
        let enabled = searchManager.serviceEnabled[sid] ?? true

        return HStack(spacing: 12) {
            CloudServiceBrandMark(
                cloudServiceId: sid,
                displayNameHint: account.displayName,
                dimension: 24,
                symbolUsesTitle3: true
            )
            .foregroundStyle(enabled ? .primary : .secondary)
            .opacity(enabled ? 1 : 0.45)
            .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .foregroundStyle(enabled ? .primary : .secondary)
                if let nick = account.nickname, nick != account.displayName {
                    Text(nick)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { searchManager.serviceEnabled[sid] ?? true },
                set: { searchManager.setServiceEnabled(serviceId: sid, enabled: $0) }
            ))
            .labelsHidden()
        }
    }

    // MARK: - Live Activity Relay

    @ViewBuilder
    private var relaySection: some View {
        Section {
            TextField("http://192.168.50.10:8787", text: $relayURLDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.done)
                .focused($focusedInputField, equals: .relayURL)
                .onSubmit {
                    finishEditingInput(.relayURL)
                }

            relayStatusRow

            Button {
                // Commit any pending edits (in case the user typed but didn't
                // press return) and force an immediate probe.
                let urlChanged = relay.urlString != relayURLDraft
                finishEditingInput(.relayURL)
                if !urlChanged {
                    Task { await relay.probeNow() }
                }
            } label: {
                Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(relayURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("Live Activity Relay")
        } footer: {
            Text("""
                 Optional. When a NAS service from `nas-relay/` is reachable, \
                 the Lock Screen Live Activity stays fresh even while this \
                 app is fully suspended (push notifications). Leave blank to \
                 use the on-device update path that runs while the app is alive.
                 """)
        }
    }

    @ViewBuilder
    private var relayStatusRow: some View {
        HStack(spacing: 12) {
            relayStatusIndicator
            VStack(alignment: .leading, spacing: 2) {
                Text(relayStatusTitle)
                    .font(.subheadline.weight(.semibold))
                if let detail = relayStatusDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var relayStatusIndicator: some View {
        let color: Color
        switch relay.status {
        case .connected: color = .green
        case .probing:   color = .yellow
        case .disabled:  color = .secondary
        case .unreachable: color = .red
        }
        return Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay {
                if case .probing = relay.status {
                    Circle().stroke(Color.yellow, lineWidth: 1).scaleEffect(1.5)
                        .opacity(0.5)
                }
            }
    }

    private var relayStatusTitle: String {
        switch relay.status {
        case .disabled:                       return "Disabled"
        case .probing:                        return "Probing…"
        case .connected(let n) where n == 1:  return "Connected · 1 group"
        case .connected(let n):               return "Connected · \(n) groups"
        case .unreachable:                    return "Unreachable"
        }
    }

    private var relayStatusDetail: String? {
        switch relay.status {
        case .disabled:                return "Enter a URL to enable APNs-driven Live Activity updates."
        case .probing:                 return nil
        case .connected:               return "Live Activity will update via the relay even when the app is suspended."
        case .unreachable(let reason): return reason
        }
    }

    // MARK: - NAS Agent

    @ViewBuilder
    private var agentSection: some View {
        Section {
            TextField("http://192.168.50.10:8790", text: $agentURLDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.done)
                .focused($focusedInputField, equals: .agentURL)
                .onSubmit {
                    finishEditingInput(.agentURL)
                }

            SecureField("Agent bearer token", text: $agentTokenDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focusedInputField, equals: .agentToken)
                .onSubmit {
                    finishEditingInput(.agentToken)
                }

            agentStatusRow

            Button {
                finishEditingInput(.agentURL)
                finishEditingInput(.agentToken)
                Task { await agent.probeNow() }
            } label: {
                Label("Test Agent Connection", systemImage: "bolt.horizontal.circle")
            }
            .disabled(
                agentURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || agentTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        } header: {
            Text("NAS Agent")
        } footer: {
            Text("""
                 Optional Python agent (`nas-agent/`) for natural-language Sonos control via \
                 your relay. Use the same machine as the relay with port 8790 by default, \
                 and paste the `AGENT_USER_TOKEN` from your Docker `.env`. Requires OpenAI \
                 API key on the server.
                 """)
        }
    }

    @ViewBuilder
    private var agentStatusRow: some View {
        HStack(spacing: 12) {
            agentStatusIndicator
            VStack(alignment: .leading, spacing: 2) {
                Text(agentStatusTitle)
                    .font(.subheadline.weight(.semibold))
                if let detail = agentStatusDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
    }

    private var agentStatusIndicator: some View {
        let color: Color
        switch agent.status {
        case .connected: color = .green
        case .probing: color = .yellow
        case .disabled: color = .secondary
        case .unreachable: color = .red
        }
        return Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay {
                if case .probing = agent.status {
                    Circle().stroke(Color.yellow, lineWidth: 1).scaleEffect(1.5)
                        .opacity(0.5)
                }
            }
    }

    private var agentStatusTitle: String {
        switch agent.status {
        case .disabled: return "Disabled"
        case .probing: return "Probing…"
        case .connected: return "Connected"
        case .unreachable: return "Unreachable"
        }
    }

    private var agentStatusDetail: String? {
        switch agent.status {
        case .disabled:
            return "Enter agent URL and bearer token from your NAS stack `.env`."
        case .probing: return nil
        case .connected: return "Agent can reach OpenAI and the Node relay."
        case .unreachable(let reason): return reason
        }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: appVersionString)
        }
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "—"
        let b = info?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}

private struct SettingsHubDestinationRow: View {
    let destination: SettingsHubDestination
    let status: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: destination.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(destination.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(destination.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let status {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Add Speaker Sheet (shared)

/// Sheet used by both the first-run setup screen and the new Settings tab
/// for adding a speaker by IP. Owns its own text field state so either call
/// site can present it without coordinating.
struct AddSpeakerSheet: View {
    @Bindable var manager: SonosManager
    @State private var newSpeakerIP = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("Speaker IP Address", text: $newSpeakerIP)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)

                Button {
                    Task {
                        await manager.addSpeaker(ip: newSpeakerIP)
                        if manager.errorMessage == nil {
                            newSpeakerIP = ""
                            dismiss()
                        }
                    }
                } label: {
                    if manager.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Connect").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newSpeakerIP.isEmpty || manager.isLoading)

                if let error = manager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Add Speaker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
