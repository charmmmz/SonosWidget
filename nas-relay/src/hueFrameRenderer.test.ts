import assert from 'node:assert/strict';
import { test } from 'node:test';

import type { HueAmbienceFrame } from './hueAmbienceFrames.js';
import { ClipHueAmbienceRenderer } from './hueFrameRenderer.js';
import type { HueLightUpdateBody } from './hueRenderer.js';
import type { HueAreaResource, HueLightClient, HueLightResource } from './hueTypes.js';

const area: HueAreaResource = {
  id: 'room-1',
  name: 'Playroom',
  kind: 'room',
  childLightIDs: ['gradient-strip', 'desk-lamp'],
};

const gradientLight: HueLightResource = {
  id: 'gradient-strip',
  name: 'Gradient Strip',
  supportsColor: true,
  supportsGradient: true,
  supportsEntertainment: true,
  function: 'decorative',
  functionMetadataResolved: true,
};

const basicLight: HueLightResource = {
  id: 'desk-lamp',
  name: 'Desk Lamp',
  supportsColor: true,
  supportsGradient: false,
  supportsEntertainment: true,
  function: 'decorative',
  functionMetadataResolved: true,
};

test('CLIP frame renderer applies per-light frame colors', async () => {
  const client = new RecordingHueLightClient();
  const renderer = new ClipHueAmbienceRenderer(client);
  const frame = frameWithLights();

  await renderer.render(frame);

  assert.equal(client.updates.length, 2);
  assert.equal(client.updates[0]!.id, 'gradient-strip');
  assert.equal(client.updates[0]!.body.gradient?.points.length, 2);
  assert.equal(client.updates[0]!.body.dynamics.duration, 3200);
  assert.equal(client.updates[1]!.id, 'desk-lamp');
  assert.equal(client.updates[1]!.body.gradient, undefined);
  assert.ok(client.updates[1]!.body.color);
  assert.equal(client.updates[1]!.body.dynamics.duration, 3200);
});

test('CLIP frame renderer can turn off frame lights', async () => {
  const client = new RecordingHueLightClient();
  const renderer = new ClipHueAmbienceRenderer(client);

  await renderer.stop(frameWithLights());

  assert.deepEqual(client.updates, [
    {
      id: 'gradient-strip',
      body: { on: { on: false }, dynamics: { duration: 1200 } },
    },
    {
      id: 'desk-lamp',
      body: { on: { on: false }, dynamics: { duration: 1200 } },
    },
  ]);
});

function frameWithLights(): HueAmbienceFrame {
  return {
    mode: 'clipFallback',
    targets: [
      {
        area,
        metadataComplete: false,
        lights: [
          {
            light: gradientLight,
            colors: [
              { r: 1, g: 0.2, b: 0.1 },
              { r: 0.1, g: 0.6, b: 1 },
            ],
          },
          {
            light: basicLight,
            colors: [{ r: 0.9, g: 0.7, b: 0.1 }],
          },
        ],
      },
    ],
    transitionSeconds: 3.2,
    reason: 'steady',
    createdAt: new Date('2026-05-12T02:30:00Z'),
    metadataComplete: false,
    phase: 0,
    progressOffset: 0,
  };
}

class RecordingHueLightClient implements HueLightClient {
  readonly updates: Array<{ id: string; body: HueLightUpdateBody }> = [];

  async updateLight(id: string, body: unknown): Promise<void> {
    this.updates.push({ id, body: body as HueLightUpdateBody });
  }
}
