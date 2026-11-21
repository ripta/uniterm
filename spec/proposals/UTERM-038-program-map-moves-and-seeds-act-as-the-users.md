# UTERM-038: A Program's Map Move and Browser Seed Act as the User's

**Status:** accepted
**Created:** 2026-11-21
**Updated:** 2026-11-21

## Dependencies

- UTERM-008, for the map's `set-region` command
- UTERM-037, for the browser's layout `url` seed

## Impacts

- UTERM-008 — M3: the As built bullet that `set-region` "is not saved with the pane, since a program's move is not the
  user's". Superseded in part.
- UTERM-037 — "Each command is the user's action": the bullet that a layout seed refuses search text and app addresses,
  and M1's As built and Decision Log entry on it. Superseded in part.

## Summary

A map region a program sets with `set-region` is saved with the pane, as the user's Go to Place is. A browser pane's
layout `url` seed resolves as the user's typed address does, so search text searches and an app address asks.

## Motivation

ADR-12 was retracted on 2026-11-20. A program's operation is the same operation as the user's, and it behaves the same
way. ADR-15, still proposed, states that principle. The user ruled that the retraction must be followed through.
Implemented proposals stay frozen. Where their code still makes a program's action differ from the user's, the fix is
follow-up work in a new proposal.

Two such places remain:

- The map's `set-region` shows the region and never saves it, because "a program's move is not the user's". Every
  matching user move saves. Go to Place calls `regionSettled`, and so do Zoom to Fit Pins and the zoom and Face North
  commands. A program's move is lost at relaunch, where the user's identical move is kept.
- A browser pane a layout creates loads its `url` seed by the typed scheme rule, but refuses search text and app
  addresses. The user's equivalent is a new browser pane with that text typed in. It searches, or asks to open the app.

UTERM-008 and UTERM-037 are implemented, so their text is frozen. This proposal records the changes and supersedes the
affected parts.

## Design Decisions (Settled)

### A program's region is the user's region

Decision: `set-region` saves its region with the pane, through the same path Go to Place uses.

- The region passes `GeoRegion`'s checks, as it does now.
- The gesture gate is unchanged. It filters MapKit's own reports after a resize, after a set, and for the empty-pane
  default. Those reports come from no one's move, so the gate applies to every source. ADR-15 keeps such a rule for
  programs too.
- The saved region lands in the description's payload, where a user's region goes. A region carries no secret, unlike
  a program's pins, which stay in the undo-only part.

Rationale: a program's operation behaves as the user's. Go to Place is the user's way to set a region outright, and it
saves. Chosen by the user on 2026-11-21.

### A layout seed is a typed address

Decision: a browser pane's layout `url` seed runs the user's typed-address path in the new pane's first tab.

- Search text searches with the chosen engine, as typed text does.
- An app address asks to hand off as a typed one does, through the same question and the same rule for which page may
  ask.
- The schemes no source may load stay refused at parse time, before any pane is made. That is a rule for every source,
  per ADR-15. The seed still needs browser navigation, which is ADR-15's authority carve-out.
- Text that cannot resolve, such as a search with no engine, is refused at parse time, before any pane is made.

Rationale: a program's operation behaves as the user's. Opening a browser pane and typing into it is the user's
equivalent of a seeded pane. Chosen by the user on 2026-11-21.

## Design Decisions (Open)

None.

## Risks

- **A program's move rewrites the layout file** — likelihood: high, impact: low. Each `set-region` writes the layout, as
  each Go to Place does. Accepted: the user's Go to Place writes the same way, and a program's operation behaves as the
  user's.
- **A layout can ask to open another app** — likelihood: low, impact: medium. A seeded app address asks the user, as a
  typed one does. Accepted: the user answers the question, and the layout already needs browser navigation.

## Milestones

### M1: Program moves and seeds act as the user's

**Status:** DONE

- `set-region` saves its region with the pane, and a reopen or relaunch shows it
- MapKit's own region reports after a set or a resize are still not saved
- `testSetRegionRunsGeoRegionsChecksAndIsNotSaved` becomes a test that the region is saved
- A layout seed of search text searches, and an app address asks as a typed one does
- A seed with a scheme no source loads, or text that cannot resolve, is refused before any pane is made
- UTERM-008 and UTERM-037 carry "Superseded in part by UTERM-038" markers on the replaced text

**As built:**

- `set-region` shows the region and then saves it through `regionSettled`, the path Go to Place uses. That function is
  no longer private. The gesture gate in the map view is unchanged, so MapKit's report after a set is dropped and saves
  nothing. A refused region still saves nothing.
- A layout's browser `url` rides to the pane as the typed text, as `AppletChoice.browserPage(String)`. The request
  reader checks it with the typed-address rule. A scheme no source loads, empty text, and a search that no engine can
  turn into an address are refused as bad arguments before any pane is made. Search text and app addresses pass.
- `BrowserApplet(seed:)` takes the text and holds it until `start`. Then it runs `commit(address:in:)` on the first tab,
  the path a typed address and a controller's navigate use. Search text searches with the engine chosen at that time.
  An app address asks through the same question and the same rule for which page may ask. The first tab's owner for a
  remote-controlled pane is adopted as before.
- The reader checks a search against every engine, since the engine is a setting read at start. No engine can fail
  today, so that refusal is not reachable from the wire.
- A seeded tab's stored address is empty until it loads, where a resolved seed stored it at once. A pane that is
  described before it starts has no first page.
- Skew: the layout request wire accepts more seed text. An older app refuses search and app-address seeds at parse time
  with a bad argument, before any pane is made, so a controller that sends one sees a refusal and never a wrong page.
  A newer app accepts every seed an older one did. No deploy order is needed.
- Nothing beyond the checks.

## Decision Log

- 2026-11-21: Drafted as follow-up work after an audit of the proposals for ADR-12's retraction. A verifier confirmed
  that `set-region` skips the save that every user move makes.
- 2026-11-21: The user accepted it to build now, and ruled that a layout seed resolves as typed. The seed decision was
  added here, since UTERM-037 is frozen.

## References

- UTERM-008: the map viewer and its program commands
- UTERM-037: a controller's browser commands act as the user's
- [ADR-12](../adr/ADR-12-unchosen-changes-never-move-focus-or-arm-input.md): retracted
- [ADR-15](../adr/ADR-15-a-programs-operation-is-the-users.md): proposed
