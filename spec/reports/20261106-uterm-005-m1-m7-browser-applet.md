# UTERM-005 M1-M7: Browser applet work-queue run

Started 2026-11-06. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-005 M1-M7`, from `spec/proposals/UTERM-005-browser-applet.md`. UTERM-005 adds a browser pane built on the
system's WebKit. The specs live in the code repo, so every commit below is in this repo, on the
`agent/petunia` branch.

## Run state

The run is in progress. The run's base is "8< --- snip ---", which is also the row's base. The row has no dependencies,
and no milestone carries a `Live after` line. Nothing is held, blocked, or skipped, and no work is stashed. No commands
need the user's credentials.

| Milestone | Run status | Commit |
|---|---|---|
| UTERM-005 M1: Single-page browser | DONE | "Add a single-page browser applet" |
| UTERM-005 M2: Security indicator | DONE | "Warn in the address bar when a page is not fully secure" |
| UTERM-005 M3: Tabs | DONE | "Add browser tabs, keys, and a question before resending a form" |
| UTERM-005 M4: Address bar input | DONE | "Search from the address bar, and offer plain HTTP only by the user's action" |
| UTERM-005 M5: Website data, restore, and reopen | DONE | "Give the browser its own website data, and restore tabs lazily" |
| UTERM-005 M6: Pop-ups, downloads, and running work | IN PROGRESS | |
| UTERM-005 M7: Web content failure | QUEUED | |

## Local checks

The implementer runs `make fmt-check`, `make lint`, `make check`, `make build`, and `make test-package` through `cg_run`.
It runs `make swiftpm-offline-check` when `Package.swift` changes, and builds the UI tests for testing. Then it runs
`proposals.py check` and `proposals.py freeze`. The coordinator reruns `make test-package` before each commit. It runs
`make test-app` through cg, after a filtered probe that shows whether the screen is locked. It also checks the
crash-report folder for new uniterm reports.

## Run-level best guesses

The approved plan made these guesses before any work began.

1. Plain HTTP needs an App Transport Security key. The proposal requires `http` loads and never mentions App Transport
   Security. `NSAllowsArbitraryLoadsInWebContent` is scoped to web content. If the guess is wrong, the loopback default
   and Load over HTTP fail.
2. Camera and microphone are denied explicitly. The proposal is silent. The app has no usage strings, so a capture request
   must never reach the system's privacy prompt. Rests on ADR-07. Location gets the same treatment if a test shows it can
   reach that prompt.
3. HSTS has no public WebKit query, to be confirmed in M4. The guess records `Strict-Transport-Security` from main-frame
   HTTPS responses in a small browser-owned list. It honours `max-age`, and Clear Website Data empties it. A preloaded host
   never seen before can still show the offer, but WebKit upgrades the load, so nothing downgrades. M4's text is amended
   to say so. Header parsing and the list are proved at the pure-logic layer only.
4. Detach has no host trigger. Nothing in the host sends `detach` or `reattach`. M5 and M6 build the rule and prove it by
   calling the events in applet tests. The behaviour has no user path yet.
5. Test layering. Pure logic is tested in `BrowserModel`. WebKit behaviour runs in package tests against an in-process
   fixture server, and UI tests cover the launcher, menus, and keys. If `WKWebView` cannot load under `swift test`,
   integration tests move to the UI layer, with a fixture server started by `scripts/run-ui-tests.sh`.
6. `TerminalTabBar` moves to `AppletKit`. A second copy would drift.
7. The browser's declaration has `opens: []`. "Schemes" refuses `file:`, and the text viewer owns files.
8. The payload shape is fixed at M1, with a tab array and a selected tab. ADR-06 would otherwise force a bump between
   milestones for a format no milestone ships alone.
9. The profile label goes in the browser toolbar, with no selector. "Website data" leaves placement to M5's review.
10. The host's reopen failure text gets fixed in M3. It says "Check that the shell can start" for any tab reopen failure.
    The applet supplies the reason instead.

## Not in the proposal, and not built

Adding either of these would be a scope addition, so the run leaves them out.

- File upload pickers. An `<input type=file>` does nothing without a `runOpenPanel` delegate.
- HTTP authentication dialogs. A basic-auth page shows its 401.

## Checks left to the user

- M1 to M7: look at the real window. The sandbox blocks agent screenshots.
- M2: a trusted HTTPS page shows no warning, and an HTTPS page embedding HTTP content shows one. Loopback has no trusted
  HTTPS, so tests prove only that an `http:` page warns and `about:blank` does not.
- M3: trackpad swipes and mouse buttons 4 and 5 on real hardware.
- M5: confirm the profile label's placement in a hands-on review. Logins surviving a real relaunch.
- M6: a real sign-in pop-up completing its flow against a real provider.

## Milestones

### M1: Single-page browser

Commit: "Add a single-page browser applet". A separate commit, "Allow single browser test runs in the cg allowlist",
carries the rules approved at cg's prompt during this milestone.

Checks, on 2026-11-06, with the display on and the screen unlocked:

- `make test-package`, coordinator's run `BAPV4S`: 1,194 tests, 4 skipped, 0 failures, 48.8 s.
- `make test-app`, coordinator's run `Y6SB7S`: 100 tests, 0 failures, 833.6 s.
- `make fmt-check`, `make lint`, `make check`, `make build`, `make swiftpm-offline-check`, and the UI tests' build for
  testing passed in the implementer's runs. `make fmt-check`, `make test-package`, and the build for testing were rerun
  after the last fix.
- `proposals.py check` reports nothing. `proposals.py freeze` reports one hunk this run did not make. See "Edits found
  and not made".

The spike settled best guess 5: a real `WKWebView` loads from an in-process `NWListener` server under `swift test`, with
no window. A load takes about 0.1 s.

Best guesses from the implementer:

1. Browser is the fifth launcher entry, so Cmd-5 picks it. If wrong, a few launcher tests change.
2. `BrowserApplet` exposes `descriptionTypeID`, so the app target needs no `BrowserModel` product.
3. The payload stores a URL only when a restored tab could load it, drops a URL over 32 KiB, and cuts a title to 512
   characters. This amends "What restore loads", with a Decision Log entry. If wrong, a committed `blob:` page restores as
   a refusal at every launch.
4. Downloads and new windows are interim until M6: a download is cancelled with one warning, and a new-window link does
   nothing. A failed load posts one warning until M4 builds the error page.
5. Back and forward onto a post result are refused as well as reload. M3 turns all three into the question.
6. Open Location, Reload, Back, and Forward are declared now, so the command set is not empty.
7. The applet takes its data store as a parameter, with the default store until M5.
8. `detach` and `reattach` drive only the alerts until M6 adds media suspension.
9. An IPv4 address counts as loopback only in four decimal parts, so `127.1` takes HTTPS.

Review findings and dispositions:

- Fixed: a swipe or the web view's own Reload could resend a form, so the navigation delegate is now the one gate. WebKit
  reports a history step onto a post as `.backForward` with a POST, so a gate on `.formResubmitted` alone would miss it.
- Fixed: a post to an address too long to store was not marked as a post.
- Fixed: a newer unreadable description reported as corrupt, since the payload was decoded before the version check.
- Fixed: the capture-deny test now asserts that the delegate is installed.
- Fixed: one UI test that duplicated a stronger package test was retired, and another's comment was narrowed.
- Fixed: the As built block now says the App Transport Security key drops the TLS floor for web content.
- Traced and confirmed, then fixed: Reload on a tab whose restore was refused skipped the scheme check, so a stored `blob:`
  loaded.
- Traced and confirmed, then fixed: a non-displayable or attachment response ended silently under code 102.
- Traced, smaller fix: `StatusQueue.post` already bounds text at 2,048 bytes, but the cut could remove the reason, so
  addresses are now cut to 120 characters first.
- Added as a pin: a server asking for credentials gets none and shows its own 401. WebKit asks the server twice.
- Traced and not confirmed: a same-document entry on a post page. The diagnosis stays unresolved in the review's terms,
  and a pin test shows `webView.reload()` sends no second post there.
- Added as a pin: a redirect to a refused scheme leaves the page and warns once.
- No defect: the test harness's 30 s bound.

Found by the coordinator's UI run, not by review: a new pane showed Back and Forward enabled, since `NSButton.isEnabled`
defaults to true and the state was applied only on a web view change. Fixed, with a package test that failed first.

ADR check: no conflicts and no supersessions. It raised two uncovered decisions.

- The app-wide `NSAllowsArbitraryLoadsInWebContent` passes the bar, since it reaches every later applet that hosts a web
  view. It is in the Decision Log as `Undecided`.
- Whether web content can take uniterm's window keys fails the Decision test. ADR-04 already decides it, and M3's key
  checks cover the browser.

Left open:

- A real microphone request is not proved. A page's `getUserMedia` never reached the delegate under `swift test`, and its
  promise stayed pending. The cause is unsettled, and a system privacy prompt before the delegate is one candidate, with
  no log evidence either way. The deny stands, and the test pins the delegate's answer only. Try a microphone request from
  a real page in the running app. If the app is killed or a prompt appears, best guess 2 does not hold.
- Geolocation has no `WKUIDelegate` hook, so it could not get the same treatment. What happens is unverified.

Failures and restarts:

- An `xctest` crash report at 10:58 local on 2026-11-06 is a trap in a draft of `testWebKitsOwnReloadAndGoBackCannotResendAForm`,
  an array index past the end. The current test has no such index. No product frame is involved.
- The implementer stalled twice on a cg approval prompt, once for per-test `xcrun xctest` commands and once for `log show`.
  Each was stopped and resumed with its context. cg still lists run `AP2SV9`, a microphone test from a pool that was
  cancelled, as running.

Test cost: the browser applet tests take about 1 s together, and the model tests take milliseconds. The fixture binds a
loopback port the system picks, so no two tests overlap on ports. The project has no `make test-cost` target.

### M2: Security indicator

Commit: "Warn in the address bar when a page is not fully secure".

Checks, on 2026-11-06:

- `make test-package`, coordinator's run `2KT50Y`: 1,201 tests, 4 skipped, 0 failures.
- `make fmt-check`, `make lint`, `make check`, `make build`, and the UI tests' build for testing passed in the implementer's
  runs. `proposals.py check` reports nothing, and `freeze` reports only the UTERM-013 hunk.
- `make test-app`, coordinator's run `WWM5Y9`: not a usable result. See "Unowned failures".
- A filtered UI run, `ZEBEFA`, of `BrowserUITests` and three tests that had failed: 6 tests, 0 failures.

Best guesses from the implementer:

1. The stale-flag fix sits in the rule, not in state captured at commit. Capture at commit would still show the new address
   with no warning. If wrong, the tab changes and one table row goes.
2. The brief warning on an `https` address loading after an insecure page is accepted, since it errs on the safe side. It is
   recorded in As built only.
3. The icon sits between Reload and the address field, in theme yellow, as `exclamationmark.triangle.fill`. This is for the
   user's visual check.

Review findings and dispositions:

- Traced and confirmed, then fixed: WebKit moves `url` to the new address before it updates `hasOnlySecureContent`. A stalled
  `http` load from a secure page showed the address with no warning. An `http` URL now always warns. The test failed first.
- Traced and confirmed, then fixed: `about:blank#x` was not treated as blank. One definition now serves the rule and the
  address bar.
- Traced and not confirmed: WebKit reports the flag false for a `blob:` page made by an `http` page, so it warns. A `blob:`
  page made by an `https` page could not be measured. The diagnosis stays unresolved for that case.
- Fixed by narrowing the claim: nothing could flip the flag after commit, so the observer is untested. As built and the test's
  doc comment say so. No test-only seam was added.
- Fixed: a test now asserts the hidden icon takes no room. The Decision Log entry now says which check is left to the user.
  Two comments were reworded.
- Dismissed: posting a VoiceOver announcement when the warning appears. No decision or check asks for it. The icon is reachable
  as an image with a label while shown.

The ADR check found no conflicts, and no new candidate.

Test cost: the security test class takes about 0.6 s.

### M3: Tabs

Commit: "Add browser tabs, keys, and a question before resending a form".

Checks, on 2026-11-06:

- `make test-package`, coordinator's run `A65FTM`: 1,227 tests, 4 skipped, 0 failures.
- `make test-app`, run `5W5MC3`, before the warning fix: 103 tests, 1 failure, described below.
- Filtered UI run `QEQMJ9`, after that fix, of `ShortcutOwnershipUITests`, `BrowserUITests`, and `TabsUITests`: 18 tests, 0 failures.
- `make fmt-check`, `make lint`, and the UI tests' build for testing passed after the last fix. `make check` and `make build`
  passed in the round before it, and the build for testing compiled the app after it. `proposals.py check` reports nothing, and
  `freeze` reports only the UTERM-013 hunk.
- Trackpad swipes and a physical mouse need hardware. The mouse handler is tested with real `CGEvent`-built events.

Best guesses from the implementer:

1. The question lives in the navigation delegate. It holds WebKit's decision and resolves it exactly once. A second repeat
   while one waits, and closing the tab, each cancel. If wrong, a pre-check path returns beside the gate.
2. Only a post this tab saw a form produce is ever asked about. Measured: reopening a tab on a post result sends no second post,
   and the tab shows its stored title and a blank page with its history intact. "Browser commands and keys" and M3's check are
   amended. If wrong, a yes path opens into restored history, which "What restore loads" forbids.
3. A yes on a history step onto a post result may send no post, since WebKit can serve the step from its cache. A yes on Reload
   is proved to send one.
4. Web views are lazy. A tab builds one on first use, and a tab loads when first selected. The attached-pane rule stays with M5.
5. New Tab inserts after the selected tab, selects it, and focuses the address bar. Closing the selected tab selects its right
   neighbour, or the last tab. A tab switch drops an unsent edit in the address bar. A blank tab titles itself "Browser".
6. The host says "could not be reopened: <reason>." The terminal's reason carries the shell advice, so its message is unchanged.

The coordinator's best guess, for the user's review: only the browser's own Back, Forward, and Reload may ask before resending a
form. They are the toolbar, the Browser menu, the commands, and mouse buttons 4 and 5. A page script, a background tab, a
trackpad swipe, and the web view's own Reload are refused with a notice and no question. WebKit gives no user-initiated flag, and
a page could otherwise raise the question in a loop, luring a click that repeats an earlier order. The cost is that a swipe onto
a post result is refused where a button would ask. If wrong, the swipe needs its own detection, or the question gains a limit.

Review findings and dispositions:

- Fixed by the decision above: a page's `history.back()` could raise the question in a loop, including from a background tab.
  `location.reload()` turned out to reload a post result with a GET, so it sends no post and needs no refusal.
- Fixed: matching a history step by address let an unseen restored post inherit a yes from a seen post to one address. Measured:
  at the gate the current entry is already the target, so seen posts are now keyed on the entry's identity. The test failed first.
- Fixed: load origin is per tab, and a notice from a background tab names the tab.
- Fixed: a late answer after a typed load left a stale question behind. Two tests were tightened, and one was folded into another.
- No finding on the held decision: every path resolves WebKit's handler exactly once.

Found by the coordinator's UI run, not by review: `testARemapOntoAnAppletKeyWinsAndWarnsOnce` failed. Two applets now declare Cmd-T,
so a remap posted two warnings and the terminal's was replaced on the bar. It stayed only in the history. One warning now names
every applet that lost a key. Each applet lists at most three commands, then a count. The test failed first. This is shared code,
not browser work. UTERM-013's text says one warning names the applet, so it may want a correction of fact, which the user decides.

ADR check: no conflicts. The two candidates raised, the shared tab bar and the single gate, fail the Architecture test, since both
shape one component's internals.

Test cost: the browser tab tests take about 1.3 s for 13 tests.

### M4: Address bar input

Commit: "Search from the address bar, and offer plain HTTP only by the user's action".

Checks, on 2026-11-06, with no other UI run on the screen:

- `make test-package`, coordinator's run `QSPVA7`: 1,304 tests, 4 skipped, 0 failures, 54.7 s.
- `make test-app`, coordinator's run `M1FCMR`: 105 tests, 0 failures, 839.7 s.
- `make fmt-check`, `make lint`, `make check`, `make build`, and the UI tests' build for testing passed in the implementer's runs.
  `make swiftpm-offline-check` passed in its first round, and `Package.swift` did not change after that. `proposals.py check`
  reports nothing, and `freeze` reports only the UTERM-013 hunk.

Measured real loads, under `swift test`: a self-signed TLS fixture fails with -1202 with a trust key and `errSSLBadCert` (-9808). A
plain listener answering HTTPS fails with -1200, no trust key, and `errSSLClosedNoNotify` (-9816). A closed port fails with -1004.

Best guesses from the implementer:

1. Classification. A space beats a trailing `/` and a `word:` prefix, so `note: buy milk` searches. The proposal's "a scheme is
   always an address" conflicts with "a space is always a search" there, and search was chosen. Text starting `scheme://` stays an
   address when it holds a space. Only typed text searches. `user@host` searches and `user@host.com` loads. If wrong, spaced
   `javascript:` text goes to the engine as text and runs nothing.
2. A certificate failure shows a native pane with no action, for any HTTPS load. An explicit `https://` that fails another way gets
   the plain warning.
3. An offer needs the failing URL to be the assumed one, on the same host and port. A timeout does not offer.
4. Only the selected tab asks about a handoff. A background tab's request is refused with a warning that names the tab.
5. `BrowserServices` has no default, so every construction site must pass it. It bundles the engine closure, the HSTS store, the
   opener, and the clock.
6. The Settings note sits under the control, since Settings has no status bar. A stored value is never rewritten.
7. HSTS persists to `Application Support/uniterm/Browser/hsts.json`, or `UNITERM_BROWSER_DIR` in a debug build. It holds at most
   2,048 hosts, and IP literals never record.
8. A key press on a focused link leaves no mouse-up, so it is refused with a notice. If wrong, a key press on a link meant for an
   app is refused until the user clicks it. The bound on a real click is 1 s, so a very slow machine may need a second click.

The coordinator's best guesses, for the user's review:

- A link may reach another app only after a real mouse-up in the web view within 1 s, spent once. WebKit reports a script's
  `a.click()` as `.linkActivated`, so a page could open compose windows with no click and no limit, from a background tab, and could
  loop the question. M6's check says a script never launches an app silently. A script that runs within 1 s of a real click on the
  page can still spend that click. It is bounded to one use.
- The HTTP offer uses an allow-list: -1004, -1005, or -1200 with a closed-connection status, and no certificate sign anywhere in the
  error chain. Anything unclassified gets the plain warning, so an unknown TLS failure on a later macOS cannot offer HTTP.

Review findings and dispositions:

- Fixed by the decisions above: the `mailto:` path with no gesture, and the question loop. The test failed with the gate neutered.
- Fixed by the decision above: the offer's deny-list. Six table assertions failed first.
- Fixed: a newer HSTS file was overwritten. The first test passed for the wrong reason, since its file did not decode. Reading the
  version alone first fixed that, and the test then failed on the old code, with the file cut from 66 to 35 bytes.
- Fixed: "Schemes" claimed more than was built, and it now says what ships, with the prior meanings in the Decision Log.
- Fixed: every HSTS response rewrote the file on the main thread. A move of under an hour on a live entry now records nothing.
- Fixed: the delegate's one line that feeds the list had no test. A stand-in response object now drives it, with no production seam.
- Traced and confirmed, then fixed: an offer page outlived a later failure that built no page. A new provisional load clears it.
- Accepted, recorded in As built: attacker-chosen hosts can evict entries at the 2,048 cap. Impact is low, since WebKit still enforces
  HSTS.

ADR check: no conflicts. The implementer's candidates fail as written, since the HSTS list and `BrowserServices` are mechanisms. The
invariant behind the second is in the Decision Log, waiting on the second applet that takes a setting.

Left open: the error pane was never rendered, so its layout needs the user's visual check. The self-signed fixture key is committed
as published test data in a test-only target, so a secret scanner may flag it.

An `xctest` crash report at 13:35 local on 2026-11-06 is a trap in a test draft that subclassed `WKNavigationResponse`. No product frame
is involved, and the current test uses a stand-in object.

Test cost: `BrowserAddressTests` takes about 1.5 s for 19 tests, and the new model tests take milliseconds.

### M5: Website data, restore, and reopen

Commit: "Give the browser its own website data, and restore tabs lazily".

Checks, on 2026-11-06, with no other UI run on the screen:

- `make test-package`, coordinator's run `287QC0`: 1,338 tests, 4 skipped, 0 failures, 58.2 s.
- `make test-app`, coordinator's run `WQQ03K`: 109 tests, 0 failures, 875.1 s.
- `make fmt-check`, `make lint`, `make check`, `make build`, `make swiftpm-offline-check`, and the UI tests' build for testing passed in
  the implementer's runs. `proposals.py check` reports nothing, and `freeze` reports only the UTERM-013 hunk.

Best guesses from the implementer:

1. A pane's undo part now carries each open tab's history, in `tabStates`. The part held only closed tabs, so a closed pane reopened with
   no history on any open tab. It stays out of the layout file. If wrong, pane reopen restores addresses only.
2. A tab with no page returns no history record. A blank tab used to return a useless 137-byte record, and that record replaced a pending
   one when a reopened, unloaded tab closed again.
3. WebKit's removal reports no failure, so the only failure Clear Website Data can report is an HTTPS-only list that cannot be emptied. A
   newer build's file is never rewritten, so that clear reports a partial result.
4. The profile label reads "Default Profile" at the trailing end of the toolbar, with no selector.
5. The store is a required initializer argument, so nothing in the app can fall back to WebKit's default store. A debug build's
   `UNITERM_BROWSER_STORE=memory` gives UI tests a store that keeps nothing. `forIdentifier:` was not tried under UI tests.

Review findings and dispositions:

- Fixed: a page writing `document.title` in a loop made `describe()` read and encode every tab's history on the main thread, per event, and
  throw it away. Each tab now caches its record, and the applet caches the encoded part, invalidated only by history changes. The test failed
  first with 24 reads where 0 are expected. A pane close takes the record as of the last history change, so a scroll position can be that
  old. A tab that closes alone reads live. A page pushing history entries in a loop still costs one read per entry, which WebKit rate-limits.
- Fixed: a clear, a failed write, then a second clear reported "Cleared." The test failed first.
- Fixed: the failure line contradicted itself. It now reads "Website data was partly cleared."
- Fixed: a stored address reached the pane with bidirectional overrides and unbounded combining marks, one test run giving 10,009 bytes.
  `AddressDisplay.bounded` now cleans and bounds every address shown in a question, pane, or notice. The tests failed first.
- Fixed: three proposal amendments lacked a marker or a prior meaning. VoiceOver now hears the Settings row's result, and reads the profile
  label once.
- Closed test gaps: a tab closed or reopened while detached, no repeat warning on a refused tab, a wrong `tabStates` count, local storage after
  a clear, and a test that could hang.

Weak proofs, stated plainly: `BrowserLayoutChangeTests` passes on the old code too, so it is a guard, since the window compares with the undo
part stripped. The local storage assertion was not shown to fail when a clear skips it. The real-relaunch check is left to the user: the
package test shows only that a second store instance over one identifier sees the cookie within one process.

ADR check: no conflicts. Its ADR-08 advisory is resolved by the cache above. None of the implementer's candidates passes: the UUID and the
required argument are mechanisms inside one component, and `describe()`'s cost is settled here. The fixed UUID stays a risk in the proposal.

Test cost: the new M5 tests take about 2 s together.

## Unowned failures

`make test-app` run `WWM5Y9` on 2026-11-06, 11:38 to 11:58 local, failed 22 tests with scattered focus and input errors, such as
a typed path arriving as `unite0rm-data` and the app leaving the foreground. The runner restarted three times. Another session's
`make ci`, run `38KZFC`, drove the same screen from 11:35 to 11:56, and reported a matching pattern. M2 touches only the browser,
and none of the 22 is a browser test. A filtered rerun of 6 tests passed. No crash report for uniterm appeared. The cause is
collision by correlation and by the other session's report, and is not proved by a clean full run yet. The full suite reruns when
the other session says the screen is free.

That full rerun came later, as `5W5MC3`, on 2026-11-06 from 12:34 to 12:48 local, with no other UI run on the screen. It covered
M2's code and M3's. It ran 103 tests with 1 failure, and that failure was M3's own, recorded under M3. All 22 earlier failures
passed, which supports the collision and settles that M2 did not cause them.

## Edits found and not made

- `spec/proposals/UTERM-013-shortcut-ownership-and-reopen.md` line 70: `proposals.py freeze` reports an added "Superseded in
  part by UTERM-016; see Decision Log." with origin `other`. This run did not make it.
