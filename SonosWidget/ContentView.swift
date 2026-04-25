import SwiftUI

struct ContentView: View {
    @State var manager = SonosManager()
    @State var searchManager = SearchManager()

    var body: some View {
        TabView {
            Tab("Home", systemImage: "play.circle.fill") {
                PlayerView(manager: manager, searchManager: searchManager)
                    .miniPlayerLegacyInsetIfNeeded(manager: manager)
            }
            Tab("Browse", systemImage: "magnifyingglass") {
                SearchView(manager: manager, searchManager: searchManager)
                    .miniPlayerLegacyInsetIfNeeded(manager: manager)
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView(manager: manager, searchManager: searchManager)
                    .miniPlayerLegacyInsetIfNeeded(manager: manager)
            }
        }
        .tint(manager.albumArtDominantColor ?? .blue)
        .tabBarMinimizeOnScrollIfAvailable()
        .miniPlayerSystemAccessoryIfAvailable(manager: manager)
        // Bound to the shared `manager.showingAddSpeaker` flag so either the
        // first-run setup screen or the Settings tab can flip it from any tab.
        .sheet(isPresented: $manager.showingAddSpeaker) {
            AddSpeakerSheet(manager: manager)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: manager.showFullPlayer)
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
        .onAppear {
            manager.startAutoRefresh()
            // Kick the relay watchdog so the Live Activity path can flip to
            // APNs mode the moment the NAS is reachable, without making the
            // user open Settings first.
            RelayManager.shared.startPeriodicProbe()
        }
        .onDisappear {
            manager.stopAutoRefresh()
            RelayManager.shared.stopPeriodicProbe()
        }
    }
}

#Preview { ContentView() }
