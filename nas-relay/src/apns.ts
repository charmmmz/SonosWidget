import apn from '@parse/node-apn';
import { promises as fs } from 'node:fs';
import type { Logger } from 'pino';
import type { LiveActivityContentState } from './types.js';

/// Swift's `Date` Codable default uses NSDate reference epoch (2001-01-01 UTC),
/// NOT Unix epoch. ContentState fields like `startedAt` / `endsAt` must be
/// converted before they go on the wire or the iOS decoder lands on a date
/// in 1970 + offset.
const SWIFT_DATE_EPOCH_OFFSET = 978307200; // (Date.UTC(2001,0,1) / 1000)
export function toSwiftDate(unixSeconds: number): number {
  return unixSeconds - SWIFT_DATE_EPOCH_OFFSET;
}

export interface ApnsConfig {
  bundleId: string;
  keyPath: string;
  keyId: string;
  teamId: string;
  production: boolean;
}

export interface ApnsResult {
  sent: number;
  failed: number;
  unregistered: string[]; // tokens APNs reported as gone (410)
}

/// Wraps `@parse/node-apn`. When the `.p8` key isn't present yet (Apple
/// Developer enrollment still pending), we go into "dry-run" mode and only
/// log the payload we *would* have sent — useful for validating the data
/// pipeline (Sonos events → ContentState shape) before push actually works.
export class ApnsClient {
  private provider: apn.Provider | null = null;
  private readonly log: Logger;
  private readonly config: ApnsConfig;
  private readonly dryRun: boolean;

  private constructor(config: ApnsConfig, dryRun: boolean, log: Logger) {
    this.config = config;
    this.dryRun = dryRun;
    this.log = log.child({ module: 'apns' });
  }

  static async create(config: ApnsConfig, log: Logger): Promise<ApnsClient> {
    const childLog = log.child({ module: 'apns' });

    if (!config.keyId || !config.teamId) {
      childLog.warn(
        'APNS_KEY_ID / APNS_TEAM_ID not set — running in DRY-RUN mode (logs payloads only).',
      );
      return new ApnsClient(config, true, log);
    }

    try {
      await fs.access(config.keyPath);
    } catch {
      childLog.warn(
        { keyPath: config.keyPath },
        'APNs .p8 not found — running in DRY-RUN mode (logs payloads only).',
      );
      return new ApnsClient(config, true, log);
    }

    const client = new ApnsClient(config, false, log);
    client.provider = new apn.Provider({
      token: {
        key: config.keyPath,
        keyId: config.keyId,
        teamId: config.teamId,
      },
      production: config.production,
    });
    childLog.info(
      { production: config.production, bundleId: config.bundleId },
      'APNs provider ready',
    );
    return client;
  }

  /// Push an `update` event to a list of Live Activity push tokens.
  async pushUpdate(
    tokens: string[],
    contentState: LiveActivityContentState,
    relevanceScore = 50,
  ): Promise<ApnsResult> {
    return this.push(tokens, 'update', contentState, relevanceScore);
  }

  /// Push an `end` event so iOS removes the Live Activity from Lock Screen.
  async pushEnd(tokens: string[], contentState: LiveActivityContentState): Promise<ApnsResult> {
    return this.push(tokens, 'end', contentState, 0);
  }

  private async push(
    tokens: string[],
    event: 'update' | 'end',
    contentState: LiveActivityContentState,
    relevanceScore: number,
  ): Promise<ApnsResult> {
    if (tokens.length === 0) return { sent: 0, failed: 0, unregistered: [] };

    // The Live Activity-specific fields (pushType, relevanceScore, timestamp,
    // staleDate, event, contentState) exist on the Notification prototype at
    // runtime but the shipped .d.ts hasn't been updated to declare them yet,
    // so we widen the type once with a local interface and assign through it.
    type LiveActivityNote = apn.Notification & {
      pushType: string;
      relevanceScore: number;
      timestamp: number;
      staleDate: number;
      event: 'update' | 'end';
      contentState: Record<string, unknown>;
    };
    const note = new apn.Notification() as LiveActivityNote;
    note.topic = `${this.config.bundleId}.push-type.liveactivity`;
    note.pushType = 'liveactivity';
    note.expiry = Math.floor(Date.now() / 1000) + 3600;
    note.relevanceScore = relevanceScore;
    note.timestamp = Math.floor(Date.now() / 1000);
    // Live Activities Apple-suggested 8 hour stale; iOS auto-ends at 12h.
    note.staleDate = Math.floor(Date.now() / 1000) + 8 * 3600;
    note.event = event;
    note.contentState = contentState as unknown as Record<string, unknown>;

    if (this.dryRun || !this.provider) {
      this.log.info(
        { event, tokens: tokens.length, payload: contentState },
        '[DRY-RUN] would push Live Activity update',
      );
      return { sent: tokens.length, failed: 0, unregistered: [] };
    }

    const result: ApnsResult = { sent: 0, failed: 0, unregistered: [] };
    try {
      const response = await this.provider.send(note, tokens);
      result.sent = response.sent.length;
      for (const failure of response.failed) {
        result.failed += 1;
        // 410 Unregistered = device de-installed app or token rotated;
        // surface so the caller can prune the token store.
        if (failure.status === 410 && failure.device) {
          result.unregistered.push(failure.device);
          this.log.info(
            { token: failure.device.slice(0, 8) + '…' },
            'APNs reported token Unregistered — pruning',
          );
        } else {
          this.log.warn({ failure }, 'APNs push failed');
        }
      }
    } catch (err) {
      this.log.error({ err }, 'APNs send threw');
      result.failed = tokens.length;
    }
    return result;
  }

  shutdown(): void {
    this.provider?.shutdown();
  }
}
