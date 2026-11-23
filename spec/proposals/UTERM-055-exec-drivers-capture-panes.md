# UTERM-055: Exec Drivers Capture Panes

**Status:** draft
**Created:** 2026-11-22
**Updated:** 2026-11-22

## Dependencies

- UTERM-054, for the host capture, its tab scope, its reason kinds, and the pane capture power
- UTERM-028, for the exec version negotiation that offers the new version
- UTERM-019, for the base64 field shape its exec byte results use

## Impacts

- UTERM-054 — "Where a program's capture command lives" and M6. This proposal is where exec drivers' capture lands,
  including the browser snapshot UTERM-019 planned for them.
- UTERM-019 — "Full-page snapshot", the exec skew statement, and its result chunks reaching drivers as base64. Exec
  drivers' browser snapshot moves here.
- UTERM-028 — "Version skew". This proposal adds a version to the hello's offer after UTERM-028's.

## Summary

An external exec driver captures a pane or tab, and the browser's full page, through the host capture UTERM-054 adds
for the user and for scripts. The capture rides a new exec protocol version that the app offers through UTERM-028's
version negotiation. The PNG bytes read back in base64 chunks that fit the exec frame cap.

## Motivation

UTERM-054 gives the user and Janet scripts a pane capture, but external exec drivers cannot reach it. Exec frames have
one fixed meaning per protocol version, and an unknown frame type ends the driver as malformed. ScriptWire calls do not
reach exec drivers.

UTERM-019 planned a browser snapshot for exec drivers that command browser members of groups they own. UTERM-054 moves
that snapshot into its host capture, so exec drivers would lose it. The user chose to keep exec capture as its own
proposal instead.

No exec-capable applet ships today, and the exec fixtures run only in debug builds. So no deployed driver uses capture
yet. The version this proposal adds is a published contract once it ships, under ADR-13.

## Design Decisions (Settled)

### Exec capture is its own proposal

Decision: exec drivers' capture lives here, apart from UTERM-054. It covers every applet that has UTERM-054's capture
capability, and the browser's full page.

Rationale: the user chose this. Exec capture waits on UTERM-028's version negotiation, and its wire is a published
contract that deserves its own review. UTERM-054's user and script capture does not wait for it.

### A new exec protocol version carries capture

Decision: the next exec protocol version after the one the exec protocol is at when this lands adds three frames:
capture, read-result, and discard. The app offers that version in the hello's `versions` list that UTERM-028 adds. A
driver that answers an earlier version gets none of these frames.

- Each read-result chunk carries bytes in UTERM-019's base64 field shape, so a driver has one byte encoding.
- A chunk is sized so its base64 form and envelope fit the 1 MiB frame cap.
- Errors use UTERM-054's append-only reason kinds.
- There is no image clipboard write. A program never copies a capture to the clipboard, as UTERM-054 settles.
- The app's hello keeps `protocol: 4`, as UTERM-028 does, and the new version only joins the offered list. No earlier
  version is dropped.
- A driver discards each handle it no longer needs, under ADR-11. Revocation, run end, and pane close free the rest.

Rationale: a host operation has been a new frame type at a new version before, as `layout` at version 2 and the
clipboard at version 3. UTERM-019 adds base64 at version 4 on browser commands, so there is no host version to reuse.
Naming the version relatively keeps it right if another proposal claims a version first.

### Exec capture follows UTERM-054's rules

Decision: an exec driver's capture goes through UTERM-054's host capture. Its tab scope, its target states and their
refusals, its pending state and cancel, its one failure notice per pane per run, its time bound, and its caps are
UTERM-054's. A refusal decided before the capture starts goes in the reply only.

Rationale: one capture path serves every caller, so behavior cannot drift by transport, as ADR-15 asks.

### Version skew

Decision: the deploy units are the app and external exec drivers.

- New driver, old app: an older app does not offer the new version, so the driver answers an earlier one and sends no
  capture frames.
- Old driver, new app: a driver offered the new version answers with the version it knows. A version 5 driver ignores
  the longer list, by UTERM-028's hello rule. A version 4 driver ignores the unknown `versions` field, as UTERM-028
  assumes.
- A grant stored before the capture power existed covers none of it, under ADR-14 P10.
- A capture frame sent at an earlier version ends the driver as malformed. A driver avoids that by sending capture only
  at the version it negotiated.

## Design Decisions (Open)

### Which grant and targets an exec driver captures under

A controller's layout declares the exec driver for a pane, and the driver commands browser members of groups its
controller owns. UTERM-054's pane capture power and tab scope belong to a program's grant. Candidates:

- The driver captures under its controller's grant. It needs the pane capture power in the controller's descriptor,
  and its targets are the panes of the group the controller owns, under UTERM-054's tab scope.
- The driver's own pane only, under the controller's grant. Leaves undone: the browser snapshot UTERM-019 planned for
  browser members of the group.
- A separate exec capture power in the descriptor, so a controller can grant capture to scripts and not to its driver.

### How a capture's held reply reaches a driver

UTERM-054's ScriptWire capture holds its reply until the PNG is ready, which ADR-11 allows for a command that only
reads. UTERM-019's exec skew statement says a deferred reply reaches a driver matched by request ID, as layout replies
do. Candidates:

- The capture frame's reply is deferred and matched by request ID, and it carries a result handle once the PNG is
  ready. The driver reads chunks with read-result and frees the handle with discard.
- The capture frame replies at once with a handle, and a completion event on the driver's pane event stream names it.
  A capture only reads, so ADR-11 does not require this.

## Risks

- **The exec capture version becomes a published contract** — likelihood: high, impact: medium.
  Mitigation: it is a new version in UTERM-028's offer, so no earlier meaning changes, under ADR-13. Its frames are
  settled here before M1 builds them.
- **A deployed version 4 driver rejects the longer hello** — likelihood: low, impact: medium.
  Accepted: this is UTERM-028's own assumption that a version 4 driver ignores an unknown hello field. This proposal
  adds a value to a list UTERM-028 already adds, and no new field.
- **Large reads in flight end the driver** — likelihood: medium, impact: medium.
  Mitigation: chunks are sized against the frame cap, and the driver guide says how many reads may be in flight
  within the outbound bound.
- **The design rests on two unbuilt proposals** — likelihood: high, impact: medium.
  Mitigation: M1 waits for UTERM-028 M1 and UTERM-054 M5. A change to either one's capture or version shape reopens
  the matching decision here.

## Milestones

### M1: Exec capture version

**Status:** NOT STARTED

Waits for UTERM-028 M1 and UTERM-054 M5.

- The app offers the new version in its hello, and a driver that answers it gets capture, read-result, and discard
- A driver that answers an earlier version gets none of these frames, and an older app's offer leaves the version out
- A capture from an exec driver follows UTERM-054's tab scope, target states, notice bound, time bound, and caps
- A read-result chunk fits the frame cap after base64, in UTERM-019's field shape
- An exec driver's browser full-page capture works for a browser member of its controller's group, or is refused by
  the rule "Which grant and targets an exec driver captures under" settles
- Revocation, run end, and pane close fail a pending capture and free its handle, under ADR-11
- The driver guide documents the version, the frames, their errors, and how many reads may be in flight

## Decision Log

- 2026-11-22: Filed from the UTERM-054 review. The user dropped exec capture from UTERM-054, then chose to bring it back
  as its own proposal when the review found that UTERM-019's exec browser snapshot would be lost. The frame list,
  base64 shape, and skew analysis come from that review's critique.

## References

- ADR-11: deferred applet replies never hide effects
- ADR-13: outside wires stay compatible across versions
- ADR-14: a controller controls what it opened
- ADR-15: a program's operation is the user's
