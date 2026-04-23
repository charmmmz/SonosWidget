import SwiftUI

/// Consolidated Settings tab. Groups account, speakers, music services, and
/// about-app rows into one place, replacing the two per-tab menus that used
/// to live in `PlayerView` (ellipsis) and `SearchView` (sliders).
struct SettingsView: View {
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager

    @State private var isConnectingSonos = false

    var body: some View {
        NavigationStack {
            Form {
                sonosAccountSection
                speakersSection
                musicServicesSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .scrollContentBackground(.hidden)
            .background {
                backgroundLayer.ignoresSafeArea()
            }
            .preferredColorScheme(.dark)
        }
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
            if SonosAuth.shared.isLoggedIn {
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
            } else {
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
        } header: {
            Text("Sonos Account")
        } footer: {
            Text("Sign in with your Sonos account to enable cloud-powered search, artist / album browsing, and richer playback metadata.")
        }
    }

    private func connectSonos() {
        isConnectingSonos = true
        Task {
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.windows.first
            await SonosAuth.shared.startLogin(from: window)
            if SonosAuth.shared.isLoggedIn {
                await manager.resolveCloudGroupId()
                await manager.refreshState()
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
