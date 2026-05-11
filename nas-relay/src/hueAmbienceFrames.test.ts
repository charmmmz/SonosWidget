import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  buildHueAmbienceFrame,
  entertainmentMetadataComplete,
} from './hueAmbienceFrames.js';
import type {
  HueAreaResource,
  HueRGBColor,
  HueResolvedAmbienceTarget,
  HueSnapshot,
} from './hueTypes.js';

const palette: HueRGBColor[] = [
  { r: 1, g: 0, b: 0 },
  { r: 0, g: 1, b: 0 },
  { r: 0, g: 0, b: 1 },
];
const now = new Date('2026-05-12T02:30:00Z');

function target(area: Partial<HueAreaResource> = {}): HueResolvedAmbienceTarget {
  return {
    area: {
      id: 'ent-1',
      name: 'PC Entertainment Area',
      kind: 'entertainmentArea',
      childLightIDs: ['gradient-strip', 'desk-lamp'],
      entertainmentChannels: [
        { id: 'channel-gradient', lightID: 'gradient-strip' },
        { id: 'channel-desk', lightID: 'desk-lamp' },
      ],
      ...area,
    },
    mapping: {
      sonosID: 'playroom',
      sonosName: 'Playroom',
      relayGroupID: '192.168.50.25',
      preferredTarget: { kind: 'entertainmentArea', id: 'ent-1' },
      fallbackTarget: null,
      includedLightIDs: [],
      excludedLightIDs: [],
      capability: 'liveEntertainment',
    },
    lights: [
      {
        id: 'gradient-strip',
        name: 'Gradient Strip',
        supportsColor: true,
        supportsGradient: true,
        supportsEntertainment: true,
        function: 'decorative',
        functionMetadataResolved: true,
      },
      {
        id: 'desk-lamp',
        name: 'Desk Lamp',
        supportsColor: true,
        supportsGradient: false,
        supportsEntertainment: true,
        function: 'decorative',
        functionMetadataResolved: true,
      },
    ],
  };
}

function roomTarget(): HueResolvedAmbienceTarget {
  return target({
    id: 'room-1',
    name: 'Playroom',
    kind: 'room',
    childLightIDs: ['gradient-strip', 'desk-lamp'],
    entertainmentChannels: undefined,
  });
}

function snapshot(overrides: Partial<HueSnapshot> = {}): HueSnapshot {
  return {
    groupId: '192.168.50.25',
    speakerName: 'Playroom',
    trackTitle: 'Spiral',
    artist: 'Vangelis',
    album: 'Direct',
    isPlaying: true,
    positionSeconds: 0,
    durationSeconds: 180,
    groupMemberCount: 1,
    sampledAt: new Date('2026-05-12T00:00:00Z'),
    ...overrides,
  };
}

test('frame engine distributes a 3-color album palette across two entertainment lights', () => {
  const frame = buildHueAmbienceFrame({
    targets: [target()],
    snapshot: snapshot(),
    palette,
    reason: 'steady',
    phase: 0,
    transitionSeconds: 4,
    now,
  });

  assert.equal(frame.mode, 'streamingReady');
  assert.equal(frame.transitionSeconds, 4);
  assert.equal(frame.createdAt, now);
  assert.equal(frame.metadataComplete, true);
  assert.equal(frame.targets[0]!.area.id, 'ent-1');
  assert.deepEqual(frame.targets[0]!.lights.map(light => light.light.id), [
    'gradient-strip',
    'desk-lamp',
  ]);
  assert.deepEqual(frame.targets[0]!.lights.map(light => light.colors[0]), [
    palette[0],
    palette[1],
  ]);
  assert.deepEqual(frame.targets[0]!.lights.map(light => light.channelID), [
    'channel-gradient',
    'channel-desk',
  ]);
});

test('frame engine uses entertainment channel position for spatial palette ordering', () => {
  const frame = buildHueAmbienceFrame({
    targets: [
      {
        ...target({
          entertainmentChannels: [
            { id: 'channel-gradient', lightID: 'gradient-strip', position: { x: 1, y: 0, z: 0 } },
            { id: 'channel-desk', lightID: 'desk-lamp', position: { x: 0, y: 0, z: 0 } },
          ],
        }),
      },
    ],
    snapshot: snapshot(),
    palette,
    reason: 'steady',
    phase: 0,
    transitionSeconds: 4,
    now,
  });

  assert.deepEqual(frame.targets[0]!.lights.map(light => light.light.id), [
    'gradient-strip',
    'desk-lamp',
  ]);
  assert.deepEqual(frame.targets[0]!.lights.map(light => light.colors[0]), [
    palette[1],
    palette[0],
  ]);
});

test('frame engine advances palette phase from playback progress', () => {
  const frame = buildHueAmbienceFrame({
    targets: [target()],
    snapshot: snapshot({ positionSeconds: 120, durationSeconds: 180 }),
    palette,
    reason: 'steady',
    phase: 0,
    transitionSeconds: 4,
    now,
  });

  assert.deepEqual(frame.targets[0]!.lights.map(light => light.colors[0]), [
    palette[2],
    palette[0],
  ]);
});

test('frame engine keeps multiple colors for gradients and one color for basic lights', () => {
  const frame = buildHueAmbienceFrame({
    targets: [target()],
    snapshot: snapshot(),
    palette,
    reason: 'steady',
    phase: 0,
    transitionSeconds: 4,
    now,
  });

  assert.equal(frame.targets[0]!.lights[0]!.light.supportsGradient, true);
  assert.equal(frame.targets[0]!.lights[1]!.light.supportsGradient, false);
  assert.deepEqual(frame.targets[0]!.lights[0]!.colors, palette);
  assert.deepEqual(frame.targets[0]!.lights[1]!.colors, [palette[1]]);
});

test('frame engine metadata ignores non-entertainment targets when entertainment targets are complete', () => {
  const frame = buildHueAmbienceFrame({
    targets: [target(), roomTarget()],
    snapshot: snapshot(),
    palette,
    reason: 'steady',
    phase: 0,
    transitionSeconds: 4,
    now,
  });

  assert.equal(frame.mode, 'streamingReady');
  assert.equal(frame.metadataComplete, true);
});

test('frame engine metadata is false when no entertainment targets are present', () => {
  const frame = buildHueAmbienceFrame({
    targets: [roomTarget()],
    snapshot: snapshot(),
    palette,
    reason: 'steady',
    phase: 0,
    transitionSeconds: 4,
    now,
  });

  assert.equal(frame.mode, 'clipFallback');
  assert.equal(frame.metadataComplete, false);
});

test('frame engine falls back to white when palette is empty', () => {
  const frame = buildHueAmbienceFrame({
    targets: [target()],
    snapshot: snapshot(),
    palette: [],
    reason: 'steady',
    phase: 0,
    transitionSeconds: 4,
    now,
  });

  assert.deepEqual(frame.targets[0]!.lights[0]!.colors, [{ r: 1, g: 1, b: 1 }]);
  assert.deepEqual(frame.targets[0]!.lights[1]!.colors, [{ r: 1, g: 1, b: 1 }]);
});

test('frame engine normalizes exact track-end progress offset inside palette range', () => {
  const frame = buildHueAmbienceFrame({
    targets: [target()],
    snapshot: snapshot({ positionSeconds: 180, durationSeconds: 180 }),
    palette,
    reason: 'steady',
    phase: 0,
    transitionSeconds: 4,
    now,
  });

  assert.equal(frame.progressOffset, 0);
  assert.deepEqual(frame.targets[0]!.lights.map(light => light.colors[0]), [
    palette[0],
    palette[1],
  ]);
});

test('entertainment metadata requires complete channel metadata for entertainment targets only', () => {
  assert.equal(entertainmentMetadataComplete(target().area), true);
  assert.equal(entertainmentMetadataComplete(target({
    entertainmentChannels: [{ id: 'channel-gradient', lightID: 'gradient-strip' }],
  }).area), false);
  assert.equal(entertainmentMetadataComplete(target({ kind: 'room' }).area), false);
});
