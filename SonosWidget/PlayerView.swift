import SwiftUI

struct PlayerView: View {
    @Bindable var manager: SonosManager
    @State private var showFullPlayer = true
    @State private var newSpeakerIP = ""
    @State private var showManualEntry = false

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
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                manager.showingQueue = true
                                Task { await manager.loadQueue() }
                            } label: {
                                Image(systemName: "list.bullet")
                            }
                        }
                        ToolbarItem(placement: .principal) {
                            if let source = manager.trackInfo?.source, source != .unknown {
                                HStack(spacing: 4) {
                                    Image(systemName: source.iconName)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(source.displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(source.badgeColor.opacity(0.85))
                                .clipShape(Capsule())
                            } else {
                                Text("Sonos").fontWeight(.semibold)
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button { manager.showingAddSpeaker = true } label: {
                                    Label("Enter IP Manually", systemImage: "keyboard")
                                }
                                Button { manager.rescan() } label: {
                                    Label("Rescan Network", systemImage: "arrow.clockwise")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                    .sheet(isPresented: $manager.showingQueue) {
                        QueueView(manager: manager)
                    }
            }

            if !showFullPlayer {
                miniPlayerBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if showFullPlayer {
                NowPlayingOverlay(manager: manager, isPresented: $showFullPlayer)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showFullPlayer)
    }

    // MARK: - Mini Player Bar

    private var miniPlayerBar: some View {
        Button {
            showFullPlayer = true
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
    }

    // MARK: - Speakers Home View

    private var speakersHomeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("My Speakers")
                    .font(.title2.bold())
                    .padding(.horizontal)
                    .padding(.top, 8)

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
                            speakerGroupCard(group)
                        }
                    }
                    .padding(.horizontal)
                }

                Spacer(minLength: showFullPlayer ? 20 : 80)
            }
            .padding(.top, 4)
        }
        .refreshable {
            await manager.refreshAllGroupStatuses()
        }
        .onAppear {
            manager.startAutoRefresh()
            Task { await manager.refreshAllGroupStatuses() }
        }
        .onDisappear { manager.stopAutoRefresh() }
    }

    private func speakerGroupCard(_ group: SpeakerGroupStatus) -> some View {
        let isCurrentGroup = group.coordinator.id == manager.selectedSpeaker?.id
                || group.coordinator.groupId == manager.selectedSpeaker?.groupId

        return Button {
            if !isCurrentGroup {
                Task { await manager.selectSpeaker(group.coordinator) }
            }
            showFullPlayer = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: group.members.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill")
                        .font(.title2)
                        .foregroundStyle(isCurrentGroup ? .blue : .secondary)
                        .frame(width: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.members.map(\.name).joined(separator: " + "))
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

                    if group.transportState == .playing {
                        Image(systemName: "waveform")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .symbolEffect(.variableColor.iterative, isActive: true)
                    } else if group.transportState == .paused {
                        Image(systemName: "pause.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(isCurrentGroup ? Color.blue.opacity(0.12) : Color.white.opacity(0.06))
            }
            .overlay {
                if isCurrentGroup {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.blue.opacity(0.3), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
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

// MARK: - Now Playing Full-Screen Overlay

struct NowPlayingOverlay: View {
    @Bindable var manager: SonosManager
    @Binding var isPresented: Bool
    @State private var volumeSliderValue: Double = 0
    @State private var isDraggingVolume = false
    @State private var scrubPosition: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                artBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    dragHandle
                        .padding(.top, 12)

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 16) {
                            albumArtView
                                .padding(.top, 12)
                            trackInfoView
                            progressView
                            audioQualityBadge
                            playbackControls
                            volumeControl
                            speakerButton
                                .padding(.top, 4)

                            if manager.connectionState == .disconnected, let error = manager.errorMessage {
                                VStack(spacing: 8) {
                                    Label(error, systemImage: "wifi.exclamationmark")
                                        .font(.caption).foregroundStyle(.orange)
                                    Button("Retry") { Task { await manager.refreshState() } }
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                                .padding(.top, 4)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 40)
                    }
                }
            }
            .offset(y: dragOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if value.translation.height > 0 {
                            dragOffset = value.translation.height
                        }
                    }
                    .onEnded { value in
                        if value.translation.height > 120 || value.predictedEndTranslation.height > 300 {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                isPresented = false
                            }
                        }
                        withAnimation(.spring(response: 0.3)) {
                            dragOffset = 0
                        }
                    }
            )
        }
        .sheet(isPresented: $manager.showingSpeakerPicker) {
            SpeakerPickerView(manager: manager)
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
        if let image = manager.albumArtImage {
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 80)
                    .scaleEffect(1.5)
                    .clipped()

                LinearGradient(
                    colors: [.black.opacity(0.4), .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        } else {
            Color.black
        }
    }

    // MARK: - Album Art

    @ViewBuilder
    private var albumArtView: some View {
        if let image = manager.albumArtImage {
            Image(uiImage: image)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: 300, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        } else {
            RoundedRectangle(cornerRadius: 16).fill(.quaternary)
                .frame(width: 300, height: 300)
                .overlay {
                    Image(systemName: "music.note").font(.system(size: 60)).foregroundStyle(.tertiary)
                }
        }
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

    private var progressView: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubPosition : manager.positionSeconds },
                    set: { scrubPosition = $0; isScrubbing = true }
                ),
                in: 0...max(manager.durationSeconds, 1)
            ) { editing in
                if !editing {
                    isScrubbing = false
                    Task { await manager.seekTo(scrubPosition) }
                }
            }
            .tint(.white)

            HStack {
                Text(SonosTime.display(isScrubbing ? scrubPosition : manager.positionSeconds))
                    .monospacedDigit()
                Spacer()
                Text(SonosTime.display(manager.durationSeconds))
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Audio Quality Badge

    @ViewBuilder
    private var audioQualityBadge: some View {
        if let quality = manager.trackInfo?.audioQuality {
            HStack(spacing: 4) {
                Image(systemName: quality.iconName)
                    .font(.system(size: 10, weight: .semibold))
                Text(quality.label)
                    .font(.system(size: 10, weight: .semibold))
                if let sr = quality.sampleRate, let bd = quality.bitDepth {
                    Text("·")
                        .font(.system(size: 10))
                    Text("\(bd)/\(sr / 1000)kHz")
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.white.opacity(0.1), in: Capsule())
        }
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        HStack(spacing: 40) {
            Button { Task { await manager.previousTrack() } } label: {
                Image(systemName: "backward.fill").font(.title2)
            }
            Button { Task { await manager.togglePlayPause() } } label: {
                Image(systemName: manager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
            }
            Button { Task { await manager.nextTrack() } } label: {
                Image(systemName: "forward.fill").font(.title2)
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 4)
    }

    // MARK: - Volume

    private var volumeControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))

            Slider(
                value: Binding(
                    get: { isDraggingVolume ? volumeSliderValue : Double(manager.volume) },
                    set: { volumeSliderValue = $0; isDraggingVolume = true }
                ),
                in: 0...100, step: 1
            ) { editing in
                if !editing {
                    isDraggingVolume = false
                    Task { await manager.updateVolume(Int(volumeSliderValue)) }
                }
            }
            .tint(.white.opacity(0.8))

            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Speaker Button (AirPlay-style)

    private var speakerButton: some View {
        Button {
            manager.showingSpeakerPicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "hifispeaker.fill")
                    .font(.subheadline)
                Text(speakerLabel)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var speakerLabel: String {
        manager.selectedSpeaker?.name ?? "Select Speaker"
    }
}
