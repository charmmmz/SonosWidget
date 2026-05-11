import type { SonosGroupSnapshot } from './types.js';

export type HueAmbienceTargetKind = 'entertainmentArea' | 'room' | 'zone' | 'light';
export type HueAmbienceCapability = 'basic' | 'gradientReady' | 'liveEntertainment';
export type HueGroupSyncStrategy = 'allMappedRooms' | 'coordinatorOnly';
export type HueAmbienceStopBehavior = 'leaveCurrent' | 'turnOff';
export type HueAmbienceMotionStyle = 'flowing' | 'still';
export type HueLightFunction = 'decorative' | 'functional' | 'mixed' | 'unknown';

export interface HueBridgeInfo {
  id: string;
  ipAddress: string;
  name: string;
}

export interface HueAmbienceTarget {
  kind: HueAmbienceTargetKind;
  id: string;
}

export interface HueSonosMapping {
  sonosID: string;
  sonosName: string;
  relayGroupID?: string | null;
  preferredTarget?: HueAmbienceTarget | null;
  fallbackTarget?: HueAmbienceTarget | null;
  includedLightIDs: string[];
  excludedLightIDs: string[];
  capability: HueAmbienceCapability;
}

export interface HueLightResource {
  id: string;
  name: string;
  ownerID?: string | null;
  supportsColor: boolean;
  supportsGradient: boolean;
  supportsEntertainment: boolean;
  function: HueLightFunction;
  functionMetadataResolved: boolean;
}

export interface HueAreaResource {
  id: string;
  name: string;
  kind: HueAmbienceTargetKind;
  childLightIDs: string[];
  childDeviceIDs?: string[];
}

export interface HueBridgeResources {
  lights: HueLightResource[];
  areas: HueAreaResource[];
}

export interface HueAmbienceRuntimeConfig {
  enabled: boolean;
  bridge: HueBridgeInfo;
  applicationKey: string;
  resources: HueBridgeResources;
  mappings: HueSonosMapping[];
  groupStrategy: HueGroupSyncStrategy;
  stopBehavior: HueAmbienceStopBehavior;
  motionStyle: HueAmbienceMotionStyle;
  flowIntervalSeconds: number;
}

export interface HueRGBColor {
  r: number;
  g: number;
  b: number;
}

export interface HueXYColor {
  x: number;
  y: number;
}

export interface HueResolvedAmbienceTarget {
  area: HueAreaResource;
  mapping: HueSonosMapping;
  lights: HueLightResource[];
}

export interface HueAmbienceStatus {
  configured: boolean;
  enabled?: boolean;
  bridge?: HueBridgeInfo;
  mappings?: number;
  lights?: number;
  areas?: number;
  motionStyle?: HueAmbienceMotionStyle;
  stopBehavior?: HueAmbienceStopBehavior;
  activeGroupId?: string | null;
  lastError?: string | null;
}

export interface HueAmbienceServiceStatus extends HueAmbienceStatus {
  runtimeActive: boolean;
  lastTrackKey?: string | null;
}

export interface HueLightClient {
  updateLight(id: string, body: unknown): Promise<void>;
}

export type HueSnapshot = SonosGroupSnapshot;
