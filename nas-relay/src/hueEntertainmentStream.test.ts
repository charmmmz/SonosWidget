import assert from 'node:assert/strict';
import { test } from 'node:test';

import { buildHueAmbienceFrame, type HueAmbienceFrame } from './hueAmbienceFrames.js';
import {
  HueEntertainmentStreamSession,
  HueEntertainmentStreamingRenderer,
  buildHueEntertainmentPacket,
  type HueEntertainmentControlClient,
  type HueEntertainmentDtlsSocket,
  type HueEntertainmentDtlsSocketFactory,
} from './hueEntertainmentStream.js';
import type { HueAmbienceRenderer } from './hueFrameRenderer.js';
import type { HueAmbienceRuntimeConfig, HueResolvedAmbienceTarget } from './hueTypes.js';

test('Hue Entertainment packet serializes V2 RGB frames with area id and channel ids', () => {
  const packet = buildHueEntertainmentPacket(frame(), 7);

  assert.equal(packet.subarray(0, 9).toString('ascii'), 'HueStream');
  assert.deepEqual([...packet.subarray(9, 16)], [0x02, 0x00, 7, 0x00, 0x00, 0x00, 0x00]);
  assert.equal(packet.subarray(16, 52).toString('ascii'), '01234567-89ab-cdef-0123-456789abcdef');
  assert.deepEqual([...packet.subarray(52)], [
    0x00,
    0xff, 0xff,
    0x80, 0x00,
    0x00, 0x00,
  ]);
});

test('Hue Entertainment packet rejects frames without numeric channel ids', () => {
  assert.throws(
    () => buildHueEntertainmentPacket(frame({ channelID: 'not-a-channel' }), 1),
    /numeric entertainment channel id/,
  );
});

test('Hue Entertainment stream session starts the bridge session before sending DTLS packets', async () => {
  const control = new RecordingEntertainmentControlClient();
  const socketFactory = new RecordingDtlsSocketFactory();
  const session = new HueEntertainmentStreamSession(config(), control, socketFactory.create);

  await session.render(frame(), new Date('2026-05-12T09:45:00Z'));

  assert.deepEqual(control.actions, [
    { areaID: '01234567-89ab-cdef-0123-456789abcdef', active: true },
  ]);
  assert.equal(socketFactory.sockets.length, 1);
  assert.deepEqual(socketFactory.options[0], {
    host: '192.168.50.216',
    identity: 'streaming-app-id',
    psk: '00112233445566778899aabbccddeeff',
  });
  assert.equal(socketFactory.sockets[0]?.connected, true);
  assert.equal(socketFactory.sockets[0]?.packets.length, 1);
  assert.equal(socketFactory.sockets[0]?.packets[0]?.subarray(0, 9).toString('ascii'), 'HueStream');
});

test('Hue Entertainment stream session reconnects once when the DTLS socket was closed', async () => {
  const control = new RecordingEntertainmentControlClient();
  const socketFactory = new RecordingDtlsSocketFactory();
  const session = new HueEntertainmentStreamSession(config(), control, socketFactory.create);

  await session.render(frame(), new Date('2026-05-12T09:45:00Z'));
  socketFactory.sockets[0]!.sendError = new Error('The socket is closed. Cannot send data.');

  await session.render(frame(), new Date('2026-05-12T09:45:01Z'));

  assert.deepEqual(control.actions, [
    { areaID: '01234567-89ab-cdef-0123-456789abcdef', active: true },
    { areaID: '01234567-89ab-cdef-0123-456789abcdef', active: true },
  ]);
  assert.equal(socketFactory.sockets.length, 2);
  assert.equal(socketFactory.sockets[0]?.closed, true);
  assert.equal(socketFactory.sockets[1]?.connected, true);
  assert.equal(socketFactory.sockets[0]?.packets.length, 1);
  assert.equal(socketFactory.sockets[1]?.packets.length, 1);
});

test('Hue Entertainment streaming renderer falls back to CLIP when client key is missing', async () => {
  const fallback = new RecordingRenderer();
  const renderer = new HueEntertainmentStreamingRenderer(
    { ...config(), streamingClientKey: null },
    new RecordingEntertainmentControlClient(),
    new RecordingDtlsSocketFactory().create,
    fallback,
  );

  const result = await renderer.render(frame());

  assert.deepEqual(result, { transport: 'clipFallback' });
  assert.equal(fallback.rendered.length, 1);
});

test('Hue Entertainment streaming renderer falls back to CLIP when application id is missing', async () => {
  const fallback = new RecordingRenderer();
  const renderer = new HueEntertainmentStreamingRenderer(
    { ...config(), streamingApplicationId: null },
    new RecordingEntertainmentControlClient(),
    new RecordingDtlsSocketFactory().create,
    fallback,
  );

  const result = await renderer.render(frame());

  assert.deepEqual(result, { transport: 'clipFallback' });
  assert.equal(fallback.rendered.length, 1);
});

test('Hue Entertainment streaming renderer can require streaming without CLIP fallback', async () => {
  const fallback = new RecordingRenderer();
  const renderer = new HueEntertainmentStreamingRenderer(
    { ...config(), streamingClientKey: null },
    new RecordingEntertainmentControlClient(),
    new RecordingDtlsSocketFactory().create,
    fallback,
    { allowClipFallback: false },
  );

  await assert.rejects(
    () => renderer.render(frame()),
    /streaming.*required/i,
  );
  assert.equal(fallback.rendered.length, 0);
});

function frame(overrides: { channelID?: string | null } = {}): HueAmbienceFrame {
  return buildHueAmbienceFrame({
    targets: [target(overrides)],
    snapshot: {
      groupId: 'cs2',
      speakerName: 'CS2',
      trackTitle: 'flash',
      artist: 'Counter-Strike 2',
      album: 'competitive',
      albumArtUri: '',
      isPlaying: true,
      positionSeconds: 0,
      durationSeconds: 0,
      groupMemberCount: 1,
      sampledAt: new Date('2026-05-12T09:45:00Z'),
    },
    palette: [{ r: 1, g: 0.5, b: 0 }],
    reason: 'steady',
    phase: 0,
    transitionSeconds: 0.05,
    now: new Date('2026-05-12T09:45:00Z'),
  });
}

function target(overrides: { channelID?: string | null } = {}): HueResolvedAmbienceTarget {
  return {
    area: {
      id: '01234567-89ab-cdef-0123-456789abcdef',
      name: 'PC Area',
      kind: 'entertainmentArea',
      childLightIDs: ['light-1'],
      entertainmentChannels: [{
        id: overrides.channelID ?? '0',
        lightID: 'light-1',
        serviceID: 'svc-1',
      }],
    },
    mapping: {
      sonosID: 'office',
      sonosName: 'Office',
      relayGroupID: '192.168.50.25',
      preferredTarget: { kind: 'entertainmentArea', id: '01234567-89ab-cdef-0123-456789abcdef' },
      fallbackTarget: null,
      includedLightIDs: [],
      excludedLightIDs: [],
      capability: 'liveEntertainment',
    },
    lights: [{
      id: 'light-1',
      name: 'Gradient Strip',
      supportsColor: true,
      supportsGradient: true,
      supportsEntertainment: true,
      function: 'decorative',
      functionMetadataResolved: true,
    }],
  };
}

function config(): HueAmbienceRuntimeConfig {
  return {
    enabled: true,
    cs2LightingEnabled: true,
    bridge: { id: 'bridge-1', ipAddress: '192.168.50.216', name: 'Hue Bridge' },
    applicationKey: 'app-key',
    streamingClientKey: '00112233445566778899aabbccddeeff',
    streamingApplicationId: 'streaming-app-id',
    resources: {
      lights: target().lights,
      areas: [target().area],
    },
    mappings: [target().mapping],
    groupStrategy: 'coordinatorOnly',
    stopBehavior: 'leaveCurrent',
    motionStyle: 'still',
    flowIntervalSeconds: 8,
  };
}

class RecordingEntertainmentControlClient implements HueEntertainmentControlClient {
  readonly actions: Array<{ areaID: string; active: boolean }> = [];

  async setEntertainmentStreaming(areaID: string, active: boolean): Promise<void> {
    this.actions.push({ areaID, active });
  }
}

class RecordingDtlsSocketFactory {
  readonly sockets: RecordingDtlsSocket[] = [];
  readonly options: Array<{ host: string; identity: string; psk: string }> = [];

  readonly create: HueEntertainmentDtlsSocketFactory = options => {
    this.options.push(options);
    const socket = new RecordingDtlsSocket();
    this.sockets.push(socket);
    return socket;
  };
}

class RecordingDtlsSocket implements HueEntertainmentDtlsSocket {
  connected = false;
  closed = false;
  sendError: Error | null = null;
  readonly packets: Buffer[] = [];

  async connect(): Promise<void> {
    this.connected = true;
  }

  async send(packet: Buffer): Promise<void> {
    if (this.sendError) {
      const err = this.sendError;
      this.sendError = null;
      throw err;
    }
    this.packets.push(packet);
  }

  async close(): Promise<void> {
    this.closed = true;
  }
}

class RecordingRenderer implements HueAmbienceRenderer {
  readonly rendered: HueAmbienceFrame[] = [];
  readonly stopped: HueAmbienceFrame[] = [];

  async render(frame: HueAmbienceFrame): Promise<{ transport: 'clipFallback' }> {
    this.rendered.push(frame);
    return { transport: 'clipFallback' };
  }

  async stop(frame: HueAmbienceFrame): Promise<void> {
    this.stopped.push(frame);
  }
}
