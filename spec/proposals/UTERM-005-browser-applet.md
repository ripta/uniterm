# UTERM-005: Browser Applet

**Status:** accepted
**Created:** 2026-10-31
**Updated:** 2026-11-06

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
- `file:`, `javascript:`, and a top-level `data:` page are refused. A typed address leaves the page visible, posts one
  warning that says why, and marks the address input invalid.
- A link or typed address with another scheme that macOS maps to an app asks first, naming the app and the URL, and
  opens that app only on the user's yes. `mailto:` opens the mail app without asking. A scheme no app handles loads
  nothing, posts one warning, and marks a typed address invalid.
- Only an address the user typed, or a link the user really clicked, may open an app or ask. A click counts when the web
  view saw a real mouse-up within one second before the navigation was decided, and each mouse-up is used once. WebKit
  reports a script's click as a followed link, so the navigation type alone proves nothing. A script's click, a
  script's navigation, a redirect, an iframe, and a key press that activates a focused link are refused with a warning
  and never open an app or ask. The same guards cover `mailto:`. The pane shows at most one question at a time, of any
  kind, and only the selected tab asks or opens. A request that finds another question up is refused with a warning. The question goes through
  the host's confirmation, so it never blocks another pane.
- A restored tab whose URL is refused shows `about:blank` with a durable explanation in the pane that names the refused
  URL, and the history records one warning. It keeps the stored URL in its description until the user navigates.
  Amended 2026-11-06; see Decision Log.

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
- Clear Website Data removes everything in the browser's store and empties the browser's own list of HTTPS-only
  hosts, per "Local addresses and plain HTTP". It reloads no tab. Settings says that open tabs keep their current
  session until they are reloaded or closed. It asks nothing, disables its button while a clear runs, and reports the
  outcome in Settings. A clear that could not empty the list of HTTPS-only hosts says so and never reads as a
  success.
- The store's UUID is a constant. Changing it would orphan every login and all site data, since WebKit cannot move data
  between stores. See Risks.
- Sharing is hidden state flow between panes: logging in in one pane logs in the others. CLAUDE.md asks for that to be
  an explicit decision. The user kept it at the review gate on 2026-11-03.
- The pane shows its active profile, so the sharing is visible. With one store, every pane shows the default profile.
  M5 puts a profile button at the trailing end of the browser's own toolbar. Its icon is the SF Symbol
  `person.crop.circle`. Clicking it shows a transient popover that names "Default Profile" and says every browser pane
  shares the profile's logins and site data. The popover has no controls yet. The user expects it to hold creating and
  switching profiles later. Whether a profile selector also appears on the new pane sheet stays open. A second profile would need its own store, and its profile ID would flow
  through the pane's description, per CLAUDE.md "Applet Attributes". Adding one is a decision for the user, not an
  implementation detail. Chosen by the user on 2026-11-03. Amended 2026-11-06; see Decision Log.
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
runs in a page is never restored. Restore loads lazily and never resubmits a form.

- In a terminal, the working directory is where the pane was, and a running program is state. Restore keeps the first
  and never restarts the second. In a browser, the tab's URL is where the tab was. The page's scripts, in-memory state,
  and form input are state. Restore keeps the URL and none of that state.
- Reopening a page loads it as a fresh visit, from WebKit's cache or from the network when the cache is stale. It does
  not bring back the page as it was.

- The layout payload stores each tab's last committed URL and title, and which tab is selected. It stores a URL only
  when "Schemes" lets a restored tab load it, so a committed `blob:` page is not stored. A URL over 32 KiB is not
  stored, and a title is cut to 512 characters. A tab keeps the value it last stored when a commit is not storable. It
  never stores back/forward history or form data. A restored URL that "Schemes" refuses stays in the description
  unchanged until the user navigates, since only a commit writes a URL.
- Restore loads only the selected tab of each pane, and only while the pane is attached. Other tabs load when first
  selected. A tab that has not loaded shows its stored URL and title.
- The undo-only part carries each closed tab's `interactionState` and a record for each open tab, so Cmd-Shift-T
  brings back a tab's or a pane's history within the session. The layout file never writes it, per UTERM-013. A tab
  that has loaded nothing carries no record, and one reopened but not yet loaded keeps the record it was given.
  Amended 2026-11-06; see Decision Log.
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
  Amended 2026-11-06; see Decision Log.
- A space wins over a trailing `/` and over a `word:` prefix, so `note: buy milk` and `my notes/` search. Only text that
  starts with `scheme://` stays an address when it holds a space. Text after the colon that is only digits is a port,
  even when an app registered the word as a scheme. `localhost` is read by its host part, so `localhost/app` is an
  address. A bare IPv6 address loads in brackets. Text with a control character other than whitespace is refused, not
  searched. Runs of whitespace collapse to one space in a query. Only typed text searches. A restored or commanded
  address that is not an address is refused.
- A query is percent-encoded as UTF-8, with only unreserved characters left bare, so `&`, `=`, `+`, `#`, and `%` stay
  inside the one query parameter.
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
  Amended 2026-11-06; see Decision Log.
- The offer shows only when the load that failed is the address whose HTTPS the browser assumed, so a redirect to
  another host never earns it. It shows for a refused or lost connection and for a server that does not speak TLS. It
  never shows for a certificate failure, however WebKit words the error. The pane shows the failure natively, so no
  page's script can reach the action. An explicit `https://` that fails shows a plain warning.
- WebKit has no public way to ask whether a host is under HSTS. The browser records `Strict-Transport-Security` from
  main-frame HTTPS responses in its own list, which honours `max-age`, `max-age=0` removal, and `includeSubDomains`,
  and which survives relaunch. A listed host never shows the offer. A host WebKit has preloaded but the browser has
  not seen can still show it, and the load stays HTTPS, since WebKit upgrades it, so nothing downgrades.
- One function applies this rule, for typed input and for any other scheme-less address. Load over HTTP resolves the
  typed text again through it, with HTTP as the only difference.

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
- A script with no user gesture opens nothing. WKWebView's macOS default lets such a script open a window, so the
  browser sets `javaScriptCanOpenWindowsAutomatically` to false. No public API reports a blocked attempt, so the browser
  shows no indicator for it. Amended 2026-11-06; see Decision Log.
- A script with a gesture may open many windows, so a pane holds at most ten tabs that scripts opened before it asks.
  WebKit needs an answer at once, so the eleventh call is refused and its address is remembered, at most 50 per page.
  The pane then asks the user, through the host's confirmation, whether the page may open more. Yes opens every
  remembered address as an ordinary new tab with no opener, unselected and in order, and lets that page open tabs freely
  until its next load. No drops the list, posts one warning, and refuses the page's further calls with no further
  question until its next load. Calls made while the question is up are refused and remembered too. A page that finds
  another question up keeps its list and is asked once the pane is free. A late answer to a page that loaded again or a
  pane that closed does nothing. A tab the user's own click on a link or choice from the context menu opens never counts
  toward the limit and is never refused for it. Amended 2026-11-06; see Decision Log.
- A pop-up from a tab the user is not looking at opens beside its opener, unselected, and says so. It never takes the
  selection or the keyboard.
- `window.close()` closes only a tab a script opened, never the last tab or the pane. A tab that holds unsent input or
  a download stays open and says why. A tab a script closes is not kept for reopening, since a sign-in address can
  carry a one-time code.

Rationale: a tab keeps everything an OAuth flow needs, and fits the settled tab model. A new pane needs a new host call
for an applet to request a split, and a pane built around a web view WebKit supplies. Blocking every new window breaks
the sign-ins that the website data decision exists to keep. A blocked-pop-up indicator would need WebKit to report the
blocked attempt, or the browser to judge user gestures itself through a private interface.

### Downloads

Original question: where downloads go, and how the user sees them.

Decision: downloads go to the user's Downloads folder, each file quarantined on its own, with progress in the pane's
status bar.

- A file downloads under a temporary name and takes its final, unique name when complete. A failed or cancelled
  download removes its partial file. Every file operation runs off the main thread, since the folder can be on a
  network or iCloud volume. A folder that cannot take the quarantine mark fails the download at its end, and the
  warning names the reason. The first download of a launch into a folder sweeps its leftover temporary files that are
  more than seven days old.
- A finished download posts an info message naming the file. A failed download posts a warning naming the file and the
  reason, since no user work is lost. One the user cancels posts nothing. The progress segment shows only for the
  focused pane, and a download can end while its pane is unfocused or detached, so the message is how the user learns
  the outcome. A detached pane withholds the message, records the outcome in the history when it happens, and presents
  it on reattach.
- Each finished file gets quarantine properties naming its origin and data URLs. uniterm does not set
  `LSFileQuarantineEnabled`, which would apply to the whole process and could quarantine files the terminal's shells
  create.
- A status bar segment shows progress. Reveal Latest Download, in the Browser menu and the palette, shows the newest
  finished download in Finder. Segments and status messages stay plain, so the contract does not change.
- A download keeps going while the pane is detached.
- A page's downloads that no click of the user's started count per load. The first three start as before. The fourth
  holds its policy decision and the pane asks, through the host's confirmation, whether the page may download more,
  naming the page and the file when it is known. Yes starts it and lets the page download until its next load. No
  cancels it at the decision, before WebKit starts a download, posts one warning, and cancels the page's further such
  downloads with no further question until its next load. A click on a link, a typed address, and a load the user asked
  for never count and never ask. The decisions held for the question resolve as cancelled when the tab or the pane
  closes or the page loads again. At most 16 wait. A page that finds another question up keeps its held decisions
  and is asked once the pane is free. Amended 2026-11-06; see Decision Log.
- A download in progress counts as running something. Closing its tab or its pane asks first, and closing cancels it.
  Navigating the tab away does not cancel it.
- A `blob:` download saves with or without a `download` attribute. A `data:` download saves with one. A top-level
  `data:` navigation with none is a page, which "Schemes" refuses. Amended 2026-11-06; see Decision Log.

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
  the result page of a POST asks before resubmitting. So does the user going back or forward to one. Only the browser's
  own Reload, Back, and Forward ask: the toolbar, the Browser menu, the commands, and mouse buttons 4 and 5. They ask
  only about a post this tab saw a form produce. A page's script, a trackpad swipe, a background tab, and a tab restored
  or reopened from history are refused with a notice and no question. Restore, recovery, and controller commands never
  resubmit at all. Amended 2026-11-06; see Decision Log.
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
factory also passes the browser the search engine setting, per "Search from the address bar", the list of HTTPS-only
hosts, and the opener for other apps. The host also passes each pane the browser's website data store, with no
default. Restore is settled in "What restore loads".

- The description payload holds each tab's last committed URL and title, and the selected tab, with its own version per
  ADR-06. The undo-only part holds a history record for each open tab, and the closed-tab list with each closed tab's
  `interactionState`.
- `currentDirectory` is nil. A browser pane has no directory, and a pane split from it starts in the launcher's default.
- On detach, the browser pauses and suspends media playback in every tab and holds back JavaScript alerts, confirmations,
  and prompts until reattach. Downloads keep going. Reattach resumes nothing on its own: the user starts paused media
  again. A dialog shows inside the pane, never as a window sheet, and a dialog from a tab in the background waits for
  its tab. From a page's second dialog in one load, the overlay offers "Don't show more from this page". Choosing it
  answers the dialog as Cancel would, and every later dialog from that page is dismissed until its next load, with one
  warning. There is no count limit, and at most 16 dialogs wait. Amended 2026-11-06; see Decision Log.
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
- Each frame's script reports one boolean through a message handler in that isolated world, with a random token that
  names the frame. The native side accepts nothing else from it, and the tab is marked while any frame is. One frame's
  report never clears another's. Page scripts cannot reach the handler. Amended 2026-11-06; see Decision Log.
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
  loads", and loads when next selected or attached. A tab that never held a page stays blank and shows no message.
- Reload builds a new web view from the tab's URL and its last `interactionState`, the same way reopen builds a tab, so
  the tab keeps its history. A tab that holds a history record and no URL, such as a pop-up that opened on a `blob:`
  preview, loads from the record alone. It never asks the old process. A pop-up's rebuilt view has no opener, which cannot be kept.
- A user reload or navigation that gets no answer from the content process within a fixed bound replaces the web view
  the same way. There is no background timer. The bound is 10 seconds on a clock that stops while the machine sleeps. It
  arms only on that user action, and any callback from the content process cancels it, so a slow server never fires
  it. A page that holds a dialog is waiting for the user, so the bound never replaces it. A page that holds unsent
  input may only be busy, so the user is asked first and the page is replaced only on yes. A bound that runs out on a
  tab the user is not looking at, or in a detached pane, drops the view and loads nothing until the tab is selected or
  attached. In the tab the user is looking at, a typed address then loads in the new web view, and a reload, back, or
  forward loads the page again.
- When the bound replaces a hung view, the tab ends that view's content process with SIGKILL first, so the new view
  cannot land in a process that still spins. A tab that shares the process recovers as from any stopped process. A tab
  or pane the user closes arms no bound, so the close probes the page with a trivial script call. No reply within the same
  bound ends the process, and a reply or an error that says the process ended cancels it. The web view is kept alive only
  until the probe settles. A closed tab with no web view starts no probe. The process id is read before the view is
  released. The read uses a private WebKit property, so a macOS that drops it leaves the old behaviour. See Risks.
  Amended 2026-11-06; see Decision Log.
- No recovery resends a POST.
- A stop clears the tab's unsent mark and answers its held dialogs and questions. A download belongs to the network
  process, so it keeps running and still asks on close. A page that came from a form comes back blank, since showing it
  would send the form again, and the pane says so before and after Reload. Amended 2026-11-06; see Decision Log.
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
  handler, which accepts only a frame token and a boolean, keeps at most 64 marked frames, and keeps the tab marked
  when it drops one.
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
  prompt, and a hidden iframe whose response is an attachment starts one with no gesture at all. The first three such
  downloads of a load start, and the fourth asks the user, per "Downloads". A page the user lets through, or one whose
  downloads follow a click of the user's, can still start as many as it likes, and each file costs disk space and a
  status message. Accepted: each file is quarantined, so Gatekeeper checks it before it runs. The status bar shows one
  download by name and percent, or a count, and only for the focused pane. A crash can leave a hidden temporary file,
  which the first download of a later launch removes after seven days. A click is judged by the same mouse-up note that
  judges links, and the tab follows the navigation that click started. A click that starts no main-frame navigation
  earns nothing for a later script. One window stays open: a script that navigates after a real click has started its
  navigation, before WebKit confirms it, could pass for the user's. A user choice in a hands-on review; see Decision
  Log.
- **The control permissions depend on an amendment to accepted UTERM-004** — likelihood: medium, impact: medium. Until
  UTERM-004 names browser navigation and browser read, its permission set and this proposal disagree. Mitigation: M8
  starts only after UTERM-004 M6, and its first check requires the amendment.
- **A hung content process is ended with a private WebKit property** — likelihood: medium, impact: low. WebKit leaves a
  hung process running after its web view is released. Measured under `swift test`: the process survived release of its
  view for 61 seconds, a non-persistent store, a navigation to `about:blank`, WebKit's private `_close`, and its private
  `_killWebContentProcess`, which lasted 30 seconds. SIGKILL to the process id that `_webProcessIdentifier` names ends
  it. The product reads that property in one type, `WebContentProcess`, and uses it when the hang bound replaces a view
  and when a hung tab or pane is closed without a reload. The read is guarded by `responds(to:)`. A macOS update can
  remove or rename the property, and the browser then falls back to the old behaviour: a hung page costs one core and
  its battery until the app quits. The type refuses ids at or below 1, since `kill(0, ...)` signals the app's own process
  group. It also refuses any process whose path is not a WebKit content process, so a recycled id is left alone.
  Mitigation: one type owns the private name, tests spin real pages and prove the process is gone, and a missing property
  degrades to the old behaviour with no crash. Not verified: whether the app's own exit ends a process this does not
  reach, and whether a real hang in the running app behaves as it did under `swift test`. A tab sharing the hung process
  hears it end and recovers as from any content process that stops. A closed hung tab keeps its web view for up to the
  10-second bound so the probe can run. ADR-05 says work an applet keeps after close is bounded, and this is.
- **Two WebKit applets have not chosen their stores** — likelihood: low, impact: low. UTERM-007 and UTERM-010 are drafts.
  Accepted: the browser's store is its own, so whatever they choose cannot share or clear it.

## Milestones

### M1: Single-page browser

**Status:** DONE

- A pane can run the browser applet and load a typed address
- Back, forward, and reload work
- An address typed without a scheme loads over HTTPS, except loopback, which loads over HTTP
- The launcher offers the browser, and restore picks the browser by its description type

**As built:**

- The browser has three modules. `BrowserModel` holds the scheme policy, the address policy, and the description
  payload, with no AppKit and no WebKit. `BrowserApplet` holds the applet and all WebKit use. `BrowserTestSupport` holds
  an in-process HTTP server on loopback, which has a mode enum so the TLS mode of a later milestone adds one case.
- A real `WKWebView` loads pages from that server under `swift test`, so WebKit behaviour is proved in package tests.
  Without a window the web view still loads, and a load takes about 0.1 seconds. The UI tests only cover the launcher
  entry and restore.
- Measured under `swift test`: an `https` address aimed at the plain HTTP listener fails with `NSURLErrorDomain` -1200,
  and a closed port fails with -1004. Both come as one warning naming the address. M4 builds Load over HTTP on these
  two errors.
- The scheme policy takes a source and whether the frame is the main frame. A typed, restored, or controller load
  takes `http`, `https`, and `about:blank`. A page also takes `blob:`, and a subframe takes `data:` and `about:srcdoc`.
  The web view's navigation delegate applies the page rule to every navigation. WebKit blocks a page's own link to
  `file:` before the delegate sees it, so the page rule is proved with `ftp:`.
- The address policy returns the scheme it assumed, so M4 can offer HTTP only after an assumed HTTPS load fails. It reads
  an IPv4 loopback address only as four decimal parts. `127.1` takes HTTPS.
- Reload, back, and forward refuse to resend a form post, and say so in one warning. WebKit does resend the post
  silently when asked. The navigation delegate is the one gate: it cancels a main-frame reload, resubmit, or history
  step whose request is a post, so a swipe and the web view's own Reload are covered with the buttons. The tab also
  tracks which history entries a form post produced, so the button methods can answer before they ask WebKit. A post
  that redirects to a page counts as an ordinary page. Back and forward onto a post result are refused too, which M3
  turns into the question.
- The interim scope: a navigation WebKit marks as a download, a response the browser cannot show, and one the server
  marks as an attachment are each cancelled with one warning that downloads are not available. A link that opens a new
  window does nothing. M6 builds both. WebKit reports each cancelled load as an interrupted load, code 102, and the
  tab stays quiet about that code only for the address it cancelled itself.
- A server that asks for credentials gets none. The browser answers no authentication challenge, so the page shows the
  server's own 401, and a test pins that no request carries an `Authorization` header. WebKit asks the server twice.
- Camera and microphone are denied in the UI delegate. A real `getUserMedia` call never reaches the delegate under
  `swift test`, with the web view in a window or out of one, and the page's promise stays pending. The cause is
  unsettled, and a system privacy prompt before the delegate is one candidate. The test therefore calls the delegate
  method and pins the answer for each capture type, not WebKit's route to it. The user should try a microphone request
  from a real page in the running app. WKUIDelegate has no geolocation hook, and the app has no usage strings, so
  location cannot get the same treatment.
- `NSAllowsArbitraryLoadsInWebContent` is in `Info.plist`. It also drops the transport rules' TLS version and cipher
  floor for web content, and certificate validation is unchanged. A test pins the key and that no app-wide exception
  exists. Loopback is exempt from the transport rules, so no package test can show the key's effect on a named host.
- The browser uses WebKit's default website data store for now. M5 moves it to the browser's own store.
- Back, Forward, Reload, and Open Location are declared as commands now. Reload takes Cmd-R and Open Location takes
  Cmd-L, and the built-in key conflict test passes. M3 adds the rest and its own checks.
- A restored tab loads at `start`, never at construction. A refused stored address leaves the tab blank, posts one
  warning, and stays in the description. Reload on that blank tab applies the same rule again and warns again. The
  durable explanation in the pane is M5's.
- Layout storage narrows what "What restore loads" said. See the Decision Log entry of 2026-11-06 for the stored URL.

### M2: Security indicator

**Status:** DONE

- A page with any insecure content shows a warning icon in the address bar
- A fully secure page shows no warning

**As built:**

- `SecurityIndicator.warns(url:hasOnlySecureContent:)` in `BrowserModel` is the one rule. A blank page never warns, and
  neither does an empty tab. `isBlank` reads the address string, so `about:blank#x` and `about:blank?q=1` count as
  blank, and the address bar's own blank check shares it. An `http` page always warns. Any other page warns when WebKit's
  `hasOnlySecureContent` is false. A table test pins the rule with no WebKit.
- WebKit moves `url` to a new page before it updates the flag, and a test measured it. A load from a secure page to a
  stalled `http` address showed the new address with no warning, because the flag still described the old page. The
  `http` rule closes that gap. A stalled `https` address after an insecure page warns until its flag arrives.
- The tab observes `hasOnlySecureContent` beside the address, and recomputes `showsSecurityWarning` on every state
  change. The applet passes the value to the view, which shows or hides the icon.
- The icon sits between the Reload button and the address bar, and a test shows that it gives its room back to the
  address bar while hidden. It carries the identifier `browser-security` and the label "Not secure", and it is tinted with
  the theme's yellow.
- Measured under `swift test`. A page loaded from a string with an `https` base address commits as an `https` page and
  WebKit reports it fully secure, so a test uses it for the secure case: no warning, icon hidden. WebKit blocks or
  upgrades every mixed-content subresource tried there, namely an iframe, a script, a stylesheet, a fetch, an XHR, a
  video, and an image, and the flag never flipped. `about:blank` reports the flag as false. A `blob:` page made by an
  `http` page reports false and warns.
- What is left to the user. No test makes the flag flip after commit, so the observer on the flag is not pinned by a
  test, and the check that an HTTPS page which loads insecure content gains the warning is left to the user. A secure page
  fetched over real TLS, and a `blob:` page made by an `https` page, are also unproven, since the fixture has no trusted
  HTTPS. The fully secure case is pinned only as far as the string-loaded page goes. The `about:blank` guard in the
  tab is pinned by the table and by a navigation to `about:blank`. No trust override exists, even for tests.

### M3: Tabs

**Status:** DONE

- The browser opens, switches, and closes tabs
- The tab bar is hidden when only one tab is open
- New Tab, Open Location, Reload, and tab selection work from their default keys, and the built-in key conflict test
  passes
- Back and Forward work from the Browser menu, the toolbar, trackpad swipes, and mouse buttons 4 and 5
- Cmd-W closes the current tab, and Cmd-Shift-T reopens it in its former place with its history. A pane keeps at most
  20 closed tabs
- Cmd-R, Back, or Forward onto the result page of a POST this tab sent asks before resubmitting. Amended 2026-11-06; see
  Decision Log.

**As built:**

- The tab bar is `AppletTabBar` in `AppletKit`, moved from the terminal with its accessibility identifiers unchanged. The
  terminal's tab tests are its proof. The browser's view holds the bar above the toolbar, and a hidden bar gives its
  height back to the toolbar.
- A tab's web view is built on first use. A restored tab nobody has selected holds no web view and no content process.
  `start` loads only the selected tab, and a tab loads when it is first selected. A refused stored address is tried
  once, so selecting that tab again does not warn again. M5 still owns the rule that a detached pane loads nothing.
- Every tab observes its own web view for its whole life. Only the selected tab drives the toolbar, the address bar, the
  security icon, and the pane's title. Any tab's title change reaches the palette list through `appletTabsDidChange`.
  A switch drops an unsent edit in the address bar, since the text belonged to the tab left behind.
- A new tab opens after the selected one, is selected, and moves the keyboard to the address bar. Closing a tab selects
  its right neighbour, or the last tab. The last tab answers `.nothingToClose`, so Cmd-W closes the pane. A test pins that
  a closed tab and its web view are released, so only inert data stays in the closed list.
- Closed tabs ride in the description's undo-only part with each tab's address, title, and WebKit `interactionState`.
  The layout payload never holds them. A reopened tab returns to its former index, selected, with its Back history. A
  reopened tab never fails, so it has no failure text to supply. The host's reopen failure text no longer adds "Check that
  the shell can start". The terminal's reason carries that sentence itself, so its message reads as before.
- The resubmit question lives in the navigation delegate, the one gate every resubmit path crosses. The applet's own
  Reload, Back, and Forward each set a one-shot intent just before they call the web view. The gate takes the intent at the
  next main-frame decision and clears it, and a commit or a failed load clears it too, so it never carries to a later
  navigation. A repeat of a post with a matching intent, onto an entry this tab saw a form produce, holds WebKit's decision
  and asks through `AppletHost.applet(_:confirm:)`. Yes allows that one navigation. No, a second repeat while one question
  waits, a typed load, and closing the tab each cancel it, and a second repeat is cancelled, not queued. Every other repeat
  is refused with the M1 warning and no question. That covers a page's script, the web view's own Reload, a trackpad swipe,
  which cannot be told from a script, a background tab, and a reopened tab. A swipe onto a post result is therefore refused
  with a notice, and a test calls the web view's `goBack` to stand for it. The button methods no longer pre-check, so
  `HistoryMove` lost its resubmit case. Measured: reopening a tab on a POST result issues no second POST and shows the
  stored title with a blank page. A page's `location.reload()` on a post result reaches the server as a GET, so it sends no
  post and raises no question.
- WebKit has already made the target the current history entry when the gate runs, for Back, Forward, and Reload alike. The
  gate therefore keys the set of seen posts on the identity of the current entry. A post to an address this tab never saw
  cannot borrow the answer for a seen post to the same address, and a test pins that with a reopened tab. WebKit may serve a
  history step onto a post result from its own cache, so a yes there shows the page and sends no post. No test claims the
  server's post count after a yes on a history step. A yes on Reload is proved to send one post.
- A tab keeps its own load origin. A notice from a tab that is not selected names the tab, and is delivered by that tab's
  origin, so a background tab restored at launch stays as quiet as a restore is. The restore origin ends at the user's first
  click on a link in the tab, since what follows is the user's own. A background tab never asks. The gate
  refuses its repeats, and the applet answers no to a question from any tab but the selected one.
- Mouse buttons 4 and 5 are handled by a `WKWebView` subclass, which sends them through the applet's Back and Forward.
  A test calls the handler with real events built from `CGEvent`. Trackpad swipes use `allowsBackForwardNavigationGestures`
  and no code of ours. Swipes, a physical mouse, and the UI tests' keys need real hardware or the window server, so the
  user checks them. The UI tests are built, and the coordinator runs them.
- The tab commands copy the terminal's titles and keys. The key test sits in `AppletCatalogTests`, since that target
  already reaches the window's reserved keys, and it checks the browser's keys by hand against them as the terminal's test
  does. `Package.swift` did not change.
- The terminal and the browser both declare Cmd-T, Cmd-1 to Cmd-9, and Cmd-Shift-[ and ]. One remap onto such a key
  dropped it from both, and the registry posted one warning for each applet. The status bar shows the newest message, so
  the terminal's warning was hidden behind the browser's. A pass now posts one warning that names every applet that lost a
  key. It lists at most three commands for each applet and counts the rest, so a remap of Cmd-1 stays readable. The
  warning code is shared by every applet, so the change is not browser work, and no decision text changed.
- Left for later milestones. A running download or unsent input does not yet make a tab ask before it closes, which is M6.
  M8 needs an intent-free path for a controller's reload, back, and forward. The tab's `reload`, `goBack`, and
  `goForward` set the intent unconditionally, so a controller that called them would ask. See M8. The row built no
  intent-free path. It also built nothing that loads a controller's background tab, since `loadIfNeverLoaded` loads
  only the selected tab, and no hook that asks before a download, since the pane's `downloads.adopt` has none.

### M4: Address bar input

**Status:** DONE

- Non-address input searches with the engine chosen in Settings, and a change applies to the next search in every open
  pane
- `devbox` searches, while `devbox/`, `localhost:3000`, and `devbox:8080` load as addresses. Input whose text after the
  colon is only digits is `host:port`, even when an app has registered that word as a URL scheme
- A scheme-less loopback address, `*.localhost` included, loads over HTTP
- A scheme-less address whose HTTPS load cannot connect, or whose server does not speak TLS, offers Load over HTTP. A
  certificate failure or an HSTS host never offers it. A host is under HSTS when it sent the header over HTTPS to this
  browser.
- A typed `mailto:` address opens the mail app, and so does a real click on a `mailto:` link in the selected tab, with no
  question. A page's script never opens an app. A real click on a link, or a typed address, for another app asks first,
  naming the app. A
  typed `file:`, `javascript:`, or `data:` address loads nothing, leaves the page visible, posts one warning that says
  why, and marks the address input invalid. So does a scheme no app handles. Amended 2026-11-06; see Decision Log.
- The pane shows at most one question at a time, an app-handoff question included, and the question never blocks other
  panes
- A stored engine that is no longer on the list shows in Settings as replaced by the default

**As built:**

- The address rule is `AddressClassifier` in `BrowserModel`, and `AddressPolicy.resolve` applies it. A table test holds
  every example in the milestone text and every edge the plan named: `[::1]:8080`, `user@host`, a trailing dot,
  `http:` alone, percent-encoded text, whitespace at the edges and inside, internationalized names, an IP with a port,
  `*.localhost`, and control characters. The refinements it needed are in the Decision Log entry of 2026-11-06 on the
  classification. `user@host` searches and `user@host.com` loads, since the dot and the port decide, as for any text.
- `SearchEngine` and its setting key live in `Preferences`. The Settings row is a `ChoiceSettingRow`, which now takes a
  note under its control. A stored engine that left the list shows the default selected and a note that names the stored
  text. Settings has no status bar, so the note stands where `PalettePlacement` posts its warning. The stored text is
  never rewritten. Search addresses are built by hand-encoding every byte outside the unreserved set, and tests hold
  independently written expected addresses.
- The factory passes `BrowserServices` at both construction sites. It holds the engine as a read-only closure, the shared
  HSTS list, and the opener for other apps. The parameter has no default, so a construction site that forgets it does not
  compile. The applet reads the closure at each search. A test runs two panes on one closure and changes the engine
  between searches. `BrowserApplet` depends on `Preferences` for the enum only. `BrowserServices.live` builds the list,
  so the app target needs no `BrowserModel` product.
- Load over HTTP. The pure rule is `LoadFailure` in `BrowserModel`. Measured under `swift test`, against the fixture's
  two modes and a closed port: a self-signed server is `-1202` with a failed trust and an underlying `errSSLBadCert`, a
  plain listener answering HTTPS is `-1200` with `errSSLClosedNoNotify`, and a closed port is `-1004`. `-1200` is
  ambiguous, so the rule also reads the failed trust and the underlying TLS statuses through every nested error, and a
  certificate sign wins. The rule is an allow-list. Only `-1004`, `-1005`, and a `-1200` whose status says the peer closed
  the connection can offer, and anything unclassified gets the plain warning. The
  fixture gained a TLS mode whose self-signed identity is published test data with an obvious name. No delegate
  overrides trust, so the handshake fails. A real load proves each case: the plain listener offers, the self-signed
  server shows the certificate error with no action, and the server sees no request in either until the user chooses.
  The loopback fixture stands in for a remote host, so the tests build the load the way the address bar builds it for
  one. `-1005` also offers, which the milestone text did not say. A timeout does not.
- The pane shows the failure in a native view over the page, so no page's script can reach the action. A failure that
  leaves nothing to show explains itself there, and the history records one warning with no turn on the bar. Reload on
  that view repeats the same load. A new load clears the view when it starts, so a later failure that builds no page of its
  own, such as a failed Back, leaves no stale offer over the pane. The offer is tied to the load whose scheme the browser assumed, so a failure at
  another server gets a plain warning.
- HSTS. WebKit's public headers have no HSTS query, which was confirmed first. The browser keeps its own list in a file in
  the browser's folder, and `UNITERM_BROWSER_DIR` moves it for debug builds and UI tests. Header parsing, the list, and the
  file are proved at the pure layer with an injected clock, since a self-signed response never reaches the delegate. The
  call in the navigation delegate is covered by a test that hands the delegate a stand-in response, cast to the WebKit
  type, with no production seam. A `localhost` entry proves that a listed host gets no
  offer in a real load, and an unlisted control shows that the test would fail if the list were ignored. A file from a
  newer build is never overwritten, since the store reads only its version and then keeps its list in memory. A header
  that moves a live entry's expiry by under an hour records nothing, so a busy site does not rewrite the file on the main
  thread with every response. A site that serves many host names can push entries out at the 2,048 cap. The impact is low,
  since WebKit still enforces HSTS and the list only hides an offer. The list is not yet emptied by anything. Clear
  Website Data empties it in M5.
- Handoff. A typed `mailto:` opens at once. A typed address for another app, and a link the user followed, ask first
  through the host's confirmation, naming the app and the address, with an injected opener so no test launches an app. A
  scheme no app handles posts one warning and marks a typed address. A script's or redirect's navigation to such a
  scheme stays refused, which keeps M6's script and iframe check open. WebKit reports a script's `a.click()` as a followed
  link, so the tab trusts only a real left mouse-up that `BrowserWebView` sees, with an injected clock and a one-second
  bound, spent by the first link decision. A test drives the view's own mouse-up handler with an event built from
  `CGEvent`, so a real click on the screen is left to the user. A key press that activates a focused link leaves no
  mouse-up, so it is refused with a notice, which is the choice made. A clicked `mailto:` link in the selected tab
  opens without a question, as the Schemes text says, after the same selected-tab and one-question guards as any app.
  The invalid mark already existed from M1. It now also changes the field's accessibility label to
  "Address, invalid", and tests pin that, its red text, and its clearing on edit.
- One UI test is built and not run: the Settings row with a replaced engine. The UI test for a refused address's mark was
  retired after the row. `BrowserAddressTests` owns that contract, in the field's label, its red text, and its clearing
  on edit.

### M5: Website data, restore, and reopen

**Status:** DONE

- Logins carry across browser panes and survive relaunch, in a store separate from WebKit's default store
- Every browser pane shows its active profile, the default profile, and the user confirms its placement in a hands-on
  review
- Clear Website Data removes the browser's stored data and the browser's list of HTTPS-only hosts, and reloads no tab,
  and Settings says open tabs keep their session until reloaded or closed.
- Layout restore loads only the selected tab of each attached pane. An unselected tab shows its stored URL and title,
  and loads when first selected. A detached pane loads nothing until it is attached. The layout file holds no history
  and no form data
- A restored tab whose URL has a scheme other than `http`, `https`, or `about:blank` shows `about:blank` and an
  explanation in the pane naming the URL, with one history warning, and its description keeps that URL until the user
  navigates. Amended 2026-11-06; see Decision Log.
- A browser pane reports no current directory, and a pane split from it starts in the launcher's default
- Going back or forward through reopened history never resubmits a form

**As built:**

- The store is `BrowserWebsiteData` in `BrowserApplet`. Its identifier is a constant with a comment that says it must
  never change, and a test pins the value. `live` builds `WKWebsiteDataStore(forIdentifier:)`. Neither `BrowserApplet`
  initializer has a default store any more, so no pane can reach WebKit's default store by omission. The host builds
  one `BrowserWebsiteData` at launch and passes its store to every pane. A debug build reads `UNITERM_BROWSER_STORE`, and
  the value `memory` gives a store that keeps nothing. The UI tests set it, so they never reach the user's store, which
  the app's bundle identifier scopes and a UI test shares. How `forIdentifier:` behaves under UI tests was not tried,
  since an in-memory store makes the question moot. A persistent test store would leave a folder under the app's
  container per run, and the UI tests have no way to remove it.
- Package tests run real web views against the fixture server. A cookie a page sets lands in the test's persistent
  store and never in `.default()`. Two panes on one store send one another's cookie, and a pane on another store sends
  none. A second store instance over the same identifier sees the first one's cookie. That runs in one process, so it
  proves that the identifier names the data. It does not prove that the data survives a relaunch, which is left to the
  user. Each test uses a throwaway identifier and removes its store in teardown.
- Clear Website Data is `BrowserWebsiteData.clear`, which removes every website data type since the beginning of time
  and then empties the list of HTTPS-only hosts. A test proves the cookie is gone, another store's cookie is untouched,
  the list is empty, and an open tab asked the server nothing and kept its title. `HSTSStore.removeAll` now answers
  whether the file can still hold hosts. A file from a newer build is never written, so for that file the clear throws
  after it removed the site data, and a test pins that the file's bytes are unchanged. A clear after a failed write tries
  the file again, so a second clear cannot report success for a file that still holds hosts. WebKit's own removal reports no
  failure, so the clear has no other failure to show.
- A restored address is shown through `AddressDisplay`, which now drops bidirectional controls, turns other control
  characters into spaces, and cuts by characters and by 480 bytes. A layout file can no longer put a reordering override or
  a long run of combining marks in a pane, a notice, or a question.
- Settings holds the action in `ActionSettingRow`, which `SettingsKit` links with no WebKit. The host passes a closure
  through `SettingsWindowController`, which has no default, and there was no action-row precedent. The button is disabled
  while a clear runs, a second request is ignored, and the row shows "Cleared." or the error's own line, which the error
  chooses whole. Each state is announced to VoiceOver. A failure never reads as a
  success, and a retry replaces it. A standing note says open tabs keep their current session until they are reloaded or
  closed. Tests hold the closure at a gate to prove the double click, and prove the failure text and the retry.
- The profile button is a borderless icon button, `person.crop.circle`, at the trailing end of the browser's toolbar. It
  carries the identifier `browser-profile`, the accessibility label and tooltip "Profile: Default Profile", and keeps
  its width in a narrow pane while the address bar gives way. Clicking it shows a transient popover with the profile
  name and the line "Every browser pane shares this profile's logins and site data." The popover has no controls. Both
  follow the palette, and `apply(_:)` updates an open popover in place.
- A detached pane loads nothing. `start` on a detached pane marks the pane started and loads nothing, and a tab selected
  or reopened while detached waits. `reattach` loads the selected tab if it never loaded, once. Detach has no host
  trigger, so the rule is proved by calling the events in tests, as M3 expected. The tab's own load origin survives to
  the attach, so a restore stays as quiet as at launch.
- A refused restored address is now a `LoadErrorPage` case, so the pane shows an explanation that names the address and
  the history records one warning that takes no turn on the bar. The description keeps the address through a save,
  because only a commit writes a URL and a refusal never commits, so the storable rule does not touch it. A committed
  `blob:` page is not stored, while a restored `file:` address is kept. The first is the rule for what a commit writes,
  and the second is what a restore was given. A typed load clears the explanation and the commit replaces the address.
  Reload on the blank tab warns again and stays refused, as before. Earlier tests that count warnings held without
  change.
- Pane reopen lost every open tab's history. The undo-only part held only the closed tabs, so a closed pane rebuilt each
  tab from its address alone. The part now carries one history record for each open tab, and a restore applies each
  record at the tab's first load. The layout file never holds it, and a test checks that the encoded layout has no such
  field. A test closes a pane on a page reached from a form post, rebuilds it, and shows that the history is back, that
  going back onto the post is refused with a notice and no question, and that the server saw one post.
- A tab reopened but not yet loaded lost its history when it closed again. A tab whose web view had no page reported an
  empty record that replaced the record it was given. The tab now hands back the record it holds first, and a tab with
  no page has none. The regression test failed before the fix with a 137-byte record in place of the 710-byte original.
  A tab restored and never selected closes with no record and keeps its address and title.
- `describe()` carries each open tab's history record, and the window calls it at every change an applet reports, at a
  rate a page chooses. Each tab keeps its last read of the record, and the applet keeps the encoded undo-only part. A
  commit, a finish, a load, a step, a change of address, or a change of `canGoBack` or `canGoForward` makes the read
  stale. A title change or a loading toggle never does, so a page that rewrites its title in a loop costs no read. A test
  sets a title 40 times, describes the pane at every change, and counts reads of the history record: it failed before the
  change with 24 reads and passes with none. A pane close takes the record as of the last history change, so a scroll
  position can be as old as that change, and a tab that closes alone reads the live record. A page that pushes history
  entries in a loop still costs a read for each one, and WebKit rate-limits that. A window-level test shows that a history
  entry with no new stored address raises no layout change.
- A pane split from a browser asks the factory for no directory. A test builds a real window around a real browser pane
  and splits it, and checks that the factory ran. This needed the catalog tests to link the browser and the fixture server, so `Package.swift`
  changed.
- Three UI tests are built and not run: the profile button, restoring three tabs with the second selected, and the
  Settings action with its note. The coordinator runs them. The UI test for a refused restored address was retired after
  the row. `BrowserLazyRestoreTests` owns that contract, in the error view's visible text, which names the address.
- Left to the user. Whether the profile button's placement is right, and whether logins survive a real relaunch.
  Reaching `forIdentifier:` store data across two launches needs a persistent store that the UI tests avoid.

### M6: Pop-ups, downloads, and running work

**Status:** DONE

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
- A finished download posts an info message naming it, and a failed one posts a warning. A cancelled one posts nothing.
- A `blob:` download from a page saves like any other, with or without a `download` attribute, and a `data:` download
  saves with one. A page's own `blob:` preview opens in its tab. A page's `file:` link saves nothing, even marked as a
  download.
- `srcdoc` and `data:` subframes load, while a top-level `data:` page is refused
- A script or iframe navigation to an app's scheme asks or is refused, and never launches the app silently
- Closing a tab or a pane during a download asks first, names the file, and cancels it. Navigating the tab away does
  not cancel it
- A tab with edited form input, in any frame or in a `contenteditable`, asks before close and is named in the dialog. It
  stops asking once the input is submitted or back at its defaults. An `input` event a page's script dispatches never
  marks a tab, and page scripts cannot reach the tracker's handler. A script's `document.execCommand('insertText')` on a
  focused field raises a trusted event and does mark the tab. Amended 2026-11-06; see Decision Log.
- Detach suspends media and holds alerts until reattach. Reattach does not resume media. Closing a detached pane
  answers every held alert

**As built:**

- Pop-ups. `createWebViewWith` builds a `BrowserTab` from the configuration WebKit passes, with a fresh content
  controller, so the opener relationship and the shared store hold. The tab is built at once, since WebKit needs the web
  view back from the same call. It takes the same delegates, observers, scheme gate, and tracker as any tab, and its
  first load passes the gate in its own navigation delegate. A window to a scheme the rule refuses opens nothing and
  warns. The tab opens right after its opener. The opener's selected tab selects it, and a background opener's tab
  does not. A real test calls `window.open` from a background tab and checks the selection and the notice. A real sign-in
  flow runs against the fixture: the pop-up posts to `window.opener` and closes itself, the opener hears it, and the
  selection returns to the opener. `webViewDidClose` closes only a script-opened tab. Never the last tab. A tab with unsent
  input or a download stays and warns. A tab a script closes is not put on the reopen list. Selection returns to the opener
  only when the pop-up was selected.
- WKWebView on macOS does not block a script with no gesture. A page that called `window.open` at load opened a tab, so the
  text "WebKit's macOS default blocks it" was wrong. The browser now sets `javaScriptCanOpenWindowsAutomatically` to
  false, and a test pins it on a tab's web view and on a pop-up's. No test can run a script with no gesture, since
  `evaluateJavaScript` and `callAsyncJavaScript` both carry one, so the block itself is left to the user. A script with a
  gesture opened 41 tabs in one loop, so a pane holds at most ten tabs that scripts opened, and the rest of a loop gets
  null. The limit is a policy value with no setting. The eleventh call now starts a question, as "Pop-ups" says: a
  refused call keeps its address in a per-page list of at most 50, held on the opener tab and reset at its next commit.
  The question is the host's confirmation and names the page and the count of script-opened tabs the pane holds. It
  does not quote how many calls the loop made, since the question is built at the eleventh call and the loop is still
  running. The warning after a no, and after a yes that kept fewer than the page asked for, carries the final count. A tab the user asked for does not count and is never refused: a real
  mouse-up on a link, or a choice from the context menu, marks the next window request as the user's, once, within one
  second, and that tab keeps `window.opener`. A real test clicks a `target=_blank` link twelve times past the limit with no
  warning, and a script still stops at ten. Its first run failed on the eleventh click.
- The context menu rewrites its four new-window items to new-tab items in `willOpenMenu`, by item identifier, never by
  title. The item keeps WebKit's own action, which asks for a window, so Open Link in New Tab is the same path as a
  `target=_blank` link and crosses the same gates. Each rewritten item first tells the web view the user chose it, through a
  forwarder, so the tab it opens is the user's. A menu click on a link to another app is refused with a warning, as a
  script's is. Download Linked File and Download Image in the menu are WebKit's own and may not reach the download
  delegate, since that route has no public hook. They are unproven. No UI test reaches the web view's menu.
- Downloads. A navigation WebKit marks as a download proceeds for any scheme except `javascript:` and `file:`, by
  `SchemePolicy.decideDownload`. A response the browser cannot show, or an attachment, downloads too, in a frame as well. M1's interim
  warnings are gone. The pane holds each `WKDownload` in `BrowserDownloads`, not the tab, and the status segment, the
  running labels, and the close questions read it. A download writes under a hidden `.uniterm-download-<id>.part` name in
  the injected Downloads folder. Preparing the folder, marking and naming the file, removing a partial file, and the sweep
  all run off the main thread through `DownloadFileOperations`, and each reports back as a later main-actor event. A
  download that is finishing still counts as running. A cancel that arrives then takes it out of the list at once, announces
  nothing, and removes the file the finish makes. Tests hold the operations with a semaphore and check the thread. At the
  end the file is marked and then renamed with `renamex_np` and `RENAME_EXCL`, trying
  `name`, `name 2`, and on, so no check comes before the rename. A test finishes 32 downloads into one name from 32 threads, and
  two panes share a folder in a real test. A failed download removes the partial file and posts a warning naming the file and the
  reason. The partial file is removed again when WebKit lets go of a cancelled download, since WebKit may create it after
  the cancel. A cancelled one posts nothing. A finished one posts an info message. A detached pane records the outcome now and
  presents it on reattach. A download whose navigation WebKit reports as an interrupted load stays quiet about that load.
- Names. `DownloadName.sanitize` is pure and table-tested for separators, `..`, a leading dot, bidirectional controls,
  control characters, every format character such as zero-width marks and the byte order mark, line and paragraph
  separators, the Hangul fillers and the blank braille pattern, trailing dots and spaces, runs of spaces and every kind of
  space collapsed to one, an empty result, a long name that keeps its extension, and reserved characters. A long run of
  spaces cannot push a real extension out of view.
- Leftovers and a late failure. A crash or a quit can leave `.uniterm-download-<UUID>.part` behind. The first download into a
  folder in a launch sweeps that folder off the main thread, removing only regular files of that exact name, with an
  uppercase UUID, last written more than seven days before the injected clock. A second instance may still be writing, so the
  age is generous. A test plants a user's file that resembles the name, a directory with the name, a fresh temporary file,
  and an old ordinary file, and only the old temporary file goes. A folder that cannot take the quarantine mark, as a volume
  with no extended attributes cannot, fails the download only at its end, after the bytes arrived. The warning names the
  file, says the mark failed and why the volume may not support it, and carries the system's reason. A test stands in for the
  refusal with a temporary file that is gone at the end, since no test can make a volume reject extended attributes.
- Quarantine. Each file gets `quarantineProperties` before it takes its final name: the web-download type, the agent bundle
  identifier and name, the origin page, and the address fetched. A `data:` address is the file's own bytes, so it names no
  data address. Fails closed: when the mark cannot be set the download fails. A test reads the property back and checks the
  type, the agent, and an event identifier. The system does not return the origin and data addresses on read, since it keeps
  them in its own database, so a test pins them on the download before it ends and in the record builder. A test pins
  that `App/Info.plist` has no quarantine key. The origin comes from the last committed page, since WebKit moves `url`
  to the new address before it commits.
- Schemes. A `blob:` download saves with or without a `download` attribute, and a page's own `blob:` preview opens in its tab.
  A `data:` download saves with one. A top-level `data:` navigation with none is a page and stays refused, since the policy
  cannot tell it from a page before the response. A page's `file:` link saves nothing, and WebKit stops it before the delegate. `srcdoc` and `data:`
  subframes load. Each has a real web view test.
- Download controls. A status bar segment names the one download and its percent, or counts several. Reveal Latest
  Download is in the Browser menu and the palette, unavailable with no finished download, and a moved file gets a warning
  with the command still offered. The Downloads folder and the reveal are injected through `BrowserServices`, with no
  default, so no test reaches the user's folder or Finder. Closing a tab, whether selected or not, asks first and names the file,
  and a yes cancels. Navigating the tab away does not cancel. The tab that closes releases its web view while the pane holds the
  download, and the close cancels it. WebKit's behaviour for a download held after its web view is gone was not
  measured, since a close always cancels.
- What a page can do with downloads. The pane keeps the in-flight ones and the newest finished file, so its memory follows
  the number in flight, and a test finishes 30 downloads of one name in a row, each started by a click of the user's. A
  hidden iframe whose response is an attachment starts a download with no gesture. WebKit serialises navigations in one
  tab, so typed loads cancel each other, and it holds six connections to one host. The close question and the running
  labels name at most ten downloads and a count. A page's downloads that no click started now count per load: three start,
  and the fourth holds its decision and asks. The tab judges a click from the mouse-up it saw, and follows the navigation the click
  started. A link the user clicked, or a load the user typed, is the user's through its redirects. The mark is armed by
  the click, confirmed by WebKit's provisional start, and ended by the main-frame response, a failure, a commit, or any
  action decision that does not continue it. A click that starts no main-frame navigation, such as one on a `#fragment`,
  on a `download` link, or on a link that opens a window or is cancelled, is never confirmed, so the next action ends
  it. A frame's attachment is never the user's. A test clicks a `#fragment` link for real and then navigates by script,
  and the downloads count and ask. It failed first with the earlier rule, which cleared the mark only at a response. A no cancels at the decision, so it never meets the cancel-before-first-byte hazard
  below. Tests start real downloads from a script and prove no file exists before a yes.
- A cancel before the first byte. Every download cancelled before WebKit had a byte of its body produced an `EXC_GUARD` report
  from `NetworkProcessProxy::didReceiveInvalidMessage` in the test crash folder, about one for each run that cancelled one.
  WebKit treats an IPC message from its network process as invalid, and the process restarts. Measured with a real web view
  and a store that keeps its cookies only in that process: a session cookie set before the cancel was gone for a load in another
  tab afterwards. A cancel after a byte, a download that fails, and one that finishes left the cookie and made no report. A user
  would see: every browser pane of the app loses its session cookies, so sites that keep a login in one are logged out, and a
  load or download in flight in another pane fails. Persistent cookies and the website data on disk survive, and the next load
  starts the process again, so a passing test run does not show it. The cause is in WebKit, since the cancel is the documented
  call. The browser now waits: a cancel with no byte yet takes the download out of the list at once and sends the cancel to
  WebKit with the first byte, or after 30 seconds if none comes, at which point the hazard is accepted. A cancel that beats the
  destination answer still gets a destination. A deferred download that finishes or fails first removes its file and says
  nothing. Tests: one finished all 39 download tests with no new crash report where each run made one before, and a structural
  test fails on the unfixed code. The cookie loss reproduced in scratch runs of one and of twelve cancels and did not reproduce in
  the committed test's form, so that test pins the symptom and the structural test is the one that failed first. A pane
  closed with a download that has no byte yet keeps the cancel pending for up to the grace, with no indicator.
- App schemes. A script's or an iframe's navigation to an app's scheme is refused with a warning and never asks. A
  subframe's `window.open`, the main frame's `window.open('mailto:')`, and a script's click in an iframe are real
  web view tests. A real mouse-up followed by an iframe link was asking, since WebKit calls it a followed link, so a link
  counts only when its source frame is the main frame. The regression test failed before that change. A real click on a
  main-frame link still asks.
- Unsent input. The script is `UnsentInputScript`, in an isolated `WKContentWorld`, in every frame. It watches fields, which
  include a `contenteditable` element by its text against the text at first focus. Only a trusted `input` event adds
  a field. Fields are re-checked on `focusout`, a click, `reset`, a trusted `submit`, and `pagehide`. It posts only on a change, at
  most once in 250 milliseconds, and a loop of 2,000 flips cost one post. The native side takes a frame token and a real
  boolean, nothing else, and keeps the marked frames, at most 64, so a frame clears only its own mark. A dirty frame past the
  bound cannot be remembered, so the tab stays marked until the next load, which fails on the side of asking. A marked
  subframe that its parent removes, and one that navigates away, each clear their mark as the document leaves, which a test
  measures with a real web view. Each web view has its
  own content controller. The handler is a proxy that holds the tracker weakly, and `close` removes it. A load clears the mark.
  Tests use a real web view. A page-world post throws. A page-made `input` event is untrusted, and its regression test failed
  with the check removed. A limit, measured: a script's `document.execCommand('insertText')` on a focused field raises a
  trusted `input` event and marks the tab with no typing. No detector was built, since the cost is a question the user can
  confirm, and a test pins the behaviour. Strict-body checks go through the isolated world. A subframe's edit survives the main frame's clear.
  A closed tab and its tracker are released. A trusted event cannot come from script, so the tests type through the web
  view's `NSTextInputClient`, the path of a key press or an input method, in an offscreen window. That proves the script and the
  handler in the real isolated world. It does not prove a key press through the window server.
- Running something. `isRunningSomething` is true for edited input or a download in flight, and nothing else. `runningLabels`
  names a tab by its page title, cleaned of bidirectional and control characters and cut, and a download by its file name, at
  most ten and a count. The window's pane, window, and quit paths read these two properties, and Cmd-W reaches the applet through
  `closeCurrentTab`, which answers `nothingToClose` for the last tab so the window asks. The window paths are unchanged and
  tested with a fake applet, so no window-level test with a real browser was added. `saveUnsavedWork` is unchanged.
- Detach and reattach. Detach pauses media and then suspends it in every tab. Suspending alone let a pending play resume when
  the suspension lifted, which the test caught, so the tab pauses first and sends the suspend and resume in pairs. Reattach lifts
  the suspension and starts nothing. Under `swift test` the page's `play()` stays pending, so no real playing audio
  is proved. The state goes to suspended and back, and the element stays paused. Alerts, confirmations, and prompts
  show in an overlay inside the pane, never in a window sheet or through the host, so no other pane waits. A dialog waits while
  the pane is detached and while its tab is in the background. Every completion handler runs exactly once, by the dialog
  object, and a tab close, a pane close, and the held bound each answer it. The user stops a page's dialogs. From a
  page's second dialog in a load, the overlay shows "Don't show more from this page", with the identifier
  `browser-dialog-stop` and the label "Don't show more dialogs from this page". Choosing it answers the dialog as Cancel,
  dismisses the tab's other waiting dialogs, and dismisses every later one until the next load, with one warning posted at
  the first dismissal. At most 16 dialogs wait, a policy value with no setting that guards memory only. Nothing in the host sends
  detach or reattach, so the tests call them.
- Not built, and still out of scope: file upload pickers and HTTP authentication dialogs. An upload input does nothing, and a
  basic-auth page shows its 401.
- Left to the user. A real sign-in against a real provider. How the download segment looks and reads in the status bar, and
  the Download Linked File item. Sound that stops on detach and stays stopped. The UI test for the Browser menu's Reveal item is
  built and not run, and no UI test reaches the context menu.

### M7: Web content failure

**Status:** DONE

- Killing a selected tab's content process shows the stopped-page message, and Reload brings the page back with its
  history
- Killing an unselected tab's content process leaves it not yet loaded, and selecting it loads the page
- A page that hangs its content process comes back on Reload, and the hung process is gone after the bound, whether the
  user reloaded or closed the tab. Amended 2026-11-06; see Decision Log.
- No recovery resends a POST, and a stopped tab no longer counts as running something

**As built:**

- The tab owns its web view and replaces it. `BrowserTab.webView` is built on first use and rebuilt after a stop. The
  replacement drops every reference to the old view: the delegates, the observers, the mouse and menu closures, the
  unsent-input handler, and its script. The next view installs them all again, with the data store, the media
  suspension state, and a fresh content controller. A pop-up's rebuilt view takes the browser's store, since WebKit's
  configuration is spent, and it has no `window.opener`. The applet shows the new view when the tab is selected and
  gives it the keyboard if the old one held it. Tests prove the old view is released, that it has no delegates, and that
  a second stop it reports is ignored.
- A stop. `webViewWebContentProcessDidTerminate` replaces the view, then the applet decides. The selected tab of an
  attached pane shows the stopped message in the native error pane, with a Reload button, and the history records one
  warning with no turn on the bar. Any other tab goes back to not yet loaded, holds no web view, and loads when it is
  selected or when its pane is attached. A selected tab that was stopped stays stopped when the user switches away and
  back, and never loads on its own. A blank tab that never held a page stays blank with no message. Reload on a stopped
  tab loads the stored address with the kept history, the way a reopened tab loads. A tab with a history record and no
  stored address, such as a pop-up that opened on a `blob:` preview, loads from the record alone, and a tab that stopped
  before any page committed falls back to the last typed address. The stop stays on screen until the tab knows it will
  load, so a refused stored address keeps its message. Nothing reloads by itself, so a page that stops again shows
  the message again and a page that crashes on load cannot loop. A test stops a tab twice in a row, the second time
  before its page commits, and the history comes back.
- Measured. WebKit's `_killWebContentProcess` is present on this macOS and the navigation delegate never hears of it. The
  tests send SIGKILL to the process that `_webProcessIdentifier` names, which is a real crash from WebKit's side. The
  tests have their own read, apart from the product's guarded one. A process id of 0 means no process exists yet, and `kill(0, ...)` would
  end the test run's own process group, so the helper waits for an id above 1. SIGKILL leaves no crash report.
- The history record at a stop. `interactionData` returns the tab's pending record first, and a stop stores the record it
  reads into that slot, so the description keeps the history until Reload applies it. Measured: a view that has not
  committed a page reports a small record of its own, 186 bytes against 719 for two pages, so a stop on such a view, as a
  second stop before the restore commits, would have replaced the history with it. The tab now reads the live record only
  from a view that committed a page, and takes the last record read from one otherwise. The regression test failed before
  that change with the 186-byte record.
- What a stop leaves waiting. The unsent mark clears, so the tab stops counting as running something. A download keeps
  running, keeps its entry, and still asks on close, and the file finishes after the tab's view is released. Every
  held dialog of the tab gets its one answer, and a late tap on the dialog view or a second answer does nothing. A
  question about sending a form again resolves as no at the stop, and a yes the user gives afterwards sends nothing. A
  question about opening another app is dropped through a per-tab generation, and a late yes opens nothing. The
  question itself stays on screen until the user answers it, which is stale and harmless. A close question that was up
  when the tab stopped still closes the tab on yes, and the closed tab reopens with its history. The dialog, resend, and
  handoff tests each failed with their step removed, and every stop test failed with the stop handler empty.
- A hang. `HangPolicy` in `BrowserServices` holds the bound and an injected schedule, and a test fires the bound by hand.
  A user's reload, back, forward, or typed address on an existing web view arms one bound of 10 seconds, and nothing
  else arms it. The production schedule sleeps on a suspending clock, so a machine that sleeps during the bound does not
  fire it on wake. Any callback of the navigation delegate or the UI delegate cancels the bound: a policy decision, a
  provisional start, a commit, a finish, a failure, a dialog, or a window request. A hung process answers none of them,
  so a reload sent to it reaches no server and fires the bound. A slow server still answers the first, so the bound is
  cancelled long before it would run out. Tests with a real web view prove both sides. A page running `while(true){}` is
  replaced when the bound runs out, and its reload never reached the server. A server that holds its answer cancels the
  bound and the same web view finishes the page. A short real bound proves the production schedule fires once and
  reaches the tab, which no injected test can show. The bound is a policy value with no setting.
- What the bound leaves alone. A page that waits on a dialog is not hung. WebKit never raises a `beforeunload` question to
  the public UI delegate, since it answers the question itself, and a test records that a reload of such a page ends
  normally. A test holds a `confirm` dialog, reloads, fires the bound, and the page stays. A hung page that holds unsent
  input is not replaced silently. The user is asked, in a question that names the tab, and the page is replaced only on
  yes. A no keeps the view and the input, and a process that speaks while the question is up drops a later yes. Only the
  tab the user is looking at in an attached pane asks, so another tab keeps its view. A bound that runs out on a tab
  that lost the selection, or in a detached pane, drops the hung view and loads nothing. The tab loads when it is
  selected or the pane is attached. Each test failed with its rule removed.
- After a hang in the tab the user is looking at, a reload, back, or forward loads the page again from the address and
  history, and a typed address loads in the new view after the history is restored. A typed address on a stopped or not-yet-loaded
  tab applies the kept history first in the same way. The history of the hung page is kept
  for a typed address, which starts the hung page's own load before the typed one replaces it. A page that hangs on load
  could in principle hang the new view too. Recovery never repeats on its own, so the user's next action arms the bound
  again.
- The hung process outlives its view. A scratch test measured the process alive after release of its view for 61 seconds,
  and after a non-persistent store, a navigation to `about:blank`, `_close`, and `_killWebContentProcess` for 30 seconds.
  A rebuilt view and four new tabs each got a different process from the hung one. SIGKILL to the id from
  `_webProcessIdentifier` ends it, and the user chose to ship that in a hands-on review. `WebContentProcess` owns the
  private read, guarded by `responds(to:)`, and the kill. It refuses ids at or below 1 and any process whose path does
  not name a WebKit content process. The hang bound kills the process before it builds the new view. A close of a tab
  or pane reads the id before the view is released, and probes the page with `evaluateJavaScript`. No reply within the bound
  kills the process, if the kept view still reports the same id. The probe holds the view strongly, since a released view
  answers a pending call at once, which would look like a reply. `HangPolicy` carries the type, so a test injects a
  recorder. Tests spin real pages from the fixture server and prove the process is gone on replace and on close. They
  prove a pop-up sharing the process recovers as a stopped tab, and that a live page closed normally cancels the probe
  and sends no signal. A unit test proves ids 0, 1, -1, and the test's own are never signalled. See Risks.
- No recovery resends a POST. Recovery restores history and never sets the resubmit intent, so the gate refuses the
  repeated post. Measured: a rebuilt view restores a post result as a blank page with its history, the gate refuses the
  repeat with one notice, and the server's count of posts stays one. The page is blank, so the message says so. A stopped
  tab whose page came from a form says that Reload shows it blank and does not send the form, and after Reload the pane
  says that the form was not sent again, until the next load or commit. This holds for the crash path and for the hang
  path, in tests.
- A pop-up shares its opener's process here. A test stops the selected pop-up, and the opener, in the background, lost its
  content with it. The pop-up shows the message and the opener waits to be selected, then loads with its history. Each tab
  handled its own stop.
- Fixed in M6's downloads while checking the flaky `testACancelRightAfterTheDestinationKeepsTheNetworkProcessUp`. A cancel
  of a download that already had a byte never reached WebKit, since `performCancel` refused an entry the cancel had just
  taken out of the list. The download then ran to its end, and its complete file stayed at its temporary name. A finish
  that beat a cancel that did reach WebKit also returned without letting go. Both are fixed, with a test for each that
  failed first. Run in a loop of 60, the flaky test failed once on the unfixed code and not at all on the fixed code.
  What stays uncertain is whether the one failure on the unfixed code is the whole of the earlier flake, since it
  failed once in the full run and not in its class alone.
- Structure after the row review. `BrowserTab` held about 45 properties, and its flag ladder produced two of the review's
  bugs. The hang bound moved to `HangRecovery`, the facts about form posts and the held question to `ResendGate`, and
  `hasBegunLoading`, `isStopped`, `errorPage`, and the held history record became one `LoadState`, so a stopped tab that
  also began loading cannot be written. `isMaterialized` is now the web view's existence. No behaviour changed, and the
  package tests passed before and after the move.
- Not covered. A real kill of a tab that never loaded was not tried, since a view with no page may have no process, so a
  direct call to the delegate method proves the handler. A memory kill by the system and a content process that a user
  kills from Activity Monitor take the same path as the signal, and no test reaches them. The message's look and
  placement are left to the user, and so is how Reload and the stopped tab read with VoiceOver and in a narrow pane.

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
  refused. Any background tab a controller opens loads at once. Navigate, reload, back, and forward on the selected tab
  of a key-focused pane, or on a tab with unsent input, return a structured error
- Controller reload, back, and forward never resubmit a form. They use an intent-free path that sets no resend intent,
  so they never ask and never resend. The tab's own `reload`, `goBack`, and `goForward` keep setting the intent
- A download, or a link to another app, `mailto:` included, in a controller tab asks the user first. Amended 2026-11-06;
  see Decision Log.
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
- 2026-11-06: Amended refusals and download outcomes to the contract in UTERM-017 (work-queue best guess). The text said
  a refused `file:`, `javascript:`, or `data:` address makes the address bar say why, with no level and no history. It
  now leaves the page visible, posts one warning, and marks the input invalid. A restored refusal said "a message",
  which may clear. It now has a durable pane explanation and one history warning. A failed download was an error. No
  user work is lost when a remote file does not arrive, so the level rule makes it a warning. A download that ends
  while the pane is detached was said to rely on the message reaching the user. The pane now withholds the message,
  records the outcome at once, and presents it on reattach. The profile label keeps its pane-local placement for M5's
  review.
- 2026-11-06: Narrowed what the layout payload stores (work-queue best guess). "What restore loads" said the payload
  stores each tab's last committed URL and title. It now stores a URL only when "Schemes" lets a restored tab load it,
  drops a URL over 32 KiB, and cuts a title to 512 characters. A committed `blob:` page would restore as a refusal at
  every launch, and a page chooses the length of both values, which the layout file holds. A tab keeps its last
  storable value when a commit is not storable.
- 2026-11-06: Security indicator proof narrowed (work-queue best guess). M2's second check, a fully secure page, is
  proved only with a page loaded from a string with an `https` base address. Its first check, a page with insecure
  content, is proved for `http` pages. A page that gains insecure content after commit has no test, and the user checks
  it by hand. The rest of the checks pass, so M2 is DONE, and As built names what is left to the user. An `http` page
  warns whatever the flag says, because WebKit updates the address before the flag.
- 2026-11-06: Narrowed who may ask the resubmit question (work-queue best guess). "Browser commands and keys" and M3's last
  check said that Reload, Back, and Forward onto the result page of a POST ask before resubmitting, and "Browser commands
  and keys" said restore, recovery, and controller commands never resubmit. The text now says only the browser's own
  Reload, Back, and Forward ask, and only about a post this tab saw a form produce. Anything else that repeats a post is
  refused with a notice. The prior text did not say who may ask. WebKit gives no flag for a user-initiated navigation, so
  a page reached from a post result could call `history.back()` and raise the question in a loop, and a click would
  repeat the user's earlier order. A tab restored or reopened from history has no record of which entries were posts, and
  WebKit restores a POST result there as a repeat of the post, so asking there would open a yes path into restored
  history, which "What restore loads" forbids. The cost is that a trackpad swipe onto a post result is refused with a
  notice, since a swipe cannot be told from a script. The question lives in the navigation delegate, so the gate stays
  the one place a form can be sent again.
- 2026-11-06: HSTS is the browser's own list (work-queue best guess). M4's check and "Local addresses and plain HTTP" said a
  host under HSTS never shows the offer, and no text said how the browser knows. WebKit has no public query, so the browser
  records `Strict-Transport-Security` from main-frame HTTPS responses. It honours `max-age`, removal by `max-age=0`, and
  `includeSubDomains`, and it keeps the list in a file. A host WebKit preloaded but the browser never saw can still show the
  offer, and WebKit upgrades the load, so nothing downgrades. Clear Website Data empties the list, which amends "Website
  data" and M5's check. If wrong, the offer could show for a host that is under HSTS in WebKit, and the user's click would
  meet an upgraded load that fails again.
- 2026-11-06: Address classification refined (work-queue best guess). "Search from the address bar" said input with a space is
  always a search and input with a scheme is always an address, which conflicts for `note: buy milk` and for `file:` paths
  with a space. A space now wins, except for text that starts with `scheme://`. A bare IPv6 address is an address, and
  `localhost` is read by its host part so `localhost/app` loads. Text with a control character is refused. Whitespace in a
  query collapses. Only typed text searches. If wrong, a spaced `javascript:` text searches where it was refused, which sends
  the text to the engine and runs nothing.
- 2026-11-06: Load over HTTP and handoff mechanics (work-queue best guess). The offer needs the failing load to be the one whose
  HTTPS the browser assumed, so a redirect never earns it. `-1005` offers beside `-1200` and `-1004`, and a timeout does not.
  A certificate sign, a failed trust or an underlying certificate status, wins over `-1200`. A followed link to another app
  asks, and a followed `mailto:` link opens without asking, per "Schemes", both only after a real click, per the entry
  below. A script's or redirect's navigation never asks. The factory passes the browser three things, not one. If wrong,
  the offer could miss a host that resets the handshake.
- 2026-11-06: Handoff to other apps tightened (work-queue best guess). The first build counted any navigation WebKit calls a
  followed link as the user's. The prior rules: a followed link for another app asked, a followed `mailto:` link opened with
  no check, and the selected-tab and one-question guards came after the `mailto:` check. WebKit reports a script's
  `a.click()` that way, so a page could open the mail app with no gesture, from a background tab, and could loop the
  question. Now a link is the user's only when the web view saw a real mouse-up within one second before the decision,
  each mouse-up is used once, and every guard comes before `mailto:`. A script's click, a script's navigation, a redirect,
  an iframe, and a key press on a focused link are refused with a warning. A real click on `mailto:` in the selected tab
  still opens with no question. Amends "Schemes" and M4's check. If wrong, a key press on a link that should open an app is
  refused until the user clicks it.
- 2026-11-06: Offer rule made an allow-list (work-queue best guess). The prior rule offered for `-1004`, `-1005`, and any
  `-1200` that showed no certificate sign, which would offer for a `-1200` nobody understood. Now only `-1004`, `-1005`, and
  a `-1200` with a closed-connection status offer, and the walk covers every nested error. A certificate failure cannot
  reach the offer by construction. If wrong, the offer misses a server whose closed connection reports a status not on the
  list.
- 2026-11-06: HSTS file and error page lifetime (work-queue best guess). The prior rules: a file from a newer build started
  an empty list and was overwritten by the next change. Any move of an entry's expiry rewrote the file. An error page lasted
  until a commit or a load of the tab's own, so a failed Back or a page's failed navigation left an old offer live over the
  pane. Now a newer file is never written, a move of under an hour on a live entry records nothing, and a new provisional
  load clears the page. If wrong, a newer file's hosts are forgotten by this build until the file is replaced, and an entry
  can lag a renewal by an hour.
- 2026-11-06: ADR candidate (cuts across the system): web content hosted anywhere in uniterm may load plain HTTP, with
  no App Transport Security floor, so each applet that hosts a web view owns its own scheme gate. The key is app-wide,
  so the text viewer in UTERM-007 and the canvas in UTERM-010 inherit it. Declined by the user on 2026-11-06 as
  inconsequential. Found in UTERM-005 M1.
- 2026-11-06: ADR candidate (cuts across the system): a setting reaches an applet only through its factory, explicit and
  read live, and never through the applet reading the settings store or UserDefaults. Waits on the second applet that
  takes a setting, since this one instance cannot yet show whether settings belong in a per-applet bundle or on the applet
  contract. Found in UTERM-005 M4.
- 2026-11-06: ADR candidate (cuts across the system): content an applet saves from the network is quarantined per file and
  fails closed, and uniterm never sets the process-wide `LSFileQuarantineEnabled`, which could quarantine what the
  terminal's shells create. Waits on the second applet that writes fetched files. Found in UTERM-005 M6.

- 2026-11-06: M5 as built (work-queue best guess). The pane's undo-only part now carries a history record for each open
  tab. The text said it carried each tab's record, and M3 built only the closed tabs', so a closed pane came back with
  each tab's address and no history. A tab holding a pending record keeps it, and a tab with no page carries none.
  A restored address that "Schemes" refuses stays in the description untouched, since only a commit writes a URL. A
  committed `blob:` page is not stored and a restored `file:` address is kept. The first is what a commit writes, and the
  second is what a restore was given, so the two do not conflict. The store reaches each pane as a required argument,
  where the text named no path. Settings reports a clear's outcome and says so when the list of HTTPS-only hosts could
  not be emptied, which the text left open. "Website data" named the label "Default Profile" or similar
  and left its placement to review. It now reads "Default Profile" and sits at the trailing end of the toolbar, as a first
  placement for the user's review. "What restore loads" said nothing about a refused URL in the description. It now says the
  description keeps it. M5's fifth check said a refused restored tab shows "a message naming the URL". It now says an
  explanation in the pane naming the URL, with one history warning. The undo-only part is kept between history changes,
  so a pane close can carry a scroll position older than the last history change. A debug build reads `UNITERM_BROWSER_STORE=memory` so UI tests never reach the user's store. If
  wrong, a pane undo that should carry less history costs one description field to drop, and a clear that should ignore
  a newer HSTS file would report success while the file still holds hosts.

- 2026-11-06: M6 as built (work-queue best guess). "New windows and pop-ups" said WebKit's macOS default blocks a script with
  no gesture and the browser keeps it. WKWebView's macOS default allows it, and a script at page load opened a tab, so the
  browser now sets the preference to false. The same loop with a gesture opened 41 tabs, so a pane holds ten script-opened
  tabs, which the text did not bound. A pop-up from a background tab opens unselected and says so, a script closes only a tab a
  script opened, never the last, and never one with input or a download, and such a tab is not kept for reopen because its
  address can carry a code. "Schemes" and M6 said a `data:` download saves with or without a `download` attribute. A top-level
  `data:` navigation with none is a page before any response is known, so only `blob:` saves both ways. "Unsent input" said
  the script reports one boolean per tab. WebKit gives the native side no stable frame identity, so each frame sends a random
  token and a boolean, and the tab is marked while any frame is, which keeps one frame from clearing another's mark. A link
  in a subframe is never counted as the user's click, which closes a gap that let a real click in an iframe ask to open an
  app. Detach pauses then suspends media, since suspension alone let a pending play resume. Dialogs show in an overlay in the pane
  with bounds of five per load and sixteen held. The finished-download message cannot carry the origin and data addresses on
  read, since the system keeps them privately. If wrong, a stricter pop-up limit costs one constant, a download limit is a design
  choice left open, and a `data:` link with no attribute would need a response-time decision.

- 2026-11-06: M6 review fixes (work-queue best guess). The limit of ten tabs counted every tab WebKit asked for, so a user's
  eleventh click on a link opened nothing and warned falsely. It now counts only tabs a script opened. A real click on a
  link and a choice from the context menu are the user's, and those tabs never count and are never refused. The unsent-input
  ledger dropped a dirty frame past 64 and could read it as clean. It now keeps the tab marked until the next load, which
  fails on the side of asking. A script's `execCommand('insertText')` on a focused field raises a trusted event, so the
  check "synthetic input events never mark a tab" is narrowed to events a page dispatches, and the limit stays. The name
  cleaner drops every format and line-separator character, the invisible filler letters, and collapses every run of
  spaces. File work moved off the main thread, per ADR-08, with a finishing download still counted as running and a cancel
  that resolves once. A sweep removes leftover temporary files older than seven days at the first download of a launch. The
  Risks said the handler takes one boolean per tab and the status bar shows every download, and both now say what is built,
  with the downloads finding stated: nothing bounds how many a page starts. If wrong, the sweep age is one constant, and a
  download limit stays a design choice for the user.
- 2026-11-06: Cancelling a download waits for its first byte (work-queue best guess). A cancel of a download that WebKit had
  received no byte for restarted WebKit's network process, which dropped session cookies and in-flight loads for every pane.
  "Closing a tab or a pane during a download asks first and cancels it" now holds with one wait: the download leaves the list and
  the running count at once, and the cancel goes to WebKit with the first byte, or after 30 seconds. The text said nothing about
  the moment of the cancel. If wrong, the cost is a download that lingers up to 30 seconds after its pane closes.

- 2026-11-06: M7 as built (work-queue best guess). "Web content failure" said a hung process's web view is replaced the same
  way and left the bound and the signal open. The bound is 10 seconds and arms only on a user's reload, back, forward, or
  typed address. Any callback from the content process cancels it, since a hung process sends none and a slow server's
  process sends the first at once. A typed address loads in the new view after the history is restored. The text also said
  Reload builds a view from the URL and `interactionState` and left three cases open. A tab that never held a page stays
  blank with no message. A stopped tab that the user switches away from stays stopped. A pop-up's rebuilt view has no
  opener, which cannot be kept. M5's history read takes a nil `url` for a view with no page, so a stop falls back to the
  last record read from a live page and never replaces a record with nothing. The text said a stop
  clears the unsent mark. It also answers held dialogs and questions, and leaves downloads alone. The Risks gain a hung
  process that outlives its view, since no public call ends it. If wrong, a 10-second bound is one constant, a rebuilt
  typed address that should drop history costs one line, and a hung process that WebKit does end costs the risk entry.

- 2026-11-06: ADR candidate (cuts across the system): a web view whose content process hangs cannot be ended by public
  WebKit API, so any applet that hosts a web view and recovers from a hang leaves the hung process running until the app
  quits. Declined: a known issue, not a decision. The Risks carry it. Found in UTERM-005 M7. Overtaken on 2026-11-06 by
  the SIGKILL decision below.
- 2026-11-06: ADR candidate (cuts across the system): shipping code uses no private WebKit or AppKit API, and private calls
  are allowed in test code only. Declined by the user on 2026-11-06 as inconsequential, and no longer true: the product
  reads one private WebKit property to end a hung process. Found in UTERM-005 M7.
- 2026-11-06: M7 review fixes (work-queue best guess). The hang rule said any callback of the navigation delegate cancels the
  bound. It now counts the UI delegate's callbacks too, and the bound never replaces a page that holds a dialog. The prior
  rule would have rebuilt a page that waits for the user. The prior rule also replaced a busy page with unsent input without
  asking, which loses the input. It now asks first, through the host's confirmation, and replaces on yes only. The prior rule
  reloaded a tab after the bound even when the user had switched tabs or detached the pane, which "What restore loads" and
  ADR-05 reject. Now such a tab drops the hung view and loads when selected or attached. The production clock stops while
  the machine sleeps. A stopped tab whose page came from a form said that Reload loads the page again, and it loads a blank
  one. The message and the pane now say so. M6's downloads: a cancel after the first byte never reached WebKit, and a finish
  that beat a cancel left its file. If wrong, the question for unsent input is one rule to remove, and the form message is
  two strings.
- 2026-11-06: Web content failure restores "when selected or attached" (work-queue best guess). The text said a tab that
  stopped while unselected or in a detached pane "loads when next selected". A selected tab in a detached pane has no
  selection event, and the attach loads it, as "What restore loads" does for a restored pane. The text now says selected or
  attached. If wrong, a detached pane's selected tab would wait for the user to select it, which no event offers.
- 2026-11-06: Row review fixes (work-queue best guess). M3's As built said M8's controller commands never set the resend
  intent, so they never ask. That is false, since the tab's reload, back, and forward set it unconditionally. M8 now
  checks for an intent-free path, and names two things the row did not build: loading a controller's background tab at
  once, and asking before a download in a controller tab. The facts that the row built none of the three moved from M8's
  checks to M3's As built. "Any page can write files" ended on a design choice not yet
  made, while "Design Decisions (Open)" said none. The Risk now states an accepted gap with a revisit hook. The
  Amended markers were collapsed to one per decision and milestone, since a later revision replaces the marker. The
  texts on "Schemes", "Downloads", and the milestones that changed keep their one marker. "Schemes" said a tab shows at
  most one question. The pane now shows one at a time, of any kind, since the window queued a second sheet that could
  outlive its tab. The text said nothing about Reload on a tab with a history record and no address. It now loads from
  the record. A page's title is cleaned once, at the applet, for the tab bar, the pane title, notices, and questions.
  The restore origin of a notice ends at the user's first click in the tab. Terminal titles were raw before this row and
  are left alone. A single-slot record of the load that a policy decision ended was traced: WebKit reports an
  interrupted load only for a download here, and each download sets the slot itself, so no genuine failure was seen
  swallowed. Nothing changed. If wrong, a stale slot could hide one failure notice for an address a policy refused
  earlier, and the fix is to key the slot to the navigation.

- 2026-11-06: Profile button (the user's choice in a hands-on review, not a best guess). "Website data" said every pane
  shows the default profile as a text label, "Default Profile", at the trailing end of the toolbar with no selector.
  M5's As built said the same. The label is now a borderless icon button using `person.crop.circle`. Clicking it shows a
  transient popover that names "Default Profile" and says every browser pane shares the profile's logins and site data.
  The popover has no controls. The user expects it to hold creating and switching profiles later, and nothing for that
  is built. The identifier `browser-profile` stays, and the accessibility label and tooltip read "Profile: Default
  Profile". The reason is that a text label took toolbar width and had no place to grow into a profile control. M5's
  As built and its UI test note now describe the button. M5 stays DONE.

- 2026-11-06: End a hung content process with SIGKILL (the user's choice in a hands-on review, not a best guess). The
  Risks said a hung process outlives its web view, that no public call ends it, that the private ones cannot ship, and
  that the loss was accepted. M7's As built said production code cannot end it. "Web content failure" said nothing about
  the process. Measured under `swift test`: the process survived release of its view for 61 seconds, a non-persistent
  store, a navigation to `about:blank`, private `_close`, and private `_killWebContentProcess` for 30 seconds. SIGKILL to
  the id from `_webProcessIdentifier` works, and the user chose to ship it. The tab now kills the process when the hang
  bound replaces its view. A tab or pane the user closes without a reload also leaves the process, since only a reload
  arms the bound. So a close probes the page, and no reply within the same 10-second bound kills the process. The
  Risks, "Web content failure", M7's check and As built, and the test comment that said nothing private ships are
  rewritten. The private read lives in one type behind `responds(to:)`, refuses ids at or below 1 and non-WebKit paths,
  and falls back to the old behaviour when a macOS drops the property. If wrong, a signal that reaches a recycled id is
  stopped by the path check, and a probe that kills a live page needs a page that is alive and silent for 10 seconds.
- 2026-11-06: Three ADR candidates declined (the user's choice, since the user called them inconsequential). No private
  API in shipping code is declined, and the SIGKILL decision above ships one. Plain HTTP in hosted web content with no
  App Transport Security floor is declined. One question per pane is declined as an ADR, and it stays a rule of this
  proposal. The two candidates that wait on a second applet, the settings factory and the download quarantine, stay as
  they were.

- 2026-11-06: Dialogs offer to stop (the user's choice in a hands-on review, not a best guess). "The applet contract" and
  M6's As built said a page gets five dialogs between loads and the rest are dismissed with one warning. The browser decided
  for the user and a legitimate page lost its sixth dialog. The limit and its automatic dismissal are removed. From a
  page's second dialog in one load, the overlay offers "Don't show more from this page". Choosing it answers the current
  dialog as Cancel would. It also dismisses the tab's other waiting dialogs, which the choice did not name, since the
  user said stop. Every further dialog from that page is dismissed until its next load, with one warning through the
  notice path used before. The 16 waiting dialogs stay as a memory guard. If wrong, a stop that should leave waiting
  dialogs alone costs one line in the applet.

- 2026-11-06: Script tabs ask after ten (the user's choice in a hands-on review, not a best guess). "New windows and
  pop-ups" and M6's As built said a pane holds at most ten script-opened tabs, the rest of a loop opens nothing, and
  the pane says so once. The browser decided for the user. The eleventh call is still refused, since WebKit needs the
  answer at once, but its address is kept, and the pane asks whether the page may open more. Yes opens the kept addresses
  as ordinary unselected tabs with no opener and lifts the limit for that page until its next load. No drops them,
  warns once, and refuses the page until its next load. The list holds at most 50 addresses, and a call with no address is
  counted and not kept. Two choices were not in the user's text. The question names the count the pane holds and does
  not quote the loop's total, since it is built at the eleventh call. A question that finds another up keeps its list
  and asks once the pane is free, because dropping or stacking it would lose the user's chance to answer. The stale
  question of a tab or pane that closed stays on screen until the user answers, as the other questions here do, and its
  answer does nothing. If wrong, the 50 is one constant, and asking only for the selected tab's page would be one guard.

- 2026-11-06: Downloads ask after three per load (the user's choice in a hands-on review, not a best guess). "Downloads"
  said nothing limited how many a page starts, and the Risks called that an accepted gap with a revisit hook. M6's As
  built said a limit needed a design choice and built none. Now a page's downloads that no click of the user's started
  count per load. The first three start. The fourth holds its policy decision and the pane asks whether the page may
  download more. Yes starts it and lifts the limit until the page's next load. No cancels at the decision, warns once,
  and refuses the page's further such downloads with no further question until its next load. A click and a
  typed address never count. The brief did not say how a click is told from a script for a download that comes as a
  response, and WebKit gives the response no link to its click. The tab follows the navigation: the click arms a mark,
  WebKit's provisional start confirms it, and a redirect continues it. The response, a failure, a commit, or any action
  decision that does not continue it ends it. A click that starts no main-frame navigation is never confirmed, so it
  cannot lend the mark to a later script. An earlier build cleared the mark only at a response, which let a click on a
  `#fragment` pass a later script download as the user's. That is fixed in this entry. One window stays: a script that
  navigates after a click's action is allowed and before WebKit confirms it could pass for the click's. A frame's
  attachment is never the user's. If wrong, the three is one constant, and a stricter rule needs the response tied to
  its action, which WebKit does not offer.

## References

- Original write-up: `~/projects/private_specs/uniterm/spec/research/original-writeup.md`, APPLET-3
