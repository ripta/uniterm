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

The map viewer and the image viewer accept exec drivers today, and UTERM-054 makes both capture-capable. So a driver
capturing its own pane is a live case, and deployed drivers may exist. The version this proposal adds is a published
contract once it ships, under ADR-13.

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
- A newer app can send a reason kind that a driver's version has never seen, since UTERM-054's reason kinds are
  append-only. A driver treats an unknown reason as a refusal in which nothing was captured, as UTERM-019 states for
  `unsupported-capability`. The version's documentation states this rule.
- A capture frame sent at an earlier version ends the driver as malformed. A driver avoids that by sending capture only
  at the version it negotiated.

## Design Decisions (Open)

### Which grant and targets an exec driver captures under

An exec driver has no verified identity, so ADR-14 P9 lets it keep no remembered approval. Each run gets its own group
owner, and member commands check ownership against that driver owner. A driver's browser and clipboard powers are per
run: it asks for them in Pending Requests, and Revoke and run end clear them. UTERM-028 rejects inheriting a
controller's approval, since nothing links a driver to the run that covered its launch. A driver the user starts with
Run has no controller at all. So every candidate that needs a controller's descriptor grant cannot be built for a
driver. Candidates:

- A per-run capture power the driver asks for in Pending Requests, as its browser powers are, with Allow Once and Allow
  for This Run, held on the attachment. Its targets are the driver's anchor, its source pane under ADR-14 P2, plus
  remote-controlled members of groups this run owns. The tab scope uses the driver's owner as the caller. Revoke and
  run end end the power.
- The driver captures under its controller's grant, with the pane capture power in the controller's descriptor.
  Needs a descriptor that a user-launched driver lacks, and contradicts UTERM-028's rationale.
- A separate exec capture power in the descriptor, so a controller can grant capture to scripts and not to its driver.
  Same flaw as the controller's grant, and no one is named who would set it.
- The driver's own pane only, under the per-run power or under none. Leaves undone: the browser snapshot the user chose
  to keep, since a driver's browser panes are group members, not its anchor.

Whichever is chosen must also settle two cases. Does capturing the driver's own anchor need the power too? And can the
driver still capture its anchor after Revoke, since UTERM-028 leaves a driver its own applet commands and events after
a revoke? The image viewer promises that nothing from a file the caller may not read leaves the pane, and an exec
driver holds no path-reading power. A driver that captures an anchor showing a user-opened image would get pixels its
events withhold. Filed for UTERM-054 as
[20261122-capture-bypasses-image-viewer-read-scope](../bugs/20261122-capture-bypasses-image-viewer-read-scope.md).

### How a capture's held reply reaches a driver

UTERM-054's ScriptWire capture holds its reply until the PNG is ready, which ADR-11 allows for a command that only
reads. UTERM-019's exec skew statement says a deferred reply reaches a driver matched by request ID, as layout replies
do. Candidates:

- The capture frame's reply is deferred and matched by request ID, and it carries a result handle once the PNG is
  ready. The driver reads chunks with read-result and frees the handle with discard.
- The capture frame replies at once with a handle, and a completion event on the driver's pane event stream names it.
  A capture only reads, so ADR-11 does not require this.

### The frames' fields

M1 must not invent a permanent contract, as UTERM-028 settled its version 5 JSON for the same reason. The frames need
these fields settled:

- Capture: the target pane, which capture of content, pane, or full page, and which tab.
- The capture reply: the handle, the byte size, whether the image was clamped, and its density.
- Read-result: the handle, and an offset in raw bytes rather than base64 characters. The reply's chunk carries bytes as
  a base64 string, as UTERM-019 does.
- The chunk size, and the discard reply.
- Where the reason kind goes. The exec error frame carries only `code` and `message` today.

Candidates: mirror the ScriptWire capture calls' fields one for one, so both transports name the same things, or give
the exec frames their own field set in the version 5 style.

### How the app bounds reads in flight

Retained outbound bytes are capped at 4 MiB and a frame at 1 MiB, and an overflow ends the driver. Pushed applet events
share that queue. A driver that sends five read-results before it reads its input can be ended, and its capture lost.
Candidates:

- The app refuses a read with `busy` when the retained outbound bytes plus the chunk would pass the cap. The bound
  accounts for pushed events.
- The app bounds read replies in flight per driver, and refuses the next read with `busy` past the bound. Leaves
  undone: events share the queue, so a count alone can still overflow.
- The chunk size is fixed small enough that a stated count of reads fits beside events. Leaves undone: a burst of
  events can still overflow.
- The version's documentation says how many reads may be in flight, and nothing in the app enforces it. Leaves undone:
  a driver that misreads it is ended.

## Risks

- **The exec capture version becomes a published contract** — likelihood: high, impact: medium.
  Mitigation: it is a new version in UTERM-028's offer, so no earlier meaning changes, under ADR-13. Its frames are
  settled here before M1 builds them.
- **A deployed version 4 driver rejects the longer hello** — likelihood: medium, impact: medium.
  Accepted: this is UTERM-028's own assumption that a version 4 driver ignores an unknown hello field. This proposal
  adds a value to a list UTERM-028 already adds, and no new field. Rated medium, since map viewer and image viewer
  drivers may already be deployed.
- **Large reads in flight end the driver** — likelihood: medium, impact: medium.
  Mitigation: chunks are sized against the frame cap, and "How the app bounds reads in flight" settles the bound. The
  version's documentation lives with UTERM-028 M1's version 5 documentation.
- **A driver with no verified identity reads what a pane shows** — likelihood: medium, impact: high.
  Mitigation: capture follows UTERM-054's tab scope, and needs a power for at least every pane besides the anchor, so
  a driver's reach is bounded. "Which grant and
  targets an exec driver captures under" settles the power and its targets.
- **The design rests on three unbuilt proposals and a proposed ADR** — likelihood: high, impact: medium.
  Mitigation: M1 waits for UTERM-028 M1 and UTERM-054 M5, which reaches UTERM-019's byte type and exec base64. Following
  UTERM-054's rules also rests on ADR-15, which is proposed. A change to any of their capture or version shapes reopens
  the matching decision here.

## Milestones

### M1: Exec capture version

**Status:** NOT STARTED

Waits for UTERM-028 M1 and UTERM-054 M5.

- The app offers the new version in its hello, and a driver that answers it gets capture, read-result, and discard
- A driver that answers an earlier version gets none of these frames, and an older app's offer leaves the version out
- A capture from an exec driver follows UTERM-054's tab scope, target states, notice bound, time bound, and caps
- A read-result chunk fits the frame cap after base64, in UTERM-019's field shape
- An exec driver's browser full-page capture works for a remote-controlled browser member of a group this run owns,
  or is refused by the rule "Which grant and targets an exec driver captures under" settles
- Revocation, run end, and pane close fail a pending capture and free its handle, under ADR-11
- The version's documentation, beside UTERM-028's version 5 documentation, covers the frames, their errors, the rule
  for unknown reason kinds, and the bound on reads in flight
- The new version includes every frame of the version it follows
- A second capture of a pane with a pending capture is refused, as UTERM-054's one pending capture per pane settles,
  and held captures never count against the Pending Requests panel's rows
- A driver's failure notice names the driver as pane chrome does, by executable and process ID
- A capture of a member pane needs the member to be remote-controlled and owned by this run

## Decision Log

- 2026-11-22: Filed from the UTERM-054 review. The user dropped exec capture from UTERM-054, then chose to bring it back
  as its own proposal when the review found that UTERM-019's exec browser snapshot would be lost. The frame list,
  base64 shape, and skew analysis come from that review's critique.

- 2026-11-22: Revised after the draft's design critique. Motivation said no exec-capable applet ships. The map viewer
  and image viewer accept exec drivers today, so it now says deployed drivers may exist. "Which grant and targets an
  exec driver captures under" rested on a controller's grant that drivers never hold. It now states the per-run power
  model, adds a per-run capture power candidate, and names the two anchor cases. Added the open questions "The frames'
  fields" and "How the app bounds reads in flight". "Version skew" replaced its stored-grant bullet, since driver
  grants are never stored, with the rule for unknown reason kinds. Risks gained a driver's read of a pane and the
  proposed ADR, and the version 4 risk is now rated medium.

- 2026-11-22: The re-check converged. Routed three checks and folded its notes into the grant and read-bound
  questions, including the image viewer read-scope gap, filed for UTERM-054.

## References

- ADR-11: deferred applet replies never hide effects
- ADR-13: outside wires stay compatible across versions
- ADR-14: a controller controls what it opened
- ADR-15: a program's operation is the user's
