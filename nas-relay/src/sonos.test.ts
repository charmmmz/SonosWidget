import assert from 'node:assert/strict';
import { test } from 'node:test';

import { albumArtUriFromMetadata, trackMetadataFromMetadata } from './sonos.js';

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
