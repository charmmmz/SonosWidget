import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';

import type {
  HueAmbienceRuntimeConfig,
  HueAmbienceStatus,
  HueAmbienceTarget,
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
    };
  }
}

function normalizeConfig(config: HueAmbienceRuntimeConfig): HueAmbienceRuntimeConfig {
  const flowIntervalSeconds = intervalOverride() ?? config.flowIntervalSeconds ?? 8;
  const validLightIDs = new Set((config.resources?.lights ?? []).map(light => light.id));
  const validAreaTargets = new Set((config.resources?.areas ?? []).map(area => `${area.kind}:${area.id}`));
  const isValidTarget = (target?: HueAmbienceTarget | null): target is HueAmbienceTarget => {
    if (!target) return false;
    if (target.kind === 'light') return validLightIDs.has(target.id);
    return validAreaTargets.has(`${target.kind}:${target.id}`);
  };
  const mappings: HueSonosMapping[] = [];
  for (const mapping of config.mappings ?? []) {
    const preferredTarget = isValidTarget(mapping.preferredTarget) ? mapping.preferredTarget : null;
    const fallbackTarget = isValidTarget(mapping.fallbackTarget) ? mapping.fallbackTarget : null;
    const resolvedPreferredTarget = preferredTarget ?? fallbackTarget;
    if (!resolvedPreferredTarget) continue;

    mappings.push({
      ...mapping,
      preferredTarget: resolvedPreferredTarget,
      fallbackTarget: preferredTarget ? fallbackTarget : null,
      includedLightIDs: (mapping.includedLightIDs ?? []).filter(id => validLightIDs.has(id)),
      excludedLightIDs: (mapping.excludedLightIDs ?? []).filter(id => validLightIDs.has(id)),
    });
  }

  return {
    ...config,
    enabled: config.enabled && (process.env.HUE_AMBIENCE_ENABLED ?? 'true') !== 'false',
    resources: {
      lights: config.resources?.lights ?? [],
      areas: (config.resources?.areas ?? []).map(area => ({
        ...area,
        childLightIDs: (area.childLightIDs ?? []).filter(id => validLightIDs.has(id)),
        childDeviceIDs: area.childDeviceIDs ?? [],
      })),
    },
    mappings,
    groupStrategy: config.groupStrategy ?? 'allMappedRooms',
    stopBehavior: config.stopBehavior ?? 'leaveCurrent',
    motionStyle: config.motionStyle ?? 'flowing',
    flowIntervalSeconds: Math.max(flowIntervalSeconds, 1),
  };
}

function intervalOverride(): number | undefined {
  const raw = process.env.HUE_FLOW_INTERVAL_SECONDS;
  if (!raw || raw.trim().length === 0) return undefined;

  const value = Number(raw);
  return Number.isFinite(value) ? value : undefined;
}
