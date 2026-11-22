# UTERM-039: A Controller's Browser Tabs Are Not Capped

**Status:** accepted
**Created:** 2026-11-21
**Updated:** 2026-11-21

## Dependencies

- UTERM-005, for the browser's remote commands
- UTERM-037, for the rule that a controller's open is the user's New Tab

## Impacts

- UTERM-037 — "What stays": the sentence that the per-grant tab cap stays, and the Rationale sentence on the cap.
  Superseded in part.
- UTERM-037 — M1: the check that permissions, tab ownership, and the per-grant cap are unchanged. Superseded in part.
- UTERM-005 — M8 As built: the note that a grant holds at most 16 open tabs and the 17th open is refused as busy.
  Superseded in part.
- UTERM-005 — Decision Log, 2026-11-20: the entry that a grant holds at most 16 open tabs in a pane. Superseded by a
  new Decision Log entry. The old entry is not edited.

## ADR Deviations

- ADR-14 P15, no carve-out: a controller's tab opens carry no bound on how often they act. The tabs live only in panes
  the controller opened, and revoking it stops further opens. The user accepted the remaining risk of a runaway loop on
  2026-11-21, and deferred a rate bound, per "Defer a rate bound on a controller's opens".

## Summary

A controller may open as many browser tabs as the user may. The 16-tab cap per grant per pane is dropped. A controller's
`open` behaves as the user's New Tab, and revoking the controller is the safety.

## Motivation

UTERM-005 M8 added the cap as a work-queue best guess, tagged an addition. The user never ruled on it. Its text says that
"Control" bounded nothing about how many tabs a controller opens.

The cap is not authority. The review text for the browser permission never mentions it. The text reads "Open and
navigate browser tabs, with network access signed in as you, whatever its sandbox allows"
(`Packages/UnitermKit/Sources/ControllerTrust/ControllerPolicy.swift:237-239`). A user who approves that text learns of
no limit. Each grant also gets its own 16, so the cap does not bound a pane.

The cap is a behavior difference between a controller's `open` and the user's New Tab. ADR-15 says a program's
operation behaves as the user's, and keeps only authority apart. The user ruled on 2026-11-21 that the cap goes.

UTERM-005 and UTERM-037 are implemented, so their text is frozen. This proposal records the change and supersedes the
affected parts.

## Design Decisions (Settled)

### No cap on a controller's tabs

Decision: a controller's `open` is the user's New Tab with an address typed into it, and nothing bounds how many it may
make.

- `controllerTabLimit` and its refusal are removed from `BrowserApplet+Remote.swift:83-104`.
- The refusal was the one place the browser's remote commands replied `busy` for a tab count. The `busy` code stays in
  the shared dispatcher for a full command queue (`ControlDispatcher.swift:156`) and for too many replies waiting in
  one window (`:424`).
- A page's own script-opened tabs keep their limit (`BrowserApplet.swift:1102`). That limit bounds a page, which no user
  action matches, and it is not a controller's cap.
- Ownership is unchanged. A controller still reaches only the tabs it opened, for its live grant.

Rationale: a program's operation behaves as the user's, per ADR-15. The user's New Tab has no cap. The cap was a guard on
one source, which ADR-15 names as the pattern that left neighbors open. The safety belongs in authority. The controller
needs the browser navigation permission, and the user may revoke it. Chosen by the user on 2026-11-21.

### What stays

Decision: authority is unchanged. Browser navigation gates `open`. A command reaches only a tab its caller opened, for
the caller's live grant. The schemes that no source may load stay refused.

- Browser navigation keeps its meaning and its version. Neither its permission line nor the review sheet names a bound,
  so the power a user approved is the same before and after. A saved approval carries over with no new review. ADR-14
  forbids a change in permission meaning from widening an approval, and this is no such change.

Rationale: authority decides who may act, not how many times. This rests on ADR-15's authority carve-out and ADR-14.

### Defer a rate bound on a controller's opens

Decision: no bound on how many tabs a controller may open in a period of time. A cap on the total count is the wrong
bound, since the user's New Tab has none. A rate bound on one controller's opens would leave the user's own tabs
unbounded, and it is deferred, not rejected. Amended 2026-11-21; see Decision Log.

**Revisit:** when a controller is seen opening tabs in a loop, or when the browser gains unloading of background tabs;
file a follow-up proposal for a per-controller rate on opens.

## Design Decisions (Open)

None.

## Risks

- **A runaway controller opens tabs without bound** — likelihood: low, impact: medium. A loop of `open` makes tabs far
  faster than hands can. Each tab is a web view in the app and may start a content process, so the whole app, terminals
  included, feels the memory pressure. Each tab is also saved in the pane's description, so saved state grows with the
  count. Restore stays bounded, since only the selected tab is built at relaunch. Mitigation: the dispatcher delivers a
  bounded number of commands per main-thread turn, so a flood never holds the main thread, and Revoke All Controllers stays
  reachable in the pane's frame and as a command. Commands still queued after a revoke are checked again at delivery
  and take no effect. Page content runs out of process, per UTERM-005 "Web content failure", so a page's crash or memory
  growth ends its own content process, not the app. After a revoke the tabs remain, and closing the pane removes them.
  Accepted: the safety is authority and this recovery path, per ADR-15. A pane-wide cap would apply to the user's New
  Tab too. A rate bound on one controller's opens would not, and it is deferred, per "Defer a rate bound on a
  controller's opens". This is a deviation from ADR-14 P15. Amended 2026-11-21; see Decision Log.
- **ADR-15 is still proposed** — likelihood: low, impact: low. The rationale cites its text, which may change before it
  is accepted. Accepted: the decision also rests on the user's ruling of 2026-11-21, so only the rationale's wording is
  exposed.

## Milestones

### M1: Drop the cap

**Status:** NOT STARTED

- `open` is never refused for the number of tabs the caller holds
- `controllerTabLimit` and its refusal are gone
- `testAGrantMayHoldOnlyAFixedNumberOfTabs` (`BrowserRemoteTests.swift:218-244`) is replaced by a test that opens at
  least 17 tabs from one grant, using a literal count. The last open succeeds and adds a tab
- The type's doc comment in `BrowserApplet+Remote.swift` no longer lists a tab cap among the checks before the user's
  action
- Another grant's opens, tab ownership, and the permission check are unchanged
- UTERM-005 and UTERM-037 each gain a dated "Superseded in part by UTERM-039" Decision Log entry that names the replaced
  text. Markers go only on decisions and milestones: UTERM-037 "What stays" and M1, and UTERM-005 M8. No existing
  Decision Log entry is edited, and `proposals.py freeze` passes

Version skew: a removed `busy` reply. A newer app accepts every open an older one did. An older app refuses the 17th
open from one grant with `busy`, a code the dispatcher also sends for a full queue, so a controller that handles it for
the queue handles it here. A controller that relied on that refusal as a limit sees none on a newer app. No deploy order
is needed.

## Decision Log

- 2026-11-21: Filed after the user ruled that a controller's browser tabs have no cap. The 16-tab cap came from a
  work-queue addition in UTERM-005 M8 that the user never ruled on. The user chose a superseding proposal so
  UTERM-005's and UTERM-037's frozen text keeps a record of the cap.
- 2026-11-21: Returned to draft. It was filed as accepted without critique or proposal review. It goes through
  both before it is accepted.
- 2026-11-21: Review start: 1 milestone, 2 settled decisions, 1 risk, no `**Live after:**` lines or row gates; no
  out-of-scope statements; as of the commit "Return UTERM-039 to draft until it has been critiqued and reviewed". The
  user asked for an autonomous critique and review before acceptance.
- 2026-11-21: Coherence review fixes. "What stays" now says browser navigation keeps its meaning and version, so a
  saved approval carries over under ADR-14. The runaway-controller risk now rests on authority and a traced recovery
  path, not on the user's tabs being unbounded, and names the rate, the saved-state growth, and the out-of-process
  bound ADR-07 asks for. A risk records that ADR-15 is still proposed. Two citations were corrected. (autonomous)
- 2026-11-21: Routed to M1 checks: the replacement test uses a literal count of at least 17, the type's doc comment
  drops the cap, and supersession goes through new Decision Log entries, not edits to frozen ones. (autonomous)
- 2026-11-21: Review gate: kept all. No decision earns an ADR. The user accepted the proposal.
- 2026-11-21: Renamed the pane-wide revoke in the runaway-controller risk from "Revoke Controller" to "Revoke All
  Controllers", per UTERM-042 "Palette commands: wording and target". It is the same command, with the same ID. The
  title changes once UTERM-042 M1 lands.
- 2026-11-21: ADR-14 gained P15, that a program's reach is always bounded. A controller's opens have no bound on how
  often they act, so this proposal deviates from P15. The user accepted the risk and deferred a per-controller rate on
  opens, with a revisit hook. The runaway-controller risk said "A rate limit or a pane-wide cap would apply to the
  user's New Tab too, and is out of scope." A rate on one controller's opens would not apply to the user's New Tab.

## References

- UTERM-005: the browser applet and its remote commands
- UTERM-037: a controller's browser commands act as the user's
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): authority, which this proposal leaves unchanged
- [ADR-15](../adr/ADR-15-a-programs-operation-is-the-users.md): "No cap" rests on the rule that a program's operation
  is the user's. "What stays" rests on its authority carve-out
