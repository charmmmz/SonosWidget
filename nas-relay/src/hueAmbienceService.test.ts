import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import pino from 'pino';

import { HueAmbienceConfigStore } from './hueConfigStore.js';
import { DEFAULT_STOP_GRACE_MS, HueAmbienceService } from './hueAmbienceService.js';
import type { HueAmbienceFrame } from './hueAmbienceFrames.js';
import type { HueAmbienceRenderer } from './hueFrameRenderer.js';
import type { HueAmbienceRuntimeConfig, HueLightClient, HueRGBColor, HueSnapshot } from './hueTypes.js';

test('default stop grace buffers Sonos track-change transport gaps', () => {
  assert.equal(DEFAULT_STOP_GRACE_MS, 4_000);
});

test('album art URI participates in Hue ambience track changes when metadata is empty', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      async snapshot => snapshot.albumArtUri?.includes('two')
        ? [{ r: 0, g: 0, b: 1 }]
        : [{ r: 1, g: 0, b: 0 }],
    );
    await service.load();

    service.receiveSnapshot(snapshot('/art-one.jpg'));
    await waitFor(() => client.updates.length === 1);

    service.receiveSnapshot(snapshot('/art-two.jpg'));
    await waitFor(() => client.updates.length === 2);

    assert.notDeepEqual(client.updates[0]!.body, client.updates[1]!.body);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('paused playback cancels a pending Hue ambience start before it can wake lights', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({ ...config, stopBehavior: 'turnOff' });
    const client = new RecordingHueLightClient();
    const pendingPalette = deferred<HueRGBColor[]>();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => pendingPalette.promise,
      1,
    );
    await service.load();

    service.receiveSnapshot(snapshot('/art-one.jpg'));
    await waitFor(() => service.status().runtimeActive === true);

    service.receiveSnapshot({ ...snapshot('/art-one.jpg'), isPlaying: false });
    await waitFor(() => client.updates.length === 1);
    assert.deepEqual(client.updates[0]!.body, {
      on: { on: false },
      dynamics: { duration: 1200 },
    });

    pendingPalette.resolve([{ r: 0, g: 0, b: 1 }]);
    await new Promise(resolve => setTimeout(resolve, 20));

    assert.equal(client.updates.length, 1);
    assert.equal(service.status().runtimeActive, false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('playing snapshots cancel a pending stop before lights are turned off', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({ ...config, stopBehavior: 'turnOff' });
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }],
      25,
    );
    await service.load();

    service.receiveSnapshot(snapshot('/art-one.jpg'));
    await waitFor(() => client.updates.length === 1);

    service.receiveSnapshot({ ...snapshot('/art-one.jpg'), isPlaying: false });
    await new Promise(resolve => setTimeout(resolve, 5));
    assert.equal(client.updates.length, 1);

    service.receiveSnapshot(snapshot('/art-one.jpg'));
    await new Promise(resolve => setTimeout(resolve, 35));

    assert.equal(client.updates.length, 1);
    assert.equal(service.status().runtimeActive, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('same track resumes pending Hue ambience start before stop grace and still renders', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({ ...config, stopBehavior: 'turnOff' });
    const client = new RecordingHueLightClient();
    const pendingPalette = deferred<HueRGBColor[]>();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => pendingPalette.promise,
      50,
    );
    await service.load();

    const playing = snapshot('/art-one.jpg');
    service.receiveSnapshot(playing);
    await waitFor(() => service.status().runtimeActive === true);

    service.receiveSnapshot({ ...playing, isPlaying: false });
    await new Promise(resolve => setTimeout(resolve, 5));

    service.receiveSnapshot(playing);
    pendingPalette.resolve([{ r: 0, g: 0, b: 1 }]);

    await waitFor(() => client.updates.length === 1);
    assert.equal(service.status().runtimeActive, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('same track retries Hue ambience render after initial render failure', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);
    const renderer = new FailingOnceHueAmbienceRenderer();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => new RecordingHueLightClient(),
      () => [{ r: 1, g: 0, b: 0 }],
      1,
      () => renderer,
    );
    await service.load();

    const playing = snapshot('/art-one.jpg');
    service.receiveSnapshot(playing);
    await waitFor(() => renderer.renderAttempts === 1);

    service.receiveSnapshot(playing);
    await waitFor(() => renderer.renderAttempts === 2);

    assert.equal(renderer.renderedFrames.length, 1);
    assert.equal(service.status().renderMode, 'clipFallback');
    assert.equal(service.status().runtimeActive, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('idle snapshots from other Sonos groups do not stop the active Hue ambience group', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({ ...config, stopBehavior: 'turnOff' });
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }],
      1,
    );
    await service.load();

    service.receiveSnapshot(snapshot('/art-one.jpg'));
    await waitFor(() => client.updates.length === 1);

    service.receiveSnapshot({
      ...snapshot('/other-room.jpg'),
      groupId: '192.168.50.99',
      speakerName: 'Move',
      isPlaying: false,
    });
    await new Promise(resolve => setTimeout(resolve, 20));

    assert.equal(client.updates.length, 1);
    assert.equal(service.status().runtimeActive, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('non-music playing snapshots do not start Hue ambience or set lastError', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({ ...config, stopBehavior: 'turnOff' });
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }],
      1,
    );
    await service.load();

    service.receiveSnapshot({
      ...snapshot('/tv-art.jpg'),
      playbackSourceRaw: 'tv',
      musicAmbienceEligible: false,
    });
    await new Promise(resolve => setTimeout(resolve, 20));

    assert.equal(client.updates.length, 0);
    assert.equal(service.status().runtimeActive, false);
    assert.equal(service.status().lastError, null);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('unmapped playing groups do not set lastError', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }],
      1,
    );
    await service.load();

    service.receiveSnapshot({
      ...snapshot('/unmapped-art.jpg'),
      groupId: '192.168.50.99',
      speakerName: 'Kitchen',
    });
    await new Promise(resolve => setTimeout(resolve, 20));

    assert.equal(client.updates.length, 0);
    assert.equal(service.status().runtimeActive, false);
    assert.equal(service.status().lastError, null);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('partial initial render failure turns off pending frame lights when configured', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(twoLightConfig({ stopBehavior: 'turnOff' }));
    const client = new FailOnSecondUpdateHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }, { r: 0, g: 0, b: 1 }],
      1,
    );
    await service.load();

    service.receiveSnapshot(snapshot('/partial-art.jpg'));
    await waitFor(() => client.updates.some(update => isLightOffBody(update.body)));

    assert.deepEqual(
      client.updates.filter(update => isLightOffBody(update.body)).map(update => update.id),
      ['light-1', 'light-2'],
    );
    assert.equal(service.status().runtimeActive, false);
    assert.match(service.status().lastError ?? '', /partial render failed/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('service reports streaming-ready mode for entertainment targets through CLIP fallback', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(entertainmentConfig());
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }, { r: 0, g: 0, b: 1 }],
    );
    await service.load();

    service.receiveSnapshot(snapshot('/entertainment-art.jpg'));
    await waitFor(() => client.updates.length === 1);

    const status = service.status();
    assert.equal(status.renderMode, 'streamingReady');
    assert.equal(status.entertainmentTargetActive, true);
    assert.equal(status.entertainmentMetadataComplete, true);
    assert.deepEqual(status.activeTargetIds, ['ent-1']);
    assert.ok(status.lastFrameAt);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('service reports incomplete entertainment metadata without selecting unrelated lights', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(entertainmentConfig({ entertainmentChannels: [] }));
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }, { r: 0, g: 0, b: 1 }],
    );
    await service.load();

    service.receiveSnapshot(snapshot('/entertainment-art.jpg'));
    await waitFor(() => client.updates.length === 1);

    assert.equal(service.status().renderMode, 'streamingReady');
    assert.equal(service.status().entertainmentMetadataComplete, false);
    assert.deepEqual(client.updates.map(update => update.id), ['light-1']);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

const config: HueAmbienceRuntimeConfig = {
  enabled: true,
  bridge: { id: 'bridge-1', ipAddress: '192.168.50.216', name: 'Hue Bridge' },
  applicationKey: 'secret-key',
  resources: {
    lights: [
      {
        id: 'light-1',
        name: 'Lamp',
        supportsColor: true,
        supportsGradient: false,
        supportsEntertainment: true,
        function: 'decorative',
        functionMetadataResolved: true,
      },
    ],
    areas: [
      {
        id: 'room-1',
        name: 'Room',
        kind: 'room',
        childLightIDs: ['light-1'],
      },
    ],
  },
  mappings: [
    {
      sonosID: 'office',
      sonosName: 'Office',
      relayGroupID: '192.168.50.25',
      preferredTarget: { kind: 'room', id: 'room-1' },
      fallbackTarget: null,
      includedLightIDs: [],
      excludedLightIDs: [],
      capability: 'basic',
    },
  ],
  groupStrategy: 'coordinatorOnly',
  stopBehavior: 'leaveCurrent',
  motionStyle: 'still',
  flowIntervalSeconds: 8,
};

function twoLightConfig(
  overrides: Partial<HueAmbienceRuntimeConfig> = {},
): HueAmbienceRuntimeConfig {
  return {
    ...config,
    ...overrides,
    resources: {
      lights: [
        ...config.resources.lights,
        {
          id: 'light-2',
          name: 'Lamp 2',
          supportsColor: true,
          supportsGradient: false,
          supportsEntertainment: true,
          function: 'decorative',
          functionMetadataResolved: true,
        },
      ],
      areas: [
        {
          ...config.resources.areas[0]!,
          childLightIDs: ['light-1', 'light-2'],
        },
      ],
    },
  };
}

function entertainmentConfig(
  areaOverrides: Partial<HueAmbienceRuntimeConfig['resources']['areas'][number]> = {},
): HueAmbienceRuntimeConfig {
  return {
    ...config,
    resources: {
      lights: [
        {
          id: 'light-1',
          name: 'Gradient Lamp',
          supportsColor: true,
          supportsGradient: true,
          supportsEntertainment: true,
          function: 'decorative',
          functionMetadataResolved: true,
        },
        {
          id: 'light-unrelated',
          name: 'Unrelated Lamp',
          supportsColor: true,
          supportsGradient: false,
          supportsEntertainment: false,
          function: 'decorative',
          functionMetadataResolved: true,
        },
      ],
      areas: [
        {
          id: 'ent-1',
          name: 'Entertainment Area',
          kind: 'entertainmentArea',
          childLightIDs: ['light-1'],
          entertainmentChannels: [{ id: '0', lightID: 'light-1', serviceID: 'svc-1' }],
          ...areaOverrides,
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
  };
}

function snapshot(albumArtUri: string): HueSnapshot {
  return {
    groupId: '192.168.50.25',
    speakerName: 'Office',
    trackTitle: '',
    artist: '',
    album: '',
    albumArtUri,
    isPlaying: true,
    positionSeconds: 0,
    durationSeconds: 180,
    groupMemberCount: 1,
    sampledAt: new Date('2026-05-11T00:00:00Z'),
  };
}

class RecordingHueLightClient implements HueLightClient {
  updates: Array<{ id: string; body: unknown }> = [];

  async updateLight(id: string, body: unknown): Promise<void> {
    this.updates.push({ id, body });
  }
}

class FailOnSecondUpdateHueLightClient extends RecordingHueLightClient {
  private attemptCount = 0;

  override async updateLight(id: string, body: unknown): Promise<void> {
    this.attemptCount += 1;
    if (this.attemptCount === 2) {
      throw new Error('partial render failed');
    }
    await super.updateLight(id, body);
  }
}

class FailingOnceHueAmbienceRenderer implements HueAmbienceRenderer {
  renderAttempts = 0;
  renderedFrames: HueAmbienceFrame[] = [];
  stoppedFrames: HueAmbienceFrame[] = [];

  async render(frame: HueAmbienceFrame): Promise<void> {
    this.renderAttempts += 1;
    if (this.renderAttempts === 1) {
      throw new Error('render failed');
    }
    this.renderedFrames.push(frame);
  }

  async stop(frame: HueAmbienceFrame): Promise<void> {
    this.stoppedFrames.push(frame);
  }
}

function isLightOffBody(body: unknown): boolean {
  return typeof body === 'object'
    && body !== null
    && 'on' in body
    && typeof body.on === 'object'
    && body.on !== null
    && 'on' in body.on
    && body.on.on === false;
}

async function waitFor(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 1000;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  assert.equal(predicate(), true);
}

function deferred<T>(): { promise: Promise<T>; resolve: (value: T) => void } {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(innerResolve => {
    resolve = innerResolve;
  });
  return { promise, resolve };
}
