import express from 'express';
import pino from 'pino';
import pinoHttp from 'pino-http';
import crypto from 'node:crypto';
import path from 'node:path';

import { SonosBridge } from './sonos.js';
import { createInternalSonosRouter, internalAuthMiddleware } from './internalSonosRoutes.js';
import { ApnsClient, toSwiftDate } from './apns.js';
import { TokenStore } from './tokenStore.js';
import { HueAmbienceConfigStore } from './hueConfigStore.js';
import { HueAmbienceService } from './hueAmbienceService.js';
import { createHueAmbienceRouter } from './hueRoutes.js';
import { Cs2GameStateService } from './cs2GameState.js';
import { createCs2GameStateRouter } from './cs2Routes.js';
import { Cs2LightingService } from './cs2Lighting.js';
import { shouldIgnoreHttpAutoLog } from './httpLogging.js';
import type { LiveActivityContentState, RegisterRequest, SonosGroupSnapshot } from './types.js';

const log = pino({
  level: process.env.LOG_LEVEL ?? 'info',
  transport: process.env.NODE_ENV === 'production' ? undefined : { target: 'pino-pretty' },
});

const RELAY_PORT = Number(process.env.RELAY_PORT ?? 8787);
const SEED_IP = process.env.SONOS_SEED_IP;
const DATA_DIR = process.env.DATA_DIR ?? '/app/data';
const CS2_LIGHTING_LOG_PATH = process.env.CS2_LIGHTING_LOG_PATH
  ?? path.join(DATA_DIR, 'cs2-lighting.jsonl');

if (!SEED_IP) {
  log.fatal('SONOS_SEED_IP is required (any always-on speaker IP on the LAN)');
  process.exit(1);
}

async function main(): Promise<void> {
  // ---- core wiring ------------------------------------------------------
  const tokens = new TokenStore(DATA_DIR, log);
  await tokens.load();
  const hueConfigStore = new HueAmbienceConfigStore(DATA_DIR);
  const hueAmbience = new HueAmbienceService(
    hueConfigStore,
    log.child({ module: 'hue-ambience' }),
  );
  await hueAmbience.load();
  const cs2GameState = new Cs2GameStateService();
  const cs2Lighting = new Cs2LightingService(hueConfigStore, undefined, {
    beforeRender: () => hueAmbience.pauseForExternalRenderer(),
    logger: log.child({ module: 'cs2-lighting' }),
    logFilePath: CS2_LIGHTING_LOG_PATH,
  });

  const apns = await ApnsClient.create(
    {
      bundleId: process.env.APNS_BUNDLE_ID ?? 'com.charm.SonosWidget',
      keyPath: process.env.APNS_KEY_PATH ?? path.join(DATA_DIR, 'apns.p8'),
      keyId: process.env.APNS_KEY_ID ?? '',
      teamId: process.env.APNS_TEAM_ID ?? '',
      production: (process.env.APNS_PRODUCTION ?? 'false') === 'true',
    },
    log,
  );

  const sonos = new SonosBridge(log);
  await sonos.start(SEED_IP!);

  // ---- snapshot → APNs pipeline ----------------------------------------
  sonos.on('change', async (snap: SonosGroupSnapshot) => {
    if (!cs2Lighting.shouldDeferAlbumAmbience()) {
      hueAmbience.receiveSnapshot(snap);
    }

    const matching = tokens.forGroup(snap.groupId);
    if (matching.length === 0) return;

    const state = buildContentState(snap);
    const hash = hashState(state);

    // Skip no-op pushes — a single Sonos event often fires with identical
    // payload right after we just refreshed (eventing + polling overlap).
    const targets = matching.filter(t => t.lastSentHash !== hash);
    if (targets.length === 0) return;

    const result = await apns.pushUpdate(
      targets.map(t => t.token),
      state,
    );
    for (const t of targets) {
      tokens.recordSent(t.token, hash);
    }
    for (const dead of result.unregistered) tokens.unregister(dead);

    log.debug(
      { groupId: snap.groupId, state, sent: result.sent, failed: result.failed },
      'pushed Live Activity update',
    );
  });

  // ---- HTTP -------------------------------------------------------------
  const app = express();
  app.use(express.json({ limit: '512kb' }));
  app.use(
    pinoHttp({
      logger: log,
      autoLogging: { ignore: shouldIgnoreHttpAutoLog },
      // Don't log the full body; tokens are sensitive-ish.
      serializers: { req: req => ({ method: req.method, url: req.url }) },
    }),
  );

  app.use('/internal', internalAuthMiddleware(log), createInternalSonosRouter(sonos, log));
  app.use('/api', createHueAmbienceRouter(hueAmbience, log));
  app.use('/api', createCs2GameStateRouter(cs2GameState, log.child({ module: 'cs2' })));

  cs2GameState.on('state', snapshot => {
    void cs2Lighting.receive(snapshot);
  });

  app.get('/api/health', async (_req, res) => {
    const hueAmbienceStatus = hueAmbience.status();
    const hueEntertainmentStatus = await hueAmbience.entertainmentStatus();
    res.json({
      ok: true,
      groups: sonos.allSnapshots().map(s => ({
        groupId: s.groupId,
        speakerName: s.speakerName,
        isPlaying: s.isPlaying,
        title: s.trackTitle,
        playbackSourceRaw: s.playbackSourceRaw,
        musicAmbienceEligible: s.musicAmbienceEligible,
      })),
      hueAmbience: hueAmbienceStatus,
      hueEntertainment: hueEntertainmentStatus,
      cs2Lighting: cs2Lighting.status(),
      cs2: {
        providers: cs2GameState.status(),
      },
    });
  });

  /// iOS posts here right after `Activity.request(pushType: .token)` resolves
  /// and on every `pushTokenUpdates` rotation. Body shape: `RegisterRequest`.
  /// Replies with the current ContentState so the iOS side can sanity-check
  /// what the server thinks is playing without waiting for the next event.
  app.post('/api/register-activity', async (req, res) => {
    const body = req.body as Partial<RegisterRequest>;
    if (!body.groupId || !body.token) {
      res.status(400).json({ error: 'groupId and token are required' });
      return;
    }
    tokens.register({
      groupId: body.groupId,
      token: body.token,
      attributes: body.attributes,
    });

    // Push an initial state immediately so the Lock Screen reflects current
    // playback the moment the user starts the Live Activity, not after the
    // next track change.
    const snap = sonos.current(body.groupId);
    if (snap) {
      const state = buildContentState(snap);
      const result = await apns.pushUpdate([body.token], state);
      for (const dead of result.unregistered) tokens.unregister(dead);
      tokens.recordSent(body.token, hashState(state));
      res.json({ ok: true, initialState: state });
      return;
    }
    res.json({ ok: true, initialState: null });
  });

  app.delete('/api/register-activity/:token', (req, res) => {
    const ok = tokens.unregister(req.params.token);
    res.json({ ok });
  });

  // ---- listen + shutdown -----------------------------------------------
  const server = app.listen(RELAY_PORT, () => {
    log.info({ port: RELAY_PORT }, 'relay HTTP listening');
  });

  const shutdown = (signal: string) => {
    log.info({ signal }, 'shutting down');
    server.close();
    sonos.stop();
    void hueAmbience.stop();
    apns.shutdown();
    setTimeout(() => process.exit(0), 500);
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

function buildContentState(snap: SonosGroupSnapshot): LiveActivityContentState {
  const sampledUnix = snap.sampledAt.getTime() / 1000;
  const startedAtUnix = snap.isPlaying && snap.durationSeconds > 0
    ? sampledUnix - snap.positionSeconds
    : null;
  const endsAtUnix = snap.isPlaying && snap.durationSeconds > 0
    ? sampledUnix + (snap.durationSeconds - snap.positionSeconds)
    : null;

  return {
    trackTitle: snap.trackTitle || 'Not Playing',
    artist: snap.artist || '—',
    album: snap.album,
    isPlaying: snap.isPlaying,
    positionSeconds: snap.positionSeconds,
    durationSeconds: snap.durationSeconds,
    dominantColorHex: null,
    startedAt: startedAtUnix !== null ? toSwiftDate(startedAtUnix) : null,
    endsAt: endsAtUnix !== null ? toSwiftDate(endsAtUnix) : null,
    albumArtThumbnail: null, // Phase 2: fetch + downscale art on the relay
    groupMemberCount: snap.groupMemberCount,
    playbackSourceRaw: snap.playbackSourceRaw ?? null,
  };
}

function hashState(state: LiveActivityContentState): string {
  // Hash only the user-visible fields; ignore startedAt/endsAt drift since
  // those move on every poll even when playback is unchanged.
  const projection = {
    t: state.trackTitle,
    a: state.artist,
    al: state.album,
    p: state.isPlaying,
    d: state.durationSeconds,
    s: state.playbackSourceRaw,
  };
  return crypto
    .createHash('sha256')
    .update(JSON.stringify(projection))
    .digest('hex')
    .slice(0, 16);
}

main().catch(err => {
  log.fatal({ err }, 'fatal startup error');
  process.exit(1);
});
