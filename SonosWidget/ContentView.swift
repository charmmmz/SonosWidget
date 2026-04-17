import SwiftUI

struct ContentView: View {
    @State var manager = SonosManager()

    var body: some View {
        TabView {
            Tab("Home", systemImage: "play.circle.fill") {
                PlayerView(manager: manager)
            }
            Tab("Search", systemImage: "magnifyingglass") {
                SearchView(manager: manager)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(manager.albumArtDominantColor ?? .blue)
        .overlay {
            // Use physical screen height so the overlay is guaranteed off-screen when closed.
            let screenH = UIScreen.main.bounds.height
            // miniPlayerDragOffset dual meaning:
            //   < 0  → user dragging mini-player UP  (open gesture)
            //   > 0  → user dragging full player DOWN (close gesture)
            //   = 0  → idle
            let overlayY: CGFloat = {
                if manager.showFullPlayer {
                    // Player open: drag-down offset managed locally inside NowPlayingOverlay.
                    return 0
                } else {
                    // Player closed: slide in from bottom as user drags up
                    let draggedIn = -manager.miniPlayerDragOffset * (1.0 / 0.55)
                    return max(0, screenH - draggedIn)
                }
            }()

            if manager.isConfigured {
                NowPlayingOverlay(manager: manager)
                    .offset(y: overlayY)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: manager.showFullPlayer)
                    .allowsHitTesting(manager.showFullPlayer || manager.miniPlayerDragOffset < -5)
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview { ContentView() }
