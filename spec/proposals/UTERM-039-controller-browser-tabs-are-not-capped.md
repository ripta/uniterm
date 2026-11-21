# UTERM-039: A Controller's Browser Tabs Are Not Capped

**Status:** draft
**Created:** 2026-11-21
**Updated:** 2026-11-21

## Dependencies

- UTERM-005, for the browser's remote commands
- UTERM-037, for the rule that a controller's open is the user's New Tab

## Impacts

- UTERM-037 — "What stays": the sentence that the per-grant tab cap stays, and the Rationale sentence on the cap.
  Superseded in part.
- UTERM-037 — M1: the check that permissions, tab ownership, and the per-grant cap are unchanged. Superseded in part.
- UTERM-005 — M8 As built: the note that a grant holds at most 16 open tabs and the 17th open is refused as busy.
  Superseded in part.
- UTERM-005 — Decision Log, 2026-11-20: the entry that a grant holds at most 16 open tabs in a pane. Superseded.

## Summary

A controller may open as many browser tabs as the user may. The 16-tab cap per grant per pane is dropped. A controller's
`open` behaves as the user's New Tab, and revoking the controller is the safety.

## Motivation

UTERM-005 M8 added the cap as a work-queue best guess, tagged an addition. The user never ruled on it. Its text says that
"Control" bounded nothing about how many tabs a controller opens.

The cap is not authority. The review text for the browser permission never mentions it. The text reads "Open and
navigate browser tabs, with network access signed in as you, whatever its sandbox allows"
(`Packages/UnitermKit/Sources/ControllerTrust/ControllerPolicy.swift:237-239`). A user who approves that text learns of
no limit. Each grant also gets its own 16, so the cap does not bound a pane.

The cap is a behavior difference between a controller's `open` and the user's New Tab. ADR-15 says a program's
operation behaves as the user's, and keeps only authority apart. The user ruled on 2026-11-21 that the cap goes.

UTERM-005 and UTERM-037 are implemented, so their text is frozen. This proposal records the change and supersedes the
affected parts.

## Design Decisions (Settled)

### No cap on a controller's tabs

Decision: a controller's `open` is the user's New Tab with an address typed into it, and nothing bounds how many it may
make.

- `controllerTabLimit` and its refusal are removed from `BrowserApplet+Remote.swift:83-104`.
- The refusal was the one place the browser's remote commands replied `busy` for a tab count. The `busy` code stays in
  the shared dispatcher for a full command queue (`ControlDispatcher.swift:156`, `:424`).
- A page's own script-opened tabs keep their limit (`BrowserApplet.swift:1132`). That limit bounds a page, which no user
  action matches, and it is not a controller's cap.
- Ownership is unchanged. A controller still reaches only the tabs it opened, for its live grant.

Rationale: a program's operation behaves as the user's, per ADR-15. The user's New Tab has no cap. The cap was a guard on
one source, which ADR-15 names as the pattern that left neighbors open. The safety belongs in authority. The controller
needs the browser navigation permission, and the user may revoke it. Chosen by the user on 2026-11-21.

### What stays

Decision: authority is unchanged. Browser navigation gates `open`. A command reaches only a tab its caller opened, for
the caller's live grant. The schemes that no source may load stay refused.

Rationale: authority decides who may act, not how many times. This rests on ADR-15's authority carve-out and ADR-14.

## Design Decisions (Open)

None.

## Risks

- **A runaway controller opens tabs without bound** — likelihood: low, impact: medium. Each tab is a web view and may
  start a content process. Nothing bounds a controller's tabs until the user revokes it. Accepted: the user's own tabs
  have no bound either, and the controller already holds browser navigation.

## Milestones

### M1: Drop the cap

**Status:** NOT STARTED

- `open` is never refused for the number of tabs the caller holds
- `controllerTabLimit` and its refusal are gone
- `testAGrantMayHoldOnlyAFixedNumberOfTabs` (`BrowserRemoteTests.swift:218-244`) is replaced by a test that an open past
  the old limit succeeds and builds a tab
- Another grant's opens, tab ownership, and the permission check are unchanged
- UTERM-037 and UTERM-005 carry "Superseded in part by UTERM-039" markers on the replaced text

Version skew: a removed `busy` reply. A newer app accepts every open an older one did. An older app refuses the 17th
open from one grant with `busy`, a code the dispatcher also sends for a full queue, so a controller that handles it for
the queue handles it here. A controller that relied on that refusal as a limit sees none on a newer app. No deploy order
is needed.

## Decision Log

- 2026-11-21: Filed after the user ruled that a controller's browser tabs have no cap. The 16-tab cap came from a
  work-queue addition in UTERM-005 M8 that the user never ruled on. The user chose a superseding proposal so
  UTERM-005's and UTERM-037's frozen text keeps a record of the cap.
- 2026-11-21: Returned to draft. It was filed as accepted without critique or proposal review. It goes through
  both before it is accepted.

## References

- UTERM-005: the browser applet and its remote commands
- UTERM-037: a controller's browser commands act as the user's
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): authority, which this proposal leaves unchanged
- [ADR-15](../adr/ADR-15-a-programs-operation-is-the-users.md): "No cap" rests on the rule that a program's operation
  is the user's. "What stays" rests on its authority carve-out
