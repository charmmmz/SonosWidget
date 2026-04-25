import Foundation

/// Categorized logger for Sonos Widget.
///
/// Three levels:
///   - `.error` — always emitted, prefixed `[Category] ERROR:` so it stands
///     out during user-reported bug hunts.
///   - `.info`  — always emitted. Reserve for successful state transitions
///     and summary counts (e.g. "Added to favorites", "Refreshed N items").
///   - `.debug` — stripped at compile time in Release builds via `#if DEBUG`.
///     Use for verbose request/response traces, internal fallback decisions,
///     and diagnostic banners that would otherwise spam the console.
///
/// Every call site picks a `Category` so filtering in Xcode console is easy
/// (search e.g. `[Playback]` to see all playback logs).
enum SonosLog {
    /// All log categories used across the app. Add new cases here rather
    /// than inventing bare-string prefixes at call sites.
    enum Category: String {
        case search         = "Search"
        case playback       = "Playback"
        case station        = "Station"
        case favorites      = "Favorites"
        case cloudAPI       = "CloudAPI"
        case cloudSearch    = "CloudSearch"
        case soap           = "SOAP"
        case sonosCloud     = "SonosCloud"
        case sonosAuth      = "SonosAuth"
        case artistDetail   = "ArtistDetail"
        case albumDetail    = "AlbumDetail"
        case playlistDetail = "PlaylistDetail"
        case nowPlaying     = "NowPlaying"
        case parseCloudIds  = "parseCloudIds"
        case navItem        = "NavItem"
        case tv             = "TV"
    }

    /// Always logged. Use sparingly for unexpected failures worth reporting.
    @inline(__always)
    static func error(_ category: Category, _ message: @autoclosure () -> String) {
        print("[\(category.rawValue)] ERROR: \(message())")
    }

    /// Always logged. Use for operational signal (success, counts, state).
    @inline(__always)
    static func info(_ category: Category, _ message: @autoclosure () -> String) {
        print("[\(category.rawValue)] \(message())")
    }

    /// Compiled out of Release builds. Use for high-volume traces and
    /// internal details that would otherwise drown the console.
    @inline(__always)
    static func debug(_ category: Category, _ message: @autoclosure () -> String) {
        #if DEBUG
        print("[\(category.rawValue)] \(message())")
        #endif
    }
}
