# UTERM-053: The Browser's Per-Tab Work Never Grows with the Tab Count on the Main Thread

**Status:** draft
**Created:** 2026-11-22
**Updated:** 2026-11-22

## Dependencies

- UTERM-005, for the browser applet and its tab records

## Impacts

- UTERM-041 — M1 makes the shared tab bar scroll. This proposal changes how the same bar creates and updates its items.
  See the first open question.
- UTERM-051 — it moves the layout decode off the main thread. That leaves this cost on the main thread at launch.
- UTERM-052 — it bounds the description's encode. This proposal bounds the refresh and the bar. Both walk every tab on
  each change. See "Whether the three per-tab walks share one fix".

## ADR Deviations

None.

## Summary

The browser pane's tab bar and refresh stop doing work for every tab each time something changes. Their main-thread
cost stops growing with the tab count.

## Motivation

`AppletTabBar.update` keeps one `AppletTabItem` view per title. It creates the missing views. Then it sets the index,
title, selection, and both closures on every item. `BrowserApplet.refresh` computes every tab's title and calls it. It
also rebuilds the published tab list and a change snapshot from every tab. The restoring init runs `wire` and
`refresh`, so each title is cleaned twice.

The cost was measured on 2026-11-22 in a debug build, with 10,000 tabs. The bar's first update took 1.17 s. An update
that changed only the selection took 61 ms. The restoring init took 1.63 s as a whole. Building the tab objects alone
took 7 ms. At 50,000 tabs the report measured a restore of about 11 s.

A refresh follows each load state and title change. A page chooses how often its title changes. So a page can make the
main thread pay 160 ms or more per change in a 10,000-tab pane.

ADR-08 allows only local work whose duration uniterm bounds on the main thread. A pane has no tab cap, so this work has
no bound. The bug is `20261122-browser-tab-bar-builds-a-view-per-tab-on-main-thread`.

## Design Decisions (Settled)

None yet.

## Design Decisions (Open)

### How this fits UTERM-041 and the tab-bar-overflow bug

UTERM-041 M1 turns the shared tab bar into a scrolling bar. The bug `20261121-tab-bar-overflow-hides-tabs` is fixed by
that change. Both change the layout of the bar this proposal changes.

Candidates:

- Land UTERM-041 M1 first. Design this proposal's windowing against the scrolling bar. Cost: the bug stays open until
  M1 lands.
- Fold the windowing into UTERM-041 M1. Cost: that milestone grows, and it is already settled and accepted. This is a
  scope addition to UTERM-041.
- Design this proposal first. Cost: UTERM-041 M1 is then redone against a windowed bar.

### How the bar bounds its per-tab work

Candidates:

- Show only the items that fit, and reuse them as the user scrolls or the selection moves. The bar already caps each
  item's width at a narrowest size, so only a bounded number can be visible. A scrolling bar and a windowed bar need
  the same visible-range calculation.
- Cap the tabs per pane. That brings in a product limit and a rule for stored panes over the cap. It would also bound
  every other cost that grows with the tab count.

### Whether a tab cap is in scope

A cap changes behavior a user can see. This question asks whether to add it before it asks how.

Candidates:

- No cap. The fix bounds the bar and the refresh, and nothing else.
- A cap on tabs per pane, with a stated value, a visible refusal, and a rule for a stored pane over the cap.

### How the refresh updates only what changed

Candidates:

- Keep each tab's cleaned title on the tab. Recompute it only when the raw title changes. The refresh then compares
  per-tab values, and it still walks every tab.
- Report which tab changed, and update that tab's entry in the published list and the snapshot. The cost becomes one
  tab's. This changes how the applet reports a change to the window, and UTERM-052 considers the same report.

### Whether the three per-tab walks share one fix

The bar, the refresh, and the description each walk every tab per change. UTERM-052 covers the description.

Candidates:

- One mechanism for all three, such as a per-tab change report. Cost: the proposals settle together.
- Separate fixes per walk. Cost: three bounded fixes, and the pane still walks every tab if one is skipped.

## Risks

- **A windowed bar shows a stale title or selection for a tab that scrolls into view** — likelihood: medium,
  impact: medium.
  Mitigation: a regression test scrolls a tab into view after its title changed and checks the item.
- **An incremental refresh drifts from a full one, so the published list disagrees with the tabs** — likelihood:
  medium, impact: high.
  Mitigation: a test compares the incremental result with a full rebuild after a random sequence of changes.
- **The windowed bar breaks VoiceOver, which reads every item today** — likelihood: medium, impact: low.
  Mitigation: UTERM-041's VoiceOver check runs against the windowed bar.

## Milestones

### M1: Measure the three walks

**Status:** NOT STARTED

The bug's numbers cover the bar and the restoring init. They leave out the refresh alone.

- The cost of the bar update, the refresh, and the description is recorded for 1,000, 10,000, and 50,000 tabs, in the
  As built block

### M2: Bound the bar and the refresh

**Status:** NOT STARTED

Waits on the open questions above.

- A test shows that a selection change costs the main thread no more at 10,000 tabs than at 10 tabs
- A test shows that a restore of 10,000 tabs creates a bounded number of views
- A test shows that a changed title reaches the bar when its tab is visible

## Decision Log

- 2026-11-22: Filed as a draft from bug `20261122-browser-tab-bar-builds-a-view-per-tab-on-main-thread`. A triage run
  reproduced the cost, estimated the fix as large with non-trivial decisions, and the user chose to open a proposal.

## References

- ADR-08: UI responsiveness
- Bug `20261122-browser-tab-bar-builds-a-view-per-tab-on-main-thread`
- Bug `20261121-tab-bar-overflow-hides-tabs`
- UTERM-041: the uniform tab marker slot
- UTERM-051: the launch reads the layout off the main thread
- UTERM-052: the browser's description never encodes tabs on the main thread
