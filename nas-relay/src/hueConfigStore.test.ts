import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import { HueAmbienceConfigStore } from './hueConfigStore.js';
import type { HueAmbienceRuntimeConfig } from './hueTypes.js';

const config: HueAmbienceRuntimeConfig = {
  enabled: true,
  bridge: { id: 'bridge-1', ipAddress: '192.168.50.216', name: 'Hue Bridge' },
  applicationKey: 'secret-key',
  resources: { lights: [], areas: [] },
  mappings: [],
  groupStrategy: 'coordinatorOnly',
  stopBehavior: 'turnOff',
  motionStyle: 'still',
  flowIntervalSeconds: 8,
};

test('config store persists runtime config without redacting the saved application key', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-config-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);

    const reloaded = new HueAmbienceConfigStore(dir);
    const loaded = await reloaded.load();
    assert.equal(loaded?.applicationKey, 'secret-key');

    const raw = JSON.parse(await readFile(path.join(dir, 'hue-ambience-config.json'), 'utf8'));
    assert.equal(raw.applicationKey, 'secret-key');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('config store status redacts application key', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-config-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);

    assert.deepEqual(store.status(), {
      configured: true,
      enabled: true,
      bridge: { id: 'bridge-1', ipAddress: '192.168.50.216', name: 'Hue Bridge' },
      mappings: 0,
      lights: 0,
      areas: 0,
      motionStyle: 'still',
      stopBehavior: 'turnOff',
    });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('config store drops stale Hue targets and light overrides', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-config-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({
      ...config,
      resources: {
        lights: [
          {
            id: 'study-lamp',
            name: '台灯',
            supportsColor: true,
            supportsGradient: false,
            supportsEntertainment: true,
            function: 'decorative',
            functionMetadataResolved: true,
          },
        ],
        areas: [
          {
            id: 'study-room',
            name: 'Study',
            kind: 'room',
            childLightIDs: ['study-lamp', 'old-lamp'],
            childDeviceIDs: ['study-device'],
          },
        ],
      },
      mappings: [
        {
          sonosID: 'study',
          sonosName: 'Study',
          preferredTarget: { kind: 'room', id: 'study-room' },
          fallbackTarget: { kind: 'zone', id: 'old-zone' },
          includedLightIDs: ['study-lamp', 'old-lamp'],
          excludedLightIDs: ['old-lamp'],
          capability: 'basic',
        },
        {
          sonosID: 'old',
          sonosName: 'Old Room',
          preferredTarget: { kind: 'room', id: 'old-room' },
          fallbackTarget: null,
          includedLightIDs: [],
          excludedLightIDs: [],
          capability: 'basic',
        },
      ],
    });

    assert.deepEqual(store.current?.resources.areas[0]?.childLightIDs, ['study-lamp']);
    assert.deepEqual(store.current?.mappings.map(mapping => mapping.sonosID), ['study']);
    assert.equal(store.current?.mappings[0]?.fallbackTarget, null);
    assert.deepEqual(store.current?.mappings[0]?.includedLightIDs, ['study-lamp']);
    assert.deepEqual(store.current?.mappings[0]?.excludedLightIDs, []);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('config store uses flow interval environment override', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-config-'));
  const previous = process.env.HUE_FLOW_INTERVAL_SECONDS;
  process.env.HUE_FLOW_INTERVAL_SECONDS = '4';
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({ ...config, flowIntervalSeconds: 8 });

    assert.equal(store.current?.flowIntervalSeconds, 4);
  } finally {
    if (previous === undefined) {
      delete process.env.HUE_FLOW_INTERVAL_SECONDS;
    } else {
      process.env.HUE_FLOW_INTERVAL_SECONDS = previous;
    }
    await rm(dir, { recursive: true, force: true });
  }
});
