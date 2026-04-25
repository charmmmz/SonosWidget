// MUST stay structurally compatible with `SonosActivityAttributes.ContentState`
// in the iOS app (Shared/Models.swift). Apple's ActivityKit decodes the
// `content-state` JSON of an APNs liveactivity push using the iOS-side
// Codable shape, so any field name / type mismatch will silently fail to
// decode and the Live Activity won't update.
//
// Date fields use Apple's `.deferredToDate` JSONDecoder default which
// expects seconds since 2001-01-01 UTC (NSDate reference date), not Unix
// epoch. Convert with `toSwiftDate()` in apns.ts before sending.
export interface LiveActivityContentState {
  trackTitle: string;
  artist: string;
  album: string;
  isPlaying: boolean;
  positionSeconds: number;
  durationSeconds: number;

  // Optional fields — keys must remain optional in the same way iOS does
  // them, but JSON-omit when undefined so we don't ship explicit nulls
  // that confuse the Swift decoder.
  dominantColorHex?: string | null;
  startedAt?: number | null;        // Swift Date, seconds since 2001-01-01 UTC
  endsAt?: number | null;           // Swift Date, seconds since 2001-01-01 UTC
  albumArtThumbnail?: string | null; // base64 (Swift Data ↔ JSON)
  groupMemberCount: number;
  playbackSourceRaw?: string | null;
}

/// Minimal projection of what we keep in memory per Sonos coordinator. Built
/// from sonos-ts AVTransport / RenderingControl events.
export interface SonosGroupSnapshot {
  groupId: string;
  speakerName: string;
  trackTitle: string;
  artist: string;
  album: string;
  isPlaying: boolean;
  positionSeconds: number;
  durationSeconds: number;
  groupMemberCount: number;
  /// Wall-clock time at which `positionSeconds` was sampled. Used to derive
  /// the Swift-encoded `startedAt` / `endsAt` for the progress timer.
  sampledAt: Date;
}

export interface RegisterRequest {
  groupId: string;
  /// Hex string from `Activity.pushTokenUpdates` on iOS.
  token: string;
  /// Speaker name carried by `SonosActivityAttributes.speakerName` on iOS.
  /// We log it but the Live Activity itself is created on-device with the
  /// attributes — push updates only carry ContentState, not Attributes.
  attributes?: { speakerName?: string };
}

export interface TokenEntry extends RegisterRequest {
  /// ISO timestamp of registration; mostly for log auditing.
  registeredAt: string;
  /// Hash of the last ContentState we successfully shipped. Used to skip
  /// no-op pushes (e.g. positionSeconds drifting by 1 doesn't count).
  lastSentHash?: string;
}
