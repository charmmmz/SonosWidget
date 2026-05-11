# Hue Ambience Target Scope Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Limit Music Ambience assignments to Entertainment Areas and Room/Zone targets, while making Entertainment Areas trust Hue membership instead of task/decorative filtering.

**Architecture:** Add explicit target-scope policy helpers in shared Swift and NAS resolver code. iOS setup stops creating direct-light targets and shows manual light editing only for Room/Zone. Both iOS local rendering and NAS relay rendering use the selected target kind to decide whether function filtering and manual include/exclude overrides apply.

**Tech Stack:** Swift/SwiftUI/XCTest for iOS app logic, TypeScript Node test runner for `nas-relay`, existing Hue resource and resolver models.

---

## File Structure

- Modify `Shared/HueAmbienceModels.swift`
  - Add target-kind policy helpers.
  - Remove direct Light pseudo-targets from assignable options.
  - Keep `.light` decoding for backward compatibility.
- Modify `Shared/HueAmbienceStore.swift`
  - Sanitize legacy direct-light mappings out.
  - Clear include/exclude overrides for Entertainment Area mappings.
- Modify `Shared/HueAmbienceRenderer.swift`
  - Make Entertainment Area resolution ignore function metadata and manual overrides.
  - Keep Room/Zone filtering unchanged.
- Modify `SonosWidget/MusicAmbienceSettingsView.swift`
  - Show the Lights editor only for Room/Zone mappings.
- Modify `Shared/HueAmbienceRelayConfig.swift`
  - No structural change expected; verification should prove sanitized mappings are what gets encoded.
- Modify `nas-relay/src/hueRenderer.ts`
  - Make NAS Entertainment Area resolution mirror iOS.
  - Keep Room/Zone filtering unchanged.
- Modify `nas-relay/src/hueConfigStore.ts`
  - Normalize legacy direct-light mappings out.
  - Clear include/exclude overrides for Entertainment Area mappings.
- Modify tests:
  - `SonosWidgetTests/HueAmbienceStoreTests.swift`
  - `SonosWidgetTests/MusicAmbienceManagerTests.swift`
  - `SonosWidgetTests/HueAmbienceRelayConfigTests.swift`
  - `nas-relay/src/hueRenderer.test.ts`
  - `nas-relay/src/hueConfigStore.test.ts`

---

## Task 1: Add iOS Target Scope Policy And Sanitization

**Files:**
- Modify: `Shared/HueAmbienceModels.swift`
- Modify: `Shared/HueAmbienceStore.swift`
- Test: `SonosWidgetTests/HueAmbienceStoreTests.swift`

- [ ] **Step 1: Write failing iOS model/store tests**

Add these tests to `SonosWidgetTests/HueAmbienceStoreTests.swift`:

```swift
func testAreaOptionsExcludeDirectLightTargets() {
    let options = HueAmbienceAreaOptions.displayAreas(
        from: [
            HueAreaResource(
                id: "ent-1",
                name: "Playroom Area",
                kind: .entertainmentArea,
                childLightIDs: ["light-1"]
            ),
            HueAreaResource(
                id: "room-1",
                name: "Playroom",
                kind: .room,
                childLightIDs: ["light-1"]
            ),
            HueAreaResource(
                id: "zone-1",
                name: "Desk Zone",
                kind: .zone,
                childLightIDs: ["light-2"]
            )
        ],
        lights: [
            HueLightResource(
                id: "light-1",
                name: "Desk Lamp",
                ownerID: "device-1",
                supportsColor: true,
                supportsGradient: false,
                supportsEntertainment: true
            )
        ]
    )

    XCTAssertEqual(
        options.map(\.kind),
        [.entertainmentArea, .room, .zone]
    )
    XCTAssertFalse(options.contains { $0.kind == .light })
}

func testEntertainmentMappingSanitizationClearsManualLightOverrides() {
    let suiteName = "HueAmbienceStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let storage = HueAmbienceDefaults(defaults: defaults)
    let store = HueAmbienceStore(storage: storage)

    store.updateResources(HueBridgeResources(
        lights: [
            HueLightResource(
                id: "task-light",
                name: "Task Lamp",
                ownerID: "device-1",
                supportsColor: true,
                supportsGradient: false,
                supportsEntertainment: true,
                function: .functional
            )
        ],
        areas: [
            HueAreaResource(
                id: "ent-1",
                name: "Playroom Area",
                kind: .entertainmentArea,
                childLightIDs: ["task-light"],
                childDeviceIDs: ["device-1"]
            )
        ]
    ))
    store.upsertMapping(HueSonosMapping(
        sonosID: "playroom",
        sonosName: "Playroom",
        preferredTarget: .entertainmentArea("ent-1"),
        includedLightIDs: ["task-light"],
        excludedLightIDs: ["task-light"],
        capability: .liveEntertainment
    ))

    store.updateResources(store.hueResources)

    let mapping = store.mapping(forSonosID: "playroom")
    XCTAssertEqual(mapping?.preferredTarget, .entertainmentArea("ent-1"))
    XCTAssertEqual(mapping?.includedLightIDs, [])
    XCTAssertEqual(mapping?.excludedLightIDs, [])
}

func testLegacyDirectLightMappingIsRemovedDuringSanitization() {
    let suiteName = "HueAmbienceStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let storage = HueAmbienceDefaults(defaults: defaults)
    let store = HueAmbienceStore(storage: storage)

    store.updateResources(HueBridgeResources(
        lights: [
            HueLightResource(
                id: "light-1",
                name: "Desk Lamp",
                ownerID: "device-1",
                supportsColor: true,
                supportsGradient: false,
                supportsEntertainment: true
            )
        ],
        areas: [
            HueAreaResource(
                id: "room-1",
                name: "Playroom",
                kind: .room,
                childLightIDs: ["light-1"],
                childDeviceIDs: ["device-1"]
            )
        ]
    ))
    store.upsertMapping(HueSonosMapping(
        sonosID: "playroom",
        sonosName: "Playroom",
        preferredTarget: .light("light-1"),
        capability: .gradientReady
    ))

    store.updateResources(store.hueResources)

    XCTAssertNil(store.mapping(forSonosID: "playroom"))
}
```

- [ ] **Step 2: Run iOS model/store tests and verify failure**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SonosWidgetTests/HueAmbienceStoreTests/testAreaOptionsExcludeDirectLightTargets -only-testing:SonosWidgetTests/HueAmbienceStoreTests/testEntertainmentMappingSanitizationClearsManualLightOverrides -only-testing:SonosWidgetTests/HueAmbienceStoreTests/testLegacyDirectLightMappingIsRemovedDuringSanitization
```

Expected: FAIL because direct light options are still generated, Entertainment Area overrides are preserved, and direct-light mappings are still valid.

- [ ] **Step 3: Add target policy helpers and remove direct light options**

In `Shared/HueAmbienceModels.swift`, add helpers near `HueAmbienceTarget`:

```swift
extension HueAmbienceTarget {
    var allowsManualLightSelection: Bool {
        switch self {
        case .room, .zone:
            return true
        case .entertainmentArea, .light:
            return false
        }
    }

    var bypassesFunctionFiltering: Bool {
        if case .entertainmentArea = self { return true }
        return false
    }

    var isLegacyDirectLightTarget: Bool {
        if case .light = self { return true }
        return false
    }
}
```

Update `HueAmbienceAreaOptions.displayAreas(from:lights:)` so it returns only `areas` sorted by kind/name. Remove `lightTargets` creation from this function. Keep `.light` enum support for decoding only.

- [ ] **Step 4: Sanitize mappings by selected target kind**

In `Shared/HueAmbienceStore.swift`, update `HueSonosMapping.sanitized(for:)`:

```swift
guard let target = resolvedPreferred ?? resolvedFallback,
      !target.isLegacyDirectLightTarget else {
    return nil
}

var mapping = self
mapping.preferredTarget = target
mapping.fallbackTarget = resolvedPreferred == nil ? nil : resolvedFallback

if target.isEntertainmentArea {
    mapping.includedLightIDs = []
    mapping.excludedLightIDs = []
} else {
    mapping.includedLightIDs = includedLightIDs.intersection(validLightIDs)
    mapping.excludedLightIDs = excludedLightIDs.intersection(validLightIDs)
}
return mapping
```

- [ ] **Step 5: Run iOS model/store tests and verify pass**

Run the same command from Step 2.

Expected: PASS.

- [ ] **Step 6: Commit Task 1**

```bash
git add Shared/HueAmbienceModels.swift Shared/HueAmbienceStore.swift SonosWidgetTests/HueAmbienceStoreTests.swift
git commit -m "feat: restrict hue ambience target options"
```

---

## Task 2: Update iOS Resolver And Setup UI

**Files:**
- Modify: `Shared/HueAmbienceRenderer.swift`
- Modify: `SonosWidget/MusicAmbienceSettingsView.swift`
- Test: `SonosWidgetTests/MusicAmbienceManagerTests.swift`
- Test: `SonosWidgetTests/HueAmbienceStoreTests.swift`

- [ ] **Step 1: Write failing iOS resolver tests**

Add to `SonosWidgetTests/MusicAmbienceManagerTests.swift`:

```swift
func testStoredResolverIncludesFunctionalLightsForEntertainmentAreas() {
    let resolver = StoredHueTargetResolver(
        areas: [
            HueAreaResource(
                id: "ent-1",
                name: "Playroom Area",
                kind: .entertainmentArea,
                childLightIDs: ["decorative", "task"],
                childDeviceIDs: ["device-decorative", "device-task"]
            )
        ],
        lights: [
            makeLight(id: "decorative", ownerID: "device-decorative", function: .decorative),
            makeLight(id: "task", ownerID: "device-task", function: .functional)
        ]
    )

    let targets = resolver.resolveTargets(for: [
        HueSonosMapping(
            sonosID: "playroom",
            sonosName: "Playroom",
            preferredTarget: .entertainmentArea("ent-1"),
            excludedLightIDs: ["decorative"],
            capability: .liveEntertainment
        )
    ])

    XCTAssertEqual(targets.first?.lightIDs, ["decorative", "task"])
}

func testStoredResolverKeepsRoomFunctionFilteringAndManualOverrides() {
    let resolver = StoredHueTargetResolver(
        areas: [
            HueAreaResource(
                id: "room-1",
                name: "Playroom",
                kind: .room,
                childLightIDs: ["decorative", "task"],
                childDeviceIDs: ["device-decorative", "device-task"]
            )
        ],
        lights: [
            makeLight(id: "decorative", ownerID: "device-decorative", function: .decorative),
            makeLight(id: "task", ownerID: "device-task", function: .functional)
        ]
    )

    let defaultTargets = resolver.resolveTargets(for: [
        HueSonosMapping(
            sonosID: "playroom",
            sonosName: "Playroom",
            preferredTarget: .room("room-1")
        )
    ])
    XCTAssertEqual(defaultTargets.first?.lightIDs, ["decorative"])

    let manualTargets = resolver.resolveTargets(for: [
        HueSonosMapping(
            sonosID: "playroom",
            sonosName: "Playroom",
            preferredTarget: .room("room-1"),
            includedLightIDs: ["task"],
            excludedLightIDs: ["decorative"]
        )
    ])
    XCTAssertEqual(manualTargets.first?.lightIDs, ["task"])
}
```

If the existing `makeLight` helper lacks `ownerID`, extend its signature to:

```swift
private func makeLight(
    id: String,
    ownerID: String? = nil,
    supportsGradient: Bool = false,
    supportsEntertainment: Bool = false,
    function: HueLightFunction = .decorative,
    functionMetadataResolved: Bool = true
) -> HueLightResource
```

and pass `ownerID` through to `HueLightResource`.

- [ ] **Step 2: Add UI policy test**

Add to `SonosWidgetTests/HueAmbienceStoreTests.swift`:

```swift
func testTargetPolicyAllowsManualLightSelectionOnlyForRoomsAndZones() {
    XCTAssertFalse(HueAmbienceTarget.entertainmentArea("ent-1").allowsManualLightSelection)
    XCTAssertTrue(HueAmbienceTarget.room("room-1").allowsManualLightSelection)
    XCTAssertTrue(HueAmbienceTarget.zone("zone-1").allowsManualLightSelection)
    XCTAssertFalse(HueAmbienceTarget.light("light-1").allowsManualLightSelection)
}
```

- [ ] **Step 3: Run focused iOS resolver tests and verify failure**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SonosWidgetTests/MusicAmbienceManagerTests/testStoredResolverIncludesFunctionalLightsForEntertainmentAreas -only-testing:SonosWidgetTests/MusicAmbienceManagerTests/testStoredResolverKeepsRoomFunctionFilteringAndManualOverrides -only-testing:SonosWidgetTests/HueAmbienceStoreTests/testTargetPolicyAllowsManualLightSelectionOnlyForRoomsAndZones
```

Expected: FAIL because Entertainment Area still applies function filtering and manual exclusions.

- [ ] **Step 4: Implement iOS resolver policy**

In `Shared/HueAmbienceRenderer.swift`, update the light filter in `resolveTargets(for:)`:

```swift
let bypassesFiltering = target.bypassesFunctionFiltering
let lightIDs = area.childLightIDs.filter { lightID in
    guard let light = lightsByID[lightID] else {
        return false
    }
    guard Self.area(area, canUse: light, mapping: mapping, bypassesManualOverrides: bypassesFiltering) else {
        return false
    }
    guard light.supportsColor else {
        return false
    }
    if bypassesFiltering {
        return true
    }
    guard !mapping.excludedLightIDs.contains(lightID) else {
        return false
    }
    return area.kind == .light
        || light.participatesInAmbienceByDefault
        || mapping.includedLightIDs.contains(lightID)
}
```

Change `area(_:canUse:mapping:)` to accept a bypass flag:

```swift
private static func area(
    _ area: HueAreaResource,
    canUse light: HueLightResource,
    mapping: HueSonosMapping,
    bypassesManualOverrides: Bool
) -> Bool {
    if area.kind == .light || (!bypassesManualOverrides && mapping.includedLightIDs.contains(light.id)) {
        return true
    }
    guard !area.childDeviceIDs.isEmpty else {
        return light.ownerID == nil
    }
    guard let ownerID = light.ownerID else {
        return false
    }
    return area.childDeviceIDs.contains(ownerID)
}
```

- [ ] **Step 5: Hide Lights editor for Entertainment Area**

In `SonosWidget/MusicAmbienceSettingsView.swift`, add:

```swift
private var showsLightSelection: Bool {
    currentMapping?.preferredTarget?.allowsManualLightSelection == true
}
```

Change the DisclosureGroup guard:

```swift
if showsLightSelection && !areaLights.isEmpty {
    DisclosureGroup("Lights", isExpanded: $isLightSelectionExpanded) {
        ...
    }
}
```

Change `areaLights` to return an empty array unless the current target allows manual light selection:

```swift
guard currentMapping?.preferredTarget?.allowsManualLightSelection == true,
      let currentArea else {
    return []
}
```

- [ ] **Step 6: Run focused iOS resolver tests and verify pass**

Run the command from Step 3.

Expected: PASS.

- [ ] **Step 7: Commit Task 2**

```bash
git add Shared/HueAmbienceRenderer.swift SonosWidget/MusicAmbienceSettingsView.swift SonosWidgetTests/MusicAmbienceManagerTests.swift SonosWidgetTests/HueAmbienceStoreTests.swift
git commit -m "feat: align ios hue target filtering policy"
```

---

## Task 3: Update NAS Resolver And Config Normalization

**Files:**
- Modify: `nas-relay/src/hueRenderer.ts`
- Modify: `nas-relay/src/hueConfigStore.ts`
- Test: `nas-relay/src/hueRenderer.test.ts`
- Test: `nas-relay/src/hueConfigStore.test.ts`

- [ ] **Step 1: Write failing NAS resolver tests**

Add to `nas-relay/src/hueRenderer.test.ts`:

```ts
const runtimeConfig = (overrides: Partial<HueAmbienceRuntimeConfig>): HueAmbienceRuntimeConfig => ({
  ...config,
  ...overrides,
  resources: overrides.resources ?? config.resources,
  mappings: overrides.mappings ?? config.mappings,
});

const light = (
  overrides: Partial<HueLightResource> & Pick<HueLightResource, 'id'>
): HueLightResource => ({
  name: overrides.id,
  supportsColor: true,
  supportsGradient: false,
  supportsEntertainment: true,
  function: 'decorative',
  functionMetadataResolved: true,
  ...overrides,
});

const snapshot = () => ({
  groupId: '192.168.50.25',
  speakerName: 'Playroom',
  trackTitle: 'A',
  artist: 'B',
  album: 'C',
  isPlaying: true,
  positionSeconds: 1,
  durationSeconds: 120,
  groupMemberCount: 1,
  sampledAt: new Date('2026-05-11T00:00:00Z'),
});

test('entertainment area resolution includes functional lights and ignores manual overrides', () => {
  const config = runtimeConfig({
    resources: {
      lights: [
        light({ id: 'decorative', ownerID: 'device-decorative', function: 'decorative' }),
        light({ id: 'task', ownerID: 'device-task', function: 'functional' }),
      ],
      areas: [
        {
          id: 'ent-1',
          name: 'Playroom Area',
          kind: 'entertainmentArea',
          childLightIDs: ['decorative', 'task'],
          childDeviceIDs: ['device-decorative', 'device-task'],
        },
      ],
    },
    mappings: [
      {
        sonosID: 'playroom',
        sonosName: 'Playroom',
        relayGroupID: '192.168.50.25',
        preferredTarget: { kind: 'entertainmentArea', id: 'ent-1' },
        fallbackTarget: null,
        includedLightIDs: [],
        excludedLightIDs: ['decorative'],
        capability: 'liveEntertainment',
      },
    ],
  });

  const targets = resolveHueTargets(config, snapshot());

  assert.deepEqual(targets[0]!.lights.map(light => light.id), ['decorative', 'task']);
});

test('room resolution keeps functional filtering and manual overrides', () => {
  const baseConfig = runtimeConfig({
    resources: {
      lights: [
        light({ id: 'decorative', ownerID: 'device-decorative', function: 'decorative' }),
        light({ id: 'task', ownerID: 'device-task', function: 'functional' }),
      ],
      areas: [
        {
          id: 'room-1',
          name: 'Playroom',
          kind: 'room',
          childLightIDs: ['decorative', 'task'],
          childDeviceIDs: ['device-decorative', 'device-task'],
        },
      ],
    },
    mappings: [
      {
        sonosID: 'playroom',
        sonosName: 'Playroom',
        relayGroupID: '192.168.50.25',
        preferredTarget: { kind: 'room', id: 'room-1' },
        fallbackTarget: null,
        includedLightIDs: [],
        excludedLightIDs: [],
        capability: 'gradientReady',
      },
    ],
  });

  assert.deepEqual(resolveHueTargets(baseConfig, snapshot())[0]!.lights.map(light => light.id), ['decorative']);

  const manualConfig = {
    ...baseConfig,
    mappings: [
      {
        ...baseConfig.mappings[0]!,
        includedLightIDs: ['task'],
        excludedLightIDs: ['decorative'],
      },
    ],
  };

  assert.deepEqual(resolveHueTargets(manualConfig, snapshot())[0]!.lights.map(light => light.id), ['task']);
});
```

Add these helpers once near the existing `config` fixture in `hueRenderer.test.ts`, then add the two tests below the current target-resolution coverage.

- [ ] **Step 2: Write failing NAS config normalization tests**

Add to `nas-relay/src/hueConfigStore.test.ts`:

```ts
const runtimeConfig = (overrides: Partial<HueAmbienceRuntimeConfig>): HueAmbienceRuntimeConfig => ({
  ...config,
  ...overrides,
  resources: overrides.resources ?? config.resources,
  mappings: overrides.mappings ?? config.mappings,
});

const light = (
  overrides: Partial<HueAmbienceRuntimeConfig['resources']['lights'][number]> &
    Pick<HueAmbienceRuntimeConfig['resources']['lights'][number], 'id'>
): HueAmbienceRuntimeConfig['resources']['lights'][number] => ({
  name: overrides.id,
  supportsColor: true,
  supportsGradient: false,
  supportsEntertainment: true,
  function: 'decorative',
  functionMetadataResolved: true,
  ...overrides,
});

test('config store clears light overrides for entertainment mappings', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-config-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(runtimeConfig({
      resources: {
        lights: [
          light({ id: 'task-light', ownerID: 'device-1', function: 'functional' }),
        ],
        areas: [
          {
            id: 'ent-1',
            name: 'Playroom Area',
            kind: 'entertainmentArea',
            childLightIDs: ['task-light'],
            childDeviceIDs: ['device-1'],
          },
        ],
      },
      mappings: [
        {
          sonosID: 'playroom',
          sonosName: 'Playroom',
          relayGroupID: '192.168.50.25',
          preferredTarget: { kind: 'entertainmentArea', id: 'ent-1' },
          fallbackTarget: null,
          includedLightIDs: ['task-light'],
          excludedLightIDs: ['task-light'],
          capability: 'liveEntertainment',
        },
      ],
    }));

    assert.deepEqual(store.current?.mappings[0]?.includedLightIDs, []);
    assert.deepEqual(store.current?.mappings[0]?.excludedLightIDs, []);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('config store removes legacy direct light mappings', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'hue-config-'));
  try {
    const store = new HueAmbienceConfigStore(dir);
    await store.save(runtimeConfig({
      resources: {
        lights: [
          light({ id: 'light-1', ownerID: 'device-1' }),
        ],
        areas: [
          {
            id: 'room-1',
            name: 'Playroom',
            kind: 'room',
            childLightIDs: ['light-1'],
            childDeviceIDs: ['device-1'],
          },
        ],
      },
      mappings: [
        {
          sonosID: 'playroom',
          sonosName: 'Playroom',
          relayGroupID: '192.168.50.25',
          preferredTarget: { kind: 'light', id: 'light-1' },
          fallbackTarget: null,
          includedLightIDs: [],
          excludedLightIDs: [],
          capability: 'gradientReady',
        },
      ],
    }));

    assert.deepEqual(store.current?.mappings, []);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
```

Add these helpers once near the top-level `config` fixture in `hueConfigStore.test.ts`, then add both normalization tests below the existing stale-target test.

- [ ] **Step 3: Run focused NAS tests and verify failure**

Run:

```bash
cd nas-relay
npm test -- --test-name-pattern="entertainment area resolution includes functional|room resolution keeps functional|clears light overrides|removes legacy direct light"
```

Expected: FAIL because NAS still applies function filtering to Entertainment Areas and preserves direct light mappings/overrides.

- [ ] **Step 4: Implement NAS resolver policy**

In `nas-relay/src/hueRenderer.ts`, change `shouldUseLightForAmbience` to accept the area kind:

```ts
export function shouldUseLightForAmbience(
  light: HueLightResource,
  mapping: HueSonosMapping,
  areaKind: string | undefined,
): boolean {
  if (areaKind === 'entertainmentArea') {
    return true;
  }
  if (mapping.excludedLightIDs.includes(light.id)) {
    return false;
  }
  if (mapping.includedLightIDs.includes(light.id)) {
    return true;
  }
  return light.functionMetadataResolved && light.function !== 'functional';
}
```

Update the call site:

```ts
.filter(light => area.kind === 'light' || shouldUseLightForAmbience(light, mapping, area.kind));
```

Update `lightBelongsToAreaDevice` so manual include overrides do not bypass ownership for Entertainment Areas:

```ts
if (area.kind === 'light' || (area.kind !== 'entertainmentArea' && mapping.includedLightIDs.includes(light.id))) {
  return true;
}
```

- [ ] **Step 5: Implement NAS config normalization**

In `nas-relay/src/hueConfigStore.ts`, make direct light targets invalid for Music Ambience assignment:

```ts
function isAssignableTarget(target: unknown): target is HueAmbienceTarget {
  return isValidTarget(target) && target.kind !== 'light';
}
```

Use `isAssignableTarget` for `preferredTarget` and `fallbackTarget` in mapping normalization. After resolving the target:

```ts
const isEntertainmentTarget = resolvedPreferredTarget?.kind === 'entertainmentArea';
return {
  ...mapping,
  preferredTarget: resolvedPreferredTarget,
  fallbackTarget: preferredTarget ? fallbackTarget : null,
  includedLightIDs: isEntertainmentTarget
    ? []
    : stringArray(mapping.includedLightIDs).filter(id => validLightIDs.has(id)),
  excludedLightIDs: isEntertainmentTarget
    ? []
    : stringArray(mapping.excludedLightIDs).filter(id => validLightIDs.has(id)),
};
```

- [ ] **Step 6: Run focused NAS tests and verify pass**

Run the command from Step 3.

Expected: PASS.

- [ ] **Step 7: Commit Task 3**

```bash
git add nas-relay/src/hueRenderer.ts nas-relay/src/hueRenderer.test.ts nas-relay/src/hueConfigStore.ts nas-relay/src/hueConfigStore.test.ts
git commit -m "feat: align nas hue target filtering policy"
```

---

## Task 4: Relay Config Verification And Final Checks

**Files:**
- Test: `SonosWidgetTests/HueAmbienceRelayConfigTests.swift`
- Inspect all modified files.

- [ ] **Step 1: Add relay config assertion for sanitized Entertainment overrides**

Extend `SonosWidgetTests/HueAmbienceRelayConfigTests.swift` with:

```swift
func testRelayConfigDoesNotEncodeEntertainmentLightOverrides() throws {
    let suiteName = "HueAmbienceRelayConfigTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = HueAmbienceStore(storage: HueAmbienceDefaults(defaults: defaults))
    let credentials = InMemoryHueRelayCredentialStorage()
    let credentialStore = HueCredentialStore(storage: credentials)
    let bridge = HueBridgeInfo(id: "bridge-1", ipAddress: "192.168.1.2", name: "Hue Bridge")
    store.bridge = bridge
    credentialStore.saveApplicationKey("secret", forBridgeID: bridge.id)
    store.updateResources(HueBridgeResources(
        lights: [
            HueLightResource(
                id: "task-light",
                name: "Task Lamp",
                ownerID: "device-1",
                supportsColor: true,
                supportsGradient: false,
                supportsEntertainment: true,
                function: .functional,
                functionMetadataResolved: true
            )
        ],
        areas: [
            HueAreaResource(
                id: "ent-1",
                name: "Playroom Area",
                kind: .entertainmentArea,
                childLightIDs: ["task-light"],
                childDeviceIDs: ["device-1"]
            )
        ]
    ))
    store.upsertMapping(HueSonosMapping(
        sonosID: "playroom",
        sonosName: "Playroom",
        preferredTarget: .entertainmentArea("ent-1"),
        includedLightIDs: ["task-light"],
        excludedLightIDs: ["task-light"],
        capability: .liveEntertainment
    ))

    let config = try HueAmbienceRelayConfig(
        store: store,
        credentialStore: credentialStore,
        sonosSpeakers: []
    )
    let data = try JSONEncoder().encode(config)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let mappings = try XCTUnwrap(object["mappings"] as? [[String: Any]])
    let mapping = try XCTUnwrap(mappings.first)

    XCTAssertEqual(mapping["includedLightIDs"] as? [String], [])
    XCTAssertEqual(mapping["excludedLightIDs"] as? [String], [])
}
```

This test intentionally leaves the overrides on the stored mapping so relay export has to enforce the Entertainment Area rule itself.

- [ ] **Step 2: Run focused relay config test and verify failure**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SonosWidgetTests/HueAmbienceRelayConfigTests/testRelayConfigDoesNotEncodeEntertainmentLightOverrides
```

Expected: FAIL because `HueAmbienceRelayConfig` still serializes manual light overrides from an already-stored Entertainment Area mapping.

- [ ] **Step 3: Enforce relay config override clearing**

Update `HueAmbienceRelayMapping.init(mapping:relayGroupID:)`:

```swift
if mapping.preferredTarget?.isEntertainmentArea == true {
    self.includedLightIDs = []
    self.excludedLightIDs = []
} else {
    self.includedLightIDs = mapping.includedLightIDs.sorted()
    self.excludedLightIDs = mapping.excludedLightIDs.sorted()
}
```

- [ ] **Step 4: Re-run focused relay config test and verify pass**

Run the command from Step 2.

Expected: PASS.

- [ ] **Step 5: Run full verification**

Run:

```bash
cd nas-relay
npm test
npm run build
cd ..
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project SonosWidget.xcodeproj -scheme SonosWidget -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SonosWidgetTests/HueAmbienceStoreTests -only-testing:SonosWidgetTests/HueAmbienceRelayConfigTests -only-testing:SonosWidgetTests/MusicAmbienceManagerTests
git diff --check HEAD
git status --short
```

Expected:

- `npm test`: all tests pass.
- `npm run build`: exits 0.
- XCTest selected suites: `TEST SUCCEEDED`.
- `git diff --check HEAD`: exits 0.
- `git status --short`: only expected staged/unstaged files before final commit, then clean after commit.

- [ ] **Step 6: Commit Task 4**

```bash
git add SonosWidgetTests/HueAmbienceRelayConfigTests.swift Shared/HueAmbienceRelayConfig.swift
git commit -m "test: cover hue entertainment relay overrides"
```

---

## Final Report

Summarize:

- commits created
- iOS test result
- NAS test/build result
- behavior change: only Entertainment Area and Room/Zone can be selected; direct Light is legacy-only and sanitized away
