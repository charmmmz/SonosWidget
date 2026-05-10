import assert from 'node:assert/strict';
import { test } from 'node:test';
import { PNG } from 'pngjs';

import { extractPaletteFromColors, paletteForSnapshot, paletteFromAlbumArtBuffer } from './hueAlbumArtPalette.js';
import type { HueRGBColor } from './hueTypes.js';

const blue: HueRGBColor = { r: 0.02, g: 0.08, b: 0.92 };
const yellow: HueRGBColor = { r: 0.96, g: 0.82, b: 0.05 };

test('album art palette extraction keeps distinct useful cover colors', () => {
  const palette = extractPaletteFromColors([
    ...Array(18).fill(blue),
    ...Array(12).fill(yellow),
    ...Array(5).fill({ r: 0.02, g: 0.02, b: 0.02 }),
  ]);

  assert.ok(palette.length >= 2);
  assert.ok(palette.some(color => color.b > 0.7 && color.r < 0.2));
  assert.ok(palette.some(color => color.r > 0.7 && color.g > 0.6 && color.b < 0.2));
});

test('snapshot palette prefers fetched album art colors over stable metadata colors', async () => {
  const palette = await paletteForSnapshot(
    {
      groupId: '192.168.50.25',
      speakerName: 'Office',
      trackTitle: 'Any Song',
      artist: 'Any Artist',
      album: 'Any Album',
      albumArtUri: 'http://192.168.50.25:1400/getaa?s=1',
      isPlaying: true,
      positionSeconds: 0,
      durationSeconds: 180,
      groupMemberCount: 1,
      sampledAt: new Date('2026-05-11T00:00:00Z'),
    },
    {
      fetchAlbumArt: async () => Buffer.from('fake-art'),
      extractPalette: async () => [blue, yellow],
    },
  );

  assert.deepEqual(palette, [blue, yellow]);
});

test('album art palette extraction decodes PNG artwork bytes', () => {
  const palette = paletteFromAlbumArtBuffer(makeStripedPng([blue, yellow]));

  assert.ok(palette.some(color => color.b > 0.7 && color.r < 0.2));
  assert.ok(palette.some(color => color.r > 0.7 && color.g > 0.6 && color.b < 0.2));
});

function makeStripedPng(colors: HueRGBColor[]): Buffer {
  const width = colors.length * 8;
  const height = 8;
  const png = new PNG({ width, height });

  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const color = colors[Math.floor(x / 8)]!;
      const index = (y * width + x) * 4;
      png.data[index] = Math.round(color.r * 255);
      png.data[index + 1] = Math.round(color.g * 255);
      png.data[index + 2] = Math.round(color.b * 255);
      png.data[index + 3] = 255;
    }
  }

  return PNG.sync.write(png);
}
