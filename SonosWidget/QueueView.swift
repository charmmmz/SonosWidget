import SwiftUI

struct QueueView: View {
    @Bindable var manager: SonosManager
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            Group {
                if manager.queue.isEmpty {
                    ContentUnavailableView("Queue is empty",
                                           systemImage: "music.note.list",
                                           description: Text("Start playing music on your Sonos speaker."))
                } else {
                    List {
                        ForEach(manager.queue) { item in
                            queueRow(item)
                                .contextMenu {
                                    Button {
                                        Task { await manager.playTrackInQueue(item) }
                                    } label: {
                                        Label("Play Now", systemImage: "play.fill")
                                    }
                                    Button(role: .destructive) {
                                        Task { await manager.deleteFromQueue(item: item) }
                                    } label: {
                                        Label("Remove from Queue", systemImage: "trash")
                                    }
                                }
                        }
                        .onMove { source, destination in
                            manager.moveQueueItem(from: source, to: destination)
                        }
                        .onDelete { indexSet in
                            guard let idx = indexSet.first else { return }
                            let item = manager.queue[idx]
                            Task { await manager.deleteFromQueue(item: item) }
                        }
                    }
                    .listStyle(.plain)
                    .environment(\.editMode, $editMode)
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { manager.showingQueue = false }
                }
                if !manager.queue.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(editMode == .active ? "Done" : "Edit") {
                            withAnimation {
                                editMode = editMode == .active ? .inactive : .active
                            }
                        }
                    }
                }
            }
        }
    }

    private func queueRow(_ item: QueueItem) -> some View {
        let isNowPlaying = manager.trackInfo?.title == item.title
            && manager.trackInfo?.artist == item.artist

        return HStack(spacing: 12) {
            AsyncImage(url: URL(string: item.albumArtURL ?? "")) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay { Image(systemName: "music.note").font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(isNowPlaying ? .bold : .regular))
                    .foregroundStyle(isNowPlaying ? .blue : .primary)
                    .lineLimit(1)
                Text(item.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isNowPlaying {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .symbolEffect(.variableColor.iterative, isActive: manager.isPlaying)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await manager.playTrackInQueue(item) }
        }
    }
}
