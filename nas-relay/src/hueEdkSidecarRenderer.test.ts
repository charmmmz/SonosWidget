import assert from 'node:assert/strict';
import { test } from 'node:test';

import { buildHueAmbienceFrame, type HueAmbienceFrame } from './hueAmbienceFrames.js';
import type { HueAmbienceRuntimeConfig, HueRGBColor } from './hueTypes.js';

test('Hue EDK sidecar renderer configures the selected entertainment area and sends ambient commands', async () => {
  const { createHueEdkSidecarRenderer } = await loadSidecarRendererModule();
  const recorder = recordingFetch();
  const renderer = createHueEdkSidecarRenderer(config, {
    baseUrl: 'http://hue-edk-sidecar:8787',
    fetch: recorder.fetch,
    token: 'relay-token',
    targetFps: 60,
  });

  const result = await renderer.render(cs2Frame('ambient', ctPalette, {
    mode: 'competitive',
    transitionSeconds: 0.28,
  }));

  assert.equal(result.transport, 'entertainmentStreaming');
  assert.deepEqual(recorder.calls.map(call => call.path), [
    '/configure',
    '/session/start',
    '/ambient/team',
  ]);
  assert.equal(recorder.calls[0]?.headers.authorization, 'Bearer relay-token');
  assert.deepEqual(recorder.calls[0]?.body, {
    bridgeIp: '192.168.50.216',
    bridgeName: 'Hue Bridge',
    applicationKey: 'app-key',
    streamingClientKey: 'stream-key',
    streamingApplicationId: 'stream-app',
    entertainmentAreaId: 'ent-1',
    targetFps: 60,
    sessionPolicy: 'reuse',
  });
  assert.equal((recorder.calls[2]?.body as Record<string, unknown>).team, 'neutral');
  assert.equal((recorder.calls[2]?.body as Record<string, unknown>).transitionMs, 280);
  assert.equal(typeof (recorder.calls[2]?.body as Record<string, unknown>).brightness, 'number');
});

test('Hue EDK sidecar renderer maps CS2 flash and kill frames to spatial effect endpoints', async () => {
  const { createHueEdkSidecarRenderer } = await loadSidecarRendererModule();
  const recorder = recordingFetch();
  const renderer = createHueEdkSidecarRenderer(config, {
    baseUrl: 'http://hue-edk-sidecar:8787',
    fetch: recorder.fetch,
  });

  await renderer.render(cs2Frame('flash', [{ r: 1, g: 1, b: 1 }], {
    attackSeconds: 0.12,
    holdSeconds: 0.08,
    fadeSeconds: 0.7,
    transitionSeconds: 0.08,
  }));
  await renderer.render(cs2Frame('kill', [{ r: 1, g: 0.72, b: 0.12 }], {
    strength: 3,
    attackSeconds: 0.05,
    holdSeconds: 0.1,
    fadeSeconds: 0.2,
    transitionSeconds: 0.08,
  }));

  assert.deepEqual(recorder.calls.map(call => call.path), [
    '/configure',
    '/session/start',
    '/effect/flash',
    '/effect/kill',
  ]);
  assert.deepEqual(recorder.calls[2]?.body, {
    intensity: 1,
    attackMs: 120,
    holdMs: 80,
    fadeMs: 700,
  });
  assert.deepEqual(recorder.calls[3]?.body, {
    r: 1,
    g: 0.92,
    b: 0.55,
    intensity: 1,
    durationMs: 210,
    radius: 2.5,
  });
});

test('Hue EDK sidecar renderer maps CS2 damage and burning states to native pulse and sphere effects', async () => {
  const { createHueEdkSidecarRenderer } = await loadSidecarRendererModule();
  const recorder = recordingFetch();
  const renderer = createHueEdkSidecarRenderer(config, {
    baseUrl: 'http://hue-edk-sidecar:8787',
    fetch: recorder.fetch,
  });

  const result = await renderer.render(cs2Frame('damage', [{ r: 1, g: 0.05, b: 0.02 }], {
    effectKey: 'damage-1',
    attackSeconds: 0.08,
    holdSeconds: 0.4,
    fadeSeconds: 0.55,
    transitionSeconds: 0.14,
  }));
  await renderer.render(cs2Frame('damage', [{ r: 0.5, g: 0.02, b: 0.01 }], {
    effectKey: 'damage-1',
    attackSeconds: 0.08,
    holdSeconds: 0.4,
    fadeSeconds: 0.55,
    transitionSeconds: 0.14,
  }));
  await renderer.render(cs2Frame('burning', [{ r: 1, g: 0.28, b: 0 }], {
    effectKey: 'burning-1',
    attackSeconds: 0.08,
    holdSeconds: 0.2,
    fadeSeconds: 0.4,
    transitionSeconds: 0.12,
  }));

  assert.equal(result.nativeEffectActive, true);
  assert.deepEqual(recorder.calls.map(call => call.path), [
    '/configure',
    '/session/start',
    '/effect/pulse',
    '/effect/sphere',
  ]);
  assert.deepEqual(recorder.calls[2]?.body, {
    r: 1,
    g: 0.05,
    b: 0.02,
    intensity: 1,
    attackMs: 80,
    holdMs: 400,
    fadeMs: 550,
  });
  assert.deepEqual(recorder.calls[3]?.body, {
    kind: 'burning',
    r: 1,
    g: 0.28,
    b: 0,
    intensity: 1,
    attackMs: 80,
    holdMs: 200,
    fadeMs: 400,
    x: 0,
    y: 0,
    z: -0.82,
    radius: 1.35,
  });
});

test('Hue EDK sidecar renderer maps planted C4 and round freeze to iterator effects', async () => {
  const { createHueEdkSidecarRenderer } = await loadSidecarRendererModule();
  const recorder = recordingFetch();
  const renderer = createHueEdkSidecarRenderer(config, {
    baseUrl: 'http://hue-edk-sidecar:8787',
    fetch: recorder.fetch,
  });

  const planted = await renderer.render(cs2Frame('bombPlanted', [{ r: 1, g: 0.16, b: 0.03 }], {
    effectKey: 'c4-1',
    remainingMs: 32_000,
    cadenceMs: 820,
    transitionSeconds: 0.18,
  }));
  await renderer.render(cs2Frame('bombPlanted', [{ r: 0.24, g: 0.04, b: 0.01 }], {
    effectKey: 'c4-1',
    remainingMs: 31_000,
    cadenceMs: 800,
    transitionSeconds: 0.18,
  }));
  const freeze = await renderer.render(cs2Frame('roundFreeze', [{ r: 0.05, g: 0.18, b: 0.44 }], {
    effectKey: 'freeze-1',
    transitionSeconds: 0.4,
  }));
  const exploded = await renderer.render(cs2Frame('bombExploded', [{ r: 1, g: 0.55, b: 0.04 }], {
    effectKey: 'c4-explosion-1',
    attackSeconds: 0.04,
    holdSeconds: 0.2,
    fadeSeconds: 1,
    transitionSeconds: 0.04,
  }));

  assert.equal(planted.nativeEffectActive, true);
  assert.equal(freeze.nativeEffectActive, true);
  assert.equal(exploded.nativeEffectActive, true);
  assert.deepEqual(recorder.calls.map(call => call.path), [
    '/configure',
    '/session/start',
    '/ambient/team',
    '/effect/c4',
    '/ambient/team',
    '/effect/iterator',
    '/effect/explosion',
  ]);
  assert.deepEqual(recorder.calls[3]?.body, {
    remainingMs: 32000,
    intensity: 1,
  });
  assert.deepEqual(recorder.calls[5]?.body, {
    kind: 'freeze',
    r: 0.05,
    g: 0.18,
    b: 0.44,
    intensity: 0.44,
    pulseMs: 680,
    offsetMs: 180,
    order: 'clockwise',
    mode: 'cycle',
  });
  assert.deepEqual(recorder.calls[6]?.body, {
    r: 1,
    g: 0.55,
    b: 0.04,
    intensity: 1,
    durationMs: 1240,
    radius: 2.2,
  });
});

test('Hue EDK sidecar renderer does not replay one CS2 effect across animation frames', async () => {
  const { createHueEdkSidecarRenderer } = await loadSidecarRendererModule();
  const recorder = recordingFetch();
  const renderer = createHueEdkSidecarRenderer(config, {
    baseUrl: 'http://hue-edk-sidecar:8787',
    fetch: recorder.fetch,
  });

  await renderer.render(cs2Frame('flash', [{ r: 0.45, g: 0.6, b: 0.8 }], {
    effectKey: 'flash-1',
    attackSeconds: 0.12,
    holdSeconds: 0.08,
    fadeSeconds: 0.7,
    transitionSeconds: 0.08,
  }));
  await renderer.render(cs2Frame('flash', [{ r: 1, g: 1, b: 1 }], {
    effectKey: 'flash-1',
    attackSeconds: 0.12,
    holdSeconds: 0.08,
    fadeSeconds: 0.7,
    transitionSeconds: 0.08,
  }));

  assert.deepEqual(recorder.calls.map(call => call.path), [
    '/configure',
    '/session/start',
    '/effect/flash',
  ]);
});

test('Hue EDK sidecar renderer refuses CS2 rendering without streaming credentials', async () => {
  const { createHueEdkSidecarRenderer } = await loadSidecarRendererModule();
  const renderer = createHueEdkSidecarRenderer({
    ...config,
    streamingClientKey: null,
  }, {
    baseUrl: 'http://hue-edk-sidecar:8787',
    fetch: recordingFetch().fetch,
  });

  await assert.rejects(
    () => renderer.render(cs2Frame('ambient', ctPalette)),
    /missing Hue Entertainment streaming credentials/,
  );
});

test('Hue EDK sidecar renderer stops the active sidecar session', async () => {
  const { createHueEdkSidecarRenderer } = await loadSidecarRendererModule();
  const recorder = recordingFetch();
  const renderer = createHueEdkSidecarRenderer(config, {
    baseUrl: 'http://hue-edk-sidecar:8787',
    fetch: recorder.fetch,
  });
  const frame = cs2Frame('ambient', ctPalette);

  await renderer.render(frame);
  await renderer.stop(frame);

  assert.deepEqual(recorder.calls.map(call => call.path), [
    '/configure',
    '/session/start',
    '/ambient/team',
    '/session/stop',
  ]);
});

interface SidecarRendererModule {
  createHueEdkSidecarRenderer: (
    config: HueAmbienceRuntimeConfig,
    options: Record<string, unknown>,
  ) => {
    render(frame: HueAmbienceFrame): Promise<{
      transport: 'entertainmentStreaming';
      nativeEffectActive?: boolean;
    }>;
    stop(frame: HueAmbienceFrame): Promise<void>;
  };
}

async function loadSidecarRendererModule(): Promise<SidecarRendererModule> {
  try {
    return await import('./hueEdkSidecarRenderer.js') as SidecarRendererModule;
  } catch (err) {
    assert.fail(`expected Hue EDK sidecar renderer module to load: ${err instanceof Error ? err.message : String(err)}`);
  }
}

interface RecordedRequest {
  path: string;
  headers: Record<string, string>;
  body: unknown;
}

function recordingFetch(): {
  calls: RecordedRequest[];
  fetch: (url: string, init?: Record<string, unknown>) => Promise<{
    ok: boolean;
    status: number;
    text(): Promise<string>;
  }>;
} {
  const calls: RecordedRequest[] = [];
  return {
    calls,
    fetch: async (url, init = {}) => {
      calls.push({
        path: new URL(url).pathname,
        headers: normalizeHeaders(init.headers),
        body: init.body ? JSON.parse(String(init.body)) : null,
      });
      return {
        ok: true,
        status: 200,
        text: async () => '{"ok":true}',
      };
    },
  };
}

function normalizeHeaders(headers: unknown): Record<string, string> {
  if (!headers || typeof headers !== 'object') return {};
  return Object.fromEntries(
    Object.entries(headers as Record<string, unknown>)
      .map(([key, value]) => [key.toLowerCase(), String(value)]),
  );
}

const ctPalette: HueRGBColor[] = [
  { r: 0.05, g: 0.18, b: 0.44 },
  { r: 0.02, g: 0.09, b: 0.24 },
];

function cs2Frame(
  reason: string,
  palette: HueRGBColor[],
  overrides: Record<string, unknown> = {},
): HueAmbienceFrame {
  const transitionSeconds = typeof overrides.transitionSeconds === 'number'
    ? overrides.transitionSeconds
    : 0.28;
  const frame = buildHueAmbienceFrame({
    targets: [{
      area: config.resources.areas[0]!,
      mapping: config.mappings[0]!,
      lights: config.resources.lights,
    }],
    snapshot: {
      groupId: 'cs2',
      speakerName: 'CS2',
      trackTitle: reason,
      artist: 'Counter-Strike 2',
      album: 'competitive',
      albumArtUri: '',
      isPlaying: true,
      positionSeconds: 0,
      durationSeconds: 0,
      groupMemberCount: 1,
      sampledAt: new Date('2026-05-13T00:00:00Z'),
    },
    palette,
    reason: 'steady',
    phase: 0,
    transitionSeconds,
    now: new Date('2026-05-13T00:00:00Z'),
  });
  return {
    ...frame,
    effect: {
      source: 'cs2',
      reason,
      effectKey: overrides.effectKey,
      mode: overrides.mode ?? 'competitive',
      transitionSeconds,
      attackSeconds: overrides.attackSeconds ?? 0,
      holdSeconds: overrides.holdSeconds ?? 0,
      fadeSeconds: overrides.fadeSeconds ?? 0,
      cadenceMs: overrides.cadenceMs,
      remainingMs: overrides.remainingMs,
      strength: overrides.strength,
    },
  } as HueAmbienceFrame;
}

const config: HueAmbienceRuntimeConfig = {
  enabled: true,
  cs2LightingEnabled: true,
  bridge: { id: 'bridge-1', ipAddress: '192.168.50.216', name: 'Hue Bridge' },
  applicationKey: 'app-key',
  streamingClientKey: 'stream-key',
  streamingApplicationId: 'stream-app',
  resources: {
    lights: [{
      id: 'light-1',
      name: 'Gradient Strip',
      supportsColor: true,
      supportsGradient: true,
      supportsEntertainment: true,
      function: 'decorative',
      functionMetadataResolved: true,
    }],
    areas: [{
      id: 'ent-1',
      name: 'PC Area',
      kind: 'entertainmentArea',
      childLightIDs: ['light-1'],
      entertainmentChannels: [{ id: '0', lightID: 'light-1', serviceID: 'svc-1' }],
    }],
  },
  mappings: [{
    sonosID: 'office',
    sonosName: 'Office',
    relayGroupID: '192.168.50.25',
    preferredTarget: { kind: 'entertainmentArea', id: 'ent-1' },
    fallbackTarget: null,
    includedLightIDs: [],
    excludedLightIDs: [],
    capability: 'liveEntertainment',
  }],
  groupStrategy: 'coordinatorOnly',
  stopBehavior: 'leaveCurrent',
  motionStyle: 'still',
  flowIntervalSeconds: 8,
};
