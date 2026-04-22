import SwiftUI

struct SpeakerPickerView: View {
    @Bindable var manager: SonosManager
    @Environment(\.dismiss) private var dismiss
    @State private var isProcessing = false
    @State private var premuteMemberVolumes: [String: Int] = [:]

    private var visibleSpeakers: [SonosPlayer] {
        var seen = Set<String>()
        let all = manager.allSpeakers.filter { !$0.isInvisible && seen.insert($0.id).inserted }
        let coordID = manager.selectedSpeaker?.id
        return all.sorted { a, _ in a.id == coordID }
    }

    private var currentGroupId: String? {
        guard let sel = manager.selectedSpeaker else { return nil }
        return sel.groupId ?? sel.id
    }

    private func isInCurrentGroup(_ speaker: SonosPlayer) -> Bool {
        guard let gid = currentGroupId else { return false }
        return speaker.groupId == gid
    }

    private var accent: Color { manager.albumArtDominantColor ?? .accentColor }
    private var isEverywhere: Bool { manager.isEverywhereActive }

    var body: some View {
        NavigationStack {
            ScrollView {
                if visibleSpeakers.isEmpty {
                    ContentUnavailableView("No Speakers Found",
                                           systemImage: "hifispeaker.slash",
                                           description: Text("Make sure your Sonos speakers are on the same network."))
                    .padding(.top, 60)
                } else {
                    VStack(spacing: 0) {
                        if visibleSpeakers.count > 1 {
                            everywhereRow
                        }

                        ForEach(visibleSpeakers) { speaker in
                            let inGroup = isInCurrentGroup(speaker)
                            speakerRow(speaker, inGroup: inGroup)
                        }
                    }
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.white.opacity(0.06))
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .navigationTitle("Speakers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear { loadVolumes() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(24)
        .tint(accent)
    }

    // MARK: - Load Volumes

    private func loadVolumes() {
        Task {
            let members = manager.currentGroupMembers
            if members.count > 1 {
                await manager.fetchMemberVolumes()
            } else if let solo = members.first {
                if manager.memberVolumes[solo.ipAddress] == nil {
                    manager.memberVolumes[solo.ipAddress] = manager.volume
                }
            }
        }
    }

    // MARK: - Everywhere Row

    private var everywhereRow: some View {
        VStack(spacing: 0) {
            Button {
                guard !isProcessing else { return }
                Task { await toggleEverywhere() }
            } label: {
                HStack(spacing: 12) {
                    checkCircle(isActive: isEverywhere)

                    Image(systemName: "house.fill")
                        .font(.body)
                        .foregroundStyle(isEverywhere ? accent : .white.opacity(0.5))
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Everywhere")
                            .font(.subheadline.weight(isEverywhere ? .semibold : .regular))
                            .foregroundStyle(.white)
                        Text(isEverywhere ? "All speakers grouped" : "Play on all speakers")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().opacity(0.3).padding(.leading, 56)
        }
    }

    // MARK: - Speaker Row

    private func speakerRow(_ speaker: SonosPlayer, inGroup: Bool) -> some View {
        let isCoord = speaker.id == manager.selectedSpeaker?.id
        let vol = manager.memberVolumes[speaker.ipAddress] ?? manager.volume

        return VStack(spacing: 0) {
            Button {
                guard !isProcessing else { return }
                Task { await handleTap(speaker, inGroup: inGroup, isCoord: isCoord) }
            } label: {
                HStack(spacing: 12) {
                    checkCircle(isActive: inGroup)

                    Image(systemName: "hifispeaker.fill")
                        .font(.body)
                        .foregroundStyle(inGroup ? accent : .white.opacity(0.5))
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(speaker.name)
                            .font(.subheadline.weight(inGroup ? .semibold : .regular))
                            .foregroundStyle(.white)
                        if isCoord {
                            Text("Currently Playing")
                                .font(.caption)
                                .foregroundStyle(accent)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if inGroup {
                volumeRow(speaker: speaker, vol: vol)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if speaker.id != visibleSpeakers.last?.id {
                Divider().opacity(0.3).padding(.leading, 56)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: inGroup)
    }

    // MARK: - Volume Row (matches Home page GroupVolumeBar pattern)

    private func volumeRow(speaker: SonosPlayer, vol: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: vol == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    let newVol = max(0, vol - 2)
                    Task { await manager.setMemberVolume(ip: speaker.ipAddress, volume: newVol) }
                }
                .onLongPressGesture {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if vol > 0 {
                        premuteMemberVolumes[speaker.ipAddress] = vol
                        Task { await manager.setMemberVolume(ip: speaker.ipAddress, volume: 0) }
                    } else if let saved = premuteMemberVolumes[speaker.ipAddress] {
                        premuteMemberVolumes[speaker.ipAddress] = nil
                        Task { await manager.setMemberVolume(ip: speaker.ipAddress, volume: saved) }
                    }
                }

            PickerVolumeBar(volume: vol) { step in
                let newVol = min(100, max(0, vol + step))
                Task { await manager.setMemberVolume(ip: speaker.ipAddress, volume: newVol) }
            }

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let newVol = min(100, vol + 2)
                Task { await manager.setMemberVolume(ip: speaker.ipAddress, volume: newVol) }
            } label: {
                Text("\(vol)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 22, height: 28, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .padding(.bottom, 8)
    }

    // MARK: - Check Circle

    private func checkCircle(isActive: Bool) -> some View {
        ZStack {
            if isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.5))
            } else {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isActive ? accent : .white.opacity(0.2))
            }
        }
        .frame(width: 24, height: 24)
    }

    // MARK: - Actions

    private func handleTap(_ speaker: SonosPlayer, inGroup: Bool, isCoord: Bool) async {
        isProcessing = true
        defer { isProcessing = false }

        if inGroup {
            if isCoord {
                let others = manager.currentGroupMembers.filter { $0.id != speaker.id }
                if let target = others.first {
                    await manager.transferPlayback(to: target)
                }
            } else {
                await manager.removeSpeakerFromGroup(speaker)
            }
        } else {
            await manager.addSpeakerToGroup(speaker)
        }

        await manager.fetchMemberVolumes()
    }

    // MARK: - Everywhere

    private func toggleEverywhere() async {
        isProcessing = true
        defer { isProcessing = false }

        if isEverywhere {
            let notCoord = visibleSpeakers.filter { $0.id != manager.selectedSpeaker?.id }
            for speaker in notCoord {
                await manager.removeSpeakerFromGroup(speaker)
            }
        } else {
            let notInGroup = visibleSpeakers.filter { !isInCurrentGroup($0) }
            for speaker in notInGroup {
                await manager.addSpeakerToGroup(speaker)
            }
        }

        await manager.fetchMemberVolumes()
    }
}

// MARK: - Volume Bar (tap left = −2, tap right = +2, matches Home page GroupVolumeBar)

private struct PickerVolumeBar: View {
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
