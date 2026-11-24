# UTERM-052: The Browser's Description Never Encodes Tabs on the Main Thread

**Status:** accepted
**Created:** 2026-11-22
**Updated:** 2026-11-23

## Dependencies

- UTERM-005, for the browser applet and its tab records

## Impacts

- UTERM-051 — "Where the typed decode runs" takes `describe()`'s `JSONValue` payload as its off-main step's input, and
  undo reopen decodes the description `describeAndClose` puts on the ledger. A fix here that changes when the payload is
  ready, or its type, amends that decision. See "This proposal settles now, against UTERM-051's settled payload form".
- UTERM-053 — it settles the tab cap, with no cap, and shares this proposal's record choke point. Its M1 depends on
  this proposal's M2, and routes the selection, insert, and remove sites through its declared change. This proposal's
  saved-state revision says only whether anything saved changed, not which tab. See "The applet keeps each tab's
  encoded record and counts its saved changes" and "No tab cap in this proposal".

## ADR Deviations

- ADR-08 "The main thread may do local work whose duration uniterm bounds", no carve-out: each save, and each
  `describe()`, builds the browser's tab array once on the main thread from each tab's kept record. The pass is
  pointer-sized per tab and encodes nothing. A pane has no tab cap, so the pass's size has no bound. The user accepted
  the copy this replaces on 2026-11-22, and chose this pass on 2026-11-22 in the UTERM-053 review. See "The applet
  keeps each tab's encoded record and counts its saved changes".

## Summary

The browser applet stops encoding every tab record on the main thread each time the window asks for a description. A
change costs the description one tab's work on the main thread, and a save encodes nothing there. Two costs still grow
with the tab count: one pointer-sized pass over the kept records at each save, and a pane close's read and encode of
every loaded tab's history. A restore also gives each tab its encoded record once. The close's cost is new for a pane
that sat quiet before it closed, since a save no longer prepares it. A dirty map pane's save stops encoding its undo
part too.

## Motivation

`BrowserApplet.describe` builds its payload with `JSONValue(encoding:)`. That encodes every tab record to bytes and
decodes the bytes back into a `JSONValue` tree. The window asks for a description at every change the applet reports.
A page chooses how often its title changes. So each title change re-encodes the whole pane.

The path runs on the main thread. WebKit reports the new title through key-value observing. The applet's refresh sees
a changed title and reports a change to the window. The window calls `describe()` and compares the result with the
last saved description, so that a change the layout file does not hold is not a layout change. Each tab record holds
the tab's title, so the comparison usually finds a real change. The window then reports a layout change. After a quiet
second, or at most 10 s into a stream of changes, the save calls `describe()` again. The comparison needs to know
only whether one tab's record changed. It rebuilds and re-encodes every tab to find out.

The cost is linear and was measured on 2026-11-22 in a debug build. It is about 20 microseconds per tab.

| Tabs | Encode time |
|------|-------------|
| 1,000 | 21 ms |
| 10,000 | 197 ms |
| 50,000 | 988 ms |

At 1,000 tabs one title change already exceeds a 16 ms frame.

ADR-08 allows only local work whose duration uniterm bounds on the main thread. A pane has no tab cap, so this work has
no bound. The layout save already moved its encode and write off the main thread. The description that feeds it is
still built on the main thread.

The undo part of the description is cached until a tab's history or the closed tabs change. The tab records are not
cached. The bug is `20261122-browser-describe-reencodes-tabs-on-main-thread`.

## Design Decisions (Settled)

### This proposal settles now, against UTERM-051's settled payload form

Original question: whether this waits for UTERM-051's payload form. UTERM-051 was in design review, and might have
changed `AppletDescription`'s payload form. The candidates were settling now, settling after UTERM-051, and leaving the
description as it is.

Decision: settle now. UTERM-051 is accepted. Its settled "Where the typed decode runs" keeps the payload a `JSONValue`
tree, and each applet's off-main step decodes through that tree. No pending design changes the form.

Rationale: the wait has already ended, so the question has no live choice. Leaving the description as it is would drop
this proposal's goal, and it keeps a cost of about 21 ms per title change at 1,000 tabs on the main thread.

- The coupling now runs the other way. A fix here that changes when `describe()` returns its payload, or the payload's
  type, changes the input of UTERM-051's off-main step. Such a fix must say how it amends UTERM-051's settled decision.

### No tab cap in this proposal

Original question: whether a tab cap is in scope. A cap would bound every cost that grows with the tab count. It is a
scope addition, and it changes behavior a user can see. The candidates were no cap, settled here; no cap, settled in
UTERM-053 and inherited here; and a cap on tabs per pane with a stated value and a visible refusal.

Decision: this proposal adds no cap. Its fix bounds the description with no cap. It does not settle UTERM-053's own cap
question, which weighs a cap against that proposal's costs.

Rationale: a cap does not bound the panes it exists for. ADR-06 keeps version skew lossless per pane, so a pane restored
or undo-reopened over the cap keeps every tab and still pays every per-tab cost. A cap would also refuse the user's New
Tab, which UTERM-039 rests on having no cap. Settling the question for UTERM-053 would decide part of an unreviewed
draft's mechanism. Waiting on UTERM-053 would hold this proposal on a question its own design does not need.

Leaves undone: the other per-tab costs on the main thread still grow with the tab count. These are `refresh`'s walk and
the tab bar, which UTERM-053 owns, and the terminal's description, which encodes every tab at each call.

### The applet keeps each tab's encoded record and counts its saved changes

Original question: where the tab records get encoded. The candidates were a cache of the encoded records on the main
thread, kept per tab; a payload built off the main thread from copied records; both together; and comparing one tab
instead of the pane, through a change in the window's side of the applet contract. The review added dropping today's
rule that a description equal to the saved one is not a layout change.

Decision: the browser keeps each tab's encoded record, and the window learns of a saved change from a counter instead of
a comparison.

- Each tab keeps its record's encoded `JSONValue`. The tab's record setter acts only on a real change. On that change
  it rebuilds the tab's encoded record and moves the applet's saved-state revision at once. `describe()` and the saved
  description build the tab array from each tab's kept record when asked, in one pointer-sized pass. They stay
  synchronous, and the payload stays the `JSONValue` tree that UTERM-051 reads, so UTERM-051 is not amended. Amended
  2026-11-22, with UTERM-053; see Decision Log.
- The undo part's cache is removed. Once the save asks for the saved description alone, only a pane close builds the
  undo part, once per applet. See "The save asks for the saved description alone". Amended 2026-11-22; see Decision
  Log.
- The applet contract gains an optional saved-state revision, which is nil by default. The browser moves its revision
  at each tab's record change, from the record setter, and at each selection change, insert, and remove. This
  proposal's M2 moves it at today's selection, insert, and remove sites. UTERM-053's M1 later routes those sites
  through its declared change. Unsent-input marks, dialogs, and loading segments do not move it.
  Amended 2026-11-22, with UTERM-053; see Decision Log.
- The window records each pane's revision when it takes the save snapshot. At a change report it compares the pane's
  revision with the recorded one, and skips `describe()`. An applet with no revision keeps today's comparison of
  descriptions.
- A title change costs the description one tab's encode. Each save or `describe()` builds the tab array once, from the
  kept records. The pass is pointer-sized per tab and encodes nothing. It replaces the copy of a kept array at the
  first change after each save, which the user accepted on the main thread. See ADR Deviations. Amended 2026-11-22,
  with UTERM-053; see Decision Log.

Rationale: it is the only candidate whose per-change cost does not grow with the tab count and whose `describe()` stays
synchronous. The revision is compared with the one at the last save, not the last report. A report that reached no
saver, such as one after the quit save, still counts at the next save. The off-main builds make `describe()`
asynchronous and amend UTERM-051. Quit's save and an undo reopen right after a close need the payload at once, so they
would wait for the build on the main thread anyway. The cache alone keeps three walks of every tab per change: the
assembly, the undo part, and the window's deep comparison. Dropping the equal-description rule would write the file
every 10 s for a loading segment, an unsent-input mark, or a dialog, since the browser reports each of them. It would
change when every applet's changes save.

Leaves undone: the pass over the kept records at each save. `refresh`'s walk and the tab bar, which UTERM-053 owns. The
terminal's description, which still encodes every tab at each call, and keeps the window's comparison.

### The save asks for the saved description alone

Original question: how the save avoids building the undo part. The save called `describe()` and dropped the undo part.
After any tab's history change, the next save encoded every tab's WebKit history on the main thread and threw it away.
The candidates were a call for the saved description alone; keeping each tab's encoded undo entry; making the
description's undo part lazy; and accepting one undo encode per save. The review added splitting the contract so
`describe()` returns only the saved part and the close composes the undo part, and keeping the undo entries current at
each change.

Decision: the applet contract gains a call for the saved description alone. Its default returns `describe()` without the
undo part. The browser answers it from each tab's kept record and builds no undo part. The map answers it with its
payload description, and builds no undo part either. The save calls it. The window's change check calls it for an
applet with no saved-state revision, which includes the map. A pane close keeps calling `describe()`. Amended
2026-11-23; see Decision Log.

Rationale: it removes the undo encode from every save and adds no scope. With the save and the change check moved off
`describe()`, a close is the browser's only caller of the undo part, once per applet. So its cache never hits, and the
cache is removed instead of rekeyed. A lazy undo part loses history: the close drops each never-loaded tab's restored
history right after `describe()`, so a part evaluated later finds nothing. It would also change a shared `Sendable`,
`Equatable` type that UTERM-051 reads. Kept undo entries still walk every tab at each save, and they add an index
alignment that a missed move would break. Splitting the contract makes the two calls unable to disagree, but it moves
the terminal's, the map's, and the text viewer's undo parts too, which is a scope addition.

Leaves undone: a pane close reads and encodes every loaded tab's history on the main thread, while the user waits on
the close. Today a save fills the undo cache and each tab's kept history read. So closing a pane that sat quiet for a
second reads and encodes no history today, though it encodes every tab record. Under this decision nothing fills either
cache before the close, so that close's history cost is new. The total main-thread work drops, but the history work
moves from a deferred save to the close. Bug `20261122-browser-close-encodes-every-tab-history-on-main-thread` tracks
it. Other applets keep building their undo
parts at each save, since only the browser and the map answer the new call.

## Design Decisions (Open)

None.

## Risks

- **The cached payload drifts from `BrowserDescription`'s coding, and the layout file loses a field** — likelihood:
  medium, impact: medium.
  The applet assembles the payload from cached parts instead of encoding `BrowserDescription`. A field added later
  could be left out of the cached form.
  Mitigation: an M2 test compares the cached payload with `JSONValue(encoding:)` of the same `BrowserDescription`,
  after each kind of change, for a fixture with every field set.
- **A saved change that does not move the revision leaves the layout stale** — likelihood: low, impact: medium.
  The layout file keeps the old state until another change or quit saves it. A crash before then loses it.
  Mitigation: the revision moves from the record setter and from the selection, insert, and remove sites. An M2 test
  changes a background tab's title and URL, the selection, and adds and closes tabs, and checks that each reaches the
  next saved layout.
- **A record change that bypasses the record setter leaves the revision unmoved** — likelihood: low, impact: medium.
  UTERM-053 drops `refresh`'s comparison, so the record setter is the revision's only source for record changes.
  Records change at two sites today: the title and the committed URL. The commit sets the record without notifying
  the applet until a later state change.
  Mitigation: the record is `private(set)` on the tab, so every change goes through the setter. M2's revision test
  covers a commit with no later title event, and an equal title moves nothing.

## Milestones

### M1: Measure the full description

**Status:** NOT STARTED

The scratch measurement covered the encode alone.

- The cost of a full `describe()` is recorded for 1,000, 10,000, and 50,000 tabs, in the As built block
- The cost of the pass over 50,000 kept encoded records, as each save and `describe()` makes it, is recorded in the
  As built block
- The cost of a pane close's `describe()` with 1,000 and 10,000 loaded tabs is recorded in the As built block. Today's
  close after a quiet second is recorded beside it, split into the record encode and the undo part, so the two can be
  compared

### M2: Bound the description's main-thread cost

**Status:** NOT STARTED

- A test shows that a burst of title changes costs the window's change check no more per change at 10,000 tabs than at
  10 tabs. `describe()` and a save are timed apart, since each pays the accepted pass over the kept records. `refresh`
  and the tab bar are timed apart too, since UTERM-053 owns them. A record change rebuilds only its own tab's encoded
  record, with no search through the tabs
- A test shows that the restoring init gives each tab its encoded record once, and that the first save after a restore
  encodes nothing. A stored record that validation leaves unchanged takes its encoded form from the stored payload's
  tree, with no encode. The restore's time is recorded in the As built block
- A test closes a pane right after a page finishes loading in a background tab, with no other history change. An undo
  reopen brings back the history as it stood after the finish
- A test replaces a pane's applet, and runs a window that has never saved, as a second instance does. A change report
  from a pane with no recorded revision, or one recorded from another applet, counts as a layout change
- The saved-state revision's doc comment says that an applet adopting it moves it before every report of a change to
  its saved description
- A test shows that the cached payload equals `JSONValue(encoding:)` of the same `BrowserDescription` after a title
  change, a URL change, a tab added and closed, and a selection change, for a fixture with every field set
- A test changes a background tab's title and URL, the selection, and adds and closes tabs. Each one moves the revision
  and reaches the next saved layout. A change to a loading segment alone moves nothing and is not a layout change
- A test shows that an applet with no saved-state revision keeps today's comparison of descriptions
- A test shows that a save builds no undo part after a history change, and that an undo reopen still brings back each
  tab's history
- A test shows that the saved description alone equals `describe()` without its undo part, after each kind of change
  in the payload test above
- A test shows that a commit with no later title event moves the revision, and that assigning an equal title moves
  nothing
- The call for the saved description alone is a requirement of the applet protocol, with a default. A test shows that
  the window's save, through the applet type it holds, reaches the browser's own answer
- A map test shows that the saved description alone equals `describe()` without its undo part, and that a save and a
  change check of a dirty map pane build no undo part. An undo reopen of a dirty map pane still brings back its edits
- The kept history read on each tab, and the doc comment that says the applet keys a kept description on
  `historyVersion`, are each removed or given a stated current user
- The revision test covers a selection change and a tab added and closed, as well as the two record sites. It passes
  before and after UTERM-053 routes those sites through its declared change

## Decision Log

- 2026-11-22: Filed as a draft from bug `20261122-browser-describe-reencodes-tabs-on-main-thread`. The user asked for a
  proposal, and said it need not wait for UTERM-051's review.
- 2026-11-22: Traced why every title change pays the encode, and added the one-tab comparison as a candidate under
  "Where the tab records get encoded".
- 2026-11-22: Review start: 2 milestones, 0 settled decisions, 2 risks, no `**Live after:**` lines or row gates, no
  out-of-scope statements; the user asked for an autonomous review of the three open questions. Baseline is the commit
  "Trace UTERM-052's per-title encode and add the one-tab comparison".
- 2026-11-22: This proposal settles now, since UTERM-051 is accepted and keeps the payload a `JSONValue` tree.
  Converged in 1 pass (autonomous). Correction of fact: the question said "UTERM-051 is in design review. It may change
  `AppletDescription`'s payload form." The Impacts entry said UTERM-051 "may change `AppletDescription`'s payload
  form". Both now name the real coupling, which runs from this fix to UTERM-051. Added UTERM-053 to Impacts.
- 2026-11-22: No tab cap in this proposal, and UTERM-053 keeps its own cap question. Converged in 2 passes
  (autonomous). The recommendation moved from settling the cap here for UTERM-053 too, once the critique showed that
  would decide part of an unreviewed draft's mechanism.
- 2026-11-22: The browser keeps each tab's encoded record and an assembled tab array, the undo key becomes a counter,
  and an optional saved-state revision on the applet contract replaces the window's per-change comparison. Converged
  in 1 pass (autonomous). The recommendation moved from a flag on each change report to a revision compared with the
  one at the last save, once the critique showed a flag can lose a change that reached no saver. The critique added
  that option.
- 2026-11-22: The user accepted the copy of the kept tab array at the first change after each save, as an ADR-08
  deviation. The other choices were building the payload off the main thread, which amends UTERM-051 and still makes
  quit and undo wait, and the cache alone, which keeps three walks of every tab per change.
- 2026-11-22: Dropped the risk that an off-main build reorders descriptions, since no description is built off the
  main thread. Replaced the stale-title risk with the risk that the cached payload drifts from the encoded one, and
  added the risk that a saved change does not move the revision (autonomous). M2's first check said "a burst of title
  changes costs the main thread no more per change at 10,000 tabs than at 10 tabs". `refresh` walks every tab per
  change, and UTERM-053 owns it, so no fix here could pass that check. It now times the description path alone. Routed
  the critique's checks to M1 and M2.
- 2026-11-22: The whole-proposal review found that each save still builds and drops the undo part, which encodes every
  tab's history on the main thread after any history change. Added "How the save avoids building the undo part" as an
  open question (autonomous). Added the risk that UTERM-053 reshapes the comparison the revision moves from. Routed four
  checks to M2: a finish-only history change reaching undo, a pane with no recorded revision, the first change after a
  save, and the revision's doc rule. Correction of fact: the rationale rejected dropping the equal-description rule
  because "the save would still encode every tab on the main thread". With the per-tab cache it would not. It is now
  rejected because the browser reports loading segments, unsent-input marks, and dialogs, so each would write the file.
  Motivation now says the save waits for a quiet second.
- 2026-11-22: The save asks for the saved description alone, through a new contract call whose default drops the undo
  part. Converged in 1 pass (autonomous). The critique added splitting the contract, which is a scope addition, and
  keeping undo entries current at each change.
- 2026-11-22: Amended "The applet keeps each tab's encoded record and counts its saved changes" (autonomous). It said
  "The undo part's cache key becomes a counter. It moves on any tab's history change, on a tab added, closed, or moved,
  and on a change to the closed tabs." Once only a close builds the undo part, the cache never hits, so it is removed.
  M2's undo check said "the undo part is encoded again only after a tab's history or the closed tabs change". It now
  checks that a save builds no undo part. Routed a close-time measurement to M1 and an equality check to M2.
- 2026-11-22: The re-check pass found that a close of a quiet pane gets slower than today. A save no longer fills the
  undo cache or each tab's kept history read, so the close reads and encodes every loaded tab's history (autonomous).
  The Summary and the save decision's Leaves undone line now say so, and M1 records today's close beside the new one.
  The decision stands for now, and goes to the review gate. Routed three checks to M2: the saved-description call is a
  protocol requirement, the dead kept read and doc comment go, and the revision test covers every saved change kind.
  Correction of fact: the Leaves undone line said the close "still encodes every tab's history once" and takes on reads
  "for each tab whose history changed since its last read". With no save reading first, that is every loaded tab.
- 2026-11-22: The final re-check pass converged. Correction of fact: the Leaves undone line said today's quiet close
  "costs today nothing beyond wrapping the cached part". It still encodes every tab record. M1 now splits today's close
  into the record encode and the undo part.
- 2026-11-22: Risk review found nothing to add (autonomous). Each risk carries a likelihood, an impact, and a
  mitigation. None is high in both. The new contract members ship in one binary, and the layout file's bytes do not
  change, so no decision is a one-way door. The in-flight UTERM-053 is already a risk.
- 2026-11-22: Review gate: kept "The save asks for the saved description alone". The user chose to pay the history
  read and encode at a pane close, over keeping undo entries current at each history change, and over letting saves
  keep building the undo part.
- 2026-11-22: ADR candidate (cuts across the system): a change report never makes the window rebuild an applet's whole
  description. Declined: applies ADR-08 "The main thread never waits on work whose duration uniterm does not bound",
  and only the browser adopts the revision.
- 2026-11-22: Accepted.

- 2026-11-22: Amended with UTERM-053, by the user's choice in that proposal's review. UTERM-053 drops `refresh`'s
  comparison, which this proposal's revision moved from. Each tab's record setter now rebuilds that tab's encoded record
  and moves the revision on a real change. Selection, inserts, and removes move it through UTERM-053's declared change.
  The kept assembled array is gone: finding a changed tab's element in it needs a scan of every tab, since a change
  names a tab, not an index. The description builds the array from the kept records at each call instead. The ADR-08
  deviation, the risk on UTERM-053's reshape, and M2's checks are updated to match.
- 2026-11-22: Followed UTERM-053's coherence pass. This M2 builds the record setter and moves the revision at today's
  selection, insert, and remove sites, so it works without UTERM-053. Fixed the text left from the kept array in the
  Summary, Leaves undone, and the stale-revision risk. Dropped "moved" from the checks, since the browser has no tab
  move. The burst check now times only the window's change check, since `describe()` pays the array pass. Added a check
  that a restore builds each encoded record once and the first save encodes nothing.
- 2026-11-22: Followed UTERM-053's re-check. A restore gives each tab its encoded record once, about 20 µs per tab, so
  the Summary names it and M2 reuses the stored payload's tree for a record validation leaves unchanged. M1 measures
  the pass over the kept records instead of the removed array's copy.
- 2026-11-22: Scheduled as UTERM-052 M1-M2 in queue.md.
- 2026-11-23: (addition) From the triage of bug `20261122-map-describe-encodes-document-at-every-save`. The user chose
  to add the map's answer to M2. Amended "The save asks for the saved description alone": it said only the browser
  answers the new call, and its Leaves undone line said the bug tracks the map's undo encode at each save. The map now
  answers with its payload description and builds no undo part. The Summary says so, and M2 gained a map check.

## References

- ADR-08: UI responsiveness
- Bug `20261122-browser-describe-reencodes-tabs-on-main-thread`
- UTERM-051: the launch reads the layout off the main thread
- UTERM-053: the browser's per-tab work never grows with the tab count on the main thread
- UTERM-039: a controller's browser tabs are not capped
- Bug `20261122-browser-close-encodes-every-tab-history-on-main-thread`
- Bug `20261122-map-describe-encodes-document-at-every-save`
- Bug `20261122-terminal-describe-encodes-every-tab-at-each-change`
