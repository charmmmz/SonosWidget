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
        return { transport: 'entertainmentStreaming' };
      }
      await this.post('/effect/flash', {
        intensity: frameIntensity(frame),
        attackMs: secondsToMs(effect.attackSeconds, 90),
        holdMs: secondsToMs(effect.holdSeconds, 90),
        fadeMs: secondsToMs(effect.fadeSeconds, 700),
      });
      return { transport: 'entertainmentStreaming' };
    }

    if (effect?.source === 'cs2' && effect.reason === 'kill') {
      if (!this.markEffectForPlayback(effect.effectKey, frame.createdAt)) {
        return { transport: 'entertainmentStreaming' };
      }
      await this.post('/effect/kill', {
        intensity: frameIntensity(frame),
        durationMs: 220,
      });
      return { transport: 'entertainmentStreaming' };
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
