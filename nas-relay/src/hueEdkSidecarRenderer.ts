import type { HueAmbienceFrame, HueAmbienceTargetFrame } from './hueAmbienceFrames.js';
import type { HueAmbienceRenderResult, HueAmbienceRenderer } from './hueFrameRenderer.js';
import type { HueAmbienceRuntimeConfig, HueRGBColor } from './hueTypes.js';

export type HueEdkSidecarFetch = (
  url: string,
  init?: {
    method?: string;
    headers?: Record<string, string>;
    body?: string;
  },
) => Promise<{
  ok: boolean;
  status: number;
  text(): Promise<string>;
}>;

export interface HueEdkSidecarRendererOptions {
  baseUrl: string;
  token?: string | null;
  fetch?: HueEdkSidecarFetch;
  targetFps?: number;
  sessionPolicy?: 'reuse' | 'takeover';
}

export function createHueEdkSidecarRenderer(
  config: HueAmbienceRuntimeConfig,
  options: HueEdkSidecarRendererOptions,
): HueAmbienceRenderer {
  return new HueEdkSidecarRenderer(config, options);
}

class HueEdkSidecarRenderer implements HueAmbienceRenderer {
  private configuredAreaId: string | null = null;
  private sessionStarted = false;
  private readonly playedEffectKeys = new Map<string, number>();

  constructor(
    private readonly config: HueAmbienceRuntimeConfig,
    private readonly options: HueEdkSidecarRendererOptions,
  ) {}

  async render(frame: HueAmbienceFrame): Promise<HueAmbienceRenderResult> {
    const target = entertainmentTargetForSidecar(frame);
    await this.ensureConfigured(target.area.id);
    await this.ensureStarted();

    const effect = frame.effect;
    if (effect?.source === 'cs2' && effect.reason === 'flash') {
      if (!this.markEffectForPlayback(effect.effectKey, frame.createdAt)) {
        return { transport: 'entertainmentStreaming', nativeEffectActive: true };
      }
      await this.post('/effect/flash', {
        intensity: frameIntensity(frame),
        attackMs: secondsToMs(effect.attackSeconds, 90),
        holdMs: secondsToMs(effect.holdSeconds, 90),
        fadeMs: secondsToMs(effect.fadeSeconds, 700),
      });
      return { transport: 'entertainmentStreaming', nativeEffectActive: true };
    }

    if (effect?.source === 'cs2' && effect.reason === 'kill') {
      if (!this.markEffectForPlayback(effect.effectKey, frame.createdAt)) {
        return { transport: 'entertainmentStreaming', nativeEffectActive: true };
      }
      const profile = nativeKillProfile(effect.strength);
      await this.post('/effect/kill', {
        ...profile.color,
        intensity: Math.max(frameIntensity(frame), profile.intensity),
        durationMs: profile.durationMs,
        radius: profile.radius,
      });
      return { transport: 'entertainmentStreaming', nativeEffectActive: true };
    }

    if (effect?.source === 'cs2' && effect.reason === 'burning') {
      if (!this.markEffectForPlayback(effect.effectKey, frame.createdAt)) {
        return { transport: 'entertainmentStreaming', nativeEffectActive: true };
      }
      const color = nativePulseColor(effect.reason, frame);
      await this.post('/effect/sphere', {
        kind: 'burning',
        ...color,
        intensity: frameIntensity(frame),
        attackMs: secondsToMs(effect.attackSeconds, 80),
        holdMs: secondsToMs(effect.holdSeconds, 120),
        fadeMs: secondsToMs(effect.fadeSeconds, 520),
        x: 0,
        y: 0,
        z: -0.82,
        radius: 1.35,
      });
      return { transport: 'entertainmentStreaming', nativeEffectActive: true };
    }

    if (effect?.source === 'cs2' && isPulseEffect(effect.reason)) {
      if (!this.markEffectForPlayback(effect.effectKey, frame.createdAt)) {
        return { transport: 'entertainmentStreaming', nativeEffectActive: true };
      }
      const color = nativePulseColor(effect.reason, frame);
      await this.post('/effect/pulse', {
        ...color,
        intensity: nativePulseIntensity(effect.reason, frame),
        attackMs: secondsToMs(effect.attackSeconds, 80),
        holdMs: secondsToMs(effect.holdSeconds, 120),
        fadeMs: secondsToMs(effect.fadeSeconds, 520),
      });
      return { transport: 'entertainmentStreaming', nativeEffectActive: true };
    }

    if (effect?.source === 'cs2' && effect.reason === 'bombPlanted') {
      if (!this.markEffectForPlayback(effect.effectKey, frame.createdAt)) {
        return { transport: 'entertainmentStreaming', nativeEffectActive: true };
      }
      await this.post('/ambient/team', {
        team: 'neutral',
        brightness: 1,
        transitionMs: secondsToMs(frame.transitionSeconds, 180),
        palette: framePalette(frame),
      });
      await this.post('/effect/c4', {
        remainingMs: effect.remainingMs ?? 40_000,
        intensity: frameIntensity(frame),
      });
      return { transport: 'entertainmentStreaming', nativeEffectActive: true };
    }

    if (effect?.source === 'cs2' && effect.reason === 'roundFreeze') {
      if (!this.markEffectForPlayback(effect.effectKey, frame.createdAt)) {
        return { transport: 'entertainmentStreaming', nativeEffectActive: true };
      }
      const color = framePalette(frame)[0] ?? { r: 0.05, g: 0.18, b: 0.44 };
      await this.post('/ambient/team', {
        team: 'neutral',
        brightness: 1,
        transitionMs: secondsToMs(frame.transitionSeconds, 400),
        palette: framePalette(frame),
      });
      await this.post('/effect/iterator', {
        kind: 'freeze',
        r: color.r,
        g: color.g,
        b: color.b,
        intensity: Math.min(0.65, Math.max(0.34, frameIntensity(frame))),
        pulseMs: 680,
        offsetMs: 180,
        order: 'clockwise',
        mode: 'cycle',
      });
      return { transport: 'entertainmentStreaming', nativeEffectActive: true };
    }

    if (effect?.source === 'cs2' && effect.reason === 'bombExploded') {
      if (!this.markEffectForPlayback(effect.effectKey, frame.createdAt)) {
        return { transport: 'entertainmentStreaming', nativeEffectActive: true };
      }
      const color = framePalette(frame)[0] ?? { r: 1, g: 0.55, b: 0.04 };
      await this.post('/effect/explosion', {
        r: color.r,
        g: color.g,
        b: color.b,
        intensity: frameIntensity(frame),
        durationMs: secondsToMs(
          (effect.attackSeconds ?? 0) + (effect.holdSeconds ?? 0) + (effect.fadeSeconds ?? 0),
          1_100,
        ),
        radius: 2.2,
      });
      return { transport: 'entertainmentStreaming', nativeEffectActive: true };
    }

    await this.post('/ambient/team', {
      team: teamForEffect(effect?.reason),
      brightness: 1,
      transitionMs: secondsToMs(frame.transitionSeconds, 240),
      palette: framePalette(frame),
    });
    return { transport: 'entertainmentStreaming' };
  }

  async stop(_frame: HueAmbienceFrame): Promise<void> {
    await this.post('/session/stop', {});
    this.sessionStarted = false;
  }

  async release(): Promise<void> {
    await this.post('/session/stop', {});
    this.sessionStarted = false;
  }

  private async ensureConfigured(areaId: string): Promise<void> {
    if (this.configuredAreaId === areaId) return;

    if (!this.config.streamingClientKey) {
      throw new Error('missing Hue Entertainment streaming credentials');
    }

    await this.post('/configure', {
      bridgeIp: this.config.bridge.ipAddress,
      bridgeName: this.config.bridge.name,
      applicationKey: this.config.applicationKey,
      streamingClientKey: this.config.streamingClientKey,
      streamingApplicationId: this.config.streamingApplicationId,
      entertainmentAreaId: areaId,
      targetFps: this.options.targetFps ?? 60,
      sessionPolicy: this.options.sessionPolicy ?? 'reuse',
    });
    this.configuredAreaId = areaId;
    this.sessionStarted = false;
  }

  private async ensureStarted(): Promise<void> {
    if (this.sessionStarted) return;
    await this.post('/session/start', {});
    this.sessionStarted = true;
  }

  private async post(path: string, body: unknown): Promise<void> {
    const response = await this.fetchFn()(sidecarUrl(this.options.baseUrl, path), {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        ...(this.options.token ? { authorization: `Bearer ${this.options.token}` } : {}),
      },
      body: JSON.stringify(body),
    });

    if (response.ok) return;

    const text = await response.text().catch(() => '');
    throw new Error(`Hue EDK sidecar ${path} failed (${response.status})${text ? `: ${text}` : ''}`);
  }

  private fetchFn(): HueEdkSidecarFetch {
    const fetchFn = this.options.fetch ?? globalThis.fetch;
    if (!fetchFn) {
      throw new Error('Hue EDK sidecar renderer requires fetch');
    }
    return fetchFn as HueEdkSidecarFetch;
  }

  private markEffectForPlayback(effectKey: string | undefined, createdAt: Date): boolean {
    if (!effectKey) return true;
    if (this.playedEffectKeys.has(effectKey)) return false;

    this.playedEffectKeys.set(effectKey, createdAt.getTime());
    if (this.playedEffectKeys.size > 128) {
      const oldest = [...this.playedEffectKeys.entries()]
        .sort((a, b) => a[1] - b[1])
        .slice(0, this.playedEffectKeys.size - 128);
      for (const [key] of oldest) {
        this.playedEffectKeys.delete(key);
      }
    }
    return true;
  }
}

function entertainmentTargetForSidecar(frame: HueAmbienceFrame): HueAmbienceTargetFrame {
  const targets = frame.targets.filter(target => target.area.kind === 'entertainmentArea');
  if (targets.length !== 1 || !targets[0]) {
    throw new Error('Hue EDK sidecar rendering requires exactly one entertainment area target');
  }
  return targets[0];
}

function sidecarUrl(baseUrl: string, path: string): string {
  const normalized = baseUrl.endsWith('/') ? baseUrl.slice(0, -1) : baseUrl;
  return `${normalized}${path}`;
}

function secondsToMs(seconds: number | undefined, fallbackMs: number): number {
  if (!Number.isFinite(seconds)) return fallbackMs;
  return Math.max(0, Math.round((seconds as number) * 1000));
}

function teamForEffect(reason: string | undefined): 'CT' | 'T' | 'observer' | 'neutral' {
  if (reason === 'observerAmbient') return 'observer';
  return 'neutral';
}

function isPulseEffect(reason: string | undefined): boolean {
  return reason === 'damage' || reason === 'death';
}

function nativePulseColor(reason: string, frame: HueAmbienceFrame): HueRGBColor {
  switch (reason) {
    case 'burning':
      return { r: 1, g: 0.28, b: 0 };
    case 'death':
      return { r: 0.8, g: 0.02, b: 0.02 };
    case 'damage':
    default:
      return framePalette(frame)[0] ?? { r: 1, g: 0.05, b: 0.02 };
  }
}

function nativePulseIntensity(reason: string, frame: HueAmbienceFrame): number {
  const intensity = frameIntensity(frame);
  if (reason === 'death') return Math.min(intensity, 0.55);
  return intensity;
}

function nativeKillProfile(strength: number | undefined): {
  color: HueRGBColor;
  intensity: number;
  durationMs: number;
  radius: number;
} {
  const tier = Math.min(3, Math.max(1, Math.round(strength ?? 1)));
  if (tier >= 3) {
    return {
      color: { r: 1, g: 0.92, b: 0.55 },
      intensity: 1,
      durationMs: 210,
      radius: 2.5,
    };
  }
  if (tier === 2) {
    return {
      color: { r: 1, g: 0.82, b: 0.24 },
      intensity: 0.95,
      durationMs: 190,
      radius: 2.1,
    };
  }
  return {
    color: { r: 1, g: 0.68, b: 0.1 },
    intensity: 0.86,
    durationMs: 170,
    radius: 1.7,
  };
}

function framePalette(frame: HueAmbienceFrame): HueRGBColor[] {
  const colors: HueRGBColor[] = [];
  for (const target of frame.targets) {
    for (const light of target.lights) {
      const color = light.colors[0];
      if (!color) continue;
      if (colors.some(existing => sameColor(existing, color))) continue;
      colors.push(clampColor(color));
      if (colors.length >= 8) return colors;
    }
  }
  return colors.length > 0 ? colors : [{ r: 0, g: 0, b: 0 }];
}

function frameIntensity(frame: HueAmbienceFrame): number {
  return Math.max(...framePalette(frame).map(color => Math.max(color.r, color.g, color.b)), 0);
}

function sameColor(a: HueRGBColor, b: HueRGBColor): boolean {
  return Math.abs(a.r - b.r) < 0.0001
    && Math.abs(a.g - b.g) < 0.0001
    && Math.abs(a.b - b.b) < 0.0001;
}

function clampColor(color: HueRGBColor): HueRGBColor {
  return {
    r: clamp01(color.r),
    g: clamp01(color.g),
    b: clamp01(color.b),
  };
}

function clamp01(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.max(0, Math.min(1, value));
}
