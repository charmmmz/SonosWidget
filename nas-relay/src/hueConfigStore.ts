import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';

import type {
  HueAreaResource,
  HueAmbienceRuntimeConfig,
  HueAmbienceStatus,
  HueAmbienceTarget,
  HueEntertainmentChannelResource,
  HueLightResource,
  HueSonosMapping,
} from './hueTypes.js';

const DEFAULT_FILE_NAME = 'hue-ambience-config.json';

export class HueAmbienceConfigStore {
  private currentConfig: HueAmbienceRuntimeConfig | null = null;
  private readonly filePath: string;

  constructor(dataDir: string, filePath = process.env.HUE_AMBIENCE_CONFIG_PATH) {
    this.filePath = filePath && filePath.trim().length > 0
      ? filePath
      : path.join(dataDir, DEFAULT_FILE_NAME);
  }

  get configPath(): string {
    return this.filePath;
  }

  get current(): HueAmbienceRuntimeConfig | null {
    return this.currentConfig;
  }

  async load(): Promise<HueAmbienceRuntimeConfig | null> {
    try {
      const raw = await readFile(this.filePath, 'utf8');
      const parsed = JSON.parse(raw) as HueAmbienceRuntimeConfig;
      this.currentConfig = normalizeConfig(parsed);
      return this.currentConfig;
    } catch (err: any) {
      if (err?.code === 'ENOENT') {
        this.currentConfig = null;
        return null;
      }
      throw err;
    }
  }

  async save(config: HueAmbienceRuntimeConfig): Promise<void> {
    this.currentConfig = normalizeConfig(config);
    await mkdir(path.dirname(this.filePath), { recursive: true });
    await writeFile(this.filePath, `${JSON.stringify(this.currentConfig, null, 2)}\n`, 'utf8');
  }

  async clear(): Promise<void> {
    this.currentConfig = null;
    await rm(this.filePath, { force: true });
  }

  status(): HueAmbienceStatus {
    if (!this.currentConfig) {
      return { configured: false };
    }

    return {
      configured: true,
      enabled: this.currentConfig.enabled,
      bridge: this.currentConfig.bridge,
      mappings: this.currentConfig.mappings.length,
      lights: this.currentConfig.resources.lights.length,
      areas: this.currentConfig.resources.areas.length,
      motionStyle: this.currentConfig.motionStyle,
      stopBehavior: this.currentConfig.stopBehavior,
      renderMode: null,
      activeTargetIds: [],
      entertainmentTargetActive: false,
      entertainmentMetadataComplete: false,
      lastFrameAt: null,
    };
  }
}

function normalizeConfig(config: HueAmbienceRuntimeConfig): HueAmbienceRuntimeConfig {
  const flowIntervalSeconds = intervalOverride() ?? config.flowIntervalSeconds ?? 8;
  const lights = recordArray<HueLightResource>(config.resources?.lights);
  const areas = recordArray<HueAreaResource>(config.resources?.areas);
  const validLightIDs = new Set(lights.map(light => light.id));
  const validAreaTargets = new Set(areas.map(area => `${area.kind}:${area.id}`));
  const isValidTarget = (target?: HueAmbienceTarget | null): target is HueAmbienceTarget => {
    if (!target) return false;
    if (target.kind === 'light') return validLightIDs.has(target.id);
    return validAreaTargets.has(`${target.kind}:${target.id}`);
  };
  const isAssignableTarget = (target?: HueAmbienceTarget | null): target is HueAmbienceTarget => {
    return isValidTarget(target) && target.kind !== 'light';
  };
  const mappings: HueSonosMapping[] = [];
  for (const mapping of recordArray<HueSonosMapping>(config.mappings)) {
    const preferredTarget = isAssignableTarget(mapping.preferredTarget) ? mapping.preferredTarget : null;
    const fallbackTarget = isAssignableTarget(mapping.fallbackTarget) ? mapping.fallbackTarget : null;
    const resolvedPreferredTarget = preferredTarget ?? fallbackTarget;
    if (!resolvedPreferredTarget) continue;
    const isEntertainmentTarget = resolvedPreferredTarget.kind === 'entertainmentArea';

    mappings.push({
      ...mapping,
      preferredTarget: resolvedPreferredTarget,
      fallbackTarget: preferredTarget ? fallbackTarget : null,
      includedLightIDs: isEntertainmentTarget
        ? []
        : stringArray(mapping.includedLightIDs).filter(id => validLightIDs.has(id)),
      excludedLightIDs: isEntertainmentTarget
        ? []
        : stringArray(mapping.excludedLightIDs).filter(id => validLightIDs.has(id)),
    });
  }

  return {
    ...config,
    enabled: config.enabled && (process.env.HUE_AMBIENCE_ENABLED ?? 'true') !== 'false',
    resources: {
      lights,
      areas: areas.map(area => {
        const childLightIDs = stringArray(area.childLightIDs).filter(id => validLightIDs.has(id));
        const childLightIDSet = new Set(childLightIDs);
        return {
          ...area,
          childLightIDs,
          childDeviceIDs: stringArray(area.childDeviceIDs),
          entertainmentChannels: recordArray<HueEntertainmentChannelResource>(area.entertainmentChannels)
            .filter(channel => !channel.lightID || childLightIDSet.has(channel.lightID))
            .flatMap(channel => {
              const id = normalizeChannelID(channel.id);
              if (!id) return [];

              return [{
                id,
                lightID: channel.lightID ?? null,
                serviceID: channel.serviceID ?? null,
                position: channel.position ?? null,
              }];
            }),
        };
      }),
    },
    mappings,
    groupStrategy: config.groupStrategy ?? 'allMappedRooms',
    stopBehavior: config.stopBehavior ?? 'leaveCurrent',
    motionStyle: config.motionStyle ?? 'flowing',
    flowIntervalSeconds: Math.max(flowIntervalSeconds, 1),
  };
}

function asArray<T>(value: T[] | unknown): T[] {
  return Array.isArray(value) ? value : [];
}

function stringArray(value: unknown): string[] {
  return asArray<unknown>(value).filter((item): item is string => typeof item === 'string');
}

function recordArray<T>(value: T[] | unknown): T[] {
  return asArray<unknown>(value).filter(isRecord) as T[];
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function normalizeChannelID(value: unknown): string | null {
  if (typeof value !== 'string' && typeof value !== 'number') return null;

  const id = String(value);
  return id.length > 0 ? id : null;
}

function intervalOverride(): number | undefined {
  const raw = process.env.HUE_FLOW_INTERVAL_SECONDS;
  if (!raw || raw.trim().length === 0) return undefined;

  const value = Number(raw);
  return Number.isFinite(value) ? value : undefined;
}
