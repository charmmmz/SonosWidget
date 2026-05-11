# Hue Ambience Target Scope Design

## Goal

Music Ambience should expose only two Hue target scopes:

- Entertainment Area
- Room / Zone

Direct individual Light targets are removed from the setup flow. Entertainment
Areas should trust the Hue app's own area membership and should not apply the
app's task/decorative function filtering. Room and Zone targets keep the current
default light filtering and remain the only scopes that allow manual light
include/exclude edits.

## Behavior

### Entertainment Area

When a Sonos speaker is assigned to an Entertainment Area:

- All color-capable lights contained in that Entertainment Area may participate.
- Hue light function metadata is ignored for selection. A light marked for tasks
  can still participate if Hue includes it in the Entertainment Area.
- Manual `includedLightIDs` and `excludedLightIDs` are ignored and cleared.
- The setup UI does not show the expandable Lights editor.
- NAS and iOS local rendering resolve the same set of lights.

This treats Entertainment Area as the user's explicit Hue-side sync group.

### Room / Zone

When a Sonos speaker is assigned to a Room or Zone:

- Existing task/decorative filtering remains in place.
- Lights marked as task/functional are excluded by default.
- Lights with unresolved function metadata are excluded by default.
- Users may manually include or exclude lights from the expandable Lights editor.
- Manual edits are persisted and synced to NAS.

This keeps Room/Zone behavior conservative because those Hue scopes are usually
general-purpose lighting groups rather than explicit ambience groups.

### Direct Light

Direct Light target selection is no longer offered in the Music Ambience setup.
Existing direct-light mappings from older builds are treated as legacy data:

- They are not displayed as assignable options.
- They are removed by mapping/resource sanitization when possible.
- They are not generated in new relay configs.

## Data Flow

1. Hue resource refresh loads Entertainment Areas, Rooms, Zones, and Lights.
2. Assignable area options include only Entertainment Areas, Rooms, and Zones.
3. Assigning an Entertainment Area creates a mapping with empty include/exclude
   overrides.
4. Assigning a Room or Zone keeps the existing override model.
5. iOS local rendering and NAS relay rendering both use the selected target kind
   to decide whether function filtering applies.

## Implementation Notes

- Add a target-kind helper for "allows manual light editing" so UI and sanitizer
  rules are explicit rather than inferred from labels.
- Keep the `HueAmbienceTarget.light` enum case if needed for backwards Codable
  compatibility, but stop creating it from Music Ambience UI.
- For Entertainment Area resolution, still enforce basic safety checks:
  the light must exist, belong to the selected Hue area/device, and support color.
  Only the function metadata and manual include/exclude checks are bypassed.
- For Room/Zone resolution, keep current behavior.
- Mirror the same resolver rule in `Shared/HueAmbienceRenderer.swift` and
  `nas-relay/src/hueRenderer.ts`.

## Testing

Add focused tests for:

- iOS assignable options exclude direct Light pseudo-targets.
- iOS setup row shows the Lights editor only for Room/Zone mappings.
- iOS resolver includes task/function lights for Entertainment Area mappings.
- iOS resolver still excludes task/function lights by default for Room/Zone.
- iOS mapping sanitization clears include/exclude overrides for Entertainment
  Areas and removes legacy direct Light targets.
- NAS resolver includes task/function lights for Entertainment Area mappings.
- NAS resolver still excludes task/function lights by default for Room/Zone.
- NAS config normalization clears include/exclude overrides for Entertainment
  Area mappings and removes legacy direct Light targets.

## Non-Goals

- Do not add per-light Music Ambience assignment.
- Do not change Hue Bridge pairing, album color extraction, or motion behavior.
- Do not change true Entertainment streaming transport work.
