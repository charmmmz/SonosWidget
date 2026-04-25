import { SonosManager } from '@svrooij/sonos';
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

  // ---- internals --------------------------------------------------------

  private attachDeviceListeners(device: any): void {
    // sonos-ts devices have an Events emitter that re-emits a useful subset
    // of the underlying UPnP service events. We just need a "something
    // happened, please re-snapshot" trigger; the actual state we always pull
    // fresh via PositionInfo / TransportInfo to avoid event-payload drift
    // between firmware versions.
    try {
      device.Events.on('current-track', () => void this.refreshSnapshot(device));
      device.Events.on('transport-state', () => void this.refreshSnapshot(device));
      device.Events.on('group-name', () => void this.refreshSnapshot(device));
    } catch (err) {
      this.log.warn({ err, device: device.Name }, 'failed to attach device events');
    }
  }

  private async refreshSnapshot(device: any): Promise<void> {
    try {
      // Use the device's LAN IP as the group identifier so iOS and the
      // relay agree without an extra mapping step. iOS already knows the
      // coordinator's playbackIP; sending that as `groupId` matches the
      // `device.Host` we read here.
      const groupId: string = device.Host ?? device.Uuid;
      const transport = await device.AVTransportService.GetTransportInfo();
      const position = await device.AVTransportService.GetPositionInfo();

      const isPlaying = String(transport.CurrentTransportState) === 'PLAYING';
      const positionSeconds = parseDuration(position.RelTime ?? '00:00:00');
      const durationSeconds = parseDuration(position.TrackDuration ?? '00:00:00');

      // sonos-ts decodes the `currentTrack` event payload into structured
      // fields, but GetPositionInfo gives us back the raw DIDL — title /
      // artist / album live inside, so we either parse the DIDL or use the
      // device's lastTrack cache. The lastTrack cache is friendlier.
      const trackTitle = device.CurrentTrack?.Title ?? '';
      const artist = device.CurrentTrack?.Artist ?? '';
      const album = device.CurrentTrack?.Album ?? '';

      const snapshot: SonosGroupSnapshot = {
        groupId,
        speakerName: device.Name ?? device.Uuid,
        trackTitle,
        artist,
        album,
        isPlaying,
        positionSeconds,
        durationSeconds,
        // Manager doesn't always know the live group size from here; default 1
        // and let the iOS app continue to drive groupMemberCount for the
        // local-update path. We can refine in a Phase 1.5 if needed.
        groupMemberCount: 1,
        sampledAt: new Date(),
      };

      this.snapshots.set(groupId, snapshot);
      this.emit('change', snapshot);
    } catch (err) {
      this.log.warn(
        { err, device: device.Name },
        'snapshot refresh failed — will retry on next event',
      );
    }
  }
}

/// Parse `HH:MM:SS` (Sonos's RelTime / TrackDuration format) → seconds.
function parseDuration(s: string): number {
  const parts = s.split(':').map(Number);
  if (parts.length !== 3 || parts.some(Number.isNaN)) return 0;
  return parts[0]! * 3600 + parts[1]! * 60 + parts[2]!;
}
