import { dtls } from 'node-dtls-client';

import type { HueAmbienceFrame, HueAmbienceTargetFrame } from './hueAmbienceFrames.js';
import { ClipHueAmbienceRenderer, type HueAmbienceRenderResult, type HueAmbienceRenderer } from './hueFrameRenderer.js';
import type { HueAmbienceRuntimeConfig, HueLightClient } from './hueTypes.js';

const HUE_STREAM_HEADER = Buffer.from('HueStream', 'ascii');
const HUE_ENTERTAINMENT_VERSION = [0x02, 0x00] as const;
const HUE_ENTERTAINMENT_PORT = 2100;
const HUE_ENTERTAINMENT_CHANNEL_LIMIT = 20;
const HUE_ENTERTAINMENT_AREA_ID_BYTES = 36;

export interface HueEntertainmentControlClient {
  setEntertainmentStreaming(areaID: string, active: boolean): Promise<void>;
}

export interface HueEntertainmentDtlsSocket {
  connect(): Promise<void>;
  send(packet: Buffer): Promise<void>;
  close(): Promise<void>;
}

export interface HueEntertainmentDtlsSocketOptions {
  host: string;
  identity: string;
  psk: string;
}

export type HueEntertainmentDtlsSocketFactory = (
  options: HueEntertainmentDtlsSocketOptions,
) => HueEntertainmentDtlsSocket;

export class HueEntertainmentStreamSession {
  private socket: HueEntertainmentDtlsSocket | null = null;
  private activeAreaID: string | null = null;
  private sequence = 0;

  constructor(
    private readonly config: HueAmbienceRuntimeConfig,
    private readonly controlClient: HueEntertainmentControlClient,
    private readonly socketFactory: HueEntertainmentDtlsSocketFactory = options =>
      new NodeHueEntertainmentDtlsSocket(options),
  ) {}

  async render(frame: HueAmbienceFrame, now: Date = new Date()): Promise<void> {
    const target = entertainmentTargetForStreaming(frame);
    await this.ensureStarted(target.area.id);

    const packet = buildHueEntertainmentPacket(
      {
        ...frame,
        createdAt: now,
      },
      this.sequence,
    );
    this.sequence = (this.sequence + 1) & 0xff;
    await this.socket?.send(packet);
  }

  async stop(): Promise<void> {
    const socket = this.socket;
    const activeAreaID = this.activeAreaID;

    this.socket = null;
    this.activeAreaID = null;

    await socket?.close();
    if (activeAreaID) {
      await this.controlClient.setEntertainmentStreaming(activeAreaID, false);
    }
  }

  private async ensureStarted(areaID: string): Promise<void> {
    if (this.socket && this.activeAreaID === areaID) return;

    if (this.activeAreaID && this.activeAreaID !== areaID) {
      await this.stop();
    }

    const clientKey = this.config.streamingClientKey;
    const applicationId = this.config.streamingApplicationId;
    if (!clientKey || !applicationId) {
      throw new Error('missing Hue Entertainment streaming credentials');
    }

    await this.controlClient.setEntertainmentStreaming(areaID, true);
    const socket = this.socketFactory({
      host: this.config.bridge.ipAddress,
      identity: applicationId,
      psk: clientKey,
    });

    try {
      await socket.connect();
      this.socket = socket;
      this.activeAreaID = areaID;
      this.sequence = 0;
    } catch (err) {
      await socket.close().catch(() => {});
      await this.controlClient.setEntertainmentStreaming(areaID, false).catch(() => {});
      throw err;
    }
  }
}

export class HueEntertainmentStreamingRenderer implements HueAmbienceRenderer {
  private readonly session: HueEntertainmentStreamSession;

  constructor(
    private readonly config: HueAmbienceRuntimeConfig,
    controlClient: HueEntertainmentControlClient,
    socketFactory: HueEntertainmentDtlsSocketFactory,
    private readonly fallbackRenderer: HueAmbienceRenderer,
  ) {
    this.session = new HueEntertainmentStreamSession(config, controlClient, socketFactory);
  }

  async render(frame: HueAmbienceFrame): Promise<HueAmbienceRenderResult> {
    if (!canStreamFrame(this.config, frame)) {
      return await this.fallbackRenderer.render(frame);
    }

    try {
      await this.session.render(frame, frame.createdAt);
      return { transport: 'entertainmentStreaming' };
    } catch {
      await this.session.stop().catch(() => {});
      return await this.fallbackRenderer.render(frame);
    }
  }

  async stop(frame: HueAmbienceFrame): Promise<void> {
    await this.session.stop();
    await this.fallbackRenderer.stop(frame);
  }

  async release(): Promise<void> {
    await this.session.stop();
  }
}

export function createHueEntertainmentStreamingRenderer(
  config: HueAmbienceRuntimeConfig,
  lightClient: HueLightClient & HueEntertainmentControlClient,
  socketFactory?: HueEntertainmentDtlsSocketFactory,
): HueAmbienceRenderer {
  return new HueEntertainmentStreamingRenderer(
    config,
    lightClient,
    socketFactory ?? (options => new NodeHueEntertainmentDtlsSocket(options)),
    new ClipHueAmbienceRenderer(lightClient),
  );
}

export function buildHueEntertainmentPacket(frame: HueAmbienceFrame, sequence: number): Buffer {
  const target = entertainmentTargetForStreaming(frame);
  const areaID = Buffer.from(target.area.id, 'ascii');
  if (areaID.byteLength !== HUE_ENTERTAINMENT_AREA_ID_BYTES) {
    throw new Error('Hue Entertainment area id must be a 36-byte UUID string');
  }

  const channelFrames = target.lights.slice(0, HUE_ENTERTAINMENT_CHANNEL_LIMIT).map(lightFrame => {
    const channelID = numericChannelID(lightFrame.channelID);
    const color = lightFrame.colors[0] ?? { r: 0, g: 0, b: 0 };
    return {
      channelID,
      r: hueColorWord(color.r),
      g: hueColorWord(color.g),
      b: hueColorWord(color.b),
    };
  });

  const packet = Buffer.alloc(16 + HUE_ENTERTAINMENT_AREA_ID_BYTES + (channelFrames.length * 7));
  let offset = 0;
  HUE_STREAM_HEADER.copy(packet, offset);
  offset += HUE_STREAM_HEADER.length;
  packet[offset++] = HUE_ENTERTAINMENT_VERSION[0];
  packet[offset++] = HUE_ENTERTAINMENT_VERSION[1];
  packet[offset++] = sequence & 0xff;
  packet[offset++] = 0x00;
  packet[offset++] = 0x00;
  packet[offset++] = 0x00;
  packet[offset++] = 0x00;
  areaID.copy(packet, offset);
  offset += HUE_ENTERTAINMENT_AREA_ID_BYTES;

  for (const channelFrame of channelFrames) {
    packet[offset++] = channelFrame.channelID;
    packet[offset++] = channelFrame.r[0];
    packet[offset++] = channelFrame.r[1];
    packet[offset++] = channelFrame.g[0];
    packet[offset++] = channelFrame.g[1];
    packet[offset++] = channelFrame.b[0];
    packet[offset++] = channelFrame.b[1];
  }

  return packet;
}

function canStreamFrame(config: HueAmbienceRuntimeConfig, frame: HueAmbienceFrame): boolean {
  if (!config.streamingClientKey) return false;
  if (!config.streamingApplicationId) return false;

  try {
    entertainmentTargetForStreaming(frame);
    return true;
  } catch {
    return false;
  }
}

function entertainmentTargetForStreaming(frame: HueAmbienceFrame): HueAmbienceTargetFrame {
  const targets = frame.targets.filter(target => target.area.kind === 'entertainmentArea');
  if (targets.length !== 1 || !targets[0]) {
    throw new Error('Hue Entertainment streaming requires exactly one entertainment area target');
  }
  if (!targets[0].metadataComplete) {
    throw new Error('Hue Entertainment streaming requires complete channel metadata');
  }
  return targets[0];
}

function numericChannelID(value: string | null | undefined): number {
  if (typeof value !== 'string' || !/^\d+$/.test(value)) {
    throw new Error('Hue Entertainment streaming requires a numeric entertainment channel id');
  }

  const channelID = Number(value);
  if (!Number.isInteger(channelID) || channelID < 0 || channelID > 255) {
    throw new Error('Hue Entertainment streaming requires a numeric entertainment channel id between 0 and 255');
  }

  return channelID;
}

function hueColorWord(value: number): [number, number] {
  if (!Number.isFinite(value)) return [0, 0];
  const word = Math.round(Math.max(0, Math.min(value, 1)) * 0xffff);
  return [(word >> 8) & 0xff, word & 0xff];
}

class NodeHueEntertainmentDtlsSocket implements HueEntertainmentDtlsSocket {
  private socket: dtls.Socket | null = null;

  constructor(private readonly options: HueEntertainmentDtlsSocketOptions) {}

  connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      const socket = dtls.createSocket({
        type: 'udp4',
        address: this.options.host,
        port: HUE_ENTERTAINMENT_PORT,
        psk: {
          [this.options.identity]: Buffer.from(this.options.psk, 'hex'),
        },
        timeout: 2_000,
        ciphers: ['TLS_PSK_WITH_AES_128_GCM_SHA256'],
      });
      this.socket = socket;

      const cleanup = (): void => {
        socket.off('connected', onConnected);
        socket.off('error', onError);
      };
      const onConnected = (): void => {
        cleanup();
        resolve();
      };
      const onError = (err: Error): void => {
        cleanup();
        reject(err);
      };

      socket.once('connected', onConnected);
      socket.once('error', onError);
    });
  }

  send(packet: Buffer): Promise<void> {
    return new Promise((resolve, reject) => {
      if (!this.socket) {
        reject(new Error('Hue Entertainment DTLS socket is not connected'));
        return;
      }

      this.socket.send(packet, (err?: Error | null) => {
        if (err) {
          reject(err);
          return;
        }
        resolve();
      });
    });
  }

  close(): Promise<void> {
    return new Promise(resolve => {
      if (!this.socket) {
        resolve();
        return;
      }

      const socket = this.socket;
      this.socket = null;
      socket.close(resolve);
    });
  }
}
