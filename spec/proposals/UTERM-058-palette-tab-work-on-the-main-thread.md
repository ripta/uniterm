# UTERM-058: The Palette's Tab Work on the Main Thread

**Status:** draft
**Created:** 2026-11-23
**Updated:** 2026-11-23

## Dependencies

- UTERM-002, for the command palette and its tab entries
- UTERM-053, for the published tab list's shape, which the palette reads

## Impacts

- UTERM-053 — "The window's host-side walks stay out of scope, and the palette's cost is filed as a bug". This proposal
  is where the palette's cost lands.

## ADR Deviations

None identified yet. ADR-08 asks for main-thread work whose duration uniterm bounds. Today's palette work grows with
the tab count, and a pane has no tab cap.

## Summary

Decide how the command palette lists and filters tabs without main-thread work that grows with the number of tabs.

## Motivation

While the palette shows, every change a pane reports schedules a rebuild. `schedulePaletteRefresh` in
`MainWindowController+Palette.swift` coalesces rebuilds to at most one per 100 ms. It bounds how often a rebuild runs,
not the work in each.

Each rebuild runs `tabCandidates(target:)`. It loops over every pane and every tab of `publishedTabs.all`. It
neutralizes each title and detail, and builds a `PaletteEntry` for each tab. It then builds a `Set` of the live keys to
prune the recency list, and runs `firstIndex` on the recency list once per tab.

Each keystroke filters every candidate. Choosing a tab, and scripting's tab lookups in `WindowScripting.swift`, scan the
published list once per call.

So a background page in a large browser pane that changes its title in a loop costs up to 10 full rebuilds a second,
while the palette shows. A pane has no tab cap, per UTERM-039 and UTERM-053.

UTERM-053 kept these walks out of its scope. It rejected bounding the rebuild there as an addition, since that leaves
the per-keystroke filter linear and needs a per-tab change report from every applet to the host.

Filed from bug
[20261122-palette-rebuild-walks-every-tab](../bugs/20261122-palette-rebuild-walks-every-tab.md). The trace was
confirmed against the tree on 2026-11-23. The cost was not measured.

## Design Decisions (Settled)

None.

## Design Decisions (Open)

### How the palette's tab work is bounded

Candidates:

- An incremental palette index. The palette keeps its tab entries between rebuilds, and updates only the tabs that
  changed. That needs a per-tab change report. See the next question. The per-keystroke filter still visits every
  candidate unless the index also supports a filter that does not.
- A bound on the candidates. A rebuild and a filter visit at most a fixed number of tabs, such as the most recent ones
  and the selected tab of each pane. This changes what the palette lists for a pane with many tabs. A user can no
  longer reach every tab by name through the palette.
- No rule. The palette keeps walking every tab, as today. This leaves the ADR-08 gap the bug names.

The measurement in M1 may show the cost is too small to matter at realistic tab counts. That would favor no rule, with
a recorded bound.

### How the palette learns which tab changed

Applies only to an incremental index. Today an applet reports that its tabs changed, not which tab. Candidates include a
per-tab change report in the host contract that every tab-publishing applet implements, and a revision per tab that the
palette compares, as UTERM-052's saved-state revision does for a whole applet. Either is a new host contract.

### Whether scripting's tab lookups change too

`chooseTab` and scripting's tab lookups scan the published list once per call. Open: whether they move to the same
index, or stay out of scope as one bounded scan per call.

## Risks

- **A bound on candidates hides tabs the user expects to find** — likelihood: medium, impact: medium, if that candidate
  wins. Mitigation: the palette would say when it lists fewer tabs than a pane holds. The tab bar is not a fallback
  yet, since bug `20261121-tab-bar-overflow-hides-tabs` leaves tabs past its trailing edge out of reach.
- **A per-tab change report that an applet forgets leaves the palette stale** — likelihood: medium, impact: low, if the
  index candidate wins. Mitigation: a contract test per applet, as UTERM-052 does for its revision.

## Milestones

### M1: Measure the palette's tab work

**Status:** NOT STARTED

Further milestones are written once the open questions settle.

- The cost of one palette rebuild is recorded for 1,000 and 10,000 tabs in one browser pane, in the As built block
- The cost of one keystroke's filter is recorded for the same counts, in the As built block
- The cost per second is recorded while a background page changes its title on a timer and the palette shows

## Decision Log

- 2026-11-23: Filed as a draft from bug `20261122-palette-rebuild-walks-every-tab`. The user asked for a proposal at
  its triage. The bug's two fix options became candidates under "How the palette's tab work is bounded", and "No rule"
  was added as the plain behavior. The change report became a follow-up question, and scripting's lookups a third. M1
  measures the cost first, since no one has measured it.

## References

- ADR-08: UI responsiveness
- [UTERM-053](UTERM-053-browser-tab-work-never-grows-with-the-tab-count-on-the-main-thread.md): the browser's per-tab
  work, which ruled the palette out of scope
- [UTERM-052](UTERM-052-browser-description-never-encodes-tabs-on-the-main-thread.md): the saved-state revision
- Bug [20261122-palette-rebuild-walks-every-tab](../bugs/20261122-palette-rebuild-walks-every-tab.md)
