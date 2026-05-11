import { brightness, rgbToXy, rotatePalette } from './huePalette.js';
import type {
  HueAmbienceRuntimeConfig,
  HueLightResource,
  HueRGBColor,
  HueResolvedAmbienceTarget,
  HueSnapshot,
  HueSonosMapping,
  HueLightClient,
} from './hueTypes.js';

export interface HueLightUpdateBody {
  on: { on: boolean };
  dimming?: { brightness: number };
  color?: { xy: { x: number; y: number } };
  gradient?: { points: Array<{ color: { xy: { x: number; y: number } } }> };
  dynamics: { duration: number };
}

export function shouldUseLightForAmbience(
  light: HueLightResource,
  mapping: HueSonosMapping,
): boolean {
  if (mapping.excludedLightIDs.includes(light.id)) {
    return false;
  }
  if (mapping.includedLightIDs.includes(light.id)) {
    return true;
  }
  return light.functionMetadataResolved && light.function !== 'functional';
}

export function resolveHueTargets(
  config: HueAmbienceRuntimeConfig,
  snapshot: HueSnapshot,
): HueResolvedAmbienceTarget[] {
  const lightsByID = new Map(config.resources.lights.map(light => [light.id, light]));
  const seenAreaIDs = new Set<string>();

  return config.mappings
    .filter(mapping => mappingMatchesSnapshot(mapping, snapshot))
    .flatMap(mapping => {
      const area = resolveArea(config, mapping.preferredTarget) ?? resolveArea(config, mapping.fallbackTarget);
      if (!area || seenAreaIDs.has(area.id)) return [];
      seenAreaIDs.add(area.id);

      const lights = area.childLightIDs
        .map(id => lightsByID.get(id))
        .filter((light): light is HueLightResource => Boolean(light))
        .filter(light => lightBelongsToAreaDevice(light, area, mapping))
        .filter(light => light.supportsColor)
        .filter(light => area.kind === 'light' || shouldUseLightForAmbience(light, mapping));

      if (lights.length === 0) return [];
      return [{ area, mapping, lights }];
    });
}

export function buildHueLightBody(
  light: HueLightResource,
  palette: HueRGBColor[],
  transitionSeconds: number,
): HueLightUpdateBody {
  const duration = Math.round(Math.max(transitionSeconds, 0.1) * 1000);
  if (light.supportsGradient && palette.length > 1) {
    const points = palette.slice(0, 5).map(color => ({ color: colorJSON(color) }));
    return {
      on: { on: true },
      dimming: { brightness: Math.max(...palette.map(color => brightness(color) * 100)) },
      gradient: { points },
      dynamics: { duration },
    };
  }

  return {
    on: { on: true },
    dimming: { brightness: brightness(palette[0] ?? { r: 1, g: 1, b: 1 }) * 100 },
    color: colorJSON(palette[0] ?? { r: 1, g: 1, b: 1 }),
    dynamics: { duration },
  };
}

export async function applyHuePalette(
  client: HueLightClient,
  targets: HueResolvedAmbienceTarget[],
  palette: HueRGBColor[],
  transitionSeconds: number,
): Promise<void> {
  let lightOffset = 0;
  for (const target of targets) {
    for (const light of target.lights) {
      const body = buildHueLightBody(light, rotatePalette(palette, lightOffset), transitionSeconds);
      await client.updateLight(light.id, body);
      lightOffset += 1;
    }
  }
}

export async function stopHueTargets(
  client: HueLightClient,
  targets: HueResolvedAmbienceTarget[],
): Promise<void> {
  for (const target of targets) {
    for (const light of target.lights) {
      await client.updateLight(light.id, {
        on: { on: false },
        dynamics: { duration: 1200 },
      });
    }
  }
}

function mappingMatchesSnapshot(mapping: HueSonosMapping, snapshot: HueSnapshot): boolean {
  return mapping.relayGroupID === snapshot.groupId
    || mapping.sonosID === snapshot.groupId
    || mapping.sonosName === snapshot.speakerName;
}

function resolveArea(
  config: HueAmbienceRuntimeConfig,
  target: HueSonosMapping['preferredTarget'],
) {
  if (!target) return undefined;
  if (target.kind === 'light') {
    const light = config.resources.lights.find(candidate => candidate.id === target.id);
    if (!light) return undefined;
    return {
      id: light.id,
      name: light.name,
      kind: 'light' as const,
      childLightIDs: [light.id],
      childDeviceIDs: light.ownerID ? [light.ownerID] : [],
    };
  }
  return config.resources.areas.find(area => area.id === target.id && area.kind === target.kind)
    ?? config.resources.areas.find(area => area.id === target.id);
}

function lightBelongsToAreaDevice(
  light: HueLightResource,
  area: { kind?: string; childDeviceIDs?: string[] },
  mapping: HueSonosMapping,
): boolean {
  if (area.kind === 'light' || mapping.includedLightIDs.includes(light.id)) {
    return true;
  }

  const childDeviceIDs = area.childDeviceIDs ?? [];
  if (childDeviceIDs.length === 0) return !light.ownerID;
  if (!light.ownerID) return false;
  return childDeviceIDs.includes(light.ownerID);
}

function colorJSON(color: HueRGBColor): { xy: { x: number; y: number } } {
  const xy = rgbToXy(color);
  return { xy: { x: xy.x, y: xy.y } };
}
