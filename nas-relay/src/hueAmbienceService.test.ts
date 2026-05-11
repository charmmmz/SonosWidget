import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import pino from 'pino';

import { HueAmbienceConfigStore } from './hueConfigStore.js';
import { DEFAULT_STOP_GRACE_MS, HueAmbienceService } from './hueAmbienceService.js';
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

test('non-music playing snapshots do not start Hue ambience', async () => {
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
