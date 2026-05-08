import SwiftUI

struct PlayerView: View {
    @Bindable var manager: SonosManager
    @Bindable var searchManager: SearchManager
    @State private var newSpeakerIP = ""
    @State private var showManualEntry = false
    /// Tracked per-session so we only auto-connect on the *first* discovery
    /// result. After the auto-attempt, any speaker change is user-initiated.
    @State private var didAutoConnect = false

    var body: some View {
        Group {
            if manager.isConfigured {
                configuredView
            } else {
                NavigationStack {
                    setupView
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .principal) {
                                Text("Sonos").fontWeight(.semibold)
                            }
                        }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { manager.loadSavedState() }
    }

    // MARK: - Configured View

    private var configuredView: some View {
        NavigationStack {
            speakersHomeView
                .background {
                    blurredArtBackground.ignoresSafeArea()
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        .scrollContentBackground(.hidden)
    }

    private var blurredArtBackground: some View {
        ZStack {
            Color.black
            if let image = manager.albumArtImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 80)
                    .scaleEffect(1.5)
                    .id(manager.trackInfo?.albumArtURL)
                    .transition(.opacity)
                Color.black.opacity(0.6)
            }
        }
        .animation(.easeInOut(duration: 0.8), value: manager.trackInfo?.albumArtURL)
    }

    // MARK: - Speakers Home View

    @State private var dropTargetGroupID: String?
    @State private var isSeparateZoneTargeted = false
    @State private var isTransferringPlayback = false
    @State private var homeToastMessage: String?

    private var speakersHomeView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                // Surfaced when probe found no viable backend — user is
                // off-LAN and not signed in to Sonos Cloud (or cloud group
                // hasn't resolved). Tap-to-refresh runs another probe.
                if manager.isSpeakerUnreachable {
                    unreachableBanner
                }
                if manager.groupStatuses.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Loading speakers…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.top, 40)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(manager.groupStatuses) { group in
                            let isDropTarget = dropTargetGroupID == group.id
                            let dropAccent = manager.groupAlbumColors[group.id]
                                ?? manager.albumArtDominantColor
                                ?? .accentColor

                            speakerGroupCard(group)
                                // Drag source: carry the group ID as a String.
                                .draggable(group.id) {
                                    dragPreview(group)
                                }
                                // Drop target: receive another group's ID.
                                .dropDestination(for: String.self) { items, _ in
                                    guard let sourceID = items.first,
                                          sourceID != group.id else { return false }
                                    Task { await manager.mergeGroups(sourceGroupID: sourceID,
                                                                     intoGroupID: group.id) }
                                    return true
                                } isTargeted: { targeted in
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        dropTargetGroupID = targeted ? group.id : nil
                                    }
                                }
                                // Highlight drop target with an animated border.
                                .overlay {
                                    if isDropTarget {
                                        RoundedRectangle(cornerRadius: 14)
                                            .strokeBorder(dropAccent.opacity(0.8), lineWidth: 2)
                                            .transition(.opacity)
                                    }
                                }
                                .scaleEffect(isDropTarget ? 1.02 : 1.0)
                                .animation(.spring(response: 0.25, dampingFraction: 0.7),
                                           value: isDropTarget)
                        }
                    }
                    .padding(.horizontal)
                }

                Spacer(minLength: 20)
            }
            // Home tab has no navigation title, so without a top inset the
            // first speaker card hugs the status bar and leaves the lower
            // half of the screen visually empty. A 48pt pad breathes the
            // group cards away from the notch while still letting taller
            // lists flow off the bottom normally.
            .padding(.top, 48)
        }
        // Single source of truth for the "we're driving via Sonos Cloud"
        // affordance. Floats at the top-left inside the breathing space
        // above the first speaker card, so it doesn't push the cards
        // down. Not scroll-linked by design — the connection state is
        // relevant regardless of where you've scrolled to.
        .overlay(alignment: .topLeading) {
            if manager.transportBackend == .cloud {
                remoteModePill
                    .padding(.leading, 16)
                    .padding(.top, 16)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            homeActionZone
                .padding(.trailing, 20)
                // The mini-player no longer lives inside this view's bounds —
                // it's attached above the tab bar via safeAreaInset / the
                // iOS 26 tab accessory, so the ScrollView's overlay already
                // bottoms out just above the mini-player. A small breathing
                // margin is all that's needed.
                .padding(.bottom, 16)
        }
        .toast($homeToastMessage)
        .onAppear {
            Task { await manager.refreshAllGroupStatuses() }
        }
    }

    private var remoteModePill: some View {
        Label("Remote", systemImage: "cloud.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.12), in: Capsule())
            .accessibilityLabel("Controlling via Sonos Cloud")
    }

    private var unreachableBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Speaker unreachable")
                    .font(.subheadline.weight(.semibold))
                Text("Pull down to retry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { _ = await manager.probeBackend() }
            } label: {
                if manager.isProbing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.top, 8)
    }

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

    private var transferZone: some View {
        Menu {
            Button {
                transferAppleMusicToSonos()
            } label: {
                Label("iPhone -> Sonos", systemImage: "iphone.and.arrow.forward")
            }

            Button {
                transferSonosToIPhone()
            } label: {
                Label("Sonos -> iPhone", systemImage: "speaker.wave.2.fill")
            }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(isTransferringPlayback ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                    Circle()
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1.5)
                    if isTransferringPlayback {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.left.arrow.right")
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
        .disabled(isTransferringPlayback || !manager.isConfigured)
        .accessibilityLabel("Transfer playback")
    }

    private var ungroupZone: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(isSeparateZoneTargeted ? Color.red.opacity(0.85) : Color.white.opacity(0.08))
                Circle()
                    .strokeBorder(
                        isSeparateZoneTargeted ? Color.red : Color.white.opacity(0.2),
                        lineWidth: 1.5
                    )
                Image(systemName: "minus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSeparateZoneTargeted ? .white : .white.opacity(0.35))
            }
            .frame(width: 52, height: 52)
            .scaleEffect(isSeparateZoneTargeted ? 1.15 : 1.0)

            Text("UNGROUP")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(isSeparateZoneTargeted ? .red : .white.opacity(0.25))
        }
    }

    @ViewBuilder
    private func dragPreview(_ group: SpeakerGroupStatus) -> some View {
        let visibleMembers = group.members
            .filter { !$0.isInvisible }
            .sorted { a, _ in a.id == group.coordinator.id }
        let accent = manager.groupAlbumColors[group.id] ?? .secondary

        HStack(spacing: 10) {
            if let img = manager.groupAlbumImages[group.id] {
                Image(uiImage: img)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(0.15))
                    .frame(width: 36, height: 36)
                    .overlay { Image(systemName: "hifispeaker.fill").font(.caption).foregroundStyle(.secondary) }
            }
            Text(visibleMembers.map(\.name).joined(separator: " + "))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
    }

    private func transferAppleMusicToSonos() {
        guard !isTransferringPlayback else { return }
        isTransferringPlayback = true

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
            isTransferringPlayback = false
        }
    }

    private func transferSonosToIPhone() {
        guard !isTransferringPlayback else { return }
        isTransferringPlayback = true

        Task {
            do {
                let result = try await searchManager.transferSonosAppleMusicToPhone(manager: manager)
                if let warning = result.warningMessage {
                    manager.errorMessage = warning
                    $homeToastMessage.showToast(warning)
                } else {
                    $homeToastMessage.showToast("Transferred to iPhone")
                }
            } catch {
                manager.errorMessage = error.localizedDescription
                $homeToastMessage.showToast(error.localizedDescription)
            }
            isTransferringPlayback = false
        }
    }

    private func speakerGroupCard(_ group: SpeakerGroupStatus) -> some View {
        SpeakerGroupCardView(group: group, manager: manager)
    }

    // MARK: - Setup (Auto-Discovery)

    private var setupView: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .padding(.bottom, 16)

            Text("Connect to Sonos")
                .font(.title2.bold())
                .padding(.bottom, 6)

            if manager.discovery.isScanning && manager.discovery.discoveredSpeakers.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching your network…")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.bottom, 20)
            } else if manager.discovery.discoveredSpeakers.isEmpty {
                Text("No Sonos speakers found on this network.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.bottom, 12)
                Button { manager.discovery.startScan() } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .padding(.bottom, 20)
            } else {
                // Speakers found → we auto-connect to the first coordinator
                // so the user lands on the player straight away. All other
                // speakers still show up via topology once we're in. Tapping
                // a specific row below still works as an explicit override.
                HStack(spacing: 8) {
                    if manager.isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Text(autoConnectMessage)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.bottom, 16)
            }

            if !manager.discovery.discoveredSpeakers.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(manager.discovery.discoveredSpeakers.enumerated()), id: \.element.id) { idx, speaker in
                        Button {
                            Task { await manager.connectFromDiscovery(speaker) }
                        } label: {
                            HStack {
                                Image(systemName: "hifispeaker.fill")
                                    .foregroundStyle(.tint).frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(speaker.name).fontWeight(.medium)
                                    Text(speaker.ipAddress).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if manager.isLoading && manager.selectedSpeaker?.id == speaker.id {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 12).padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                        if idx < manager.discovery.discoveredSpeakers.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                if manager.discovery.isScanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Still scanning…").font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
            }

            Spacer()

            Button { showManualEntry.toggle() } label: {
                Text("Enter IP address manually").font(.footnote)
            }.padding(.bottom, 4)

            if showManualEntry {
                HStack(spacing: 8) {
                    TextField("192.168.1.100", text: $newSpeakerIP)
                        .textFieldStyle(.roundedBorder).keyboardType(.decimalPad)
                    Button("Connect") { Task { await manager.addSpeaker(ip: newSpeakerIP) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(newSpeakerIP.isEmpty || manager.isLoading)
                }
                .padding(.horizontal, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let error = manager.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.center).padding(.horizontal).padding(.top, 8)
            }

            Spacer().frame(height: 32)
        }
        .animation(.easeInOut(duration: 0.25), value: manager.discovery.discoveredSpeakers.count)
        .animation(.easeInOut(duration: 0.25), value: showManualEntry)
        .onChange(of: manager.discovery.discoveredSpeakers.count) { _, _ in
            attemptAutoConnect()
        }
        .onAppear { attemptAutoConnect() }
    }

    /// Picks the first coordinator from discovery and connects immediately.
    /// Safe to call repeatedly — the `didAutoConnect` latch + `isLoading` /
    /// `isConfigured` guards stop duplicate attempts.
    private func attemptAutoConnect() {
        guard !didAutoConnect,
              !manager.isConfigured,
              !manager.isLoading,
              let preferred = manager.discovery.discoveredSpeakers.first(where: \.isCoordinator)
                  ?? manager.discovery.discoveredSpeakers.first
        else { return }
        didAutoConnect = true
        Task { await manager.connectFromDiscovery(preferred) }
    }

    private var autoConnectMessage: String {
        let speakers = manager.discovery.discoveredSpeakers
        let target = speakers.first(where: \.isCoordinator) ?? speakers.first
        if manager.isLoading, let name = target?.name {
            return "Connecting to \(name)…"
        }
        let n = speakers.count
        return n == 1 ? "Found 1 speaker" : "Found \(n) speakers"
    }

}

// MARK: - Speaker Group Card

private struct SpeakerGroupCardView: View {
    let group: SpeakerGroupStatus
    @Bindable var manager: SonosManager

    @State private var premuteGroupVolume: Int?
    @State private var premuteMemberVolumes: [String: Int] = [:]
    @State private var showMemberVolumes = false

    private var expandButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                showMemberVolumes.toggle()
            }
            if showMemberVolumes {
                Task { await manager.fetchMemberVolumes() }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .rotationEffect(.degrees(showMemberVolumes ? 180 : 0))
                .frame(width: 20, height: 20)
                .background(.white.opacity(showMemberVolumes ? 0.2 : 0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3), value: showMemberVolumes)
    }

    private var isCurrentGroup: Bool {
        group.coordinator.id == manager.selectedSpeaker?.id
            || group.coordinator.groupId == manager.selectedSpeaker?.groupId
    }
    private var accent: Color { manager.groupAlbumColors[group.id] ?? .secondary }
    private var artImage: UIImage? { manager.groupAlbumImages[group.id] }
    private var visibleMembers: [SonosPlayer] {
        group.members.filter { !$0.isInvisible }.sorted { a, _ in a.id == group.coordinator.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Top row: art + track info + waveform ──
            Button {
                if !isCurrentGroup {
                    Task { await manager.selectSpeaker(group.coordinator) }
                }
            } label: {
                HStack(spacing: 12) {
                    if group.trackInfo?.source == .tv {
                        // TV input never has cover art — show a dedicated
                        // TV glyph instead of the generic speaker fallback
                        // so the row stays unambiguous when the user is on
                        // soundbar/HDMI input.
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(0.1))
                            .frame(width: 44, height: 44)
                            .overlay {
                                Image(systemName: "tv")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                    } else if let img = artImage {
                        Image(uiImage: img)
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(0.1))
                            .frame(width: 44, height: 44)
                            .overlay {
                                Image(systemName: "hifispeaker.fill")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(visibleMembers.map(\.name).joined(separator: " + "))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        if let track = group.trackInfo, track.source == .tv {
                            // `getPositionInfo` already populates `artist`
                            // with the format string for TV input
                            // ("Dolby Atmos · MAT" / "Multichannel PCM · 5.1"
                            // / "No signal"), so we render the same
                            // "title — subtitle" pattern as music rows
                            // without any TV-specific branching.
                            Text("\(track.title) — \(track.artist)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if let track = group.trackInfo, track.title != "Unknown" {
                            Text("\(track.title) — \(track.artist)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text("Idle")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    CircularProgressPlayButton(
                        isPlaying: group.transportState == .playing,
                        progress: {
                            if isCurrentGroup, manager.durationSeconds > 0 {
                                return manager.positionSeconds / manager.durationSeconds
                            }
                            if let t = group.trackInfo, t.durationSeconds > 0 {
                                return t.positionSeconds / t.durationSeconds
                            }
                            return 0
                        }(),
                        accent: isCurrentGroup ? accent : .white.opacity(0.55),
                        size: 32,
                        ringWidth: 2.5
                    ) {
                        Task {
                            await manager.togglePlayPauseForGroup(
                                groupID: group.id,
                                coordinatorIP: group.coordinator.ipAddress,
                                currentState: group.transportState
                            )
                        }
                    }
                }
                // Without this the outer Button only counts taps on the
                // rendered subviews (art / text / play button); the
                // `Spacer()` gap between title and the circular play
                // button silently swallows touches, so tapping the
                // empty middle of the card does nothing. Forcing a
                // rectangular hit-test region makes the whole row
                // switch speakers as expected.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // ── Volume section: master (collapsed) or per-member (expanded) ──
            if !showMemberVolumes {
                // Master / group volume row
                HStack(spacing: 10) {
                    Image(systemName: group.volume == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            let newVol = max(0, group.volume - 2)
                            Task {
                                await manager.setVolumeForGroup(
                                    groupID: group.id,
                                    coordinatorIP: group.coordinator.ipAddress,
                                    newVolume: newVol
                                )
                            }
                        }
                        .onLongPressGesture {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            if group.volume > 0 {
                                premuteGroupVolume = group.volume
                                Task {
                                    await manager.setVolumeForGroup(
                                        groupID: group.id,
                                        coordinatorIP: group.coordinator.ipAddress,
                                        newVolume: 0
                                    )
                                }
                            } else if let saved = premuteGroupVolume {
                                premuteGroupVolume = nil
                                Task {
                                    await manager.setVolumeForGroup(
                                        groupID: group.id,
                                        coordinatorIP: group.coordinator.ipAddress,
                                        newVolume: saved
                                    )
                                }
                            }
                        }

                    GroupVolumeBar(volume: group.volume) { step in
                        let newVol = min(100, max(0, group.volume + step))
                        Task {
                            await manager.setVolumeForGroup(
                                groupID: group.id,
                                coordinatorIP: group.coordinator.ipAddress,
                                newVolume: newVol
                            )
                        }
                    }

                    HStack(spacing: 4) {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            let newVol = min(100, group.volume + 2)
                            Task {
                                await manager.setVolumeForGroup(
                                    groupID: group.id,
                                    coordinatorIP: group.coordinator.ipAddress,
                                    newVolume: newVol
                                )
                            }
                        } label: {
                            Text("\(group.volume)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(width: 22, height: 28, alignment: .center)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if visibleMembers.count > 1 {
                            expandButton
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 2)
                .padding(.bottom, 8)
                .transition(.opacity)
            } else {
                // Per-member volume rows (master hidden)
                VStack(spacing: 0) {
                    ForEach(visibleMembers) { member in
                        let vol = manager.memberVolumes[member.ipAddress] ?? 0
                        HStack(spacing: 8) {
                            Text(member.name)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                                .frame(width: 62, alignment: .leading)

                            Image(systemName: vol == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.35))
                                .frame(width: 14)
                                .contentShape(Rectangle())
                                .onLongPressGesture {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    if vol > 0 {
                                        premuteMemberVolumes[member.ipAddress] = vol
                                        Task { await manager.setMemberVolume(ip: member.ipAddress, volume: 0) }
                                    } else if let saved = premuteMemberVolumes[member.ipAddress] {
                                        premuteMemberVolumes[member.ipAddress] = nil
                                        Task { await manager.setMemberVolume(ip: member.ipAddress, volume: saved) }
                                    }
                                }
                                .animation(.easeInOut, value: vol)

                            GroupVolumeBar(volume: vol) { step in
                                let nv = min(100, max(0, vol + step))
                                Task { await manager.setMemberVolume(ip: member.ipAddress, volume: nv) }
                            }

                            // Volume number (center-aligned) + collapse button on last row
                            HStack(spacing: 4) {
                                Text("\(vol)")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.4))
                                    .frame(width: 22, alignment: .center)
                                // Collapse chevron on last member, invisible placeholder on others
                                if member.id == visibleMembers.last?.id {
                                    expandButton
                                } else {
                                    Color.clear.frame(width: 20, height: 20)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                    }
                }
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(isCurrentGroup ? accent.opacity(0.12) : Color.white.opacity(0.06))
        }
        .overlay {
            if isCurrentGroup {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(accent.opacity(0.3), lineWidth: 1)
            }
        }
        // Re-fetch member volumes whenever group master volume changes while panel is open
        .onChange(of: group.volume) { _, _ in
            guard showMemberVolumes else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                await manager.fetchMemberVolumes()
            }
        }
    }
}

// MARK: - Circular Progress Play Button

private struct CircularProgressPlayButton: View {
    var isPlaying: Bool
    var progress: Double       // 0 … 1
    var accent: Color
    var size: CGFloat
    var ringWidth: CGFloat = 3
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Track ring
                Circle()
                    .stroke(accent.opacity(0.22), lineWidth: ringWidth)
                // Progress ring — animates linearly with each position tick
                Circle()
                    .trim(from: 0, to: max(0, min(1, progress)))
                    .stroke(accent, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)
                // Icon
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Group Volume Bar (tap left = −2, tap right = +2)

private struct GroupVolumeBar: View {
    var volume: Int
    var onStep: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let progress = min(max(Double(volume) / 100.0, 0), 1)
            let thumbX = geo.size.width * progress
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.12))
                    .frame(height: 4)
                Capsule()
                    .fill(.white.opacity(0.55))
                    .frame(width: max(0, thumbX), height: 4)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { gesture in
                        guard abs(gesture.translation.width) < 6 else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onStep(gesture.startLocation.x < thumbX ? -2 : 2)
                    }
            )
        }
        .frame(height: 28)
    }
}

// MARK: - Now Playing Full-Screen Overlay

struct NowPlayingOverlay: View {
    @Bindable var manager: SonosManager
    var searchManager: SearchManager
    @State private var volumeSliderValue: Double = 0
    @State private var isDraggingVolume = false
    @State private var premuteVolume: Int?
    @State private var scrubPosition: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var dragDownOffset: CGFloat = 0
    @State private var nowPlayingInfo: SonosCloudAPI.NowPlayingResponse?
    @State private var lastFetchedTrackURI: String?
    /// Handle on the in-flight NowPlaying fetch so we can cancel it when
    /// the track changes again before the previous lookup resolves. Without
    /// this, a slow fetch for track A could land after track B's fetch and
    /// stomp the newer artist/album data, or — worse — the user could tap
    /// the album/artist link while stale `nowPlayingInfo` still holds the
    /// previous song, sending them to the wrong detail page.
    @State private var nowPlayingFetchTask: Task<Void, Never>?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let isLandscape = geo.size.width > geo.size.height
                if isLandscape {
                    landscapeLayout(geo: geo)
                } else {
                    portraitLayout(geo: geo)
                }
            }
            .background { artBackground }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .offset(y: dragDownOffset)
        .ignoresSafeArea(edges: .bottom)
        .onChange(of: manager.showFullPlayer) { _, isOpen in
            if !isOpen { dragDownOffset = 0 }
        }
        .onChange(of: manager.trackInfo?.trackURI) { _, newURI in
            guard let uri = newURI, uri != lastFetchedTrackURI else { return }
            lastFetchedTrackURI = uri
            // Immediately blank the stale artist/album payload so the
            // header's NavigationLinks fall back to plain Text until the
            // new track's response lands. If we skip this, tapping the
            // album or artist right after an external control point
            // (official Sonos app, voice assistant, etc.) changes the
            // song would still push the *previous* song's detail view.
            nowPlayingInfo = nil
            nowPlayingFetchTask?.cancel()
            nowPlayingFetchTask = Task {
                // Keep SearchManager's speaker IP in sync before probing —
                // if the selected speaker just became available, this lets
                // `ensureMusicServicesPopulated` reach the speaker.
                searchManager.configure(speakerIP: manager.selectedSpeaker?.playbackIP)
                // Ensure the local-sid → cloud-service-id table is built
                // before we ask NowPlaying for artist / album ids.
                // Otherwise `fetchNowPlaying` bails early and the
                // artist / album text renders as plain Text (non-tappable)
                // until the user visits the Browse tab.
                await searchManager.probeLinkedServices()
                guard !Task.isCancelled else { return }
                await fetchNowPlaying(trackURI: uri)
            }
        }
        .onChange(of: manager.selectedSpeaker?.playbackIP) { _, newIP in
            // Selected speaker's IP just resolved (discovery finished,
            // user switched speakers, etc.) — reconfigure SearchManager
            // and (re-)build the sid mapping using the newly reachable
            // host, unblocking the artist / album links.
            guard let ip = newIP, !ip.isEmpty else { return }
            searchManager.configure(speakerIP: ip)
            Task {
                if !searchManager.hasFinishedProbing {
                    await searchManager.probeLinkedServices()
                } else {
                    await searchManager.refreshServiceIdMappingIfNeeded()
                }
                // Mapping may have just become available. If the
                // initial `fetchNowPlaying` ran with an empty mapping
                // and bailed, the `onChange(trackURI)` above won't
                // retry because `lastFetchedTrackURI` is already set
                // to the current URI. Force a retry here so the
                // artist / album links pick up without the user
                // having to tap a new song first.
                if nowPlayingInfo == nil, let uri = manager.trackInfo?.trackURI {
                    await fetchNowPlaying(trackURI: uri)
                }
            }
        }
        .task {
            // Feed SearchManager the current speaker IP *before* we probe
            // linked services so `ensureMusicServicesPopulated` has a
            // reachable host to hit — otherwise the local-sid ↔ cloud-sid
            // mapping never builds on first launch (user never visits
            // Browse), and the artist / album NavigationLinks below end
            // up non-tappable until the user flips to the Browse tab.
            searchManager.configure(speakerIP: manager.selectedSpeaker?.playbackIP)
            await searchManager.probeLinkedServices()
            if let uri = manager.trackInfo?.trackURI, uri != lastFetchedTrackURI {
                lastFetchedTrackURI = uri
                await fetchNowPlaying(trackURI: uri)
            }
        }
        .sheet(isPresented: $manager.showingSpeakerPicker) {
            SpeakerPickerView(manager: manager)
        }
        .sheet(isPresented: $manager.showingQueue) {
            QueueView(manager: manager)
        }
    }

    // MARK: - Portrait Layout

    private func portraitLayout(geo: GeometryProxy) -> some View {
        let h = geo.size.height
        // Full-bleed square cover. Cap at h * 0.55 as a safety on small
        // devices (e.g. SE) where a width-sized square would crowd out the
        // transport row below; on every modern iPhone width wins this min.
        let artSz = max(1, min(geo.size.width, h * 0.55))
        let s = max(0.5, h / 760)

        return VStack(spacing: 0) {
            albumArtView(size: artSz)

            trackInfoView
                .padding(.horizontal, 32)
                .padding(.top, 22 * s)

            progressView
                .padding(.top, 18 * s)

            // TV input has no transport actions worth surfacing
            // (`GetCurrentTransportActions` returns just `Set, Play` and the
            // soundbar can't seek or skip a live stream). Swap the row for
            // the soundbar EQ toggles so the slot doesn't feel empty.
            if manager.trackInfo?.source == .tv {
                soundbarEQPanel
                    .padding(.top, 18 * s)
                    .padding(.horizontal, 32)
            } else {
                playbackControls
                    .padding(.top, 22 * s)
            }

            volumeControl
                .padding(.top, manager.trackInfo?.source == .tv ? 18 * s : 22 * s)

            // Queue is meaningless for TV input (the soundbar isn't playing
            // a queue, it's passing through HDMI/optical), so hide the list
            // button and let the speaker picker fill the row.
            bottomActions(showQueue: manager.trackInfo?.source != .tv)
                .padding(.top, 16 * s)

            Spacer(minLength: 0)

            errorBanner
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Drag handle floats above the cover so the artwork can take the
        // full top of the screen without losing the pull-to-dismiss
        // affordance.
        .overlay(alignment: .top) {
            dragHandle
                .padding(.top, 8)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(dismissDragGesture)
    }

    // MARK: - Landscape Layout (player left | queue right)

    private func landscapeLayout(geo: GeometryProxy) -> some View {
        let leftW = geo.size.width * 0.55
        let topPad: CGFloat = 12
        let fixedBelow: CGFloat = 196
        let artSz = max(80, min(leftW * 0.38, geo.size.height - topPad - fixedBelow))

        return HStack(spacing: 0) {
            // ── Left panel: player (gesture lives here to avoid QueueView List interference) ──
            VStack(spacing: 0) {
                dragHandle
                    .padding(.top, 10)

                Spacer(minLength: topPad)

                HStack(alignment: .center, spacing: 16) {
                    albumArtView(size: artSz)

                    VStack(alignment: .leading) {
                        Spacer(minLength: 0)
                        Text(manager.trackInfo?.title ?? "Not Playing")
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        // Hide artist/album rows for TV — the format pill in
                        // `tvFormatPanel` already conveys the codec.
                        if manager.trackInfo?.source != .tv {
                            Text(manager.trackInfo?.artist ?? "—")
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                                .padding(.top, 3)
                            Text(manager.trackInfo?.album ?? "")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                                .padding(.top, 1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: artSz, alignment: .leading)
                }
                .padding(.horizontal, 20)

                progressContent
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                if manager.trackInfo?.source == .tv {
                    soundbarEQPanel
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                } else {
                    playbackControls.padding(.top, 10)
                }
                volumeControl.padding(.top, 6)
                bottomActions(showQueue: false).padding(.top, 6)

                Spacer(minLength: 0)
                errorBanner
            }
            .frame(width: leftW)
            .contentShape(Rectangle())
            .simultaneousGesture(dismissDragGesture)

            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(width: 0.5)

            // ── Right panel: queue ──
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("QUEUE")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1)
                    if !manager.isPlayingFromQueue {
                        Text("· NOT IN USE")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(0.5)
                    }
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)

                QueueView(manager: manager, showNavigation: false)
            }
            .frame(maxWidth: .infinity)
            .onAppear {
                if manager.queue.isEmpty {
                    Task { await manager.loadQueue() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Dismiss Drag Gesture

    /// Global coordinate space: offset is at body level (outside clipShape/padding),
    /// gestures are attached inside layouts — global coords keep translation stable.
    private var dismissDragGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { v in
                if v.translation.height > 0 {
                    dragDownOffset = v.translation.height
                }
            }
            .onEnded { v in
                if v.translation.height > 120 || v.predictedEndTranslation.height > 300 {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        manager.showFullPlayer = false
                    }
                }
                withAnimation(.spring(response: 0.3)) {
                    dragDownOffset = 0
                }
            }
    }

    // MARK: - Drag Handle

    private var dragHandle: some View {
        Capsule()
            .fill(.white.opacity(0.2))
            .frame(width: 36, height: 5)
    }

    // MARK: - Background

    @ViewBuilder
    private var artBackground: some View {
        // Apple Music-style "water reflection" backdrop: a vertically
        // flipped, heavily blurred copy of the cover lives below the
        // sharp cover. Because the flipped image's top edge IS the
        // original cover's bottom edge, the seam at the cover's lower
        // boundary is automatically continuous in colour — no need for
        // a hand-tuned gradient anchor.
        let dominant = manager.albumArtDominantColor ?? Color(white: 0.10)
        GeometryReader { geo in
            let coverHeight = min(geo.size.width, geo.size.height * 0.55)
            let coverBottomY = geo.safeAreaInsets.top + coverHeight
            let totalH = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            let coverBottomFrac = max(0.30, min(0.7, coverBottomY / max(totalH, 1)))
            ZStack {
                // Fallback while album art is loading.
                dominant

                if let image = manager.albumArtImage {
                    VStack(spacing: 0) {
                        // Reserve the area the sharp cover will occupy so the
                        // flipped reflection only fills below it.
                        Color.clear.frame(height: coverBottomY)
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .blur(radius: 60)
                            .scaleEffect(x: 1, y: -1)
                            .id(manager.trackInfo?.albumArtURL)
                            .transition(.opacity)
                    }
                }

                // Subtle dark vignette so transport text / buttons remain
                // legible even when the reflected art is bright. Stays
                // clear at the seam so the mirror effect reads cleanly.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .clear, location: min(0.95, coverBottomFrac + 0.06)),
                        .init(color: .black.opacity(0.35), location: min(0.97, coverBottomFrac + 0.22)),
                        .init(color: .black.opacity(0.6), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: manager.trackInfo?.albumArtURL)
        .animation(.easeInOut(duration: 0.8), value: manager.albumArtDominantColor)
    }

    // MARK: - Album Art

    @ViewBuilder
    private func albumArtView(size: CGFloat) -> some View {
        let isTV = manager.trackInfo?.source == .tv
        let tvFormat = manager.trackInfo?.tvFormat
        let tvHasSignal = tvFormat?.hasSignal ?? false
        // Atmos streams glow blue (matches the BadgeDolbyAtmos accent
        // family); everything else falls back to a neutral white sheen so
        // the TV slot doesn't blend into the dark background.
        let tvGlowColor: Color = (tvFormat?.isAtmos == true)
            ? Color(red: 0.36, green: 0.55, blue: 1.0)
            : .white
        return ZStack {
            // Edge-to-edge placeholder; no rounding now that the cover
            // pins to the screen edges. The TV-mode breathing halo and
            // glyph render on top of this backdrop unchanged.
            Rectangle().fill(.quaternary)
                .overlay {
                    // Subtle "audio is flowing" breathing halo behind the
                    // TV glyph — only when the bar reports a live stream.
                    // Driven by `TimelineView` so it survives navigation +
                    // backgrounding without us hand-managing a state var.
                    if isTV && tvHasSignal {
                        TimelineView(.animation(minimumInterval: 0.03, paused: false)) { ctx in
                            let t = ctx.date.timeIntervalSinceReferenceDate
                            // ~3s breathing cycle, eased so the peaks feel
                            // like inhale/exhale rather than a metronome.
                            let phase = (sin(t * (.pi * 2 / 3.0)) + 1) / 2
                            RadialGradient(
                                colors: [
                                    tvGlowColor.opacity(0.18 + 0.10 * phase),
                                    tvGlowColor.opacity(0.04),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: size * 0.55
                            )
                            .blur(radius: 30)
                            .blendMode(.plusLighter)
                            .allowsHitTesting(false)
                        }
                    }
                    // For TV input there's no album art — swap the music-note
                    // placeholder for a TV glyph so the now-playing screen
                    // immediately reads as "watching" instead of "buffering".
                    Image(systemName: isTV ? "tv" : "music.note")
                        .font(.system(size: isTV ? 96 : 60, weight: isTV ? .light : .regular))
                        .foregroundStyle(.tertiary)
                }

            if !isTV, let image = manager.albumArtImage {
                ZStack(alignment: .bottomLeading) {
                    Image(uiImage: image)
                        .resizable().aspectRatio(1, contentMode: .fit)

                    if verticalSizeClass != .compact,
                       let source = manager.trackInfo?.source, source != .unknown {
                        SourceBadgeView(source: source, tintColor: manager.albumArtDominantColor)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 14)
                    }
                }
                .id(manager.trackInfo?.albumArtURL)
                .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        // For TV input, reuse the streaming-source badge slot to show LIVE/IDLE.
        .overlay(alignment: .bottomLeading) {
            if isTV && verticalSizeClass != .compact {
                tvSignalBadge(hasSignal: tvHasSignal)
                    .padding(10)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: manager.trackInfo?.albumArtURL)
    }

    /// Pill that mirrors `SourceBadgeView` proportions — kept here rather
    /// than in `SourceBadgeView` itself because the LIVE/IDLE state is
    /// strictly TV-specific and shouldn't pollute the music badge enum.
    @ViewBuilder
    private func tvSignalBadge(hasSignal: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(hasSignal ? Color.red : Color.white.opacity(0.4))
                .frame(width: 6, height: 6)
                .opacity(hasSignal ? 1.0 : 0.6)
            Text(hasSignal ? "LIVE" : "IDLE")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hasSignal ? .white : .white.opacity(0.6))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(
            Capsule().stroke(
                hasSignal ? Color.red.opacity(0.6) : Color.white.opacity(0.25),
                lineWidth: 1)
        )
    }

    // MARK: - Track Info

    private var trackInfoView: some View {
        let isTV = manager.trackInfo?.source == .tv
        return VStack(spacing: 4) {
            Text(manager.trackInfo?.title ?? "Not Playing")
                .font(.title3.bold()).foregroundStyle(.white).lineLimit(1)
                // Safety-net shadow: keeps the title legible even if the
                // page tint underneath happens to be near-white (covers
                // with bright bottom edges).
                .shadow(color: .black.opacity(0.45), radius: 6, y: 1)

            // For TV input the codec ("Dolby Atmos · MAT") is already
            // shown by the format badge in `tvFormatPanel` below, so
            // skip the artist/album subtitle rows entirely — repeating
            // it here just creates visual noise and the user already
            // complained about the duplicate Dolby Atmos label.
            if !isTV {
                if let artistNav = artistBrowseItem {
                    NavigationLink {
                        ArtistDetailView(artistItem: artistNav, searchManager: searchManager, manager: manager)
                    } label: {
                        Text(manager.trackInfo?.artist ?? "—")
                            .font(.body).foregroundStyle(manager.albumArtDominantColor ?? .white.opacity(0.7)).lineLimit(1)
                            .shadow(color: .black.opacity(0.4), radius: 5, y: 1)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(manager.trackInfo?.artist ?? "—")
                        .font(.body).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        .shadow(color: .black.opacity(0.4), radius: 5, y: 1)
                }

                if let albumNav = albumBrowseItem {
                    NavigationLink {
                        AlbumDetailView(albumItem: albumNav, searchManager: searchManager, manager: manager)
                    } label: {
                        Text(manager.trackInfo?.album ?? "")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(manager.trackInfo?.album ?? "")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                }
            }
        }
    }

    // MARK: - Now Playing Navigation

    private var artistBrowseItem: BrowseItem? {
        if let artist = nowPlayingInfo?.item?.artists?.first,
           let objectId = artist.objectId,
           let serviceId = nowPlayingInfo?.item?.resource?.id?.serviceId,
           let accountId = nowPlayingInfo?.item?.resource?.id?.accountId {
            return searchManager.makeArtistItem(
                objectId: objectId, name: artist.name ?? "",
                cloudServiceId: serviceId, accountId: accountId)
        }
        // Fallback for live radio: nowPlaying lookup failed (track id is the
        // radio station URI, not a song id) but we still have the artist
        // name from the broadcast metadata. Build a search-by-name artist
        // item so tapping navigates into ArtistDetailView, which already
        // resolves Apple Music artists by name via `searchService`.
        return liveStreamArtistBrowseItem
    }

    private var albumBrowseItem: BrowseItem? {
        if let item = nowPlayingInfo?.item,
           let albumId = item.albumId,
           let serviceId = item.resource?.id?.serviceId,
           let accountId = item.resource?.id?.accountId {
            return searchManager.makeAlbumItem(
                objectId: albumId,
                title: item.albumName ?? manager.trackInfo?.album ?? "",
                artist: manager.trackInfo?.artist ?? "",
                artURL: nowPlayingInfo?.images?.tile1x1,
                cloudServiceId: serviceId, accountId: accountId)
        }
        // Same fallback as `artistBrowseItem`: in a live broadcast we have
        // the album name from broadcast metadata even if the per-track
        // nowPlaying lookup couldn't run, so feed it to AlbumDetailView and
        // let its existing search-by-name path resolve the real album id.
        return liveStreamAlbumBrowseItem
    }

    /// Build an artist `BrowseItem` for Apple Music live broadcasts where we
    /// only have the artist *name* (no per-track id). The detail view's
    /// `searchService` flow resolves the real artist id from the name. We
    /// pull `sid` / `sn` from whatever URI the speaker is currently on
    /// (e.g. `x-sonosapi-radio:radio:rsa.LiveRadio1?sid=204&sn=2`).
    private var liveStreamArtistBrowseItem: BrowseItem? {
        guard let artistName = manager.trackInfo?.artist, !artistName.isEmpty,
              let ids = liveStreamCloudIds else { return nil }
        return searchManager.makeArtistItem(
            objectId: artistName,
            name: artistName,
            cloudServiceId: ids.cloudSid,
            accountId: ids.accountId)
    }

    private var liveStreamAlbumBrowseItem: BrowseItem? {
        guard let albumName = manager.trackInfo?.album, !albumName.isEmpty,
              let artistName = manager.trackInfo?.artist, !artistName.isEmpty,
              let ids = liveStreamCloudIds else { return nil }
        return searchManager.makeAlbumItem(
            objectId: albumName,
            title: albumName,
            artist: artistName,
            artURL: manager.trackInfo?.albumArtURL,
            cloudServiceId: ids.cloudSid,
            accountId: ids.accountId)
    }

    private var liveStreamCloudIds: (cloudSid: String, accountId: String)? {
        guard let trackURI = manager.trackInfo?.trackURI else { return nil }
        var localSid: Int?
        var sn: String?
        if let queryPart = trackURI.split(separator: "?").last {
            for param in queryPart.split(separator: "&") {
                let kv = param.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                if kv[0] == "sid" { localSid = Int(kv[1]) }
                if kv[0] == "sn" { sn = String(kv[1]) }
            }
        }
        guard let sid = localSid,
              let cloudSid = searchManager.cloudServiceId(forLocalSid: sid),
              let accountId = sn else { return nil }
        return (cloudSid, accountId)
    }

    private func fetchNowPlaying(trackURI: String) async {
        guard let token = await SonosAuth.shared.validAccessToken(),
              let householdId = SonosAuth.shared.householdId else { return }

        var localSid: Int?
        var accountId = "2"
        if let queryPart = trackURI.split(separator: "?").last {
            for param in queryPart.split(separator: "&") {
                let kv = param.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                if kv[0] == "sid" { localSid = Int(kv[1]) }
                if kv[0] == "sn" { accountId = String(kv[1]) }
            }
        }

        guard let sid = localSid,
              let cloudSid = searchManager.cloudServiceId(forLocalSid: sid) else {
            nowPlayingInfo = nil
            return
        }

        guard let objectId = SonosAppleMusicTrackResolver
            .cloudTrackObjectIDForNowPlaying(fromTrackURI: trackURI) else {
            nowPlayingInfo = nil
            return
        }

        do {
            let response = try await SonosCloudAPI.nowPlaying(
                token: token, householdId: householdId,
                serviceId: cloudSid, accountId: accountId,
                trackObjectId: objectId)
            // Drop the result if the current track has moved on during the
            // request — we don't want an older lookup overwriting a newer
            // song's info when two track-changes happen back-to-back.
            guard manager.trackInfo?.trackURI == trackURI else { return }
            nowPlayingInfo = response
        } catch {
            SonosLog.error(.nowPlaying, "Fetch failed: \(error)")
            if manager.trackInfo?.trackURI == trackURI {
                nowPlayingInfo = nil
            }
        }
    }

    // MARK: - Progress

    /// Inner progress content — no outer padding, usable in both portrait and landscape info column.
    @ViewBuilder
    private var progressContent: some View {
        if manager.trackInfo?.source == .tv {
            tvFormatPanel
        } else if manager.trackInfo?.isLiveStream == true {
            liveProgressContent
        } else {
            musicProgressContent
        }
    }

    /// Live broadcast indicator — replaces the seek bar for streams that
    /// have no fixed duration (Apple Music 1, TuneIn live stations,
    /// internet radio, line-in / AirPlay). Mimics Apple Music's player:
    /// thin rule on each side with a centered "LIVE" pill.
    private var liveProgressContent: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(.white.opacity(0.18))
                .frame(height: 3)
            Text("LIVE")
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.78))
            Capsule()
                .fill(.white.opacity(0.18))
                .frame(height: 3)
        }
        .frame(height: 18)
        .padding(.horizontal, 4)
    }

    /// TV input has no scrubbable timeline. The signal status now lives
    /// on the album-art bottom-left (next to where the music badge would
    /// be), so this row only needs to carry the audio format chip.
    /// The slot height is fixed so switching between signal/no-signal
    /// doesn't shift everything below it.
    @ViewBuilder
    private var tvFormatPanel: some View {
        let format = manager.trackInfo?.tvFormat
        HStack {
            Spacer(minLength: 0)
            // For Atmos: `[badge] <variant>` (e.g. `[●] TrueHD`); we drop
            // channel layout because Atmos is object-based and the "2.0"
            // in "MAT 2.0" is a protocol version, not a channel count.
            //
            // For non-Atmos: codec + channel layout as separate slots
            // (e.g. `Multichannel PCM · 5.1`).
            if let format, format.hasSignal {
                HStack(spacing: 4) {
                    if format.isAtmos {
                        Image("BadgeDolbyAtmos")
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .frame(height: 11)
                            .accessibilityLabel("Dolby Atmos")
                        if let variant = format.atmosVariant {
                            Text(variant)
                                .font(.system(size: 9, weight: .semibold))
                        }
                    } else {
                        Text(format.codec)
                            .font(.system(size: 9, weight: .semibold))
                        if let layout = format.channelLayout {
                            Text("·")
                                .font(.system(size: 9))
                            Text(layout)
                                .font(.system(size: 9, weight: .medium).monospaced())
                        }
                    }
                }
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.white.opacity(0.08), in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .frame(height: 22)
    }

    /// Two square-ish cards side-by-side, mirroring the Sonos S2 app's TV
    /// audio panel: large glyph in the top-left, title + state stacked
    /// flush-bottom-left. No accent borders or fills — the active state
    /// just brightens the glyph and state text. Tap = toggle (Night Sound)
    /// or open level picker (Speech Enhancement).
    private var soundbarEQPanel: some View {
        HStack(spacing: 10) {
            nightSoundCard
            speechEnhancementCard
        }
    }

    private var nightSoundCard: some View {
        let isOn = manager.nightMode
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { await manager.toggleNightMode() }
        } label: {
            soundbarEQCard(
                iconName: isOn ? "moon.fill" : "moon",
                title: "Night Sound",
                stateText: isOn ? "On" : "Off",
                isOn: isOn
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Night Sound")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }

    private var speechEnhancementCard: some View {
        let level = manager.speechEnhancement
        // SF Symbol with a slash overlay when Off matches the Sonos
        // reference's "person with x" silhouette closely enough; the
        // filled variant for On reads as "speech is being enhanced".
        let icon = level.isOn ? "waveform.badge.mic" : "waveform.slash"
        return Menu {
            Picker("Speech Enhancement", selection: Binding(
                get: { manager.speechEnhancement },
                set: { newLevel in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { await manager.setSpeechEnhancement(newLevel) }
                }
            )) {
                ForEach(SpeechEnhancementLevel.allCases, id: \.self) { lvl in
                    Text(lvl.label).tag(lvl)
                }
            }
        } label: {
            soundbarEQCard(
                iconName: icon,
                title: "Speech Enhancement",
                stateText: level.label,
                isOn: level.isOn
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Speech Enhancement")
        .accessibilityValue(level.label)
    }

    /// Shared chrome for both EQ cards. Icon top-left, title + state pinned
    /// bottom-left. Height is **locked** to 92pt — without a hard cap the
    /// inner `Spacer` competes with the outer page `Spacer`s and the cards
    /// balloon to fill any leftover vertical slack, breaking the layout.
    private func soundbarEQCard(
        iconName: String,
        title: String,
        stateText: String,
        isOn: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: iconName)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white.opacity(isOn ? 0.95 : 0.55))
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isOn ? 1.0 : 0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(stateText)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(isOn ? 0.7 : 0.45))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 92)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.08))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Standard music timeline + audio-quality badge. Extracted so the TV-mode
    /// branch can swap in its own panel without touching the slider.
    private var musicProgressContent: some View {
        VStack(spacing: 4) {
            ThumblessSlider(
                value: Binding(
                    get: { isScrubbing ? scrubPosition : manager.positionSeconds },
                    set: { scrubPosition = $0; isScrubbing = true }
                ),
                range: 0...max(manager.durationSeconds, 1),
                thumbDragOnly: true
            ) { editing in
                if !editing {
                    isScrubbing = false
                    Task { await manager.seekTo(scrubPosition) }
                }
            }

            HStack {
                Text(SonosTime.display(isScrubbing ? scrubPosition : manager.positionSeconds))
                    .monospacedDigit()

                Spacer()

                if let quality = manager.trackInfo?.audioQuality {
                    // When a Dolby Atmos badge is present, the badge itself
                    // already reads "Dolby Atmos" — repeating it as text
                    // creates the duplicate the user complained about. Hand
                    // the label through `badgeCompanionLabel` which strips
                    // the redundant prefix (returning nil when nothing
                    // remains, e.g. plain music Atmos with no transport
                    // variant). Lossless/Hi-Res keep their full label since
                    // the badge is glyph-only.
                    let companion: String? = quality.badgeAssetImageName != nil
                        ? AudioQuality.badgeCompanionLabel(forQualityLabel: quality.label)
                        : quality.label
                    HStack(spacing: 4) {
                        if let badge = quality.badgeAssetImageName {
                            Image(badge)
                                .resizable()
                                .renderingMode(.template)
                                .scaledToFit()
                                .frame(height: 11)
                                .accessibilityLabel(quality.label)
                        }
                        if let companion {
                            Text(companion)
                                .font(.system(size: 9, weight: .semibold))
                        }
                        if let sr = quality.sampleRate, let bd = quality.bitDepth {
                            // Only draw the separator if there's a preceding
                            // text token; otherwise the dot looks orphaned
                            // sitting alone next to the badge.
                            if companion != nil {
                                Text("·")
                                    .font(.system(size: 9))
                            }
                            Text("\(bd)/\(sr / 1000)kHz")
                                .font(.system(size: 9, weight: .medium))
                        }
                    }
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.08), in: Capsule())
                }

                Spacer()

                Text(SonosTime.display(manager.durationSeconds))
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var progressView: some View {
        progressContent.padding(.horizontal, 32)
    }

    // MARK: - Playback Controls

    @ViewBuilder
    private var playbackControls: some View {
        if manager.trackInfo?.isLiveStream == true {
            liveBroadcastControls
        } else {
            standardPlaybackControls
        }
    }

    /// Live-stream variant: a single Stop/Play button. Skip / shuffle /
    /// repeat are intentionally hidden — the underlying transport doesn't
    /// honor them for live broadcasts and the official Apple Music UI
    /// presents the same pared-down layout.
    private var liveBroadcastControls: some View {
        let compact = verticalSizeClass == .compact
        let stopSize: CGFloat = compact ? 30 : 40
        let playFrame: CGFloat = compact ? 44 : 60

        return HStack {
            Spacer()
            Button { Task { await manager.togglePlayPause() } } label: {
                Image(systemName: manager.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: stopSize))
                    .frame(width: playFrame, height: playFrame)
                    .contentTransition(.symbolEffect(.replace))
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 32)
    }

    private var standardPlaybackControls: some View {
        let compact = verticalSizeClass == .compact
        let playSize: CGFloat   = compact ? 34 : 44
        let skipSize: CGFloat   = compact ? 20 : 26
        let modeSize: CGFloat   = compact ? 14 : 16
        let modeFrame: CGFloat  = compact ? 30 : 38
        let playFrame: CGFloat  = compact ? 44 : 60

        let queueActive = manager.isPlayingFromQueue

        return HStack(spacing: 0) {
            // Shuffle
            Button { Task { await manager.toggleShuffle() } } label: {
                let accent = manager.albumArtDominantColor ?? .white
                Image(systemName: "shuffle")
                    .font(.system(size: modeSize, weight: .semibold))
                    .foregroundStyle(manager.isShuffling && queueActive ? .white : .white.opacity(queueActive ? 0.45 : 0.2))
                    .frame(width: modeFrame, height: modeFrame)
                    .background(manager.isShuffling && queueActive ? accent.opacity(0.85) : Color.clear,
                                in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!queueActive)

            Spacer()

            // Previous
            Button { Task { await manager.previousTrack() } } label: {
                Image(systemName: "backward.fill").font(.system(size: skipSize))
                    .foregroundStyle(queueActive ? .white : .white.opacity(0.2))
            }
            .disabled(!queueActive)

            Spacer()

            // Play / Pause
            Button { Task { await manager.togglePlayPause() } } label: {
                Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: playSize))
                    .frame(width: playFrame, height: playFrame)
                    .contentTransition(.symbolEffect(.replace))
            }

            Spacer()

            // Next
            Button { Task { await manager.nextTrack() } } label: {
                Image(systemName: "forward.fill").font(.system(size: skipSize))
            }

            Spacer()

            // Repeat
            Button { Task { await manager.toggleRepeat() } } label: {
                let accent = manager.albumArtDominantColor ?? .white
                Image(systemName: manager.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: modeSize, weight: .semibold))
                    .foregroundStyle(manager.repeatMode != .off && queueActive ? .white : .white.opacity(queueActive ? 0.45 : 0.2))
                    .frame(width: modeFrame, height: modeFrame)
                    .background(manager.repeatMode != .off && queueActive ? accent.opacity(0.85) : Color.clear,
                                in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!queueActive)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 32)
    }

    // MARK: - Volume

    private var currentVolume: Int {
        isDraggingVolume ? Int(volumeSliderValue) : manager.volume
    }

    private var volumeControl: some View {
        HStack(spacing: 10) {
            Image(systemName: currentVolume == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    let newVol = max(0, currentVolume - 2)
                    Task { await manager.updateVolume(newVol) }
                }
                .onLongPressGesture {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if currentVolume > 0 {
                        premuteVolume = currentVolume
                        Task { await manager.updateVolume(0) }
                    } else if let saved = premuteVolume {
                        premuteVolume = nil
                        Task { await manager.updateVolume(saved) }
                    }
                }

            ThumblessSlider(
                value: Binding(
                    get: { isDraggingVolume ? volumeSliderValue : Double(manager.volume) },
                    set: { volumeSliderValue = $0; isDraggingVolume = true }
                ),
                range: 0...100,
                tintColor: .white.opacity(0.8),
                onStepTap: { step in
                    let newVol = min(100, max(0, currentVolume + step))
                    Task { await manager.updateVolume(newVol) }
                }
            ) { editing in
                if !editing {
                    isDraggingVolume = false
                    Task { await manager.updateVolume(Int(volumeSliderValue)) }
                }
            }

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let newVol = min(100, currentVolume + 2)
                Task { await manager.updateVolume(newVol) }
            } label: {
                Text("\(currentVolume)")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Bottom Actions (Speaker + optional Queue button)

    private let bottomButtonHeight: CGFloat = 38

    private func bottomActions(showQueue: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                manager.showingSpeakerPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: manager.isEverywhereActive ? "house.fill" : "hifispeaker.fill")
                        .font(.subheadline)
                    if manager.isEverywhereActive {
                        Text("Everywhere")
                            .font(.subheadline.weight(.medium))
                    } else {
                        Text(manager.selectedSpeaker?.name ?? "Select Speaker")
                            .font(.subheadline.weight(.medium))
                        if manager.currentGroupMembers.count > 1 {
                            Text("+ \(manager.currentGroupMembers.count - 1)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.white.opacity(0.2), in: Capsule())
                        }
                    }
                }
                .foregroundStyle(.white.opacity(0.7))
                .frame(height: bottomButtonHeight)
                .padding(.horizontal, 16)
                .background(.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)

            if showQueue {
                Button {
                    manager.showingQueue = true
                    Task { await manager.loadQueue() }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: bottomButtonHeight, height: bottomButtonHeight)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Error Banner

    @ViewBuilder
    private var errorBanner: some View {
        if manager.connectionState == .disconnected, let error = manager.errorMessage {
            VStack(spacing: 8) {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
                Button("Retry") { Task { await manager.refreshState() } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.bottom, 8)
        }
    }
}

// MARK: - ThumblessSlider

/// - When `thumbDragOnly` is false: full-bar drag to any position (e.g. volume slider).
///   A short tap (< 6 pt movement) triggers `onStepTap` if provided, so the bar also
///   supports "tap left of thumb → −2, tap right of thumb → +2" without jumping.
/// - When `thumbDragOnly` is true: drag must start within `thumbTolerance` of the current
///   thumb; a tap anywhere else does nothing. A small thumb circle is shown.
private struct ThumblessSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var tintColor: Color = .white
    var trackHeight: CGFloat = 5
    var thumbDragOnly: Bool = false
    var thumbTolerance: CGFloat = 28
    /// Called with ±2 when the user taps left/right of the current position instead of dragging.
    var onStepTap: ((Int) -> Void)? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var dragStartX: CGFloat = 0
    @State private var dragStartValue: Double = 0
    @State private var dragValid: Bool = false
    @State private var hasDragged: Bool = false
    @State private var lastHapticInteger: Int = Int.min

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let progress = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
            let thumbX = geo.size.width * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tintColor.opacity(0.2))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(tintColor)
                    .frame(width: max(0, thumbX), height: trackHeight)
                if thumbDragOnly {
                    Circle()
                        .fill(tintColor)
                        .frame(width: 13, height: 13)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .offset(x: max(0, thumbX - 6.5))
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let moved = abs(gesture.translation.width) > 6
                        if thumbDragOnly {
                            if !dragValid {
                                let nearThumb = abs(gesture.startLocation.x - thumbX) <= thumbTolerance
                                if nearThumb && moved {
                                    dragValid = true
                                    hasDragged = true
                                    dragStartX = gesture.startLocation.x
                                    dragStartValue = value
                                    lastHapticInteger = Int(value)
                                }
                            }
                            guard dragValid else { return }
                            let delta = gesture.location.x - dragStartX
                            let pct = min(max(0, (dragStartValue - range.lowerBound) / span + delta / geo.size.width), 1)
                            value = range.lowerBound + pct * span
                            fireTickIfNeeded()
                            onEditingChanged(true)
                        } else {
                            if moved || hasDragged {
                                if !hasDragged { lastHapticInteger = Int(value) }
                                hasDragged = true
                                let pct = min(max(0, gesture.location.x / geo.size.width), 1)
                                value = range.lowerBound + pct * span
                                fireTickIfNeeded()
                                onEditingChanged(true)
                            }
                        }
                    }
                    .onEnded { gesture in
                        defer { dragValid = false; hasDragged = false; lastHapticInteger = Int.min }
                        if hasDragged {
                            onEditingChanged(false)
                        } else if let step = onStepTap {
                            // Short tap — left of thumb = −2, right = +2
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            let tapped = gesture.startLocation.x
                            step(tapped < thumbX ? -2 : 2)
                        }
                    }
            )
        }
        .frame(height: 28)
    }

    private func fireTickIfNeeded() {
        let cur = Int(value)
        if cur != lastHapticInteger {
            lastHapticInteger = cur
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}

// MARK: - Mini Player Bar (persistent across tabs)

/// Compact now-playing bar that lives at the bottom of the app and stays
/// visible on every tab (Home / Search / …) — tapping it opens the full
/// player; dragging up does the same with an interactive rubber-band.
///
/// Use the `.miniPlayerInset(manager:)` modifier on each tab's root view
/// to mount it above the tab bar with matching content padding.
struct MiniPlayerBar: View {
    @Bindable var manager: SonosManager
    /// When mounted inside iOS 26's `tabViewBottomAccessory` slot the system
    /// provides its own liquid-glass capsule + horizontal inset, and renders
    /// the accessory *inline with the selected tab icon* once the user
    /// scrolls. In that case we must not apply our own material/insets or
    /// the double chrome looks wrong.
    var inSystemAccessory: Bool = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                manager.showFullPlayer = true
            }
        } label: {
            HStack(spacing: 12) {
                let isTV = manager.trackInfo?.source == .tv
                let artSize: CGFloat = inSystemAccessory ? 32 : 44
                let cornerRadius: CGFloat = inSystemAccessory ? 6 : 8
                if isTV {
                    // TV input never has cover art — show a `tv` glyph
                    // instead of the music note so the mini-player matches
                    // the home card and full player.
                    RoundedRectangle(cornerRadius: cornerRadius).fill(.quaternary)
                        .frame(width: artSize, height: artSize)
                        .overlay { Image(systemName: "tv").font(.caption).foregroundStyle(.tertiary) }
                } else if let image = manager.albumArtImage {
                    Image(uiImage: image)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: artSize, height: artSize)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                } else {
                    RoundedRectangle(cornerRadius: cornerRadius).fill(.quaternary)
                        .frame(width: artSize, height: artSize)
                        .overlay { Image(systemName: "music.note").font(.caption).foregroundStyle(.tertiary) }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(manager.trackInfo?.title ?? "Not Playing")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        // Only the unreachable warning remains inline — the
                        // cloud/remote affordance lives exclusively on the
                        // Home speakers list so the mini-player stays quiet
                        // in the common case.
                        if let glyph = backendMiniGlyph {
                            Image(systemName: glyph.name)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(glyph.tint)
                                .accessibilityLabel(glyph.label)
                        }
                    }
                    Text(manager.trackInfo?.artist ?? "—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    Task { await manager.togglePlayPause() }
                } label: {
                    Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)

                Button {
                    Task { await manager.nextTrack() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, inSystemAccessory ? 12 : 16)
            .padding(.vertical, inSystemAccessory ? 6 : 10)
            .modifier(MiniPlayerChromeModifier(useCustomChrome: !inSystemAccessory))
            // Make the ENTIRE bar hit-testable — without this, SwiftUI only
            // counts taps on the HStack's concrete subviews (art + text +
            // controls) and the `Spacer()` gap in the middle silently
            // swallows touches, so tapping the empty area between title and
            // the play button does nothing.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(y: manager.miniPlayerDragOffset)
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    let dy = value.translation.height
                    if dy < 0 {
                        // rubber-band: follow finger but resist at extremes
                        manager.miniPlayerDragOffset = dy * 0.55
                    }
                }
                .onEnded { value in
                    let dy = value.translation.height
                    let vel = value.predictedEndTranslation.height
                    if dy < -40 || vel < -200 {
                        manager.miniPlayerDragOffset = 0
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            manager.showFullPlayer = true
                        }
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            manager.miniPlayerDragOffset = 0
                        }
                    }
                }
        )
    }

    /// Mini-player only lights up when the speaker is genuinely unreachable
    /// (no LAN, no cloud). Cloud mode is signaled instead by the pill at the
    /// top-left of the Home speakers list so we don't stamp a glyph onto
    /// every track title while remote-controlling normally.
    private var backendMiniGlyph: (name: String, tint: Color, label: String)? {
        switch manager.transportBackend {
        case .unknown where manager.isConfigured:
            return ("wifi.exclamationmark", .orange, "Speaker unreachable")
        default:
            return nil
        }
    }
}

/// Chrome wrapper for `MiniPlayerBar`. When used outside iOS 26's
/// `tabViewBottomAccessory` slot we draw our own rounded material capsule;
/// inside the system accessory slot we rely on the liquid-glass chrome that
/// the tab bar provides (and fuses with the selected tab icon on scroll).
private struct MiniPlayerChromeModifier: ViewModifier {
    let useCustomChrome: Bool

    func body(content: Content) -> some View {
        if useCustomChrome {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        } else {
            content
        }
    }
}

/// Renders `MiniPlayerBar` only when it should be visible — i.e. the user
/// has a speaker configured, isn't looking at the full player, and isn't
/// actively typing (soft keyboard up). Keyboard awareness matters because
/// both the `safeAreaInset` (iOS < 26) and `tabViewBottomAccessory`
/// (iOS 26+) mount points ride up with the keyboard by default and waste
/// half of the search-results viewport. Apple Music / Spotify drop their
/// mini-players the same way during active input.
private struct KeyboardAwareMiniPlayer: View {
    @Bindable var manager: SonosManager
    var inSystemAccessory: Bool = false
    @State private var isKeyboardVisible = false

    var body: some View {
        Group {
            if manager.isConfigured
                && !manager.showFullPlayer
                && !isKeyboardVisible {
                MiniPlayerBar(manager: manager, inSystemAccessory: inSystemAccessory)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
    }
}

/// ViewModifier that inserts `MiniPlayerBar` into a tab's bottom safe-area
/// inset. Used only on iOS < 26 — newer OSes get the mini-player through
/// `tabViewBottomAccessory`.
private struct MiniPlayerInset: ViewModifier {
    @Bindable var manager: SonosManager

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            KeyboardAwareMiniPlayer(manager: manager)
        }
    }
}

extension View {
    /// Legacy fallback path for iOS < 26. On iOS 26 this is a no-op because
    /// `tabViewBottomAccessory` already supplies the shared mini-player.
    @ViewBuilder
    func miniPlayerLegacyInsetIfNeeded(manager: SonosManager) -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            modifier(MiniPlayerInset(manager: manager))
        }
    }

    /// iOS 26+: attach the mini-player as the tab bar's bottom accessory
    /// so the OS can collapse the inactive tabs on scroll and render the
    /// selected-tab icon side-by-side with the mini-player capsule.
    @ViewBuilder
    func miniPlayerSystemAccessoryIfAvailable(manager: SonosManager) -> some View {
        if #available(iOS 26.0, *) {
            self.tabViewBottomAccessory {
                KeyboardAwareMiniPlayer(manager: manager, inSystemAccessory: true)
            }
        } else {
            self
        }
    }

    /// iOS 26+: minimize the tab bar when the user scrolls content down, so
    /// the selected-tab icon slides next to the mini-player accessory. Apple's
    /// default behavior on iOS is `.automatic`, which does *not* enable this
    /// on iPhone — we have to opt in explicitly.
    @ViewBuilder
    func tabBarMinimizeOnScrollIfAvailable() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
