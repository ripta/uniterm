# UTERM-059: The Terminal's Change Check Never Encodes Every Tab

**Status:** draft
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

## ADR Deviations

- ADR-08 "The main thread may do local work whose duration uniterm bounds": open. Each save still builds the terminal's
  payload from every tab on the main thread. See "What a save still pays".

## Summary

A terminal pane stops encoding every tab at each change it reports. The window learns of a saved change from the
terminal's saved-state revision, as UTERM-052 sets up for the browser, and skips `describe()` at a report that changes
nothing saved. A title change, the most frequent report, then costs the change check nothing that grows with the tab
count.

## Motivation

The window asks a terminal pane for its description at every change the pane reports. `TerminalApplet.describe`
builds a `TerminalDescription` from every tab, then encodes it and the closed tabs with `JSONValue(encoding:)`. The
window compares the result with the last saved description, in `notifyLayoutIfDescriptionChanged`.

The pane reports a change at each title change of the selected tab, so the status bar can follow it. The title is not
in the saved description. So that comparison always finds no change, and the whole encode buys nothing. A program sets
the title, and a spinner sets it many times a second. The pane also reports a change when any tab's directory
changes, and at each tab insert, remove, and select.

The cost is linear in the tab count. It was measured on 2026-11-23 in a debug build, with a fake engine, with every tab
holding a directory:

| Tabs | One `describe()` |
|------|------------------|
| 1 | 65 µs |
| 100 | 2.2 ms |
| 1,000 | 21 ms |

That is about 21 µs per tab, the same rate UTERM-052 measured for the browser's records. At 1,000 tabs one title change
exceeds a 16 ms frame.

A shell tab holds a pty, which limits a shell pane's tab count. A restored program-mode pane holds no session per
waiting tab, so a stored layout can carry any number of them. ADR-08 allows only local work whose duration uniterm
bounds on the main thread, and a pane has no tab cap.

The closed tabs are capped at 20, so their encode is bounded. The unbounded part is the open tabs.

The bug is `20261122-terminal-describe-encodes-every-tab-at-each-change`. UTERM-052 settled the browser only, and
its Leaves undone lines name the terminal's description as untouched.

## Design Decisions (Settled)

### The terminal adopts the saved-state revision

Original question: whether the terminal adopts UTERM-052's saved-state revision, its call for the saved description
alone, or both.

Decision: the terminal adopts the revision. The window then compares the pane's revision with the one it recorded at
the last save, and skips `describe()` at a report that moved nothing. The terminal keeps the call's default answer,
`describe()` without the undo part.

Rationale: only the revision removes the per-change walk. The saved-description call alone drops the closed-tab
encode, which the cap of 20 already bounds, and leaves every open tab encoded at each change check.

Leaves undone: each save still builds the payload from every tab. See "What a save still pays".

## Design Decisions (Open)

### Where the revision moves

The saved description holds the mode, the command, each tab's reported and start directory, and the selected index. A
change to any of them must move the revision before the pane reports it. A missed site silently skips a layout save
until another change or quit saves it.

Today's sites are each tab's directory report, a tab opened or reopened, a tab removed, a selection change, and a start
that drops the tabs whose session failed. That start reports only a tabs change today, not a change to the
description. The mode and the command are set only when the applet is built. A title change, a link hover, and a
segment change must not move the revision.

Candidates:

- A property observer on each saved field: the tab's reported directory, the tab array, and the selected index. The
  observer moves the revision on a real change. A new site that writes a saved field cannot miss
  it, since it does not have to remember to.
- A call that moves the revision at each site that changes a saved field today. It is explicit at each site. A new site
  must remember to call it.
- A per-tab record of the saved fields, kept as an encoded `JSONValue` and rebuilt on a real change, as the browser
  does. It moves the revision from the record's setter. It also makes the save's pass encode nothing, which ties this
  question to "What a save still pays".

### Whether to fix it at these tab counts

The measurement shows about 21 µs per tab per change in a debug build. A shell pane with 30 tabs pays well under a
millisecond per title change. Only a restored program-mode pane with hundreds of waiting tabs reaches a frame.

Candidates:

- Fix it once UTERM-052 M2 lands, since a program chooses how often the title changes and a pane has no tab cap.
- Defer it, with a revisit hook tied to a measurement of a release build at a realistic tab count, or to a report of
  a slow terminal pane.
- Reject it, and accept the cost as an ADR-08 deviation with a stated reason.

### What a save still pays

Under the settled decision, each save still builds and encodes the payload from every tab on the main thread. A save
runs after a quiet second, or at most every 10 s during a stream of changes. So its cost is per save, not per change.

Candidates:

- Accept the encode at each save as an ADR-08 deviation, as the user accepted the browser's pass over its kept
  records.
- Keep each tab's encoded record, as the browser does, so each save makes only a pointer-sized pass. This is the third
  candidate under "Where the revision moves".
- Build the payload off the main thread from copied tab values. This changes when `describe()` returns its payload,
  which amends UTERM-051's settled "Where the typed decode runs".

## Risks

- **A saved change that does not move the revision leaves the layout stale** — likelihood: low, impact: medium.
  The layout file keeps the old directories or selection until another change or quit saves it. A crash before then
  loses them.
  Mitigation: a test changes a background tab's directory and the selection, and opens, reopens, and closes tabs. Each one moves the revision and reaches the next saved layout. A title change moves nothing.
- **UTERM-052 M2 changes the revision's contract before this lands** — likelihood: low, impact: low.
  This proposal adopts whatever M2 ships, and the terminal's sites do not depend on its form.
  Accepted: the milestone below cannot start until M2 is done, so it reads the shipped contract.

## Milestones

### M1: The terminal's change check skips the description

**Status:** NOT STARTED

- A test shows that a burst of title changes on the selected tab costs the window's change check no more per change at
  1,000 tabs than at 10 tabs, with `describe()` timed apart
- A test changes a background tab's directory, the selection, and opens, reopens, and closes tabs. Each one moves the
  revision and reaches the next saved layout. A title change, a link hover, and a segment change move nothing and are
  not layout changes
- A test shows that a restored pane's first change report counts against the revision the window recorded at restore
- A test shows that a start that drops a tab whose session failed moves the revision, and the drop reaches the next
  saved layout
- The bug `20261122-terminal-describe-encodes-every-tab-at-each-change` is closed

## Decision Log

- 2026-11-24: Filed as a draft from bug `20261122-terminal-describe-encodes-every-tab-at-each-change`. The triage
  measured 21 µs per tab per `describe()` in a debug build, and found that the closed tabs are capped at 20. The user
  chose a proposal over amending the bug, with the revision settled as the mechanism. The other choice was adding the
  terminal to UTERM-052, which would reopen that accepted proposal's settled exclusion of the terminal.

## References

- ADR-08: UI responsiveness
- UTERM-052: the browser's description never encodes tabs on the main thread
- UTERM-051: the launch reads the layout off the main thread
- Bug `20261122-terminal-describe-encodes-every-tab-at-each-change`
