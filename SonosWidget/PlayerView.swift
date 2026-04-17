import SwiftUI

struct PlayerView: View {
    @Bindable var manager: SonosManager
    @State private var newSpeakerIP = ""
    @State private var showManualEntry = false
    @State private var isConnectingSonos = false

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
        .sheet(isPresented: $manager.showingAddSpeaker) { addSpeakerSheet }
        .onAppear { manager.loadSavedState() }
    }

    // MARK: - Configured View

    private var configuredView: some View {
        ZStack(alignment: .bottom) {
            NavigationStack {
                speakersHomeView
                    .background {
                        blurredArtBackground.ignoresSafeArea()
                    }
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button { manager.showingAddSpeaker = true } label: {
                                    Label("Enter IP Manually", systemImage: "keyboard")
                                }
                                Button { manager.rescan() } label: {
                                    Label("Rescan Network", systemImage: "arrow.clockwise")
                                }

                                Divider()

                                if SonosAuth.shared.isLoggedIn {
                                    Button(role: .destructive) {
                                        SonosAuth.shared.logout()
                                    } label: {
                                        Label("Disconnect Sonos Account", systemImage: "person.crop.circle.badge.minus")
                                    }
                                } else {
                                    Button {
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
                                    } label: {
                                        Label("Connect Sonos Account", systemImage: "person.crop.circle.badge.plus")
                                    }
                                    .disabled(isConnectingSonos)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
            }
            .scrollContentBackground(.hidden)

            if !manager.showFullPlayer {
                miniPlayerBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: manager.showFullPlayer)
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

    // MARK: - Mini Player Bar

    private var miniPlayerBar: some View {
        Button {
            manager.showFullPlayer = true
        } label: {
            HStack(spacing: 12) {
                if let image = manager.albumArtImage {
                    Image(uiImage: image)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                        .frame(width: 44, height: 44)
                        .overlay { Image(systemName: "music.note").font(.caption).foregroundStyle(.tertiary) }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.trackInfo?.title ?? "Not Playing")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
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

    // MARK: - Speakers Home View

    @State private var dropTargetGroupID: String?
    @State private var isSeparateZoneTargeted = false

    private var speakersHomeView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
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

                Spacer(minLength: manager.showFullPlayer ? 20 : 80)
            }
            .padding(.top, 4)
        }
        .overlay(alignment: .bottomTrailing) {
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
                .padding(.trailing, 20)
                .padding(.bottom, manager.showFullPlayer ? 20 : 76)
        }
        .onAppear {
            manager.startAutoRefresh()
            Task { await manager.refreshAllGroupStatuses() }
        }
        .onDisappear { manager.stopAutoRefresh() }
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

            if manager.discovery.isScanning {
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
                Text("Select a speaker to get started:")
                    .font(.subheadline).foregroundStyle(.secondary)
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
    }

    // MARK: - Add Speaker Sheet

    private var addSpeakerSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("Speaker IP Address", text: $newSpeakerIP)
                    .textFieldStyle(.roundedBorder).keyboardType(.decimalPad)
                Button {
                    Task {
                        await manager.addSpeaker(ip: newSpeakerIP)
                        if manager.errorMessage == nil {
                            manager.showingAddSpeaker = false
                            newSpeakerIP = ""
                        }
                    }
                } label: {
                    if manager.isLoading { ProgressView().frame(maxWidth: .infinity) }
                    else { Text("Connect").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newSpeakerIP.isEmpty || manager.isLoading)
                if let error = manager.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Add Speaker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { manager.showingAddSpeaker = false }
                }
            }
        }
    }
}

// MARK: - Speaker Group Card

private struct SpeakerGroupCardView: View {
    let group: SpeakerGroupStatus
    @Bindable var manager: SonosManager

    @State private var premuteGroupVolume: Int?
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
                    if let img = artImage {
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

                        if let track = group.trackInfo, track.title != "Unknown" {
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
                        progress: isCurrentGroup && manager.durationSeconds > 0
                            ? manager.positionSeconds / manager.durationSeconds
                            : 0,
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
    @State private var volumeSliderValue: Double = 0
    @State private var isDraggingVolume = false
    @State private var showMemberVolumes = false
    @State private var premuteVolume: Int?
    @State private var scrubPosition: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var dragDownOffset: CGFloat = 0
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            if isLandscape {
                landscapeLayout(geo: geo)
            } else {
                portraitLayout(geo: geo)
            }
        }
        .background { artBackground.ignoresSafeArea() }
        .sheet(isPresented: $manager.showingSpeakerPicker) {
            SpeakerPickerView(manager: manager)
        }
        .sheet(isPresented: $manager.showingQueue) {
            QueueView(manager: manager)
        }
    }

    // MARK: - Portrait Layout

    private func portraitLayout(geo: GeometryProxy) -> some View {
        let artSz = min(geo.size.width - 80, geo.size.height * 0.42)

        return VStack(spacing: 0) {
            dragHandle
                .padding(.top, 8)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(dismissDragGesture)

            Spacer(minLength: 8)

            albumArtView(size: artSz)
                .contentShape(Rectangle())
                .gesture(dismissDragGesture)

            trackInfoView
                .padding(.horizontal, 32)
                .padding(.top, 20)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(dismissDragGesture)

            progressView
                .padding(.top, 16)

            playbackControls
                .padding(.top, 20)

            volumeControl
                .padding(.top, 20)

            bottomActions(showQueue: true)
                .padding(.top, 14)

            Spacer(minLength: 8)

            errorBanner
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: dragDownOffset)
    }

    // MARK: - Landscape Layout (player left | queue right)

    private func landscapeLayout(geo: GeometryProxy) -> some View {
        let leftW = geo.size.width * 0.55
        let fixedBelow: CGFloat = 196
        let topPad:     CGFloat = 12
        let artSz = max(80, min(leftW * 0.38, geo.size.height - topPad - fixedBelow))

        return VStack(spacing: 0) {
            Spacer(minLength: topPad)

            // ── Drag-safe zone (no child DragGestures) ──
            HStack(alignment: .center, spacing: 16) {
                albumArtView(size: artSz)

                VStack(alignment: .leading) {
                    Spacer(minLength: 0)
                    Text(manager.trackInfo?.title ?? "Not Playing")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .lineLimit(2)
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
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: artSz, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
            .gesture(dismissDragGesture)

            // ── Controls zone ──
            progressContent
                .padding(.horizontal, 20)
                .padding(.top, 14)

            playbackControls.padding(.top, 10)
            volumeControl.padding(.top, 6)
            bottomActions(showQueue: true).padding(.top, 6)

            Spacer(minLength: 0)
            errorBanner
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: dragDownOffset)
    }

    // MARK: - Dismiss Drag Gesture

    private var dismissDragGesture: some Gesture {
        DragGesture()
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
            .fill(.white.opacity(0.4))
            .frame(width: 36, height: 5)
    }

    // MARK: - Background

    @ViewBuilder
    private var artBackground: some View {
        ZStack {
            Color.black
            if let image = manager.albumArtImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 80)
                    .scaleEffect(1.5)
                    .clipped()
                    .id(manager.trackInfo?.albumArtURL)
                    .transition(.opacity)
                LinearGradient(
                    colors: [.black.opacity(0.4), .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: manager.trackInfo?.albumArtURL)
    }

    // MARK: - Album Art

    @ViewBuilder
    private func albumArtView(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(.quaternary)
                .overlay {
                    Image(systemName: "music.note").font(.system(size: 60)).foregroundStyle(.tertiary)
                }

            if let image = manager.albumArtImage {
                Image(uiImage: image)
                    .resizable().aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                    .overlay(alignment: .bottomLeading) {
                        // Hide source badge in landscape — art is too small for it to read well.
                        if verticalSizeClass != .compact,
                           let source = manager.trackInfo?.source, source != .unknown {
                            SourceBadgeView(source: source, tintColor: manager.albumArtDominantColor)
                                .padding(10)
                        }
                    }
                    .id(manager.trackInfo?.albumArtURL)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.6), value: manager.trackInfo?.albumArtURL)
    }

    // MARK: - Track Info

    private var trackInfoView: some View {
        VStack(spacing: 4) {
            Text(manager.trackInfo?.title ?? "Not Playing")
                .font(.title3.bold()).foregroundStyle(.white).lineLimit(1)
            Text(manager.trackInfo?.artist ?? "—")
                .font(.body).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            Text(manager.trackInfo?.album ?? "")
                .font(.subheadline).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
        }
    }

    // MARK: - Progress

    /// Inner progress content — no outer padding, usable in both portrait and landscape info column.
    private var progressContent: some View {
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
                    HStack(spacing: 3) {
                        Text(quality.label)
                            .font(.system(size: 9, weight: .semibold))
                        if let sr = quality.sampleRate, let bd = quality.bitDepth {
                            Text("·")
                                .font(.system(size: 9))
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

    private var playbackControls: some View {
        let compact = verticalSizeClass == .compact
        let playSize: CGFloat   = compact ? 34 : 44
        let skipSize: CGFloat   = compact ? 20 : 26
        let modeSize: CGFloat   = compact ? 14 : 16
        let modeFrame: CGFloat  = compact ? 30 : 38
        let playFrame: CGFloat  = compact ? 44 : 60

        return HStack(spacing: 0) {
            // Shuffle
            Button { Task { await manager.toggleShuffle() } } label: {
                let accent = manager.albumArtDominantColor ?? .white
                Image(systemName: "shuffle")
                    .font(.system(size: modeSize, weight: .semibold))
                    .foregroundStyle(manager.isShuffling ? .white : .white.opacity(0.45))
                    .frame(width: modeFrame, height: modeFrame)
                    .background(manager.isShuffling ? accent.opacity(0.85) : Color.clear,
                                in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Previous
            Button { Task { await manager.previousTrack() } } label: {
                Image(systemName: "backward.fill").font(.system(size: skipSize))
            }

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
                    .foregroundStyle(manager.repeatMode != .off ? .white : .white.opacity(0.45))
                    .frame(width: modeFrame, height: modeFrame)
                    .background(manager.repeatMode != .off ? accent.opacity(0.85) : Color.clear,
                                in: Circle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 32)
    }

    // MARK: - Volume

    private var currentVolume: Int {
        isDraggingVolume ? Int(volumeSliderValue) : manager.volume
    }

    private var volumeControl: some View {
        let members = manager.currentGroupMembers
        let isGrouped = members.count > 1

        return VStack(spacing: 10) {
            // ── Master / Group volume row ──
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

                // Volume number + expand button (grouped only)
                HStack(spacing: 4) {
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

                    if isGrouped {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                showMemberVolumes.toggle()
                            }
                            if showMemberVolumes {
                                Task { await manager.fetchMemberVolumes() }
                            }
                        } label: {
                            Image(systemName: showMemberVolumes ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(width: 18, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // ── Per-member volume sliders (expanded) ──
            if showMemberVolumes && isGrouped {
                VStack(spacing: 8) {
                    ForEach(members) { member in
                        let vol = manager.memberVolumes[member.ipAddress] ?? 0
                        HStack(spacing: 8) {
                            Text(member.name)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.55))
                                .frame(width: 72, alignment: .leading)
                                .lineLimit(1)

                            Image(systemName: vol == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.35))
                                .frame(width: 16)

                            ThumblessSlider(
                                value: Binding(
                                    get: { Double(manager.memberVolumes[member.ipAddress] ?? 0) },
                                    set: { manager.memberVolumes[member.ipAddress] = Int($0) }
                                ),
                                range: 0...100,
                                tintColor: .white.opacity(0.6),
                                onStepTap: { step in
                                    let cur = manager.memberVolumes[member.ipAddress] ?? 0
                                    let nv = min(100, max(0, cur + step))
                                    Task { await manager.setMemberVolume(ip: member.ipAddress, volume: nv) }
                                }
                            ) { editing in
                                if !editing {
                                    let v = manager.memberVolumes[member.ipAddress] ?? 0
                                    Task { await manager.setMemberVolume(ip: member.ipAddress, volume: v) }
                                }
                            }

                            Text("\(vol)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.35))
                                .frame(width: 22, alignment: .trailing)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 32)
        .onChange(of: isGrouped) { _, newVal in
            if !newVal { showMemberVolumes = false }
        }
    }

    // MARK: - Bottom Actions (Speaker + optional Queue button)

    private let bottomButtonHeight: CGFloat = 38

    private func bottomActions(showQueue: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                manager.showingSpeakerPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "hifispeaker.fill")
                        .font(.subheadline)
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
