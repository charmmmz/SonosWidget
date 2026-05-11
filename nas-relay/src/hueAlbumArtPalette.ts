import jpeg from 'jpeg-js';
import { PNG } from 'pngjs';

import { stablePaletteForTrack } from './huePalette.js';
import type { HueRGBColor, HueSnapshot } from './hueTypes.js';

const SAMPLE_SIZE = 24;
const MAX_PALETTE_COLORS = 5;
const MAX_ALBUM_ART_BYTES = 5 * 1024 * 1024;

export interface HueAlbumArtPaletteDependencies {
  fetchAlbumArt?: (uri: string) => Promise<Buffer>;
  extractPalette?: (data: Buffer) => Promise<HueRGBColor[]> | HueRGBColor[];
}

interface DecodedImage {
  width: number;
  height: number;
  data: Uint8Array;
}

export async function paletteForSnapshot(
  snapshot: HueSnapshot,
  dependencies: HueAlbumArtPaletteDependencies = {},
): Promise<HueRGBColor[]> {
  const fallback = stablePaletteForTrack(
    snapshot.trackTitle,
    snapshot.artist,
    snapshot.album,
    snapshot.albumArtUri ?? '',
  );

  if (!snapshot.albumArtUri) {
    return fallback;
  }

  try {
    const imageData = await (dependencies.fetchAlbumArt ?? fetchAlbumArt)(snapshot.albumArtUri);
    const palette = await (dependencies.extractPalette ?? paletteFromAlbumArtBuffer)(imageData);
    return palette.length > 0 ? palette : fallback;
  } catch {
    return fallback;
  }
}

export async function fetchAlbumArt(uri: string): Promise<Buffer> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 5_000);
  try {
    const response = await fetch(uri, { signal: controller.signal });
    if (!response.ok) {
      throw new Error(`Album art request failed with HTTP ${response.status}`);
    }

    const contentLength = Number(response.headers.get('content-length') ?? '0');
    if (contentLength > MAX_ALBUM_ART_BYTES) {
      throw new Error('Album art response is too large');
    }

    const arrayBuffer = await response.arrayBuffer();
    if (arrayBuffer.byteLength > MAX_ALBUM_ART_BYTES) {
      throw new Error('Album art response is too large');
    }

    return Buffer.from(arrayBuffer);
  } finally {
    clearTimeout(timeout);
  }
}

export function paletteFromAlbumArtBuffer(data: Buffer): HueRGBColor[] {
  const colors = sampleImageColors(decodeImage(data));
  const palette = extractPaletteFromColors(colors);
  return palette.length > 0 ? palette : fallbackPaletteFromAlbumColors(colors);
}

export function extractPaletteFromColors(
  colors: HueRGBColor[],
  maxColors = MAX_PALETTE_COLORS,
): HueRGBColor[] {
  const colorLimit = Math.max(0, Math.min(maxColors, MAX_PALETTE_COLORS));
  if (colorLimit === 0) return [];

  const buckets = new Map<string, ColorBucket>();
  for (const color of colors) {
    if (!isUsefulAlbumColor(color)) continue;
    const key = bucketKey(color);
    const bucket = buckets.get(key) ?? new ColorBucket();
    bucket.add(color);
    buckets.set(key, bucket);
  }

  const palette: HueRGBColor[] = [];
  for (const bucket of Array.from(buckets.values()).sort((a, b) => b.score - a.score)) {
    const color = bucket.averageColor;
    if (palette.some(existing => distance(existing, color) < 0.28)) continue;
    palette.push(color);
    if (palette.length === colorLimit) return palette;
  }

  return palette;
}

function decodeImage(data: Buffer): DecodedImage {
  if (isPng(data)) {
    const png = PNG.sync.read(data);
    return { width: png.width, height: png.height, data: png.data };
  }
  if (isJpeg(data)) {
    const jpegImage = jpeg.decode(data, { useTArray: true });
    return { width: jpegImage.width, height: jpegImage.height, data: jpegImage.data };
  }
  throw new Error('Unsupported album art image format');
}

function sampleImageColors(image: DecodedImage): HueRGBColor[] {
  const width = Math.max(image.width, 1);
  const height = Math.max(image.height, 1);
  const colors: HueRGBColor[] = [];

  for (let y = 0; y < SAMPLE_SIZE; y += 1) {
    const sourceY = Math.min(height - 1, Math.floor(((y + 0.5) / SAMPLE_SIZE) * height));
    for (let x = 0; x < SAMPLE_SIZE; x += 1) {
      const sourceX = Math.min(width - 1, Math.floor(((x + 0.5) / SAMPLE_SIZE) * width));
      const index = (sourceY * width + sourceX) * 4;
      const alpha = image.data[index + 3]! / 255;
      if (alpha <= 0.1) continue;
      colors.push({
        r: image.data[index]! / 255,
        g: image.data[index + 1]! / 255,
        b: image.data[index + 2]! / 255,
      });
    }
  }

  return colors;
}

function isPng(data: Buffer): boolean {
  return data.length >= 8
    && data[0] === 0x89
    && data[1] === 0x50
    && data[2] === 0x4e
    && data[3] === 0x47;
}

function isJpeg(data: Buffer): boolean {
  return data.length >= 3 && data[0] === 0xff && data[1] === 0xd8 && data[2] === 0xff;
}

function bucketKey(color: HueRGBColor): string {
  return [
    Math.round(color.r * 5),
    Math.round(color.g * 5),
    Math.round(color.b * 5),
  ].join(':');
}

class ColorBucket {
  private rTotal = 0;
  private gTotal = 0;
  private bTotal = 0;
  private saturationTotal = 0;
  private count = 0;

  add(color: HueRGBColor): void {
    this.rTotal += color.r;
    this.gTotal += color.g;
    this.bTotal += color.b;
    this.saturationTotal += saturation(color);
    this.count += 1;
  }

  get averageColor(): HueRGBColor {
    if (this.count === 0) return { r: 0, g: 0, b: 0 };
    return {
      r: this.rTotal / this.count,
      g: this.gTotal / this.count,
      b: this.bTotal / this.count,
    };
  }

  get score(): number {
    return this.count
      * Math.max(this.saturationTotal / Math.max(this.count, 1), 0.1)
      * Math.max(brightness(this.averageColor), 0.1);
  }
}

function isUsefulAlbumColor(color: HueRGBColor): boolean {
  return brightness(color) >= 0.14 && saturation(color) >= 0.22;
}

function saturation(color: HueRGBColor): number {
  const maxComponent = brightness(color);
  const minComponent = Math.min(color.r, color.g, color.b);
  if (maxComponent <= 0) return 0;
  return (maxComponent - minComponent) / maxComponent;
}

function brightness(color: HueRGBColor): number {
  return Math.max(color.r, color.g, color.b);
}

function distance(a: HueRGBColor, b: HueRGBColor): number {
  const rDelta = a.r - b.r;
  const gDelta = a.g - b.g;
  const bDelta = a.b - b.b;
  return Math.sqrt(rDelta * rDelta + gDelta * gDelta + bDelta * bDelta);
}

function fallbackPaletteFromAlbumColors(colors: HueRGBColor[]): HueRGBColor[] {
  if (colors.length === 0) return [];

  const total = colors.reduce(
    (sum, color) => ({
      r: sum.r + color.r,
      g: sum.g + color.g,
      b: sum.b + color.b,
    }),
    { r: 0, g: 0, b: 0 },
  );
  return [readableLightColor({
    r: total.r / colors.length,
    g: total.g / colors.length,
    b: total.b / colors.length,
  })];
}

function readableLightColor(color: HueRGBColor): HueRGBColor {
  const maxComponent = brightness(color);
  if (maxComponent <= 0) return { r: 0.3, g: 0.3, b: 0.3 };

  const targetMax = Math.min(Math.max(maxComponent, 0.3), 0.82);
  const scale = targetMax / maxComponent;
  return {
    r: clamp(color.r * scale),
    g: clamp(color.g * scale),
    b: clamp(color.b * scale),
  };
}

function clamp(value: number): number {
  return Math.min(Math.max(value, 0), 1);
}
