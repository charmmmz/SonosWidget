import { appendFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';

import { buildHueAmbienceFrame, type HueAmbienceFrame } from './hueAmbienceFrames.js';
import type { HueAmbienceRenderer } from './hueFrameRenderer.js';
import { HueClipClient } from './hueClient.js';
import type { HueAmbienceConfigStore } from './hueConfigStore.js';
import type { Cs2GameStateSnapshot } from './cs2Types.js';
import { createHueEntertainmentStreamingOnlyRenderer, type HueEntertainmentControlClient } from './hueEntertainmentStream.js';
import type {
  HueAmbienceRuntimeConfig,
  HueRGBColor,
  HueResolvedAmbienceTarget,
} from './hueTypes.js';

export type Cs2LightingMode = 'idle' | 'deathmatch' | 'competitive' | 'unknown';

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
    | 'roundFreeze'
    | 'roundOver';
  palette: HueRGBColor[];
  transitionSeconds: number;
  attackSeconds: number;
  holdSeconds: number;
  fadeSeconds: number;
  dynamicKey?: string;
}

export interface Cs2LightingDecisionContext {
  bombPlantedAt?: number | null;
  nowMs?: number;
}

export interface Cs2LightingStatus {
  enabled: boolean;
  active: boolean;
  mode: Cs2LightingMode;
  transport: 'entertainmentStreaming' | 'unavailable';
  fallbackReason: string | null;
}

interface Cs2LightingLogger {
  debug?(data: Record<string, unknown>, message: string): void;
  info?(data: Record<string, unknown>, message: string): void;
  warn?(data: Record<string, unknown>, message: string): void;
}

interface Cs2LightingServiceOptions {
  activeTimeoutMs?: number;
  minRenderIntervalMs?: number;
  beforeRender?: () => Promise<void> | void;
  now?: () => number;
  logger?: Cs2LightingLogger;
  logFilePath?: string;
}

const defaultActiveTimeoutMs = 3_000;
const defaultMinRenderIntervalMs = 70;
const animationFrameIntervalMs = 40;
const c4FuseMs = 40_000;

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
    { r: 1, g: 0.72, b: 0.12 },
    { r: 1, g: 0.25, b: 0.04 },
    { r: 0.55, g: 0.02, b: 0 },
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
} satisfies Record<string, HueRGBColor[]>;

interface HeldCs2Effect {
  decision: Cs2LightingDecision;
  baseDecision: Cs2LightingDecision;
  startedAtMs: number;
}

interface Cs2PresetKeyframe {
  atMs: number;
  palette: HueRGBColor[];
  ease?: 'linear' | 'smooth' | 'out';
}

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
  private animationTimer: NodeJS.Timeout | null = null;
  private animationContext: {
    providerSteamId: string;
    config: HueAmbienceRuntimeConfig;
    targets: HueResolvedAmbienceTarget[];
  } | null = null;
  private animationInFlight = false;
  private heldEffects = new Map<string, HeldCs2Effect>();
  private bombPlantedAtByProvider = new Map<string, number>();
  private activeProviderSteamId: string | null = null;
  private lastDiagnosticSignature: string | null = null;

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
    const now = this.options.now?.() ?? Date.now();

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

    this.updateBombClock(snapshot, previous, now);
    const decisionContext: Cs2LightingDecisionContext = {
      bombPlantedAt: this.bombPlantedAtByProvider.get(snapshot.providerSteamId),
      nowMs: now,
    };
    const overlayDecision = momentaryDecisionForSnapshot(snapshot, previous);
    const backgroundDecision = backgroundDecisionForSnapshot(snapshot, decisionContext);
    const baseDecision = overlayDecision ?? backgroundDecision;
    if (!baseDecision) {
      this.clearActive(true);
      this.heldEffects.delete(snapshot.providerSteamId);
      this.fallbackReason = null;
      await this.logLightingCleared(snapshot, 'no_active_decision');
      return;
    }

    const decision = this.decisionWithHeldEffect(snapshot.providerSteamId, baseDecision, snapshot, decisionContext, now);
    const signature = frameSignature(decision, snapshot);
    if (signature === this.lastRenderSignature) {
      if (this.activeFrame) {
        this.lastRenderedAt = new Date(now);
        this.scheduleInactiveStop();
      }
      return;
    }
    if (!isPriorityDecision(decision)
      && now - this.lastRenderAttemptAt < (this.options.minRenderIntervalMs ?? defaultMinRenderIntervalMs)) {
      return;
    }

    this.lastRenderAttemptAt = now;
    this.lastRenderSignature = signature;

    try {
      await this.renderDecisionFrame(config, targets, decision, new Date(now), true);
      this.activeProviderSteamId = snapshot.providerSteamId;
      await this.logLightingDecision(snapshot, backgroundDecision, overlayDecision, decision);
      if (this.activeTransport === 'entertainmentStreaming'
        && this.shouldAnimateProvider(snapshot.providerSteamId, decision)) {
        this.schedulePresetAnimation(snapshot.providerSteamId, config, targets);
      }
    } catch (err) {
      this.clearActive(true);
      this.fallbackReason = `render_error:${err instanceof Error ? err.message : String(err)}`;
      await this.logLightingRenderError(snapshot, backgroundDecision, overlayDecision, decision, this.fallbackReason);
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
      const providerSteamId = this.activeProviderSteamId;
      void this.stopActiveRenderer();
      void this.logLightingInactiveTimeout(providerSteamId);
    }, this.options.activeTimeoutMs ?? defaultActiveTimeoutMs);
    this.inactiveStopTimer.unref?.();
  }

  private cancelInactiveStop(): void {
    if (!this.inactiveStopTimer) return;
    clearTimeout(this.inactiveStopTimer);
    this.inactiveStopTimer = null;
  }

  private async stopActiveRenderer(): Promise<void> {
    this.cancelInactiveStop();
    this.cancelAnimation();
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
    this.cancelAnimation();
    if (stopRenderer) {
      void this.stopActiveRenderer();
    }
    this.activeFrame = null;
    this.activeMode = 'idle';
    this.activeTransport = 'unavailable';
    this.activeProviderSteamId = null;
    this.lastRenderedAt = null;
    this.lastRenderSignature = null;
  }

  private async renderDecisionFrame(
    config: HueAmbienceRuntimeConfig,
    targets: HueResolvedAmbienceTarget[],
    decision: Cs2LightingDecision,
    now: Date,
    runBeforeRender: boolean,
    refreshActiveDeadline = true,
  ): Promise<void> {
    const frame = buildCs2Frame(targets, decision, now);
    if (runBeforeRender) {
      await this.options.beforeRender?.();
    }

    const result = await this.rendererForConfig(config).render(frame);
    if (result.transport !== 'entertainmentStreaming') {
      throw new Error('CS2 lighting requires Hue Entertainment streaming');
    }

    this.activeFrame = frame;
    this.activeMode = decision.mode;
    this.activeTransport = result.transport;
    this.fallbackReason = null;
    if (refreshActiveDeadline) {
      this.lastRenderedAt = frame.createdAt;
      this.scheduleInactiveStop();
    }
  }

  private schedulePresetAnimation(
    providerSteamId: string,
    config: HueAmbienceRuntimeConfig,
    targets: HueResolvedAmbienceTarget[],
  ): void {
    this.animationContext = { providerSteamId, config, targets };
    if (this.animationTimer) return;

    this.animationTimer = setTimeout(() => {
      this.animationTimer = null;
      void this.renderPresetAnimation();
    }, animationFrameIntervalMs);
    this.animationTimer.unref?.();
  }

  private async renderPresetAnimation(): Promise<void> {
    if (this.animationInFlight) return;
    const context = this.animationContext;
    if (!context) return;

    const snapshot = this.previousByProvider.get(context.providerSteamId);
    if (!snapshot) {
      this.animationContext = null;
      return;
    }

    const nowMs = this.options.now?.() ?? Date.now();
    if (nowMs - this.lastRenderAttemptAt > (this.options.activeTimeoutMs ?? defaultActiveTimeoutMs)) {
      this.clearActive(true);
      return;
    }

    const decisionContext: Cs2LightingDecisionContext = {
      bombPlantedAt: this.bombPlantedAtByProvider.get(context.providerSteamId),
      nowMs,
    };
    const background = backgroundDecisionForSnapshot(snapshot, decisionContext);
    const held = this.heldEffects.get(context.providerSteamId);
    if (!held && !isAnimatedBackgroundDecision(background)) {
      this.animationContext = null;
      return;
    }

    this.animationInFlight = true;
    try {
      const now = new Date(nowMs);
      let decision = background;
      let overlayComplete = false;
      if (held) {
        const animated = heldEffectDecision(held, background ?? held.baseDecision, nowMs);
        decision = animated.decision;
        overlayComplete = animated.complete;
        if (animated.complete) {
          this.heldEffects.delete(context.providerSteamId);
          void this.logLightingOverlayComplete(snapshot, held.decision, background);
        }
      }

      if (!decision) {
        this.animationContext = null;
        return;
      }

      this.lastRenderSignature = `animation|${context.providerSteamId}|${decision.reason}|${decision.dynamicKey ?? ''}`;
      await this.renderDecisionFrame(context.config, context.targets, decision, now, false, false);

      const shouldContinue = this.heldEffects.has(context.providerSteamId)
        || isAnimatedBackgroundDecision(background)
        || (held !== undefined && !overlayComplete);
      if (!shouldContinue) {
        this.animationContext = null;
      } else {
        this.animationTimer = setTimeout(() => {
          this.animationTimer = null;
          void this.renderPresetAnimation();
        }, animationFrameIntervalMs);
        this.animationTimer.unref?.();
      }
    } finally {
      this.animationInFlight = false;
    }
  }

  private cancelAnimation(): void {
    if (this.animationTimer) {
      clearTimeout(this.animationTimer);
      this.animationTimer = null;
    }
    this.animationContext = null;
  }

  private shouldAnimateProvider(providerSteamId: string, decision: Cs2LightingDecision): boolean {
    return this.heldEffects.has(providerSteamId) || isAnimatedBackgroundDecision(decision);
  }

  private updateBombClock(
    snapshot: Cs2GameStateSnapshot,
    previous: Cs2GameStateSnapshot | undefined,
    now: number,
  ): void {
    const provider = snapshot.providerSteamId;
    const bomb = snapshot.round?.bomb?.toLowerCase();
    const previousBomb = previous?.round?.bomb?.toLowerCase();
    if (bomb === 'planted') {
      if (previousBomb !== 'planted' || !this.bombPlantedAtByProvider.has(provider)) {
        this.bombPlantedAtByProvider.set(provider, now);
      }
      return;
    }
    this.bombPlantedAtByProvider.delete(provider);
  }

  private decisionWithHeldEffect(
    providerSteamId: string,
    decision: Cs2LightingDecision,
    snapshot: Cs2GameStateSnapshot,
    context: Cs2LightingDecisionContext,
    now: number,
  ): Cs2LightingDecision {
    if (isHeldEventDecision(decision)) {
      const active = this.heldEffects.get(providerSteamId);
      if (active?.decision.reason === decision.reason && !heldEffectComplete(active, now)) {
        return heldEffectDecision(active, backgroundDecisionForSnapshot(snapshot, context) ?? active.baseDecision, now).decision;
      }

      const startedAtMs = now - firstFrameLeadMs(decision);
      const held = {
        decision,
        baseDecision: baseDecisionForHeldEffect(snapshot, decision, context),
        startedAtMs,
      };
      this.heldEffects.set(providerSteamId, held);
      return heldEffectDecision(held, held.baseDecision, now).decision;
    }

    const held = this.heldEffects.get(providerSteamId);
    if (!held) return decision;

    const animated = heldEffectDecision(held, decision, now);
    if (!animated.complete) {
      return animated.decision;
    }

    this.heldEffects.delete(providerSteamId);
    return decision;
  }

  private async logLightingDecision(
    snapshot: Cs2GameStateSnapshot,
    backgroundDecision: Cs2LightingDecision | null,
    overlayDecision: Cs2LightingDecision | null,
    finalDecision: Cs2LightingDecision,
  ): Promise<void> {
    const record = this.diagnosticRecord(snapshot, {
      event: 'decision',
      transport: this.activeTransport,
      finalReason: finalDecision.reason,
      finalDynamicKey: finalDecision.dynamicKey ?? null,
      backgroundReason: backgroundDecision?.reason ?? null,
      backgroundDynamicKey: backgroundDecision?.dynamicKey ?? null,
      overlayReason: overlayDecision?.reason ?? null,
      firstColor: finalDecision.palette[0] ?? null,
      palette: finalDecision.palette.slice(0, 4),
      transitionSeconds: finalDecision.transitionSeconds,
    });
    await this.writeDedupedDiagnosticRecord(record, 'CS2 lighting decision selected', 'info');
  }

  private async logLightingCleared(snapshot: Cs2GameStateSnapshot, clearReason: string): Promise<void> {
    const record = this.diagnosticRecord(snapshot, {
      event: 'cleared',
      clearReason,
      transport: 'unavailable',
      finalReason: null,
      backgroundReason: null,
      overlayReason: null,
      firstColor: null,
    });
    await this.writeDedupedDiagnosticRecord(record, 'CS2 lighting cleared', 'info');
  }

  private async logLightingRenderError(
    snapshot: Cs2GameStateSnapshot,
    backgroundDecision: Cs2LightingDecision | null,
    overlayDecision: Cs2LightingDecision | null,
    finalDecision: Cs2LightingDecision,
    error: string,
  ): Promise<void> {
    const record = this.diagnosticRecord(snapshot, {
      event: 'render_error',
      error,
      transport: this.activeTransport,
      finalReason: finalDecision.reason,
      finalDynamicKey: finalDecision.dynamicKey ?? null,
      backgroundReason: backgroundDecision?.reason ?? null,
      overlayReason: overlayDecision?.reason ?? null,
      firstColor: finalDecision.palette[0] ?? null,
    });
    await this.writeDedupedDiagnosticRecord(record, 'CS2 lighting render failed', 'warn');
  }

  private async logLightingOverlayComplete(
    snapshot: Cs2GameStateSnapshot,
    overlayDecision: Cs2LightingDecision,
    backgroundDecision: Cs2LightingDecision | null,
  ): Promise<void> {
    const record = this.diagnosticRecord(snapshot, {
      event: 'overlay_complete',
      transport: this.activeTransport,
      finalReason: backgroundDecision?.reason ?? null,
      backgroundReason: backgroundDecision?.reason ?? null,
      overlayReason: overlayDecision.reason,
      firstColor: backgroundDecision?.palette[0] ?? null,
    });
    await this.writeDedupedDiagnosticRecord(record, 'CS2 lighting overlay completed', 'debug');
  }

  private async logLightingInactiveTimeout(providerSteamId: string | null): Promise<void> {
    const snapshot = providerSteamId ? this.previousByProvider.get(providerSteamId) : undefined;
    const record = snapshot
      ? this.diagnosticRecord(snapshot, {
        event: 'inactive_timeout',
        transport: this.activeTransport,
        finalReason: null,
        backgroundReason: null,
        overlayReason: null,
        firstColor: null,
      })
      : {
        event: 'inactive_timeout',
        timestamp: new Date(this.options.now?.() ?? Date.now()).toISOString(),
        providerSteamId,
        transport: this.activeTransport,
      };
    await this.writeDedupedDiagnosticRecord(record, 'CS2 lighting inactive timeout', 'info');
  }

  private diagnosticRecord(
    snapshot: Cs2GameStateSnapshot,
    extra: Record<string, unknown>,
  ): Record<string, unknown> {
    const state = snapshot.player?.state;
    return {
      timestamp: new Date(this.options.now?.() ?? Date.now()).toISOString(),
      providerSteamId: snapshot.providerSteamId,
      providerName: snapshot.provider?.name ?? null,
      playerName: snapshot.player?.name ?? null,
      team: snapshot.player?.team ?? null,
      activity: snapshot.player?.activity ?? null,
      map: snapshot.map?.name ?? null,
      mapMode: snapshot.map?.mode ?? null,
      mapPhase: snapshot.map?.phase ?? null,
      roundPhase: snapshot.round?.phase ?? null,
      bomb: snapshot.round?.bomb ?? null,
      health: state?.health ?? null,
      armor: state?.armor ?? null,
      flashed: state?.flashed ?? null,
      burning: state?.burning ?? null,
      smoked: state?.smoked ?? null,
      roundKills: state?.round_kills ?? null,
      matchKills: snapshot.player?.match_stats?.kills ?? null,
      matchDeaths: snapshot.player?.match_stats?.deaths ?? null,
      sourceIp: snapshot.sourceIp ?? null,
      ...extra,
    };
  }

  private async writeDedupedDiagnosticRecord(
    record: Record<string, unknown>,
    message: string,
    level: 'debug' | 'info' | 'warn',
  ): Promise<void> {
    const signature = diagnosticSignature(record);
    if (signature === this.lastDiagnosticSignature) return;
    this.lastDiagnosticSignature = signature;
    await this.writeDiagnosticRecord(record, message, level);
  }

  private async writeDiagnosticRecord(
    record: Record<string, unknown>,
    message: string,
    level: 'debug' | 'info' | 'warn',
  ): Promise<void> {
    const payload = {
      message,
      ...record,
    };
    this.options.logger?.[level]?.(payload, message);

    const logFilePath = this.options.logFilePath;
    if (!logFilePath) return;

    try {
      await mkdir(dirname(logFilePath), { recursive: true });
      await appendFile(logFilePath, `${JSON.stringify(payload)}\n`, 'utf8');
    } catch (err) {
      this.options.logger?.warn?.(
        {
          err: err instanceof Error ? err.message : String(err),
          logFilePath,
        },
        'failed to write CS2 lighting diagnostic log',
      );
    }
  }
}

function createCs2HueRenderer(config: HueAmbienceRuntimeConfig): HueAmbienceRenderer {
  const client = new HueClipClient(config.bridge, config.applicationKey);
  return createHueEntertainmentStreamingOnlyRenderer(
    config,
    client as HueClipClient & HueEntertainmentControlClient,
  );
}

export function buildCs2LightingDecision(
  snapshot: Cs2GameStateSnapshot,
  previous?: Cs2GameStateSnapshot,
  context: Cs2LightingDecisionContext = {},
): Cs2LightingDecision | null {
  const overlay = momentaryDecisionForSnapshot(snapshot, previous);
  if (overlay) return overlay;

  return backgroundDecisionForSnapshot(snapshot, context);
}

function momentaryDecisionForSnapshot(
  snapshot: Cs2GameStateSnapshot,
  previous?: Cs2GameStateSnapshot,
): Cs2LightingDecision | null {
  const mode = gameMode(snapshot);
  const state = snapshot.player?.state;
  const health = clamp01((state?.health ?? 100) / 100);
  const activity = snapshot.player?.activity?.toLowerCase();
  const isDead = (state?.health ?? 100) <= 0;
  const observer = activity === 'spectating' || activity === 'observer' || activity === 'menu';

  if (observer) return null;

  if (isDeathEvent(snapshot, previous)) {
    return {
      mode,
      reason: 'death',
      palette: dim(palettes.damage, 0.28),
      transitionSeconds: 0.25,
      attackSeconds: 0.12,
      holdSeconds: 0.65,
      fadeSeconds: 0.8,
    };
  }

  if (isDead) return null;

  if ((state?.flashed ?? 0) > 0 && ((previous?.player?.state?.flashed ?? 0) <= 0)) {
    return {
      mode,
      reason: 'flash',
      palette: palettes.flash,
      transitionSeconds: 0.08,
      attackSeconds: 0.12,
      holdSeconds: 0.08,
      fadeSeconds: 0.7,
    };
  }

  if ((state?.burning ?? 0) > 0) {
    return {
      mode,
      reason: 'burning',
      palette: palettes.burning,
      transitionSeconds: mode === 'deathmatch' ? 0.08 : 0.12,
      attackSeconds: mode === 'deathmatch' ? 0.06 : 0.08,
      holdSeconds: 0.2,
      fadeSeconds: 0.4,
    };
  }

  if (healthDropped(snapshot, previous)) {
    return {
      mode,
      reason: 'damage',
      palette: palettes.damage,
      transitionSeconds: mode === 'deathmatch' ? 0.1 : 0.14,
      attackSeconds: mode === 'deathmatch' ? 0.06 : 0.08,
      holdSeconds: mode === 'deathmatch' ? 0.28 : 0.4,
      fadeSeconds: mode === 'deathmatch' ? 0.35 : 0.55,
    };
  }

  if (killsIncreased(snapshot, previous)) {
    return {
      mode,
      reason: 'kill',
      palette: palettes.kill,
      transitionSeconds: mode === 'deathmatch' ? 0.06 : 0.08,
      attackSeconds: mode === 'deathmatch' ? 0.04 : 0.05,
      holdSeconds: mode === 'deathmatch' ? 0.08 : 0.1,
      fadeSeconds: mode === 'deathmatch' ? 0.16 : 0.2,
    };
  }

  return null;
}

function backgroundDecisionForSnapshot(
  snapshot: Cs2GameStateSnapshot,
  context: Cs2LightingDecisionContext,
): Cs2LightingDecision | null {
  const mode = gameMode(snapshot);
  const state = snapshot.player?.state;
  const health = clamp01((state?.health ?? 100) / 100);
  const activity = snapshot.player?.activity?.toLowerCase();
  const isDead = (state?.health ?? 100) <= 0;
  const observer = activity === 'spectating' || activity === 'observer' || activity === 'menu';
  if (observer || isDead) return null;

  const phase = roundPhase(snapshot);
  if (phase === 'over') {
    return roundBackgroundDecision(snapshot, 'roundOver', 0.32, 0.35);
  }

  if (mode === 'competitive' && snapshot.round?.bomb?.toLowerCase() === 'planted') {
    return bombPlantedDecision(mode, context);
  }

  if (phase === 'freezetime') {
    return roundBackgroundDecision(snapshot, 'roundFreeze', 0.48, 0.4);
  }

  if (health > 0 && health <= 0.3) {
    return lowHealthBackgroundDecision(snapshot, health);
  }

  return {
    mode,
    reason: 'ambient',
    palette: teamAmbientPalette(snapshot),
    transitionSeconds: mode === 'deathmatch' ? 0.18 : 0.28,
    attackSeconds: 0,
    holdSeconds: 0,
    fadeSeconds: 0,
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

function lowHealthBackgroundDecision(snapshot: Cs2GameStateSnapshot, health: number): Cs2LightingDecision {
  const mode = gameMode(snapshot);
  const severity = clamp01((0.3 - health) / 0.3);
  const redWash = 0.12 + (severity * 0.16);
  return {
    mode,
    reason: 'lowHealth',
    palette: blendPalettes(teamAmbientPalette(snapshot), palettes.lowHealth, redWash),
    transitionSeconds: 0.3,
    attackSeconds: 0,
    holdSeconds: 0,
    fadeSeconds: 0,
  };
}

function roundBackgroundDecision(
  snapshot: Cs2GameStateSnapshot,
  reason: 'roundFreeze' | 'roundOver',
  intensity: number,
  transitionSeconds: number,
): Cs2LightingDecision {
  return {
    mode: gameMode(snapshot),
    reason,
    palette: dim(teamAmbientPalette(snapshot), intensity),
    transitionSeconds,
    attackSeconds: 0,
    holdSeconds: 0,
    fadeSeconds: 0,
  };
}

function deathFallbackDecision(snapshot: Cs2GameStateSnapshot): Cs2LightingDecision {
  return {
    mode: gameMode(snapshot),
    reason: 'ambient',
    palette: dim(teamAmbientPalette(snapshot), 0.3),
    transitionSeconds: 0.45,
    attackSeconds: 0,
    holdSeconds: 0,
    fadeSeconds: 0,
  };
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
    decision.dynamicKey,
    snapshot.player?.team,
    snapshot.player?.state?.health,
    snapshot.player?.state?.flashed,
    snapshot.player?.state?.burning,
    snapshot.player?.state?.round_kills,
    snapshot.player?.match_stats?.kills,
    snapshot.round?.bomb,
    snapshot.round?.phase,
    snapshot.map?.phase,
  ].join('|');
}

function diagnosticSignature(record: Record<string, unknown>): string {
  return [
    record.event,
    record.providerSteamId,
    record.transport,
    record.finalReason,
    record.finalDynamicKey,
    record.backgroundReason,
    record.backgroundDynamicKey,
    record.overlayReason,
    record.clearReason,
    record.error,
    record.team,
    record.activity,
    record.map,
    record.mapMode,
    record.mapPhase,
    record.roundPhase,
    record.bomb,
    record.health,
    record.flashed,
    record.burning,
    record.roundKills,
    JSON.stringify(record.firstColor ?? null),
  ].join('|');
}

function roundPhase(snapshot: Cs2GameStateSnapshot): string {
  return snapshot.round?.phase?.toLowerCase() ?? '';
}

function bombPlantedDecision(
  mode: Exclude<Cs2LightingMode, 'idle' | 'unknown'>,
  context: Cs2LightingDecisionContext,
): Cs2LightingDecision {
  const nowMs = context.nowMs ?? Date.now();
  const plantedAt = context.bombPlantedAt ?? nowMs;
  const elapsed = Math.max(0, Math.min(c4FuseMs, nowMs - plantedAt));
  const urgency = elapsed / c4FuseMs;
  const periodMs = 900 - (urgency * 720);
  const phase = (elapsed % periodMs) / periodMs;
  const lit = phase < 0.24;
  const baseIntensity = lit ? 1 : 0.18 + (urgency * 0.22);
  const palette = lit ? palettes.bomb : dim(palettes.bomb, baseIntensity);

  return {
    mode,
    reason: 'bombPlanted',
    palette,
    transitionSeconds: Math.max(0.04, Math.min(0.18, periodMs / 1000 * 0.22)),
    attackSeconds: 0,
    holdSeconds: 0,
    fadeSeconds: 0,
    dynamicKey: `bomb:${Math.floor(elapsed / periodMs)}:${lit ? 'on' : 'off'}`,
  };
}

function baseDecisionForHeldEffect(
  snapshot: Cs2GameStateSnapshot,
  effect: Cs2LightingDecision,
  context: Cs2LightingDecisionContext,
): Cs2LightingDecision {
  return backgroundDecisionForSnapshot(snapshot, context)
    ?? (effect.reason === 'death' ? deathFallbackDecision(snapshot) : ambientDecision(snapshot));
}

function ambientDecision(snapshot: Cs2GameStateSnapshot): Cs2LightingDecision {
  const mode = gameMode(snapshot);
  return {
    mode,
    reason: 'ambient',
    palette: teamAmbientPalette(snapshot),
    transitionSeconds: mode === 'deathmatch' ? 0.18 : 0.28,
    attackSeconds: 0,
    holdSeconds: 0,
    fadeSeconds: 0,
  };
}

function firstFrameLeadMs(decision: Cs2LightingDecision): number {
  switch (decision.reason) {
    case 'flash':
      return 45;
    case 'kill':
      return 25;
    case 'damage':
    case 'burning':
      return 30;
    case 'death':
      return 45;
    default:
      return Math.min(Math.max(decision.attackSeconds * 1000 * 0.35, 20), 45);
  }
}

function heldEffectComplete(held: HeldCs2Effect, now: number): boolean {
  return now - held.startedAtMs > heldEffectTotalMs(held.decision);
}

function heldEffectDecision(
  held: HeldCs2Effect,
  fallbackDecision: Cs2LightingDecision,
  now: number,
): { decision: Cs2LightingDecision; complete: boolean } {
  const elapsed = Math.max(0, now - held.startedAtMs);
  const preset = overlayPresetKeyframes(held.decision, held.baseDecision, fallbackDecision);
  const last = preset.at(-1);
  if (!last || elapsed > last.atMs) {
    return { complete: true, decision: fallbackDecision };
  }

  const sampled = samplePresetKeyframes(preset, elapsed);
  return {
    complete: false,
    decision: {
      ...fallbackDecision,
      mode: held.decision.mode,
      reason: held.decision.reason,
      palette: sampled.palette,
      transitionSeconds: held.decision.transitionSeconds,
      attackSeconds: held.decision.attackSeconds,
      holdSeconds: held.decision.holdSeconds,
      fadeSeconds: held.decision.fadeSeconds,
      dynamicKey: `${held.decision.reason}:preset:${sampled.segment}:${Math.floor(sampled.progress * 10)}`,
    },
  };
}

function heldEffectTotalMs(decision: Cs2LightingDecision): number {
  return overlayPresetDurationMs(decision);
}

function overlayPresetDurationMs(decision: Cs2LightingDecision): number {
  switch (decision.reason) {
    case 'flash':
      return 900;
    case 'kill':
      return 220;
    case 'damage':
      return 620;
    case 'burning':
      return 820;
    case 'death':
      return 760;
    default:
      return (decision.attackSeconds + decision.holdSeconds + decision.fadeSeconds) * 1000;
  }
}

function overlayPresetKeyframes(
  effect: Cs2LightingDecision,
  start: Cs2LightingDecision,
  fallback: Cs2LightingDecision,
): Cs2PresetKeyframe[] {
  switch (effect.reason) {
    case 'flash':
      return [
        { atMs: 0, palette: start.palette, ease: 'smooth' },
        { atMs: 90, palette: palettes.flash, ease: 'out' },
        { atMs: 220, palette: palettes.flash, ease: 'linear' },
        { atMs: 900, palette: fallback.palette, ease: 'out' },
      ];
    case 'kill':
      return [
        { atMs: 0, palette: start.palette, ease: 'smooth' },
        { atMs: 35, palette: [{ r: 1, g: 0.86, b: 0.22 }, ...palettes.kill], ease: 'out' },
        { atMs: 95, palette: palettes.kill, ease: 'smooth' },
        { atMs: 220, palette: fallback.palette, ease: 'out' },
      ];
    case 'damage':
      return [
        { atMs: 0, palette: start.palette, ease: 'smooth' },
        { atMs: 70, palette: palettes.damage, ease: 'out' },
        { atMs: 180, palette: dim(palettes.damage, 0.45), ease: 'smooth' },
        { atMs: 620, palette: fallback.palette, ease: 'out' },
      ];
    case 'burning':
      return [
        { atMs: 0, palette: start.palette, ease: 'smooth' },
        { atMs: 60, palette: palettes.burning, ease: 'out' },
        { atMs: 180, palette: dim(palettes.burning, 0.7), ease: 'linear' },
        { atMs: 320, palette: palettes.burning.slice().reverse(), ease: 'smooth' },
        { atMs: 520, palette: dim(palettes.burning, 0.45), ease: 'linear' },
        { atMs: 820, palette: fallback.palette, ease: 'out' },
      ];
    case 'death':
      return [
        { atMs: 0, palette: start.palette, ease: 'smooth' },
        { atMs: 120, palette: dim(palettes.damage, 0.36), ease: 'out' },
        { atMs: 300, palette: dim(palettes.damage, 0.12), ease: 'smooth' },
        { atMs: 760, palette: fallback.palette, ease: 'out' },
      ];
    default:
      return [
        { atMs: 0, palette: start.palette, ease: 'smooth' },
        { atMs: overlayPresetDurationMs(effect), palette: fallback.palette, ease: 'out' },
      ];
  }
}

function samplePresetKeyframes(
  keyframes: Cs2PresetKeyframe[],
  elapsedMs: number,
): { palette: HueRGBColor[]; segment: number; progress: number } {
  const first = keyframes[0];
  if (!first || elapsedMs <= first.atMs) {
    return { palette: first?.palette ?? [], segment: 0, progress: 0 };
  }

  for (let index = 1; index < keyframes.length; index += 1) {
    const previous = keyframes[index - 1]!;
    const next = keyframes[index]!;
    if (elapsedMs > next.atMs) continue;

    const span = Math.max(1, next.atMs - previous.atMs);
    const rawProgress = clamp01((elapsedMs - previous.atMs) / span);
    return {
      palette: blendPalettes(previous.palette, next.palette, easeProgress(rawProgress, next.ease)),
      segment: index,
      progress: rawProgress,
    };
  }

  const last = keyframes[keyframes.length - 1]!;
  return { palette: last.palette, segment: keyframes.length - 1, progress: 1 };
}

function easeProgress(progress: number, ease: Cs2PresetKeyframe['ease'] = 'smooth'): number {
  switch (ease) {
    case 'linear':
      return clamp01(progress);
    case 'out': {
      const t = clamp01(progress);
      return 1 - ((1 - t) * (1 - t));
    }
    case 'smooth':
    default:
      return smoothstep(progress);
  }
}

function isDeathEvent(snapshot: Cs2GameStateSnapshot, previous?: Cs2GameStateSnapshot): boolean {
  const currentHealth = snapshot.player?.state?.health;
  const previousHealth = previous?.player?.state?.health;
  return Number.isFinite(currentHealth)
    && (currentHealth as number) <= 0
    && Number.isFinite(previousHealth)
    && (previousHealth as number) > 0;
}

function isPriorityDecision(decision: Cs2LightingDecision): boolean {
  return decision.reason !== 'ambient' && decision.reason !== 'lowHealth';
}

function isHeldEventDecision(decision: Cs2LightingDecision): boolean {
  return decision.attackSeconds > 0 || decision.holdSeconds > 0 || decision.fadeSeconds > 0;
}

function isAnimatedBackgroundDecision(decision: Cs2LightingDecision | null): boolean {
  return decision?.reason === 'bombPlanted';
}

function blendPalettes(from: HueRGBColor[], to: HueRGBColor[], progress: number): HueRGBColor[] {
  const count = Math.max(from.length, to.length, 1);
  const blended: HueRGBColor[] = [];
  for (let index = 0; index < count; index += 1) {
    const a = from[index % from.length] ?? { r: 0, g: 0, b: 0 };
    const b = to[index % to.length] ?? a;
    blended.push({
      r: lerp(a.r, b.r, progress),
      g: lerp(a.g, b.g, progress),
      b: lerp(a.b, b.b, progress),
    });
  }
  return blended;
}

function smoothstep(value: number): number {
  const t = clamp01(value);
  return t * t * (3 - (2 * t));
}

function lerp(from: number, to: number, progress: number): number {
  return clamp01(from + ((to - from) * progress));
}

function clamp01(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.max(0, Math.min(1, value));
}
