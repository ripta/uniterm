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
| UTERM-005 M2: Security indicator | IN PROGRESS | |
| UTERM-005 M3: Tabs | QUEUED | |
| UTERM-005 M4: Address bar input | QUEUED | |
| UTERM-005 M5: Website data, restore, and reopen | QUEUED | |
| UTERM-005 M6: Pop-ups, downloads, and running work | QUEUED | |
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

## Edits found and not made

- `spec/proposals/UTERM-013-shortcut-ownership-and-reopen.md` line 70: `proposals.py freeze` reports an added "Superseded in
  part by UTERM-016; see Decision Log." with origin `other`. This run did not make it.
