import SwiftUI
import UIKit
import BackgroundTasks
import WidgetKit
import ActivityKit

@main
struct SonosWidgetApp: App {

    static let bgRefreshID = "com.charm.SonosWidget.refresh"

    init() {
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithTransparentBackground()
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithTransparentBackground()
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgRefreshID, using: nil) { task in
            Self.handleBackgroundRefresh(task: task as! BGAppRefreshTask)
        }

        // iOS does NOT reliably fire willTerminateNotification on force-quit,
        // so clean up any orphaned Live Activities from a previous session here.
        for activity in Activity<SonosActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    guard url.scheme == "sonoswidget" else { return }
                    Task { await SonosAuth.shared.handleCallback(url: url) }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    Self.scheduleBackgroundRefresh()
                }
        }
    }

    // MARK: - Background Refresh

    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: bgRefreshID)
        // Ask to be woken up in ~15 minutes; system may delay but will try.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func handleBackgroundRefresh(task: BGAppRefreshTask) {
        // Schedule the next refresh before doing any work.
        scheduleBackgroundRefresh()

        let refreshTask = Task {
            guard let ip = SharedStorage.coordinatorIP ?? SharedStorage.speakerIP else {
                task.setTaskCompleted(success: false)
                return
            }

            do {
                // Fetch current playback state from the Sonos device.
                async let transportState = SonosAPI.getTransportInfo(ip: ip)
                async let trackInfo = SonosAPI.getPositionInfo(ip: ip)

                let state = try await transportState
                let track = try await trackInfo

                let titleChanged = track.title != SharedStorage.cachedTrackTitle
                let playStateChanged = (state == .playing) != SharedStorage.isPlaying

                // Update shared storage.
                SharedStorage.isPlaying = state == .playing
                SharedStorage.cachedTrackTitle = track.title
                SharedStorage.cachedArtist = track.artist
                SharedStorage.cachedAlbum = track.album
                SharedStorage.cachedAlbumArtURL = track.albumArtURL

                if titleChanged || playStateChanged {
                    WidgetCenter.shared.reloadAllTimelines()
                }

                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            refreshTask.cancel()
        }
    }
}
