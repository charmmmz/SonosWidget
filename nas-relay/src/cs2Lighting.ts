import { buildHueAmbienceFrame, type HueAmbienceFrame } from './hueAmbienceFrames.js';
import type { HueAmbienceRenderer } from './hueFrameRenderer.js';
import { HueClipClient } from './hueClient.js';
import type { HueAmbienceConfigStore } from './hueConfigStore.js';
import type { Cs2GameStateSnapshot } from './cs2Types.js';
import { createHueEntertainmentStreamingRenderer, type HueEntertainmentControlClient } from './hueEntertainmentStream.js';
import type {
  HueAmbienceRuntimeConfig,
  HueRGBColor,
  HueResolvedAmbienceTarget,
} from './hueTypes.js';

export type Cs2LightingMode = 'idle' | 'deathmatch' | 'competitive' | 'spectatorAmbient' | 'unknown';

export interface Cs2LightingDecision {
  mode: Exclude<Cs2LightingMode, 'idle' | 'unknown'>;
  reason:
    | 'ambient'
    | 'bombPlanted'
    | 'burning'
    | 'damage'
    | 'death'
    | 'flash'
    | 'kill'
    | 'lowHealth'
    | 'spectator';
  palette: HueRGBColor[];
  transitionSeconds: number;
}

export interface Cs2LightingStatus {
  enabled: boolean;
  active: boolean;
  mode: Cs2LightingMode;
  transport: 'clipFallback' | 'entertainmentStreaming' | 'unavailable';
  fallbackReason: string | null;
}

interface Cs2LightingServiceOptions {
  activeTimeoutMs?: number;
  minRenderIntervalMs?: number;
  beforeRender?: () => Promise<void> | void;
}

const defaultActiveTimeoutMs = 3_000;
const defaultMinRenderIntervalMs = 70;

const palettes = {
  flash: [
    { r: 1, g: 1, b: 1 },
    { r: 0.88, g: 0.94, b: 1 },
  ],
  burning: [
    { r: 1, g: 0.28, b: 0 },
    { r: 1, g: 0.08, b: 0 },
    { r: 0.55, g: 0.02, b: 0 },
  ],
  damage: [
    { r: 1, g: 0.05, b: 0.02 },
    { r: 0.45, g: 0, b: 0 },
  ],
  kill: [
    { r: 0.18, g: 1, b: 0.32 },
    { r: 0.04, g: 0.35, b: 0.12 },
  ],
  bomb: [
    { r: 1, g: 0.16, b: 0.03 },
    { r: 0.8, g: 0.02, b: 0 },
    { r: 1, g: 0.55, b: 0.04 },
  ],
  lowHealth: [
    { r: 0.75, g: 0.02, b: 0.03 },
    { r: 0.12, g: 0, b: 0 },
  ],
  ctAmbient: [
    { r: 0.05, g: 0.18, b: 0.44 },
    { r: 0.02, g: 0.09, b: 0.24 },
  ],
  tAmbient: [
    { r: 0.48, g: 0.18, b: 0.02 },
    { r: 0.22, g: 0.06, b: 0 },
  ],
  ctSpectator: [
    { r: 0.08, g: 0.14, b: 0.18 },
    { r: 0.03, g: 0.08, b: 0.12 },
  ],
  tSpectator: [
    { r: 0.18, g: 0.1, b: 0.03 },
    { r: 0.1, g: 0.04, b: 0 },
  ],
} satisfies Record<string, HueRGBColor[]>;

export class Cs2LightingService {
  private previousByProvider = new Map<string, Cs2GameStateSnapshot>();
  private activeFrame: HueAmbienceFrame | null = null;
  private activeMode: Cs2LightingMode = 'idle';
  private fallbackReason: string | null = null;
  private lastRenderSignature: string | null = null;
  private lastRenderedAt: Date | null = null;
  private lastRenderAttemptAt = 0;
  private activeTransport: Cs2LightingStatus['transport'] = 'unavailable';
  private activeRenderer: HueAmbienceRenderer | null = null;
  private activeRendererConfigKey: string | null = null;
  private inactiveStopTimer: NodeJS.Timeout | null = null;

  constructor(
    private readonly store: HueAmbienceConfigStore,
    private readonly rendererFactory: (
      config: HueAmbienceRuntimeConfig,
    ) => HueAmbienceRenderer = config =>
      createCs2HueRenderer(config),
    private readonly options: Cs2LightingServiceOptions = {},
  ) {}

  async receive(snapshot: Cs2GameStateSnapshot): Promise<void> {
    const previous = this.previousByProvider.get(snapshot.providerSteamId);
    this.previousByProvider.set(snapshot.providerSteamId, snapshot);

    const config = this.store.current;
    if (!config?.cs2LightingEnabled) {
      this.clearActive(true);
      this.fallbackReason = null;
      return;
    }

    const targets = resolveCs2EntertainmentTargets(config);
    if (targets.length === 0) {
      this.clearActive(true);
      this.fallbackReason = 'no_entertainment_area';
      return;
    }

    const decision = buildCs2LightingDecision(snapshot, previous);
    if (decision.mode === 'spectatorAmbient' && gameMode(snapshot) === 'deathmatch') {
      this.clearActive(true);
      this.fallbackReason = null;
      return;
    }

    const now = Date.now();
    const signature = frameSignature(decision, snapshot);
    if (signature === this.lastRenderSignature) {
      if (this.activeFrame) {
        this.lastRenderedAt = new Date(now);
        this.scheduleInactiveStop();
      }
      return;
    }
    if (now - this.lastRenderAttemptAt < (this.options.minRenderIntervalMs ?? defaultMinRenderIntervalMs)) {
      return;
    }

    this.lastRenderAttemptAt = now;
    this.lastRenderSignature = signature;
    const frame = buildCs2Frame(targets, decision, new Date(now));

    try {
      await this.options.beforeRender?.();
      const result = await this.rendererForConfig(config).render(frame);
      this.activeFrame = frame;
      this.activeMode = decision.mode;
      this.activeTransport = result.transport;
      this.fallbackReason = null;
      this.lastRenderedAt = frame.createdAt;
      this.scheduleInactiveStop();
    } catch (err) {
      this.clearActive(true);
      this.fallbackReason = `render_error:${err instanceof Error ? err.message : String(err)}`;
    }
  }

  shouldDeferAlbumAmbience(now: Date = new Date()): boolean {
    return this.status(now).active;
  }

  status(now: Date = new Date()): Cs2LightingStatus {
    const enabled = this.store.current?.cs2LightingEnabled === true;
    const active = enabled
      && this.fallbackReason === null
      && this.lastRenderedAt !== null
      && now.getTime() - this.lastRenderedAt.getTime() <= (this.options.activeTimeoutMs ?? defaultActiveTimeoutMs);

    return {
      enabled,
      active,
      mode: active ? this.activeMode : 'idle',
      transport: active ? this.activeTransport : 'unavailable',
      fallbackReason: this.fallbackReason,
    };
  }

  private rendererForConfig(config: HueAmbienceRuntimeConfig): HueAmbienceRenderer {
    const configKey = [
      config.bridge.id,
      config.bridge.ipAddress,
      config.applicationKey,
      config.streamingClientKey ?? '',
      config.streamingApplicationId ?? '',
    ].join('|');
    if (this.activeRenderer && this.activeRendererConfigKey === configKey) {
      return this.activeRenderer;
    }

    void this.stopActiveRenderer();
    this.activeRenderer = this.rendererFactory(config);
    this.activeRendererConfigKey = configKey;
    return this.activeRenderer;
  }

  private scheduleInactiveStop(): void {
    this.cancelInactiveStop();
    this.inactiveStopTimer = setTimeout(() => {
      void this.stopActiveRenderer();
    }, this.options.activeTimeoutMs ?? defaultActiveTimeoutMs);
  }

  private cancelInactiveStop(): void {
    if (!this.inactiveStopTimer) return;
    clearTimeout(this.inactiveStopTimer);
    this.inactiveStopTimer = null;
  }

  private async stopActiveRenderer(): Promise<void> {
    this.cancelInactiveStop();
    const renderer = this.activeRenderer;
    const frame = this.activeFrame;
    this.activeRenderer = null;
    this.activeRendererConfigKey = null;
    if (renderer && frame) {
      await renderer.stop(frame).catch(() => {});
    }
  }

  private clearActive(stopRenderer = false): void {
    this.cancelInactiveStop();
    if (stopRenderer) {
      void this.stopActiveRenderer();
    }
    this.activeFrame = null;
    this.activeMode = 'idle';
    this.activeTransport = 'unavailable';
    this.lastRenderedAt = null;
    this.lastRenderSignature = null;
  }
}

function createCs2HueRenderer(config: HueAmbienceRuntimeConfig): HueAmbienceRenderer {
  const client = new HueClipClient(config.bridge, config.applicationKey);
  return createHueEntertainmentStreamingRenderer(
    config,
    client as HueClipClient & HueEntertainmentControlClient,
  );
}

export function buildCs2LightingDecision(
  snapshot: Cs2GameStateSnapshot,
  previous?: Cs2GameStateSnapshot,
): Cs2LightingDecision {
  const mode = gameMode(snapshot);
  const state = snapshot.player?.state;
  const health = clamp01((state?.health ?? 100) / 100);
  const activity = snapshot.player?.activity?.toLowerCase();
  const isDead = (state?.health ?? 100) <= 0;
  const spectator = activity === 'spectating' || activity === 'observer' || activity === 'menu' || isDead;

  if (mode === 'competitive' && spectator) {
    return {
      mode: 'spectatorAmbient',
      reason: 'spectator',
      palette: spectatorPalette(snapshot),
      transitionSeconds: 0.5,
    };
  }

  if ((state?.flashed ?? 0) > 0) {
    return {
      mode,
      reason: 'flash',
      palette: palettes.flash,
      transitionSeconds: 0.05,
    };
  }

  if ((state?.burning ?? 0) > 0) {
    return {
      mode,
      reason: 'burning',
      palette: palettes.burning,
      transitionSeconds: mode === 'deathmatch' ? 0.08 : 0.12,
    };
  }

  if (healthDropped(snapshot, previous)) {
    return {
      mode,
      reason: 'damage',
      palette: palettes.damage,
      transitionSeconds: mode === 'deathmatch' ? 0.08 : 0.12,
    };
  }

  if (isDead) {
    return {
      mode,
      reason: 'death',
      palette: dim(palettes.damage, 0.28),
      transitionSeconds: 0.25,
    };
  }

  if (killsIncreased(snapshot, previous)) {
    return {
      mode,
      reason: 'kill',
      palette: palettes.kill,
      transitionSeconds: mode === 'deathmatch' ? 0.1 : 0.16,
    };
  }

  if (health > 0 && health <= 0.3) {
    return {
      mode,
      reason: 'lowHealth',
      palette: scaleHealthPalette(palettes.lowHealth, health),
      transitionSeconds: 0.3,
    };
  }

  if (mode === 'competitive' && snapshot.round?.bomb?.toLowerCase() === 'planted') {
    return {
      mode,
      reason: 'bombPlanted',
      palette: palettes.bomb,
      transitionSeconds: 0.2,
    };
  }

  return {
    mode,
    reason: 'ambient',
    palette: teamAmbientPalette(snapshot),
    transitionSeconds: mode === 'deathmatch' ? 0.18 : 0.28,
  };
}

function buildCs2Frame(
  targets: HueResolvedAmbienceTarget[],
  decision: Cs2LightingDecision,
  now: Date,
): HueAmbienceFrame {
  return buildHueAmbienceFrame({
    targets,
    palette: decision.palette,
    snapshot: {
      groupId: 'cs2',
      speakerName: 'CS2',
      trackTitle: decision.reason,
      artist: 'Counter-Strike 2',
      album: decision.mode,
      albumArtUri: '',
      isPlaying: true,
      positionSeconds: 0,
      durationSeconds: 0,
      groupMemberCount: 1,
      sampledAt: now,
    },
    reason: 'steady',
    phase: 0,
    transitionSeconds: decision.transitionSeconds,
    now,
  });
}

function resolveCs2EntertainmentTargets(config: HueAmbienceRuntimeConfig): HueResolvedAmbienceTarget[] {
  const lightsByID = new Map(config.resources.lights.map(light => [light.id, light]));
  const seenAreaIDs = new Set<string>();
  const targets: HueResolvedAmbienceTarget[] = [];

  for (const mapping of config.mappings) {
    const target = [mapping.preferredTarget, mapping.fallbackTarget]
      .find(candidate => candidate?.kind === 'entertainmentArea');
    if (!target || seenAreaIDs.has(target.id)) continue;

    const area = config.resources.areas.find(candidate =>
      candidate.id === target.id && candidate.kind === 'entertainmentArea',
    );
    if (!area) continue;

    const lights = area.childLightIDs
      .map(id => lightsByID.get(id))
      .filter((light): light is NonNullable<typeof light> => Boolean(light))
      .filter(light => light.supportsColor && light.supportsEntertainment);
    if (lights.length === 0) continue;

    seenAreaIDs.add(area.id);
    targets.push({ area, mapping, lights });
  }

  return targets;
}

function gameMode(snapshot: Cs2GameStateSnapshot): Exclude<Cs2LightingMode, 'idle' | 'unknown' | 'spectatorAmbient'> {
  const mode = snapshot.map?.mode?.toLowerCase() ?? '';
  if (mode.includes('deathmatch')) return 'deathmatch';
  return 'competitive';
}

function healthDropped(snapshot: Cs2GameStateSnapshot, previous?: Cs2GameStateSnapshot): boolean {
  const currentHealth = snapshot.player?.state?.health;
  const previousHealth = previous?.player?.state?.health;
  return Number.isFinite(currentHealth)
    && Number.isFinite(previousHealth)
    && (previousHealth as number) > (currentHealth as number)
    && (currentHealth as number) > 0;
}

function killsIncreased(snapshot: Cs2GameStateSnapshot, previous?: Cs2GameStateSnapshot): boolean {
  const currentKills = snapshot.player?.state?.round_kills ?? snapshot.player?.match_stats?.kills;
  const previousKills = previous?.player?.state?.round_kills ?? previous?.player?.match_stats?.kills;
  return Number.isFinite(currentKills)
    && Number.isFinite(previousKills)
    && (currentKills as number) > (previousKills as number);
}

function teamAmbientPalette(snapshot: Cs2GameStateSnapshot): HueRGBColor[] {
  return snapshot.player?.team?.toUpperCase() === 'T' ? palettes.tAmbient : palettes.ctAmbient;
}

function spectatorPalette(snapshot: Cs2GameStateSnapshot): HueRGBColor[] {
  return snapshot.player?.team?.toUpperCase() === 'T' ? palettes.tSpectator : palettes.ctSpectator;
}

function scaleHealthPalette(palette: HueRGBColor[], health: number): HueRGBColor[] {
  const scale = 0.35 + (1 - health) * 0.35;
  return dim(palette, scale);
}

function dim(palette: HueRGBColor[], scale: number): HueRGBColor[] {
  return palette.map(color => ({
    r: clamp01(color.r * scale),
    g: clamp01(color.g * scale),
    b: clamp01(color.b * scale),
  }));
}

function frameSignature(decision: Cs2LightingDecision, snapshot: Cs2GameStateSnapshot): string {
  return [
    decision.mode,
    decision.reason,
    snapshot.player?.team,
    snapshot.player?.state?.health,
    snapshot.player?.state?.flashed,
    snapshot.player?.state?.burning,
    snapshot.player?.state?.round_kills,
    snapshot.player?.match_stats?.kills,
    snapshot.round?.bomb,
  ].join('|');
}

function clamp01(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.max(0, Math.min(1, value));
}
