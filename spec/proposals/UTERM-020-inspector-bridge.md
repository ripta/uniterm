# UTERM-020: Inspector Bridge

**Status:** draft
**Created:** 2026-11-11
**Updated:** 2026-11-11

## Dependencies

- UTERM-019, for controller tabs' capabilities, page events, permissions, and trusted input
- UTERM-005 M8 and UTERM-004 M6, through UTERM-019

## Impacts

- UTERM-019 — "Capabilities": the set gains private-API capabilities, reported from this proposal's startup probe.
- UTERM-019 — "Page events": the buffer gains console, exception, and network event types.
- UTERM-019 — "Trusted input": script evaluation with a user gesture falls under browser input.

## Summary

Controller scripts get console output, network traffic with bodies, request interception, emulation, and debugging in
their own browser tabs. These reach past public WebKit API. uniterm gets them by driving a hidden Web Inspector
frontend, and by calling a few private WebKit methods directly. A compatibility layer fails closed: a missing method
turns a capability off, and a failure at runtime reaches the script as an error.

## Motivation

UTERM-019 covers what public WebKit API allows. The findings note, `spec/reports/20261111-wkwebview-automation-vs-cdp.md`,
lists what it cannot reach: every request and response with bodies, interception and mocking, throttling, console
output from workers, the debugger and profilers, CSS matched rules, and timezone emulation. Those are the parts of the
Chrome DevTools Protocol that make a browser debuggable from a script.

WebKit's own Web Inspector already speaks a protocol with all of them. `-[WKWebView _inspector]` returns a
`_WKInspector`, and its `inspectorWebView` returns the inspector frontend, a WKWebView owned by uniterm's process. A
bridge script in that frontend could send protocol commands and receive events. The note's probe found these names on
macOS 26.6.2. Nobody has tried the bridge yet.

uniterm will not ship on the App Store, so private API is acceptable on that ground.

## Design Decisions (Settled)

### Scope

Decision: every command acts only on a tab the controller opened, as UTERM-019 "Scope of every command" defines it. A
tab a page opens from a controller tab belongs to no controller.

### What scripts see

Decision: typed commands for each area, plus raw protocol passthrough behind its own permission.

- Console, network observation, network control, emulation, and debugging each get typed commands with schemas.
  uniterm's command names stay fixed when WebKit's protocol changes underneath them.
- A raw command sends one inspector protocol message to a controller tab and returns the reply. Its approval review says
  it grants everything the inspector can do in that tab, including what the other permissions gate.
- Raw replies are page-controlled data, validated for size and shape like any other reply.

Rationale: typed commands keep the permission split meaningful and hide WebKit's churn. The raw command reaches what
nobody has curated yet, such as most debugger detail, for a controller the user trusts that far.

### Permissions

Decision: five new typed permissions plus one for raw, each separate, per ADR-09.

- Browser console covers console messages and exceptions, workers included.
- Browser network read covers observing requests and responses, and reading bodies.
- Browser network control covers interception, mocking, throttling, and cache control.
- Browser debug covers the debugger, profilers, heap, and CSS matched rules.
- Browser emulation covers timezone and device-scale overrides.
- Browser inspector raw covers raw protocol passthrough.
- Script evaluation with a user gesture falls under UTERM-019's browser input. It grants the same real user activation
  that synthesized input does.
- An approval stored before these permissions existed covers none of them.

Rationale: ADR-09 makes each power its own permission. Bodies can hold credentials, so reading them is its own grant.
Interception can change what the user's signed-in session sends, so it is separate from reading.

### Fallback order

Decision: if a route fails, the next one is tried in this order.

1. The hidden inspector frontend bridge.
2. Safari's remote-inspector protocol to `webinspectord`. It likely requires an Apple-only entitlement.
3. Only the private methods uniterm calls directly, per "Direct private methods". Console, network bodies,
   interception, throttling, and debugging are deferred.
4. A local proxy that terminates TLS with a uniterm CA the user trusts. This is a last resort and needs its own
   decision before anyone builds it.

If both spikes fail, M5 through M9 move to deferred with this revisit hook:

**Revisit:** when a macOS release changes `_WKInspector` or the inspector frontend; on or after 2027-06-15 (the
expected first beta of the next macOS release)

Rationale: the bridge is in-process and needs no entitlement. `webinspectord` is the route Safari itself uses. A
trusted CA could vouch for any site on the Mac if its key leaked, so it comes last.

### Direct private methods

Decision: these private methods stand alone and do not depend on either spike.

- `_setResourceLoadDelegate:` observes every resource load, without bodies and without modifying anything.
- `_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:` runs script with user
  activation.
- `_WKProcessPoolConfiguration.timeZoneOverride` sets the timezone.
- `_setOverrideDeviceScaleFactor:` sets the device scale.

### The private API boundary

Decision: one module owns every private WebKit call, and a make check fails the build when another module reaches
private WebKit API.

- The module holds the startup probe, every guarded call, and the bridge script.
- It exposes uniterm's own interface to the browser applet. The applet never names a private selector.
- The check follows the pattern of `check-ghosttykit-imports`.

Rationale: ADR-01 wraps libghostty, an unstable dependency, behind uniterm's own protocol in one module. Private WebKit
API is less stable than libghostty, and uniterm cannot pin it, since WebKit ships with macOS.

### Compatibility

Decision: private API fails closed.

- Every private call checks `respondsToSelector:`, or the class or symbol lookup, before calling. Nothing links against
  a private symbol, so a removed one cannot stop the app from launching.
- A startup probe checks every private class, selector, and protocol domain this proposal uses. It reports the results
  into UTERM-019's capabilities set.
- A command whose capability is off, or whose private call fails at runtime, returns a structured error naming the
  capability. It never crashes the app or the helper.
- The probe checks names only, takes milliseconds, and runs with the unit tests.
- Behavioral smoke tests drive real web views in their own make target, not on every test run. They are meant for each
  new macOS beta and point release, since a probe cannot catch a method whose signature or meaning changed.

### Isolation

Decision: the bridge adds no helper process, and keeps page data out of uniterm's process except as bounded messages.

- The frontend's JavaScript runs in a WebKit content process, as the browser's own pages do. M1 proves this before
  anything builds on it. If it is false, ADR-07 needs an exception stated with its bound, and the work stops for a
  decision.
- No bridge call blocks the main thread, per ADR-08. Body size and event volume are bounded before they reach it.
- Janet stays in the existing helper, per ADR-10.

### What is never restored

Decision: interception rules, throttling, overrides, breakpoints, and raw subscriptions are never saved in the layout,
per ADR-03. They end with the run or the tab.

## Design Decisions (Open)

### Web Inspector on a controller tab

What happens when the user opens Web Inspector on a controller tab while the hidden frontend is connected. Candidates:
refuse the user's inspector while a controller holds the tab, end the controller's bridge and tell it, or show the
user's inspector and keep both if WebKit allows it.

### Response bodies

How large a body may be, and how it reaches the script. Candidates: inline in the event up to a limit, or fetched on
request by a request ID while WebKit still holds it.

### A paused page

What happens when the debugger pauses a page and the script stops responding. Candidates: resume at run end only, resume
after a timeout, or let the user resume from the pane.

### Timezone scope

`timeZoneOverride` sits on the process pool configuration, so it may apply to every page, not one tab. Candidates:
offer it only when no user tab would be affected, give controller tabs their own configuration if WebKit allows it, or
use the inspector protocol's override instead if it is per page.

### Raw events

Whether events from raw subscriptions land in UTERM-019's per-tab buffer, or in a buffer of their own.

### Protocol drift

How the startup probe detects inspector protocol changes. Candidates: read the protocol definitions the frontend loads
and check each command uniterm uses, or send a harmless command per domain at first use.

### Untested macOS builds

Whether private capabilities turn off on a macOS build that the smoke tests have not passed on. Candidates: off until
the smoke tests record a pass for that build, or on with a warning.

## Risks

- **A macOS update breaks a private path in a way the probe cannot see** — likelihood: high, impact: medium. A method
  keeps its name and changes its meaning. Mitigation: the smoke tests run on each beta and point release, and every
  failure reaches the script as an error.
- **The bridge depends on the inspector frontend's internal JavaScript** — likelihood: high, impact: medium. That code
  has no contract at all. Mitigation: the bridge lives in the one private module, and the probe checks for the objects
  it uses.
- **Network read hands a controller the user's credentials** — likelihood: medium, impact: high. Bodies and headers can
  hold tokens. Mitigation: network read is its own permission, its review says so, and it covers only controller tabs.
- **Interception can change what a signed-in session sends** — likelihood: medium, impact: high. Mitigation: network
  control is its own permission, limited to controller tabs.
- **Raw passthrough grants everything the inspector can do** — likelihood: medium, impact: high. Accepted: its review
  says so, and it is the only path to uncurated domains.
- **Both spikes fail** — likelihood: medium, impact: high. Most of this proposal would then be undone. Mitigation: the
  spikes come first, and "Fallback order" names what follows.
- **The capability names become a published contract** — likelihood: high, impact: medium. Mitigation: the names follow
  `uniterm/api-version`, as UTERM-019 settles.

## Milestones

### M1: Inspector bridge spike

**Status:** NOT STARTED

Starts after UTERM-019 M1.

- A hidden inspector frontend connects to a controller tab without showing a window, or the result is recorded
- A bridge script in the frontend sends one protocol command and receives its reply and one event, or the result is
  recorded
- Whether the frontend's JavaScript runs outside uniterm's process is recorded, with how it was measured
- Whether the user can still open Web Inspector on that tab is recorded
- The result and the macOS build are recorded in the As built block, and the user rules on the next step

### M2: webinspectord spike

**Status:** NOT STARTED

Runs only if M1 shows the bridge cannot work. Otherwise it is dropped, with the user's approval.

- Whether uniterm can connect to `webinspectord` and reach its own web views is recorded, with the error if it cannot
- The user rules on the next step

### M3: Private API module and compatibility

**Status:** NOT STARTED

- One module holds every private WebKit call, and a make check fails when another module reaches private WebKit API
- The startup probe reports each private capability into the capabilities set
- A capability whose name is missing reports off, and its command returns a structured error
- A private call that fails at runtime returns a structured error, and the app and the helper keep running
- The name probes run with the unit tests in milliseconds
- A separate make target runs the behavioral smoke tests

### M4: Direct private methods

**Status:** NOT STARTED

- Resource-load observation reports each load of a controller tab as a page event, without bodies
- Script evaluation with a user gesture opens a pop-up that untrusted script cannot
- Timezone and device-scale overrides apply, and the timezone override's reach is recorded
- Each has a smoke test

### M5: Console and exceptions

**Status:** NOT STARTED

- Console messages and uncaught exceptions from a controller tab appear as page events, workers included
- Event volume past the bound drops the oldest events and counts them
- A smoke test covers both

### M6: Network observation

**Status:** NOT STARTED

- Every request and response of a controller tab appears as a page event with its headers
- A script with network read gets a response body within the size limit
- Bodies past the limit are refused with a structured error and never reach the main thread whole
- A smoke test covers a page, a subresource, and a fetch

### M7: Network control

**Status:** NOT STARTED

- A script intercepts a request and lets it continue, changes it, or answers it with a mock
- Throttling and cache control apply to the controller tab only
- Interception rules end with the run
- A smoke test covers each

### M8: Debugging

**Status:** NOT STARTED

- A script sets a breakpoint, receives the pause as an event, and resumes
- A profile and a heap snapshot return within their size limits
- CSS matched rules return for a node
- A paused page follows the rule settled under "A paused page"

### M9: Raw protocol passthrough

**Status:** NOT STARTED

- A raw command sends one protocol message and returns its reply
- A controller without browser inspector raw gets a structured error
- An oversized or malformed raw reply is refused with a structured error

## Decision Log

- 2026-11-11: Drafted from the findings note `spec/reports/20261111-wkwebview-automation-vs-cdp.md`, after UTERM-019.
  The user chose typed commands plus a raw escape, five permissions plus raw, and one private module with a make
  check. The user set the fallback order: the bridge, then `webinspectord`, then direct private methods. A uniterm CA
  proxy comes last, since the user is wary of installing one.
- 2026-11-11: Placing user-gesture script under browser input was a best guess in the permission options. The user
  chose that option. The "Isolation" points come from the ADR check. The user approved the outline that listed them.
- 2026-11-11: ADR check: ADR-07 and ADR-08 need the frontend's process and the main thread's load addressed, which
  "Isolation" does. ADR-09 shapes "Permissions". ADR-01's pattern shapes "The private API boundary". Possible ADR
  candidate: private WebKit as a dependency, mirroring ADR-01. A related "no private API in shipping code" candidate
  was declined before, so it is not raised.

## References

- Findings note: `spec/reports/20261111-wkwebview-automation-vs-cdp.md`
- [ADR-01](../adr/ADR-01-libghostty-behind-terminal-surface-protocol.md): the pattern for an unstable dependency
- [ADR-03](../adr/ADR-03-restored-state-never-runs-a-program.md): nothing a controller sets is restored
- [ADR-07](../adr/ADR-07-failure-isolation.md): failure isolation
- [ADR-08](../adr/ADR-08-ui-responsiveness.md): no main-thread wait
- [ADR-09](../adr/ADR-09-control-authority-requires-authenticated-identity-and-explicit-scope.md): each power is its
  own permission
- [ADR-10](../adr/ADR-10-app-unsandboxed-helpers-sandboxed.md): no new helper
