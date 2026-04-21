# SonosWidget

An iOS app that brings **Dynamic Island**, **Live Activity**, and **Home Screen Widget** support to Sonos speakers.

Built as a personal project to fill the gap — the official Sonos app doesn't support these iOS features.

## Features

- **Dynamic Island** — see what's playing at a glance, with playback controls
- **Live Activity** — real-time track info and controls on the Lock Screen
- **Home Screen Widget** — album art, track info, and quick actions
- **Full Playback Control** — play/pause, skip, shuffle, repeat, volume
- **Speaker Management** — auto-discovery via SSDP, grouping/ungrouping
- **Queue Management** — view, reorder, and manage the play queue
- **Music Search** — browse and play from linked services (Spotify, Apple Music, Tidal, etc.)
- **Adaptive Theming** — UI accent color extracted from album art

## Tech

- Swift / SwiftUI
- ActivityKit (Live Activities & Dynamic Island)
- WidgetKit (Home Screen Widget)
- AppIntents (interactive widget controls)
- Sonos local API + Sonos Cloud API (OAuth)
- SSDP for speaker discovery

## Requirements

- iOS 18+
- Sonos speakers on the same local network

## Setup

1. Clone the repo
2. Open `SonosWidget.xcodeproj` in Xcode
3. Build and run on a real device (widgets and Live Activities require a physical device)
4. The app will auto-discover Sonos speakers on your network

## License

This is a personal project. Feel free to reference or learn from the code.
