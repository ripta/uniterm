# UTERM-017: Status Bar Placement and Contract

**Status:** draft
**Created:** 2026-11-05
**Updated:** 2026-11-05

## Dependencies

- UTERM-001: the status bar, its segments, and "Status message model"
- ADR-05: detach holds back alerts, and work kept alive after close must be visible

## Impacts

- UTERM-001 — "Status message model": the window gains slots of its own, and the queue may change how it treats
  repeats and warnings. Amend there when the open questions settle.
- UTERM-003 — "Placement of refusals": the REPL budget refusal says "the status bar says why" for a pane with nothing
  else to show.
- UTERM-004 — "A window-owned slot" and "History": the host-owned pending-permission indicator needs a home, and
  driver stderr shares the history.
- UTERM-005 — "Placement of refusals": the address bar's refusals and the profile label.
- UTERM-008 — "Notice levels": the level rule moves here from its Decision Log. "Placement of refusals": the file
  failure box.
- UTERM-009 is implemented and frozen. The rules here describe what it already does, so it needs no change.

## Summary

One rule for where an applet's notice goes, and one rule for its level, shared by every applet. The window gains
status slots of its own, for state that belongs to the window rather than to the focused pane. The open questions
cover the shared queue: repeats, missed warnings, the history, and posting while detached or during restore.

## Motivation

A user review found that the map drew its load notices over the map, where they hid MapKit's attribution and could not
be dismissed. They moved to the status bar. A follow-up audit of every proposal found the same pattern elsewhere:

- The map's offline banner covered a map that still showed pins. It has moved to the status bar.
- The map posted load notices as info, and the data viewer posted the same kind as warnings.
- Four unbuilt proposals said "a message" or "the pane says" without a place. They have been amended.
- "This window's layout is not saved" is true for the whole session, but posts as info and clears in 5 seconds. The
  window has no slot of its own to keep showing it.
- Each applet removes its own repeats. A path that skips that step posts the same message again.
- Warnings clear after 5 seconds, and nothing tells the user one was missed.
- One history per window, capped at 500, has no pane filter. UTERM-004's driver stderr will share it.
- The viewers post load notices from detached panes, while the terminal holds its notifications until reattach.

The fixes so far were made one applet at a time. Without a shared rule, each new applet decides again.

## Design Decisions (Settled)

### Where a notice goes

Decision: when the pane's content is still on screen, a notice posts once to the status bar. When the state it reports
lasts, a segment shows while it holds. When the pane has nothing else to show, the pane says it.

- A notice posts once per load. A refresh that works out the same notice again posts nothing. A new load posts again.
- The history keeps every posted notice, so a notice that cleared can still be read.
- A failure that leaves the pane empty, and the wait while something opens, stay in the pane.

Rationale: the user chose this for the map and the data viewer at review, after the map's notices covered its
attribution. The status bar exists to carry this kind of information. A pane that has nothing to show has room to
explain itself, and the status bar's message may be gone before the user looks.

### Notice levels

Decision: a notice that some content is not shown is a warning. A notice that changes nothing on screen, such as a file
found at a new path, is info. Lost user work is an error, so it stays until the user sees it.

- Each notice carries its level, so an applet never picks one by matching text.

Rationale: the user approved this rule after the audit found the two viewers posting the same kind of notice at
different levels. A warning clears in 5 seconds, which suits content left out. Lost work must not clear on its own.

### Version skew

The status bar is in-process. No contract here crosses a deploy unit. UTERM-004's driver stderr keeps its wire format.
Only the host's handling of the text may change.

## Design Decisions (Open)

### A window-owned slot

The window owns only the message area, its dismiss button, and the unseen-error indicator. State that belongs to the
window has nowhere to stay.

Candidates for what it shows:

- "Layout not saved", in every window of a second uniterm instance
- UTERM-004's host-owned pending-permission indicator
- Work kept alive after a pane closed, which ADR-05 requires to be visible

Options:

- A. One window slot per kind, in a fixed order before the applet segments. Each kind is a case the host fills.
- B. One general window slot that shows the most important window state, with the rest in its tooltip.
- C. No window slot. Window state posts as a sticky message instead.

Constraint: the slot is runtime state only. Writing it to the layout file would need a version bump under ADR-06.

### Removing repeats

Each applet removes its own repeats today. Anything that skips that step repeats.

- A. The queue drops a message whose source and text match one still pending or shown. Applets keep their own
  once-per-load rule.
- B. Applets keep sole ownership. The rule above stays in each applet, and a test checks each path.
- C. Both: the queue coalesces as a backstop, and applets keep their rule.

Constraint: ADR-05 says uniterm does nothing else on an applet's behalf. A queue rule must not stand in for an applet's
own response. Coalescing a display is not acting for the applet, but this needs settling.

### Posting while detached or during restore

ADR-05 says an applet holds back alerts while detached. The terminal holds its notifications until reattach. The
viewers post load notices from detached panes. At launch, many restored panes can post at once, and the bar skips to
the newest.

- A. Load notices are not alerts. They post while detached, since the history keeps them. Record why.
- B. Load notices are alerts. Each applet holds them until reattach, as the terminal does.
- C. The host holds every message from a detached pane until reattach, so no applet does it.

A second question: whether restore-time notices go to the history only, without taking a turn on the bar.

### Clickable segments

A segment takes no action. Every actionable state therefore stays in the pane. UTERM-005 records the same limit.

- A. Segments stay plain. Record it as a rule that holds across applets.
- B. A segment may carry one command from the registry, run on click.

Constraint: a click must never approve or grant a permission, per ADR-09. A segment command must not take a reserved
window key, per ADR-04.

### A signal for missed warnings

Only errors stay and raise the unseen indicator. A warning that cleared while the user looked away leaves no trace on
the bar.

- A. No change. The segment pattern covers lasting state, and one-off warnings are minor.
- B. The unseen indicator also counts warnings, in a lesser tone.
- C. Warnings stay until the next message replaces them, like errors, but need no dismissal.

### History

One history per window keeps 500 messages. The source label is the applet's title, which can repeat, such as two
"zsh" panes. Driver stderr will share the history.

- Whether the history panel filters by pane. A filter keys on the stable pane ID, per ADR-02, not on the title.
- Whether a click on a history row focuses the pane that posted it.
- Whether the cap is per source, so one chatty source cannot push out other panes' errors, or errors are kept apart
  from the cap.
- What level driver stderr posts at. Errors stick and fold together, so stderr as errors would bury real ones.

### Placement of refusals

These cases do not fit the settled rule cleanly:

- The map's file failure shows in the pane, though tiles and command-layer pins can still show. Neither viewer posts
  its load failure to the history.
- UTERM-005 says a refused `file:` or `javascript:` address makes "the address bar say why". The status bar would match
  how the viewers refuse drops.
- UTERM-005's active profile is a lasting fact about a pane. A segment fits, but its placement was left to M5's
  review.
- UTERM-003's REPL budget refusal leaves the new pane empty, and its status message may clear in 5 seconds. The rule
  says the pane should explain itself. Any retry must be the user's, since ADR-03 forbids restore from running a
  program.

### The level rule as an ADR

The level rule is a cross-applet contract. It may belong in an ADR once settled, so a new applet cannot miss it.

- A. Write an ADR for placement and levels.
- B. Keep it in this proposal and in the doc comment beside the code.

## Risks

- **A shared rule drifts from the applets** — likelihood: medium, impact: low. An applet built later may pick its own
  placement. Mitigation: the rule lives beside the notice type in AppletKit, and each applet's tests check its levels.
- **Window slots crowd a one-line bar** — likelihood: medium, impact: medium. Window state and applet segments share
  one line. Mitigation: settle the order and overflow with the slot design, and check it in a narrow window.
- **A queue-level repeat filter hides a real repeat** — likelihood: low, impact: medium. Two failures with the same
  text from one source may be distinct events. Mitigation: coalesce only while the first is pending or shown, and keep
  every post in the history.
- **Holding messages while detached loses them** — likelihood: low, impact: medium. A pane closed while detached
  would drop what it held. Mitigation: whichever option settles posts held messages to the history at close.

## Milestones

Provisional. The open questions may reshape them.

### M1: Shared rules and the window slot

**Status:** NOT STARTED

- Every applet's notices carry a level by the settled rule, and a test per applet checks them
- The rule sits beside the notice type in AppletKit
- The window slot shows "Layout not saved" in every window of a second instance, for as long as the instance runs
- The slot is not written to the layout file
- The user looks at the bar with the slot showing, in both dock positions and a narrow window

### M2: The queue

**Status:** NOT STARTED

- The settled repeat rule holds: a test posts the same message twice and checks the bar and the history
- The settled warning signal holds, with a test on a fake clock
- The history meets the settled filter and cap rules, and a flood from one source keeps another pane's errors
- A stderr flood never blocks the main thread

### M3: Detached panes and restore

**Status:** NOT STARTED

- The terminal, the map, and the data viewer follow one rule for posting while detached
- A pane closed while detached keeps its held messages in the history
- A launch that restores many panes follows the settled restore rule

## Decision Log

- 2026-11-05: Drafted after a status bar audit, at the user's request. The placement rule and the level rule are the
  user's, chosen during the map and data viewer reviews. The rest is open.

## References

- UTERM-001: Foundation, "Status bar" and "Status message model"
- ADR-02: pane tree nodes have stable IDs
- ADR-03: restored state never runs a program
- ADR-04: uniterm owns key bindings
- ADR-05: applet lifecycle events and applet responses
- ADR-06: layout file versioning
- ADR-09: control authority
