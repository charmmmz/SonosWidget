import type { Logger } from 'pino';

import { HueClipClient } from './hueClient.js';
import type { HueAmbienceConfigStore } from './hueConfigStore.js';
import { paletteForSnapshot } from './hueAlbumArtPalette.js';
import { rotatePalette } from './huePalette.js';
import { applyHuePalette, resolveHueTargets, stopHueTargets } from './hueRenderer.js';
import type {
  HueAmbienceRuntimeConfig,
  HueAmbienceServiceStatus,
  HueLightClient,
  HueRGBColor,
  HueResolvedAmbienceTarget,
  HueSnapshot,
} from './hueTypes.js';

type HuePaletteProvider = (snapshot: HueSnapshot) => Promise<HueRGBColor[]> | HueRGBColor[];

export class HueAmbienceService {
  private config: HueAmbienceRuntimeConfig | null = null;
  private activeTimer: NodeJS.Timeout | null = null;
  private activeTargets: HueResolvedAmbienceTarget[] = [];
  private activeTrackKey: string | null = null;
  private activeGroupId: string | null = null;
  private lastError: string | null = null;

  constructor(
    private readonly store: HueAmbienceConfigStore,
    private readonly log: Logger,
    private readonly clientFactory: (config: HueAmbienceRuntimeConfig) => HueLightClient = config =>
      new HueClipClient(config.bridge, config.applicationKey),
    private readonly paletteProvider: HuePaletteProvider = paletteForSnapshot,
  ) {}

  async load(): Promise<void> {
    this.config = await this.store.load();
  }

  async saveConfig(config: HueAmbienceRuntimeConfig): Promise<void> {
    await this.stopActive();
    await this.store.save(config);
    this.config = this.store.current;
    this.lastError = null;
  }

  async clearConfig(): Promise<void> {
    await this.stopActive();
    await this.store.clear();
    this.config = null;
    this.lastError = null;
  }

  async stop(): Promise<void> {
    await this.stopActive();
  }

  status(): HueAmbienceServiceStatus {
    return {
      ...this.store.status(),
      runtimeActive: this.activeTimer !== null || this.activeTargets.length > 0,
      activeGroupId: this.activeGroupId,
      lastTrackKey: this.activeTrackKey,
      lastError: this.lastError,
    };
  }

  receiveSnapshot(snapshot: HueSnapshot): void {
    const config = this.config;
    if (!config || !config.enabled) {
      void this.stopActive();
      return;
    }

    if (!snapshot.isPlaying) {
      void this.stopActive();
      return;
    }

    const targets = resolveHueTargets(config, snapshot);
    if (targets.length === 0) {
      void this.stopActive();
      this.lastError = 'No Hue area mapped for the active Sonos group';
      return;
    }

    const trackKey = [
      snapshot.groupId,
      snapshot.trackTitle,
      snapshot.artist,
      snapshot.album,
      snapshot.albumArtUri,
    ].join('|');
    if (trackKey === this.activeTrackKey && this.activeTargets.length > 0) {
      return;
    }

    void this.startForSnapshot(config, snapshot, targets, trackKey);
  }

  private async startForSnapshot(
    config: HueAmbienceRuntimeConfig,
    snapshot: HueSnapshot,
    targets: HueResolvedAmbienceTarget[],
    trackKey: string,
  ): Promise<void> {
    await this.stopActive(false);
    this.activeTargets = targets;
    this.activeTrackKey = trackKey;
    this.activeGroupId = snapshot.groupId;
    this.lastError = null;

    const client = this.clientFactory(config);
    const palette = await this.paletteProvider(snapshot);
    const intervalSeconds = Math.max(config.flowIntervalSeconds, 1);

    let step = 0;
    const apply = async () => {
      try {
        const nextPalette = config.motionStyle === 'flowing'
          ? rotatePalette(palette, step)
          : palette;
        await applyHuePalette(client, targets, nextPalette, config.motionStyle === 'flowing' ? intervalSeconds : 4);
        step += 1;
      } catch (err) {
        this.lastError = err instanceof Error ? err.message : String(err);
        this.log.warn({ err, groupId: snapshot.groupId }, 'Hue ambience update failed');
      }
    };

    await apply();
    if (config.motionStyle === 'flowing' && palette.length > 1) {
      this.activeTimer = setInterval(() => {
        void apply();
      }, intervalSeconds * 1000);
    }
  }

  private async stopActive(applyStopBehavior = true): Promise<void> {
    if (this.activeTimer) {
      clearInterval(this.activeTimer);
      this.activeTimer = null;
    }

    const config = this.config;
    const targets = this.activeTargets;
    this.activeTargets = [];
    this.activeTrackKey = null;
    this.activeGroupId = null;

    if (!applyStopBehavior || !config || config.stopBehavior !== 'turnOff' || targets.length === 0) {
      return;
    }

    try {
      await stopHueTargets(this.clientFactory(config), targets);
    } catch (err) {
      this.lastError = err instanceof Error ? err.message : String(err);
      this.log.warn({ err }, 'Hue ambience stop failed');
    }
  }
}
