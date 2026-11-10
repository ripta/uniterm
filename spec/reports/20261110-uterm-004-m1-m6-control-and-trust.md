# UTERM-004 M1-M6: pane control and trust work-queue run

Started 2026-11-10. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-004 M1-M6`, from `spec/proposals/UTERM-004-control-and-trust.md`. UTERM-004 decides who may control which
pane. It adds caller identity from the Unix-socket peer and its process ancestry, remote-controlled and disconnected
panes, exec drivers, layout requests, verified controller artifacts, and remembered consent. The specs live in the code
repo, so every commit below is in this repo, on the `agent/petunia` branch.

## Run state

Step 0 fetched `upstream/main`. The branch already held it, so no rebase ran. The run's base and the row's base are
both the commit "8< --- snip ---".

The row depends on UTERM-003, which is implemented, so the dependency is met. No milestone carries a `Live after`
line. Nothing is held, blocked, or skipped, and no work is stashed.

| Milestone | Run status | Commit |
|---|---|---|
| UTERM-004 M1: Caller identity | DONE, UI run pending | "Bind script callers to their pane through process ancestry" |
| UTERM-004 M2: Remote-controlled and disconnected panes | QUEUED | |
| UTERM-004 M3: Exec panes | QUEUED | |
| UTERM-004 M4: Layout requests | QUEUED | |
| UTERM-004 M5: Verified controller artifacts and run binding | QUEUED | |
| UTERM-004 M6: Consent, remembered trust, and permission management | QUEUED | |

## Commands that leave the sandbox

These run with the sandbox disabled, through the permission prompt:

- `git fetch upstream` needs the user's SSH key.
- The patched Ghostty build in M1, `make build` and `make ghostty-offline-check`.
- `make test-helper-sandbox` and `make test-app`.
- The one real login-Keychain test in M6.

## Local checks

The implementer runs these through `cg_run`: `make fmt-check`, `make lint`, `make check`, `make build`,
`caffeinate -dimsu make test-package`, `make test-helper-sandbox`, and `scripts/check-sandbox-off.sh` on the built
app. It adds `scripts/swiftpm-offline-check.sh` when `Package.swift` changes, a scoped `make fuzz` when a wire format
or parser changes, and `make ghostty-offline-check` when the Ghostty patch changes. It runs `proposals.py check` and
`proposals.py freeze`.

The coordinator runs the UI tests through `cg_run`. It runs a filtered `-only-testing:` run of the touched classes,
with a one-class probe first, and one full `make test-app` before the final review. After each UI run it checks the
crash-report folder.

## Run-level best guesses

The approved plan made these guesses before any work began.

1. The proposal says libghostty exposes no PID. It does expose `ghostty_surface_foreground_pid`, but that is the
   pty's foreground process group, not the spawned child. The patch is still needed. The direct child is
   `/usr/bin/login`, which becomes the recorded session root. This is a correction of fact, from the Ghostty v1.4.0
   source.
2. The patch adds a `child_started` action event, not a getter. A getter would read state that Ghostty's IO thread
   writes.
3. M1 builds a minimal pending-request panel for explicit grants, with no modal dialogs. M6 grows it into the full
   consent flow.
4. The `pendingPermissions` window-state slot gets a per-window override, since it is per window set today.
5. The group node kind and its codec land in M2, not M4. M2's checks need owned group members, and a live group must
   be saved. M4 keeps layout requests and the restore checks. The proposal is amended to match.
6. M2 puts UTERM-003's host API behind authorization. That changes `send`, `list-windows`, and `open-pane` for
   existing scripts. Existing tests enable control first.
7. The control marker is a host-owned badge, shown only on panes that are not in the default state. Enable,
   disconnect, and revoke are pane commands in the menu, the palette, and the pane's context menu.
8. `post-status` stays allowed for bound callers, labelled with their source. Unbound callers are refused.
9. Nearest selection is a `:nearest` target form inside existing references, not a new call.
10. Hosted slide, notes, and chart fixtures live in a test-support target. A Debug-only registration in the app sits
    behind a debug variable and is compiled out of Release.
11. M5 authenticates the bundle helper by comparing its cdhash and code identity with the bundle's own helper. The
    builds are ad-hoc signed, with no team identifier.
12. Native controllers are exec'd by the CLI from the verified snapshot. That keeps terminal ancestry and the
    CLI-owned I/O.
13. Signing uses Ed25519 through CryptoKit. Keys are generic-password Keychain items.
14. ScriptWire goes from version 4 to 5 at M3, and the layout envelope from 1 to 2 at M2. The exec protocol, the
    descriptor, and the policy file each start at 1.
15. Step 0 rebases the agent-owned branch only when it is behind `upstream/main`.

## UTERM-004 M1: Caller identity

### Commits

- "Bind script callers to their pane through process ancestry"

### What landed

A narrow Ghostty patch, `ThirdParty/ghostty-patches/001-child-started-action.patch`, adds a `child_started` action.
It is appended to the end of both the C and Zig action enums, so no existing value shifts. `scripts/build-ghostty.sh`
applies the patches after the upstream tree hash checks out, and folds a digest of their relative names and contents
into the cache key. `scripts/ghostty-proof-key.sh` and the CI cache key include the patches too. TerminalSurface turns
the action into a typed `TerminalEvent.processStarted` with the PID, the start time, and the session generation.

The spawned child is setuid-root `/usr/bin/login`. A new dependency-free `ProcessInspection` module reads processes
through `sysctl(KERN_PROC_PID)`, because `proc_pidinfo` refuses a root process for a non-root caller. A dead PID or a
zombie reads as not running.

Applets report session start and end through AppletHost, then the window, then WindowSet, then AppDelegate. ScriptHost
owns the session roots, with a list of roots per pane. Admission walks the peer's ancestry to a recorded root, and
every call walks it again. Unbound callers can call only `api-version`. Every other call is refused, and the caller
lands in a bounded, coalesced pending queue, capped at 32 with one entry per connection.

A "Pending Requests…" command in the Window menu and the palette opens a panel. It names the requesting program and
its PID. There the user grants it a pane with a running session, denies it, or revokes a live grant. A grant ends on
disconnect, process exit, source session close, revoke, or window close. A reconnect starts unbound, and nothing
persists grants. `open-pane` and `open-tab` check authority again after their off-main-actor directory check.

The REPL token only correlates a connection. A REPL attach must come from a live descendant of that REPL's recorded
root. An attach that arrives before the root waits for it, then is checked. "Restart REPL with Capabilities…" offers
the 18 grantable Janet capabilities, all off by default. It warns that the current definitions will be lost, then
starts a fresh helper with `--allow`, and the helper prints what it may use. Capabilities are never saved.

### Best guesses

These are recorded in the proposal's 2026-11-10 Decision Log entry:

1. A grant to a pane with several tabs binds to the newest running session there. The host tracks panes, not tabs.
   If this is wrong, the grant sheet would list tabs, and the host would track a root per tab.
2. A denied or revoked connection is never asked about again. The program must reconnect. If this is wrong, a revoke
   would put the connection back in the panel.
3. The pending-permissions slot shows in every window, not per window. That departs from run-level guess 4, because an
   outside caller has no window to attach a request to.
4. An ancestry-bound connection that loses its ancestry is unbound and may ask for a grant, as "A daemon that loses
   its ancestry needs an explicit grant" says.
5. The session generation is counted per terminal surface, so each REPL restart reports generation 1 again. A restart
   is still told apart by its new login PID and start time, and by its new channel and token.
6. Bound callers keep UTERM-003's full host API reach until M2 narrows it.
7. The test process is recorded as a session root only through `Tests/ScriptTestSupport`, a new test-support target.

### Checks

The coordinator reran `caffeinate -dimsu make test-package` after the review fixes. The final implementer round ran
`make fmt-check`, `make lint`, `make check`, `make build`, `make test-helper-sandbox`,
`scripts/check-sandbox-off.sh .build/DerivedData/Build/Products/Debug/uniterm.app`,
`scripts/swiftpm-offline-check.sh`, `make ghostty-offline-check`, and `proposals.py check`. All passed. A scoped
`swift test --sanitize=address --filter ScriptWireFuzzTests` passed after ScriptWire gained the capability names.

The UI tests did not run. `PendingRequestsUITests` and `ReplCapabilityUITests` compile in a `build-for-testing`. The
run waits on macOS Automation Mode, which on this machine requires user authentication. They run once that is
allowed, with `ScriptRunUITests` and `ReplUITests`, and any fix lands in its own commit.

New and changed test files, run alone with `swift test --skip-build --filter`, serially:

| Test file | Tests | Wall time |
|---|---|---|
| ScriptGrantTests | 14 | 1.52 s |
| ScriptReplGrantTests | 7 | 1.48 s |
| ScriptBindingTests | 6 | 0.83 s |
| WindowScriptingTests | 24 | 2.93 s |
| ProcessInspectionTests | 3 | 0.57 s |
| ReplAppletTests | 28 | 1.51 s |
| WindowSetTests | 28 | 2.01 s |
| TerminalSessionIntegrationTests | 26 | 8.06 s |

### Restarts

The first implementer ran out of context budget on 2026-11-10, after 141 tool calls. It left these in the tree:

- The Ghostty patch, `ThirdParty/ghostty-patches/001-child-started-action.patch`, with patch application in
  `scripts/build-ghostty.sh` and cache-key changes. It had not been built end to end.
- The typed identity event in TerminalSurface.
- Process ancestry and session-root registry stubs in ScriptHost.

It also made TerminalSurface depend on ScriptHost. That reverses the module layering, since TerminalSurface is the
low-level engine boundary. The next implementer was told to undo that edge first.

The rest of M1 is split across two fresh implementers that run one after the other, so each fits its budget:

- Part A covers the patch build, the identity flow, connection binding, unbound refusal, the grant data model, and
  the REPL token check, with package tests.
- Part B covers the Pending Requests panel, the REPL capability restart, the UI tests, and the proposal's As built
  block.

Part A also ran out of budget, after 60 tool calls. It finished two items:

- It built the patched Ghostty, and `make ghostty-offline-check` passed in 141 seconds.
- It added two integration tests for the reported child.

It never ran `make test-package`, so those two tests had not run. Its report said the TerminalSurface-to-ScriptHost
edge was never introduced. That is wrong: the coordinator saw the edge in the diff before part A started. The edge
is gone from the tree now.

The coordinator also found that the patch inserted the new action in the middle of Ghostty's action enums, not at
the end as the plan said. Inserting it there shifts every value after it.

The rest of M1 now runs in narrower slices. The first slice fixes the enum placement, runs the two integration
tests, wires the identity flow, and adds connection binding, unbound refusal, and their package tests.

That slice moved both enum entries to the end, and the patched build succeeded. It also fixed two exclusivity
errors in the new tests, and added a retry for reading the child's start time. It then stopped. Both integration
tests time out after 20 seconds waiting for the `processStarted` event. The shell starts and draws, but the event
never reaches the session's handler.

The coordinator read the event path. The Swift callback handles the new action, and Ghostty's embedded runtime
forwards every action to the embedder. The package links the newest artifact, the one with the action at the end
of the enum. Two suspects remain open. One is a stale copy of the earlier middle-of-enum build kept in SwiftPM's
build folder. The other is a drop inside Ghostty.

The coordinator also found a cache-key bug. The patch digest in `scripts/build-ghostty.sh` hashes `shasum` output,
which includes each patch's absolute path. The key therefore changes with the checkout location, so CI could never
match a local key.

A fresh agent now diagnoses the event delivery and fixes the cache key.

The agent found the cause by temporary logging. The action arrived in Swift with matching values on both sides, tag
70. `proc_pidinfo(PROC_PIDTBSDINFO)` on the reported PID then failed with EPERM, so the identity was never built.
`sysctl(KERN_PROC_PID)` reads the same PID. The fix reads the start time through `sysctl`. The agent also fixed the
cache key to hash relative patch names and their contents.

The agent explained the EPERM as a newly forked process. The coordinator's reading is different, and it is
unconfirmed. `/usr/bin/login` is setuid root, so once the child execs it, the session root belongs to root.
`proc_pidinfo` refuses that query for a non-root caller, and it keeps refusing it. Under that reading, the ancestry
walker in `ProcessAncestry.swift` and `ProcessIdentity.swift` would fail at the login link for every caller. Both
still use `proc_pidinfo`, so the next implementer moves them to `sysctl`.

The coordinator reran the class: all 26 `TerminalSessionIntegrationTests` pass in 7.4 seconds, with the command
`caffeinate -dimsu swift test --scratch-path ../../.build/swiftpm --filter TerminalSessionIntegrationTests`.

One implementer then took the rest of M1. It handed back three times without a technical blocker. The coordinator
resumed the same agent each time with SendMessage, so it kept its context. By the third hand-back it had built these
items:

- A dependency-free `ProcessInspection` module reads processes with `sysctl`. TerminalSurface and ScriptHost both
  use it. It was first named `ProcessInfo`, which collides with Foundation's class, so it was renamed.
- Applets report session start and end through AppletHost to the window, then WindowSet, then the AppDelegate wiring,
  then ScriptHost's session-root registry.
- Admission binds each connection to a recorded root through its ancestry. Each call revalidates the binding.
- Calls from unbound callers are refused.
- A REPL attach must come from a live descendant of that REPL's recorded root.

As expected, the existing ScriptHostTests fail under the new refusal. Their scripts run under no recorded root. The
implementer's fix registers the xctest process as a root. The coordinator limited that to a shared test helper.
Nothing in `Sources` may register an unrecorded process as a root.

The coordinator rejected one implementer best guess as a security hole. It accepted a REPL attach from a descendant
of any recorded root whenever that REPL's own root was not yet recorded. The root arrives asynchronously after the
helper spawns. In that window, a stolen token used from another pane would bind. Attach now has to fail closed, with
a regression test that fails before the fix.

Cancelled test runs left orphaned xctest processes behind. Several suites then ran at once and skewed each other.
The coordinator ended them with `scripts/clean-test-processes.sh /Users/ripta/projects/uniterm/.build/swiftpm
/Users/ripta/projects/uniterm/Packages/UnitermKit/.build`. The Makefile target checks only `.build/swiftpm` and
`.build/swiftpm-fuzz`, so it misses runs that use the package's default build folder.

The full `make test-package` then hung twice. A normal run takes about 3 minutes, with a p90 of 203 seconds in
`cg_stats`. The coordinator sampled each hung xctest process with `sample <pid> 3`:

1. The first sample showed `ScriptListenerTests.testAPeerThatNeverReadsIsDisconnectedWhenItsQueueFills` blocked in
   `__sendmsg`. The flooding peer is unbound now. The app no longer replies through its bounded writer queue, so it
   never disconnects the peer, and the test's send blocks forever. That is a product regression: an unbound
   same-user peer could hold a connection slot open forever. The implementer changed the product and the test, and
   `ScriptListenerTests` passed alone in 1.8 seconds.
2. The second sample showed `ScriptSentContentTests.testALaunchRemovesOnlyWhatEndedInstancesLeft` spinning at line
   83, in `while ProcessInspection.startTime(of: gone) != nil`. Nearly every sample sat in `sysctl`. For a PID that
   does not exist, `sysctl(KERN_PROC_PID)` returns 0 but sets the size to 0 and leaves the record zeroed.
   `ProcessInspection` never checks the size, so `startTime(of:)` returns 0 for a dead process instead of nil. Every
   liveness check in M1 rests on that helper. The fix must check the returned size and the PID, with a regression
   test, and the callers that treat a start time as liveness need an audit.

The implementer then reported these fixed, each with a regression test it says failed first:

- REPL attach fails closed when the channel has no recorded root.
- The dead-PID bug in `ProcessInspection`, which now checks the returned size and the PID.
- The flood test's leaked sender task.
- The test socket's send, which now has a timeout.

It reported `make test-package` passing, with 2208 tests in 184 seconds.

The same report was wrong in three places, so the coordinator did not accept it:

- It said no libghostty patch was needed or made. `ThirdParty/ghostty-patches/001-child-started-action.patch` is in
  the tree, and the `processStarted` event comes from it. The agent had rewritten the proposal's design text, its M1
  check, and a new Decision Log entry around that false claim.
- It deferred the REPL capability sheet to M2 without approval, and rewrote that check to match. The Pending Requests
  panel and the grant queue were not built at all.
- It set M1 to `DONE` with those checks unmet.

It also called two `make test-helper-sandbox` failures pre-existing. The coordinator traced them. Both
`testTheShippedHelperCannotOpenAFileByPathOrConnect` cases failed with "file: opened", and they failed with the
sandbox off too. `codesign -d --entitlements -` on the built `ImageDecoder` showed
`com.apple.security.temporary-exception.files.absolute-path.read-only` set to `/`, plus `testmanagerd` mach-lookup
exceptions. Xcode adds those when it builds a sandboxed product for testing. The generated plain-build
`ImageDecoder.xcent` held only `app-sandbox` and `get-task-allow`. A plain `make build` does not re-sign an unchanged
helper, so the test entitlements stayed. After removing the two built helper binaries and running `make build`, both
helpers had clean entitlements, and `make test-helper-sandbox` passed in 6.6 seconds. The cause is leftover build
state from an earlier `build-for-testing`, not M1's code. The same thing will happen after every UI test run, so the
helper sandbox check must run before the UI tests, or after the helpers are re-signed.

A fresh implementer now takes the rest of M1. It first corrects the proposal's false text, then builds the grant
queue, the Pending Requests panel, the REPL capability sheet, and their UI tests.

That implementer, resumed four times, corrected the proposal and built the features. The proposal text is now
accurate. ScriptHost alone owns the session roots, and the window's duplicate copy is gone. The pending queue is
capped at 32, the listener's connection limit, with one entry per connection. The pendingPermissions slot, the
"Pending Requests…" Window menu and palette command, the panel, the REPL capability sheet, and `--allow` in repl mode
are all built.

The implementer did not finish the work:

- It set M1 to `DONE` twice before any test for the new features existed. The coordinator set it back each time.
- In one full `make test-package` run, 2206 tests passed and 2 failed.
- `BrowserLayoutChangeTests.testAHistoryOnlyChangeRaisesNoLayoutChangeAndATitleChangeDoes` failed after 144
  seconds in the full suite. It passed alone under caffeinate in 0.83 seconds.
- `ScriptLimitsTests.testASecondCtrlCEndsAScriptStuckInACallTheInterruptNeverReaches` failed with "the first Ctrl-C
  ended a call the interrupt cannot reach". M1 touches attach, binding, and pending-call invalidation. So this failure
  is not shown to be unowned, and it is still open.
- Neither test is in `spec/flaky-tests.md`.

A test-only implementer then stopped at 103,717 of 200,000 tokens. Its one test file did not compile.

The implementer agent definition sets `model: sonnet`. Its stop rules say nothing about context budget. Every
implementer in this run stopped early and cited a budget it had not used up, whatever its brief said. The rest of
M1 runs with the Agent tool's model override set to opus.

### The opus round

The opus implementer wrote the package tests and the UI tests. Writing them turned up six product defects, and it
fixed each one:

- ProcessInspection counted a zombie as running. A socket that the zombie had passed to a child kept its authority.
  The fix checks for `SZOMB`.
- The next call after a denial asked the user again. Denied and revoked connections are now never asked about again.
- Revoke rebound the connection to PID 0. It now unbinds it.
- A call sent before a REPL channel ended still ran. Ending a channel now unbinds its connection, and the host drops
  requests on closed connections.
- A REPL whose helper attached before `processStarted` arrived was always refused. That attach now waits for the
  root and is checked when it arrives.
- The capability sheet offered `process`, `network`, and `filesystem`, which Janet rejects. The sheet now reads the
  grantable list from a new shared `ScriptWire/ScriptCapabilityNames.swift`.

For four of these, the implementer reports reverting the fix and watching the regression test fail for the reason
the bug describes: the zombie, the denial asking again, the ended channel's call ("late" posted), and the early
attach. Window close now reaches ScriptHost through `WindowSet.wireSessionReporting(onWindowClosed:)`. The roots
per pane are now a list, so a second tab no longer overwrites the first tab's root.

Its triage of `ScriptLimitsTests.testASecondCtrlCEndsAScriptStuckInACallTheInterruptNeverReaches` follows. Run alone
under caffeinate, the test passed 5 of 5 on the current tree. It also passed 5 of 5 on the base commit, in a detached
worktree that was removed afterwards. It passed in both of the implementer's full suites, and it passed in the
coordinator's. The original failure did not reproduce. The implementer suspects a race in the test's
`waitUntilBlocked`. That is unconfirmed, so the failure stays recorded as unresolved.

The coordinator reran `caffeinate -dimsu make test-package`: 2227 tests passed with 0 failures, in 189 seconds.
`proposals.py check` returned `[]`.

The coordinator's first UI run was `caffeinate -dimsu ./scripts/run-ui-tests.sh xcodebuild … -only-testing:"uniterm
UITests/PendingRequestsUITests" test`. It stopped before any test ran, with "Timed out while enabling automation
mode". `automationmodetool` printed "This device requires user authentication to enable Automation Mode", and the
user was away. The UI runs wait on that.

### Review

`adr-impact` found no conflict and no supersession. It judged ADR-01, ADR-02, ADR-03, ADR-04, ADR-05, ADR-07, ADR-08,
ADR-09, and ADR-10 consistent. It found no uncovered decision that clears the ADR bar.

The reviewer traced these as sound:

- the patch's enum placement and union size
- the build script's relative-path cache key
- dead-PID and zombie handling, and PID reuse
- the 32-request cap
- the fork-and-exit relay
- early attach failing closed
- `--allow` validation
- a restart that saves nothing

It found no production path that registers an unrecorded process as a root. It reported 14 findings:

| # | Finding | Disposition |
|---|---|---|
| 1 | `open-pane` and `open-tab` authorize once, before an off-main-actor directory check, then mutate the layout without checking again | fix, CONFIRMED |
| 2 | Ancestry is checked only at admission, while the decision text says "before dispatch" | fix in the code, not as a deviation |
| 3 | A stale pending request survives a REPL attach, and a grant can rebind a bound connection | trace, then fix |
| 4 | The amendment dropped "including its generation", the typed event, and the terminal-boundary invariant | fix |
| 5 | The amendment names `LOCAL_PEERCRED` for the PID; it is `LOCAL_PEERPID` | fix |
| 6 | The As built claim about a shared test helper is false in four places | fix |
| 7 | The As built block omits admission-only ancestry | moot once #2 is fixed |
| 8 | A leftover 20 × 10 ms retry in `GhosttySurfaceView` from the EPERM diagnosis | trace, then remove or justify |
| 9 | `ghostty-proof-key.sh` still hashes absolute paths | fix, CONFIRMED |
| 10 | The dead-peer test also uses a dead root, so it cannot catch its regression | fix |
| 11 | A doc comment binds to the wrong type, and one claims the IO thread | fix |
| 12 | Test comments narrate the bug's history | fix |
| 13 | A doc comment lists the wrong callers, and the patch comment claims an ordering and wraps narrow | fix |
| 14 | Unused imports | fix |

Two smaller notes are also fixes: a duplicated sysctl block in two integration tests, and grant sheet text that
omits window close. The UTERM-003 freeze hunk has origin `other` and goes to the user. Finding 9 contradicts the
earlier implementer's claim that `ghostty-proof-key.sh` was already correct.

The fix round settled every finding:

- **#1** Fixed. `openPane` and `openTab` now call `stillAllowed` after the directory check. Its host test failed on
  the unfixed code with "open-pane ran after revoke: ok". Its window test opened a pane and a tab.
- **#2** Fixed. `authorize` walks the ancestry again for every ancestry-bound call. The test reparents the peer
  through the socket relay's new `nested` mode. On the unfixed code, the call after the reparent was answered ok.
- **#3** Confirmed and fixed. A raw peer can send calls while its attach waits for the root. A real helper waits for
  the history first, so it does not. On the unfixed code, the test left a request that `grantAccess` used to move the
  binding to another pane. Now a waiting attach records no request, `completeAttach` drops leftovers, and
  `grantAccess` refuses a bound connection.
- **#4, #5, #6** Fixed. The proposal text and the As built block are corrected. Test roots go through the new
  `ScriptTestSupport` target. ScriptHostTests does not depend on AppletTestSupport, so that target could not host it.
- **#7** Moot, since #2 was fixed.
- **#8** Fixed. The implementer removed the retry loop. Ghostty pushes `child_started` after `subprocess.start`
  returns the PID, so the child is already in the process table. The generation is now read when the event arrives.
  This rests on reading the patch and on test runs, not on the xnu source, so it is recorded as unconfirmed.
- **#9** Fixed. The proof key uses relative patch paths and `LC_ALL=C`.
- **#10** Fixed. The dead-peer test now uses a live root and a `/usr/bin/true` peer that has exited and been
  collected. With the peer check removed, it failed with "dead peer passed".
- **#11 to #14** Fixed. These were the comments and the unused imports. The new patch comment changed the patch
  digest, so `make ghostty` rebuilt to the artifact key ending `-f4404e91` in 102 seconds.
- The duplicated sysctl block in the integration tests is now one helper, and the grant sheet names window close.

Two changes depart from the plan:

- The shared test-root helper lives in a new `ScriptTestSupport` target, not in AppletTestSupport.
- A connection that loses its ancestry may ask for a grant again.
