# Home Speaker Ordering

## Status

Implemented. Home speaker cards can be reordered directly from the Home screen,
and the preferred order persists across app refreshes.

## Behavior

The Home screen reuses speaker-card drag and drop for two related actions:

- Drop near the top edge of a card to place the dragged group before that card.
- Drop near the bottom edge of a card to place the dragged group after that card.
- Drop near the center of a card to merge the dragged group into the target
  group, preserving the existing grouping behavior.

This keeps the Home screen dense and avoids introducing a separate ordering
sheet or another toolbar control.

## Persistence

`SharedStorage.homeSpeakerGroupOrder` stores the preferred Home order as an
array of stable group identifiers in the app-group defaults. `SonosManager`
applies that order whenever group statuses are refreshed from LAN, Cloud, or
fallback paths.

The ordering algorithm ranks groups by the saved identifiers first. Unknown or
new groups fall back to a deterministic name/id sort so newly discovered
speakers still appear predictably.

## Main Components

| Component | Responsibility |
| --- | --- |
| `SharedStorage.homeSpeakerGroupOrder` | Persists the user's preferred group order |
| `SonosManager.sortedSpeakerGroups` | Applies saved order with deterministic fallback sorting |
| `SonosManager.speakerGroupDropIntent` | Interprets drop position as reorder-before, merge, or reorder-after |
| `SonosManager.reorderSpeakerGroup` | Reorders the current Home group list and writes the new order |
| `PlayerView` | Provides card drag/drop, target highlighting, and calls manager reorder/merge actions |

## Design Notes

The final implementation differs from the original planning sketch. The plan
considered a dedicated ordering sheet, but the shipped behavior uses edge-based
drop zones because it combines naturally with the existing grouping gesture:
one drag can either reorder or group depending on where it lands.

The top and bottom 25% of a target card are reorder zones. The center 50% keeps
the existing grouping action. Tests cover those thresholds so later UI changes
do not accidentally make grouping and ordering ambiguous.

## Verification

`SpeakerOrderingTests` covers:

- Applying a saved order ahead of alphabetical fallback.
- Persisting order after moving a group.
- Mapping card drop position to reorder-before, merge, or reorder-after.
- Reordering relative to a target and writing the updated storage order.
