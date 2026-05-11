import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
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

const runtimeConfig = (overrides: Partial<HueAmbienceRuntimeConfig>): HueAmbienceRuntimeConfig => ({
  ...config,
  ...overrides,
  resources: overrides.resources ?? config.resources,
  mappings: overrides.mappings ?? config.mappings,
});

const light = (
  overrides: Partial<HueAmbienceRuntimeConfig['resources']['lights'][number]> &
    Pick<HueAmbienceRuntimeConfig['resources']['lights'][number], 'id'>,
): HueAmbienceRuntimeConfig['resources']['lights'][number] => ({
  name: overrides.id,
  supportsColor: true,
  supportsGradient: false,
  supportsEntertainment: true,
  function: 'decorative',
  functionMetadataResolved: true,
  ...overrides,
});

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
      renderMode: null,
      activeTargetIds: [],
      entertainmentTargetActive: false,
      entertainmentMetadataComplete: false,
      lastFrameAt: null,
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

test('config store clears light overrides for entertainment mappings', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-config-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(runtimeConfig({
      resources: {
        lights: [
          light({ id: 'task-light', ownerID: 'device-1', function: 'functional' }),
        ],
        areas: [
          {
            id: 'ent-1',
            name: 'Playroom Area',
            kind: 'entertainmentArea',
            childLightIDs: ['task-light'],
            childDeviceIDs: ['device-1'],
          },
        ],
      },
      mappings: [
        {
          sonosID: 'playroom',
          sonosName: 'Playroom',
          relayGroupID: '192.168.50.25',
          preferredTarget: { kind: 'entertainmentArea', id: 'ent-1' },
          fallbackTarget: null,
          includedLightIDs: ['task-light'],
          excludedLightIDs: ['task-light'],
          capability: 'liveEntertainment',
        },
      ],
    }));

    assert.deepEqual(store.current?.mappings[0]?.includedLightIDs, []);
    assert.deepEqual(store.current?.mappings[0]?.excludedLightIDs, []);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('config store removes legacy direct light mappings', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-config-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(runtimeConfig({
      resources: {
        lights: [
          light({ id: 'light-1', ownerID: 'device-1' }),
        ],
        areas: [
          {
            id: 'room-1',
            name: 'Playroom',
            kind: 'room',
            childLightIDs: ['light-1'],
            childDeviceIDs: ['device-1'],
          },
        ],
      },
      mappings: [
        {
          sonosID: 'playroom',
          sonosName: 'Playroom',
          relayGroupID: '192.168.50.25',
          preferredTarget: { kind: 'light', id: 'light-1' },
          fallbackTarget: null,
          includedLightIDs: [],
          excludedLightIDs: [],
          capability: 'gradientReady',
        },
      ],
    }));

    assert.deepEqual(store.current?.mappings, []);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('config store preserves entertainment channel metadata for valid lights', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-config-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({
      ...config,
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
            id: 'ent-1',
            name: 'Entertainment',
            kind: 'entertainmentArea',
            childLightIDs: ['light-1'],
            entertainmentChannels: [
              {
                id: '0',
                lightID: 'light-1',
                serviceID: 'svc-1',
                position: { x: 0, y: 1, z: 0 },
              },
              {
                id: 'stale',
                lightID: 'old-light',
                serviceID: 'old-service',
              },
            ],
          },
        ],
      },
    });

    assert.deepEqual(store.current?.resources.areas[0]?.entertainmentChannels, [
      {
        id: '0',
        lightID: 'light-1',
        serviceID: 'svc-1',
        position: { x: 0, y: 1, z: 0 },
      },
    ]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('config store drops malformed entertainment channel ids while preserving backward-compatible shapes', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-config-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({
      ...config,
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
            id: 'ent-1',
            name: 'Entertainment',
            kind: 'entertainmentArea',
            childLightIDs: ['light-1'],
            entertainmentChannels: [
              { lightID: 'light-1', serviceID: 'missing-id' },
              { id: null, lightID: 'light-1', serviceID: 'null-id' },
              { id: { value: 'object-id' }, lightID: 'light-1', serviceID: 'object-id' },
              { id: '', lightID: 'light-1', serviceID: 'empty-id' },
              { id: 7, lightID: 'light-1', serviceID: 'numeric-id' },
              { id: 'no-light', serviceID: 'service-without-light' },
              { id: 'stale-light', lightID: 'old-light', serviceID: 'old-light-service' },
            ],
          },
        ],
      },
    } as unknown as HueAmbienceRuntimeConfig);

    assert.deepEqual(store.current?.resources.areas[0]?.entertainmentChannels, [
      {
        id: '7',
        lightID: 'light-1',
        serviceID: 'numeric-id',
        position: null,
      },
      {
        id: 'no-light',
        lightID: null,
        serviceID: 'service-without-light',
        position: null,
      },
    ]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('config store load treats malformed top-level array containers as empty arrays', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-config-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await writeFile(store.configPath, JSON.stringify({
      ...config,
      resources: { lights: {}, areas: {} },
      mappings: {},
    }), 'utf8');

    const loaded = await store.load();

    assert.deepEqual(loaded?.resources.lights, []);
    assert.deepEqual(loaded?.resources.areas, []);
    assert.deepEqual(loaded?.mappings, []);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('config store load treats malformed area child and channel containers as empty arrays', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-config-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await writeFile(store.configPath, JSON.stringify({
      ...config,
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
            id: 'ent-1',
            name: 'Entertainment',
            kind: 'entertainmentArea',
            childLightIDs: 'light-1',
            childDeviceIDs: { id: 'device-1' },
            entertainmentChannels: { id: '0', lightID: 'light-1' },
          },
        ],
      },
      mappings: [
        {
          sonosID: 'study',
          sonosName: 'Study',
          preferredTarget: { kind: 'entertainmentArea', id: 'ent-1' },
          fallbackTarget: null,
          includedLightIDs: 'light-1',
          excludedLightIDs: { id: 'old-light' },
          capability: 'basic',
        },
      ],
    }), 'utf8');

    const loaded = await store.load();

    assert.deepEqual(loaded?.resources.areas[0]?.childLightIDs, []);
    assert.deepEqual(loaded?.resources.areas[0]?.childDeviceIDs, []);
    assert.deepEqual(loaded?.resources.areas[0]?.entertainmentChannels, []);
    assert.deepEqual(loaded?.mappings[0]?.includedLightIDs, []);
    assert.deepEqual(loaded?.mappings[0]?.excludedLightIDs, []);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('config store load drops malformed array elements while preserving valid entries', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-config-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await writeFile(store.configPath, JSON.stringify({
      ...config,
      resources: {
        lights: [
          null,
          'bad',
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
          null,
          {
            id: 'ent-1',
            name: 'Entertainment',
            kind: 'entertainmentArea',
            childLightIDs: [null, 7, { id: 'bad' }, 'light-1', 'old-light'],
            childDeviceIDs: [null, 7, { id: 'bad' }, 'device-1'],
            entertainmentChannels: [
              null,
              'bad',
              {
                id: '0',
                lightID: 'light-1',
                serviceID: 'svc-1',
                position: { x: 0, y: 1, z: 0 },
              },
            ],
          },
        ],
      },
      mappings: [
        null,
        {
          sonosID: 'study',
          sonosName: 'Study',
          preferredTarget: { kind: 'entertainmentArea', id: 'ent-1' },
          fallbackTarget: null,
          includedLightIDs: [null, 7, { id: 'bad' }, 'light-1', 'old-light'],
          excludedLightIDs: [null, 7, { id: 'bad' }, 'old-light'],
          capability: 'liveEntertainment',
        },
      ],
    }), 'utf8');

    const loaded = await store.load();

    assert.deepEqual(loaded?.resources.lights.map(light => light.id), ['light-1']);
    assert.deepEqual(loaded?.resources.areas.map(area => area.id), ['ent-1']);
    assert.deepEqual(loaded?.resources.areas[0]?.childLightIDs, ['light-1']);
    assert.deepEqual(loaded?.resources.areas[0]?.childDeviceIDs, ['device-1']);
    assert.deepEqual(loaded?.resources.areas[0]?.entertainmentChannels, [
      {
        id: '0',
        lightID: 'light-1',
        serviceID: 'svc-1',
        position: { x: 0, y: 1, z: 0 },
      },
    ]);
    assert.deepEqual(loaded?.mappings.map(mapping => mapping.sonosID), ['study']);
    assert.deepEqual(loaded?.mappings[0]?.includedLightIDs, []);
    assert.deepEqual(loaded?.mappings[0]?.excludedLightIDs, []);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('config store status includes inactive renderer fields without secrets', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-config-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);

    const status = store.status();
    assert.equal((status as any).applicationKey, undefined);
    assert.equal(status.renderMode, null);
    assert.deepEqual(status.activeTargetIds, []);
    assert.equal(status.entertainmentTargetActive, false);
    assert.equal(status.entertainmentMetadataComplete, false);
    assert.equal(status.lastFrameAt, null);
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
