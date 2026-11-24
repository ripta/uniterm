# UTERM-059: The Terminal's Change Check Never Encodes Every Tab

**Status:** accepted
**Created:** 2026-11-24
**Updated:** 2026-11-24

## Dependencies

- UTERM-052, whose M2 adds the optional saved-state revision and the call for the saved description alone to the
  applet contract

## Impacts

- UTERM-052 — "The applet keeps each tab's encoded record and counts its saved changes" names the terminal's
  description in its Leaves undone line. This proposal makes the terminal the revision's second adopter. It relies on
  that decision's rule that a window compares descriptions only for an applet with no revision, and on M2's doc rule
  that an adopter moves the revision before every report of a change to its saved description.
- UTERM-053 — its M1 rewrites the terminal's insert and remove sites and publishes a read-through view over its tabs.
  "Observers on the tabs and the selection move the revision" relies on every write to the tabs reaching one place.
- UTERM-058 — its M2 gives the terminal a map from ID to tab, which the same decision's writes must keep in step.

## ADR Deviations

- ADR-08 "The main thread may do local work whose duration uniterm bounds", no carve-out: each save, and each
  `describe()`, builds the terminal's tab array once on the main thread from each tab's kept record. Every terminal pane
  pays it at every save, whether or not it changed. The pass is pointer-sized per tab and encodes nothing. A pane has no
  tab cap, so the pass's size has no bound. It matches the browser's pass, which the user accepted in UTERM-052. See
  "Each tab keeps its encoded record".

## Summary

A terminal pane stops encoding every tab at each change it reports. The window learns of a saved change from the
terminal's saved-state revision, as UTERM-052 sets up for the browser, and skips `describe()` at a report that changes
nothing saved. A title change, the most frequent report, then costs the change check nothing that grows with the tab
count. Each tab keeps its encoded record, so a save encodes no tab and makes one pointer-sized pass over the tabs. A
restore and an undo reopen encode each tab's record once, which today's first save after them pays instead.

## Motivation

The window asks a terminal pane for its description at every change the pane reports. `TerminalApplet.describe`
builds a `TerminalDescription` from every tab, then encodes it and the closed tabs with `JSONValue(encoding:)`. The
window compares the result with the last saved description, in `notifyLayoutIfDescriptionChanged`.

The pane reports a change at each title change of the selected tab, so the status bar can follow it. The title is not
in the saved description. So that comparison always finds no change, and the whole encode buys nothing. A program sets
the title, and a spinner sets it many times a second. The pane also reports a change when any tab's directory
changes, when a command finishes in the selected tab, and at each tab insert, remove, and select. A finished command
reports so the status bar can show a failed exit code, which the saved description does not hold either.

The cost is linear in the tab count. It was measured on 2026-11-23 in a debug build, with a fake engine, with every tab
holding a directory:

| Tabs | One `describe()` |
|------|------------------|
| 1 | 65 µs |
| 100 | 2.2 ms |
| 1,000 | 21 ms |

That is about 21 µs per tab, the same rate UTERM-052 measured for the browser's records. At 1,000 tabs one title change
exceeds a 16 ms frame.

A shell tab holds a pty, which limits a shell pane's tab count. The limit is the system's, not uniterm's, and every
process on the machine shares it. A program-mode pane that uniterm writes holds one tab, since program mode never opens
another. A layout file that uniterm did not write can still hold a program-mode pane with any number of tabs. A restore
keeps them all, since it starts no session for a waiting tab. ADR-08 allows only local work whose duration uniterm
bounds on the main thread, and a pane has no tab cap.

The closed tabs are capped at 20, so their encode is bounded. The unbounded part is the open tabs.

The bug is `20261122-terminal-describe-encodes-every-tab-at-each-change`. UTERM-052 settled the browser only, and
its Leaves undone lines name the terminal's description as untouched.

## Design Decisions (Settled)

### The terminal adopts the saved-state revision

Original question: whether the terminal adopts UTERM-052's saved-state revision, its call for the saved description
alone, or both.

Decision: the terminal adopts both. The window compares the pane's revision with the one it recorded at the last save,
and skips `describe()` at a report that moved nothing. The terminal answers the call for the saved description alone
itself, with the payload assembled from the kept records and no undo part. `describe()` is that answer plus the undo
part, so the two cannot disagree. A pane close keeps calling `describe()`, so undo still gets the closed tabs. Amended
2026-11-24; see Decision Log.

Rationale: only the revision removes the per-change walk. The saved-description call alone drops the closed-tab
encode, which the cap of 20 already bounds, and leaves every open tab encoded at each change check. Without the call,
every save of every terminal pane would encode up to 20 closed tabs and throw them away. The call is a protocol
requirement with a default, so answering it adds one method and no state. Caching the encoded undo part instead would
add invalidation at each write to the closed tabs, which is the cache UTERM-052 removed from the browser.

Leaves undone: each save still makes a pass over every tab's kept record. See "Each tab keeps its encoded record". A
pane close encodes the closed tabs, which the cap of 20 bounds.

### The terminal is fixed once UTERM-052 M2 lands

Original question: whether to fix it at these tab counts. The measurement shows about 21 µs per tab per change in a
debug build. A shell pane with 30 tabs pays well under a millisecond per title change. The candidates were fixing it once
UTERM-052 M2 lands; deferring it, with a revisit hook tied to a release-build measurement or a report of a slow pane;
and rejecting it as an ADR-08 deviation with a stated reason. The review added a status-only host call for title
changes, a cached description the window compares by storage, and a restore that cuts a program-mode pane to one tab.

Decision: fix it once UTERM-052 M2 lands. The milestone below starts after M2.

Rationale: a program chooses how often the selected tab's title changes, and the pane has no tab cap that uniterm
sets. The pty limit that bounds a shell pane is the system's, and any process can use it up or an administrator can
raise it. So neither the rate nor the count has a bound uniterm promises, which is what ADR-08 asks for. A release-build
measurement would lower the per-tab constant and leave the cost linear, so deferring for one could not change the
answer. Rejecting it would leave the deviation in place for every pane. A status-only host call would change the
contract for every applet, and still leave directory changes and finished commands paying `describe()`. A cached
description compared by storage relies on how the standard library compares arrays, and its missed-mark failure is the
same as a missed revision move. Cutting a program-mode pane at restore drops tabs that ADR-06 keeps lossless per pane,
and leaves shell panes linear.

Leaves undone: a title change still walks every tab on the main thread outside the change check. The tab bar takes
every tab's title at each title change, and the host reads the computed published list. Bug
`20261122-terminal-tab-changes-walk-every-tab` gives both to UTERM-053 M1. While the palette shows, each title change
also schedules a palette rebuild over every tab, which UTERM-058 owns. A title change reaches a bound only once all
three land.

### Each tab keeps its encoded record

Original question: what a save still pays. Under the revision, each save still built and encoded the payload from every
tab on the main thread. A save describes every pane in every window, so a quiet terminal pane paid at every save the
app made, whichever pane caused it. The candidates were accepting the encode at each save as an ADR-08 deviation;
keeping each tab's encoded record, as the browser does; and building the payload off the main thread from copied tab
values. The review added building each record as a `JSONValue` by hand, with no encoder round trip; a kept array of
records beside the tabs; and the window reusing a pane's last saved description while its revision has not moved.

Decision: each tab keeps its saved part as an encoded `JSONValue`. The record is built through `TerminalDescription.Tab`'s
own coding, by one function on the tab that the record, a closed tab's entry, and `describe()` all share. It is rebuilt
only when the tab's reported directory really changes. An equal report changes nothing. `describe()` and the saved
description build the tab array from the kept records in one pointer-sized pass, and assemble the top level around it.
They stay synchronous, and the payload stays the `JSONValue` tree UTERM-051 reads. A restore and an undo reopen give
each tab its record once, from the tab's resolved start directory, since the stored one may differ from where the tab
starts.

Rationale: it is the only candidate that leaves no encode on the main thread at a save, and it keeps `describe()`
synchronous. An off-main build still copies every tab's values on the main thread, which is a pass of the same order.
It also makes `describe()` asynchronous and amends UTERM-051, and quit's save, a pane close, and an undo reopen would
wait for the build anyway. Accepting the encode leaves a full per-tab encode of every terminal pane at every save. That
is much larger than the pointer-sized pass the user accepted for the browser. A hand-built record lowers the constant
but keeps a per-tab build at every save, and it can drift from the coding. A kept array copies itself at the first
change after each save, and it adds an index alignment with the tabs that every insert, remove, and reopen must keep.
Reusing the saved description makes the revision the only thing that decides what a save writes. A missed move would
then be lost at quit too, where today quit's `describe()` still writes the truth. It would also change the window's side
of UTERM-052's contract, which the browser shares.

Leaves undone: each save, and each `describe()`, makes the pointer-sized pass over every tab's kept record, in every
terminal pane, whether or not that pane changed. See ADR Deviations. A pane close still encodes the closed tabs, which
the cap of 20 bounds.

### Observers on the tabs and the selection move the revision

Original question: where the revision moves. The saved description holds the mode, the command, each tab's reported and
start directory, and the selected index. A change to any of them must move the revision before the pane reports it. A
missed site silently skips a layout save until another change or quit saves it. Today's sites are each tab's directory
report, a tab opened or reopened, a tab removed, a selection change, and a start that drops the tabs whose session
failed. That start reports only a tabs change today, not a change to the description. The mode and the command are set
only when the applet is built. A title change, a link hover, and a segment change must not move the revision. The
candidates were a property observer on each saved field, a call at each site, and the per-tab record's setter, which
"Each tab keeps its encoded record" settled for the directory. The review added a few private mutators that alone write
the tabs and the selection, and a small owned type that holds both behind its own mutators.

Decision: the tab record's setter moves the revision on a real directory change, as settled. A `didSet` observer on the
tab array moves it at every write, and one on the selected index moves it when the value differs from the old one. The
array's observer does not read its old value, so an insert or a remove copies nothing. One change may move the revision
more than once. That costs nothing, since the window only checks whether the revision differs. Writes in the init move
nothing, which is right, since no window has recorded a revision yet.

A start that drops failed tabs keeps reporting only a tabs change. Its observer moves the revision, and every save
describes every pane, so the next save from any cause writes the drop. At launch the restore runs before the saver is
wired, so a report from the start would reach no saver. A window opened later schedules a save right after it starts its
panes.

Rationale: observers are the only candidate where a later write to either field cannot skip the move. Each write to
`tabs` today is a real saved change, and `Tab` is a class, so a change inside a tab never writes the array. A call at
each site leaves a later site free to forget it, which is the failure the first risk names. Private mutators inside the
type are a convention, since Swift lets every member of the type write a private field, so a later `swapAt` would compile
and move nothing. An owned type would make a direct write a compile error. Observers already cover every write that type
would refuse, so it adds a type and a mutator vocabulary with no current failure it prevents. Observers also survive
UTERM-053 M1's rewrite of the terminal's insert and remove sites, whichever proposal lands second. If that rewrite or
UTERM-058 M2 moves the tabs out of a stored array property, the move goes in the one function that owns inserts and
removes. See the risk on those proposals.

## Design Decisions (Open)

None.

## Risks

- **A saved change that does not move the revision leaves the layout stale** — likelihood: low, impact: medium.
  The layout file keeps the old directories or selection until another change or quit saves it. A crash before then
  loses them.
  Mitigation: observers on the tabs and the selection, and the record setter for each directory, move the revision at
  every write, so no site has to remember to. A test changes a background tab's directory and the selection, and opens,
  reopens, and closes tabs. Each one moves the revision and reaches the next saved layout. A title change moves nothing.
- **UTERM-052 M2 changes the revision's contract before this lands** — likelihood: low, impact: low.
  This proposal adopts whatever M2 ships, and the terminal's sites do not depend on its form.
  Accepted: the milestone below cannot start until M2 is done, so it reads the shipped contract.
- **The assembled payload drifts from `TerminalDescription`'s coding, and the layout file loses a field** —
  likelihood: medium, impact: medium.
  The applet assembles the top level around the kept records instead of encoding `TerminalDescription`. A field added
  later could be left out, and ADR-06 would then drop it from every save without an error.
  Mitigation: an M1 test compares the assembled payload with `JSONValue(encoding:)` of the same description after each
  kind of change, for a fixture with every field set. It fails when the description gains a field the assembly does
  not write.
- **UTERM-053 M1 or UTERM-058 M2 changes how the terminal stores its tabs, and the observers stop firing** —
  likelihood: medium, impact: medium.
  UTERM-053 M1 makes the terminal publish a read-through view over its tabs and selection, and gives every tab a stored
  position kept by one insert and remove function. UTERM-058 M2 gives the terminal a map from ID to tab. If either moves
  the tabs out of a stored array property, a write no longer runs the array's observer, and a saved change skips the
  revision.
  Mitigation: the revision moves at every write to the terminal's tabs and selection, wherever that storage lives. When
  the storage stops being a stored array property, the move goes in the one function that owns inserts and removes. M1's
  revision tests stay in the suite, and pass before and after UTERM-053 M1 and UTERM-058 M2, whichever lands first.

## Milestones

### M1: The terminal's change check and save encode no tab

**Status:** NOT STARTED

- A test shows that a burst of title changes on the selected tab costs the window's change check no more per change at
  1,000 tabs than at 10 tabs, with `describe()` timed apart
- A test changes a background tab's directory, the selection, and opens, reopens, and closes tabs. Each one moves the
  revision and reaches the next saved layout. A title change, a link hover, a segment change, and a command that
  finishes with a nonzero exit in the selected tab move nothing and are not layout changes. Each check asserts that the
  revision moved, not by how much, since one change may move it more than once
- A test shows that a restored pane's first change report, before any save, counts as a layout change
- A test shows that a start that drops a tab whose session failed moves the revision, and the drop reaches the next
  saved layout
- A test shows that the same directory reported twice by a tab moves the revision once, and rebuilds that tab's record
  once
- A test shows that `describe()`'s payload equals an independent `JSONValue(encoding:)` of the same
  `TerminalDescription` after a directory change, a tab opened, reopened, and closed, a selection change, and a restore,
  for a shell pane and for a program-mode pane with a command. The fixture sets every field, and the test fails when
  `TerminalDescription` or its tab gains a stored property the assembly does not write, even one left nil. The expected
  description is built from the applet's state apart from the assembly path
- A tab's reported directory is `private(set)` on the tab, and its only setter rebuilds the tab's record
- A test shows that the saved description alone equals `describe()` without its undo part, after each kind of change
  in the payload test above, with closed tabs present
- A test shows that the window's save, through the applet type it holds, reaches the terminal's own answer to the call
  for the saved description alone, not the protocol's default
- A test shows that a restore and an undo reopen build each tab's record once, and that the first save after either
  encodes no tab
- The bug `20261122-terminal-describe-encodes-every-tab-at-each-change` is closed

## Decision Log

- 2026-11-24: Filed as a draft from bug `20261122-terminal-describe-encodes-every-tab-at-each-change`. The triage
  measured 21 µs per tab per `describe()` in a debug build, and found that the closed tabs are capped at 20. The user
  chose a proposal over amending the bug, with the revision settled as the mechanism. The other choice was adding the
  terminal to UTERM-052, which would reopen that accepted proposal's settled exclusion of the terminal.
- 2026-11-24: Review start: 1 milestone, 1 settled decision, 2 risks, no `**Live after:**` lines or row gates, no
  out-of-scope statements; the user asked for an autonomous review of the three open questions. Baseline is the commit
  "Draft UTERM-059 for the terminal's per-tab encode at each change".
- 2026-11-24: Correction of fact, from the review's trace of the premise. Motivation said "A restored program-mode pane
  holds no session per waiting tab, so a stored layout can carry any number of them." Program mode never opens a second
  tab, so a pane uniterm writes holds one. Only a layout file uniterm did not write reaches the unbounded case. A shell
  pane stays bounded by the system's pty limit, which uniterm does not set.
- 2026-11-24: The terminal is fixed once UTERM-052 M2 lands, over deferring or rejecting it. Converged in 1 pass
  (autonomous). The critique added a status-only host call, a cached description compared by storage, and a restore
  that cuts a program-mode pane to one tab. None of them could win. Motivation now names a finished command in the
  selected tab as a report site. The decision's Leaves undone line names the tab bar's walk at each title change, which
  UTERM-053 M1 owns. Routed a finished-command check to M1.
- 2026-11-24: Each tab keeps its encoded record, built through the tab type's own coding, over accepting a full encode
  at each save or building the payload off the main thread. Converged in 1 pass (autonomous). The critique added a
  hand-built record, a kept array of records, and the window reusing a saved description while the revision holds. The
  last is a scope addition to UTERM-052's window side, and none could win. The ADR-08 deviation now names the pass over
  the kept records in every terminal pane at every save. Routed three checks to M1: an equal directory report moves
  nothing, the payload equals an independent encode after each kind of change, and a restore builds each record once.
- 2026-11-24: Observers on the tab array and the selected index move the revision, beside the record setter for each
  tab's directory, over a call at each site. Converged in 1 pass (autonomous). The critique added a small owned type for
  the tabs and the selection, which could not win, and showed that private mutators cannot keep the type's other
  members out. A start that drops failed tabs needs no new report, since the next save from any cause writes the drop.
  Routed a check to M1 that the revision tests assert a move, not an exact count.
- 2026-11-24: The whole-proposal review found that the default saved-description call still encodes the closed tabs at
  every save, so "a save encodes nothing" did not hold. Reopened that part of "The terminal adopts the saved-state
  revision" (autonomous). The terminal now answers the call itself, and `describe()` is that answer plus the undo part.
  Converged in 1 pass (autonomous). The decision said "The terminal keeps the call's default answer, `describe()`
  without the undo part." Its Leaves undone line said "each save still builds the payload from every tab", which the
  kept records had already made untrue. Caching the undo part could not win. Rejected the finding that closed-tab
  titles have no length bound, since every title is cut to 80 characters when it arrives. Routed two checks to M1: the
  saved description equals `describe()` without its undo part, and the save reaches the terminal's own answer.
- 2026-11-24: Fixed the rest of the whole-proposal review (autonomous). Added UTERM-053 and UTERM-058 to Impacts, with
  a risk that either changes how the terminal stores its tabs and the observers stop firing. The observer decision now
  says where the move goes if the storage changes. Added the risk that the assembled payload drifts from the
  description's coding. The fix decision's Leaves undone line now names the published-list read and the palette
  rebuild at each title change. The Summary names the restore's one encode per tab. Routed to M1: the payload fixture
  sets every field, and the directory is `private(set)` on the tab. Correction of fact: M1 said "a restored pane's
  first change report counts against the revision the window recorded at restore". The window records a revision only
  at a save, so the check now says the first report before any save counts as a layout change.
- 2026-11-24: The re-check pass converged with no design-level finding (autonomous). Routed to M1 that the payload test
  catches an unwritten field left nil, and builds its expected description apart from the assembly path.
- 2026-11-24: Risk review (autonomous). Each risk carries a likelihood, an impact, and a mitigation or an acceptance.
  None is high in both. The contract members ship in one binary, and the layout file's bytes do not change, so no
  decision is a one-way door and no version skew applies. The in-flight UTERM-052 M2, UTERM-053 M1, and UTERM-058 M2
  are each covered by a risk.
- 2026-11-24: Review gate: kept all. The user chose that the terminal answers the call for the saved description alone
  itself, over keeping the default, which encodes the closed tabs at every save, and over caching the undo part.
- 2026-11-24: No decision earns an ADR. Each shapes the terminal applet alone.
- 2026-11-24: Accepted.

## References

- ADR-08: UI responsiveness
- UTERM-052: the browser's description never encodes tabs on the main thread
- UTERM-051: the launch reads the layout off the main thread
- Bug `20261122-terminal-describe-encodes-every-tab-at-each-change`
