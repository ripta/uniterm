# UTERM-005: Browser Applet

**Status:** accepted
**Created:** 2026-10-31
**Updated:** 2026-11-03

## Dependencies

- UTERM-001
- UTERM-004, for "Control"

## Impacts

- UTERM-004 — "Control": adds browser navigation and browser read to its typed permission set

## Summary

A browser applet built on the system's WebKit. It has tabs, back, forward, and reload buttons, and an address bar with a
security indicator.

## Motivation

Docs, dashboards, and local dev servers often sit beside a terminal. A browser pane keeps them in the same window. It is
also the main target for remote control in UTERM-004, such as opening a page from a script.

## Design Decisions (Settled)

### WebKit

The applet uses `WKWebView`. It bundles no browser engine of its own.

No native bridge is reachable from a page's own script world. The one bridge, the unsent-input tracker, lives in an
isolated content world and accepts only a boolean per tab. Amended 2026-11-03; see Decision Log.

### Controls

- Back, forward, and reload buttons.
- An address bar. Typed addresses without a scheme default to HTTPS, except loopback, per "Local addresses and plain
  HTTP". Amended 2026-11-03; see Decision Log.
- A security indicator. A page that is not fully secure shows a warning icon.

### Schemes

Original question, raised by the review: no decision said which URL schemes the browser loads from each source.

Decision: a typed address, a restored tab, and a controller's command load only `http`, `https`, and `about:blank`.
A page may also open its own `blob:` URLs, and a download may come from any scheme but `javascript:`.

- A page's own navigation may load `http`, `https`, `about:blank`, and a `blob:` URL that page created, such as a
  generated PDF preview. WebKit already limits a `blob:` URL to the origin that made it.
- A navigation WebKit marks as a download proceeds as a download, per "Downloads", whatever its scheme except
  `javascript:`. That keeps `blob:` and `data:` exports working.
- `file:`, `javascript:`, and a top-level `data:` page are refused. The address bar says why.
- A link or typed address with another scheme that macOS maps to an app asks first, naming the app and the URL, and
  opens that app only on the user's yes. `mailto:` opens the mail app without asking.
- A restored tab whose URL is refused shows `about:blank` with a message naming the refused URL. It keeps the stored URL
  in its description until the user navigates.

Rationale: one rule for typed, restored, and controller input keeps a payload or a controller from reaching what the
address bar cannot. Dashboard exports and previews are `blob:` and `data:` URLs that exist only inside the page, so the
page's own downloads and previews must pass. Loading `file:` would need a file read scope, which the text viewer in
UTERM-007 owns. A top-level `data:` page is a known phishing vehicle. App URL handlers have a history of exploits, and a
page chooses the arguments, so a handoff waits for the user. A mail draft still needs the user to send it, so `mailto:`
skips the question.

### Tabs

The applet supports multiple tabs. Its tab bar follows the same rule as the terminal applet: hidden when there is only
one tab.

### Website data

Original questions:

- Whether all browser panes share one cookie and storage store, or each pane gets its own.
- Whether data persists across launches.

Decision: every browser pane shares one persistent website data store that belongs to the browser alone. Settings gets
a Clear Website Data action.

- The store is `WKWebsiteDataStore(forIdentifier:)` with a fixed UUID the browser owns. It is not WebKit's app-wide
  default store. The text viewer in UTERM-007 and the canvas in UTERM-010 also use WebKit, so they neither share the
  browser's logins nor lose their data when it is cleared.
- Every tab in every browser pane uses it. Logins carry across panes and survive relaunch.
- Descriptions carry no store reference, and the layout file holds no website data.
- Clear Website Data removes everything in the browser's store. It reloads no tab. Settings says that open tabs keep
  their current session until they are reloaded or closed.
- The store's UUID is a constant. Changing it would orphan every login and all site data, since WebKit cannot move data
  between stores. See Risks.
- Sharing is hidden state flow between panes: logging in in one pane logs in the others. CLAUDE.md asks for that to be
  an explicit decision. The user kept it at the review gate on 2026-11-03.
- The pane shows its active profile, so the sharing is visible. With one store, every pane shows the default profile,
  labelled "Default Profile" or similar. Where the label sits, and whether a profile selector appears on the new pane
  sheet or on the browser pane, are iterated with the user in hands-on review during M5. A second profile would need its
  own store, and its profile ID would flow through the pane's description, per CLAUDE.md "Applet Attributes". Adding
  one is a decision for the user, not an implementation detail. Chosen by the user on 2026-11-03.
- A browser pane a program creates uses the same store. "Control" decides what a controller may do with it.

Rationale: the motivation is docs and dashboards, and they need logins that last. Per-pane stores make every new pane
log in again. Their cleanup rule can also delete a store that only a kept-aside newer layout file names, which loses
site data. A non-persistent store logs out of every dashboard at each relaunch. Named profiles add a Settings list and a
new applet attribute that no current need calls for. Without a clear action, the user has no way to remove cookies.

### What restore loads

Original question, from "The applet contract": a description likely holds each tab's URL. Restoring it loads pages, and
a page can run scripts. Decide whether that counts as running a program under ADR-03, or whether restore shows the URL
and loads it only on request.

Decision: the open page is where a tab was, not running state, so restore reopens it. ADR-03 holds unchanged: what
runs in a page is never restored. Restore loads lazily and never resubmits a form. Amended 2026-11-03; see Decision
Log.

- In a terminal, the working directory is where the pane was, and a running program is state. Restore keeps the first
  and never restarts the second. In a browser, the tab's URL is where the tab was. The page's scripts, in-memory state,
  and form input are state. Restore keeps the URL and none of that state.
- Reopening a page loads it as a fresh visit, from WebKit's cache or from the network when the cache is stale. It does
  not bring back the page as it was.

- The layout payload stores each tab's last committed URL and title, and which tab is selected. It never stores
  back/forward history or form data.
- Restore loads only the selected tab of each pane, and only while the pane is attached. Other tabs load when first
  selected. A tab that has not loaded shows its stored URL and title.
- The undo-only part carries each tab's `interactionState`, so Cmd-Shift-T brings back a tab's or a pane's history
  within the session. The layout file never writes it, per UTERM-013.
- No restore path resubmits a form or replays a POST. That includes going back or forward through restored history.
- A restored URL passes the rule in "Schemes".
- The payload is stored data that every later build reads. ADR-06's per-type version defuses that one-way door: the
  browser upgrades its own older payloads, and an older build keeps a newer payload byte-for-byte.
- A GET with side effects, such as a confirm link, runs again when its tab is restored selected. See Risks.

Rationale: GET is a safe method under RFC 9110 §9.2.1, and browsers restore sessions this way. Showing each URL and
waiting costs one action per pane on every relaunch, which defeats restoring a browser. Splitting local from remote
URLs misses side-effecting remote GETs. A private host such as `app.test` also looks remote until DNS resolves it.
Lazy loading keeps a relaunch from loading every tab at once, and keeps detached panes quiet, per ADR-05.

### Search from the address bar

Original question: whether non-URL input runs a search, and with which engine.

Decision: input that is not an address runs a search. Settings picks the engine from a fixed list.

- Input with a scheme, or ending in `/`, is always an address. Input with a space is always a search. Other input is
  an address when it holds a dot, is `localhost`, is an IP address, or has a `host:port` form. Anything else searches.
- The list is DuckDuckGo, the default, then Google, Bing, Ecosia, and Kagi. It is an enum-backed setting key.
- The browser factory passes the applet a read-only view of this setting at construction. The applet reads the current
  engine each time it builds a search URL, so a change applies to the next search in every open pane. This is the first
  setting to reach an applet. It arrives through the factory explicitly, never through ambient UserDefaults reads.

Rationale: the search engine is a privacy choice, and users really do pick different ones, so it earns a setting. A
fixed list fits the existing enum-backed setting keys and needs no template validation. A free-form template is a knob
nobody asked for. A browser with no search makes users type full addresses, which no other browser asks.

### Local addresses and plain HTTP

Original question: whether `localhost` and plain IP addresses default to HTTP instead of HTTPS.

Decision: loopback defaults to HTTP. Every other scheme-less address tries HTTPS, and a failure offers plain HTTP only
by the user's action.

- `localhost`, `*.localhost`, `127.0.0.0/8`, and `[::1]` default to HTTP.
- Any other scheme-less load tries HTTPS. When it cannot connect, or the server does not speak TLS, the error page
  offers Load over HTTP and says the connection will be unencrypted. Nothing downgrades without that action.
- A certificate validation failure shows the certificate error, never the HTTP offer. A host under HSTS never shows it.
- One function applies this rule, for typed input and for any other scheme-less address.

Rationale: local dev servers are part of the motivation, and they almost never serve TLS on loopback. Loopback traffic
never leaves the machine. Defaulting private ranges or single-label names to HTTP would send a router password across a
shared LAN in cleartext without the user choosing it. Falling back to HTTP automatically lets anyone on the network
force any host down to cleartext. An offer limited to private IP literals would miss `app.test`, `nas.local`, and LAN
names, which look like any other host until DNS resolves them.

### New windows and pop-ups

Original question: what a link that opens a new window does: a new tab, a new pane, or blocked.

Decision: it opens a new tab in the same pane.

- The tab is built with the configuration WebKit passes to the UI delegate, so the opener relationship and the shared
  store hold. Sign-in pop-ups work.
- It opens right after the opener tab and is selected.
- A script-opened tab may close itself with `window.close()`.
- WebKit's macOS default blocks a script with no user gesture from opening a window. The browser keeps that default.
  No public API reports such a blocked attempt, so the browser shows no indicator for it.

Rationale: a tab keeps everything an OAuth flow needs, and fits the settled tab model. A new pane needs a new host call
for an applet to request a split, and a pane built around a web view WebKit supplies. Blocking every new window breaks
the sign-ins that the website data decision exists to keep. A blocked-pop-up indicator would need WebKit to report the
blocked attempt, or the browser to judge user gestures itself through a private interface.

### Downloads

Original question: where downloads go, and how the user sees them.

Decision: downloads go to the user's Downloads folder, each file quarantined on its own, with progress in the pane's
status bar.

- A file downloads under a temporary name and takes its final, unique name when complete. A failed or cancelled
  download removes its partial file.
- A finished download posts an info message naming the file. A failed download posts an error naming the file and the
  reason. One the user cancels posts nothing. The progress segment shows only for the focused pane, and a download can
  end while its pane is unfocused or detached, so the message is how the user learns the outcome. Amended 2026-11-05; see Decision Log.
- Each finished file gets quarantine properties naming its origin and data URLs. uniterm does not set
  `LSFileQuarantineEnabled`, which would apply to the whole process and could quarantine files the terminal's shells
  create.
- A status bar segment shows progress. Reveal Latest Download, in the Browser menu and the palette, shows the newest
  finished download in Finder. Segments and status messages stay plain, so the contract does not change.
- A download keeps going while the pane is detached.
- A download in progress counts as running something. Closing its pane asks first, and closing cancels it.

Rationale: dashboard exports are often `blob:` URLs that exist only inside the page, and authenticated downloads need
uniterm's store, so handing off to another browser fails. Refusing downloads breaks the same exports. A save panel for
every file adds a step for no gain over a unique name. Per-file quarantine keeps Gatekeeper's check on downloaded files
without touching anything else uniterm writes. Downloading under a temporary name keeps a crash from leaving a
truncated file that looks complete. Cancelling on close keeps ADR-05's rule without a bounded after-close indicator.

### Browser commands and keys

Original question, raised by the review: ADR-04 and UTERM-013 give each applet its own commands and keys, and no open
question covered which ones the browser declares.

Decision: the browser declares commands for the settled controls in UTERM-002's registry. Back and Forward have no
default key.

- New Tab, Cmd-T, in File. Open Location, Cmd-L, in File, focuses the address bar. Reload, Cmd-R, in View. Reloading
  the result page of a POST asks before resubmitting. So does the user going back or forward to one. Restore, recovery,
  and controller commands never resubmit at all.
- Select Next Tab, Cmd-Shift-], and Select Previous Tab, Cmd-Shift-[, in Window. Cmd-1 to Cmd-8 select a tab, and
  Cmd-9 is Select Last Tab. The titles match the terminal's, so a user's App Shortcuts remap covers both applets.
- Back and Forward sit in the applet menu, named Browser, with no default key. The toolbar buttons, trackpad swipes,
  and mouse buttons 4 and 5 also reach them.
- Cmd-W and Cmd-Shift-T stay uniterm's, per UTERM-013. Closed tabs ride in the undo-only part of the description at
  depth 20, and reopen by stamp.
- Find in page and zoom are not part of this proposal.

Rationale: Cmd-[ and Cmd-] are uniterm's reserved Focus Previous Pane and Focus Next Pane keys. Declaring them would
drop the keys and fail the built-in conflict test. Cmd-Left and Cmd-Right would take line navigation away from the
address bar and from web form fields, since an enabled applet item takes its key before the view. Moving uniterm's pane
keys is a cross-applet change that would need its own proposal.

### Control

Original question, "Control levels": which UTERM-004 levels the browser supports, and which commands it accepts, such as
navigate and reload. UTERM-004 has since replaced levels with two access modes and an independent exec driver.

Decision: the browser supports remote-controlled and disconnected, and no exec driver. Its commands need two browser
permissions of their own, and act only on tabs the controller opened.

- Exec is refused before anything starts, per UTERM-004.
- The commands are open a new tab with a URL, navigate, reload, back, forward, select a tab, and read URLs and titles.
- They need two new typed permissions in UTERM-004's framework. Browser navigation covers open, navigate, reload, back,
  forward, and select. Browser read covers URLs and titles. Their meaning says that navigation is network access signed
  in as the user, whatever the controller's own sandbox allows, and that read returns addresses that may carry tokens.
  The approval review says so for navigation alone, too. A pane-control approval stored before these permissions
  existed cannot cover them, since ADR-09 says a change in permission meaning cannot increase an existing approval.
- Open and navigate accept only what "Schemes" allows, checked after parsing the URL. No command evaluates script in a
  page.
- A tab opened by open belongs to that controller for its live grant, even after the user types in it. The pane's
  remote-control marker shows that the pane is driven. Navigate, reload, back, forward, select, and read act only on
  such tabs. Aimed at any other tab, they return a structured error. A tab a page opens from a controller tab, a tab
  reopened with Cmd-Shift-T, and a restored tab belong to no controller.
- Commands never take keyboard focus. While the pane holds key focus, open creates its tab without selecting it, and
  select is refused with a structured error. A background tab a controller opens loads at once while the pane is
  attached.
- Navigate, reload, back, and forward are refused with a structured error when the target is the selected tab of a pane
  that holds key focus, or a tab that holds unsent input per "Unsent input". The controller owns retrying.
- The two permissions follow UTERM-004's versioned permission meanings and admission. An old controller on a new build,
  and a new controller on an old build, refuse unsupported semantics before any effect. The structured errors are new
  error codes in UTERM-004's existing error shape.
- Controller reload, back, and forward never resubmit a form.
- In a controller tab, a download, or a navigation to a non-web scheme that would open another app, asks the user
  first.
- A browser pane created by a layout request starts at `about:blank`. A URL seeded through a layout request needs
  browser navigation and passes the same scheme check.

Rationale: under plain pane control, a script that UTERM-003 denies network access could reach the network through a
browser pane it created, and read pages signed in as the user. ADR-09 keeps one power from silently granting another, so
browser access is its own permission. Keeping commands to the controller's own tabs protects the user's tabs. Refusing
to navigate the focused tab protects what the user is typing, including drafts the unsent-input tracker misses. Its cost is a
stale page, which the controller's retry or Cmd-R recovers. A development-reload flow is unaffected, since the user
saves from another pane and the browser pane does not hold key focus. Refusing control entirely would leave the
motivation's main use undone. No current caller needs an exec driver, and its event stream would hand the user's later
browsing to the driver. Exec support can be added later as a new combination.

UTERM-004 reaches only browser panes a program created, since a program addresses its source pane and the groups it
owns. Telling the nearest browser pane to open a page therefore works for a program's own browser panes, not ones the
user made.

### The applet contract

Original context and question: context from UTERM-001, which shipped the applet contract. ADR-05 and ADR-06 cover its lifecycle and its description
versioning. An ADR for the rest of the contract is a candidate in UTERM-001's Decision Log. This proposal may reshape
it, so it is not written yet. Every applet implements:

- A view the pane hosts, a title, and status bar segments.
- `start`, `focus`, and a palette update.
- `detach`, `reattach`, and `close`. uniterm sends these lifecycle events, and each applet owns its response, per
  ADR-05. On detach an applet pauses audio, video, and alerts at once. uniterm keeps no closed applet alive. An applet
  that keeps work going after close owns its bound and a visible indicator.
- `isRunningSomething` and `runningLabels`. Closing a pane, a window, or the app asks first when an affected pane is
  running something, and the dialog names it.
- `describe()`, an inert description with a type and a per-type version. Undo and layout restore both rebuild the
  applet from it, in the same place. Undo is not a snapshot of running state. An applet that wants undo to bring back
  more saves it in its description. ADR-03 says restoring it never runs a program the user did not ask for. ADR-06
  says the applet owns its payload and its version. It upgrades its own older versions, and bumps the version on any
  change an older build cannot round-trip. A description this build cannot read is kept byte-for-byte.

For the browser: a description likely holds each tab's URL. Restoring it loads pages, and a page can run scripts.
Decide whether that counts as running a program under ADR-03, or whether restore shows the URL and loads it only on
request. Also decide what counts as running something, such as a download or a form with unsent input. On detach the
browser pauses media, per ADR-05.

Decision: the browser needs no change to the applet contract. The host gains what any new applet type needs: a launcher
entry, an applet choice, and a restorer branch for the browser's type, as UTERM-009 does for the data viewer. The
factory also passes the browser the search engine setting, per "Search from the address bar". Restore is settled in
"What restore loads".

- The description payload holds each tab's last committed URL and title, and the selected tab, with its own version per
  ADR-06. The undo-only part holds each tab's `interactionState` and the closed-tab list.
- `currentDirectory` is nil. A browser pane has no directory, and a pane split from it starts in the launcher's default.
- On detach, the browser suspends media playback in every tab and holds back JavaScript alerts and confirmations until
  reattach. Downloads keep going. Reattach resumes nothing on its own: the user starts paused media again.
- Running something: see "Unsent input" and "Downloads". `runningLabels` names each such tab by title, and a download
  by file name.

Rationale: the data viewer in UTERM-009 also needed no contract change, and the browser's needs fit the same contract.
Holding alerts follows ADR-05's rule for what the user would notice but cannot see. Leaving media paused on reattach
keeps a pane coming back into view from starting sound the user did not ask for.

### Unsent input

Original question, from "The applet contract": what counts as running something, such as a download or a form with
unsent input.

Decision: a tab counts as running something while it holds edited form input that differs from its defaults. An
isolated-world script tracks it. A download in progress also counts, per "Downloads". Nothing else does.

- A `WKUserScript` in an isolated `WKContentWorld`, in every frame, listens at document level in the capture phase for
  trusted `input` events. That covers `contenteditable`.
- A tab is marked while some edited field differs from its default value. The mark clears on load, on submit, and when
  the fields return to their defaults. Fields are re-checked on `focusout`, and after `submit` or `click`.
- The script reports one boolean per tab through a message handler in that isolated world. The native side accepts
  nothing else from it. Page scripts cannot reach the handler.
- The mark clears when the tab's content process terminates, since the input is already gone.
- It misses drafts a page keeps only in script. "Control" guards the focused tab for that reason.

Rationale: closing a pane with a half-written comment loses it without asking unless something notices. Counting native
keystrokes cannot tell typing from scrolling or j and k shortcuts, so nearly every close and quit would ask, and the
quit dialog would teach the user to click through terminal warnings too. Counting playing media adds frequent prompts for
work a reload recovers. The tracker narrows the proposal's "no native bridge to page scripts" line to a bridge the page's
own world cannot reach.

### Web content failure

Original question, raised by the review: ADR-07 requires each applet hosting code uniterm does not control to show how
its failures are contained, and no open question covered the browser's.

Decision: a failed tab shows a stopped-page message, and recovery always rebuilds the tab's web view from its URL.

- WebKit runs page content in a separate process, so a crash, a memory kill, or a hang stays out of uniterm's process.
- When a tab's content process terminates while the tab is selected in an attached pane, the tab shows a message that
  the page stopped, with a Reload action. Otherwise the tab returns to the not-yet-loaded state of "What restore
  loads", and loads when next selected.
- Reload builds a new web view from the tab's URL and its last `interactionState`, the same way reopen builds a tab, so
  the tab keeps its history. It never asks the old process.
- A user reload or navigation that gets no answer from the content process within a fixed bound replaces the web view
  the same way. There is no background timer.
- No recovery resends a POST.
- Each tab handles its own termination. A pop-up tab may share its opener's process, so both can stop together.

Rationale: a hung process may never handle a `reload()`, so rebuilding the web view is the recovery that always works,
and the restore path already builds tabs that way. Reloading automatically after a memory kill would load tabs nobody is
looking at, wake detached panes against ADR-05, and push memory straight back up. A background probe wakes every tab
for a signal that a user's own reload already gives. Closing a failed tab throws away its place for a failure that is
usually recoverable.

## Design Decisions (Open)

None.

## Risks

- **Web content is untrusted input inside the app** — likelihood: high, impact: medium.
  Mitigation: WebKit runs content out of process, per "Web content failure". No native bridge is reachable from a
  page's own script world, per "WebKit". A compromised content process can still post to the isolated tracker's
  handler, which accepts only a boolean per tab.
- **One website data store serves every browser pane** — likelihood: high, impact: low. Logging in in one pane logs in
  every pane, including panes a program created. Accepted: sharing is the explicit choice in "Website data", for logins
  that last. What a controller may do with it is gated by "Control".
- **Controller navigation acts as the user** — likelihood: medium, impact: high. A controller's GET carries the user's
  cookies, so it can trigger a side-effecting GET on a site or on a `localhost` service. Mitigation: browser navigation
  is its own permission, and its approval review says it is network access signed in as the user, per "Control".
  Commands reach only the controller's own tabs.
- **Restore repeats a side-effecting GET** — likelihood: medium, impact: low. A selected tab restored on a confirm or
  unsubscribe link sends that GET again at relaunch. Accepted: GET is a safe method under RFC 9110, single-use links
  fail harmlessly on reuse, and lazy loading limits it to one tab per attached pane.
- **Tab URLs in the layout file can carry tokens** — likelihood: medium, impact: medium. OAuth codes, signed-URL tokens,
  and session IDs in a URL are written to disk in the layout file. Accepted: the layout file sits in the user's own
  Library, like a shell history or a browser's session file. Controller reads, which cross a trust boundary, are gated
  by "Control".
- **The store's fixed UUID is a one-way door** — likelihood: low, impact: medium. Changing the UUID, or the bundle ID
  that scopes it, orphans every login and all site data. Accepted: the UUID is a constant that nothing changes, and the
  loss is recoverable by logging in again.
- **Single-label names go to the search engine** — likelihood: medium, impact: low. Typing an intranet name such as
  `devbox` sends it to the chosen engine. Accepted: the user types `devbox/` or `http://devbox` to go there, per
  "Search from the address bar", and picks the engine.
- **Any page can write files to Downloads** — likelihood: medium, impact: low. A page can start a download with no
  prompt. Accepted: each file is quarantined, so Gatekeeper checks it before it runs, and the status bar shows every
  download.
- **The control permissions depend on an amendment to accepted UTERM-004** — likelihood: medium, impact: medium. Until
  UTERM-004 names browser navigation and browser read, its permission set and this proposal disagree. Mitigation: M8
  starts only after UTERM-004 M6, and its first check requires the amendment.
- **Two WebKit applets have not chosen their stores** — likelihood: low, impact: low. UTERM-007 and UTERM-010 are drafts.
  Accepted: the browser's store is its own, so whatever they choose cannot share or clear it.

## Milestones

### M1: Single-page browser

**Status:** NOT STARTED

- A pane can run the browser applet and load a typed address
- Back, forward, and reload work
- An address typed without a scheme loads over HTTPS, except loopback, which loads over HTTP
- The launcher offers the browser, and restore picks the browser by its description type

### M2: Security indicator

**Status:** NOT STARTED

- A page with any insecure content shows a warning icon in the address bar
- A fully secure page shows no warning

### M3: Tabs

**Status:** NOT STARTED

- The browser opens, switches, and closes tabs
- The tab bar is hidden when only one tab is open
- New Tab, Open Location, Reload, and tab selection work from their default keys, and the built-in key conflict test
  passes
- Back and Forward work from the Browser menu, the toolbar, trackpad swipes, and mouse buttons 4 and 5
- Cmd-W closes the current tab, and Cmd-Shift-T reopens it in its former place with its history. A pane keeps at most
  20 closed tabs
- Cmd-R, Back, or Forward onto the result page of a POST asks before resubmitting

### M4: Address bar input

**Status:** NOT STARTED

- Non-address input searches with the engine chosen in Settings, and a change applies to the next search in every open
  pane
- `devbox` searches, while `devbox/`, `localhost:3000`, and `devbox:8080` load as addresses. Input whose text after the
  colon is only digits is `host:port`, even when an app has registered that word as a URL scheme
- A scheme-less loopback address, `*.localhost` included, loads over HTTP
- A scheme-less address whose HTTPS load cannot connect, or whose server does not speak TLS, offers Load over HTTP. A
  certificate failure or an HSTS host never offers it
- A typed `mailto:` address opens the mail app. A link or typed address for another app asks first, naming the app. A
  typed `file:`, `javascript:`, or `data:` address loads nothing, and the address bar says why. So does a scheme no app
  handles
- A tab shows at most one pending app-handoff question, and the question never blocks other panes
- A stored engine that is no longer on the list shows in Settings as replaced by the default

### M5: Website data, restore, and reopen

**Status:** NOT STARTED

- Logins carry across browser panes and survive relaunch, in a store separate from WebKit's default store
- Every browser pane shows its active profile, the default profile, and the user confirms its placement in a hands-on
  review
- Clear Website Data removes the browser's stored data and reloads no tab, and Settings says open tabs keep their
  session until reloaded or closed
- Layout restore loads only the selected tab of each attached pane. An unselected tab shows its stored URL and title,
  and loads when first selected. A detached pane loads nothing until it is attached. The layout file holds no history
  and no form data
- A restored tab whose URL has a scheme other than `http`, `https`, or `about:blank` shows `about:blank` and a message
  naming the URL, and its description keeps that URL until the user navigates
- A browser pane reports no current directory, and a pane split from it starts in the launcher's default
- Going back or forward through reopened history never resubmits a form

### M6: Pop-ups, downloads, and running work

**Status:** NOT STARTED

- A link or script that opens a window opens a tab right after its opener, selected. A script never closes the last tab
  or the pane. When a pop-up tab closes itself, selection returns to its opener while the opener exists
- A sign-in pop-up keeps its opener relationship and completes its flow
- The web view's context menu offers Open Link in New Tab, not New Window
- A download lands in Downloads under a unique name, quarantined with its origin, and uniterm does not set
  `LSFileQuarantineEnabled`. While it runs, the file has a temporary name. A failed or cancelled download leaves no
  file. A suggested name with path separators, `..`, a leading dot, or bidirectional overrides is cleaned. Two
  downloads never take the same name
- The status bar shows a download's progress, the download keeps going while the pane is detached, and Reveal Latest
  Download shows the focused pane's newest finished file in Finder. It is unavailable with no finished download, and a
  moved or deleted file gets a status message
- A finished download posts an info message naming it, and a failed one posts an error. A cancelled one posts nothing.
  Amended 2026-11-05; see Decision Log.
- A `blob:` or `data:` download from a page saves like any other, with or without a `download` attribute, and a page's
  own `blob:` preview opens in its tab. A page's `file:` link saves nothing, even marked as a download
- `srcdoc` and `data:` subframes load, while a top-level `data:` page is refused
- A script or iframe navigation to an app's scheme asks or is refused, and never launches the app silently
- Closing a tab or a pane during a download asks first, names the file, and cancels it. Navigating the tab away does
  not cancel it
- A tab with edited form input, in any frame or in a `contenteditable`, asks before close and is named in the dialog. It
  stops asking once the input is submitted or back at its defaults. Synthetic input events never mark a tab, and page
  scripts cannot reach the tracker's handler
- Detach suspends media and holds alerts until reattach. Reattach does not resume media. Closing a detached pane
  answers every held alert

### M7: Web content failure

**Status:** NOT STARTED

- Killing a selected tab's content process shows the stopped-page message, and Reload brings the page back with its
  history
- Killing an unselected tab's content process leaves it not yet loaded, and selecting it loads the page
- A page that hangs its content process comes back on Reload
- No recovery resends a POST, and a stopped tab no longer counts as running something

### M8: Remote control

**Status:** NOT STARTED

Starts after UTERM-004 M6.

- UTERM-004's permission set names browser navigation and browser read before the browser accepts any command
- A controller with pane control alone gets a structured error from every browser command, and so does one whose stored
  approval predates the browser permissions. Browser navigation and browser read each unlock only their own commands
- A URL seeded through a layout request needs browser navigation and passes "Schemes"
- The approval review says that navigation is network access signed in as the user, and that read returns addresses
- Open and navigate refuse `javascript:`, `data:`, and `file:` URLs, in any letter case and with surrounding whitespace
- Navigate, reload, back, forward, select, and read on a tab the controller did not open return a structured error. A
  controller tab stays the controller's after the user types in it. A tab a page opened from it, a reopened tab, and a
  restored tab belong to no controller
- Open never moves keyboard focus: in a key-focused pane its tab opens unselected and loads at once, and select is
  refused. Navigate, reload, back, and forward on the selected tab of a key-focused pane, or on a tab with unsent input,
  return a structured error
- Controller reload, back, and forward never resubmit a form
- A download, or a link to another app, `mailto:` included, in a controller tab asks the user first
- A browser pane created by a layout request starts at `about:blank`
- Exec is refused before anything starts

## Decision Log

- 2026-10-31: Drafted from the original write-up without an interview. The open questions hold everything undecided.
- 2026-11-01: Added "The applet contract" with context from UTERM-001's implementation.
- 2026-11-03: Review start: 3 milestones, 3 settled decisions, 2 risks, no `**Live after:**` lines or row gates; one
  out-of-scope statement, no native bridge to page scripts; as of the commit "Make undo reopen from the description, and
  let applets own lifecycle". The user asked for a full autonomous review of the open questions.
- 2026-11-03: Website data: one persistent store owned by the browser and shared by every browser pane, with Clear
  Website Data in Settings. Converged in 1 pass. (autonomous)
- 2026-11-03: Restore loads each pane's selected tab lazily with a GET, never resubmits a form, and keeps history in the
  undo-only part. A page load is not running a program under ADR-03. Converged in 1 pass. (autonomous)
- 2026-11-03: Non-address input searches, with the engine picked from a fixed Settings list and passed to the applet by
  its factory. Converged in 1 pass. (autonomous)
- 2026-11-03: Loopback defaults to HTTP. Other scheme-less addresses try HTTPS and offer HTTP only by the user's action,
  never after a certificate failure. Converged in 1 pass. (autonomous)
- 2026-11-03: A link or script that opens a window opens a tab in the same pane. Pop-ups with no user gesture stay
  blocked by WebKit's default, with no indicator. Converged in 1 pass. (autonomous)
- 2026-11-03: Downloads go to Downloads under a temporary name, are quarantined per file, show in a status bar segment,
  and count as running something. Converged in 1 pass. (autonomous)
- 2026-11-03: The browser declares New Tab, Open Location, Reload, and tab selection with default keys, and Back and
  Forward with none, since Cmd-[ and Cmd-] are reserved. Converged in 1 pass. (autonomous)
- 2026-11-03: Control: remote-controlled and disconnected, no exec. Two new typed permissions, browser navigation and
  browser read. Commands act only on the controller's own tabs, never take focus, and never navigate the selected tab
  of a key-focused pane. Judge after 3 passes, budget trigger: chosen over the same design without the focused-tab
  guard, because that one can discard input the user is typing. Dissent left standing: none. The two permissions amend
  accepted UTERM-004. (autonomous, judge, addition)
- 2026-11-03: A tab with edited form input counts as running something, tracked by an isolated-world script that
  reports one boolean. Narrows the out-of-scope "no native bridge to page scripts" line to a bridge the page's own world
  cannot reach. Converged in 1 pass. (autonomous, addition)
- 2026-11-03: A failed content process shows a stopped-page message for a visible tab, and returns other tabs to not
  yet loaded. Recovery rebuilds the web view from the URL. Converged in 1 pass. (autonomous)
- 2026-11-03: The applet contract needs no change. The factory passes the search setting. Detach suspends media and
  holds alerts. (autonomous)
- 2026-11-03: UTERM-001's candidate ADR for the rest of the applet contract: this proposal does not reshape the
  contract, so nothing here holds it back.
- 2026-11-03: Added M4 to M8 so that every settled decision has a milestone that builds it, and routed the review's
  implementation-level findings to their checks. (autonomous)
- 2026-11-03: ADR candidate (departs from the past): loading a page's top-level URL with a GET is not running a program,
  as a second exception beside shell mode, superseding ADR-03. Declined on 2026-11-03: it fails the Decision test,
  since the browser applies ADR-03's principle and decides nothing new. ADR-03 rules that restored state never runs a
  program. Its terminal bullets apply that rule, and are not a list of exceptions.
- 2026-11-03: Coherence review. Amended "Controls": it said "Typed addresses without a scheme default to HTTPS"; loopback
  now defaults to HTTP, per "Local addresses and plain HTTP". Amended "WebKit" to carry the narrowed out-of-scope line:
  the review's unsent-input tracker had replaced "Expose no native bridge to page scripts in this proposal" in Risks with
  no out-of-scope statement left. Added "Schemes". Clear Website Data reloads no tab, since a reload could lose unsent
  input or resubmit a form. Reveal moved from the download segment to a command, since segments carry no action. The
  contract decision now names the launcher, choice, and restorer the host gains. Control also refuses select in a
  key-focused pane and any navigation of a tab with unsent input, and states its skew. Web content recovery keeps
  history. Rewrote Risks to the standard, adding eight risks. Dropped M4's routed DNS lookup for single-label names and
  its `*.localhost` resolution condition, which no decision covered. (autonomous)
- 2026-11-03: Re-check. "Schemes" lets a page open its own `blob:` URLs and lets a download come from any scheme but
  `javascript:`, so exports keep working. A handoff to another app asks first, except `mailto:`. Reload of a POST result
  asks before resubmitting. (autonomous)
- 2026-11-03: Proposal loop converged in 3 passes. Risk review: every risk carries a likelihood, an impact, and a
  mitigation or acceptance, and none is high likelihood with high impact. (autonomous)
- 2026-11-03: Review gate: kept all. The user kept the shared website data store as an explicit choice, and added a
  visible active-profile label on each browser pane, showing the default profile for now. The label's placement and a
  possible profile selector are iterated during M5. (addition)
- 2026-11-03: Amended "What restore loads". It said "loading a page's top-level URL with a GET is not running a program
  under ADR-03". The user reframed it by what counts as state: the open page is where a tab was, and the page's running
  state is never restored. ADR-03 stays unchanged.
- 2026-11-03: Accepted by the user.
- 2026-11-03: Scheduled as UTERM-005 M1-M7 and UTERM-005 M8 in queue.md.
- 2026-11-05: Downloads report their outcome in the status bar, after a status bar audit. The text gave progress a
  segment and said nothing about the end. A segment shows only for the focused pane, and a download can finish while
  its pane is unfocused or detached. A finished download now posts info, and a failed one posts an error, each naming
  the file. A cancelled one posts nothing, since the user chose it.

## References

- Original write-up: `~/projects/private_specs/uniterm/spec/research/original-writeup.md`, APPLET-3
