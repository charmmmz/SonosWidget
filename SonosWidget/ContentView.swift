import SwiftUI

struct ContentView: View {
    @State var manager = SonosManager()

    var body: some View {
        TabView {
            Tab("Player", systemImage: "play.circle.fill") {
                PlayerView(manager: manager)
            }
            Tab("Search", systemImage: "magnifyingglass") {
                SearchView(manager: manager)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .preferredColorScheme(.dark)
    }
}

#Preview { ContentView() }
