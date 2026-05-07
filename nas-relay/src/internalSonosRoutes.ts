import { Router, type Request, type Response, type NextFunction } from 'express';
import type { Logger } from 'pino';

import type { SonosBridge } from './sonos.js';

export function internalAuthMiddleware(log: Logger): (req: Request, res: Response, next: NextFunction) => void {
  return (req: Request, res: Response, next: NextFunction) => {
    const expected = process.env.INTERNAL_API_TOKEN ?? '';
    if (!expected) {
      log.warn('INTERNAL_API_TOKEN unset — refusing /internal requests');
      res.status(503).json({ ok: false, error: 'internal_api_disabled' });
      return;
    }
    const sent = req.headers['x-internal-token'];
    if (typeof sent !== 'string' || sent !== expected) {
      res.status(401).json({ ok: false, error: 'unauthorized' });
      return;
    }
    next();
  };
}

function snapshotJson(s: {
  groupId: string;
  speakerName: string;
  trackTitle: string;
  artist: string;
  album: string;
  isPlaying: boolean;
  positionSeconds: number;
  durationSeconds: number;
  groupMemberCount: number;
  sampledAt: Date;
}) {
  return {
    groupId: s.groupId,
    speakerName: s.speakerName,
    trackTitle: s.trackTitle,
    artist: s.artist,
    album: s.album,
    isPlaying: s.isPlaying,
    positionSeconds: s.positionSeconds,
    durationSeconds: s.durationSeconds,
    groupMemberCount: s.groupMemberCount,
    sampledAt: s.sampledAt.toISOString(),
  };
}

export function createInternalSonosRouter(sonos: SonosBridge, log: Logger): Router {
  const r = Router();

  r.get('/sonos/groups', (_req, res) => {
    res.json({
      ok: true,
      groups: sonos.allSnapshots().map(snapshotJson),
    });
  });

  r.get('/sonos/state', async (req, res) => {
    const groupId = typeof req.query.groupId === 'string' ? req.query.groupId : '';
    if (!groupId) {
      res.status(400).json({ ok: false, error: 'groupId query parameter required' });
      return;
    }
    try {
      const snap = await sonos.pullFreshSnapshot(groupId);
      if (!snap) {
        res.status(404).json({ ok: false, error: 'unknown_group', groupId });
        return;
      }
      res.json({ ok: true, state: snapshotJson(snap) });
    } catch (err) {
      log.warn({ err, groupId }, 'pullFreshSnapshot failed');
      res.status(500).json({ ok: false, error: String(err) });
    }
  });

  r.post('/sonos/play', async (req, res) => {
    const groupId = typeof req.body?.groupId === 'string' ? req.body.groupId : '';
    if (!groupId) {
      res.status(400).json({ ok: false, error: 'groupId required' });
      return;
    }
    try {
      await sonos.play(groupId);
      const snap = sonos.current(groupId);
      res.json({ ok: true, state: snap ? snapshotJson(snap) : null });
    } catch (err) {
      const msg = String(err);
      if (msg.includes('unknown_group')) {
        res.status(404).json({ ok: false, error: 'unknown_group', groupId });
        return;
      }
      log.warn({ err, groupId }, 'play failed');
      res.status(500).json({ ok: false, error: msg });
    }
  });

  r.post('/sonos/pause', async (req, res) => {
    const groupId = typeof req.body?.groupId === 'string' ? req.body.groupId : '';
    if (!groupId) {
      res.status(400).json({ ok: false, error: 'groupId required' });
      return;
    }
    try {
      await sonos.pause(groupId);
      const snap = sonos.current(groupId);
      res.json({ ok: true, state: snap ? snapshotJson(snap) : null });
    } catch (err) {
      const msg = String(err);
      if (msg.includes('unknown_group')) {
        res.status(404).json({ ok: false, error: 'unknown_group', groupId });
        return;
      }
      log.warn({ err, groupId }, 'pause failed');
      res.status(500).json({ ok: false, error: msg });
    }
  });

  r.post('/sonos/next', async (req, res) => {
    const groupId = typeof req.body?.groupId === 'string' ? req.body.groupId : '';
    if (!groupId) {
      res.status(400).json({ ok: false, error: 'groupId required' });
      return;
    }
    try {
      await sonos.next(groupId);
      const snap = sonos.current(groupId);
      res.json({ ok: true, state: snap ? snapshotJson(snap) : null });
    } catch (err) {
      const msg = String(err);
      if (msg.includes('unknown_group')) {
        res.status(404).json({ ok: false, error: 'unknown_group', groupId });
        return;
      }
      log.warn({ err, groupId }, 'next failed');
      res.status(500).json({ ok: false, error: msg });
    }
  });

  r.post('/sonos/previous', async (req, res) => {
    const groupId = typeof req.body?.groupId === 'string' ? req.body.groupId : '';
    if (!groupId) {
      res.status(400).json({ ok: false, error: 'groupId required' });
      return;
    }
    try {
      await sonos.previous(groupId);
      const snap = sonos.current(groupId);
      res.json({ ok: true, state: snap ? snapshotJson(snap) : null });
    } catch (err) {
      const msg = String(err);
      if (msg.includes('unknown_group')) {
        res.status(404).json({ ok: false, error: 'unknown_group', groupId });
        return;
      }
      log.warn({ err, groupId }, 'previous failed');
      res.status(500).json({ ok: false, error: msg });
    }
  });

  r.post('/sonos/volume', async (req, res) => {
    const groupId = typeof req.body?.groupId === 'string' ? req.body.groupId : '';
    const volume = req.body?.volume;
    if (!groupId) {
      res.status(400).json({ ok: false, error: 'groupId required' });
      return;
    }
    if (typeof volume !== 'number' || Number.isNaN(volume)) {
      res.status(400).json({ ok: false, error: 'volume must be a number' });
      return;
    }
    try {
      await sonos.setGroupVolume(groupId, volume);
      const snap = sonos.current(groupId);
      res.json({ ok: true, state: snap ? snapshotJson(snap) : null });
    } catch (err) {
      const msg = String(err);
      if (msg.includes('unknown_group')) {
        res.status(404).json({ ok: false, error: 'unknown_group', groupId });
        return;
      }
      log.warn({ err, groupId }, 'setGroupVolume failed');
      res.status(500).json({ ok: false, error: msg });
    }
  });

  return r;
}
