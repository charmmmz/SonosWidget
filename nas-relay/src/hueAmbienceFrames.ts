import { rotatePalette } from './huePalette.js';
import type {
  HueAmbienceFrameReason,
  HueAmbienceRenderMode,
  HueAreaResource,
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
}

export interface BuildHueAmbienceFrameInput {
  targets: HueResolvedAmbienceTarget[];
  snapshot: HueSnapshot;
  palette: HueRGBColor[];
  reason: HueAmbienceFrameReason;
  phase: number;
  transitionSeconds: number;
  now?: Date;
}

export function buildHueAmbienceFrame(input: BuildHueAmbienceFrameInput): HueAmbienceFrame {
  const palette = input.palette.length > 0 ? input.palette : [white];
  const progressOffset = playbackProgressOffset(input.snapshot, palette.length);
  const mode: HueAmbienceRenderMode = input.targets.some(target => target.area.kind === 'entertainmentArea')
    ? 'streamingReady'
    : 'clipFallback';
  const targetFrames = input.targets.map((target, targetIndex) => {
    const metadataComplete = entertainmentMetadataComplete(target.area);
    const spatialRanks = entertainmentSpatialRanks(target);
    return {
      area: target.area,
      lights: target.lights.map((light, lightIndex) =>
        buildLightFrame(
          light,
          target.area,
          palette,
          input.phase + progressOffset + targetIndex + (spatialRanks?.get(light.id) ?? lightIndex),
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

function entertainmentSpatialRanks(target: HueResolvedAmbienceTarget): Map<string, number> | null {
  if (target.area.kind !== 'entertainmentArea') return null;

  const channelsByLightID = new Map(
    (target.area.entertainmentChannels ?? [])
      .filter(channel => channel.lightID)
      .map(channel => [channel.lightID!, channel]),
  );
  const positionedLights = target.lights.map(light => {
    const channel = channelsByLightID.get(light.id);
    const position = channel?.position;
    if (
      !position
      || !Number.isFinite(position.x)
      || !Number.isFinite(position.y)
      || !Number.isFinite(position.z)
    ) {
      return null;
    }

    return { lightID: light.id, position };
  });

  if (positionedLights.some(light => light === null)) return null;

  return new Map(
    positionedLights
      .filter((light): light is NonNullable<typeof light> => light !== null)
      .sort((a, b) =>
        a.position.x - b.position.x
        || a.position.z - b.position.z
        || a.position.y - b.position.y
        || a.lightID.localeCompare(b.lightID),
      )
      .map((light, index) => [light.lightID, index]),
  );
}

function buildLightFrame(
  light: HueLightResource,
  area: HueAreaResource,
  palette: HueRGBColor[],
  offset: number,
): HueAmbienceLightFrame {
  const colors = rotatePalette(palette, offset).slice(0, light.supportsGradient ? 5 : 1);
  const channelID = area.entertainmentChannels?.find(channel => channel.lightID === light.id)?.id;

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
