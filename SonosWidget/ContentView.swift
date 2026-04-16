import SwiftUI

struct ContentView: View {
    @State private var manager = SonosManager()
    @State private var newSpeakerIP = ""
    @State private var volumeSliderValue: Double = 0
    @State private var isDraggingVolume = false
    @State private var scrubPosition: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var showManualEntry = false

    var body: some View {
        NavigationStack {
            Group {
                if manager.isConfigured {
                    nowPlayingView
                } else {
                    setupView
                }
            }
            .navigationTitle("Sonos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if manager.isConfigured {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            manager.showingQueue = true
                            Task { await manager.loadQueue() }
                        } label: {
                            Image(systemName: "list.bullet")
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
            }
            .sheet(isPresented: $manager.showingAddSpeaker) { addSpeakerSheet }
            .sheet(isPresented: $manager.showingQueue) { queueSheet }
        }
        .onAppear { manager.loadSavedState() }
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

    // MARK: - Now Playing

    private var nowPlayingView: some View {
        ScrollView {
            VStack(spacing: 16) {
                speakerPicker
                albumArtView.padding(.top, 4)
                trackInfoView
                progressView
                playbackControls
                volumeControl

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
            .padding()
        }
        .refreshable { await manager.refreshState() }
        .onAppear { manager.startAutoRefresh() }
        .onDisappear { manager.stopAutoRefresh() }
    }

    private var speakerPicker: some View {
        Menu {
            ForEach(manager.speakers) { speaker in
                Button {
                    Task { await manager.selectSpeaker(speaker) }
                } label: {
                    HStack {
                        Text(speaker.name)
                        if speaker.id == manager.selectedSpeaker?.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "hifispeaker.fill").foregroundStyle(.secondary)
                Text(manager.selectedSpeaker?.name ?? "Select Speaker").fontWeight(.medium)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

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

    private var trackInfoView: some View {
        VStack(spacing: 4) {
            Text(manager.trackInfo?.title ?? "Not Playing").font(.title3.bold()).lineLimit(1)
            Text(manager.trackInfo?.artist ?? "—").font(.body).foregroundStyle(.secondary).lineLimit(1)
            Text(manager.trackInfo?.album ?? "").font(.subheadline).foregroundStyle(.tertiary).lineLimit(1)
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
            .tint(.primary)

            HStack {
                Text(SonosTime.display(isScrubbing ? scrubPosition : manager.positionSeconds))
                    .monospacedDigit()
                Spacer()
                Text(SonosTime.display(manager.durationSeconds))
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
    }

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
        .foregroundStyle(.primary)
        .padding(.vertical, 4)
    }

    private var volumeControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
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
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Queue Sheet

    private var queueSheet: some View {
        NavigationStack {
            Group {
                if manager.queue.isEmpty {
                    ContentUnavailableView("Queue is empty",
                                           systemImage: "music.note.list",
                                           description: Text("Start playing music on your Sonos speaker."))
                } else {
                    List {
                        ForEach(manager.queue) { item in
                            HStack(spacing: 12) {
                                AsyncImage(url: URL(string: item.albumArtURL ?? "")) { phase in
                                    if let img = phase.image {
                                        img.resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        Rectangle().fill(.quaternary)
                                            .overlay { Image(systemName: "music.note").font(.caption2).foregroundStyle(.tertiary) }
                                    }
                                }
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.subheadline).lineLimit(1)
                                    Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { manager.showingQueue = false }
                }
            }
        }
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

#Preview { ContentView() }
