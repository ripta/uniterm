# UTERM-038: A Program's Map Move Is Saved as the User's Is

**Status:** draft
**Created:** 2026-11-21
**Updated:** 2026-11-21

## Dependencies

- UTERM-008, for the map's `set-region` command

## Impacts

- UTERM-008 — M3: the As built bullet that `set-region` "is not saved with the pane, since a program's move is not the
  user's". Superseded in part.

## Summary

A map region a program sets with `set-region` is saved with the pane, as the user's Go to Place is.

## Motivation

ADR-12 was retracted on 2026-11-20. A program's operation is the same operation as the user's, and it behaves the same
way. The user ruled that the retraction must be followed through. Implemented proposals stay frozen. Where their code
still follows a rule the retraction removed, the fix is follow-up work in a new proposal.

The map's `set-region` is such a place. It shows the region and never saves it, because "a program's move is not the
user's". Every matching user move saves. Go to Place calls `regionSettled`, and so do Zoom to Fit Pins and the zoom and
Face North commands. A program's move is lost at relaunch, where the user's identical move is kept.

UTERM-008 is implemented, so its text is frozen. This proposal records the change and supersedes the affected part.

## Design Decisions (Settled)

### A program's region is the user's region

Decision: `set-region` saves its region with the pane, through the same path Go to Place uses.

- The region passes `GeoRegion`'s checks, as it does now.
- The gesture gate is unchanged. It filters MapKit's own reports after a resize, after a set, and for the empty-pane
  default. Those reports come from no one's move, so they apply to every source.
- The saved region lands in the description's payload, where a user's region goes. A region carries no secret, unlike
  a program's pins, which stay in the undo-only part.

Rationale: a program's operation behaves as the user's. Go to Place is the user's way to set a region outright, and it
saves.

## Design Decisions (Open)

None.

## Risks

- **A program's move rewrites the layout file** — likelihood: high, impact: low. Each `set-region` writes the layout, as
  each Go to Place does. Accepted: the user's Go to Place writes the same way, and a program's operation behaves as
  the user's.

## Milestones

### M1: Program moves are saved

**Status:** NOT STARTED

- `set-region` saves its region with the pane, and a reopen or relaunch shows it
- MapKit's own region reports after a set or a resize are still not saved
- `testSetRegionRunsGeoRegionsChecksAndIsNotSaved` becomes a test that the region is saved
- UTERM-008 carries a "Superseded in part by UTERM-038" marker on the `set-region` bullet

## Decision Log

- 2026-11-21: Drafted as follow-up work after an audit of the proposals for ADR-12's retraction. A verifier confirmed
  that `set-region` skips the save that every user move makes.

## References

- UTERM-008: the map viewer and its program commands
- UTERM-037: a controller's browser commands act as the user's
- [ADR-12](../adr/ADR-12-unchosen-changes-never-move-focus-or-arm-input.md): retracted
