# UTERM-017: Status Bar Placement and Contract

**Status:** implemented
**Created:** 2026-11-05
**Updated:** 2026-11-06

## Dependencies

- UTERM-001: the status bar, its segments, and "Status message model"
- ADR-05: detach holds back alerts, and work kept alive after close must be visible

## Impacts

- UTERM-001 — "Status message model": this proposal supersedes its repeat, unseen-indicator, and history policies
  where stated below. The implemented proposal stays frozen; M1 records a supersession marker rather than rewriting it.
- UTERM-003 — "Placement of refusals": the REPL budget refusal says "the status bar says why" for a pane with nothing
  else to show.
- UTERM-004 — "A window-owned slot" and "History": the host-owned pending-permission indicator needs a home, and
  driver stderr shares the history.
- UTERM-005 — "Placement of refusals": the address bar's refusals and the profile label.
- UTERM-008 — "Notice levels": the level rule moves here from its Decision Log. "Placement of refusals": the file
  failure box.
- UTERM-009 — "The applet contract": this proposal supersedes detached-notice handling and adds failure history.
  Its implemented design stays frozen; M1 records a supersession marker, and M3 changes the current applet behavior.

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
- Every admitted notice enters the bounded history, so it can be read after clearing until retention evicts it.
- A failure that leaves the pane empty, and the wait while something opens, stay in the pane.

Rationale: the user chose this for the map and the data viewer at review, after the map's notices covered its
attribution. The status bar exists to carry this kind of information. A pane that has nothing to show has room to
explain itself, and the status bar's message may be gone before the user looks.

### Notice levels

Decision: a notice that some content is not shown is a warning. A notice that changes nothing on screen, such as a file
found at a new path, is info. Lost user work, including work that cannot reach disk, is an error. Its message never
times out; replacement leaves unseen-error attention until acknowledged. Amended 2026-11-06; see Decision Log.

- Each notice carries its level, so an applet never picks one by matching text.

Rationale: the user approved this rule after the audit found the two viewers posting the same kind of notice at
different levels. A warning clears in 5 seconds, which suits content left out. Lost work must not clear its attention
signal on its own.

### Version skew

The status bar is in-process. No contract here crosses a deploy unit. UTERM-004's driver stderr keeps its wire format.
Only the host's handling of the text may change.

Origin, delivery, source identity, slots, and history are runtime state in the same app artifact. No saved layout or
public script/driver protocol changes. Reverting the app restores the former presentation without a data migration.

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

Decision: A. The host owns one typed slot per active kind, in fixed order before the focused applet's
segments: layout not saved, pending permissions, and work surviving close. The message, dismiss control, and unseen
indicator remain before these slots. Slots are runtime state and never enter the layout file.

Each active kind stays discoverable at the minimum supported width, with compact symbols and full accessible labels
and tooltips. This proposal builds the layout-not-saved state. Permission and surviving-work producers supply their
state when their own features are built; it does not build those subsystems. An applet retaining work still owns its
time bound and indicator under ADR-05. The host slot presents that applet-supplied state without retaining its applet.

Rationale: simultaneous durable conditions must not replace one another or compete with transient notices. A tooltip
behind the most important condition hides the others.

### Removing repeats

Each applet removes its own repeats today. Anything that skips that step repeats.

- A. The queue drops a message whose source and text match one still pending or shown. Applets keep their own
  once-per-load rule.
- B. Applets keep sole ownership. The rule above stays in each applet, and a test checks each path.
- C. Both: the queue coalesces as a backstop, and applets keep their rule.

Constraint: ADR-05 says uniterm does nothing else on an applet's behalf. A queue rule must not stand in for an applet's
own response. Coalescing a display is not acting for the applet, but this needs settling.

Decision: C. Applets keep once-per-load or once-per-event ownership. The queue also coalesces repeated
presentation when source identity, level, and text match a message still pending or shown. Every admitted post enters
the bounded history, including a post whose presentation coalesces. A repeat never restarts the displayed dwell time.
A new load posts again; there is no permanent text suppression.

Source identity excludes mutable labels. Distinct pane IDs and levels never coalesce. Queue display policy is not an
applet's lifecycle response and does not replace its once-per-load rule under ADR-05.

Rationale: both layers serve different failures. Applets recognize semantic events; the queue prevents repeated
presentation without erasing their diagnostic record.

### Posting while detached or during restore

ADR-05 says an applet holds back alerts while detached. The terminal holds its notifications until reattach. The
viewers post load notices from detached panes. At launch, many restored panes can post at once, and the bar skips to
the newest.

- A. Load notices are not alerts. They post while detached, since the history keeps them. Record why.
- B. Load notices are alerts. Each applet holds them until reattach, as the terminal does.
- C. The host holds every message from a detached pane until reattach, so no applet does it.

A second question: whether restore-time notices go to the history only, without taking a turn on the bar.

Decision: B for detached posting. Load notices and terminal notifications are alerts for presentation.
Each applet responds to detach by withholding their visible presentation. A shared bounded helper may implement that
response, but the host never infers or takes over the applet's lifecycle policy.

An applet records an alert in the window history when it occurs through explicit history-only delivery. That delivery
raises no unseen indicator, sound, or message. On reattach the applet presents its bounded retained alerts without
adding the same history entries again. Close leaves the recorded history intact. Retention is bounded in both count
and text size; presentation loss from that bound must be represented by a count. No history is persisted across
window close. Lasting state segments reflect current state when the pane returns.

Rationale: history preserves what happened without interrupting the user for hidden content. Applet-owned suppression
honors ADR-05 and makes the terminal and viewers consistent.

Restore-time delivery follows "Restore-time notices" below.

### Clickable segments

A segment takes no action. Every actionable state therefore stays in the pane. UTERM-005 records the same limit.

- A. Segments stay plain. Record it as a rule that holds across applets.
- B. A segment may carry one command from the registry, run on click.

Constraint: a status segment grants no permission. ADR-09 still requires a deliberate local approval flow for added
authority. Reserved window keys remain owned by uniterm under ADR-04.

Decision: A. Applet and window state segments stay plain. Existing history activation and message dismissal
remain controls. A state needing an action exposes it through the pane, menu, palette, or the feature's existing local
panel. There is no command or callback property on a state segment.

Rationale: the current use cases already have explicit action entry points. General segment dispatch would add an
unneeded contract and change the established click-to-history behavior. A status click supplies no permission grant;
ADR-09 still requires authenticated scope and a deliberate local approval flow.

### Restore-time notices

Whether restore-time notices go to the history only, without taking a turn on the bar.

Decision: restore-origin info and warning notices enter history without taking a turn in the message area.
Attached-pane warnings still raise the lesser unseen signal. Restore-origin errors use ordinary error presentation
when attached. Detached applets suppress all attention under the detached-posting rule. Later user loads post normally.

The load carries its origin explicitly through asynchronous completion and downstream callbacks, alongside its
existing generation. There is no global startup timeout or implicit inherited suppression. Restore never retries a
program or expands execution intent.

Rationale: launch chatter must not bury current activity, but loss of user work must remain visible.

### A signal for missed warnings

Only errors stay and raise the unseen indicator. A warning that cleared while the user looked away leaves no trace on
the bar.

- A. No change. The segment pattern covers lasting state, and one-off warnings are minor.
- B. The unseen indicator also counts warnings, in a lesser tone.
- C. Warnings stay until the next message replaces them, like errors, but need no dismissal.

Decision: B. Track unseen warnings and errors separately. Error tone wins while any unseen error remains;
otherwise unseen warnings use a lesser tone. Warnings still clear after 5 seconds. Errors do not time out.

History acknowledges only the record IDs actually exposed in its visible viewport and current filter. Merely opening
the panel acknowledges neither hidden rows nor later arrivals outside that viewport. Detached history-only records
raise no signal until the applet presents them on reattach. Restore-origin warnings from attached panes can raise the
signal without entering the message area.

Rationale: extending dwell alone does not account for replaced or skipped warnings. A severity-aware indicator keeps
missed notices discoverable without making all warnings sticky.

### History filtering

Original question: whether the history panel filters by pane. A filter keys on the stable pane ID, per ADR-02,
not on the title. One history per window keeps 500 messages; source titles can repeat.

Decision: one retained store, with All as the default and an optional pane filter keyed by stable pane ID. Rows and
filter choices show the snapshot title plus a distinguishing pane ID. Closed panes remain distinguishable and
filterable while their rows remain. Host and script records remain in All and never inherit the focused pane's ID.

Rationale: a filter needs no separate source-owned stores and makes two equally named panes distinguishable.

### History navigation

Original question: whether a click on a history row focuses the pane that posted it.

Decision: an explicit Focus Pane action navigates to a live source pane in the same window. Reading and selecting
row text never changes focus. A closed source retains its row and identity, with navigation unavailable. Activation
resolves the ID again. It never reopens a pane, invents a tab target, or runs a program.

Rationale: deliberate navigation helps locate the source without coupling ordinary reading to a focus change.
This adds navigation to the existing display-only history; the no-addition alternative leaves lookup manual.

### History retention

Whether the cap is per source, so one chatty source cannot push out other panes' errors, or errors are kept apart
from the cap.

Decision: keep one hard aggregate limit of 500 retained records: 100 errors and 400 info/warnings.
Each pool evicts the oldest record from its most represented source; ties use the oldest record. These are policy
constants, not settings. A non-error flood cannot evict another pane's error. More than 100 active error sources cannot
each retain a row. This is bounded diagnostic history, not a permanent audit log.

Bound retained text, pending and detached presentation storage, and folded-error storage in both count and bytes.
Source indexes and loss summaries must also stay bounded. Retention loss has a readable summary and unseen severity
counts; eviction never acknowledges unseen notices. The summary has an explicit acknowledgement path so a lost row
cannot leave an impossible-to-clear indicator.

The host binds source identity at origin. Pane messages keep their original stable ID after close, rather than
collapsing every closed pane to ID 0. Display names never determine identity. Non-pane sources remain distinguished by
kind and a host-issued producer identity when equal names can collide. A producer cannot claim another producer's
identity. Identifiers and retained bindings are runtime-only and bounded with their producers and records.

UTERM-004 bounds, sanitizes, and coalesces stderr before admission to the main-thread queue. This proposal proves the
consumer contract with synthetic producers; UTERM-004 wires the actual driver.

Rationale: separate bounded severity pools protect real errors from diagnostic chatter. Source-aware eviction keeps a
single producer from dominating either pool without multiplying the aggregate limit by the source count.

### Driver stderr levels

What level driver stderr posts at. Errors stick and fold together, so stderr as errors would bury real ones.

Decision: raw stderr is info-level diagnostic text. It goes to the history only and takes no turn on the bar. Its text
is sanitized and coalesced, never matched against words to guess a level. A host-observed driver exit or protocol
failure creates a separate typed warning when requested content is unavailable, or an error when user work is lost. Its
owning feature supplies the pane explanation and explicit restart action.

Rationale: stderr is a channel, not a severity. Treating every line as an error would bury loss-of-work errors. This
changes no driver wire format and promises no lossless per-line history beyond the bounded ingress. Amended 2026-11-06;
see Decision Log.

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

Decision: apply the content-availability rule to each named case.

- A map with usable tiles or command-layer pins reports a file failure once as a status warning and history entry.
  A failed-file segment remains while the state holds. No file-failure box covers the map.
- An empty data viewer or refused REPL shows a durable explanation in its pane and records one diagnostic history
  entry. It needs no competing transient explanation. The history entry has the typed failure level.
- A refused user address leaves the existing page visible. It posts one warning to the bar/history and marks the
  address input invalid without covering the page. A refused restored URL with only blank content gets a durable
  pane explanation. Programmatic callers still receive their structured refusal; this does not change authorization.
- The active browser profile remains visible locally on every pane. A focused-only segment cannot meet that existing
  requirement. UTERM-005 M5 keeps its hands-on placement review. No profile selector or second store is added.
- Retry is always the user's action. A restored refusal never runs a program automatically.

M1 implements the map and current notice/history machinery. UTERM-003 and UTERM-005 wire their actual REPL and browser
paths when built, using the contract here. A requested load or operation not shown is a warning; a benign relocation
is info; lost user work, including work that cannot reach disk, is an error. Amended 2026-11-06; see Decision Log.

Rationale: usable content stays unobscured, while an empty pane keeps the explanation the user needs to recover.

### The level rule as an ADR

The level rule is a cross-applet contract. It may belong in an ADR once settled, so a new applet cannot miss it.

- A. Write an ADR for placement and levels.
- B. Keep it in this proposal and in the doc comment beside the code.

Decision: B. Keep placement and levels in this proposal and in the doc comment beside the code. The user declined
an ADR at the final gate.

Rationale: the proposal and code documentation carry the cross-applet rule without a separate ADR.

## Design Decisions (Open)

None.

## Risks

- **A shared rule drifts from the applets** — likelihood: medium, impact: low. An applet built later may pick its own
  placement. Mitigation: the rule lives beside the notice type in AppletKit, and each applet's tests check its levels.
- **Window slots crowd a one-line bar** — likelihood: medium, impact: medium. Window state and applet segments share
  one line. Mitigation: settle the order and overflow with the slot design, and check it in a narrow window.
- **A queue-level repeat filter hides a real repeat** — likelihood: low, impact: medium. Two failures with the same
  text from one source may be distinct events. Mitigation: coalesce only while the first is pending or shown, and keep
  every post in the history.
- **Holding messages while detached loses them** — likelihood: low, impact: medium. A pane closed while detached
  would drop what it held. Mitigation: applets record history-only entries when events occur, before close.
- **Later features change their status producers** — likelihood: medium, impact: medium. UTERM-003, UTERM-004, and
  UTERM-005 are not built, so their producers may change. Mitigation: this proposal defines presentation contracts
  and tests them with synthetic producers; their owning milestones wire the actual REPL, permission, and stderr paths.
- **Bounded history loses diagnostic detail** — likelihood: high, impact: medium. Sustained posting exceeds either
  retention pool, and more than 100 error sources cannot all retain a row. Mitigation: source-aware eviction,
  separate severity pools, bounded text and storage, readable loss summaries, and explicit acknowledgement of unseen
  losses. Accepted for the rest: this is session diagnostic history, not a durable audit log.
- **Quiet restore or detached posting hides a failure** — likelihood: medium, impact: medium. A restore completion or
  detached alert may arrive long after launch. Mitigation: explicit per-load origin, ordinary attached-error display,
  attached warning attention, history recorded at event time, and bounded reattach presentation with an overflow count.

## Milestones

### M1: Shared rules and the window slot

**Status:** DONE

- Every implemented applet's notices carry a level by the settled rule, and its tests check them
- The map file-failure overlay becomes one warning/history entry and a lasting failed-file segment
- Empty current viewers retain pane explanations and record one diagnostic history entry
- Failure text and segments follow the current load generation after replacement or cancellation
- Frozen UTERM-001 and UTERM-009 receive supersession markers and Decision Log links to this proposal
- UTERM-003, UTERM-004, UTERM-005, and UTERM-008 carry the applicable contracts into their owning milestones
- The rule sits beside the notice type in AppletKit
- The window slot shows "Layout not saved" in every window of a second instance, for as long as the instance runs
- The slot is not written to the layout file
- The user looks at the bar with the slot showing, in both dock positions and a narrow window
- Every active window-state kind remains discoverable at the supported minimum width, with a usable message area

**As built:**

- The check where the user looks at the bar with the slot showing, in both dock positions and a narrow window, is left
  to the user. Package tests lay out the real bar at the window's real minimum width, but only the user's eyes judge
  how it looks. The check includes hovering each window slot for its tooltip, which a headless test could not verify.
- An empty map is one whose tiles report a failure and whose command layers hold no pin. The map decides on each
  refresh. A failure that arrives while tiles or pins still show is a warning on the bar. If the tiles fail later, the
  pane also explains it. If the tiles come back after an empty-pane failure, the history keeps its one entry and the
  failed-file segment stays.
- A memory stop that loaded no rows in the data viewer counts as an empty pane. It records one warning in the history
  and posts nothing.
- A notice now has a key apart from its text, and the cut-rows notice waits for the load to settle so it posts once
  with the final count. A sheet switch resets the viewer's notices, because each sheet is a load.
- Level audit: a terminal that cannot start, a program that cannot start, a tab that cannot open, and a file the
  viewers cannot open were errors and are warnings now, since nothing the user made is lost. A refused map edit stays a
  warning. It keeps the file and any earlier unsaved pins and clears only the undo stack. A failed save stays an
  error, because the rule now names work that cannot reach disk. The drop and open-panel catch blocks for a throwing
  `replaceSource` are unreachable today, since no applet's `replaceSource` throws. They stay as part of the contract.
- Window state lives on the window set. The layout persistence publishes the second-instance state there, so the app
  delegate needs no change. A narrow bar hides applet segments from the last one back, and the window's minimum width
  is unchanged. See Decision Log.

### M2: The queue

**Status:** DONE

- The settled repeat rule holds: a test posts the same message twice and checks the bar and the history
- Equal pane IDs with different titles still coalesce; different IDs or levels do not
- A repeated display never extends its dwell or erases an admitted history entry
- The settled warning signal holds, with a test on a fake clock
- The history meets the All/pane filter and 100-error/400-other retention rules
- An info flood from one source cannot evict another pane's error; error floods exercise source-aware eviction
- All retained, pending, folded, source-index, and summary storage stays bounded in count and bytes. Amended
  2026-11-06; see Decision Log.
- Eviction preserves unseen severity and offers a readable loss summary with deliberate acknowledgement
- Same-name producers and posts after pane close retain distinct host-bound origin identities
- Filtered-out and offscreen messages remain unseen while the history panel is open
- Every retained message and retention-loss summary has readable full text, including through keyboard accessibility
- A pane closed between row rendering and Focus Pane activation is never reopened or targeted by a stale ID
- A synthetic stderr flood never blocks the main thread; actual driver ingress remains UTERM-004
- Raw stderr remains info regardless of text; typed driver failure retains semantic severity

**As built:**

- The check where the user looks at the expanded history is left to the user: the filter menu, the Focus Pane controls,
  the loss strip, and keyboard use. Package tests drive the real panel at 500 rows. Only the user's eyes judge its
  layout.
- Pane identity binds when an applet takes its pane, including a launcher swap. Other producers get an identity from
  the status center. The retention, byte, and wording choices are in the Decision Log.
- Coalescing, the two unseen sets, the two retention pools, and the loss summary work as the settled decisions say.
  Eviction moves a dropped record's unseen count into the summary, and only the summary's control clears it.
- The panel reports the rows whose whole line is in view, and only while the window can show them. The window
  acknowledges exactly those. Reading, filtering, and scrolling never move the keyboard.
- The synthetic stderr consumer is a bounded ingress plus a producer method. A typed failure posts at its kind's level.
  Actual driver wiring stays with UTERM-004.
- A full test run hung once. Window closes in the package tests leave dispatch workers blocked in AppKit's animation
  loop, so the shared pool had none left for a later test. The leak predates this milestone and is not fixed here. The
  flood test uses its own threads.

### M3: Detached panes and restore

**Status:** DONE

- The terminal, the map, and the data viewer follow one rule for posting while detached
- A pane closed while detached keeps its held messages in the history
- Detached history-only delivery raises no visible message or unseen indicator
- Reattach presents bounded held alerts without duplicate history; overflow has a count. A new load drops the
  presentation of the replaced load's held notices, and keeps held errors and alerts no load produced. Amended
  2026-11-06; see Decision Log.
- A restore-origin warning recorded while detached retains restore policy on reattach: warning attention, no message
  turn
- Restore origin survives asynchronous completion and a user replacement load never inherits it
- A launch that restores many panes follows the settled restore rule
- Detached presentation storage stays bounded in count and bytes. Amended 2026-11-06; see Decision Log.

**As built:**

- Nothing in the host sends `detach` or `reattach` yet, as UTERM-001 M10 intends. The detached behavior therefore has no
  user path. Package tests call the events directly on each applet. A trigger needs its own proposal.
- The terminal, the map, and the data viewer share one rule through one helper that each applet owns and calls from its
  own detach and reattach. The host adds no policy. The terminal now keeps a bounded number of notifications, where it
  kept only the newest. The test that pinned newest-only changed with the contract.
- Every terminal post goes through the same helper, including a failed shell start on a launch restore. Its clipboard
  dialog is a question, not a notice, and still shows while the pane is detached. It is left alone.
- The window starts each launch-restored applet with the restore origin, and every other applet with the user origin. A
  file-watcher reload and a revert are a third origin that posts normally. The reasons are in the Decision Log.
- A tile failure is not a load, so it carries no origin and still posts once per outage.
- The many-pane launch is proved through the real window, host, and status center with a stand-in applet. The real
  viewers and the terminal are proved alone. No package test launches real files in many real panes.
- A pane can present only the history records its own host issued, once each. The queue also refuses an ID it never
  issued and another source's retained record. The host's ledger keeps an entry while the history keeps its record,
  so a held alert never falls off it and returns as a duplicate.
- A new load calls `replaceLoad` on the applet's alert helper. It drops the held notices the replaced load produced.
  Their history records stay. Held errors stay, and so do alerts no load produced, such as a terminal notification.
  A notice from a nested table is not a load notice. The map's load, the data viewer's load, and its sheet switch each
  make the call.
- UTERM-008's relaunch notice still reads true. Its program-pin producer is unbuilt, so its restore-origin info goes to
  the history under this rule when it ships.

## Decision Log

- 2026-11-05: Drafted after a status bar audit, at the user's request. The placement rule and the level rule are the
  user's, chosen during the map and data viewer reviews. The rest is open.
- 2026-11-05: Review start: 3 milestones, 3 settled entries, 4 risks, no `Live after` lines or row gates,
  and no explicit out-of-scope statements; at "Draft a proposal for where status notices go and the shared queue".
  The user requested an autonomous review and one commit at the end.
- 2026-11-05: Segments stay plain; actions use existing explicit controls (autonomous). Converged in one critic pass.
- 2026-11-05: Detached posting: applet-owned suppression, history-only recording, and bounded reattach presentation
  (autonomous). Converged in one critic pass.
- 2026-11-05: Repeats: applet event ownership plus source/level/text display coalescing; retain admitted history
  (autonomous). Converged in one critic pass.
- 2026-11-05: Window slots: typed runtime slots per kind, with producers built by their owning features (autonomous).
  Converged in one critic pass.
- 2026-11-05: Risk review: later features own their status producers; synthetic producers prove this contract before
  those features are built (autonomous).
- 2026-11-05: History navigation: explicit Focus Pane action, never a side effect of reading or selecting text
  (autonomous, addition). Adds live-pane navigation to history. Converged in one critic pass.
- 2026-11-05: History filtering: All plus stable-pane-ID filtering, snapshot labels, and closed-source identity
  (autonomous). Converged in one critic pass.
- 2026-11-05: Missed warnings: lesser unseen tone, with acknowledgement by exposed record ID rather than panel-open
  state (autonomous). Converged in one critic pass.
- 2026-11-05: Restore-time notices: history-only info/warnings, with attached warning attention and ordinary errors;
  explicit per-load origin survives async completion (autonomous). Converged in one critic pass.
- 2026-11-05: Clarified the original error rule: errors never time out; replacement retains unseen-error attention.
  Clarified that history keeps admitted notices only within its existing bounded-retention purpose (autonomous).
- 2026-11-05: ADR candidate (cuts across the system): notice placement preserves usable content, and severity
  distinguishes unavailable content from loss of user work. Declined on 2026-11-05: the user chose no ADR.
- 2026-11-05: Refusals: usable content gets status/history and lasting state; empty panes keep a durable explanation;
  browser profiles stay pane-local and retries stay explicit (autonomous). Converged in one critic pass.
- 2026-11-05: Driver stderr: untyped diagnostic text is info; host-observed failures carry semantic typed severity
  (autonomous). Converged in one critic pass. Actual driver ingress stays with UTERM-004.
- 2026-11-05: History retention: a 500-record aggregate split into 100 errors and 400 other records, with
  source-aware eviction, bounded summaries, and original source identity after close (autonomous).
  Converged in one critic pass. Bounded diagnostic loss is accepted; eviction does not acknowledge unseen notices.
- 2026-11-05: Risk review: recorded bounded diagnostic loss and delayed restore/detach exposure, alongside the
  dependency on unbuilt producers (autonomous). No high-likelihood/high-impact risk or deploy gate remains.
- 2026-11-05: Coherence review: no inconsistency, gap requiring a design change, or weak decision. Routed the
  restore-plus-reattach combination to M3. Corrected the original constraint's attribution to ADR-09: that ADR requires
  scoped local approval, not a general ban on clicks (autonomous).
- 2026-11-05: Proposal convergence: full critique SOUND, followed by a CONVERGED re-check of corrected ADR
  attribution, runtime rollback/skew text, and risk entries. No design defect or dissent remains (autonomous).
  Nine critic findings were routed to checks in M1, M2, and M3; no milestone or deploy gate was added.
- 2026-11-05: Review gate: kept all decisions, including the Focus Pane addition; nothing reopened. The user approved
  including the proposal index's matching status row in the single final commit.
- 2026-11-05: Accepted at the user's final gate. No ADR created. The three milestones remain unscheduled.
- 2026-11-05: Scheduled as M1-M3 in queue.md, at the top of the queue.
- 2026-11-06: M1 level audit (work-queue best guess). Failed terminal starts and failed file opens in the viewers moved
  from error to warning, because the level rule keeps error for lost user work. A failed save stays an error. The rule
  now names work that cannot reach disk, which covers it. Reverting is a one-line change per post.
- 2026-11-06: Amended "Notice levels" and "Placement of refusals" (work-queue best guess). Both said "Lost user work is
  an error", and a failed save keeps its unsaved edits in memory, so the wording did not literally cover it. Both now
  say "Lost user work, including work that cannot reach disk, is an error". The AppletNotice doc comment carries the
  same words.
- 2026-11-06: M1 window state reaches the window set from the layout persistence, which already holds the set, and the
  slot's text lives with the state (work-queue best guess). Applet segments are the only thing a narrow bar hides.
  The window's minimum width, which comes only from the pane tree, is unchanged.
- 2026-11-06: M2 retention, identity, and panel mechanisms (work-queue best guess). The byte limits are policy
  constants sized so the count limits bind first: 2,048 bytes per message text, 128 per source label, 128 KiB for the
  error pool, 256 KiB for the other pool, 64 KiB and 32 entries for waiting messages, 128 KiB and 100 entries for
  folded errors, and 64 live non-pane producers. Non-pane identity comes from the status center, and the source-taking
  post is package-only. Raw stderr is recorded to the history without a bar turn, since a flood of info would
  otherwise take every turn. The loss summary is a strip at the top of the panel, so it stays reachable. Each is a
  small change to revert.
- 2026-11-06: Amended M2's bounded-storage check and added a matching M3 check (work-queue best guess). M2's check
  read "All retained, pending, folded, detached, source-index, and summary storage stays bounded in count and bytes".
  Detached presentation storage does not exist until M3 builds the detach rule, so M2 cannot bound it. M2 drops the
  word, and M3 carries the check. M2 exposes the text cut as a shared helper for M3 to use. If M3 builds the storage
  without a bound, the check fails there.
- 2026-11-06: Amended "Driver stderr levels" and the matching UTERM-004 text (work-queue best guess). The decision said
  raw stderr is info, and UTERM-004 said it appears in the status bar. A flood of info lines would take every turn on
  the bar and bury a real notice, so raw stderr now goes to the history only. UTERM-004's text and check were amended
  to match. Its driver wiring still owes one hop to the main thread for each drain, never one for each line.
- 2026-11-06: Non-pane producers read as "name (applet N)" or "name (script N)" in the bar and the history (work-queue
  best guess). A producer that names itself "uniterm" would otherwise look like the host. Only the host reads as plain
  "uniterm". The status center also checks an identity's kind, so a script cannot post under an applet's number. A
  producer that is dropped without retiring frees its slot. A pane that titles itself "uniterm" still reads that way on
  the bar, as before. Its history rows carry the pane ID.
- 2026-11-06: Keyboard path for the history (work-queue best guess). The panel refuses first responder until the user
  runs the Focus Message History command, which has no default key. The command opens the panel and moves the keyboard
  into its table. The arrow keys move a row cursor, Return runs Focus Pane on that row, Tab reaches the filter and
  the loss control, and Escape returns the keyboard to the focused pane. Mouse reading and opening never move the
  keyboard. A default key would need a shortcut decision under UTERM-013, so none is set. If a key is wanted, it is
  one binding.
- 2026-11-06: The history acknowledges only whole rows, only in a window that can show them, and never from inside
  layout (work-queue best guess). A row with a sliver in view has not been read. A minimized or covered window shows
  nothing, so arrivals stay unseen until it is visible again. The report waits one turn of the main actor when layout
  asks for it, since refreshing the rows from inside layout lays the panel out again. Each is a small change to
  revert.
- 2026-11-06: The set of windows holds at most 32 messages while no window is open (work-queue best guess). Past the
  limit the oldest info or warning goes first, and an error goes only when every held message is one. The next window
  shows one message that counts what was lost, at the most severe level lost. The limit is a policy constant.
- 2026-11-06: ADR candidate (cuts across the system): the host binds a status source's identity at origin, and no
  producer can claim another's. Undecided. Found in UTERM-017 M2.
- 2026-11-06: M3 host delivery (work-queue best guess). The applet contract has one delivery requirement with three
  ways: a message, attention with no turn, and history only. It takes an optional record ID. A call with an ID presents
  that record again and adds no history entry. History-only delivery returns the record ID, so a detached applet keeps
  it. A record that retention dropped before the pane returned moves its signal to the loss summary. The old post and
  record calls are conveniences over it. Each is a small change to revert.
- 2026-11-06: M3 restore marking (work-queue best guess). The start event carries a required origin, restore or user,
  with no default. The window records which applets the launch restore built and starts each with restore, once. Every
  other start passes user: a new pane, a pane reopened by undo, and a launcher swap. The first draft added a separate
  launch-restore call with a default that did nothing. A launch-restored applet could miss it silently, and ADR-05 lists
  four events. The origin now rides on the start event. It is not set in the restoring initializer, because undo reopen
  uses the same initializer and is a user action. A file-watcher reload and a revert are a third origin, reload, because
  neither is the user's new choice or the launch. A sheet switch is a user load. A skipped sort follows the origin of
  the sort now in effect, and a filter does not change it. The changed-on-disk warning follows what set the flag: the
  restore, when it compared the unsaved pins' base with the file, or the watcher.
- 2026-11-06: M3 held-alert bound (work-queue best guess). A detached applet holds at most 8 alerts and 8 KiB, each text
  cut to the status text bound. Past either, the oldest non-error goes first, and an error goes only when every held
  alert is one. The loss is counted, and reattach shows one more message naming the count. It takes the most severe
  level lost and the strongest delivery lost, so a count of restore warnings takes no turn. That message is a new
  history entry. The limits are policy constants.
- 2026-11-06: M3 record ownership (work-queue best guess). A pane's host keeps a ledger of the history records it
  issued, 256 at most, and honors a present call only for its own records and only once. An ID it did not issue is
  delivered as a new record of that pane. The queue also refuses an ID it never issued and a retained record of another
  source, because the loss summary would otherwise show an unseen count with no row to clear. The queue cannot tell who
  made a record that retention dropped, which is why the ledger sits in the host. The limit is a policy constant.
- 2026-11-06: M3 reaches past load notices (work-queue best guess). The map and the data viewer send every post through
  the alert helper, not only their load notices. The user's own actions happen while the pane is attached, so those
  posts are unchanged. A completion that lands while the pane is detached follows the same rule. The terminal sends
  every post through it, so a failed start on a launch restore takes no turn.

- 2026-11-06: Amended M3's record-ownership entry above (work-queue best guess). It said the host's ledger holds 256
  records at most. Hundreds of later detached alerts could push a held error off the ledger, and reattach then
  delivered it as a new record, a second history row. The ledger now keeps an entry exactly while the history keeps its
  record, so retention has one rule and the limit constant is gone. A record the history dropped is delivered as a new
  record, which restores it.
- 2026-11-06: Amended M3's reattach check (work-queue best guess). It let a pane that loaded file A, then file B while
  detached, replay A's held notices after B's, so a stale "File not opened" turn could follow a successful load. A new
  load now drops the presentation of the held notices the replaced load produced. Their history records stay, since
  they were real events. Held errors stay held, because they report lost user work. Alerts no load produced stay held.
  A notice of the load carries that fact when it is delivered, and the applet calls `replaceLoad` where it resets its
  posted notices.

## References

- UTERM-001: Foundation, "Status bar" and "Status message model"
- ADR-02: pane tree nodes have stable IDs
- ADR-03: restored state never runs a program
- ADR-04: uniterm owns key bindings
- ADR-05: applet lifecycle events and applet responses
- ADR-06: layout file versioning
- ADR-09: control authority
