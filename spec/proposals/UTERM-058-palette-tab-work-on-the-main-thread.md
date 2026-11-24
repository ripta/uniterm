# UTERM-058: The Palette's Tab Work on the Main Thread

**Status:** accepted
**Created:** 2026-11-23
**Updated:** 2026-11-23

## Dependencies

- UTERM-002, for the command palette and its tab entries
- UTERM-053 M1, for the published tab list's read-through view and its change type. M1 here measures after it lands

## Impacts

- UTERM-053 — "The window's host-side walks stay out of scope, and the palette's cost is filed as a bug". This proposal
  is where the palette's cost lands.
- UTERM-053 — "Scripting's tab lookups need no new contract" adds a check to UTERM-053 M1: the browser's `contains` and
  `selectTab(id:)` resolve through its ID map. "The tab report names what changed by ID" makes the read-through view
  return a tab's details by ID. It also makes the host's change value share UTERM-053's change type, so UTERM-053's
  refresh change names removed tabs by ID instead of by position. UTERM-053 records these amendments in its own
  decisions and Decision Log.
- Bug `20261122-terminal-tab-changes-walk-every-tab` — M2 fixes its lookups by tab ID. Its other walks stay with it.
- UTERM-002 — "The palette ranks tabs off the main thread" replaces the live query's walk of the pane tree, and keeps a
  second copy of each tab's derived text. UTERM-002 is implemented, so it is superseded in part, not edited.

## ADR Deviations

- ADR-08, no carve-out: a pane's first ingest into the palette's index reads each of its tabs once on the main thread.
  It runs once per restore, bulk open, or applet swap, and rides on work that is already linear in the tabs it brings.
  UTERM-053 declares the applet's own share of that work. This entry covers the window's share.
- ADR-08, no carve-out: a pane is read again in full after a pane-level event, such as a terminal's start, and after
  the index finds its count disagrees with the pane's. A pane-level event already walks every tab once, per UTERM-053.
  A count mismatch happens only after an applet reports a change wrongly.

## Summary

Decide how the command palette lists and filters tabs without main-thread work that grows with the number of tabs.

## Motivation

While the palette shows, every change a pane reports schedules a rebuild. `schedulePaletteRefresh` in
`MainWindowController+Palette.swift` coalesces rebuilds to at most one per 100 ms. It bounds how often a rebuild runs,
not the work in each.

Each rebuild runs `tabCandidates(target:)`. It loops over every pane and every tab of `publishedTabs.all`. It
neutralizes each title and detail, and builds a `PaletteEntry` for each tab. It then builds a `Set` of the live keys to
prune the recency list, and runs `firstIndex` on the recency list once per tab.

Each keystroke runs the same full rebuild, not only a filter. `onQueryChange` calls `refreshCommandPalette`, which calls
`tabCandidates`, and nothing coalesces it. The ranking then matches the query against every candidate and sorts the
matches. A pane tree change also rebuilds at once, from `onTreeChange` in `MainWindowController.swift`. The palette view
scans every entry it is given for the selection.

Some of the cost sits in today's tab list. `AppletTabList.all` copies its tabs at each read, and the terminal's
`publishedTabs` maps every tab at each read. UTERM-053 M1 replaces both with a read-through view.

Choosing a tab, and scripting's tab lookups in `WindowScripting.swift`, scan the published list once per call.

So a background page in a large browser pane that changes its title in a loop costs up to 10 full rebuilds a second,
while the palette shows. Typing costs one more full rebuild per keystroke. A pane has no tab cap, per UTERM-039 and
UTERM-053.

UTERM-053 kept these walks out of its scope. It rejected bounding the rebuild there as an addition, since that leaves
the per-keystroke filter linear and needs a per-tab change report from every applet to the host.

Filed from bug
[20261122-palette-rebuild-walks-every-tab](../bugs/20261122-palette-rebuild-walks-every-tab.md). The trace was
confirmed against the tree on 2026-11-23. The cost was not measured.

## Design Decisions (Settled)

### Scripting's tab lookups need no new contract

Original question: whether scripting's tab lookups change too. `chooseTab` and scripting's tab lookups scan the
published list once per call. Open: whether they move to the same index, or stay out of scope as one bounded scan per
call.

Decision: no new contract here.

- After UTERM-053 M1, the browser's published list is a read-through view, and its settled per-change bound says a
  lookup by ID goes through the applet's map from ID to tab with no scan. The view's `contains` and `selectTab(id:)` are
  lookups by ID, so they fall under that bound. UTERM-053 M1 gains a check that says so.
- `chooseTab` drops its `contains` guard. `selectTab(id:)` already returns false for an ID the applet does not hold, so
  the guard is a second scan that changes no behavior.
- The terminal's lookups by ID still scan, since UTERM-053 left the terminal's own walks out of scope. M2 gives the
  terminal a map from ID to tab. See "The tab report names what changed by ID". Amended 2026-11-23; see Decision Log.
- `tabs(of:)` lists every tab of a pane. Its cost is linear in its own output, which is inherent.

Rationale: the browser's bound is already settled, so a second requirement on the tab list would say the same thing
twice. A requirement on every applet's view would bring in an ID map for the questions applet, whose tab cap already
bounds its scan. The terminal has no cap, so M2 gives it a map for the tab report's own reads. Routing lookups through the palette's index was rejected. Scripting would then depend on palette
state, and every lookup would wait on the index's queue. Amended 2026-11-23; see Decision Log. One scan
per call left as is was rejected. A controller that names tabs in a loop would pay a scan per call, the program-driven
class UTERM-053 rejected.

### The palette ranks tabs off the main thread, from an index kept for the window's life

Original question: how the palette's tab work is bounded. Candidates were an incremental palette index, a bound on the
candidates, and no rule. The measurement in M1 might show the cost is too small to matter at realistic tab counts.

Decision: a tab index that lives as long as the window, owned by one serial queue off the main thread. The main thread
never shares a mutable copy with it. Messages apply in the order the main thread sends them, so an insert never lands
after its own retitle and a remove never lands before its insert.

- The main thread sends the index a message for each per-tab change, and for each pane added, dropped, or given a new
  applet. At each tree change the window diffs each pane's applet identity against the last one it sent. So a replaced
  applet, which keeps its pane ID, reads as a swap. A tree change also sends the pane order. Each message costs
  main-thread work in proportion to the change.
- A pane's first ingest reads each of its tabs once on the main thread. This rides on the pane's restore, bulk open, or
  applet swap. The window's first panes, which arrive before any tree change, get the same ingest. It is declared under
  ADR Deviations.
- Each report also carries the pane's live tab count. When it disagrees with the index, the window reads that pane
  again in full. Choosing a tab that turns out to be gone also sends a remove for it. So a wrong report that changes the
  count heals at the pane's next report. A report that names a tab the index lacks reads the pane again too. A wrong
  report that keeps the count, such as a remove that names the wrong tab, heals only when the pane is next read in
  full. M2's contract test is what guards against it.
- Layout, focus, and divider changes no longer rebuild anything. Only a tab change or a pane change touches the index.
- Each keystroke sends the query and a generation number. The query also carries the selected entry's ID, the recency
  lists, the target pane and its selected tab, the filter, and the applet types. It also carries the command
  candidates. Their availability is computed on the main thread, and there are a bounded number of them.
- The worker ranks tabs and commands together with today's ranking. It replies with the top rows, the total count, and
  the selected entry's position. The view fetches more rows as the user scrolls. So the view's selection, first-choice,
  arrow, and scroll lookups scan only the rows it holds.
- A reply older than the current generation is dropped. While the palette shows, a change to the index re-runs the
  current query, coalesced, and posts fresh rows. So a tab that closes under an idle palette leaves the list. A hidden
  palette runs no ranking.
- A tree change, or a tab change in the target pane, re-sends the query with fresh command availability. It rides on
  the coalesced re-rank. So a command a closed pane or a closed tab made available shows as it can run now.
- Keys that read the list, such as the arrows, Return, and Tab completion, queue while the reply for the current query
  is pending. They replay in order against that reply. A text change discards queued selection moves but keeps a later
  Return. Every path that hides the palette clears the queue. So Return acts on the entry the user highlighted for the
  query they typed, as UTERM-002 requires.
- The field shows a pending state only once a reply is overdue by a fixed delay, per ADR-08's Consequences.

Rationale: a fuzzy subsequence match cannot be made sublinear in general. A one-letter query matches nearly every tab.
Only moving the match and the sort off the main thread bounds the main thread's work per keystroke. That is the request
and later reply that ADR-08 prescribes. Every tab stays reachable by name, so UTERM-002's "one keyboard path to every
tab" holds.

The index is a second copy of each tab's derived text, kept by the window. UTERM-002's live query rejected a second
copy because it drifts. Here the change report and a per-applet contract test keep it current, and the count check
heals a wrong report that changes the count. See "A change report that an applet gets wrong leaves the palette stale" under Risks.

A kept set that still ranked on the main thread was rejected. Its per-keystroke scan grows with a tab count that no cap
or rate bound limits, per UTERM-039. UTERM-053's declared linear parts all run once per event, never per keystroke.
Time-sliced ranking on the main thread was rejected. It needs the same key queue and pending state, and still spends
main-thread time per keystroke in proportion to the tab count. Not re-ranking on a background change was rejected. It
supersedes part of UTERM-002 and still rebuilds per keystroke. "No rule" and "measure first" were rejected, since with no
cap a threshold met at one count bounds nothing at a larger one. M1 still records the cost. A bound on the candidates
was rejected, since it breaks UTERM-002's reach to every tab and UTERM-053 M1's working-directory check. A per-pane tab
cap was rejected. It reopens UTERM-039 and UTERM-053's "No tab cap", and a stored pane over the cap loses tabs.

### The tab report names what changed by ID, and the window reads the values back

Original question: how the palette learns which tab changed. Today an applet reports that its tabs changed, not which
tab. Candidates included a per-tab change report in the host contract that every tab-publishing applet implements, and a
revision per tab that the palette compares. Either is a new host contract.

Decision: `appletTabsDidChange` takes a change value. The call has no form that omits the change, so a call site that
forgets fails to compile.

- The forms are: a set of tab IDs whose title or details changed; an insert of a contiguous range at a position; a
  remove of a set of tab IDs; a selection change; and the whole list. Removes name IDs, never positions, since the
  index is keyed by ID and a positional remove would delete the wrong entry after one missed message.
- The whole-list form is for applets with one tab, where it costs one tab, and for pane-level events, where it reads
  the pane again in full as ADR Deviations declares. A multi-tab applet reports a change to some of its tabs by ID.
- The host's change value is the same AppletKit type as UTERM-053's refresh change value. UTERM-053's refresh change
  is amended to name removed tabs by ID, which its ID map resolves with no scan. So one fact has one vocabulary.
- The window reads each named tab's title and details from the published list by ID, then sends them to the index. The
  published list stays the only source of each tab's text.
- A lookup by ID in an applet with no tab cap must not scan. An applet with a cap, such as the questions applet, may
  scan, since its cap bounds the scan. The browser's goes through its map after UTERM-053 M1. The terminal's scans
  today, and
  bug `20261122-terminal-tab-changes-walk-every-tab` has no owner. So M2 gives the terminal a map from ID to tab, which
  that bug calls no design call. The bug keeps its other walks.
- The read-through view returns a tab's details by ID. UTERM-053's published entry holds no details, and the terminal's
  working directory is a detail the palette searches. This amends UTERM-053's view. See Impacts.

Rationale: one source for each tab's text keeps UTERM-053's "no second copy to drift" rule. A report that carried the
values was rejected. Each applet would state a tab's text twice, once in its published list and once in the report, and
a fallback title built differently on one path would leave the palette showing text the bar does not. A revision per tab
was rejected, since finding the changed tabs visits every tab per report. Re-reading the changed pane was rejected for
the same cost, which is the retitle loop in the Motivation. Observing each published entry's setter was rejected. It
needs a second mechanism for inserts, removes, and the selection, and its callbacks would fire partway through the
browser's position pass.

## Design Decisions (Open)

None.

## Risks

- **A change report that an applet gets wrong leaves the palette stale** — likelihood: medium, impact: medium. The
  compile check forces some form, but an applet can name the wrong form or the wrong tab. A missed insert leaves a tab
  out of the palette. Mitigation: M2's per-applet contract test checks that the reports match the published list after
  each kind of change. The count check reads a pane again when the index disagrees with it, so a missed insert or
  remove heals at that pane's next report. A wrong report that keeps the count, such as a remove naming the wrong tab
  or a retitle the applet failed to name, stays wrong until that pane is read again. A later report that names a tab
  the index lacks reads the pane again.
- **A queued key replays against the wrong list and opens the wrong tab** — likelihood: low, impact: medium.
  Mitigation: M3's tests cover Return before the reply, a text change between an arrow and Return, and Escape.
- **UTERM-053 M1's view lands in a different shape** — likelihood: low, impact: medium. M2 and M3 read details by ID
  and share its change type. Mitigation: M1 here waits for UTERM-053 M1. UTERM-053 is amended to record this
  proposal's changes to its view and its change type.
- **Ranking at very large counts makes results arrive late** — likelihood: medium, impact: low. The main thread stays
  responsive, but results lag the typing. Mitigation: the pending state shows once a reply is overdue, a burst of
  keystrokes ranks only the newest query, and M3 records the reply time at 1,000 and 10,000 tabs.
- **The work waits on a long chain** — likelihood: medium, impact: low. M1 and M2 wait on UTERM-053 M1, which waits on
  UTERM-041 M1 and UTERM-052 M2. Accepted: nothing here can start sooner without building against a list shape that
  UTERM-053 replaces. The terminal's map from ID to tab moved into M2, so the chain holds no unowned bug.
- **The index keeps every tab's text for the window's life** — likelihood: high, impact: low. It costs memory whether
  or not the palette is used. Accepted: it holds a short cleaned title and detail per tab, and a build at each show
  would put a linear read on the main thread at every open.

## Milestones

### M1: Measure the palette's tab work

**Status:** NOT STARTED

The baseline that M3's numbers are compared against, taken after UTERM-053 M1 so it measures the read-through view.

- The cost of one palette rebuild, including ranking, is recorded for 1,000 and 10,000 tabs in one browser pane, in a
  release build with the injected palette wake, in the As built block
- The cost of one keystroke, as rebuild plus rank plus the view's update, is recorded for the same counts
- The main-thread cost per second is recorded while a background page changes its title on a timer and the palette
  shows

### M2: The tab report names what changed

**Status:** NOT STARTED

- Every applet that calls `appletTabsDidChange` passes a change value, and a call without one fails to compile
- A test shows that a title change, a directory change, an open, a close, and a selection change in one tab of a large
  pane are each reported by ID, not as the whole list
- A test shows that a bulk open is reported as one range insert, and that the terminal's start-time drop of failed
  tabs is reported as one remove of their IDs
- A per-applet contract test shows that after each kind of change, the tabs the reports describe match the published
  list
- A test shows that the window reads a named tab's title and details by ID with no scan, for the browser and the
  terminal
- The terminal finds a tab by ID through a map, and `selectTab(id:)` and the published list's `contains` no longer scan
- A test shows that a removed browser tab reaches the window by ID, including a Close Other Tabs over many tabs
- The shared change type is the union of UTERM-053's forms and this proposal's, with UTERM-053's pane-level change and
  the whole-list form as one form. A test shows that a change that names no tab touches no tab in the index
- "Applets with one tab" means applet types that only ever hold one tab. A test shows that the questions applet reports
  by ID, both for adds and removes among several open questions and for the swap from its empty placeholder to the
  first question, which changes the tab's ID while the count stays one
- The terminal's ID map has one owner: UTERM-053 M1's close-by-ID work does not build a second one
- A random sequence of opens, closes, bulk opens, and the start-time drop of failed tabs leaves the terminal's ID map
  matching its tabs, as UTERM-053 M1 tests the browser's
- `chooseTab` no longer checks `contains` before `selectTab(id:)`, and choosing a closed tab still takes the tab-gone
  path

### M3: The palette ranks tabs off the main thread

**Status:** NOT STARTED

- A test shows that retitling one background tab in a 10,000-tab pane while the palette shows reads one tab on the main
  thread, not every tab
- A test shows that typing one character walks no tabs on the main thread
- A test shows that a focus change, a layout change, and a divider step walk no tabs
- A test shows that a pane whose applet is replaced drops the old applet's tabs and lists the new one's
- A test shows that the window's first panes are in the index before the palette first shows, and that a report that
  arrives before a pane's ingest is not lost
- A test shows that a report whose count disagrees with the index's own count reads that pane again, and that a missed
  insert then shows in the list. The check compares against the index, not a tally of what was sent, so a remove that
  names an ID the pane never published also reads the pane again
- A test shows that a report naming a tab the index lacks reads that pane again
- A test shows that messages apply in the order sent, including an insert followed at once by its retitle
- A test shows that after a split, a move, or an undo, tied entries follow the new tree order
- A test shows that a removed tab leaves the recency list, so a live tab keeps its recency boost
- A test shows that Return pressed before the reply for the current query arrives acts on the entry highlighted for
  that query, and that a text change discards queued arrow presses but keeps a later Return
- A test shows that each way of hiding the palette clears the queued keys: Escape, a click outside, closing, the
  hotkey, and a change of placement
- A test shows that the highlight stays on its entry across a background re-rank, including when that entry sits below
  the rows the view holds
- A test shows that an arrow press between a re-rank's request and its reply keeps the arrowed entry, and Return opens
  it
- A test shows that Down past the held rows fetches more rows and moves onto the next one
- A test shows that the rows fetched as the user scrolls join into exactly the full ranking, with commands interleaved,
  including when a re-rank lands between two fetches
- A test shows that a tab that closes under an idle palette leaves the list
- A test shows that a hidden palette runs no ranking while a background page retitles in a loop
- A test shows that a burst of keystrokes ranks only the newest query
- A test shows that a pane closing under the palette updates which commands can run, with no keystroke
- A test shows that a tab change in the target pane while the palette shows re-sends command availability and the
  selected tab, so Next Tab disables when the pane drops to one tab, with no keystroke
- A test shows that one wrong report costs one full re-read of its pane, even with other reports for that pane in
  flight
- A test shows that Return pressed while a fetch for more rows is pending acts on the row Down reached, which is the row
  after the highlighted entry in the ranking the fetch answers from, even when a background re-rank lands first
- A test with an injected clock shows that the pending state appears only once a reply is overdue
- A test shows that neutralizing a long title stops reading at its cap, and neutralizing runs on the worker
- A test shows that a terminal tab is still found by its working directory
- UTERM-002's palette checks still pass
- The costs M1 recorded are recorded again for the same counts, in the As built block

## Decision Log

- 2026-11-23: Filed as a draft from bug `20261122-palette-rebuild-walks-every-tab`. The user asked for a proposal at
  its triage. The bug's two fix options became candidates under "How the palette's tab work is bounded", and "No rule"
  was added as the plain behavior. The change report became a follow-up question, and scripting's lookups a third. M1
  measures the cost first, since no one has measured it.
- 2026-11-23: Review start: 1 milestone, 0 settled decisions, 2 risks, no `Live after` lines or row gates, no
  out-of-scope statements; proposal at commit "Draft UTERM-058 for the palette's tab work on the main thread". The user
  asked for an autonomous review of every open question.
- 2026-11-23: Motivation corrected against the code: each keystroke and each tree change runs a full rebuild, not only
  a filter, and the per-read list copies go away with UTERM-053 M1.
- 2026-11-23: Scripting's tab lookups need no new contract. The browser's lookups by ID fall under UTERM-053's settled
  bound, `chooseTab` drops its redundant `contains` guard, and the terminal's lookups join its walk bug. (autonomous)
  Converged in 1 pass.
- 2026-11-23: The palette ranks tabs off the main thread, from an index kept for the window's life, and replies with
  the top rows. (autonomous, judge) Judge after 3 passes, on budget. A kept set that ranked on the main thread was
  rejected, since its per-keystroke scan grows with a tab count no cap or rate bound limits. The first ingest is
  declared under ADR Deviations.
- 2026-11-23: The scripting decision's rationale amended. It said "The palette keeps nothing while it is hidden, so
  scripting would read state that does not exist, or the palette would pay its cost while hidden." The index now lives
  for the window's life, so that reason no longer holds. The decision stands on the settled per-ID bound, and on
  scripting not depending on palette state behind a queue. (autonomous)
- 2026-11-23: The tab report names what changed by ID, and the window reads the values back by ID. Removes name IDs,
  a range insert covers bulk opens, and the change value shares UTERM-053's type. The wiring depends on the terminal's
  lookup-by-ID fix, and the read-through view returns details by ID. (autonomous) Converged in 1 pass. A report that
  carried the values was the first pick before the critique. It was dropped because each applet would state a tab's
  text twice.
- 2026-11-23: Coherence review fixes. (autonomous) The shared change type had said "or a projection of it". UTERM-053's
  refresh change removes by position, which this proposal forbids, so UTERM-053's remove is amended to name IDs and the
  projection is gone. The amendments to UTERM-053 were claimed in Impacts but not recorded there, so they go to the
  review gate before UTERM-053 is edited. A wrong report now heals through a count check per report. The whole-list
  form is limited to one-tab applets and pane-level events, and the full re-read is declared under ADR Deviations.
  Messages apply in send order on one serial queue. A hidden palette runs no ranking. Every hide path clears queued
  keys. A tree change re-sends command availability. The window's first panes get an explicit ingest.
- 2026-11-23: The terminal's map from ID to tab moved into M2. (autonomous, addition) The scripting decision had said
  the terminal's lookups "join bug `20261122-terminal-tab-changes-walk-every-tab`, which owns those walks". That bug
  has no owner, and M2 blocked on it. The bug calls the map no design call, and M2 already edits the terminal's call
  sites.
- 2026-11-23: Re-check fixes. (autonomous) The count check had said a wrong report "never leaves a tab out of reach
  for good". A wrong report that keeps the count does not heal, so the claim is narrowed, and no further healing
  mechanism is added. "A lookup by ID must not scan" now exempts applets with a tab cap, such as the questions applet.
  The scripting rationale had said a no-scan requirement "would bring in an ID map for the terminal and the questions
  applet", and now rests on the questions applet's cap alone.
- 2026-11-23: Review gate: kept all. The user kept the off-main index, the terminal's map from ID to tab in M2, and the
  amendments to UTERM-053, which are now applied there.
- 2026-11-23: No decision earns an ADR. Ranking off the main thread applies ADR-08's request-and-reply principle, and
  the tab report shapes one host protocol inside one binary.
- 2026-11-23: Accepted by the user after the review.
- 2026-11-23: Risks reviewed. (autonomous) The stale-report risk is raised to medium impact, since a missed insert
  leaves a tab out of the palette until the count check heals it. Added: the long dependency chain, accepted, and the
  index's memory for the window's life, accepted. Both are low impact.

## References

- ADR-08: UI responsiveness
- [UTERM-053](UTERM-053-browser-tab-work-never-grows-with-the-tab-count-on-the-main-thread.md): the browser's per-tab
  work, which ruled the palette out of scope
- [UTERM-052](UTERM-052-browser-description-never-encodes-tabs-on-the-main-thread.md): the saved-state revision
- Bug [20261122-palette-rebuild-walks-every-tab](../bugs/20261122-palette-rebuild-walks-every-tab.md)
