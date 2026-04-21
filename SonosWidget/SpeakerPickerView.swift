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
            List {
                if visibleSpeakers.isEmpty {
                    ContentUnavailableView("No Speakers Found",
                                           systemImage: "hifispeaker.slash",
                                           description: Text("Make sure your Sonos speakers are on the same network."))
                } else {
                    if visibleSpeakers.count > 1 {
                        everywhereRow
                    }

                    ForEach(visibleSpeakers) { speaker in
                        let inGroup = isInCurrentGroup(speaker)
                        speakerRow(speaker, inGroup: inGroup)
                    }
                }
            }
            .navigationTitle("Speakers")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if manager.currentGroupMembers.count > 1 {
                    Task { await manager.fetchMemberVolumes() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .tint(accent)
    }

    // MARK: - Everywhere Row

    private var everywhereRow: some View {
        Button {
            guard !isProcessing else { return }
            Task { await toggleEverywhere() }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    if isProcessing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: isEverywhere ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isEverywhere ? accent : .secondary)
                    }
                }
                .frame(width: 28)

                Image(systemName: "house.fill")
                    .font(.title3)
                    .foregroundStyle(isEverywhere ? accent : .primary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Everywhere")
                        .font(.body.weight(isEverywhere ? .semibold : .regular))
                    Text(isEverywhere ? "All speakers grouped" : "Play on all speakers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Speaker Row

    private func speakerRow(_ speaker: SonosPlayer, inGroup: Bool) -> some View {
        let isCoord = speaker.id == manager.selectedSpeaker?.id
        let vol = manager.memberVolumes[speaker.ipAddress] ?? 0

        return VStack(spacing: 0) {
            Button {
                guard !isProcessing else { return }
                Task { await handleTap(speaker, inGroup: inGroup, isCoord: isCoord) }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        if isProcessing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: inGroup ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(inGroup ? accent : .secondary)
                        }
                    }
                    .frame(width: 28)

                    Image(systemName: "hifispeaker.fill")
                        .font(.title3)
                        .foregroundStyle(inGroup ? accent : .primary)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(speaker.name)
                            .font(.body.weight(inGroup ? .semibold : .regular))
                        if isCoord {
                            Text("Currently Playing")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if inGroup {
                HStack(spacing: 10) {
                    Image(systemName: vol == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                        .contentShape(Rectangle())
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

                    Slider(value: Binding(
                        get: { Double(manager.memberVolumes[speaker.ipAddress] ?? 0) },
                        set: { manager.memberVolumes[speaker.ipAddress] = Int($0) }
                    ), in: 0...100) { editing in
                        if !editing {
                            let v = manager.memberVolumes[speaker.ipAddress] ?? 0
                            Task { await manager.setMemberVolume(ip: speaker.ipAddress, volume: v) }
                        }
                    }
                    .tint(accent)

                    Text("\(vol)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                }
                .padding(.leading, 68)
                .padding(.trailing, 4)
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: inGroup)
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

        if manager.currentGroupMembers.count > 1 {
            await manager.fetchMemberVolumes()
        }
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

        if manager.currentGroupMembers.count > 1 {
            await manager.fetchMemberVolumes()
        }
    }
}
