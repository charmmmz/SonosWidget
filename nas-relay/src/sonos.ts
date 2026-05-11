import { SonosEvents, SonosManager, type SonosDevice } from '@svrooij/sonos';
import { EventEmitter } from 'node:events';
import type { Logger } from 'pino';
import type { SonosGroupSnapshot } from './types.js';

/// Wraps @svrooij/sonos to give us a single clean event stream:
///   `change` (groupId, snapshot)
/// fired whenever any meaningful field shifts on any coordinator. The
/// underlying lib emits a flurry of granular events (current-track, volume,
/// transport-state, playback-stopped, etc.) that we collapse into one snapshot
/// per group so the consumer only needs one handler.
export class SonosBridge extends EventEmitter {
  private readonly manager = new SonosManager();
  private readonly snapshots = new Map<string, SonosGroupSnapshot>();
  private readonly refreshSequences = new Map<string, number>();
  private readonly log: Logger;
  private periodicHandle: NodeJS.Timeout | null = null;

  constructor(log: Logger) {
    super();
    this.log = log.child({ module: 'sonos' });
  }

  async start(seedIp: string): Promise<void> {
    this.log.info({ seedIp }, 'discovering Sonos household via seed IP');
    const ok = await this.manager.InitializeFromDevice(seedIp);
    if (!ok) {
      throw new Error(`Sonos seed ${seedIp} did not respond — verify the IP`);
    }

    for (const device of this.manager.Devices) {
      this.log.info(
        { name: device.Name, host: device.Host, uuid: device.Uuid },
        'attached Sonos device',
      );
      this.attachDeviceListeners(device);
      // Prime the snapshot table so a register-activity coming in immediately
      // can ship something useful even before the first Sonos event fires.
      void this.refreshSnapshot(device).catch(err =>
        this.log.warn({ err, device: device.Name }, 'initial snapshot fetch failed'),
      );
    }

    // Belt-and-braces: poll once a minute as a safety net in case GENA
    // subscriptions silently expire (Sonos firmware bug; renews are auto
    // but rare hiccups aren't unheard of).
    this.periodicHandle = setInterval(() => {
      for (const device of this.manager.Devices) {
        void this.refreshSnapshot(device).catch(() => undefined);
      }
    }, 60_000);
  }

  stop(): void {
    if (this.periodicHandle) clearInterval(this.periodicHandle);
    this.manager.CancelSubscription();
  }

  /// Latest known snapshot for a group, or undefined if we haven't sampled yet.
  current(groupId: string): SonosGroupSnapshot | undefined {
    return this.snapshots.get(groupId);
  }

  allSnapshots(): SonosGroupSnapshot[] {
    return Array.from(this.snapshots.values());
  }

  /// Coordinator IP used as `groupId` by iOS / relay health — resolve group coordinator.
  resolveCoordinator(groupId: string): SonosDevice | undefined {
    for (const device of this.manager.Devices) {
      const coord = device.Coordinator;
      if (coord.Host === groupId) return coord;
    }
    return undefined;
  }

  async pullFreshSnapshot(groupId: string): Promise<SonosGroupSnapshot | undefined> {
    const coord = this.resolveCoordinator(groupId);
    if (!coord) return undefined;
    await this.refreshSnapshot(coord);
    return this.snapshots.get(groupId);
  }

  async play(groupId: string): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    await coord.Play();
    await this.refreshSnapshot(coord);
  }

  async pause(groupId: string): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    await coord.Pause();
    await this.refreshSnapshot(coord);
  }

  async next(groupId: string): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    await coord.Next();
    await this.refreshSnapshot(coord);
  }

  async previous(groupId: string): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    await coord.Previous();
    await this.refreshSnapshot(coord);
  }

  async setGroupVolume(groupId: string, volume: number): Promise<void> {
    const coord = this.requireCoordinator(groupId);
    const v = Math.min(100, Math.max(0, Math.round(volume)));
    await coord.GroupRenderingControlService.SetGroupVolume({
      InstanceID: 0,
      DesiredVolume: v,
    });
    await this.refreshSnapshot(coord);
  }

  private requireCoordinator(groupId: string): SonosDevice {
    const coord = this.resolveCoordinator(groupId);
    if (!coord) {
      throw new Error(`unknown_group: no coordinator matches groupId ${groupId}`);
    }
    return coord;
  }

  // ---- internals --------------------------------------------------------

  private attachDeviceListeners(device: any): void {
    // sonos-ts devices have an Events emitter that re-emits a useful subset
    // of the underlying UPnP service events. We just need a "something
    // happened, please re-snapshot" trigger; the actual state we always pull
    // fresh via PositionInfo / TransportInfo to avoid event-payload drift
    // between firmware versions.
    try {
      device.Events.on(SonosEvents.AVTransport, () => void this.refreshSnapshot(device));
      device.Events.on(SonosEvents.CurrentTrackUri, () => void this.refreshSnapshot(device));
      device.Events.on(SonosEvents.CurrentTrackMetadata, () => void this.refreshSnapshot(device));
      device.Events.on(SonosEvents.CurrentTransportState, () => void this.refreshSnapshot(device));
      device.Events.on(SonosEvents.CurrentTransportStateSimple, () => void this.refreshSnapshot(device));
      device.Events.on(SonosEvents.PlaybackStopped, () => void this.refreshSnapshot(device));
      device.Events.on(SonosEvents.GroupName, () => void this.refreshSnapshot(device));
    } catch (err) {
      this.log.warn({ err, device: device.Name }, 'failed to attach device events');
    }
  }

  private async refreshSnapshot(device: any): Promise<void> {
    let groupId: string | null = null;
    let refreshSequence = 0;
    try {
      // Use the coordinator LAN IP as the group identifier so iOS and the
      // relay agree without an extra mapping step. iOS sends `playbackIP`,
      // which is `coordinatorIP ?? ipAddress`.
      const coordinator = device.Coordinator ?? device;
      const resolvedGroupId = firstNonEmpty(coordinator.Host, device.Host, device.Uuid);
      if (!resolvedGroupId) {
        throw new Error(`missing Sonos group id for ${device.Name ?? 'unknown device'}`);
      }
      groupId = resolvedGroupId;
      refreshSequence = this.beginRefresh(resolvedGroupId);
      const transport = await coordinator.AVTransportService.GetTransportInfo();
      const position = await coordinator.AVTransportService.GetPositionInfo();
      if (!this.isCurrentRefresh(resolvedGroupId, refreshSequence)) return;

      const isPlaying = String(transport.CurrentTransportState) === 'PLAYING';
      const trackUri = firstNonEmpty(position.TrackURI, coordinator.CurrentTrackUri, device.CurrentTrackUri);
      const playbackSourceRaw = playbackSourceFromTrackUri(trackUri);
      const positionSeconds = parseDuration(position.RelTime ?? '00:00:00');
      const durationSeconds = parseDuration(position.TrackDuration ?? '00:00:00');
      const metadata = trackMetadataFromMetadata(position.TrackMetaData);

      // sonos-ts decodes the `currentTrack` event payload into structured
      // fields, but GetPositionInfo gives us back the raw DIDL — title /
      // artist / album live inside, so we either parse the DIDL or use the
      // device's lastTrack cache. The lastTrack cache is friendlier.
      const trackTitle = firstNonEmpty(coordinator.CurrentTrack?.Title, device.CurrentTrack?.Title, metadata.title);
      const artist = firstNonEmpty(coordinator.CurrentTrack?.Artist, device.CurrentTrack?.Artist, metadata.artist);
      const album = firstNonEmpty(coordinator.CurrentTrack?.Album, device.CurrentTrack?.Album, metadata.album);
      const albumArtUri = absoluteAlbumArtUri(
        coordinator.CurrentTrack?.AlbumArtUri
          ?? coordinator.CurrentTrack?.AlbumArtURI
          ?? device.CurrentTrack?.AlbumArtUri
          ?? device.CurrentTrack?.AlbumArtURI
          ?? metadata.albumArtUri,
        coordinator.Host ?? device.Host ?? resolvedGroupId,
      );

      const snapshot: SonosGroupSnapshot = {
        groupId: resolvedGroupId,
        speakerName: coordinator.Name ?? device.Name ?? device.Uuid,
        trackTitle,
        artist,
        album,
        albumArtUri,
        isPlaying,
        playbackSourceRaw,
        musicAmbienceEligible: isMusicAmbienceEligibleForSnapshot({
          trackTitle,
          artist,
          album,
          albumArtUri,
          playbackSourceRaw,
        }),
        positionSeconds,
        durationSeconds,
        // Manager doesn't always know the live group size from here; default 1
        // and let the iOS app continue to drive groupMemberCount for the
        // local-update path. We can refine in a Phase 1.5 if needed.
        groupMemberCount: 1,
        sampledAt: new Date(),
      };

      this.snapshots.set(resolvedGroupId, snapshot);
      this.emit('change', snapshot);
    } catch (err) {
      if (groupId && !this.isCurrentRefresh(groupId, refreshSequence)) return;
      this.log.warn(
        { err, device: device.Name },
        'snapshot refresh failed — will retry on next event',
      );
    }
  }

  private beginRefresh(groupId: string): number {
    const sequence = (this.refreshSequences.get(groupId) ?? 0) + 1;
    this.refreshSequences.set(groupId, sequence);
    return sequence;
  }

  private isCurrentRefresh(groupId: string, sequence: number): boolean {
    return this.refreshSequences.get(groupId) === sequence;
  }
}

/// Parse `HH:MM:SS` (Sonos's RelTime / TrackDuration format) → seconds.
function parseDuration(s: string): number {
  const parts = s.split(':').map(Number);
  if (parts.length !== 3 || parts.some(Number.isNaN)) return 0;
  return parts[0]! * 3600 + parts[1]! * 60 + parts[2]!;
}

export function albumArtUriFromMetadata(metadata: unknown): string | null {
  return trackMetadataFromMetadata(metadata).albumArtUri;
}

export function playbackSourceFromTrackUri(trackUri: unknown): string | null {
  if (typeof trackUri !== 'string') return null;
  const uri = trackUri.trim().toLowerCase();
  if (uri.length === 0) return null;

  if (uri.startsWith('x-sonos-spotify:') || uri.includes('sid=9&') || uri.endsWith('sid=9')) return 'spotify';
  if (uri.startsWith('x-sonosprog-http:') || uri.includes('sid=204')) return 'appleMusic';
  if (uri.includes('sid=203')) return 'amazonMusic';
  if (uri.includes('sid=174')) return 'tidal';
  if (uri.includes('sid=284')) return 'youtubeMusic';
  if (uri.startsWith('x-sonos-htastream:')) return 'tv';
  if (uri.startsWith('x-sonos-vli:') || uri.startsWith('x-rincon-stream:')) return 'airplay';
  if (
    uri.startsWith('x-sonosapi-stream:')
    || uri.startsWith('x-sonosapi-radio:')
    || uri.startsWith('x-rincon-mp3radio:')
    || uri.startsWith('aac:')
  ) {
    return 'radio';
  }
  if (uri.startsWith('x-file-cifs:') || uri.startsWith('x-rincon-playlist:')) return 'library';
  return null;
}

export function isMusicAmbienceEligibleForSnapshot(snapshot: {
  trackTitle?: string | null;
  artist?: string | null;
  album?: string | null;
  albumArtUri?: string | null;
  playbackSourceRaw?: string | null;
}): boolean {
  if (snapshot.playbackSourceRaw === 'tv' || snapshot.playbackSourceRaw === 'lineIn') {
    return false;
  }

  if (snapshot.albumArtUri && snapshot.albumArtUri.trim().length > 0) return true;

  const title = normalizedMetadata(snapshot.trackTitle);
  const artist = normalizedMetadata(snapshot.artist);
  const album = normalizedMetadata(snapshot.album);
  if (!title) return false;

  if (snapshot.playbackSourceRaw && snapshot.playbackSourceRaw !== 'unknown') return true;
  return Boolean(artist || album);
}

export interface SonosTrackMetadata {
  title: string | null;
  artist: string | null;
  album: string | null;
  albumArtUri: string | null;
}

export function trackMetadataFromMetadata(metadata: unknown): SonosTrackMetadata {
  if (!metadata) {
    return emptyTrackMetadata();
  }
  if (typeof metadata !== 'string') {
    return trackMetadataFromTrackObject(metadata);
  }

  return {
    title: xmlTagValue(metadata, 'dc:title'),
    artist: xmlTagValue(metadata, 'dc:creator') ?? xmlTagValue(metadata, 'upnp:artist'),
    album: xmlTagValue(metadata, 'upnp:album'),
    albumArtUri: xmlTagValue(metadata, 'upnp:albumArtURI'),
  };
}

function trackMetadataFromTrackObject(metadata: unknown): SonosTrackMetadata {
  if (!metadata || typeof metadata !== 'object') return emptyTrackMetadata();
  const track = metadata as Record<string, unknown>;

  return {
    title: firstObjectString(track.Title, track.title),
    artist: firstObjectString(track.Artist, track.artist, track.Creator, track.creator),
    album: firstObjectString(track.Album, track.album),
    albumArtUri: firstObjectString(track.AlbumArtUri, track.AlbumArtURI, track.albumArtUri),
  };
}

function emptyTrackMetadata(): SonosTrackMetadata {
  return {
    title: null,
    artist: null,
    album: null,
    albumArtUri: null,
  };
}

function normalizedMetadata(value: string | null | undefined): string {
  const normalized = (value ?? '').trim().toLowerCase();
  return normalized === 'unknown' ? '' : normalized;
}

function xmlTagValue(xml: string, tag: string): string | null {
  const escapedTag = tag.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = xml.match(new RegExp(`<${escapedTag}[^>]*>([^<]+)<\\/${escapedTag}>`, 'i'));
  const value = match?.[1] ? decodeXmlEntities(match[1]).trim() : '';
  return value.length > 0 ? value : null;
}

function firstNonEmpty(...values: Array<string | null | undefined>): string {
  return firstObjectString(...values) ?? '';
}

function firstObjectString(...values: unknown[]): string | null {
  for (const value of values) {
    if (typeof value !== 'string') continue;
    const trimmed = value.trim();
    if (trimmed.length > 0) return trimmed;
  }
  return null;
}

function absoluteAlbumArtUri(uri: string | null | undefined, host: string | undefined): string | null {
  if (!uri) return null;
  if (/^https?:\/\//i.test(uri)) return uri;
  if (!host) return uri;
  const path = uri.startsWith('/') ? uri : `/${uri}`;
  return `http://${host}:1400${path}`;
}

function decodeXmlEntities(value: string): string {
  return value
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'");
}
