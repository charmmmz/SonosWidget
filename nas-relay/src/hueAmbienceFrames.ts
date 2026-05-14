import { rotatePalette } from './huePalette.js';
import type {
  HueAmbienceFrameReason,
  HueAmbienceRenderMode,
  HueAreaResource,
  HueEntertainmentChannelResource,
  HueLightResource,
  HueRGBColor,
  HueResolvedAmbienceTarget,
  HueSnapshot,
} from './hueTypes.js';

const white: HueRGBColor = { r: 1, g: 1, b: 1 };

export interface HueAmbienceLightFrame {
  light: HueLightResource;
  colors: HueRGBColor[];
  channelID?: string | null;
}

export interface HueAmbienceTargetFrame {
  area: HueAreaResource;
  lights: HueAmbienceLightFrame[];
  metadataComplete: boolean;
}

export interface HueAmbienceFrame {
  mode: HueAmbienceRenderMode;
  targets: HueAmbienceTargetFrame[];
  transitionSeconds: number;
  reason: HueAmbienceFrameReason;
  createdAt: Date;
  metadataComplete: boolean;
  phase: number;
  progressOffset: number;
  effect?: HueAmbienceFrameEffect;
}

export interface HueAmbienceFrameEffect {
  source: string;
  reason: string;
  effectKey?: string;
  mode?: string;
  transitionSeconds?: number;
  attackSeconds?: number;
  holdSeconds?: number;
  fadeSeconds?: number;
  effectPhase?: string;
  cadenceMs?: number;
  remainingMs?: number;
  strength?: number;
}

export interface BuildHueAmbienceFrameInput {
  targets: HueResolvedAmbienceTarget[];
  snapshot: HueSnapshot;
  palette: HueRGBColor[];
  reason: HueAmbienceFrameReason;
  phase: number;
  transitionSeconds: number;
  now?: Date;
  effect?: HueAmbienceFrameEffect;
}

interface LightFrameSource {
  light: HueLightResource;
  channelID?: string | null;
  offsetIndex: number;
}

export function buildHueAmbienceFrame(input: BuildHueAmbienceFrameInput): HueAmbienceFrame {
  const palette = input.palette.length > 0 ? input.palette : [white];
  const progressOffset = playbackProgressOffset(input.snapshot, palette.length);
  const mode: HueAmbienceRenderMode = input.targets.some(target => target.area.kind === 'entertainmentArea')
    ? 'streamingReady'
    : 'clipFallback';
  const targetFrames = input.targets.map((target, targetIndex) => {
    const metadataComplete = entertainmentMetadataComplete(target.area);
    const frameSources = lightFrameSources(target);
    return {
      area: target.area,
      lights: frameSources.map(source =>
        buildLightFrame(
          source.light,
          target.area,
          palette,
          input.phase + progressOffset + targetIndex + source.offsetIndex,
          source.channelID,
        ),
      ),
      metadataComplete,
    };
  });
  const entertainmentTargetFrames = targetFrames.filter(target => target.area.kind === 'entertainmentArea');

  return {
    mode,
    targets: targetFrames,
    transitionSeconds: input.transitionSeconds,
    reason: input.reason,
    createdAt: input.now ?? new Date(),
    metadataComplete: entertainmentTargetFrames.length > 0
      && entertainmentTargetFrames.every(target => target.metadataComplete),
    phase: input.phase,
    progressOffset,
    ...(input.effect ? { effect: input.effect } : {}),
  };
}

export function entertainmentMetadataComplete(area: HueAreaResource): boolean {
  if (area.kind !== 'entertainmentArea') return false;
  const channelLightIDs = new Set(
    (area.entertainmentChannels ?? [])
      .map(channel => channel.lightID)
      .filter((lightID): lightID is string => typeof lightID === 'string' && lightID.length > 0),
  );

  return area.childLightIDs.length > 0 && area.childLightIDs.every(lightID => channelLightIDs.has(lightID));
}

function lightFrameSources(target: HueResolvedAmbienceTarget): LightFrameSource[] {
  if (target.area.kind !== 'entertainmentArea') {
    return target.lights.map((light, index) => ({ light, offsetIndex: index }));
  }

  const lightsByID = new Map(target.lights.map(light => [light.id, light]));
  const channelSources = (target.area.entertainmentChannels ?? [])
    .map((channel, index) => {
      const light = channel.lightID ? lightsByID.get(channel.lightID) : undefined;
      return light ? { light, channel, fallbackIndex: index } : null;
    })
    .filter((source): source is {
      light: HueLightResource;
      channel: HueEntertainmentChannelResource;
      fallbackIndex: number;
    } => source !== null);

  if (channelSources.length === 0) {
    return target.lights.map((light, index) => ({ light, offsetIndex: index }));
  }

  const spatialRanks = entertainmentChannelSpatialRanks(channelSources);
  return channelSources.map(source => ({
    light: source.light,
    channelID: source.channel.id,
    offsetIndex: spatialRanks?.get(source.channel.id) ?? source.fallbackIndex,
  }));
}

function entertainmentChannelSpatialRanks(
  channelSources: Array<{
    channel: HueEntertainmentChannelResource;
  }>,
): Map<string, number> | null {
  const positionedChannels = channelSources.map(source => {
    const position = source.channel.position;
    if (
      !position
      || !Number.isFinite(position.x)
      || !Number.isFinite(position.y)
      || !Number.isFinite(position.z)
    ) {
      return null;
    }

    return { channelID: source.channel.id, position };
  });

  if (positionedChannels.some(channel => channel === null)) return null;

  return new Map(
    positionedChannels
      .filter((channel): channel is NonNullable<typeof channel> => channel !== null)
      .sort((a, b) =>
        a.position.x - b.position.x
        || a.position.z - b.position.z
        || a.position.y - b.position.y
        || a.channelID.localeCompare(b.channelID),
      )
      .map((channel, index) => [channel.channelID, index]),
  );
}

function buildLightFrame(
  light: HueLightResource,
  area: HueAreaResource,
  palette: HueRGBColor[],
  offset: number,
  channelIDOverride?: string | null,
): HueAmbienceLightFrame {
  const colors = rotatePalette(palette, offset).slice(0, light.supportsGradient ? 5 : 1);
  const channelID = channelIDOverride ?? area.entertainmentChannels?.find(channel => channel.lightID === light.id)?.id;

  return {
    light,
    ...(channelID ? { channelID } : {}),
    colors,
  };
}

function playbackProgressOffset(snapshot: HueSnapshot, paletteLength: number): number {
  if (paletteLength <= 0 || snapshot.durationSeconds <= 0 || snapshot.positionSeconds < 0) return 0;
  const progress = Math.min(Math.max(snapshot.positionSeconds / snapshot.durationSeconds, 0), 1);
  return Math.floor(progress * paletteLength) % paletteLength;
}
