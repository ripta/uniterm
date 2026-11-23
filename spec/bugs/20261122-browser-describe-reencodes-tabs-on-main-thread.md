# The browser re-encodes every tab record on the main thread at each change

**Status:** open
**Found:** 2026-11-22, during the design critique of UTERM-051
**Validation:** mechanism confirmed by reading the code; cost not measured

## Observed

`BrowserApplet.describe` builds its payload with `JSONValue(encoding:)` on the main thread. That encodes every tab
record to bytes and decodes the bytes back into a `JSONValue` tree.

The window asks for a description at every change the applet reports. A page chooses how often its title changes. So
each title change re-encodes the whole pane. The cost grows with the tab count.

The undo part is cached until a tab's history or the closed tabs change. The tab records are not cached.

## Cause

ADR-08 allows only local work whose duration uniterm bounds on the main thread. A pane has no tab cap, so this work has
no bound. The layout save moved its encode and write off the main thread. The description that feeds it is still built
on the main thread.

## Repro

Not run. A pane of 50,000 tabs whose selected page changes its title in a loop should show the cost on the main thread.

## Fix

Not settled. Candidates are caching the tab-record part the way the undo part is cached, or building the payload off
the main thread. UTERM-051 may change `AppletDescription`'s payload form, which bears on both.
