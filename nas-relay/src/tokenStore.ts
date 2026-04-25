import { promises as fs } from 'node:fs';
import path from 'node:path';
import type { Logger } from 'pino';
import type { RegisterRequest, TokenEntry } from './types.js';

/// Disk-backed token registry. In-memory `Map<token, TokenEntry>` for fast
/// lookups; write-through to a JSON file on every mutation so the relay
/// container can be restarted without re-registering every device.
export class TokenStore {
  private readonly tokens = new Map<string, TokenEntry>();
  private readonly path: string;
  private readonly log: Logger;
  private flushPromise: Promise<void> | null = null;

  constructor(dataDir: string, log: Logger) {
    this.path = path.join(dataDir, 'tokens.json');
    this.log = log.child({ module: 'tokenStore' });
  }

  async load(): Promise<void> {
    try {
      const raw = await fs.readFile(this.path, 'utf8');
      const parsed = JSON.parse(raw) as TokenEntry[];
      for (const entry of parsed) this.tokens.set(entry.token, entry);
      this.log.info({ count: this.tokens.size }, 'loaded persisted tokens');
    } catch (err: any) {
      if (err.code !== 'ENOENT') {
        this.log.warn({ err }, 'failed to load tokens.json — starting empty');
      }
    }
  }

  register(req: RegisterRequest): TokenEntry {
    const existing = this.tokens.get(req.token);
    const entry: TokenEntry = {
      ...req,
      registeredAt: existing?.registeredAt ?? new Date().toISOString(),
      lastSentHash: existing?.lastSentHash, // preserve so repeat-register doesn't double-push
    };
    this.tokens.set(req.token, entry);
    void this.flush();
    this.log.info({ token: shortToken(req.token), groupId: req.groupId }, 'registered');
    return entry;
  }

  unregister(token: string): boolean {
    const removed = this.tokens.delete(token);
    if (removed) {
      void this.flush();
      this.log.info({ token: shortToken(token) }, 'unregistered');
    }
    return removed;
  }

  forGroup(groupId: string): TokenEntry[] {
    const out: TokenEntry[] = [];
    for (const entry of this.tokens.values()) {
      if (entry.groupId === groupId) out.push(entry);
    }
    return out;
  }

  /// Update the cached "last shipped hash" so we can skip no-op pushes. Done
  /// atomically with a debounced flush since this is a write-heavy field.
  recordSent(token: string, hash: string): void {
    const entry = this.tokens.get(token);
    if (entry) {
      entry.lastSentHash = hash;
      void this.flush();
    }
  }

  /// Coalesce repeated mutations into one write per ~100 ms.
  private async flush(): Promise<void> {
    if (this.flushPromise) return this.flushPromise;
    this.flushPromise = new Promise<void>(resolve => {
      setTimeout(async () => {
        try {
          const data = JSON.stringify(Array.from(this.tokens.values()), null, 2);
          await fs.writeFile(this.path, data, 'utf8');
        } catch (err) {
          this.log.error({ err }, 'failed to persist tokens.json');
        } finally {
          this.flushPromise = null;
          resolve();
        }
      }, 100);
    });
    return this.flushPromise;
  }
}

function shortToken(token: string): string {
  return token.length <= 12 ? token : `${token.slice(0, 6)}…${token.slice(-4)}`;
}
