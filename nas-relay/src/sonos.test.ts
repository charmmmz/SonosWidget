import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { test } from 'node:test';
import { SonosEvents } from '@svrooij/sonos';
import pino from 'pino';

import {
  albumArtUriFromMetadata,
  isMusicAmbienceEligibleForSnapshot,
  playbackSourceFromTrackUri,
  SonosBridge,
  trackMetadataFromMetadata,
} from './sonos.js';

test('album art extraction accepts parsed Sonos Track metadata objects', () => {
  assert.equal(
    albumArtUriFromMetadata({ AlbumArtUri: '/getaa?s=1&u=x-sonos-http%3atrack' }),
    '/getaa?s=1&u=x-sonos-http%3atrack',
  );
});

test('album art extraction accepts raw DIDL strings', () => {
  assert.equal(
    albumArtUriFromMetadata(
      '<DIDL-Lite><item><upnp:albumArtURI>/getaa?s=1&amp;u=x-sonos-http%3atrack</upnp:albumArtURI></item></DIDL-Lite>',
    ),
    '/getaa?s=1&u=x-sonos-http%3atrack',
  );
});

test('track metadata extraction accepts raw DIDL strings', () => {
  assert.deepEqual(
    trackMetadataFromMetadata(
      '<DIDL-Lite><item><dc:title>Blue Train</dc:title><dc:creator>John Coltrane</dc:creator><upnp:album>Blue Train</upnp:album><upnp:albumArtURI>/getaa?s=1&amp;u=x-sonos-http%3atrack</upnp:albumArtURI></item></DIDL-Lite>',
    ),
    {
      title: 'Blue Train',
      artist: 'John Coltrane',
      album: 'Blue Train',
      albumArtUri: '/getaa?s=1&u=x-sonos-http%3atrack',
    },
  );
});

test('track metadata extraction accepts parsed Sonos Track metadata objects', () => {
  assert.deepEqual(
    trackMetadataFromMetadata({
      Title: 'Teardrop',
      Artist: 'Massive Attack',
      Album: 'Mezzanine',
      AlbumArtUri: '/getaa?s=1&u=x-sonos-http%3ateardrop',
    }),
    {
      title: 'Teardrop',
      artist: 'Massive Attack',
      album: 'Mezzanine',
      albumArtUri: '/getaa?s=1&u=x-sonos-http%3ateardrop',
    },
  );
});

test('playback source extraction identifies TV input as non-music ambience', () => {
  assert.equal(playbackSourceFromTrackUri('x-sonos-htastream:RINCON_123:spdif'), 'tv');
  assert.equal(isMusicAmbienceEligibleForSnapshot({
    trackTitle: 'TV',
    artist: 'Live audio',
    album: '',
    albumArtUri: null,
    playbackSourceRaw: 'tv',
  }), false);
});

test('music ambience eligibility still allows music metadata without a known source', () => {
  assert.equal(isMusicAmbienceEligibleForSnapshot({
    trackTitle: 'Blue Train',
    artist: 'John Coltrane',
    album: 'Blue Train',
    albumArtUri: null,
    playbackSourceRaw: null,
  }), true);
});

test('bridge refreshes snapshots when the Sonos library emits real event names', () => {
  const bridge = new SonosBridge(pino({ enabled: false }));
  const events = new EventEmitter();
  const refreshedDevices: string[] = [];
  const device = { Name: 'Office', Events: events };

  (bridge as unknown as { refreshSnapshot: (device: unknown) => Promise<void> }).refreshSnapshot = async refreshed => {
    refreshedDevices.push((refreshed as { Name: string }).Name);
  };
  (bridge as unknown as { attachDeviceListeners: (device: unknown) => void }).attachDeviceListeners(device);

  events.emit(SonosEvents.AVTransport, {});
  events.emit(SonosEvents.CurrentTrackUri, 'x-rincon-queue:RINCON_1#0');
  events.emit(SonosEvents.CurrentTrackMetadata, { Title: 'Blue Train' });
  events.emit(SonosEvents.CurrentTransportState, 'PLAYING');
  events.emit(SonosEvents.CurrentTransportStateSimple, 'PLAYING');
  events.emit(SonosEvents.PlaybackStopped);
  events.emit(SonosEvents.GroupName, 'Office');

  assert.deepEqual(refreshedDevices, [
    'Office',
    'Office',
    'Office',
    'Office',
    'Office',
    'Office',
    'Office',
  ]);
});

test('bridge ignores stale snapshot refreshes that complete after a newer refresh', async () => {
  const bridge = new SonosBridge(pino({ enabled: false }));
  const staleTransport = deferred<{ CurrentTransportState: string }>();
  const stalePosition = deferred<Record<string, string>>();
  let transportCalls = 0;
  let positionCalls = 0;
  const snapshots: Array<{ isPlaying: boolean; title: string }> = [];
  const device = {
    Host: '192.168.50.25',
    Name: 'Office',
    Uuid: 'office',
    AVTransportService: {
      GetTransportInfo: () => {
        transportCalls += 1;
        return transportCalls === 1
          ? staleTransport.promise
          : Promise.resolve({ CurrentTransportState: 'PAUSED_PLAYBACK' });
      },
      GetPositionInfo: () => {
        positionCalls += 1;
        return positionCalls === 1
          ? Promise.resolve(positionInfo('Paused Song'))
          : stalePosition.promise;
      },
    },
  };

  bridge.on('change', snapshot => {
    snapshots.push({ isPlaying: snapshot.isPlaying, title: snapshot.trackTitle });
  });

  const firstRefresh = (bridge as unknown as { refreshSnapshot: (device: unknown) => Promise<void> }).refreshSnapshot(device);
  const secondRefresh = (bridge as unknown as { refreshSnapshot: (device: unknown) => Promise<void> }).refreshSnapshot(device);
  await secondRefresh;

  staleTransport.resolve({ CurrentTransportState: 'PLAYING' });
  stalePosition.resolve(positionInfo('Stale Playing Song'));
  await firstRefresh;

  assert.deepEqual(snapshots, [{ isPlaying: false, title: 'Paused Song' }]);
  assert.deepEqual(bridge.current('192.168.50.25')?.trackTitle, 'Paused Song');
});

function positionInfo(title: string): Record<string, string> {
  return {
    RelTime: '00:00:00',
    TrackDuration: '00:03:00',
    TrackURI: 'x-rincon-queue:RINCON_1#0',
    TrackMetaData: `<DIDL-Lite><item><dc:title>${title}</dc:title><dc:creator>Artist</dc:creator><upnp:album>Album</upnp:album><upnp:albumArtURI>/getaa?s=1&amp;u=x-sonos-http%3atrack</upnp:albumArtURI></item></DIDL-Lite>`,
  };
}

function deferred<T>(): { promise: Promise<T>; resolve: (value: T) => void } {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(innerResolve => {
    resolve = innerResolve;
  });
  return { promise, resolve };
}
