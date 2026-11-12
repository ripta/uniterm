# UTERM-019: Browser Automation for Controllers

**Status:** draft
**Created:** 2026-11-11
**Updated:** 2026-11-11

## Dependencies

- UTERM-005 M8, for controller tabs, the browser command schema, and the browser navigation and browser read
  permissions
- UTERM-004 M6, through UTERM-005 M8, for the permission framework the new permissions join
- UTERM-003, for the `uniterm` Janet module and its API version

## Impacts

- UTERM-005 — "Control": its line "No command evaluates script in a page" stays true for a controller without browser
  script, and stops being true for one with it. That line is superseded in part once this proposal is accepted.
- UTERM-004 — "Permission scopes and approval flow" and "Verified artifact and run binding": four new permission kinds
  join the descriptor's permission set.
- The follow-up inspector-bridge proposal reuses "Capabilities" and "Page events", and adds private-API capabilities
  to the same set.

## Summary

Controller scripts drive their own browser tabs beyond UTERM-005 M8's navigate and read. They run JavaScript, follow
page events, answer page dialogs, capture pages, read and write cookies, and send trusted input. Everything here uses
public WebKit API. A capabilities command tells a script what this build can do.

## Motivation

Chrome exposes the Chrome DevTools Protocol on a debugging port, and tools such as Puppeteer drive pages through it.
WebKit has no such port. The findings note, `spec/reports/20261111-wkwebview-automation-vs-cdp.md`, shows that most of
what that protocol is used for can be built on public WebKit API. UTERM-005 M8 gives a controller navigation and URLs.
That is not enough to log in, fill a form, wait for a page, or check what it shows.

The private-API surface, such as network observation and the debugger, depends on a spike and belongs to the follow-up
inspector-bridge proposal. This proposal holds the work that has no such unknown.

## Design Decisions (Settled)

### Scope of every command

Decision: every command in this proposal acts only on a tab the controller opened, as UTERM-005 "Control" defines it.

- Aimed at any other tab, a command returns the structured error M8 returns.
- A tab a page opens from a controller tab belongs to no controller, as in M8.
- The tab and pane references are the ones UTERM-003 defines. No command addresses a tab by its index, per ADR-02.

Rationale: M8 already protects the user's own tabs this way. The new powers are stronger than navigation, so the
boundary matters more, not less.

### Permissions

Decision: four new typed permissions, separate from M8's browser navigation and browser read and from each other.

- Browser script covers running JavaScript, injecting scripts, and answering page dialogs.
- Browser input covers synthesized mouse, key, and scroll events.
- Browser cookies covers reading and writing cookies, per "Cookies".
- Browser capture covers snapshots and PDF output.
- Page events fall under browser read, since they carry URLs. User agent, zoom, and print-media emulation fall under
  browser navigation. Find in page falls under browser read.
- Each permission's approval review states its meaning. Browser script says a script can read and change anything the
  page shows, signed in as the user. Browser cookies says it returns session cookies, including HttpOnly ones.
- An approval stored before these permissions existed cannot cover them, per ADR-09.

Rationale: ADR-09 makes each power its own permission, and says one granted power never silently grants another. A
single automation permission would hand input and cookies to any controller that only needed JavaScript.

### Capabilities

Decision: a capabilities command returns the set of capabilities this build supports, as symbols.

- Public-API capabilities always report as available.
- The answer comes from state uniterm computes once at startup. It never waits on WebKit or on a script, per ADR-08.
- A command whose capability is unavailable returns a structured error naming the capability. It never crashes the
  app or the helper.
- The follow-up inspector-bridge proposal adds private-API capabilities to the same set, from its startup probe.

Rationale: a script can check before it relies on something, and a failure that slips past the check still reaches the
caller as an error.

### Page events

Decision: each controller tab keeps a bounded buffer of page events. A script reads it with a cursor.

- The events are navigation started, committed, finished, and failed, plus server redirect, web content process
  terminated, and dialog opened.
- A next-events command takes a tab, a cursor, and a timeout. It replies when events past the cursor exist or the
  timeout passes. The reply carries the events, the new cursor, and how many events were dropped since the cursor.
- A full buffer drops its oldest events and counts them. It never grows past its bound, and never blocks the app.
- The buffer exists only while the tab belongs to the controller. Closing the tab or ending the run discards it.
- Remote callers still receive no pushed applet events. UTERM-004's "Exec wire format" line stands. This is a reply to
  a command.

Rationale: the cursor means nothing is lost between reads, and the dropped count makes overflow visible. It needs no
change to the wire. The inspector-bridge proposal's console and network streams can use the same shape. A push stream
would amend UTERM-004 and the wire protocol, and needs rules for slow handlers and reentrancy. One-shot waits miss
events between waits and stall on a dialog during load.

### Script helpers

Decision: uniterm ships Janet helpers that hide the cursor bookkeeping, built into the helper binary beside the C host
functions.

- They are plain functions, not macros, such as a wait-for that waits on one event type and an each-event that calls a
  handler per event.
- They are part of the `uniterm` module family and follow its `uniterm/api-version`.
- They are built in because the default sandbox denies loading modules.

Rationale: the raw next-events loop is correct but wordy. Shipping the helpers means every script gets the same
correct handling of cursors and dropped events.

### Page JavaScript

Decision: a run-script command uses WebKit's `callAsyncJavaScript`.

- Arguments pass as typed values, never by building source text.
- The command awaits a returned promise and replies with its value or its error.
- It can target a frame of the tab, per "Frames" in the open decisions.
- The reply is page-controlled data. uniterm validates its size and shape like any other script input.
- A script injection command adds a script at document start or end, in the main frame or all frames, for the tab's
  later loads.

Rationale: typed arguments rule out injection through string building. Awaiting promises matches how pages work.

### Dialogs in controller tabs

Decision: a script with browser script answers alert, confirm, and prompt dialogs in its tabs.

- A dialog opening appears as a page event. An answer-dialog command accepts, dismisses, or supplies prompt text.
- Waiting for the answer never blocks the main thread, per ADR-08. WebKit's completion handler is held, as
  `PageDialog` already holds it.
- A detached pane holds its dialogs until reattach, per ADR-05.

Rationale: a page that calls `confirm()` stops until it gets an answer. Without this, a script cannot get past it.

### Cookies

Decision: a script with browser cookies reads and writes cookies only for the origins currently loaded in its tabs.

- It uses `WKHTTPCookieStore`, so HttpOnly cookies are included.
- A cookie for any other origin is refused with a structured error.

Rationale: the browser has one persistent website data store, per UTERM-005 "Website data". Access to the whole store
would hand a controller session cookies for sites it never opened. A controller can already reach an origin's cookies
by navigating there, which browser navigation allows.

### Trusted input

Decision: synthesized input never takes keyboard focus.

- Input goes only to a controller tab in a pane that does not hold key focus.
- uniterm builds AppKit events and delivers them to that tab's web view directly. The first responder never changes.
- Synthesized keys go only to the web view. They never reach window keys or the app menu, per ADR-04.
- Aimed at a pane with key focus, an input command returns a structured error.

Rationale: M8 keeps controllers from taking focus, to protect what the user is typing. Events from page JavaScript are
untrusted, and pages refuse them for pop-ups, clipboard writes, and many form controls. Events WebKit receives through
AppKit count as real input.

### What is never restored

Decision: injected scripts, the user agent, zoom, and print-media settings that a controller sets are never saved in
the layout. A relaunch or an undo never re-runs a controller's scripts, per ADR-03.

## Design Decisions (Open)

### Content world

Where run-script and injected scripts run by default.

- An isolated world. The page cannot see or tamper with the controller's code, but the script cannot read page
  JavaScript state.
- The page's own world. The script sees everything the page's scripts see, and the page can interfere with it.
- The caller names the world on each call, with one of the two as the default.

### Frames

How a script names a frame for run-script and injection.

- A frame ID uniterm assigns and reports in page events.
- A selector path, such as an iframe's name or URL. It is readable, but not unique.
- Main frame only in this proposal, with frames added later.

### Capability names and the unavailable error

The symbols the capabilities command returns, and the error kind for an unavailable capability.

- Reuse the existing `unsupported` kind, with the capability named in the message.
- Add a new `unavailable` kind, so a script can tell "this build cannot" from "this applet has no such command".

### An unanswered dialog

What happens when a script does not answer a dialog.

- A timeout, then dismiss.
- A timeout, then show the dialog to the user in the pane.
- Show it to the user at once, and let the script answer first if it can.

### Buffer size and event contents

How many events a tab's buffer keeps, and how much of a URL an event carries. A full URL may carry tokens, which is
why browser read covers events.

### Injection lifetime

How long an injected script lasts: until removed, until the next top-level navigation, or for the run.

### Full-page snapshot

Whether a snapshot can cover the whole page. Candidates: `takeSnapshot` with a large rect, scroll-and-stitch, or PDF
only.

### Permission descriptor format

How the four permissions enter the controller descriptor. UTERM-004's format 1 knows only `pane-control` and
`capability`. Candidates: new kinds in a format 2, coordinated with how UTERM-004 M6 and UTERM-005 M8 add browser
navigation and browser read, or browser permissions as one kind with typed scopes.

### Helper names

Which helpers ship, and whether they live in `uniterm` or a separate built-in module such as `uniterm/browser`.

## Risks

- **A controller with browser script acts as the user on any site it opens** — likelihood: medium, impact: high. It
  can read pages and submit forms signed in as the user. Mitigation: browser script is its own permission, its review
  says so, and it reaches only the controller's own tabs.
- **Cookie values leave the app** — likelihood: medium, impact: high. A session cookie a controller reads works outside
  uniterm. Mitigation: browser cookies is its own permission, limited to the origins the controller's tabs have loaded.
- **WebKit may refuse key events delivered without focus** — likelihood: medium, impact: medium. If so, keyboard input
  cannot work under "Trusted input". Mitigation: the input milestone's first check proves it before anything builds on
  it. If it fails, keyboard input reopens as a design question.
- **Page data in replies is hostile input** — likelihood: high, impact: medium. A page controls what run-script
  returns. Mitigation: replies pass the same size and shape validation as any command argument, and the wire limits
  apply.
- **The capability names become a published contract** — likelihood: high, impact: medium. Scripts will depend on them,
  and renaming one breaks them. Mitigation: the names follow `uniterm/api-version`, and a rename takes a version bump.

## Milestones

### M1: Capabilities and permissions

**Status:** NOT STARTED

Starts after UTERM-005 M8.

- A capabilities command returns every capability in this proposal, each reported as available
- The reply comes from startup state, and a test shows it never waits on WebKit
- A command whose capability is off returns a structured error that names it, and the helper keeps running
- Browser script, browser input, browser cookies, and browser capture are typed permissions with review text
- A controller with only M8's permissions gets a structured error from every command in this proposal
- An approval stored before these permissions existed covers none of them

### M2: Page events

**Status:** NOT STARTED

- Navigation started, committed, finished, and failed, server redirect, content process terminated, and dialog opened
  each appear in the tab's buffer
- Next-events replies at once when events past the cursor exist, and after the timeout otherwise
- A full buffer drops its oldest events, and the next reply reports how many
- Closing the tab or ending the run discards the buffer, and a later read returns a structured error
- The shipped helpers wait for one event type and call a handler per event, and both report dropped events
- A tab the controller did not open has no buffer

### M3: Page JavaScript and dialogs

**Status:** NOT STARTED

- Run-script passes typed arguments and returns a promise's value or its error
- An oversized or malformed reply is refused with a structured error
- An injected script runs at the chosen time in the chosen frames on later loads
- An alert, a confirm, and a prompt in a controller tab each appear as an event, and answer-dialog answers them
- A dialog waiting for its answer never blocks the main thread
- A detached pane holds its dialog until reattach
- A relaunch and an undo run none of the controller's injected scripts

### M4: Capture and page settings

**Status:** NOT STARTED

- A snapshot returns an image of the tab's viewport, and PDF output returns a document
- User agent, zoom, and print-media emulation apply to the tab and are never saved in the layout
- Find in page returns its match result

### M5: Cookies

**Status:** NOT STARTED

- A script reads and writes cookies, HttpOnly ones included, for an origin its tab has loaded
- A cookie for any other origin is refused with a structured error

### M6: Trusted input

**Status:** NOT STARTED

- A key event delivered to a controller tab's web view without changing the first responder reaches the page as
  trusted input, or the result is recorded and keyboard input goes back to design
- Clicks, scrolls, and typing reach the page as trusted events
- An input command aimed at a pane with key focus returns a structured error
- A synthesized Cmd-W, Cmd-T, or other window key never reaches the window or the app menu

## Decision Log

- 2026-11-11: Drafted from the findings note `spec/reports/20261111-wkwebview-automation-vs-cdp.md`. The user chose a
  bounded event buffer read with a cursor, over a push stream and one-shot waits, after seeing a sketch of each. The
  user chose four new permissions, cookie access limited to the origins in the controller's tabs, and input that never
  takes focus. The user asked for shipped Janet helpers so the event loop is not verbose.
- 2026-11-11: Placing page events under browser read, page settings under browser navigation, and find under browser
  read were best guesses in the outline. The user approved the outline that listed them.
- 2026-11-11: UTERM-005 "Control" says "No command evaluates script in a page." It gets a "Superseded in part by
  UTERM-019" marker when this proposal is accepted, not while it is a draft.
- 2026-11-11: ADR check: no conflicts and no supersessions. ADR-02, ADR-03, ADR-04, ADR-05, ADR-08, and ADR-09 shape
  the settled decisions above. The capability model is a possible ADR candidate, to raise only if the inspector-bridge
  proposal makes it span every applet.

## References

- Findings note: `spec/reports/20261111-wkwebview-automation-vs-cdp.md`
- [ADR-02](../adr/ADR-02-pane-tree-nodes-have-stable-ids.md): no addressing by index
- [ADR-03](../adr/ADR-03-restored-state-never-runs-a-program.md): restore never runs a controller's scripts
- [ADR-04](../adr/ADR-04-uniterm-owns-key-bindings-and-terminal-config.md): synthesized keys never reach window keys
- [ADR-05](../adr/ADR-05-applet-lifecycle-events-and-applet-responses.md): a detached pane holds dialogs
- [ADR-08](../adr/ADR-08-ui-responsiveness.md): no main-thread wait on a script or WebKit
- [ADR-09](../adr/ADR-09-control-authority-requires-authenticated-identity-and-explicit-scope.md): each power is its
  own permission
