# UTERM-053: The Browser's Per-Tab Work Never Grows with the Tab Count on the Main Thread

**Status:** draft
**Created:** 2026-11-22
**Updated:** 2026-11-22

## Dependencies

- UTERM-005, for the browser applet and its tab records

## Impacts

- UTERM-041 — M1 makes the shared tab bar scroll, and makes `AppletTabBar.update` take published tabs. This proposal
  changes how the same bar creates and updates its items, and may change `AppletTabList`'s shape. Its VoiceOver check
  bears on a windowed bar. See "How this fits UTERM-041" and "What VoiceOver reaches in a windowed bar".
- UTERM-051 — it moves the layout decode off the main thread. That leaves this cost on the main thread at launch.
- UTERM-052 — it bounds the description's encode, and asks the same tab cap question. The refresh and the description
  both need to know which tab changed. See "Whether the three per-tab walks share one fix" and "Whether a tab cap is in
  scope".

## ADR Deviations

None.

## Summary

The browser pane's tab bar and refresh stop doing work for every tab each time something changes. Their main-thread
cost stops growing with the tab count.

## Motivation

### The walks

`AppletTabBar.update` keeps one `AppletTabItem` view per title. It creates the missing views. Then it sets the index,
title, selection, and both closures on every item. Each of those setters re-sets the item's accessibility identifier,
label, and value, with no check that the value changed. `layout()` sets a frame on every item on every layout pass, and
each update and each resize asks for one. `apply(_:)` walks every item at a theme change.

`BrowserApplet.refresh` cleans every tab's title and hands the list to the bar. It rebuilds the published
`AppletTabList` from every tab. That list is an immutable struct, so changing one entry builds a new one, and its init
scans every tab to check the selection. `refresh` also builds a change snapshot that copies every tab's record, ID, and
title, and compares it with the last one.

The private init cleans every title once for `publishedTabs`. It then calls `refresh()`, which cleans them all again
and overwrites that list.

The window and the palette read the published list. The palette rebuilds its candidates from every tab of every pane
while it shows, and each tab change schedules a rebuild. Scripting walks the list to report tabs. Those host-side walks
are out of this proposal's scope unless the open question below brings them in.

### Where a large count comes from

A stored layout can hold any number of tabs. A controller can open tabs with no limit. A page the user granted can open
pop-ups with no limit. Each open runs a full refresh, so a loop that opens N tabs one by one costs the main thread work
that grows with N².

### The cost

The cost was measured on 2026-11-22 in a debug build, with 10,000 tabs. The bar's first update took 1.17 s. An update
that changed only the selection took 61 ms. Computing the titles took about 99 ms more, per the bug's measurement. The
restoring init took 1.63 s as a whole. Building the tab objects alone took 7 ms. At 50,000 tabs the report measured a
restore of about 11 s.

A refresh follows each load state and title change, including a background tab's. A page chooses how often its title
changes. So a page can make the main thread pay about 160 ms per change in a 10,000-tab pane.

ADR-08 allows only local work whose duration uniterm bounds on the main thread. A pane has no tab cap, so this work has
no bound. The bug is `20261122-browser-tab-bar-builds-a-view-per-tab-on-main-thread`.

### Who shares the bar

The terminal and the questions applet use the same `AppletTabBar`. The terminal updates it at each title a program
sets, and it has no tab cap. The questions applet caps its tabs. A change to the bar reaches all three.

## Design Decisions (Settled)

None yet.

## Design Decisions (Open)

### How this fits UTERM-041

UTERM-041 is accepted, and its M1 has not started. Its scrolling bar is settled: the bar takes published tabs, hides
below two tabs, scrolls by trackpad and shift-scroll, shows that more tabs lie past an edge, and keeps the selected tab
fully in view. The bug `20261121-tab-bar-overflow-hides-tabs` is fixed by that milestone.

Candidates:

- Design the windowing now, against UTERM-041's settled bar. Build it in a milestone that depends on UTERM-041 M1, and
  list UTERM-041 under Dependencies. Nothing waits, and nothing built is redone.
- Fold the windowing into UTERM-041 M1. That milestone grows, and it is already accepted. This is a scope addition to
  UTERM-041.
- Wait for UTERM-041 M1 to land, then design this. The design waits for no reason the bar's contract gives.

### How the bar bounds its per-tab work

All items have one width, so the visible range is plain arithmetic from the scroll offset.

Candidates:

- A hand-built windowed bar inside UTERM-041's scroll view. It keeps only the items that fit, plus a margin, and rebinds
  them as the bar scrolls or the selection moves. An item's select and close actions carry the tab's ID, not its
  index, since a reused item changes index and a close runs later in a task.
- An AppKit reuse container, such as `NSCollectionView` with a fixed-size layout. It brings reuse, scroll-to-item, and
  accessibility for items off screen. It is a heavier component to keep inside UTERM-041's look.
- Guard each item setter on equality, and stop rebuilding the closures. This is a shortcut. It leaves the walk over
  every item, the view per tab, and the layout of every item in place.

### What the bar takes as input

A windowed bar still costs the main thread a walk if its caller builds a full array of titles on every refresh. So the
bar's input contract decides whether a selection change can be bounded. UTERM-041 settled that the bar takes published
tabs, so the shape of `AppletTabList` is a joint constraint.

Candidates:

- The bar holds the applet's list and re-reads only its visible items at each update. The list is not rebuilt per
  change. A stale item cannot happen, since the bar never keeps its own copy of a title.
- The bar asks a data source for the count and for the item at an index.
- The bar keeps taking a full list per update. This leaves a walk per change, and it rules out a bounded selection
  change.

### What VoiceOver reaches in a windowed bar

UTERM-041 M1 checks that a VoiceOver user reaches each tab's markers and its close button. A windowed bar has no
element for a tab off screen. The palette and the keyboard still reach every tab, but a tab's markers show only in the
bar. Whether VoiceOver's scroll commands make the bar load more items is not yet known.

Candidates:

- Expose an accessibility element per tab without a view per tab, from the bar's own accessibility children. The
  elements are cheap objects, and they are built when VoiceOver asks.
- Rely on VoiceOver scrolling to bring items into view, once a test shows it does. That may amend UTERM-041 M1's
  VoiceOver check.
- Use the AppKit reuse container's accessibility, if that candidate wins above.

### How the refresh updates only what changed

`tabDidChange` already names the changed tab. So the applet can apply a change without asking the window to change its
side of the contract. UTERM-041 M1 adds markers to the refresh, and one grant end can change many tabs' markers. A
change can name a set of tabs.

Candidates:

- Keep each tab's cleaned title and published entry on the tab. Apply changes from the named tab or set of tabs. Drop
  or reshape the change snapshot. Change `AppletTabList`'s shape so that updating one entry and checking the selection
  each cost one tab's work. `AppletTabList` is shared by every applet, the palette, and scripting, and it ships in the
  same app. Scripting maps it to script values, so the script-facing form is unchanged.
- Keep each tab's cleaned title on the tab, and recompute it only when the raw title changes. This is a shortcut. It
  removes the cleaning, about 99 ms at 10,000 tabs, and leaves the walk over every tab, the list rebuild, and the
  snapshot in place.

### What counts as bounded under ADR-08

ADR-08 asks for main-thread work whose duration uniterm bounds. It does not say the cost must be constant. The
candidates above differ on exactly this.

Candidates:

- Per change, the main thread does a constant amount of work per changed tab, plus the visible items.
- Per change, a walk over every tab is allowed when each step is a cheap comparison, under a stated tab count.

### Whether the three per-tab walks share one fix

The bar, the refresh, and UTERM-052's description each walk every tab per change. They are not one kind. Only windowing
bounds the views and the layout. A windowed bar re-reads its visible items, so it needs no change report. The refresh
and the description both need to know which tab changed.

Candidates:

- The refresh and the description share one per-tab change mechanism. The bar is bounded on its own by windowing.
- One mechanism for all three. The bar gets a report it does not need, and the three proposals settle together.
- A separate fix per walk. The refresh and the description each build their own change tracking.

### Whether a tab cap is in scope

UTERM-052 asks the same question. Settling it twice could settle it two ways. A cap cannot bound a restore without
losing data. A restore of a stored pane over the cap must either load every tab, which is the unbounded cost again, or
drop or defer tabs. A cap does bound the opening loop and the web content processes. The questions applet's cap is a
precedent.

Candidates:

- No addition. The fix bounds the walks, and the pane keeps no cap.
- A cap on tabs per pane, with a stated value, a visible refusal, and a rule for a stored pane over the cap. This adds
  a product limit beside the pop-up limit and the questions cap.

Which proposal settles it is part of the answer. The other references the result.

### Whether the terminal's own walks are in scope

The bar change reaches the terminal either way. The terminal also builds its full title list at each title a program
sets.

Candidates:

- No addition. The terminal gets the bounded bar and keeps its own title list.
- Bound the terminal's title updates too. This adds the terminal applet to the scope.

### Whether the host-side walks are in scope

The palette rebuilds its candidates from every tab of every pane, and scripting walks the list to report tabs.

Candidates:

- No addition. Name them out of scope.
- Bound the palette's rebuild too. This adds host-side scope.

## Risks

- **An incremental refresh drifts from a full one, so the published list disagrees with the tabs** — likelihood:
  medium, impact: high.
  Mitigation: an M2 check compares the incremental result with a full rebuild after a random sequence of changes.
- **A reused item acts on the wrong tab** — likelihood: medium, impact: high.
  Mitigation: items carry tab IDs, and an M2 check closes a tab through a reused item.
- **`AppletTabList` changes shape under every applet while UTERM-041 M1 adds markers to it** — likelihood: medium,
  impact: medium.
  Mitigation: settle "How this fits UTERM-041" so the two changes land in a stated order.

## Milestones

### M1: Bound the bar and the refresh

**Status:** NOT STARTED

Waits on the open questions above.

- A test counts, for one selection change at 10,000 tabs, the item views rebound, the titles cleaned, and the list
  entries rebuilt. Each count is at most a constant that does not depend on the tab count
- A test shows that a restore of 10,000 tabs creates a bounded number of item views, and that a layout pass sets at most
  that many frames
- A test shows that a resize and a theme change at 10,000 tabs each touch a bounded number of items
- A test shows that a title that changes while its tab is off screen shows when the tab scrolls into view
- A test shows that closing a tab through a reused item closes that tab, by ID
- A test compares the incremental published list with a full rebuild after a random sequence of opens, closes, moves,
  title changes, and selections
- A test shows that opening 1,000 tabs one by one does work linear in the count
- The bar, the refresh, and the restoring init are timed at 1,000, 10,000, and 50,000 tabs, before and after, in the
  As built block

## Decision Log

- 2026-11-22: Filed as a draft from bug `20261122-browser-tab-bar-builds-a-view-per-tab-on-main-thread`. A triage run
  reproduced the cost, estimated the fix as large with non-trivial decisions, and the user chose to open a proposal.
- 2026-11-22: Revised after a design critique. The second title cleaning comes from the private init, not from `wire`.
  The 160 ms figure now cites the bug's 99 ms for the titles. The Motivation names the missed per-tab costs, the
  sources of a large count, and the other applets on the bar. The cap moved out of the bar question. Added candidates:
  designing against UTERM-041's settled bar, an AppKit reuse container, setter guards labeled as a shortcut, and the
  complete incremental refresh. The refresh candidate that claimed one tab's cost was false while `AppletTabList` and
  the snapshot stay linear, so it was folded into the complete one. Added questions for the bar's input, VoiceOver
  reach, the ADR-08 bound, the terminal, and the host walks. The VoiceOver risk became an open question. The
  measurement milestone could not fail, so its timing moved into the As built block. The checks now count work, not
  time.

## References

- ADR-08: UI responsiveness
- Bug `20261122-browser-tab-bar-builds-a-view-per-tab-on-main-thread`
- Bug `20261121-tab-bar-overflow-hides-tabs`
- UTERM-041: the uniform tab marker slot
- UTERM-051: the launch reads the layout off the main thread
- UTERM-052: the browser's description never encodes tabs on the main thread
