# UTERM-051: The Launch Reads the Layout Off the Main Thread

**Status:** accepted
**Created:** 2026-11-22
**Updated:** 2026-11-22

## Dependencies

- UTERM-001, for the window and layout restore
- UTERM-004, for the routed opens that wait on the launch

## Impacts

- UTERM-050 — "Where the typed decode runs" adds an off-main step to the terminal's restore, which UTERM-050 also
  changes. The step stays free of the directory check, which UTERM-050 moves into the session start.

## Summary

The launch stops reading and decoding the whole layout file on the main thread. That covers the file decode and each
applet's decode of its own payload. The design questions below settle how.

## Motivation

Bug `20261122-layout-launch-read-runs-on-main-thread` records the problem. `applicationDidFinishLaunching` calls
`LayoutPersistence.launch` synchronously. That calls `LayoutStore.beginLaunch`, which reads the file with
`Data(contentsOf:)` and decodes it with `LayoutCodec.decode`.

A pane has no tab cap. A layout with one browser pane of 50,000 tabs took about 1,146 ms to read and decode in a debug
build. The file was 1.9 MB. The wait grows with the tab count.

The file decode is not the whole cost. `LayoutCodec` decodes each pane's payload only as far as a `JSONValue` tree.
Every applet's restoring init except the launcher's then calls `JSONValue.decoded(as:)` on its payload. That function
encodes the tree back to bytes and decodes them into the typed struct. It runs inside `windows.open(restoring:)` on the
main thread. The layout file never holds undo state, so at launch the undo decode has nothing to read.

A review measurement split the restore's cost for one browser pane. The Decision Log holds the numbers. Building the
payload's `JSONValue` tree is about six times the cost of the `decoded(as:)` round trip. The browser's tab bar costs
more than both together: it builds one view per tab on the main thread. Bug
`20261122-browser-tab-bar-builds-a-view-per-tab-on-main-thread` records that cost, which every refresh also pays.

No window exists during the wait. What freezes is the menu bar, the Dock, Cmd-Q, and the handling of open events. Moving
the work off the main thread does not shorten the time to the first window. It keeps the app responsive while the user
waits.

ADR-08 allows only local work whose duration uniterm bounds on the main thread. These decodes have no bound.

The save side was fixed separately. Saving now encodes and writes off the main thread. Bug
`20261122-browser-describe-reencodes-tabs-on-main-thread` records a related cost that the fix left in place.

## Design Decisions (Settled)

### Where the typed decode runs

Original question: how far the decode moves off the main thread. The candidates were the file decode only; the file
decode plus a nonisolated per-applet step through the `JSONValue` tree; that step decoding straight from the payload's
bytes; the typed decode on the main thread straight from bytes; and a cap on tabs per pane.

Decision: the launch reads and decodes the file off the main thread. Each applet type also gains a nonisolated step
that turns its description into a typed, `Sendable` restore value off the main thread, through its existing decode of
the `JSONValue` tree. The main thread then only builds the applet from that value. The launcher and the debug fixtures
follow the same contract.

Rationale: it leaves no decode on the main thread, so it meets ADR-08 for the decode, and it keeps one decode path.
The straight-from-bytes variant also leaves no decode on the main thread, but it adds a second path. Most applets
already decode in a pure static function, such as `TerminalDescription.decode`, so the step reuses it. Decoding from
bytes saves only off-main time, since the codec still builds the tree. Its second path is one that undo reopen would
not share. The other candidates leave a decode that grows with the tab count on the main thread. The cap does not bound
the file.

- The off-main step and the main-thread build are registered as one pair per applet type, so a type cannot have one
  without the other. The restorer closure captures main-actor services, so the off-main step cannot live in it.
- A description whose off-main step or main-thread build throws becomes a placeholder that keeps its exact bytes, per
  ADR-06.
- The terminal's off-main step does no filesystem check. UTERM-050 moves the directory check into the session start.
- Undo reopen of a closed pane runs both steps synchronously on the main thread. Its decode stays there and grows with
  the pane's tab count. Undo reopen is outside this proposal, which covers the launch. Bug
  `20261122-undo-reopen-decodes-pane-on-main-thread` tracks it.

### The restore's view building stays outside this proposal

Original question: whether this proposal also bounds the restore's view building. The candidates were no addition, and
an addition that bounds the main thread's whole share of the restore, view building included.

Decision: no addition. This proposal moves the read and the decodes. Bug
`20261122-browser-tab-bar-builds-a-view-per-tab-on-main-thread` owns the browser's per-tab view and model work.

Rationale: the addition as framed cannot meet its goal. Nothing caps panes or windows, so a bound per applet still adds
up to no bound. Meeting it needs a restore that yields to the run loop between panes, which changes when commands can
arrive mid-restore. It also reaches the shared tab bar, which the terminal and the questions applet use. Those are
separate concerns with their own design calls.

Leaves undone: a launch that restores a very large browser pane still holds the main thread while the pane builds. The
tab bar builds one view per tab, `refresh` walks every tab to compute titles and the published list, and the init makes
one tab object per record. At 50,000 tabs the whole restoring init took about 11 s in a debug build. The bug tracks it.

### No window shows while the read runs

Original question: what the app shows while the read runs. The candidates were no windows until the layout is ready, a
placeholder window that is a real controller, a placeholder window outside the window set, and no window with a sign of
progress on the Dock tile.

Decision: no window opens until the layout is ready. The completion opens the saved windows on the main thread as soon
as the restore value arrives. This is today's behavior, except that the menus now open and Quit works during the read.
Every other command waits; see "User commands during the read replay as today's launch runs them".

Rationale: it is the plain behavior and adds no state. A message posted with no window open already waits and goes to
the first window shown, so nothing is lost. A placeholder that is a real controller would take those messages and any
pane the user opened, then lose them when it is replaced. Every placeholder shows only during the short read and then
freezes through the restore's main-thread build like any window. A sign of progress serves no named failure. ADR-08
asks for a pending state only for results that depend on outside work, and a local read is not.

Leaves undone: no sign of progress shows during the read. The Dock stops bouncing when the launch hands off, so for
about a second at 50,000 tabs the app runs with no window. The restore's main-thread build that follows still freezes
the app. Bug `20261122-browser-tab-bar-builds-a-view-per-tab-on-main-thread` owns that.

### User commands during the read replay as today's launch runs them

Original question: what the launch does with user commands that arrive during the read. Routed opens already wait in
`LaunchOpenCoordinator`. An unbound `uniterm open` and an approved launch-sender open wait there too. The candidates
were queueing the other entry points with the routed opens and counting them as pending, letting them run and merging
the restore with what is open, refusing them until the launch finishes, and deferring them so each replays exactly as
the synchronous launch runs it today.

Decision: every command and entry point except Quit waits for the launch. That covers Cmd-N, a Dock click, File >
Open, Open With, Hide, Settings, Install Command Line Tool, Pending Requests, and Controllers & Permissions. They replay
in arrival order after the launch has made its own window decision and activated the app. Nothing about them counts as
pending, so the default window decision is today's. Each replay reads the active controller and anchor when it runs,
not when it arrived. A queued Dock click tells AppKit it was handled. The deferral sits where the commands are
registered, so a menu click and a key equivalent wait alike. Quit runs at once; see Risks. Pane-scope and window-scope
commands and the command palette need a key window, so none of them can run during the read. Amended 2026-11-22; see
Decision Log.

Rationale: today's synchronous launch holds every input in the event queue until the restore ends. Replaying after the
launch reproduces each result, with one rule. Counting a queued File > Open as pending either stalls every later routed
open behind the open panel, or ends the drain at once so the fallback window opens anyway. Letting a command run during
the read lets the restored windows take key from it as they show. Typing in Settings, or a Return meant for Pending
Requests, then goes to a restored terminal and can run a command in the wrong shell. A Hide would be undone by the
launch's activate, and a modal panel such as Install Command Line Tool's would host the restore. A Dock click would add
a shell to the saved layout at every impatient launch. Refusing drops input that today's launch honors, and gives no
feedback. Quit stays live because the read has no bound, and the user must be able to leave the app during it.

Leaves undone: every command but Quit does nothing visible until the launch finishes, as today.

### The launch moves nothing aside until it commits

Original question: what happens to the notice that an unusable layout was moved aside when the user quits during the
read. The candidates were logging the notice and accepting that the user is not told, carrying the notice to the next
launch in a note file, holding the quit until a window shows the notice, and moving nothing aside until the launch
commits.

Decision: the off-main read reports an unusable file, or a launch at the crash bound, without moving anything. Once the
main thread has seen that no quit is pending, it moves the file aside and posts the notice. On the quit path the file
stays where it is. The next launch finds the same state and reports it again. The marker write stays off the main
thread, before the applets' typed decodes, so a payload whose decode crashes still counts toward the bound.

Rationale: the notice comes from what is on disk, so nothing extra is stored. A note file adds a stored contract whose
note can outlive the pruned file it names. Logging leaves the user unaware: the next launch starts fresh with no
explanation, and the kept file can be pruned after five later moves. Holding the quit shows the notice for one frame,
which tells the user nothing. The move is one rename and a prune of at most five files, which ADR-08 allows on the main
thread.

## Design Decisions (Open)

### Whether undo reopen of a closed pane also leaves the main thread

This is a scope addition. "Where the typed decode runs" leaves undo reopen outside this proposal. Bug
`20261122-undo-reopen-decodes-pane-on-main-thread` tracks it. Bringing it in removes that statement.

`MainWindowController.reopenPane` calls `PaneRestoration.applet(for:restorer:)` synchronously. The restoring init
decodes the payload and the undo state, then builds the applet. A pane has no tab cap. The decode grows with the tab
count, and ADR-08 allows only bounded local work on the main thread.

The ledger already holds the payload's `JSONValue` tree, so reopen pays no tree build. It pays only the `decoded(as:)`
round trip: about 32 ms at 10,000 tabs and about 160 ms at 50,000 tabs in a debug build, per the Decision Log. The undo
state adds its own decode, which has not been timed. It holds each tab's history as base64 text, so it grows with
history size as well as tab count.

No candidate makes reopen bounded. The build that follows stays linear on the main thread: the tab objects, the tab bar,
and the refresh. Bug `20261122-browser-tab-bar-builds-a-view-per-tab-on-main-thread` and UTERM-053 own that. After
UTERM-053, the decode is the largest cost left in reopen. The close that comes first is also linear on the main thread.
Bug `20261122-browser-close-encodes-every-tab-history-on-main-thread` tracks it.

Candidates:

- No addition. Undo reopen stays synchronous, and the bug stays open until a later proposal takes it. Leaves undone: a
  main-thread decode of about 32 ms at 10,000 tabs and 160 ms at 50,000, plus the untimed undo decode. No ADR
  Deviations entry records it, so this candidate adds one.
- Prepare the typed restore value when the pane closes, and show a pending pane for an early reopen. The ledger entry
  holds the preparation's task, run off the main thread, beside the description. The description stays, because a
  build that throws becomes a placeholder that keeps it. A reopen after the task finishes builds at once. A reopen
  before it finishes inserts a pending pane, which keeps the description and returns it from `describe()`, then swaps
  in the built applet when the value arrives. An early reopen is reachable: a Cmd-Shift-T typed during the close's
  freeze arrives as the preparation starts. Costs: the ledger holds at most 20 entries per window, and each entry gains
  a typed value of about the size of the tree it already holds. The swap needs rules: focus moves only if the pending
  pane still has it, and a result for a closed pane, a closed window, or an evicted entry is discarded.
- Hand over the typed restore value at close, straight from the applet's live state. The browser already holds typed
  records. Nothing encodes or decodes, so nothing is pending. Costs: each applet type gains a third member beside the
  off-main step and the main-thread build. That member can drift from describe-then-decode with no error, so each type
  needs a test that the two agree. It gives up this proposal's reason for one decode path, that undo reopen shares it.
- Run the off-main step at every reopen, and show a pending pane until the value arrives. The pending pane is the same
  as in the second candidate, so a save writes its description and a close pushes it back onto the ledger. Costs: every
  reopen shows a pending frame, a one-tab terminal included.
- Run the off-main step at reopen time, and defer the window's commands the way the launch does. Costs: keystrokes are
  not commands, so typing during the decode reaches the focused pane. The reopened pane then takes focus partway
  through the input. That is the wrong-shell hazard the launch's deferral exists to prevent.
- Cap the tabs a pane may hold. Rejected, for the reason in UTERM-052 and UTERM-053's "No tab cap": a pane over the cap
  loses tabs or needs a deferred-tab state, and a cap refuses the user's own New Tab.

The pending-pane candidates must say why a pending pane fits here when "No window shows while the read runs" ruled out a
pending window. That decision read ADR-08 as asking for a pending state only for results that depend on outside work.
A local decode is not outside work.

## Risks

- **A decode that grows with the tab count stays on the main thread** — likelihood: low, impact: medium.
  An applet's off-main step could leave part of its decode in the main-thread build.
  Mitigation: M2 times the main thread's share of the read and the decodes at two tab counts, apart from view building.
  A release build of the package crashed the compiler during the review, so the review's numbers are from a debug
  build. Bug `20261122-optimized-build-crashes-compiler-in-status-queue` tracks the crash.
- **Quitting during the read** — likelihood: low, impact: medium.
  `beginLaunch` writes the launch marker after the file decode. A quit that ends the process between that write and the
  completion counts as a launch that never finished. `applicationWillTerminate` would also release the store on the main
  thread while `beginLaunch` may still run off it, and the store allows only `save` across threads.
  Mitigation: a quit that arrives during the read answers `terminateLater`. The completion sees the quit. It opens no
  window, moves nothing aside, replays no held command, and skips `launchFinished`, the activate, and the post-launch
  hooks. It puts the marker back to its count before this launch, releases the store, and lets the quit go on. A quit
  is not a crash, and it erases no count of real ones. The main thread never waits on the read. M2 checks it.
- **Quit waits out the read** — likelihood: low, impact: low.
  A quit or a logout during the read takes effect only when the read ends, which has no bound on a slow volume. Today
  the whole app is frozen for the same span, so it is no regression.
  Accepted: the main thread stays responsive, and the quit goes through as soon as the read returns.
- **The quit-confirmation fix touches the same handler** — likelihood: medium, impact: low.
  Bug `20261122-quit-skips-unsaved-work-when-nothing-runs` changes `applicationShouldTerminate`'s guard. The read's
  quit branch must sit ahead of it, since no window is open to ask about.
  Mitigation: M2's quit checks run against whichever handler is in place.
- **UTERM-050 changes the same terminal restore init** — likelihood: medium, impact: low.
  UTERM-050 is accepted and moves the terminal's directory check into the session start. Either may land first.
  Mitigation: the terminal's off-main step does no filesystem check, which M2 checks. That holds whichever lands first,
  as UTERM-050's own Impacts entry says.
- **The post-launch steps run before the layout is up** — likelihood: medium, impact: medium.
  `launchFinished`, the palette sync, `NSApp.activate`, the debug error post, and the questions hook follow `launch`
  in `applicationDidFinishLaunching`.
  Mitigation: M2 moves each one to the completion, and the `LayoutPersistence` tests move to the async API.

## Milestones

### M1: User commands wait for the launch

**Status:** NOT STARTED

The deferral lands first, so the async read never ships without it. While the launch is synchronous, nothing arrives
early, and the deferral is inert in the app.

- Every command and entry point but Quit that arrives before the launch finishes replays after it, in arrival order. The
  deferral lives in WindowKit, and a package test drives each entry point through it before `launchFinished`. The app
  delegate only forwards
- Held commands replay after the launch activates the app. A held Hide leaves the app hidden once the windows are up.
  So does a Hide from outside the app during the read, such as the Dock menu's
- A replay reads the active controller and anchor when it runs. A File > Open replayed after a restore shows its panel
  as a sheet on the active window, and the file lands beside the active pane
- A Finder open queued at launch and a Cmd-N held during it end with the file placed as today's launch places it
- A fresh launch with a Cmd-N held during it ends with the default window and the Cmd-N window. A restored launch with a
  Dock click held during it ends with only the saved windows
- A held Dock click tells AppKit it was handled
- A held command counts as no pending open. The default window decision is unchanged
- The launch paths that open no saved layout, a missing layout folder, a lock that cannot be taken, and a second
  instance, each replay held commands and routed opens
- Quit runs at once before the launch finishes

### M2: The launch reads and decodes off the main thread

**Status:** NOT STARTED

- `beginLaunch`'s read and file decode, and each applet's typed decode, run off the main thread. No `LayoutCodec.decode`
  or `decoded(as:)` runs on the main thread at launch, and no successfully prepared restore value holds a `JSONValue`.
  A description whose off-main step failed reaches the main thread as itself, for its placeholder. The main thread only
  builds applets from their restore values and opens the windows
- The launch marker is written before the applets' typed decodes run. A layout at the codec's deepest nesting decodes on
  the thread the launch uses
- Each applet type registers its off-main step and its main-thread build as one pair. The launcher and the debug
  fixtures follow the same contract. A type with only one of the two cannot be registered
- A description whose off-main step throws, and one whose main-thread build throws, each restore as a placeholder that
  keeps its exact bytes. A save then writes those bytes back unchanged
- The terminal's off-main step does no filesystem check
- Undo reopen of a closed terminal or browser pane restores it as before, with its closed-tab history
- `launchFinished`, the palette sync, `NSApp.activate`, the debug error post, and the questions hook run in the
  completion, after the windows open. The launch marker is cleared only after the launch finishes
- An unusable layout, and a launch at the crash bound, move the file aside only once the launch commits. A quit during
  such a read leaves the file in place, and the next launch reports it
- A move that fails at commit leaves saving off and the file untouched. At the crash bound, the marker drops to 1 only
  after the move succeeds
- A copy kept aside after windows fail to reopen is made off the main thread. It finishes before any save can replace
  `layout.json`, and before a quit releases the store
- A quit during the read answers `terminateLater`. With a Cmd-N held and a routed open queued, it ends with no window
  opened, no file moved, `layout.json` byte for byte unchanged, and the marker at its count before the launch. A second
  quit during the read neither cancels nor repeats the first. A package test holds the read open and quits
- The main thread's share of the read and the decodes, timed apart from view building, does not grow between a
  5,000-tab and a 50,000-tab browser layout. The timings are recorded in the As built block
- The menu bar responds while a held read runs. A UI test holds the read through a `UNITERM_TEST_HOLD_LAYOUT_READ`
  debug hook and opens the app menu. A second run quits during the held read: the process exits, and `layout.json` is
  byte for byte unchanged

## Decision Log

- 2026-11-22: Drafted from the bug report, after bug triage confirmed the bug by reading the code.
- 2026-11-22: Revised after design critique. The restore's typed decode was folded into the first question. It had
  been a separate question about the cost of building panes. The routed-open ordering question was replaced by the
  question about other entry points, because its candidates were all current behavior. The "default window plus saved
  layout" option was dropped from the display question. It grows the layout by one window per launch, and it opens a
  shell beside a routed pane.
- 2026-11-22: Review start: 0 milestones, 0 settled decisions, 3 risks, no `**Live after:**` lines or row gates, no
  out-of-scope statements; the user asked for an autonomous review of the three open questions. Baseline is the commit
  "Revise UTERM-051 after design critique".
- 2026-11-22: Correction of fact (autonomous): the layout file never writes or reads an applet's undo state. Motivation
  said the browser's restoring init decodes "on its payload and on its undo state". The cap option said "each tab's undo
  state carries WebKit history of any size". Both now say what the file holds.
- 2026-11-22: Measured the restore's split for one browser pane in a throwaway package test, debug build. Records had
  70-byte URLs and 50-character titles. At 10,000 tabs, 1.5 MB of payload: the payload's `JSONValue` tree 195 ms, the
  `decoded(as:)` round trip 32 ms, a typed decode straight from bytes 13 ms, the tab objects 7 ms, the titles 99 ms, the
  tab bar's first update 1,187 ms, a second update 64 ms, and the whole restoring init 1,809 ms. At 50,000 tabs, 7.9 MB:
  the tree 967 ms, the round trip 160 ms, the straight decode 68 ms, and the whole restoring init 10,981 ms. The init
  grows about linearly. A release build crashed the compiler, so no release numbers exist. Filed bug
  `20261122-browser-tab-bar-builds-a-view-per-tab-on-main-thread`. Correction of fact: the risk said the read-only
  option "leaves a decode of about the same size on the main thread", and Motivation said the round trip's "cost has not
  been measured". The round trip is about a sixth of the tree build. Question 1's candidates were restated as five
  distinct options, and the question about the restore's view building was added.
- 2026-11-22: The launch decodes each applet's typed payload off the main thread, through a nonisolated per-applet step
  that reuses the existing decode of the `JSONValue` tree. Converged in 1 pass (autonomous).
- 2026-11-22: The restore's view building stays outside this proposal, and the tab bar bug owns it. Converged in 1 pass
  (autonomous).
- 2026-11-22: No window shows while the read runs. Converged in 1 pass (autonomous).
- 2026-11-22: User commands during the read replay as today's launch runs them, with nothing counted as pending.
  Converged in 1 pass (autonomous). The recommendation moved from queueing them as pending once the critique showed
  the pending count fails for File > Open, and that deferral alone reproduces today's results. Correction of fact: the
  question said "Scripts are not affected. They need an existing controller". An unbound `uniterm open` needs none, and
  it already waits in the coordinator.
- 2026-11-22: Drafted two milestones (autonomous). The command deferral comes first, so the async read never ships
  without it. The quit-during-read risk is mitigated by answering `terminateLater` and clearing the marker in the
  completion (autonomous). The read-only risk was restated, since no settled option keeps a decode on the main thread.
- 2026-11-22: The whole-proposal review found that letting Settings, Hide, and the other app commands run during the
  read contradicts the deferral decision's own rationale. A restored window takes key from them as it shows. The
  decision now defers every command but Quit. It said before: "Every other command runs at once: Quit, Hide, Settings,
  Install Command Line Tool, Pending Requests, and Controllers & Permissions." Converged in 1 pass (autonomous).
- 2026-11-22: Growth check: the review's changes added four special cases that serve one requirement, that Quit works
  during the read. They are the Quit exemption from the deferral, the quit branch in the completion, moving a file aside
  only at commit, and restoring the marker's count on quit. Asked the user, who kept the requirement with those cases.
- 2026-11-22: The launch moves nothing aside until it commits, so a quit during the read loses no notice. Converged in 1
  pass (autonomous). The recommendation moved from logging and accepting the loss once the critique showed the kept file
  can be pruned before the user ever learns of it.
- 2026-11-22: The quit mitigation now puts the marker back to its count before the launch instead of clearing it, so a
  quit erases no count of real crashes (autonomous). The risk said a quit during the read counts toward the bound. Only
  a quit after the marker write does, and the marker is written after the file decode. Routed the review's
  implementation findings to M1 and M2 checks. Replaced the check "the first window opens no later than the synchronous
  launch's first window", which nothing could verify once the synchronous path is gone. Added the risks that Quit waits
  out the read and that the quit-confirmation bug fix touches the same handler.
- 2026-11-22: The re-check pass converged. Routed four checks: a failed move at commit, the order of the kept-aside copy
  against the first save, a quit during a held read in the real app, and a Hide from outside the app.
- 2026-11-22: The ADR check found no conflict in settled text. Its possible ADR-02 clash, a window opened during the
  read reusing node IDs, does not hold: each window's tree has its own ID allocator, and a new window starts its own, as
  Cmd-N does today (autonomous).
- 2026-11-22: Risk review added the risk that UTERM-050 changes the same terminal restore init (autonomous). No risk is
  high in both likelihood and impact, and no decision is a one-way door.
- 2026-11-22: ADR candidate (cuts across the system): restoring a pane decodes its saved description off the main
  thread, and the main thread only builds from typed values. Declined: applies ADR-08 "The main thread never waits on
  work whose duration uniterm does not bound."
- 2026-11-22: Review gate: nothing was asked. No decision was contested, and no addition was kept.
- 2026-11-22: Accepted.
- 2026-11-22: Wording corrections after acceptance, with no change in behavior. "No window shows while the read runs"
  said "with the menu bar and the Dock now responsive during the read". A Dock click now waits with the other commands.
  "Where the typed decode runs" said it is "the only candidate that leaves no decode on the main thread". The
  straight-from-bytes variant leaves none too. M2's check said "no restore value holds a `JSONValue`". A failed
  description reaches its placeholder as itself. The gate entry said "kept all", though no gate question was asked.
  Linked bugs `20261122-undo-reopen-decodes-pane-on-main-thread` and
  `20261122-optimized-build-crashes-compiler-in-status-queue`.
- 2026-11-22: Opened the question of whether undo reopen also leaves the main thread, at the user's request after bug
  triage found no proposal that owns it. It is a scope addition. "Where the typed decode runs" still says undo reopen is
  outside this proposal, and stays as written until the user settles the question. Candidates only so far.
- 2026-11-22: Revised the undo reopen question after design critique. Struck the claim that UTERM-052 changes when the
  payload is ready; it keeps `describe()` synchronous. The cap's stated reason was the launch's, "a cap does not bound
  the file", and reopen reads no file. Preparing at close now says what an early reopen does. Added the typed handoff at
  close. Stated that reopen stays linear on the main thread under every candidate, and what no addition leaves undone.

## References

- ADR-08: UI responsiveness
- Bug `20261122-layout-launch-read-runs-on-main-thread`
- Bug `20261122-layout-save-runs-on-main-thread`, fixed
- Bug `20261122-browser-describe-reencodes-tabs-on-main-thread`
- Bug `20261122-browser-tab-bar-builds-a-view-per-tab-on-main-thread`
- Bug `20261122-undo-reopen-decodes-pane-on-main-thread`
- Bug `20261122-optimized-build-crashes-compiler-in-status-queue`
