import https from 'node:https';

import type { HueBridgeInfo, HueEntertainmentClient, HueLightClient } from './hueTypes.js';

export class HueClipClient implements HueLightClient, HueEntertainmentClient {
  constructor(
    private readonly bridge: HueBridgeInfo,
    private readonly applicationKey: string,
    private readonly timeoutMs = 5_000,
  ) {}

  async updateLight(id: string, body: unknown): Promise<void> {
    await this.request('PUT', `/clip/v2/resource/light/${encodeURIComponent(id)}`, body);
  }

  async get<T>(path: string): Promise<T> {
    return await this.request<T>('GET', path);
  }

  async setEntertainmentStreaming(areaID: string, active: boolean): Promise<void> {
    await this.request(
      'PUT',
      `/clip/v2/resource/entertainment_configuration/${encodeURIComponent(areaID)}`,
      { action: active ? 'start' : 'stop' },
    );
  }

  private request<T = void>(method: string, requestPath: string, body?: unknown): Promise<T> {
    const payload = body === undefined ? null : JSON.stringify(body);
    const headers: Record<string, string | number> = {
      'hue-application-key': this.applicationKey,
    };
    if (payload !== null) {
      headers['Content-Type'] = 'application/json';
      headers['Content-Length'] = Buffer.byteLength(payload);
    }

    return new Promise((resolve, reject) => {
      const req = https.request(
        {
          hostname: this.bridge.ipAddress,
          port: 443,
          path: requestPath,
          method,
          rejectUnauthorized: false,
          headers,
          timeout: this.timeoutMs,
        },
        res => {
          const chunks: Buffer[] = [];
          res.on('data', chunk => chunks.push(Buffer.from(chunk)));
          res.on('end', () => {
            const text = Buffer.concat(chunks).toString('utf8');
            if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) {
              if (text.trim().length === 0) {
                resolve(undefined as T);
                return;
              }
              try {
                resolve(JSON.parse(text) as T);
              } catch {
                resolve(text as T);
              }
              return;
            }
            reject(new Error(`Hue ${method} ${requestPath} failed: HTTP ${res.statusCode} ${text}`));
          });
        },
      );

      req.on('timeout', () => {
        req.destroy(new Error(`Hue ${method} ${requestPath} timed out`));
      });
      req.on('error', reject);
      if (payload !== null) {
        req.write(payload);
      }
      req.end();
    });
  }
}
