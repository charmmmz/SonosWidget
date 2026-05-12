import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import { Cs2LightingService, buildCs2LightingDecision } from './cs2Lighting.js';
import { HueAmbienceConfigStore } from './hueConfigStore.js';
import type { HueAmbienceFrame } from './hueAmbienceFrames.js';
import type { HueAmbienceRenderer } from './hueFrameRenderer.js';
import type { Cs2GameStateSnapshot } from './cs2Types.js';
import type { HueAmbienceRuntimeConfig, HueRGBColor } from './hueTypes.js';

test('CS2 decision gives burning priority over simultaneous health damage', () => {
  const previous = snapshot({
    player: {
      state: { health: 80, burning: 0, flashed: 0 },
    },
  });
  const current = snapshot({
    player: {
      state: { health: 55, burning: 1, flashed: 0 },
    },
  });

  const decision = buildCs2LightingDecision(current, previous);

  assert.equal(decision.mode, 'competitive');
  assert.equal(decision.reason, 'burning');
  assert.deepEqual(decision.palette[0], { r: 1, g: 0.28, b: 0 });
});

test('CS2 decision ignores competitive observer state instead of taking over lights', () => {
  const decision = buildCs2LightingDecision(snapshot({
    player: {
      team: 'CT',
      activity: 'Playing',
      state: { health: 0, burning: 0, flashed: 0 },
    },
  }));

  assert.equal(decision, null);
});

test('CS2 kill effect uses a short non-green burst', () => {
  const previous = snapshot({
    player: { state: { round_kills: 0, health: 100, burning: 0, flashed: 0 } },
  });
  const current = snapshot({
    player: { state: { round_kills: 1, health: 100, burning: 0, flashed: 0 } },
  });

  const decision = buildCs2LightingDecision(current, previous);

  assert.equal(decision?.reason, 'kill');
  assert(decision.attackSeconds <= 0.08);
  assert(decision.holdSeconds <= 0.16);
  assert(decision.fadeSeconds <= 0.25);
  assert(decision.palette.every(color => color.g <= Math.max(color.r, color.b)));
});

test('CS2 decision uses separate deathmatch damage strategy', () => {
  const previous = snapshot({
    map: { mode: 'Deathmatch' },
    player: { state: { health: 100, burning: 0, flashed: 0 } },
  });
  const current = snapshot({
    map: { mode: 'Deathmatch' },
    player: { state: { health: 68, burning: 0, flashed: 0 } },
  });

  const decision = buildCs2LightingDecision(current, previous);

  assert.equal(decision.mode, 'deathmatch');
  assert.equal(decision.reason, 'damage');
  assert.equal(decision.transitionSeconds, 0.1);
  assert.deepEqual(decision.palette[0], { r: 1, g: 0.05, b: 0.02 });
});

test('CS2 lighting service renders enabled game state to mapped entertainment area', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cs2-lighting-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);
    const renderer = new RecordingHueAmbienceRenderer();
    const service = new Cs2LightingService(store, () => renderer);

    await service.receive(snapshot({
      player: { state: { health: 100, burning: 0, flashed: 1 } },
    }));

    assert.equal(renderer.renderedFrames.length, 1);
    const frame = renderer.renderedFrames[0]!;
    assert.equal(frame.mode, 'streamingReady');
    assert.equal(frame.targets[0]?.area.id, 'ent-1');
    const color = frame.targets[0]?.lights[0]?.colors[0];
    assert(color && color.r > 0.05 && color.r < 1);
    assert.equal(frame.transitionSeconds, 0.08);
    assert.deepEqual(service.status(), {
      enabled: true,
      active: true,
      mode: 'competitive',
      transport: 'entertainmentStreaming',
      fallbackReason: null,
    });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('CS2 lighting service reports Entertainment Streaming transport when renderer streams', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cs2-lighting-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);
    const renderer = new RecordingHueAmbienceRenderer('entertainmentStreaming');
    const service = new Cs2LightingService(store, () => renderer);

    await service.receive(snapshot({
      player: { state: { health: 100, burning: 0, flashed: 1 } },
    }));

    assert.equal(renderer.renderedFrames.length, 1);
    assert.deepEqual(service.status(), {
      enabled: true,
      active: true,
      mode: 'competitive',
      transport: 'entertainmentStreaming',
      fallbackReason: null,
    });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('CS2 lighting service rejects CLIP fallback render results', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cs2-lighting-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);
    const renderer = new RecordingHueAmbienceRenderer('clipFallback');
    const service = new Cs2LightingService(store, () => renderer);

    await service.receive(snapshot({
      player: { state: { health: 100, burning: 0, flashed: 1 } },
    }));

    assert.equal(renderer.renderedFrames.length, 1);
    assert.deepEqual(service.status(), {
      enabled: true,
      active: false,
      mode: 'idle',
      transport: 'unavailable',
      fallbackReason: 'render_error:CS2 lighting requires Hue Entertainment streaming',
    });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('CS2 lighting service reports fallback when no entertainment area is mapped', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cs2-lighting-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({
      ...config,
      resources: {
        ...config.resources,
        areas: [{ id: 'room-1', name: 'Room', kind: 'room', childLightIDs: ['light-1'] }],
      },
      mappings: [{
        ...config.mappings[0]!,
        preferredTarget: { kind: 'room', id: 'room-1' },
        capability: 'basic',
      }],
    });
    const renderer = new RecordingHueAmbienceRenderer();
    const service = new Cs2LightingService(store, () => renderer);

    await service.receive(snapshot());

    assert.equal(renderer.renderedFrames.length, 0);
    assert.deepEqual(service.status(), {
      enabled: true,
      active: false,
      mode: 'idle',
      transport: 'unavailable',
      fallbackReason: 'no_entertainment_area',
    });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('CS2 lighting service keeps duplicate game state active without re-rendering', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cs2-lighting-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);
    const renderer = new RecordingHueAmbienceRenderer();
    const service = new Cs2LightingService(store, () => renderer, {
      activeTimeoutMs: 10,
      minRenderIntervalMs: 100,
    });
    const state = snapshot();

    await service.receive(state);
    await new Promise(resolve => setTimeout(resolve, 20));
    await service.receive(state);

    assert.equal(renderer.renderedFrames.length, 1);
    assert.equal(service.status().active, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('CS2 lighting service renders kill as a short burst and restores ambient quickly', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cs2-lighting-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);
    const renderer = new RecordingHueAmbienceRenderer();
    let now = new Date('2026-05-12T09:30:00.000Z').getTime();
    const service = new Cs2LightingService(store, () => renderer, {
      minRenderIntervalMs: 0,
      now: () => now,
    });

    await service.receive(snapshot({
      receivedAt: new Date(now),
      player: { state: { round_kills: 0, health: 100, burning: 0, flashed: 0 } },
    }));
    now += 10;
    await service.receive(snapshot({
      receivedAt: new Date(now),
      player: { state: { round_kills: 1, health: 100, burning: 0, flashed: 0 } },
    }));
    now += 40;
    await service.receive(snapshot({
      receivedAt: new Date(now),
      player: { state: { round_kills: 1, health: 100, burning: 0, flashed: 0 } },
    }));
    const burst = renderer.renderedFrames.at(-1)?.targets[0]?.lights[0]?.colors[0];

    now += 360;
    await service.receive(snapshot({
      receivedAt: new Date(now),
      player: { state: { round_kills: 1, health: 100, burning: 0, flashed: 0 } },
    }));
    const restored = renderer.renderedFrames.at(-1)?.targets[0]?.lights[0]?.colors[0];

    assert(burst && burst.r > 0.8 && burst.g > 0.2);
    assert.deepEqual(restored, { r: 0.05, g: 0.18, b: 0.44 });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('CS2 flash effect attacks from team color to white and releases back smoothly', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'cs2-lighting-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);
    const renderer = new RecordingHueAmbienceRenderer();
    let now = new Date('2026-05-12T09:30:00.000Z').getTime();
    const service = new Cs2LightingService(store, () => renderer, {
      minRenderIntervalMs: 0,
      now: () => now,
    });

    await service.receive(snapshot({
      receivedAt: new Date(now),
      player: { team: 'CT', state: { health: 100, burning: 0, flashed: 0 } },
    }));
    const ambient = renderer.renderedFrames.at(-1)?.targets[0]?.lights[0]?.colors[0];

    now += 20;
    await service.receive(snapshot({
      receivedAt: new Date(now),
      player: { team: 'CT', state: { health: 100, burning: 0, flashed: 1 } },
    }));
    const attack = renderer.renderedFrames.at(-1)?.targets[0]?.lights[0]?.colors[0];

    now += 120;
    await service.receive(snapshot({
      receivedAt: new Date(now),
      player: { team: 'CT', state: { health: 100, burning: 0, flashed: 1 } },
    }));
    const peak = renderer.renderedFrames.at(-1)?.targets[0]?.lights[0]?.colors[0];

    now += 260;
    await service.receive(snapshot({
      receivedAt: new Date(now),
      player: { team: 'CT', state: { health: 100, burning: 0, flashed: 0 } },
    }));
    const release = renderer.renderedFrames.at(-1)?.targets[0]?.lights[0]?.colors[0];

    now += 500;
    await service.receive(snapshot({
      receivedAt: new Date(now),
      player: { team: 'CT', state: { health: 100, burning: 0, flashed: 0 } },
    }));
    const restored = renderer.renderedFrames.at(-1)?.targets[0]?.lights[0]?.colors[0];

    assert.deepEqual(ambient, { r: 0.05, g: 0.18, b: 0.44 });
    assert(attack && attack.r > ambient!.r && attack.r < 1);
    assert.deepEqual(peak, { r: 1, g: 1, b: 1 });
    assert(release && release.r > ambient!.r && release.r < 1);
    assert.deepEqual(restored, ambient);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('CS2 planted bomb effect changes blink frame as the detonation window advances', () => {
  const plantedAt = new Date('2026-05-12T09:30:00.000Z');
  const first = buildCs2LightingDecision(snapshot({
    receivedAt: plantedAt,
    round: { bomb: 'planted' },
  }), undefined, { bombPlantedAt: plantedAt.getTime(), nowMs: plantedAt.getTime() });

  const later = buildCs2LightingDecision(snapshot({
    receivedAt: new Date(plantedAt.getTime() + 15_000),
    round: { bomb: 'planted' },
  }), undefined, { bombPlantedAt: plantedAt.getTime(), nowMs: plantedAt.getTime() + 15_000 });

  assert.equal(first?.reason, 'bombPlanted');
  assert.equal(later?.reason, 'bombPlanted');
  assert.notEqual(first?.dynamicKey, later?.dynamicKey);
  assert.notDeepEqual(first?.palette, later?.palette);
});

const config: HueAmbienceRuntimeConfig = {
  enabled: true,
  cs2LightingEnabled: true,
  bridge: { id: 'bridge-1', ipAddress: '192.168.50.216', name: 'Hue Bridge' },
  applicationKey: 'secret-key',
  resources: {
    lights: [
      {
        id: 'light-1',
        name: 'Gradient Strip',
        supportsColor: true,
        supportsGradient: true,
        supportsEntertainment: true,
        function: 'decorative',
        functionMetadataResolved: true,
      },
    ],
    areas: [
      {
        id: 'ent-1',
        name: 'PC Area',
        kind: 'entertainmentArea',
        childLightIDs: ['light-1'],
        entertainmentChannels: [{ id: '0', lightID: 'light-1', serviceID: 'svc-1' }],
      },
    ],
  },
  mappings: [
    {
      sonosID: 'office',
      sonosName: 'Office',
      relayGroupID: '192.168.50.25',
      preferredTarget: { kind: 'entertainmentArea', id: 'ent-1' },
      fallbackTarget: null,
      includedLightIDs: [],
      excludedLightIDs: [],
      capability: 'liveEntertainment',
    },
  ],
  groupStrategy: 'coordinatorOnly',
  stopBehavior: 'leaveCurrent',
  motionStyle: 'still',
  flowIntervalSeconds: 8,
};

function snapshot(overrides: Partial<Cs2GameStateSnapshot> = {}): Cs2GameStateSnapshot {
  return {
    providerSteamId: '76561197981496355',
    receivedAt: new Date('2026-05-12T09:30:00Z'),
    provider: {
      name: 'Counter-Strike 2',
      appid: 730,
      steamid: '76561197981496355',
    },
    map: {
      mode: 'Competitive',
      name: 'de_inferno',
      phase: 'Live',
      ...overrides.map,
    },
    round: {
      phase: 'Live',
      ...overrides.round,
    },
    player: {
      steamid: '76561197981496355',
      name: 'Charm',
      team: 'CT',
      activity: 'Playing',
      state: {
        health: 100,
        flashed: 0,
        burning: 0,
        ...overrides.player?.state,
      },
      match_stats: {
        kills: 0,
        deaths: 0,
        ...overrides.player?.match_stats,
      },
      ...overrides.player,
    },
    payload: {},
    ...overrides,
  };
}

function maxChannel(color: HueRGBColor): number {
  return Math.max(color.r, color.g, color.b);
}

class RecordingHueAmbienceRenderer implements HueAmbienceRenderer {
  readonly renderedFrames: HueAmbienceFrame[] = [];
  readonly stoppedFrames: HueAmbienceFrame[] = [];

  constructor(private readonly transport: 'clipFallback' | 'entertainmentStreaming' = 'entertainmentStreaming') {}

  async render(frame: HueAmbienceFrame): Promise<{ transport: 'clipFallback' | 'entertainmentStreaming' }> {
    this.renderedFrames.push(frame);
    return { transport: this.transport };
  }

  async stop(frame: HueAmbienceFrame): Promise<void> {
    this.stoppedFrames.push(frame);
  }
}
