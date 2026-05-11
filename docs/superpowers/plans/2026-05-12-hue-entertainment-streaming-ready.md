# Hue Entertainment Streaming-Ready Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the NAS-side streaming-ready Music Ambience renderer, keep CLIP v2 as the active transport, and expose honest runtime status in iOS.

**Architecture:** Split NAS Music Ambience into service, effect frame engine, and renderer layers. The effect engine emits transport-independent frames from Sonos snapshots, Hue targets, album palettes, and motion settings; the first renderer maps those frames to existing CLIP v2 light updates. iOS remains the setup surface and decodes relay status instead of claiming true Entertainment streaming.

**Tech Stack:** TypeScript on Node 24-compatible `nas-relay`, Node test runner with `tsx`, Swift/SwiftUI shared app code, XCTest focused iOS tests.

---

## File Structure

- Create `nas-relay/src/hueAmbienceFrames.ts`
  - Defines `HueAmbienceFrame`, per-light frame state, render mode, runtime status helpers, and effect engine functions.
- Create `nas-relay/src/hueFrameRenderer.ts`
  - Defines the renderer interface and the CLIP fallback renderer that consumes frames.
- Modify `nas-relay/src/hueTypes.ts`
  - Adds optional Entertainment channel metadata and expanded relay status fields.
- Modify `nas-relay/src/hueRenderer.ts`
  - Keeps target resolution and light body helpers. Moves palette application callers to the new frame renderer without changing filtering behavior.
- Modify `nas-relay/src/hueAmbienceService.ts`
  - Selects render mode, uses the frame engine, tracks frame timestamps/status, and preserves stop behavior.
- Modify `nas-relay/src/hueConfigStore.ts`
  - Normalizes optional channel metadata and reports base status without leaking Hue application keys.
- Add `nas-relay/src/hueAmbienceFrames.test.ts`
  - Tests spatial palette, motion phase, progress phase, gradient frame generation, and channel completeness.
- Add `nas-relay/src/hueFrameRenderer.test.ts`
  - Tests CLIP fallback frame application and stop frames.
- Modify `nas-relay/src/hueAmbienceService.test.ts`
  - Tests renderer selection, runtime status, pending start cancellation, and stop behavior through the new renderer interface.
- Modify `nas-relay/src/hueConfigStore.test.ts`
  - Tests backward-compatible config normalization and status fields.
- Modify `Shared/HueAmbienceModels.swift`
  - Adds Codable Entertainment channel metadata and refined runtime status labels.
- Modify `Shared/HueBridgeClient.swift`
  - Parses optional Entertainment channel metadata while preserving existing child light/device extraction.
- Modify `Shared/HueAmbienceRelayConfig.swift`
  - Sends channel metadata to NAS and decodes expanded status.
- Modify `Shared/RelayClient.swift`
  - Adds expanded `/api/health` Hue ambience fields.
- Modify `Shared/RelayManager.swift`
  - Stores relay render mode/status and keeps local rendering deferral behavior unchanged.
- Modify `SonosWidget/MusicAmbienceSettingsView.swift`
  - Replaces static Live Entertainment copy with NAS runtime status.
- Modify tests:
  - `SonosWidgetTests/HueAmbienceRelayConfigTests.swift`
  - `SonosWidgetTests/HueAmbienceStoreTests.swift`
  - `SonosWidgetTests/RelayManagerTests.swift`
  - `SonosWidgetTests/MusicAmbienceManagerTests.swift`

## Task 1: Add NAS Frame Types And Effect Engine

**Files:**
- Create: `nas-relay/src/hueAmbienceFrames.ts`
- Test: `nas-relay/src/hueAmbienceFrames.test.ts`
- Modify: `nas-relay/src/hueTypes.ts`

- [ ] **Step 1: Write failing frame tests**

Create `nas-relay/src/hueAmbienceFrames.test.ts`:

```ts
import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  buildHueAmbienceFrame,
  entertainmentMetadataComplete,
} from './hueAmbienceFrames.js';
import type {
  HueAreaResource,
  HueRGBColor,
  HueResolvedAmbienceTarget,
  HueSnapshot,
} from './hueTypes.js';

const palette: HueRGBColor[] = [
  { r: 1, g: 0, b: 0 },
  { r: 0, g: 1, b: 0 },
  { r: 0, g: 0, b: 1 },
];

test('frame engine distributes album palette across lights', () => {
  const frame = buildHueAmbienceFrame({
    targets: [target()],
    palette,
    snapshot: snapshot({ positionSeconds: 0 }),
    phase: 0,
    transitionSeconds: 4,
    reason: 'steady',
  });

  assert.equal(frame.mode, 'streamingReady');
  assert.deepEqual(frame.targets[0]!.lights.map(light => light.light.id), ['light-a', 'light-b']);
  assert.deepEqual(frame.targets[0]!.lights[0]!.colors, [palette[0], palette[1], palette[2]]);
  assert.deepEqual(frame.targets[0]!.lights[1]!.colors, [palette[1], palette[2], palette[0]]);
});

test('frame engine advances palette phase from playback progress', () => {
  const first = buildHueAmbienceFrame({
    targets: [target()],
    palette,
    snapshot: snapshot({ positionSeconds: 0, durationSeconds: 120 }),
    phase: 0,
    transitionSeconds: 4,
    reason: 'steady',
  });
  const later = buildHueAmbienceFrame({
    targets: [target()],
    palette,
    snapshot: snapshot({ positionSeconds: 40, durationSeconds: 120 }),
    phase: 0,
    transitionSeconds: 4,
    reason: 'steady',
  });

  assert.notDeepEqual(later.targets[0]!.lights[0]!.colors, first.targets[0]!.lights[0]!.colors);
});

test('gradient-capable lights keep multiple colors while basic lights keep one', () => {
  const frame = buildHueAmbienceFrame({
    targets: [target()],
    palette,
    snapshot: snapshot({ positionSeconds: 0 }),
    phase: 1,
    transitionSeconds: 6,
    reason: 'trackChange',
  });

  assert.equal(frame.targets[0]!.lights[0]!.colors.length, 3);
  assert.equal(frame.targets[0]!.lights[1]!.colors.length, 1);
  assert.equal(frame.reason, 'trackChange');
  assert.equal(frame.transitionSeconds, 6);
});

test('entertainment metadata completeness requires channels for entertainment areas', () => {
  assert.equal(entertainmentMetadataComplete(target().area), true);
  assert.equal(entertainmentMetadataComplete({ ...target().area, entertainmentChannels: [] }), false);
  assert.equal(entertainmentMetadataComplete({ ...target().area, kind: 'room', entertainmentChannels: [] }), false);
});

function target(area: Partial<HueAreaResource> = {}): HueResolvedAmbienceTarget {
  return {
    area: {
      id: 'ent-1',
      name: 'Playroom Area',
      kind: 'entertainmentArea',
      childLightIDs: ['light-a', 'light-b'],
      childDeviceIDs: ['device-a', 'device-b'],
      entertainmentChannels: [
        { id: '0', lightID: 'light-a', serviceID: 'svc-a' },
        { id: '1', lightID: 'light-b', serviceID: 'svc-b' },
      ],
      ...area,
    },
    mapping: {
      sonosID: 'playroom',
      sonosName: 'Playroom',
      relayGroupID: '192.168.50.25',
      preferredTarget: { kind: 'entertainmentArea', id: 'ent-1' },
      fallbackTarget: null,
      includedLightIDs: [],
      excludedLightIDs: [],
      capability: 'liveEntertainment',
    },
    lights: [
      {
        id: 'light-a',
        name: 'Gradient Strip',
        ownerID: 'device-a',
        supportsColor: true,
        supportsGradient: true,
        supportsEntertainment: true,
        function: 'decorative',
        functionMetadataResolved: true,
      },
      {
        id: 'light-b',
        name: 'Lamp',
        ownerID: 'device-b',
        supportsColor: true,
        supportsGradient: false,
        supportsEntertainment: true,
        function: 'decorative',
        functionMetadataResolved: true,
      },
    ],
  };
}

function snapshot(overrides: Partial<HueSnapshot>): HueSnapshot {
  return {
    groupId: '192.168.50.25',
    speakerName: 'Playroom',
    trackTitle: 'Who Knows',
    artist: 'Daniel Caesar',
    album: 'Pilgrim',
    albumArtUri: '/art.jpg',
    isPlaying: true,
    positionSeconds: 0,
    durationSeconds: 180,
    groupMemberCount: 1,
    sampledAt: new Date('2026-05-12T00:00:00Z'),
    ...overrides,
  };
}
```

- [ ] **Step 2: Run frame tests and verify they fail**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree/nas-relay
npm test -- --test-name-pattern="frame engine|entertainment metadata"
```

Expected: FAIL because `./hueAmbienceFrames.js` does not exist and `HueAreaResource.entertainmentChannels` is not typed.

- [ ] **Step 3: Extend NAS Hue types**

In `nas-relay/src/hueTypes.ts`, add these types and fields:

```ts
export type HueAmbienceRenderMode = 'clipFallback' | 'streamingReady';
export type HueAmbienceFrameReason = 'steady' | 'trackChange' | 'pause' | 'stop' | 'disable';

export interface HueEntertainmentChannelResource {
  id: string;
  lightID?: string | null;
  serviceID?: string | null;
  position?: {
    x: number;
    y: number;
    z: number;
  } | null;
}

export interface HueAreaResource {
  id: string;
  name: string;
  kind: HueAmbienceTargetKind;
  childLightIDs: string[];
  childDeviceIDs?: string[];
  entertainmentChannels?: HueEntertainmentChannelResource[];
}
```

Extend status interfaces:

```ts
export interface HueAmbienceStatus {
  configured: boolean;
  enabled?: boolean;
  bridge?: HueBridgeInfo;
  mappings?: number;
  lights?: number;
  areas?: number;
  motionStyle?: HueAmbienceMotionStyle;
  stopBehavior?: HueAmbienceStopBehavior;
  renderMode?: HueAmbienceRenderMode | null;
  activeGroupId?: string | null;
  activeTargetIds?: string[];
  entertainmentTargetActive?: boolean;
  entertainmentMetadataComplete?: boolean;
  lastFrameAt?: string | null;
  lastError?: string | null;
}
```

- [ ] **Step 4: Implement the frame engine**

Create `nas-relay/src/hueAmbienceFrames.ts`:

```ts
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

export interface HueAmbienceLightFrame {
  light: HueLightResource;
  colors: HueRGBColor[];
  channelID?: string | null;
}

export interface HueAmbienceTargetFrame {
  area: HueAreaResource;
  lights: HueAmbienceLightFrame[];
}

export interface HueAmbienceFrame {
  mode: HueAmbienceRenderMode;
  targets: HueAmbienceTargetFrame[];
  transitionSeconds: number;
  reason: HueAmbienceFrameReason;
  createdAt: Date;
  metadataComplete: boolean;
}

export interface BuildHueAmbienceFrameInput {
  targets: HueResolvedAmbienceTarget[];
  palette: HueRGBColor[];
  snapshot: HueSnapshot;
  phase: number;
  transitionSeconds: number;
  reason: HueAmbienceFrameReason;
  now?: Date;
}

export function buildHueAmbienceFrame(input: BuildHueAmbienceFrameInput): HueAmbienceFrame {
  const normalizedPalette = input.palette.length > 0
    ? input.palette
    : [{ r: 1, g: 1, b: 1 }];
  const progressOffset = progressPaletteOffset(input.snapshot, normalizedPalette.length);
  const mode = input.targets.some(target => target.area.kind === 'entertainmentArea')
    ? 'streamingReady'
    : 'clipFallback';

  return {
    mode,
    targets: input.targets.map((target, targetIndex) => ({
      area: target.area,
      lights: target.lights.map((light, lightIndex) => {
        const offset = input.phase + progressOffset + targetIndex + lightIndex;
        const colors = rotatePalette(normalizedPalette, offset);
        const channel = channelForLight(target.area, light.id);
        return {
          light,
          colors: light.supportsGradient ? colors.slice(0, 5) : colors.slice(0, 1),
          channelID: channel?.id ?? null,
        };
      }),
    })),
    transitionSeconds: input.transitionSeconds,
    reason: input.reason,
    createdAt: input.now ?? new Date(),
    metadataComplete: input.targets.every(target => entertainmentMetadataComplete(target.area)),
  };
}

export function entertainmentMetadataComplete(area: HueAreaResource): boolean {
  if (area.kind !== 'entertainmentArea') {
    return false;
  }
  const channels = area.entertainmentChannels ?? [];
  if (channels.length === 0) {
    return false;
  }
  const channelLightIDs = new Set(channels.map(channel => channel.lightID).filter(Boolean));
  return area.childLightIDs.every(lightID => channelLightIDs.has(lightID));
}

function progressPaletteOffset(snapshot: HueSnapshot, paletteLength: number): number {
  if (paletteLength <= 1 || snapshot.durationSeconds <= 0 || snapshot.positionSeconds <= 0) {
    return 0;
  }
  const ratio = Math.max(0, Math.min(snapshot.positionSeconds / snapshot.durationSeconds, 1));
  return Math.floor(ratio * paletteLength);
}

function channelForLight(area: HueAreaResource, lightID: string) {
  return area.entertainmentChannels?.find(channel => channel.lightID === lightID);
}
```

- [ ] **Step 5: Run frame tests and typecheck**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree/nas-relay
npm test -- --test-name-pattern="frame engine|entertainment metadata"
npm run build
```

Expected: PASS for the new frame tests, and `tsc` exits 0.

- [ ] **Step 6: Commit Task 1**

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree
git add nas-relay/src/hueTypes.ts nas-relay/src/hueAmbienceFrames.ts nas-relay/src/hueAmbienceFrames.test.ts
git commit -m "feat: add hue ambience frame engine"
```

## Task 2: Add CLIP Frame Renderer

**Files:**
- Create: `nas-relay/src/hueFrameRenderer.ts`
- Test: `nas-relay/src/hueFrameRenderer.test.ts`
- Modify: `nas-relay/src/hueRenderer.ts`

- [ ] **Step 1: Write failing renderer tests**

Create `nas-relay/src/hueFrameRenderer.test.ts`:

```ts
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ClipHueAmbienceRenderer } from './hueFrameRenderer.js';
import type { HueAmbienceFrame } from './hueAmbienceFrames.js';
import type { HueLightClient } from './hueTypes.js';

test('CLIP frame renderer applies per-light frame colors', async () => {
  const client = new RecordingHueLightClient();
  const renderer = new ClipHueAmbienceRenderer(client);

  await renderer.render(frame());

  assert.equal(client.updates.length, 2);
  assert.equal(client.updates[0]!.id, 'gradient-light');
  assert.equal((client.updates[0]!.body as any).gradient.points.length, 2);
  assert.equal(client.updates[1]!.id, 'basic-light');
  assert.equal((client.updates[1]!.body as any).gradient, undefined);
  assert.equal((client.updates[1]!.body as any).dynamics.duration, 4000);
});

test('CLIP frame renderer can turn off frame lights', async () => {
  const client = new RecordingHueLightClient();
  const renderer = new ClipHueAmbienceRenderer(client);

  await renderer.stop(frame());

  assert.deepEqual(client.updates.map(update => update.body), [
    { on: { on: false }, dynamics: { duration: 1200 } },
    { on: { on: false }, dynamics: { duration: 1200 } },
  ]);
});

function frame(): HueAmbienceFrame {
  return {
    mode: 'streamingReady',
    transitionSeconds: 4,
    reason: 'steady',
    createdAt: new Date('2026-05-12T00:00:00Z'),
    metadataComplete: true,
    targets: [
      {
        area: {
          id: 'ent-1',
          name: 'Area',
          kind: 'entertainmentArea',
          childLightIDs: ['gradient-light', 'basic-light'],
          entertainmentChannels: [
            { id: '0', lightID: 'gradient-light' },
            { id: '1', lightID: 'basic-light' },
          ],
        },
        lights: [
          {
            light: {
              id: 'gradient-light',
              name: 'Gradient',
              supportsColor: true,
              supportsGradient: true,
              supportsEntertainment: true,
              function: 'decorative',
              functionMetadataResolved: true,
            },
            colors: [
              { r: 1, g: 0, b: 0 },
              { r: 0, g: 1, b: 0 },
            ],
            channelID: '0',
          },
          {
            light: {
              id: 'basic-light',
              name: 'Lamp',
              supportsColor: true,
              supportsGradient: false,
              supportsEntertainment: true,
              function: 'decorative',
              functionMetadataResolved: true,
            },
            colors: [{ r: 0, g: 0, b: 1 }],
            channelID: '1',
          },
        ],
      },
    ],
  };
}

class RecordingHueLightClient implements HueLightClient {
  updates: Array<{ id: string; body: unknown }> = [];

  async updateLight(id: string, body: unknown): Promise<void> {
    this.updates.push({ id, body });
  }
}
```

- [ ] **Step 2: Run renderer tests and verify they fail**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree/nas-relay
npm test -- --test-name-pattern="CLIP frame renderer"
```

Expected: FAIL because `./hueFrameRenderer.js` does not exist.

- [ ] **Step 3: Export reusable stop body duration from `hueRenderer.ts`**

Keep existing `buildHueLightBody` intact. Add this helper:

```ts
export function buildHueLightOffBody(): { on: { on: false }; dynamics: { duration: number } } {
  return {
    on: { on: false },
    dynamics: { duration: 1200 },
  };
}
```

Change `stopHueTargets` to use `buildHueLightOffBody()` so old tests and new frame renderer share the same behavior.

- [ ] **Step 4: Implement the renderer interface and CLIP fallback renderer**

Create `nas-relay/src/hueFrameRenderer.ts`:

```ts
import type { HueAmbienceFrame } from './hueAmbienceFrames.js';
import { buildHueLightBody, buildHueLightOffBody } from './hueRenderer.js';
import type { HueLightClient } from './hueTypes.js';

export interface HueAmbienceRenderer {
  render(frame: HueAmbienceFrame): Promise<void>;
  stop(frame: HueAmbienceFrame): Promise<void>;
}

export class ClipHueAmbienceRenderer implements HueAmbienceRenderer {
  constructor(private readonly client: HueLightClient) {}

  async render(frame: HueAmbienceFrame): Promise<void> {
    for (const target of frame.targets) {
      for (const lightFrame of target.lights) {
        await this.client.updateLight(
          lightFrame.light.id,
          buildHueLightBody(lightFrame.light, lightFrame.colors, frame.transitionSeconds),
        );
      }
    }
  }

  async stop(frame: HueAmbienceFrame): Promise<void> {
    for (const target of frame.targets) {
      for (const lightFrame of target.lights) {
        await this.client.updateLight(lightFrame.light.id, buildHueLightOffBody());
      }
    }
  }
}
```

- [ ] **Step 5: Run renderer and legacy renderer tests**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree/nas-relay
npm test -- --test-name-pattern="CLIP frame renderer|gradient lights|target resolution|light filtering"
npm run build
```

Expected: PASS for new and existing renderer behavior, and `tsc` exits 0.

- [ ] **Step 6: Commit Task 2**

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree
git add nas-relay/src/hueRenderer.ts nas-relay/src/hueFrameRenderer.ts nas-relay/src/hueFrameRenderer.test.ts
git commit -m "feat: render hue ambience frames through clip fallback"
```

## Task 3: Integrate Frames Into NAS Service

**Files:**
- Modify: `nas-relay/src/hueAmbienceService.ts`
- Modify: `nas-relay/src/hueAmbienceService.test.ts`
- Modify: `nas-relay/src/hueTypes.ts`

- [ ] **Step 1: Write failing service tests for render mode and status**

Add these tests to `nas-relay/src/hueAmbienceService.test.ts`:

```ts
test('service reports streaming-ready mode for entertainment targets through CLIP fallback', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(entertainmentConfig);
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [
        { r: 1, g: 0, b: 0 },
        { r: 0, g: 1, b: 0 },
      ],
    );
    await service.load();

    service.receiveSnapshot(snapshot('/art-one.jpg'));
    await waitFor(() => client.updates.length === 1);

    assert.equal(service.status().renderMode, 'streamingReady');
    assert.equal(service.status().entertainmentTargetActive, true);
    assert.equal(service.status().entertainmentMetadataComplete, true);
    assert.deepEqual(service.status().activeTargetIds, ['ent-1']);
    assert.ok(service.status().lastFrameAt);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('service reports incomplete entertainment metadata without selecting unrelated lights', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-service-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({
      ...entertainmentConfig,
      resources: {
        ...entertainmentConfig.resources,
        areas: [{
          ...entertainmentConfig.resources.areas[0]!,
          entertainmentChannels: [],
        }],
      },
    });
    const client = new RecordingHueLightClient();
    const service = new HueAmbienceService(
      store,
      pino({ enabled: false }),
      () => client,
      () => [{ r: 1, g: 0, b: 0 }],
    );
    await service.load();

    service.receiveSnapshot(snapshot('/art-one.jpg'));
    await waitFor(() => client.updates.length === 1);

    assert.equal(service.status().renderMode, 'streamingReady');
    assert.equal(service.status().entertainmentMetadataComplete, false);
    assert.deepEqual(client.updates.map(update => update.id), ['light-1']);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
```

Add this fixture near the existing `config` fixture:

```ts
const entertainmentConfig: HueAmbienceRuntimeConfig = {
  ...config,
  resources: {
    lights: [
      {
        id: 'light-1',
        name: 'Gradient Strip',
        supportsColor: true,
        supportsGradient: true,
        supportsEntertainment: true,
        function: 'decorative',
        functionMetadataResolved: true,
      },
    ],
    areas: [
      {
        id: 'ent-1',
        name: 'Playroom Entertainment',
        kind: 'entertainmentArea',
        childLightIDs: ['light-1'],
        entertainmentChannels: [{ id: '0', lightID: 'light-1', serviceID: 'svc-1' }],
      },
    ],
  },
  mappings: [
    {
      sonosID: 'office',
      sonosName: 'Office',
      relayGroupID: '192.168.50.25',
      preferredTarget: { kind: 'entertainmentArea', id: 'ent-1' },
      fallbackTarget: null,
      includedLightIDs: [],
      excludedLightIDs: [],
      capability: 'liveEntertainment',
    },
  ],
  motionStyle: 'still',
};
```

- [ ] **Step 2: Run service tests and verify they fail**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree/nas-relay
npm test -- --test-name-pattern="service reports streaming-ready|incomplete entertainment metadata"
```

Expected: FAIL because service status does not expose render mode or frame metadata yet.

- [ ] **Step 3: Update `HueAmbienceService` dependencies and fields**

In `nas-relay/src/hueAmbienceService.ts`, add imports:

```ts
import { buildHueAmbienceFrame } from './hueAmbienceFrames.js';
import { ClipHueAmbienceRenderer, type HueAmbienceRenderer } from './hueFrameRenderer.js';
```

Add fields:

```ts
private activeFrame: HueAmbienceFrame | null = null;
private lastFrameAt: string | null = null;
private activeRenderMode: HueAmbienceRenderMode | null = null;
private entertainmentTargetActive = false;
private activeEntertainmentMetadataComplete = false;
```

Use these constructor dependencies:

```ts
private readonly rendererFactory: (
  config: HueAmbienceRuntimeConfig,
  client: HueLightClient,
) => HueAmbienceRenderer = (_config, client) => new ClipHueAmbienceRenderer(client),
```

If adding the constructor parameter would disturb existing tests, append it after `stopGraceMs` and keep the default value.

- [ ] **Step 4: Build status from active frame metadata**

Update `status()`:

```ts
status(): HueAmbienceServiceStatus {
  return {
    ...this.store.status(),
    runtimeActive: this.activeTimer !== null || this.activeTargets.length > 0,
    activeGroupId: this.activeGroupId,
    activeTargetIds: this.activeTargets.map(target => target.area.id),
    renderMode: this.activeRenderMode,
    entertainmentTargetActive: this.entertainmentTargetActive,
    entertainmentMetadataComplete: this.activeEntertainmentMetadataComplete,
    lastFrameAt: this.lastFrameAt,
    lastTrackKey: this.activeTrackKey,
    lastError: this.lastError,
  };
}
```

- [ ] **Step 5: Render frames instead of raw palettes**

Inside `startForSnapshot`, replace `applyHuePalette` with frame rendering:

```ts
const client = this.clientFactory(config);
const renderer = this.rendererFactory(config, client);
const palette = await this.paletteProvider(snapshot);
if (!this.isCurrentRun(runID)) return;

const intervalSeconds = Math.max(config.flowIntervalSeconds, 1);
const transitionSeconds = config.motionStyle === 'flowing' ? intervalSeconds : 4;

let step = 0;
const apply = async () => {
  if (!this.isCurrentRun(runID)) return;
  try {
    const frame = buildHueAmbienceFrame({
      targets,
      palette,
      snapshot,
      phase: config.motionStyle === 'flowing' ? step : 0,
      transitionSeconds,
      reason: step === 0 ? 'trackChange' : 'steady',
    });
    await renderer.render(frame);
    this.activeFrame = frame;
    this.activeRenderMode = frame.mode;
    this.entertainmentTargetActive = frame.targets.some(target => target.area.kind === 'entertainmentArea');
    this.activeEntertainmentMetadataComplete = frame.metadataComplete;
    this.lastFrameAt = frame.createdAt.toISOString();
    step += 1;
  } catch (err) {
    this.lastError = err instanceof Error ? err.message : String(err);
    this.log.warn({ err, groupId: snapshot.groupId }, 'Hue ambience update failed');
  }
};
```

- [ ] **Step 6: Stop through the active renderer frame**

Update `stopActive` so it clears state and stops from `activeFrame`:

```ts
const frame = this.activeFrame;
this.activeFrame = null;
this.activeRenderMode = null;
this.entertainmentTargetActive = false;
this.activeEntertainmentMetadataComplete = false;

if (!applyStopBehavior || !config || config.stopBehavior !== 'turnOff' || !frame) {
  return;
}

try {
  await this.rendererFactory(config, this.clientFactory(config)).stop({
    ...frame,
    reason: 'stop',
  });
} catch (err) {
  this.lastError = err instanceof Error ? err.message : String(err);
  this.log.warn({ err }, 'Hue ambience stop failed');
}
```

- [ ] **Step 7: Run service and full NAS tests**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree/nas-relay
npm test -- --test-name-pattern="Hue ambience|service reports|pending Hue ambience|playing snapshots|idle snapshots|non-music"
npm test
npm run build
```

Expected: PASS for focused service tests, full NAS tests pass, and `tsc` exits 0.

- [ ] **Step 8: Commit Task 3**

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree
git add nas-relay/src/hueAmbienceService.ts nas-relay/src/hueAmbienceService.test.ts nas-relay/src/hueTypes.ts
git commit -m "feat: route hue ambience through renderer frames"
```

## Task 4: Normalize Config And Health Status

**Files:**
- Modify: `nas-relay/src/hueConfigStore.ts`
- Modify: `nas-relay/src/hueConfigStore.test.ts`
- Inspect: `nas-relay/src/index.ts`

- [ ] **Step 1: Write failing config tests**

Add these tests to `nas-relay/src/hueConfigStore.test.ts`:

```ts
test('config store preserves entertainment channel metadata for valid lights', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-config-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save({
      ...config,
      resources: {
        lights: [
          {
            id: 'light-1',
            name: 'Gradient',
            supportsColor: true,
            supportsGradient: true,
            supportsEntertainment: true,
            function: 'decorative',
            functionMetadataResolved: true,
          },
        ],
        areas: [
          {
            id: 'ent-1',
            name: 'Area',
            kind: 'entertainmentArea',
            childLightIDs: ['light-1'],
            entertainmentChannels: [
              { id: '0', lightID: 'light-1', serviceID: 'svc-1', position: { x: 0, y: 1, z: 0 } },
              { id: 'stale', lightID: 'old-light', serviceID: 'old-service' },
            ],
          },
        ],
      },
      mappings: [
        {
          sonosID: 'playroom',
          sonosName: 'Playroom',
          preferredTarget: { kind: 'entertainmentArea', id: 'ent-1' },
          fallbackTarget: null,
          includedLightIDs: [],
          excludedLightIDs: [],
          capability: 'liveEntertainment',
        },
      ],
    });

    assert.deepEqual(store.current?.resources.areas[0]?.entertainmentChannels, [
      { id: '0', lightID: 'light-1', serviceID: 'svc-1', position: { x: 0, y: 1, z: 0 } },
    ]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('config store status includes inactive renderer fields without secrets', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-config-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(config);

    assert.equal((store.status() as any).applicationKey, undefined);
    assert.equal(store.status().renderMode, null);
    assert.equal(store.status().lastFrameAt, null);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
```

- [ ] **Step 2: Run config tests and verify they fail**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree/nas-relay
npm test -- --test-name-pattern="entertainment channel metadata|inactive renderer fields"
```

Expected: FAIL because channel metadata is not normalized and status does not include inactive renderer fields.

- [ ] **Step 3: Normalize channel metadata**

In `normalizeConfig`, map areas like this:

```ts
areas: (config.resources?.areas ?? []).map(area => {
  const childLightIDs = (area.childLightIDs ?? []).filter(id => validLightIDs.has(id));
  const childLightIDSet = new Set(childLightIDs);
  return {
    ...area,
    childLightIDs,
    childDeviceIDs: area.childDeviceIDs ?? [],
    entertainmentChannels: (area.entertainmentChannels ?? [])
      .filter(channel => !channel.lightID || childLightIDSet.has(channel.lightID))
      .map(channel => ({
        id: String(channel.id),
        lightID: channel.lightID ?? null,
        serviceID: channel.serviceID ?? null,
        position: channel.position ?? null,
      })),
  };
}),
```

- [ ] **Step 4: Add inactive renderer status defaults**

Update `HueAmbienceConfigStore.status()` configured response:

```ts
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
```

- [ ] **Step 5: Verify health already carries status**

Inspect `nas-relay/src/index.ts`. The existing health endpoint should include `hueAmbience: hueAmbience.status()`. If it does not, update it to include:

```ts
hueAmbience: hueAmbience.status(),
```

- [ ] **Step 6: Run config and full NAS tests**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree/nas-relay
npm test -- --test-name-pattern="config store"
npm test
npm run build
```

Expected: PASS for config tests, full NAS tests pass, and `tsc` exits 0.

- [ ] **Step 7: Commit Task 4**

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree
git add nas-relay/src/hueConfigStore.ts nas-relay/src/hueConfigStore.test.ts nas-relay/src/index.ts
git commit -m "feat: report hue ambience streaming-ready status"
```

## Task 5: Carry Entertainment Channel Metadata From iOS

**Files:**
- Modify: `Shared/HueAmbienceModels.swift`
- Modify: `Shared/HueBridgeClient.swift`
- Modify: `SonosWidgetTests/HueAmbienceStoreTests.swift`
- Modify: `SonosWidgetTests/HueAmbienceRelayConfigTests.swift`

- [ ] **Step 1: Write failing Swift model/config tests**

In `SonosWidgetTests/HueAmbienceStoreTests.swift`, add:

```swift
func testHueAreaResourcePersistsEntertainmentChannels() throws {
    let area = HueAreaResource(
        id: "ent-1",
        name: "Playroom Area",
        kind: .entertainmentArea,
        childLightIDs: ["light-1"],
        childDeviceIDs: ["device-1"],
        entertainmentChannels: [
            HueEntertainmentChannelResource(
                id: "0",
                lightID: "light-1",
                serviceID: "svc-1",
                position: HueEntertainmentChannelPosition(x: 0, y: 1, z: 0)
            )
        ]
    )

    let data = try JSONEncoder().encode(area)
    let decoded = try JSONDecoder().decode(HueAreaResource.self, from: data)

    XCTAssertEqual(decoded.entertainmentChannels.first?.id, "0")
    XCTAssertEqual(decoded.entertainmentChannels.first?.lightID, "light-1")
    XCTAssertEqual(decoded.entertainmentChannels.first?.position?.y, 1)
}
```

In `SonosWidgetTests/HueAmbienceRelayConfigTests.swift`, extend `testRelayConfigEncodesRelayGroupIDAndFlatHueTarget` by constructing the area with channels:

```swift
HueAreaResource(
    id: "ent-1",
    name: "PC",
    kind: .entertainmentArea,
    childLightIDs: ["light-1"],
    childDeviceIDs: [],
    entertainmentChannels: [
        HueEntertainmentChannelResource(id: "0", lightID: "light-1", serviceID: "svc-1")
    ]
)
```

Then assert JSON includes them:

```swift
let resources = try XCTUnwrap(object["resources"] as? [String: Any])
let areas = try XCTUnwrap(resources["areas"] as? [[String: Any]])
let channels = try XCTUnwrap(areas.first?["entertainmentChannels"] as? [[String: Any]])
XCTAssertEqual(channels.first?["id"] as? String, "0")
XCTAssertEqual(channels.first?["lightID"] as? String, "light-1")
XCTAssertEqual(channels.first?["serviceID"] as? String, "svc-1")
```

- [ ] **Step 2: Run focused iOS tests and verify they fail**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree
xcodebuild test -project SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SonosWidgetTests/HueAmbienceStoreTests -only-testing:SonosWidgetTests/HueAmbienceRelayConfigTests
```

Expected: FAIL because `HueEntertainmentChannelResource` and the new initializer parameter do not exist.

- [ ] **Step 3: Add Swift Entertainment channel models**

In `Shared/HueAmbienceModels.swift`, add before `HueAreaResource`:

```swift
struct HueEntertainmentChannelPosition: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double
}

struct HueEntertainmentChannelResource: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var lightID: String?
    var serviceID: String?
    var position: HueEntertainmentChannelPosition?

    init(
        id: String,
        lightID: String? = nil,
        serviceID: String? = nil,
        position: HueEntertainmentChannelPosition? = nil
    ) {
        self.id = id
        self.lightID = lightID
        self.serviceID = serviceID
        self.position = position
    }
}
```

Add `entertainmentChannels` to `HueAreaResource`:

```swift
var entertainmentChannels: [HueEntertainmentChannelResource]
```

Update initializer:

```swift
init(
    id: String,
    name: String,
    kind: Kind,
    childLightIDs: [String],
    childDeviceIDs: [String] = [],
    entertainmentChannels: [HueEntertainmentChannelResource] = []
) {
    self.id = id
    self.name = name
    self.kind = kind
    self.childLightIDs = childLightIDs
    self.childDeviceIDs = childDeviceIDs
    self.entertainmentChannels = entertainmentChannels
}
```

Update `CodingKeys` and decoder:

```swift
case entertainmentChannels
```

```swift
entertainmentChannels = try container.decodeIfPresent(
    [HueEntertainmentChannelResource].self,
    forKey: .entertainmentChannels
) ?? []
```

- [ ] **Step 4: Parse channel metadata from Hue Bridge resources**

In `Shared/HueBridgeClient.swift`, update `HueEntertainmentConfigurationDTO.resource` so it builds channels:

```swift
let entertainmentChannels = (channels ?? []).enumerated().compactMap { index, channel -> HueEntertainmentChannelResource? in
    let service = channel.members?.compactMap(\.service).first
    let lightID = service.flatMap { reference -> String? in
        if reference.rtype == "light" {
            return reference.rid
        }
        return serviceToLightID[reference.rid]
    }
    return HueEntertainmentChannelResource(
        id: channel.id ?? String(index),
        lightID: lightID,
        serviceID: service?.rid,
        position: channel.position?.resource
    )
}
```

Update the return:

```swift
return HueAreaResource(
    id: id,
    name: metadata?.name ?? id,
    kind: kind,
    childLightIDs: uniqueLightIDs,
    childDeviceIDs: Self.unique(deviceIDs),
    entertainmentChannels: entertainmentChannels
)
```

Update DTOs:

```swift
private struct HueEntertainmentChannelDTO: Decodable {
    var id: String?
    var position: HueEntertainmentPositionDTO?
    var members: [HueEntertainmentMemberDTO]?
}

private struct HueEntertainmentPositionDTO: Decodable {
    var x: Double?
    var y: Double?
    var z: Double?

    var resource: HueEntertainmentChannelPosition? {
        guard let x, let y, let z else {
            return nil
        }
        return HueEntertainmentChannelPosition(x: x, y: y, z: z)
    }
}
```

- [ ] **Step 5: Run focused iOS tests**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree
xcodebuild test -project SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SonosWidgetTests/HueAmbienceStoreTests -only-testing:SonosWidgetTests/HueAmbienceRelayConfigTests
```

Expected: PASS for Hue model and config tests.

- [ ] **Step 6: Commit Task 5**

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree
git add Shared/HueAmbienceModels.swift Shared/HueBridgeClient.swift SonosWidgetTests/HueAmbienceStoreTests.swift SonosWidgetTests/HueAmbienceRelayConfigTests.swift
git commit -m "feat: sync hue entertainment channel metadata"
```

## Task 6: Decode And Display NAS Runtime Status In iOS

**Files:**
- Modify: `Shared/RelayClient.swift`
- Modify: `Shared/HueAmbienceRelayConfig.swift`
- Modify: `Shared/RelayManager.swift`
- Modify: `Shared/HueAmbienceModels.swift`
- Modify: `SonosWidget/MusicAmbienceSettingsView.swift`
- Modify: `SonosWidgetTests/RelayManagerTests.swift`
- Modify: `SonosWidgetTests/HueAmbienceStoreTests.swift`

- [ ] **Step 1: Write failing runtime status tests**

In `SonosWidgetTests/RelayManagerTests.swift`, add:

```swift
func testRuntimeStatusReflectsStreamingReadyFallback() {
    let relay = RelayManager.shared
    relay.setURL("")
    defer { relay.setURL("") }

    relay.updateHueAmbienceRuntimeStatus(
        configured: true,
        enabled: true,
        renderMode: .streamingReady,
        runtimeActive: true,
        entertainmentTargetActive: true,
        entertainmentMetadataComplete: false,
        lastError: nil
    )

    XCTAssertTrue(relay.shouldDeferLocalHueAmbience)
    XCTAssertEqual(relay.hueAmbienceRuntimeStatus, .fallback("Streaming-ready via CLIP fallback"))
    XCTAssertEqual(relay.hueAmbienceRuntimeDetail, "Entertainment channel metadata is incomplete.")
}
```

In `SonosWidgetTests/HueAmbienceStoreTests.swift`, replace the unavailable-only status test with:

```swift
func testLiveEntertainmentRuntimeStatusLabelsStreamingReadyFallback() {
    XCTAssertEqual(
        HueLiveEntertainmentRuntimeStatus.fallback("Streaming-ready via CLIP fallback").reason,
        "Streaming-ready via CLIP fallback"
    )
    XCTAssertEqual(
        HueLiveEntertainmentRuntimeStatus.unavailable.reason,
        "NAS runtime not configured"
    )
}
```

- [ ] **Step 2: Run focused tests and verify they fail**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree
xcodebuild test -project SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SonosWidgetTests/RelayManagerTests -only-testing:SonosWidgetTests/HueAmbienceStoreTests
```

Expected: FAIL because status cases and relay fields do not exist.

- [ ] **Step 3: Expand Swift runtime status model**

In `Shared/HueAmbienceModels.swift`, replace `HueLiveEntertainmentRuntimeStatus` with:

```swift
enum HueLiveEntertainmentRuntimeStatus: Equatable, Sendable {
    case unavailable
    case ready(String)
    case fallback(String)
    case active(String)
    case error(String)

    var reason: String {
        switch self {
        case .unavailable:
            return "NAS runtime not configured"
        case .ready(let message), .fallback(let message), .active(let message), .error(let message):
            return message
        }
    }
}

enum HueAmbienceRelayRenderMode: String, Codable, Equatable, Sendable {
    case clipFallback
    case streamingReady
}
```

- [ ] **Step 4: Decode expanded relay status**

In `Shared/HueAmbienceRelayConfig.swift`, extend `RelayClient.HueAmbienceStatusResponse.Status`:

```swift
let renderMode: HueAmbienceRelayRenderMode?
let activeTargetIds: [String]?
let entertainmentTargetActive: Bool?
let entertainmentMetadataComplete: Bool?
let lastFrameAt: String?
```

In `Shared/RelayClient.swift`, extend `HealthResponse.HueAmbience` with the same fields:

```swift
let renderMode: HueAmbienceRelayRenderMode?
let activeTargetIds: [String]?
let entertainmentTargetActive: Bool?
let entertainmentMetadataComplete: Bool?
let lastFrameAt: String?
let lastError: String?
```

- [ ] **Step 5: Store runtime status in `RelayManager`**

Add properties:

```swift
private(set) var hueAmbienceRuntimeStatus: HueLiveEntertainmentRuntimeStatus = .unavailable
private(set) var hueAmbienceRuntimeDetail: String = "Sync Music Ambience to NAS Relay to enable always-on ambience."
```

Replace `updateHueAmbienceRuntimeStatus(configured:enabled:)` with:

```swift
func updateHueAmbienceRuntimeStatus(
    configured: Bool,
    enabled: Bool = true,
    renderMode: HueAmbienceRelayRenderMode? = nil,
    runtimeActive: Bool? = nil,
    entertainmentTargetActive: Bool? = nil,
    entertainmentMetadataComplete: Bool? = nil,
    lastError: String? = nil
) {
    isHueAmbienceRelayConfigured = configured
    isHueAmbienceRelayEnabled = configured && enabled
    hueAmbienceSyncStatus = configured ? .synced(Date()) : .idle

    guard configured else {
        hueAmbienceRuntimeStatus = .unavailable
        hueAmbienceRuntimeDetail = "Sync Music Ambience to NAS Relay to enable always-on ambience."
        return
    }
    if let lastError, !lastError.isEmpty {
        hueAmbienceRuntimeStatus = .error(lastError)
        hueAmbienceRuntimeDetail = "NAS reported a Music Ambience runtime error."
        return
    }
    if runtimeActive == true {
        switch renderMode {
        case .streamingReady:
            hueAmbienceRuntimeStatus = .fallback("Streaming-ready via CLIP fallback")
        case .clipFallback, .none:
            hueAmbienceRuntimeStatus = .fallback("CLIP fallback active")
        }
    } else {
        hueAmbienceRuntimeStatus = .ready("NAS runtime ready")
    }
    hueAmbienceRuntimeDetail = entertainmentTargetActive == true && entertainmentMetadataComplete == false
        ? "Entertainment channel metadata is incomplete."
        : "NAS controls Music Ambience while it is reachable."
}
```

Update the private health/status mappers to pass all decoded fields.

- [ ] **Step 6: Update Settings text**

In `SonosWidget/MusicAmbienceSettingsView.swift`, replace the static Live Entertainment rows:

```swift
LabeledContent("Live Entertainment", value: relay.hueAmbienceRuntimeStatus.reason)
Text(relay.hueAmbienceRuntimeDetail)
    .font(.caption)
    .foregroundStyle(.secondary)
```

- [ ] **Step 7: Run focused iOS tests**

Run:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree
xcodebuild test -project SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SonosWidgetTests/RelayManagerTests -only-testing:SonosWidgetTests/HueAmbienceStoreTests -only-testing:SonosWidgetTests/MusicAmbienceManagerTests
```

Expected: PASS for relay manager, store status, and local deferral tests.

- [ ] **Step 8: Commit Task 6**

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree
git add Shared/RelayClient.swift Shared/HueAmbienceRelayConfig.swift Shared/RelayManager.swift Shared/HueAmbienceModels.swift SonosWidget/MusicAmbienceSettingsView.swift SonosWidgetTests/RelayManagerTests.swift SonosWidgetTests/HueAmbienceStoreTests.swift SonosWidgetTests/MusicAmbienceManagerTests.swift
git commit -m "feat: show hue ambience relay runtime status"
```

## Task 7: Final Verification And Integration

**Files:**
- Inspect all modified files.
- No new production files unless verification exposes a compile issue.

- [ ] **Step 1: Run full NAS verification**

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree/nas-relay
npm test
npm run build
```

Expected: all Node tests pass and TypeScript build exits 0.

- [ ] **Step 2: Run focused iOS verification**

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree
xcodebuild test -project SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SonosWidgetTests/HueAmbienceStoreTests -only-testing:SonosWidgetTests/HueAmbienceRelayConfigTests -only-testing:SonosWidgetTests/MusicAmbienceManagerTests -only-testing:SonosWidgetTests/RelayManagerTests
```

Expected: all selected XCTest cases pass.

- [ ] **Step 3: Review diff for scope and safety**

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree
git diff --stat origin/main...HEAD
git diff --check origin/main...HEAD
git log --oneline origin/main..HEAD
```

Expected: diff only touches planned Hue/NAS files and docs; whitespace check exits 0.

- [ ] **Step 4: Route verification failures back to the owning task**

If final verification fails, do not add an unplanned catch-all fix commit from
this task. Identify the failing area and return to the owning task:

```bash
cd /Users/charm/Documents/workspace/SonosWidget/.worktrees/hue-ambience-worktree
git status --short
git log --oneline origin/main..HEAD
```

Expected: the worker reports the failing command, the failing test/build output,
and the task number that owns the correction.

- [ ] **Step 5: Report result**

Summarize:

- commits created
- NAS test/build result
- focused iOS test result
- remaining limitation: true Hue Entertainment DTLS/UDP transport is not shipped in this phase
