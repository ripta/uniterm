# UTERM-052: The Browser's Description Never Encodes Tabs on the Main Thread

**Status:** draft
**Created:** 2026-11-22
**Updated:** 2026-11-22

## Dependencies

- UTERM-005, for the browser applet and its tab records

## Impacts

- UTERM-051 — "Where the typed decode runs" may change `AppletDescription`'s payload form. This proposal's choice of
  fix depends on that form. See the first open question.

## ADR Deviations

None.

## Summary

The browser applet stops encoding every tab record on the main thread each time the window asks for a description.
The cost of a description stops growing with the tab count on the main thread.

## Motivation

`BrowserApplet.describe` builds its payload with `JSONValue(encoding:)`. That encodes every tab record to bytes and
decodes the bytes back into a `JSONValue` tree. The window asks for a description at every change the applet reports.
A page chooses how often its title changes. So each title change re-encodes the whole pane.

The path runs on the main thread. WebKit reports the new title through key-value observing. The applet's refresh sees
a changed title and reports a change to the window. The window calls `describe()` and compares the result with the
last saved description, so that a change the layout file does not hold is not a layout change. Each tab record holds
the tab's title, so the comparison usually finds a real change. The window then reports a layout change, and the save
calls `describe()` again. The comparison needs to know only whether one tab's record changed. It rebuilds and
re-encodes every tab to find out.

The cost is linear and was measured on 2026-11-22 in a debug build. It is about 20 microseconds per tab.

| Tabs | Encode time |
|------|-------------|
| 1,000 | 21 ms |
| 10,000 | 197 ms |
| 50,000 | 988 ms |

At 1,000 tabs one title change already exceeds a 16 ms frame.

ADR-08 allows only local work whose duration uniterm bounds on the main thread. A pane has no tab cap, so this work has
no bound. The layout save already moved its encode and write off the main thread. The description that feeds it is
still built on the main thread.

The undo part of the description is cached until a tab's history or the closed tabs change. The tab records are not
cached. The bug is `20261122-browser-describe-reencodes-tabs-on-main-thread`.

## Design Decisions (Settled)

None yet.

## Design Decisions (Open)

### Whether this waits for UTERM-051's payload form

UTERM-051 is in design review. It may change `AppletDescription`'s payload form. Both candidate fixes below touch that
form. Candidates:

- Settle this proposal now. Cost: the fix may be redone if UTERM-051 changes the payload form.
- Settle this proposal's open questions after UTERM-051 settles the payload form. Cost: the bug stays open until then.
- No addition: leave the description as it is. This keeps the unbounded main-thread cost.

### Where the tab records get encoded

Candidates:

- Cache the encoded tab records, the way the undo part is cached. A title change still re-encodes every tab unless the
  cache is kept per tab. Per-tab caching makes the cost one tab's, not the pane's. The cost stays on the main thread.
- Build the payload off the main thread from copied records. The main thread pays only for the copy.
- Do both. The copy is cheap, and the encode is off the main thread and per tab.
- Compare one tab, not the pane. The applet reports which tab's record changed, or keeps each tab's encoded record.
  The window's check compares that one record with the saved one. This changes the window's side of the applet
  contract, and every applet's report would carry the change. The save still needs the whole payload, so this pairs
  with one of the candidates above for the save path.

The copy of `tabs.count` records is still linear in the main thread. Whether that is bounded enough is part of this
question. The user decides what counts as bounded under ADR-08.

### Whether a tab cap is in scope

A tab cap would bound every cost that grows with the tab count. It is a scope addition. It changes behavior a user can
see. This question asks whether to add it before it asks how.

Candidates:

- No cap. The fix bounds this cost alone.
- A cap on tabs per pane, with a stated value and a visible refusal.

## Risks

- **A cache goes stale and a saved layout loses a tab's latest title** — likelihood: medium, impact: medium.
  Mitigation: a regression test that changes a title and checks the next description carries it.
- **The off-main build reorders descriptions, so an older one is saved over a newer one** — likelihood: medium,
  impact: high.
  Mitigation: one serial owner builds descriptions, and a test checks that the last description wins.

## Milestones

### M1: Measure the full description

**Status:** NOT STARTED

The scratch measurement covered the encode alone.

- The cost of a full `describe()` is recorded for 1,000, 10,000, and 50,000 tabs, in the As built block

### M2: Bound the description's main-thread cost

**Status:** NOT STARTED

Waits on the open questions above.

- A test shows that a burst of title changes costs the main thread no more per change at 10,000 tabs than at 10 tabs
- A test shows that the next description carries a changed title

## Decision Log

- 2026-11-22: Filed as a draft from bug `20261122-browser-describe-reencodes-tabs-on-main-thread`. The user asked for a
  proposal, and said it need not wait for UTERM-051's review.
- 2026-11-22: Traced why every title change pays the encode, and added the one-tab comparison as a candidate under
  "Where the tab records get encoded".

## References

- ADR-08: UI responsiveness
- Bug `20261122-browser-describe-reencodes-tabs-on-main-thread`
- UTERM-051: the launch reads the layout off the main thread
