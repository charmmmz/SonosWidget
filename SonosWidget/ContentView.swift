import SwiftUI

struct ContentView: View {
    @State var manager = SonosManager()
    @State var searchManager = SearchManager()

    var body: some View {
        TabView {
            Tab("Home", systemImage: "play.circle.fill") {
                PlayerView(manager: manager, searchManager: searchManager)
            }
            Tab("Search", systemImage: "magnifyingglass") {
                SearchView(manager: manager, searchManager: searchManager)
            }
        }
        .tint(manager.albumArtDominantColor ?? .blue)
        .overlay {
            GeometryReader { geo in
                let screenH = geo.size.height + geo.safeAreaInsets.bottom
                let overlayY: CGFloat = {
                    if manager.showFullPlayer {
                        return 0
                    } else {
                        let draggedIn = -manager.miniPlayerDragOffset * (1.0 / 0.55)
                        return max(0, screenH - draggedIn)
                    }
                }()

                if manager.isConfigured {
                    NowPlayingOverlay(manager: manager, searchManager: searchManager)
                        .offset(y: overlayY)
                        .allowsHitTesting(manager.showFullPlayer || manager.miniPlayerDragOffset < -5)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { manager.startAutoRefresh() }
        .onDisappear { manager.stopAutoRefresh() }
    }
}

#Preview { ContentView() }
