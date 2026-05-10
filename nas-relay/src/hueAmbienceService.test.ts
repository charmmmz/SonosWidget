import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import pino from 'pino';

import { HueAmbienceConfigStore } from './hueConfigStore.js';
import { HueAmbienceService } from './hueAmbienceService.js';
import type { HueAmbienceRuntimeConfig, HueLightClient, HueRGBColor, HueSnapshot } from './hueTypes.js';

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
