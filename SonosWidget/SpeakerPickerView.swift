import SwiftUI

struct SpeakerPickerView: View {
    @Bindable var manager: SonosManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if manager.allSpeakers.isEmpty {
                    ContentUnavailableView("No Speakers Found",
                                           systemImage: "hifispeaker.slash",
                                           description: Text("Make sure your Sonos speakers are on the same network."))
                } else {
                    ForEach(groupedSpeakers, id: \.coordinator.id) { group in
                        Section {
                            ForEach(group.members, id: \.id) { speaker in
                                speakerRow(speaker, isCoordinator: speaker.id == group.coordinator.id)
                            }
                        } header: {
                            if groupedSpeakers.count > 1 {
                                Text(group.coordinator.name)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Speakers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var groupedSpeakers: [(coordinator: SonosPlayer, members: [SonosPlayer])] {
        let coordinators = manager.allSpeakers.filter(\.isCoordinator)
        return coordinators.map { coord in
            let members = manager.allSpeakers.filter { $0.groupId == coord.groupId }
            let sorted = [coord] + members.filter { $0.id != coord.id }
            return (coordinator: coord, members: sorted)
        }
    }

    private func isMemberOfCurrentGroup(_ speaker: SonosPlayer) -> Bool {
        guard let selected = manager.selectedSpeaker else { return false }
        let currentGroupId = selected.groupId ?? selected.id
        return speaker.groupId == currentGroupId
    }

    private func speakerRow(_ speaker: SonosPlayer, isCoordinator: Bool) -> some View {
        let isInGroup = isMemberOfCurrentGroup(speaker)
        let isSelected = speaker.id == manager.selectedSpeaker?.id

        return Button {
            Task { await handleTap(speaker, isCurrentlyInGroup: isInGroup) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isInGroup ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isInGroup ? .blue : .secondary)

                Image(systemName: "hifispeaker.fill")
                    .font(.title3)
                    .foregroundStyle(isSelected ? .blue : .primary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(speaker.name)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                    if isCoordinator && isInGroup {
                        Text("Coordinator")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isInGroup && !isSelected {
                    volumeBadge(for: speaker)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func volumeBadge(for speaker: SonosPlayer) -> some View {
        Image(systemName: "speaker.wave.2.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func handleTap(_ speaker: SonosPlayer, isCurrentlyInGroup: Bool) async {
        if isCurrentlyInGroup {
            if speaker.id == manager.selectedSpeaker?.id {
                // Cannot remove the selected speaker from its own group
                // unless we transfer first — do nothing
                return
            }
            await manager.removeSpeakerFromGroup(speaker)
        } else {
            await manager.addSpeakerToGroup(speaker)
        }
    }
}
