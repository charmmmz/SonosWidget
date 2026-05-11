import type { Logger } from 'pino';

import { HueClipClient } from './hueClient.js';
import { buildHueAmbienceFrame, type HueAmbienceFrame } from './hueAmbienceFrames.js';
import type { HueAmbienceConfigStore } from './hueConfigStore.js';
import { paletteForSnapshot } from './hueAlbumArtPalette.js';
import { ClipHueAmbienceRenderer, type HueAmbienceRenderer } from './hueFrameRenderer.js';
import { resolveHueTargets } from './hueRenderer.js';
import type {
  HueAmbienceRenderMode,
  HueAmbienceRuntimeConfig,
  HueAmbienceServiceStatus,
  HueLightClient,
  HueRGBColor,
  HueResolvedAmbienceTarget,
  HueSnapshot,
} from './hueTypes.js';

type HuePaletteProvider = (snapshot: HueSnapshot) => Promise<HueRGBColor[]> | HueRGBColor[];

export const DEFAULT_STOP_GRACE_MS = 4_000;

export class HueAmbienceService {
  private config: HueAmbienceRuntimeConfig | null = null;
  private activeTimer: NodeJS.Timeout | null = null;
  private stopTimer: NodeJS.Timeout | null = null;
  private activeTargets: HueResolvedAmbienceTarget[] = [];
  private activeTrackKey: string | null = null;
  private activeGroupId: string | null = null;
  private lastError: string | null = null;
  private runID = 0;
  private activeFrame: HueAmbienceFrame | null = null;
  private pendingStopFrame: HueAmbienceFrame | null = null;
  private lastFrameAt: string | null = null;
  private activeRenderMode: HueAmbienceRenderMode | null = null;
  private entertainmentTargetActive = false;
  private activeEntertainmentMetadataComplete = false;

  constructor(
    private readonly store: HueAmbienceConfigStore,
    private readonly log: Logger,
    private readonly clientFactory: (config: HueAmbienceRuntimeConfig) => HueLightClient = config =>
      new HueClipClient(config.bridge, config.applicationKey),
    private readonly paletteProvider: HuePaletteProvider = paletteForSnapshot,
    private readonly stopGraceMs = DEFAULT_STOP_GRACE_MS,
    private readonly rendererFactory: (
      config: HueAmbienceRuntimeConfig,
      client: HueLightClient,
    ) => HueAmbienceRenderer = (_config, client) => new ClipHueAmbienceRenderer(client),
  ) {}

  async load(): Promise<void> {
    this.config = await this.store.load();
  }

  async saveConfig(config: HueAmbienceRuntimeConfig): Promise<void> {
    this.cancelScheduledStop();
    this.cancelPendingWork();
    await this.stopActive();
    await this.store.save(config);
    this.config = this.store.current;
    this.lastError = null;
  }

  async clearConfig(): Promise<void> {
    this.cancelScheduledStop();
    this.cancelPendingWork();
    await this.stopActive();
    await this.store.clear();
    this.config = null;
    this.lastError = null;
  }

  async stop(): Promise<void> {
    this.cancelScheduledStop();
    this.cancelPendingWork();
    await this.stopActive();
  }

  status(): HueAmbienceServiceStatus {
    return {
      ...this.store.status(),
      runtimeActive: this.activeTimer !== null || this.activeTargets.length > 0,
      activeGroupId: this.activeGroupId,
      lastTrackKey: this.activeTrackKey,
      lastError: this.lastError,
      activeTargetIds: this.activeTargets.map(target => target.area.id),
      renderMode: this.activeRenderMode,
      entertainmentTargetActive: this.entertainmentTargetActive,
      entertainmentMetadataComplete: this.activeEntertainmentMetadataComplete,
      lastFrameAt: this.lastFrameAt,
    };
  }

  receiveSnapshot(snapshot: HueSnapshot): void {
    const config = this.config;
    if (!config || !config.enabled) {
      this.cancelScheduledStop();
      this.cancelPendingWork();
      void this.stopActive();
      return;
    }

    if (!snapshot.isPlaying) {
      if (this.snapshotIsUnrelatedToActiveGroup(snapshot)) return;
      this.scheduleStopActive();
      return;
    }

    if (snapshot.musicAmbienceEligible === false) {
      if (this.snapshotIsUnrelatedToActiveGroup(snapshot)) return;
      this.scheduleStopActive();
      this.lastError = null;
      return;
    }

    const targets = resolveHueTargets(config, snapshot);
    if (targets.length === 0) {
      if (this.snapshotIsUnrelatedToActiveGroup(snapshot)) return;
      this.scheduleStopActive();
      this.lastError = null;
      return;
    }

    this.cancelScheduledStop();

    const trackKey = [
      snapshot.groupId,
      snapshot.trackTitle,
      snapshot.artist,
      snapshot.album,
      snapshot.albumArtUri,
    ].join('|');
    if (trackKey === this.activeTrackKey && this.activeTargets.length > 0 && this.activeFrame) {
      return;
    }

    const runID = this.cancelPendingWork();
    void this.startForSnapshot(config, snapshot, targets, trackKey, runID);
  }

  private async startForSnapshot(
    config: HueAmbienceRuntimeConfig,
    snapshot: HueSnapshot,
    targets: HueResolvedAmbienceTarget[],
    trackKey: string,
    runID: number,
  ): Promise<void> {
    await this.stopActive(false);
    if (!this.isCurrentRun(runID)) return;

    this.activeTargets = targets;
    this.activeTrackKey = trackKey;
    this.activeGroupId = snapshot.groupId;
    this.lastError = null;

    const client = this.clientFactory(config);
    const renderer = this.rendererFactory(config, client);
    const intervalSeconds = Math.max(config.flowIntervalSeconds, 1);
    const transitionSeconds = config.motionStyle === 'flowing' ? intervalSeconds : 4;
    this.pendingStopFrame = this.buildStopFrame(targets, snapshot, transitionSeconds);

    const palette = await this.paletteProvider(snapshot);
    if (!this.isCurrentRun(runID)) return;

    let step = 0;
    const apply = async (): Promise<boolean> => {
      if (!this.isCurrentRun(runID)) return false;
      try {
        const frame = buildHueAmbienceFrame({
          targets,
          palette,
          snapshot,
          phase: config.motionStyle === 'flowing' ? step : 0,
          transitionSeconds,
          reason: step === 0 ? 'trackChange' : 'steady',
        });
        await renderer.render(frame);
        this.activeFrame = frame;
        this.activeRenderMode = frame.mode;
        this.entertainmentTargetActive = frame.targets.some(target => target.area.kind === 'entertainmentArea');
        this.activeEntertainmentMetadataComplete = frame.metadataComplete;
        this.lastFrameAt = frame.createdAt.toISOString();
        step += 1;
        return true;
      } catch (err) {
        this.lastError = err instanceof Error ? err.message : String(err);
        this.log.warn({ err, groupId: snapshot.groupId }, 'Hue ambience update failed');
        return false;
      }
    };

    const initialRenderSucceeded = await apply();
    if (!this.isCurrentRun(runID)) return;
    if (!initialRenderSucceeded) {
      await this.stopActive();
      return;
    }

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
    const frame = this.activeFrame ?? this.pendingStopFrame;
    this.clearActiveState();

    if (!applyStopBehavior || !config || config.stopBehavior !== 'turnOff' || !frame) {
      return;
    }

    try {
      await this.rendererFactory(config, this.clientFactory(config)).stop({ ...frame, reason: 'stop' });
    } catch (err) {
      this.lastError = err instanceof Error ? err.message : String(err);
      this.log.warn({ err }, 'Hue ambience stop failed');
    }
  }

  private clearActiveState(): void {
    this.activeTargets = [];
    this.activeTrackKey = null;
    this.activeGroupId = null;
    this.activeFrame = null;
    this.pendingStopFrame = null;
    this.activeRenderMode = null;
    this.entertainmentTargetActive = false;
    this.activeEntertainmentMetadataComplete = false;
  }

  private buildStopFrame(
    targets: HueResolvedAmbienceTarget[],
    snapshot: HueSnapshot,
    transitionSeconds: number,
  ): HueAmbienceFrame {
    return buildHueAmbienceFrame({
      targets,
      palette: [],
      snapshot,
      phase: 0,
      transitionSeconds,
      reason: 'stop',
    });
  }

  private scheduleStopActive(): void {
    this.cancelPendingWork();
    this.cancelScheduledStop();

    if (this.stopGraceMs <= 0) {
      void this.stopActive();
      return;
    }

    this.stopTimer = setTimeout(() => {
      this.stopTimer = null;
      void this.stopActive();
    }, this.stopGraceMs);
  }

  private cancelPendingWork(): number {
    this.runID += 1;
    return this.runID;
  }

  private isCurrentRun(runID: number): boolean {
    return runID === this.runID;
  }

  private cancelScheduledStop(): void {
    if (!this.stopTimer) return;
    clearTimeout(this.stopTimer);
    this.stopTimer = null;
  }

  private snapshotIsUnrelatedToActiveGroup(snapshot: HueSnapshot): boolean {
    return this.activeGroupId !== null && snapshot.groupId !== this.activeGroupId;
  }
}
