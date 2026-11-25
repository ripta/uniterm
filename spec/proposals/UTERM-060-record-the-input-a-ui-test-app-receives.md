# UTERM-060: Record the Input a UI Test's App Receives

**Status:** draft
**Created:** 2026-11-25
**Updated:** 2026-11-25

## Impacts

- UTERM-045 — "Which call sites move" left keys out. "Whether clicks need settling" waits on a click flake with
  evidence that puts the click off its target. The receipt log is evidence for the first. It serves the second only if
  a record holds the click's location and the view it hit, which "What each record holds" leaves open. Neither
  decision changes here.

## Summary

A debug build of uniterm records each key and mouse event it receives to a file that a UI test names. When a UI test
fails, the base class attaches that log to the failure. The failure then says whether the test's synthesized event
reached the app, and what the app's state was when it did. The log only diagnoses. It never resends an event, waits
on one, or changes a timeout.

## Motivation

Four open entries in `spec/flaky-tests.md` share one pattern. A single synthesized event takes 5 or 20 s to send, and
its effect never comes:

- `ShortcutOwnershipUITests.testARemapOntoAnAppletKeyWinsAndWarnsOnce`: Escape took 5.09 s to synthesize, and the
  palette never closed. The palette check answered every 0.57 s for the next 11 s, so the app was not hung.
- `CommandPaletteUITests.testAProgramTitleShowsNeutralizedAsATab`: Cmd-K took 20 s, and the palette never showed.
- `StatusBarUITests.testClickingTheDismissControlClearsAnError`: a click took until 8.20 s, and the message stayed.
- `WindowsUITests.testCommandNOpensASecondWindowWithItsOwnShell`: Cmd-N took 20 s, and no second window opened.

Each test passed alone right after. The shortcut test passed 50 of 50 alone locally. In the shortcut case, Escape
closes the palette only through its field's `cancelOperation`, and `showCommandPalette` gives that field the keyboard
before Cmd-T returns (`MainWindowController+Palette.swift:41`). That leaves a lost key window, as the
`DockedPaletteUITests` entry suspects, or an event that never arrived.

The causes need different fixes:

- XCTest gave up on the event, and it never reached the window server's queue for any app.
- The event was delivered to another app, because uniterm was not active at that instant.
- The event reached uniterm, which then lost it or mishandled it.

Nothing records which one happened. The existing `focusReport` (`UITests/UnitermUITestCase.swift:324`) reads the
frontmost app and the focused element when the report is built, seconds after the event. Its 17 call sites do not
include the shortcut test's failing wait. So every sighting ends "not confirmed", and no fix can be chosen. The
flaky-test rule forbids retries and longer timeouts, so the test side cannot recover a dropped event either way. The
first step is to tell the causes apart.

UTERM-045 scoped keys and these stalls out. Its option that would settle keys was rejected because a key settle has no
element to wait on. A receipt log needs none: it records what arrived.

The open panel's test hook is the precedent. A debug build reads `UNITERM_OPEN_PANEL_ANSWER` and talks to the test
through files (`App/OpenPanelTestHook.swift`).

## Design Decisions (Settled)

### A debug-only hook

Decision: the recording lives in a `#if DEBUG` hook in the app target, keyed on an environment variable that the UI
test base class sets, as `OpenPanelTestHook` is. A release build compiles none of it. With the variable unset, a debug
build records nothing.

Rationale: the event's arrival is only visible inside the app. A test-side check sees only what XCTest reports, which
is the stall itself.

### Evidence, not a fix

Decision: the log changes no wait, sends no event, and retries nothing. No test waits on the log. It is read only
after a failure.

Rationale: the flaky-test rule forbids retries, longer timeouts, and weaker assertions. UTERM-045 settled that a
settle never waits on the outcome of the event it comes before. A log read after the failure does neither.

### Keys and mouse

Decision: the log records key-downs, key-ups, modifier flag changes, mouse presses and releases, and scroll wheels.

Rationale: the `StatusBarUITests` sighting is a stalled click. A key-only log would leave it unexplained.

### Every failure gets the log

Decision: the UI test base class attaches the log to every failing test, with no change at call sites. A test that
passes attaches nothing.

Rationale: the shortcut test's failing wait does not call `focusReport`. A log tied to chosen call sites would have
missed that sighting. A future flake should carry the evidence without anyone predicting where it will fail.

## Design Decisions (Open)

### Whether the system's own logs already answer

The runner's `testmanagerd` may log a synthesis that failed or timed out to the unified log. UI runs set
`-collect-test-diagnostics never` (`Makefile:48`), which keeps such a log archive out of the `.xcresult`. Nobody has
read that log after a stall. Candidates:

- **No change needed.** Read `log show` for `testmanagerd` around the next stall, by hand. Picking this drops "A
  debug-only hook" and "Every failure gets the log". Leaves undone: the log, if it says anything, speaks for the
  runner. Whether it also records which app was frontmost is not known, and it cannot say what held uniterm's keyboard.
- **Turn diagnostics back on for UI runs.** The `.xcresult` then carries the system log archive. An addition: it
  changes the UI run flags in the Makefile, and it brings back whatever else the diagnostics collect.
- **Read it first, then build.** A first milestone reads the system log after a reproduced or CI stall and records what
  it says. The hook is built only for the causes it leaves open.
- **Build the hook regardless.** The log answers for the app's side, whatever the system log says.

### Where the app records an event

Candidates:

- **An `NSApplication.sendEvent` override.** It sees the events the app's main loop dispatches, before any window or
  menu routes them. It misses events a nested tracking loop pulls itself: a control's mouse tracking takes its
  `mouseUp` through `nextEvent(matching:until:inMode:dequeue:)` and never calls `sendEvent`. The app starts from
  `@main` with `NSApplication.shared` (`App/Main.swift:12`), so a debug build can make a subclass shared first when the
  variable is set. No Info.plist value changes.
- **A `nextEvent(matching:until:inMode:dequeue:)` override.** It records each event taken off the queue with `dequeue`
  true. That covers what `sendEvent` sees, plus control tracking loops. It needs the same subclass. Menu tracking runs
  in HIToolbox, and whether its events pass through this override is not known.
- **An `NSEvent` local monitor.** Installed at launch when the variable is set, with no subclass. Monitors are called
  from `sendEvent`, so it misses what `sendEvent` misses. The app already has local monitors that can consume events
  (`FieldWidget+Pickers.swift:64`, `MapViewerView.swift:225`), and the order monitors run in is not documented. An
  earlier monitor that returns nil may hide the event from the recorder.

### What each record holds

Candidates for the fields:

- A monotonic time when the app took the event, and the event's own `timestamp`, which the poster set. The gap between
  them shows a main thread that held the event. Without it, a hung app that took the event late and an event that
  arrived late read the same.
- The event type, key code, characters, and modifier flags. Open: whether to record characters at all. UI tests type
  synthetic text, and the hook runs only under a test. Leaving them out keeps typed input out of the log, but a lost
  Escape and a lost Return then read the same unless the key code is decoded.
- The key window's number, and the class and accessibility identifier of the first responder. These are read when the
  app takes the event, before it acts. A reader must not take them as the event's outcome.
- For a mouse event, its window number, its location in that window, and the identifier of the view it hits. Without
  them, the log cannot put a click off its target, which UTERM-045's click question needs.
- The event's source process, from its `CGEvent`'s `eventSourceUnixProcessID`. It tells a synthesized event from a
  person's. An addition: no sighting in Motivation needs it. It would serve UTERM-045's "Whether to detect outside
  input" leftover.
- Records that are not input events: the app becoming active and resigning active, and the key window changing. Without
  them, a missing record cannot tell "XCTest dropped it" from "uniterm was not active and another app got it".

### How a report ties a test's event to a log line

Tests send events with `app.typeKey`, `app.typeText`, `.click()`, and `.scroll` directly, at about 600 sites in
`UITests/`. Candidates:

- **The event's timestamp against XCTest's steps.** The `.xcresult` records when each "Synthesize event" step began and
  ended, 1.80 s to 6.89 s for the shortcut's Escape. A record whose event timestamp falls in that window belongs to it.
  No call site changes. The system uptime clock in the event and the wall clock in the `.xcresult` need one fixed
  offset, which the hook can record at launch. The step times exist only once the run ends, so the base class cannot
  match at teardown. A person does the matching, or a post-run tool does, and no milestone builds such a tool yet.
- **No matching.** The report shows the last records before the failure, and a person reads them against the activity
  log.
- **A test-side marker before each event.** The base class numbers each event it sends, or writes the time it sends
  it, and the report lists the records between two marks. Every send must then go through the base class, so the
  about 600 sites change. The option the user picked for "Every failure gets the log" described the log reaching a
  failure "with no wiring at the call site". Whether that rules out routing sends through the base class is the
  user's to say.

### When and where the app writes

Candidates:

- **A write per record on the main thread.** ADR-08 allows main-thread work of a known, small size, and one record is
  small. Nothing is lost when the app is killed at teardown. It adds a file write to every event in every debug UI run.
- **A serial background queue that appends.** The main thread hands off the record and returns. A record still in the
  queue when the app is killed is lost.
- **A bounded buffer written at intervals and at exit.** Whether `XCUIApplication.terminate` lets an exit write run is
  not known, so the last records may never land.
- **The unified log through `Logger`,** as `ImageViewerScrollLog` does. It survives a kill. The base class would have
  to run `log show` to collect it, and whether the UI test runner may do that is not known.

## Risks

- **The log changes the timing it measures** — likelihood: low, impact: medium. Mitigation: the hook runs only under a
  UI test. The M1 fixture measures a burst of events with and without the hook, and the As built block records the
  cost. A cost that shows in the burst reopens "When and where the app writes".
- **The log shows the event arrived, and the flake is still unexplained** — likelihood: medium, impact: low. Accepted:
  that result is itself the evidence. It moves the cause from the runner to the app, and the entry records the next
  question.
- **A hung test carries no log** — likelihood: medium, impact: medium. Mitigation: the run's execution-time allowance
  (`Makefile:47`) may end a hung test without running its teardown, and the stalls this proposal targets are hangs of
  a kind. M1 records what such a failure carries. If it carries nothing, the hook's file stays in the scratch directory,
  and the report says where.
- **A debug hook leaks into a release build** — likelihood: low, impact: medium. Accepted: the hook sits inside
  `#if DEBUG`, as `OpenPanelTestHook` and the other `UNITERM_` debug hooks in `App/AppDelegate.swift` do. CI builds no
  release configuration, so a check on one hook's name would have nothing to inspect.
- **The attachment is lost in CI** — likelihood: low, impact: medium. Mitigation: CI's `app` job uploads the
  `.xcresult` on failure (`.github/workflows/ci.yml:81-88`), and an `XCTAttachment` from the test rides inside it. M1
  checks that a failing fixture's attachment is in the uploaded result.

## Milestones

### M1: The app records the input it receives

**Status:** NOT STARTED

- A debug build with the variable set writes one record per key, flag change, mouse press, mouse release, and scroll
  wheel it receives. A debug build without it, and every release build, writes nothing
- A UI test sends a key, a modified key, a click on a plain view, a click on an `NSButton`, and a wheel, and finds one
  record for each in the log. Each record that "Where the app records an event" leaves out is named in the As built
  block
- The base class attaches the log to every failing test, and to no passing one
- A test that launches the app more than once keeps every launch's records, and the attachment holds them all. A
  second launch appends to the first launch's file and never truncates it
- The attachment is read after the app ends and before the scratch files are removed. The log file is removed with
  them
- A test ended by the execution-time allowance, whose teardown never runs, still leaves the log file's path in the
  `.xcresult`. What such a failure carries is recorded in the As built block, including whether a CI kill leaves the
  file on the runner outside the uploaded artifact
- When the capture point takes events from `nextEvent`, an `NSButton` click's `mouseUp` is recorded exactly once
- When the writes go through `Logger`, a killed app's records show in `log show` at a persisted level, with every
  field unredacted
- A failing fixture's attachment appears in a local `.xcresult`, and in the one CI uploads for a failed `app` job. The
  CI check runs on a throwaway branch, and the failing fixture is never committed
- The cost of the hook over a burst of synthesized events is measured with and without it, and recorded in the As
  built block

### M2: The flaky entries say what to look for

**Status:** NOT STARTED

- The `spec/flaky-tests.md` Rule section says that a sighting of a stalled event records whether the log shows its
  event arriving
- Each of the four entries this proposal names says what its next sighting records
- The help for `make test-app` and `make test-app-select` names where a local run's logs land

## Decision Log

- 2026-11-25: Drafted from the `ShortcutOwnershipUITests` sighting on #109. The user chose keys and mouse over keys only,
  and the log on every failure over only the waits that call `focusReport`.
- 2026-11-25: The draft's first critique pass added the question on the system's own logs, the `nextEvent` capture
  point, the activation and click-location fields, the event-timestamp matching candidate, and the off-main-thread
  writes. It dropped the release-binary check, since CI builds no release configuration and the other debug hooks
  rely on `#if DEBUG` alone.
- 2026-11-25: The re-check converged. The test-side marker candidate stays open, with the question of whether the
  user's "no wiring at the call site" rules it out. The system-log question gained a separate diagnostics candidate,
  and the event-source field is marked as an addition.

## References

- `spec/flaky-tests.md`: the four entries named in Motivation, and the `DockedPaletteUITests` entry
- UTERM-045: Settle input before UI tests send it
- ADR-08: UI responsiveness, for the bound on main-thread writes
- `App/OpenPanelTestHook.swift`: the precedent for a debug hook keyed on an environment variable
