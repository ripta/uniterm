# The browser re-encodes every tab record on the main thread at each change

**Status:** proposed
**Proposal:** UTERM-052
**Triaged:** 2026-11-22 (still reproduces; proposal filed)
**Found:** 2026-11-22, during the design critique of UTERM-051
**Estimate:** medium; one non-trivial decision, which part of the description to keep and where to build the rest. See "Fix".
**Validation:** mechanism confirmed by reading the code. Cost measured on 2026-11-22 (see "Measured cost").

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

## Measured cost

Measured on 2026-11-22 in a debug build. A scratch package test encoded `BrowserDescription` with
`JSONValue(encoding:)` for synthetic tabs with 50-byte URLs and 25-character titles.

| Tabs | Encode time |
|------|-------------|
| 1,000 | 21 ms |
| 10,000 | 197 ms |
| 50,000 | 988 ms |

The cost is linear, about 20 microseconds per tab. Every title change pays it. At 1,000 tabs one title change already
exceeds a 16 ms frame. The scratch test was not kept. It measured the encode alone, not a full `describe()` call.

## Repro

Not run in the app. A pane of 50,000 tabs whose selected page changes its title in a loop should show the cost on the
main thread. `BrowserDescribeCostTests` covers only the undo part's read count, not the tab-record encode.

## Fix

Not settled. UTERM-052 settles it. Candidates are caching the tab-record part the way the undo part is cached, or building the payload off
the main thread. UTERM-051 may change `AppletDescription`'s payload form, which bears on both.
