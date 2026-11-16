# UTERM-007 M5: text viewer remote control work-queue run

Started 2026-11-15. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-007 M5`, from `spec/proposals/UTERM-007-text-viewer-applet.md`. M5 lets a controller drive a text viewer
pane: scroll to an anchor, find, reload, and show inline Markdown. The specs live in the code repo, so every commit
below is in this repo, on the `agent/petunia` branch.

## Run state

The run's base and the row's base are both the commit "8< --- snip ---" that follows "Allow csrutil status in cg".

The row's one dependency, UTERM-004 M3, is met. No milestone carries a `Live after` line. Nothing is held, blocked, or
skipped, and no work is stashed.

| Milestone | Run status | Commits |
|---|---|---|
| UTERM-007 M5: Remote control | DONE | "Version applet commands by major and minor, and let reads wait"; "Raise request-layout's oversize error as a :bad-argument struct"; "Let a controller drive a text viewer pane" |

## Choices the user made in the plan

Exploration found three places where M5's text disagreed with the shipped code or an ADR. The user chose:

1. Reply timing. ADR-11 forbids deferring the reply of a command with an effect, and the command hook had no deferred
   reply. Every effectful command replies at once with a handle. A `wait` command with no effect holds a pending reply
   until the handle settles. This builds ADR-11's pending reply in AppletKit, in the shape UTERM-019 "Commands that
   wait" specifies. It is a scope addition.
2. Send. UTERM-003's send stays file-based, as built. UTERM-007's sentence that it lands on the inline command is
   amended.
3. Schema version. A shared major and minor across the applet schema, the dispatcher, ScriptWire, the exec wire, and
   `uniterm/send-command`. It is a scope addition.

## Run-level best guesses

1. The milestone lands as two commits: the shared command contract, then the viewer. CLAUDE.md asks for one logical
   change per commit.
2. The Janet version argument is `[major minor]`, and a bare whole number means minor 0. If wrong, only the shim's
   parser and its fixtures change.
3. Scroll or find while a load runs is refused with `busy`, not queued. M5's check allows either.
4. `wait` takes a capped timeout and answers `pending` when it passes, as UTERM-019's next-events does.
5. Reload with no file is refused.
6. The inline cap sits under the shim's 32 KiB argument limit, with room for JSON escaping.
7. A heading anchor is an index into the contents list, so no heading text crosses the wire.

## Local checks

`make fmt`, `make lint`, `make check`, `make build`, `caffeinate -dimsu make test-package`, UI `build-for-testing`,
`proposals.py check`, and `proposals.py freeze`. The coordinator runs the touched UI test classes through `cg_run`.

## M5: Remote control

### Stage A: shared command contract

Commit: "Version applet commands by major and minor, and let reads wait".

What it built:

- `AppletSchemaVersion` holds a major and a minor. The dispatcher accepts the same major and a minor up to the
  applet's own. Anything else is `unsupported-version` before any effect, and the message names both versions.
- `perform` returns `AppletCommandReply`, either `.immediate` or `.pending(PendingReply)`. A pending reply is a
  main-actor object the applet settles with `complete` or `fail`. Its `onCancel` runs when the dispatcher fails it.
- A schema entry carries `mayWait`. A `.pending` from a command not marked so fails as `failed` and asserts in debug.
  This makes ADR-11's no-effect rule a dispatch check, not only a comment.
- The dispatcher checks authority again before a pending reply goes out. `pushControl` revalidates after every
  control change on a pane, so a driver run starting on a pane fails a script's wait on it. `ownerEnded` revalidates
  when a connection ends. Window close fails every pending reply. The cap is 64 per window. Over the cap the reply
  fails as `busy`, which scripts see as `:refused`.
- ScriptWire is at version 12, with call 7 carrying a `u32` major and minor. The exec wire is at version 4, and its
  `schema` field is `[major, minor]`. Each side refuses other versions at the hello. Exec replies already matched by
  request ID, and a test shows a pending reply arriving out of order.
- `uniterm/send-command` takes `[major minor]` or a bare whole number, which means minor 0. `1.5`, negatives, strings,
  and tuples of the wrong length are refused. Its oversize-argument error is now a `:bad-argument` struct.
- Every fixture moved to schema 1.0. `NotesFixture` gained a `wait-for-notes` command that waits.

Checks: `make fmt`, `make lint`, `make check`, `make build`, and `caffeinate -dimsu make test-package` passed. A scoped
ASan fuzz of the script and exec wire codecs passed, at 2,000 iterations. The coordinator re-ran `make lint` and the 90
tests in the touched classes. Both passed. UI tests were not built, since no UI test compiles against the changed
types and `PresentationUITests` uses bare integer versions, which still work.

Implementer best guesses:

1. The exec wire's schema is a two-element array, to match the Janet tuple.
2. ScriptWire has its own `ScriptSchemaVersion`, since `ScriptWire` does not depend on `AppletKit`. `WindowScripting`
   converts between them.
3. `PendingReply` is a class the applet holds, and `complete` and `fail` say whether that call settled it. An enum
   return forces every adopter to say which kind of reply it gives.
4. Revalidation runs at explicit sites, and after review it lives in `pushControl` so a control change cannot skip it.
5. The cap is 64 per window, and over-cap fails as `busy`.
6. A driver's exec hello is accepted at the same major and a minor up to the pane's.

Review findings:

- Driver run start, failed run start, and their generation bumps did not revalidate. Traced and confirmed. Fixed in
  `pushControl`, with `ExecPaneTests.testStartingADriverFailsAScriptsWaitOnThePane`, which failed in 3.7 s before the
  fix.
- ADR-11's no-effect rule was a doc comment only. Fixed with `mayWait`, a coordinator best guess.
- A dispatcher test named for pane close tested applet release. Renamed.
- Comment wrap and an unused `Comparable` conformance. Fixed.
- A per-caller share of the pending cap. Dismissed: UTERM-019 specifies a per-window cap.
- Amending UTERM-004, UTERM-021, and UTERM-001 for the new wire versions. Dismissed: all three are `implemented` and
  frozen. UTERM-007's amendment records the change.
- During the fix round the first version of the new driver test hung on the unfixed code, since it awaited the wait
  with no bound. The coordinator cancelled that one run after 22 minutes without output and nudged the agent. The test
  and three neighbours now give up after 3 s.

`adr-impact`: consistent with ADR-05, ADR-06, ADR-07, ADR-08, ADR-09, and ADR-11. No conflicts.

ADR candidates raised, for the bar in `design.md`:

- The command schema's compatibility rule: the same major, and a minor up to the applet's own. It is a public contract
  that scripts and drivers in other processes depend on, and it is hard to reverse. It passes the bar and goes to
  UTERM-007's Decision Log as `Undecided`.
- The pending reply's rules beyond ADR-11: the `mayWait` marker, revalidation on every control change, and a
  per-window cap. ADR-11 already records the decision. These are its mechanism, so this does not pass the bar.

Found inconsistency: `request-layout`'s oversize error is still a plain string, while every other shim failure is a
struct. It sits next to this stage's shim change and needs no design call, so Stage B fixes it in its own commit.

### Bug fix found along the way

Commit: "Raise request-layout's oversize error as a :bad-argument struct". A too-large layout raised a bare string,
while every other `request-layout` failure raises a struct. The fixture assertion failed before the one-word fix.

### Stage B: the viewer's remote commands

Commit: "Let a controller drive a text viewer pane". The proposal's M5 As built block holds the detail. In short:

- The viewer declares disconnected and remote-controlled access. Exec combinations are refused at the existing gates,
  proved through the catalog and through a window's `declareExecDriver`.
- Schema `text-viewer` 1.0 has `show-markdown`, `reload`, `scroll`, `find`, and `wait`. The first four reply at once
  with a handle. Only `wait` is `mayWait`. No command opens a path.
- Replies carry handles, fixed state words, fixed failure codes, counts, and numeric anchors. A test scans replies for
  the document's text, the query, and the path.
- Inline Markdown clears the path, stops the watch, and supersedes any load. Relative images show their alt text. The
  layout file holds only a flag, in a version 2 payload written only when the flag is set. The text lives in the
  description's undo-only part, encoded once when the content arrives. A relaunched pane says the content came from a
  program and was not restored.
- `uniterm/send` stays a file send, and works once the viewer declares remote control.
- The pane's remote-control badge reach now reaches the applet through a new `Applet.hostBadgeReachDidChange(_:)`
  hook with a no-op default. The find bar uses it to keep Done clear of the badge.

Checks: `make fmt`, `make lint`, `make check`, `make build`, `scripts/swiftpm-offline-check.sh`,
`caffeinate -dimsu make test-package` (2,669 tests, 0 failures, 9 skipped, all pre-existing), and UI
`build-for-testing` passed. The coordinator ran the new UI test in the real app and viewed its screenshot. The UI
class results are below.

Implementer best guesses, recorded in the proposal's Decision Log as `(work-queue best guess)`:

1. Payload version 2 is written only when the inline flag is set. M1 to M4 are on upstream main, so the M2 entry's
   "no older reader exists" reasoning no longer holds, and ADR-06 asks for a bump. Plain descriptions stay version 1,
   so a rollback loses nothing.
2. Wait states are `loaded`, `done` for a finished scroll or find, `failed` with a code, `superseded`, and `pending`.
3. Scroll or find during a load or before the page renders answers `busy`, naming the load's handle.
4. The inline cap is 12 KiB. Quotes and backslashes cost two bytes in the helper's JSON and other control characters
   six. A test through the real shim shows 12 KiB of quotes fits and 12 KiB of `\x01` gets `:bad-argument`.
5. `wait` takes 0 to 30,000 ms, defaulting to 10,000. A timed-out wait answers `pending`.
6. The handle table holds 32. The oldest finished handle goes first, and a full table of running handles refuses with
   `busy`.
7. Scroll anchors are `page`, `heading`, `line`, and `character`. A heading is a contents-list index.
8. Remote find puts the query in the pane's own find bar, never the system find pasteboard. `backward` selects the
   last match.
9. The new badge-reach hook on `Applet`. It is a small addition to the applet contract, made to fix a collision this
   milestone exposed. The proposal said the viewer needs no contract change. This hook is the host telling every
   applet a layout fact, with a no-op default. It deserves the user's look.

Review findings and dispositions:

- An amended inline-size check had no Decision Log entry for its dropped "not Markdown" half. Fixed.
- A comment said line breaks cost six bytes in JSON. Fixed: control characters do.
- A cap test built its own JSON. Replaced by a test through the real shim.
- `Package.swift` changed without `swiftpm-offline-check`. Ran it, and it passed.
- A test-only encode counter and many widened members. The counter is gone, the undo part is encoded once on arrival,
  and most members are private again. The members the remote extension uses stay internal.
- A pane restored with notes and described before `start()` dropped them. Traced, confirmed, and fixed, with
  `testAnUnstartedRestoredPaneStillDescribesItsNotes`. That test was written after the fix, so it pins the fix, not
  the bug.
- The find-pasteboard change-count test can see another app's writes. Dismissed: M4's tests use the same pattern.
- Bounded real-time polling in tests. Dismissed: it matches the existing harness.

`adr-impact`: consistent with ADR-03, ADR-05, ADR-06, ADR-07, ADR-08, ADR-09, ADR-11, and ADR-12. No conflicts. Two
`ADVISORY` notes are recorded for the user:

- A controller with pane control can learn document content indirectly from find counts and anchors. No reply carries
  text. Recorded as an `Undecided` ADR candidate in the proposal.
- Content that is restorable by undo but never saved, as inline notes are, has no shared rule across applets. It does
  not pass the ADR bar alone, since only this viewer does it today.

The real-app UI test took four runs to pass:

1. The script's error printed as an opaque struct. The script now prints each failure's kind and message.
2. `scroll failed: the contents list has no such entry`. The pane settled a load's handle before it installed the
   contents list. That was a real ordering defect in every format, and it is fixed. The load now ends last. Two
   package tests failed with the old order and pass with the new one. It was not this failure's cause.
3. The error now names the list's size: 1 entry, and find counted all 40 matches from line 0. The note reached the page
   as one line, because Janet's reader drops a literal line break inside a quoted string, and the UI script wrote
   literal breaks. The package twin used escapes. The UI script now writes escapes. A package test checks that the UI
   script and its twin hold the same lines.
4. Passed. The screenshot showed the pane's remote-control badge drawn over the find bar's Done button. Fixed with the
   badge-reach hook above, and pinned by `TextViewerBadgeClearanceTests`, which failed without the fix. The rerun's
   screenshot shows Done clear of the badge.

Unowned failure: `FindTests.testSearchingTheDecodedCapNeverBlocksTheMainThread` failed in 2 of about 5 full package
runs, with 54 and 58 main-actor turns where it expects more than 100. It passed alone and in the other runs.
`spec/flaky-tests.md` already lists it, with sightings in runs that touch no text-viewer code. This milestone's only
change near it adds one `finish()` call after the search ends. A second, `ExecDriverChannelTests`'s oversize clipboard
test, timed out once in a full run and passed alone in 8.5 s. Neither was compared on the base commit.

Test cost: `TextViewerRemoteTests`, `RemoteHandleTests`, and `TextViewerRemoteWindowTests` ran together in 8.1 s.
The PDF match-cap test is 3.3 s of that. It is the only proof that a PDF find past the cap ends.

## Row review and final review

The run has one row, so the row review and the run's final review cover the same range, from the run's base to the
commit "Let a controller drive a text viewer pane". One `reviewer` pass did both, with an ADR review, beside one
`adr-impact` pass. A fresh implementer fixed the findings. Commit: "Record UTERM-007's contract addition and wire
skew, and name the exec version in a refusal".

Findings and dispositions:

- "The applet contract" still said the viewer needs no contract change, while the range added
  `Applet.hostBadgeReachDidChange(_:)`. Fixed: the decision is amended, with a Decision Log entry tagged
  `(work-queue best guess, addition)` that names the alternative not taken, a host inset of the applet's view.
- "Control levels" lacked the skew analysis for ScriptWire 11 to 12 and the exec wire 3 to 4. Fixed. Writing it found a
  bug: a v4 app read a protocol-3 driver's hello as malformed, since it decoded `schema` before checking the protocol,
  and its message named no version. The hello now decodes for any other protocol, and the refusal says "The driver
  speaks exec protocol 3, and this uniterm speaks 4. Update the driver or uniterm so they match." A test covers it. It
  was not run against the unfixed code. A v4 driver against a shipped v3 app still gets v3's malformed-line message,
  since that build cannot change. The proposal records it.
- ADR-11's completion event against UTERM-004's rule that remote callers receive no events. Fixed: "Control levels" now
  says `wait` stands in for it.
- UTERM-019 still said the pending reply was to be built, that schema versions match exactly, and that ScriptWire moves
  to 9. Fixed in place, with one Decision Log entry. UTERM-019's own minor-version policy now follows UTERM-007's rule.
  That is a best guess UTERM-019 may revisit.
- `pushControl`'s comment claimed every control change goes through it. `enableRemoteControl` now revalidates pending
  replies too. Pane-creation paths stay direct, since a pane being created holds no pending reply. The comment now
  says so.
- Impacts edits carry no marker. Dismissed: markers attach to decisions and milestones, and M5's one marker covers its
  checks.

`adr-impact` on the whole range: no conflicts and no supersessions. Its ADR candidates are the schema compatibility
rule, already `Undecided` in the Decision Log; the badge-reach hook, which falls below the bar unless more host overlays
follow; and the pending-reply cap and revalidation policy, which is ADR-11's mechanism and does not pass the bar alone.

Checks after the fixes: `make fmt`, `make lint`, `make check`, `make build`, and `caffeinate -dimsu make test-package`
passed. `proposals.py freeze` reported nothing.
