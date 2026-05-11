import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  buildHueLightBody,
  resolveHueTargets,
  shouldUseLightForAmbience,
} from './hueRenderer.js';
import type { HueAmbienceRuntimeConfig, HueLightResource } from './hueTypes.js';

const lights: HueLightResource[] = [
  {
    id: 'decor-gradient',
    name: 'Gradient Strip',
    supportsColor: true,
    supportsGradient: true,
    supportsEntertainment: true,
    function: 'decorative',
    functionMetadataResolved: true,
  },
  {
    id: 'task-lamp',
    name: 'Desk Lamp',
    supportsColor: true,
    supportsGradient: false,
    supportsEntertainment: true,
    function: 'functional',
    functionMetadataResolved: true,
  },
  {
    id: 'old-cache',
    name: 'Old Cached Light',
    supportsColor: true,
    supportsGradient: false,
    supportsEntertainment: true,
    function: 'unknown',
    functionMetadataResolved: false,
  },
];

const config: HueAmbienceRuntimeConfig = {
  enabled: true,
  bridge: { id: 'bridge-1', ipAddress: '192.168.50.216', name: 'Hue Bridge' },
  applicationKey: 'secret-key',
  resources: {
    lights,
    areas: [
      {
        id: 'ent-1',
        name: 'PC Entertainment Area',
        kind: 'entertainmentArea',
        childLightIDs: ['decor-gradient', 'task-lamp', 'old-cache'],
      },
    ],
  },
  mappings: [
    {
      sonosID: 'RINCON_playroom',
      sonosName: 'Playroom',
      relayGroupID: '192.168.50.25',
      preferredTarget: { kind: 'entertainmentArea', id: 'ent-1' },
      fallbackTarget: null,
      includedLightIDs: ['old-cache'],
      excludedLightIDs: ['task-lamp'],
      capability: 'liveEntertainment',
    },
  ],
  groupStrategy: 'allMappedRooms',
  stopBehavior: 'leaveCurrent',
  motionStyle: 'flowing',
  flowIntervalSeconds: 8,
};

const runtimeConfig = (overrides: Partial<HueAmbienceRuntimeConfig>): HueAmbienceRuntimeConfig => ({
  ...config,
  ...overrides,
  resources: overrides.resources ?? config.resources,
  mappings: overrides.mappings ?? config.mappings,
});

const light = (
  overrides: Partial<HueLightResource> & Pick<HueLightResource, 'id'>,
): HueLightResource => ({
  name: overrides.id,
  supportsColor: true,
  supportsGradient: false,
  supportsEntertainment: true,
  function: 'decorative',
  functionMetadataResolved: true,
  ...overrides,
});

const snapshot = () => ({
  groupId: '192.168.50.25',
  speakerName: 'Playroom',
  trackTitle: 'A',
  artist: 'B',
  album: 'C',
  isPlaying: true,
  positionSeconds: 1,
  durationSeconds: 120,
  groupMemberCount: 1,
  sampledAt: new Date('2026-05-11T00:00:00Z'),
});

test('light filtering excludes task lights and unresolved metadata unless explicitly included', () => {
  assert.equal(shouldUseLightForAmbience(lights[0]!, config.mappings[0]!), true);
  assert.equal(shouldUseLightForAmbience(lights[1]!, config.mappings[0]!), false);
  assert.equal(shouldUseLightForAmbience(lights[2]!, config.mappings[0]!), true);
});

test('target resolution matches relay group id and trusts entertainment area membership', () => {
  const targets = resolveHueTargets(config, {
    groupId: '192.168.50.25',
    speakerName: 'Playroom',
    trackTitle: 'A',
    artist: 'B',
    album: 'C',
    isPlaying: true,
    positionSeconds: 1,
    durationSeconds: 120,
    groupMemberCount: 1,
    sampledAt: new Date('2026-05-11T00:00:00Z'),
  });

  assert.deepEqual(targets.map(t => t.area.id), ['ent-1']);
  assert.deepEqual(targets[0]!.lights.map(l => l.id), ['decor-gradient', 'task-lamp', 'old-cache']);
});

test('target resolution supports direct light targets by id', () => {
  const directLightConfig: HueAmbienceRuntimeConfig = {
    ...config,
    resources: {
      lights: [
        {
          id: 'study-lamp',
          name: '台灯',
          ownerID: 'study-device',
          supportsColor: true,
          supportsGradient: false,
          supportsEntertainment: true,
          function: 'functional',
          functionMetadataResolved: true,
        },
        {
          id: 'bedroom-lamp',
          name: '台灯',
          ownerID: 'bedroom-device',
          supportsColor: true,
          supportsGradient: false,
          supportsEntertainment: true,
          function: 'decorative',
          functionMetadataResolved: true,
        },
      ],
      areas: [],
    },
    mappings: [
      {
        sonosID: 'study',
        sonosName: 'Study',
        relayGroupID: '192.168.50.25',
        preferredTarget: { kind: 'light', id: 'study-lamp' },
        fallbackTarget: null,
        includedLightIDs: [],
        excludedLightIDs: [],
        capability: 'basic',
      },
    ],
  };

  const targets = resolveHueTargets(directLightConfig, {
    groupId: '192.168.50.25',
    speakerName: 'Study',
    trackTitle: 'A',
    artist: 'B',
    album: 'C',
    isPlaying: true,
    positionSeconds: 1,
    durationSeconds: 120,
    groupMemberCount: 1,
    sampledAt: new Date('2026-05-11T00:00:00Z'),
  });

  assert.deepEqual(targets.map(t => t.area.id), ['study-lamp']);
  assert.deepEqual(targets[0]!.lights.map(l => l.id), ['study-lamp']);
});

test('target resolution scopes duplicate named lights to area devices', () => {
  const duplicateNameConfig: HueAmbienceRuntimeConfig = {
    ...config,
    resources: {
      lights: [
        {
          id: 'study-lamp',
          name: '台灯',
          ownerID: 'study-device',
          supportsColor: true,
          supportsGradient: false,
          supportsEntertainment: true,
          function: 'decorative',
          functionMetadataResolved: true,
        },
        {
          id: 'bedroom-lamp',
          name: '台灯',
          ownerID: 'bedroom-device',
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
          name: 'Study',
          kind: 'room',
          childLightIDs: ['study-lamp', 'bedroom-lamp'],
          childDeviceIDs: ['study-device'],
        },
      ],
    },
    mappings: [
      {
        sonosID: 'study',
        sonosName: 'Study',
        relayGroupID: '192.168.50.25',
        preferredTarget: { kind: 'room', id: 'room-1' },
        fallbackTarget: null,
        includedLightIDs: [],
        excludedLightIDs: [],
        capability: 'basic',
      },
    ],
  };

  const targets = resolveHueTargets(duplicateNameConfig, {
    groupId: '192.168.50.25',
    speakerName: 'Study',
    trackTitle: 'A',
    artist: 'B',
    album: 'C',
    isPlaying: true,
    positionSeconds: 1,
    durationSeconds: 120,
    groupMemberCount: 1,
    sampledAt: new Date('2026-05-11T00:00:00Z'),
  });

  assert.deepEqual(targets[0]!.lights.map(l => l.id), ['study-lamp']);
});

test('target resolution does not fallback to duplicate decorative lights when area ownership is unknown', () => {
  const duplicateNameConfig: HueAmbienceRuntimeConfig = {
    ...config,
    resources: {
      lights: [
        {
          id: 'study-lamp',
          name: '台灯',
          ownerID: 'study-device',
          supportsColor: true,
          supportsGradient: false,
          supportsEntertainment: true,
          function: 'functional',
          functionMetadataResolved: true,
        },
        {
          id: 'bedroom-lamp',
          name: '台灯',
          ownerID: 'bedroom-device',
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
          name: 'Study',
          kind: 'room',
          childLightIDs: ['study-lamp', 'bedroom-lamp'],
          childDeviceIDs: [],
        },
      ],
    },
    mappings: [
      {
        sonosID: 'study',
        sonosName: 'Study',
        relayGroupID: '192.168.50.25',
        preferredTarget: { kind: 'room', id: 'room-1' },
        fallbackTarget: null,
        includedLightIDs: [],
        excludedLightIDs: [],
        capability: 'basic',
      },
    ],
  };

  const targets = resolveHueTargets(duplicateNameConfig, {
    groupId: '192.168.50.25',
    speakerName: 'Study',
    trackTitle: 'A',
    artist: 'B',
    album: 'C',
    isPlaying: true,
    positionSeconds: 1,
    durationSeconds: 120,
    groupMemberCount: 1,
    sampledAt: new Date('2026-05-11T00:00:00Z'),
  });

  assert.deepEqual(targets, []);
});

test('target resolution uses only explicit lights when area ownership is unknown', () => {
  const duplicateNameConfig: HueAmbienceRuntimeConfig = {
    ...config,
    resources: {
      lights: [
        {
          id: 'study-lamp',
          name: '台灯',
          ownerID: 'study-device',
          supportsColor: true,
          supportsGradient: false,
          supportsEntertainment: true,
          function: 'functional',
          functionMetadataResolved: true,
        },
        {
          id: 'bedroom-lamp',
          name: '台灯',
          ownerID: 'bedroom-device',
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
          name: 'Study',
          kind: 'room',
          childLightIDs: ['study-lamp', 'bedroom-lamp'],
          childDeviceIDs: [],
        },
      ],
    },
    mappings: [
      {
        sonosID: 'study',
        sonosName: 'Study',
        relayGroupID: '192.168.50.25',
        preferredTarget: { kind: 'room', id: 'room-1' },
        fallbackTarget: null,
        includedLightIDs: ['study-lamp'],
        excludedLightIDs: [],
        capability: 'basic',
      },
    ],
  };

  const targets = resolveHueTargets(duplicateNameConfig, {
    groupId: '192.168.50.25',
    speakerName: 'Study',
    trackTitle: 'A',
    artist: 'B',
    album: 'C',
    isPlaying: true,
    positionSeconds: 1,
    durationSeconds: 120,
    groupMemberCount: 1,
    sampledAt: new Date('2026-05-11T00:00:00Z'),
  });

  assert.deepEqual(targets[0]!.lights.map(l => l.id), ['study-lamp']);
});

test('entertainment area resolution includes functional lights and ignores manual overrides', () => {
  const config = runtimeConfig({
    resources: {
      lights: [
        light({ id: 'decorative', ownerID: 'device-decorative', function: 'decorative' }),
        light({ id: 'task', ownerID: 'device-task', function: 'functional' }),
        light({ id: 'other-area-light', ownerID: 'device-other', function: 'decorative' }),
      ],
      areas: [
        {
          id: 'ent-1',
          name: 'Playroom Area',
          kind: 'entertainmentArea',
          childLightIDs: ['decorative', 'task'],
          childDeviceIDs: ['device-decorative'],
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
        includedLightIDs: ['other-area-light'],
        excludedLightIDs: ['decorative'],
        capability: 'liveEntertainment',
      },
    ],
  });

  const targets = resolveHueTargets(config, snapshot());

  assert.deepEqual(targets.map(target => target.lights.map(light => light.id)), [['decorative', 'task']]);
});

test('room resolution keeps functional filtering and manual overrides', () => {
  const baseConfig = runtimeConfig({
    resources: {
      lights: [
        light({ id: 'decorative', ownerID: 'device-decorative', function: 'decorative' }),
        light({ id: 'task', ownerID: 'device-task', function: 'functional' }),
      ],
      areas: [
        {
          id: 'room-1',
          name: 'Playroom',
          kind: 'room',
          childLightIDs: ['decorative', 'task'],
          childDeviceIDs: ['device-decorative', 'device-task'],
        },
      ],
    },
    mappings: [
      {
        sonosID: 'playroom',
        sonosName: 'Playroom',
        relayGroupID: '192.168.50.25',
        preferredTarget: { kind: 'room', id: 'room-1' },
        fallbackTarget: null,
        includedLightIDs: [],
        excludedLightIDs: [],
        capability: 'gradientReady',
      },
    ],
  });

  assert.deepEqual(resolveHueTargets(baseConfig, snapshot())[0]!.lights.map(light => light.id), ['decorative']);

  const manualConfig = {
    ...baseConfig,
    mappings: [
      {
        ...baseConfig.mappings[0]!,
        includedLightIDs: ['task'],
        excludedLightIDs: ['decorative'],
      },
    ],
  };

  assert.deepEqual(resolveHueTargets(manualConfig, snapshot())[0]!.lights.map(light => light.id), ['task']);
});

test('gradient lights receive multi-point palette bodies while basic lights receive one xy color', () => {
  const palette = [
    { r: 1, g: 0.1, b: 0.1 },
    { r: 0.1, g: 0.7, b: 1 },
    { r: 0.8, g: 0.2, b: 0.9 },
  ];

  const gradientBody = buildHueLightBody(lights[0]!, palette, 8);
  assert.equal(gradientBody.gradient?.points.length, 3);
  assert.equal(gradientBody.dynamics.duration, 8000);

  const basicBody = buildHueLightBody({ ...lights[0]!, supportsGradient: false }, palette, 4);
  assert.equal(basicBody.gradient, undefined);
  assert.ok(basicBody.color?.xy.x);
  assert.equal(basicBody.dynamics.duration, 4000);
});
