# UTERM-043: Pause Controllers

**Status:** designing
**Created:** 2026-11-21
**Updated:** 2026-11-21

## Dependencies

- UTERM-004, for pane control, grants, the control badge, Disconnect Pane, and Revoke Controller
- UTERM-019, for M3's controller dialogs and page JavaScript, and M6 "Trusted input", which first lets a controller
  send keystrokes and clicks

## Impacts

- UTERM-041 — "The authority marker follows what a live grant can act on". Whether a paused grant still shows the
  authority marker, or shows it differently, is a question here. UTERM-041's look is settled, so any change to it
  needs the user's consent.
- UTERM-042 — "Every action is a palette command". Pause and resume may join that proposal's menu and palette
  commands. That would be an addition to UTERM-042.
- UTERM-036 — its accepted risk "Keys in flight reach the new pane" is one of the interruptions a pause would stop.

## Summary

The user can pause controllers for a while, without ending their grants, and resume them later. A paused
controller's next action does not run until the user resumes. Pausing is not revoking: the controller keeps its
grant, its groups, and its tabs.

## Motivation

The user may need to type something uninterrupted in a tab while a controller runs. A controller can interrupt that
today, though it sends no keystrokes or clicks yet.

- A controller that opens a pane moves keyboard focus to it (`MainWindowController.openPane`, which ends with
  `paneArea.focus(created)`, `MainWindowController.swift`, about line 781).
- A controller that opens a browser tab moves focus into the page it loads. The browser's `open` command
  (`BrowserApplet+Remote.swift`, about lines 92-115) opens and selects the tab, then commits the controller's URL in
  the same turn. The load makes the tab's web view first responder (`beginTypedLoad`, `BrowserApplet.swift`, about
  line 479). Keys the user is typing then reach the page the controller chose, and that page's own scripts can read
  them.
- UTERM-036 accepts this as the risk "Keys in flight reach the new pane". ADR-15's consequences say a program's action
  "can move the keyboard".

UTERM-019 adds more. M3 gives a controller dialogs that take the first responder when their pane held focus, and lets
it inject JavaScript into any page in its tabs. M6 "Trusted input" lets a controller send synthesized
mouse, key, and scroll events to browser tabs it owns. A synthesized click moves focus as the user's click does, and
keys then go to that tab (UTERM-019 "Trusted input").

The only ways to stop a controller today end something. Revoke Controller ends every controller of a pane and fails
its waiting calls, and its groups stay with no owner (`revokeController(_:)`, `MainWindowController+Control.swift`,
about line 121).
Disconnect Pane refuses every program's call to one pane, and Enable Remote Control lets them back
(`MainWindowController+Control.swift`, about lines 86 and 105). That pair keeps the grant and the groups. It is still
not a pause:

- It works one pane at a time.
- Both directions issue the pane a new control generation (`PaneControlTable.set`, which always calls `bump`). The
  browser releases every tab a controller owns on a new generation (`BrowserApplet+Remote.swift`, about line 219), so
  a controller loses its browser tabs and does not get them back.
- A permission asked under the old generation goes stale, and a saved control intent is cleared.

The user asked for this during UTERM-041's review, as "pause at next action" or "pause all controllers".

## Design Decisions (Settled)

### Pause is not revoke

Decision: pausing never ends a grant, never removes a controller's groups or tab ownership, and never kills its
process. Resuming restores exactly what the controller had. Chosen by the user on 2026-11-21.

Rationale: the user wants a short, uninterrupted stretch, not the cost of a new grant or a new run.

### The proposal stays deferred while controllers send no input

Decision: this proposal stays `deferred` for as long as controllers cannot send keystrokes or clicks. Its revisit hook
is UTERM-019 M6. Chosen by the user on 2026-11-21.

- The hook fired on 2026-11-21, when UTERM-019 M6 was scheduled. The user chose to resume the design, so it is
  settled before M6 starts.

Rationale: without synthesized input, no controller can type into the tab the user types in.

### Whether the deferral still holds

Original question: the deferral rests on controllers sending no keystrokes or clicks. They send none today, but they
already move the keyboard by opening panes and browser tabs, per the Motivation. A controller with browser navigation
can load a page it serves, and focus lands in that page, so the page can read what the user types today. UTERM-019 M3
adds dialogs and injected JavaScript before M6. The candidates were keeping the M6 hook, moving the hook to M3, and
ending the deferral now.

Decision: keep the deferral and the M6 hook. Chosen by the user on 2026-11-21, after the critique raised it.

- Leaves undone: until M6, a controller's pane and tab opens still take the keyboard, and a page it loads can read the
  user's keys, with no way to pause it. UTERM-036 accepts the focus moves as "Keys in flight reach the new pane".

## Design Decisions (Open)

### What a pause covers

Candidates:

- No new mechanism. The user disconnects each pane. Leaves undone: one action per pane, a browser controller loses
  every tab it owns, per the Motivation, and neither clipboard calls nor a driver's commands to its own pane are
  gated.
- Every controller in every window.
- The controllers of one window, or of one pane.
- One controller. UTERM-042 "What revoking one controller ends" settled the like question for a revoke: it ends that
  controller's whole grant, in every window, as the badge's pane-wide revoke does for each controller it ends.
- A pause as an authority refusal, checked at the effect gates that already exist: `requireAuthority` and
  `stillAllowed` in ScriptHost, `driverRefusal`, and a driver's command authority. Queued commands meet it at the
  dispatcher's delivery re-check (`ControlDispatcher.swift`, about line 314). ADR-15 says whether a program may act is
  decided by authority.

Constraints:

- Pausing only synthesized input leaves opening panes and tabs, layouts, and dialogs free to move the keyboard.
- Letting reads run lets clipboard reads run. `driverRefusal` passes clipboard calls (`MainWindowController+Exec.swift`,
  about line 721). A user who pauses and then copies a secret could hand it to a controller with a clipboard grant.
- Does a pause cover a controller that connects during it? A run with a remembered approval acts without a prompt, per
  ADR-14, so it would act at once unless the pause is a state of the window or the app.
- Are opens from programs that are not controllers covered, such as `uniterm open` and opens through Launch Services
  that activate the app, per UTERM-036? Covering them is an addition.

### What a command does while paused

Candidates:

- The host refuses it with the existing `refused` kind, which means the caller may not command the target now. No
  wire changes. `busy` does not fit: it means the call may be sent again once the first is answered (UTERM-004), and
  ADR-13 keeps an exec-wire code's meaning fixed. A driver that retries on `busy` would spin through a pause.
- The host refuses it with a new "paused" error kind.
- The host holds it before dispatch, and runs it in order on resume.
- The host holds it up to a cap or a time limit, then refuses the rest.

Constraints on every holding candidate:

- ADR-15 says "Once a program may act, its action is not weakened, delayed, or hidden." A hold delays an allowed
  action, unless the pause is defined as authority.
- ADR-11 says "A command with an effect replies at once." A held command with an effect breaks that rule's letter,
  though a failure still means nothing ran. Choosing a hold needs an ADR Deviations entry or an amendment.
- The window's dispatcher is one ordered queue (`ControlDispatcher.swift`, `drain`, about line 284), one per window
  (`MainWindowController.swift`, about line 99). Holding a paused controller's command in place blocks every later
  command in the window, unpaused controllers' included. Holding outside the queue needs a new structure.
- Opening a pane, opening a tab, `send`, layouts, and clipboard calls never enter the dispatcher (`WindowScripting.swift`,
  about lines 151, 207, 264, and 397). A hold must cover them too.

### "Pause at the next action" and work already running

Questions:

- Does a pause take effect before the next command, or do commands already queued finish? Under a refusal, queued
  commands fail at the delivery re-check. A pending wait fails only if the pause calls `revalidatePending`, so the
  design must say whether it does.
- Does it stop page JavaScript a controller injected, or only new commands? Injected code keeps running when the host
  stops delivering commands.
- Does it stop an exec driver's commands to its own pane? The driver sends those through its attached channel
  (`ExecDriverChannel.run`), which Disconnect Pane does not gate.
- If UTERM-019 M6 sends a mouse press and its release as separate commands, a pause between them could leave a button
  held in the page. Whether M6 splits them is not yet checked.

### How the user pauses and resumes

The user named a keyboard shortcut, a menu item, and a command palette command as possible entry points. Questions:

- Which of these, and whether the badge's menu offers it too
- Whether a default key binding is reserved, per ADR-04
- Whether resume is explicit only, or also ends after a time. A time limit is a setting with no named user who would
  set it differently, unless one is found
- Whether a paused controller's own palette commands and keys, which UTERM-024 and UTERM-028 let it declare, still
  reach it while paused

### How a pause shows

Questions:

- What shows that controllers are paused, so the user does not forget, such as the badge, a marker, or the window
- Whether a paused tab keeps UTERM-041's authority marker, since its grant still stands
- Whether a paused controller's consent or adoption prompts still show, since a prompt mid-pause interrupts the typing
  the pause protects

### Whether the controller learns of a pause

Candidates:

- The controller sees nothing beyond a refused command. No wire changes.
- The wires gain an event that says control paused and resumed. No consumer of it is named yet.

ScriptWire is exempt from ADR-13, since its two sides ship together and refuse every version but their own
(UTERM-024 "Version skew"). Scripts that match on `:refused` or `:busy` would still miss a new error kind. The exec
wire to drivers is bound by ADR-13. A new error kind or event there needs an analysis of an old driver receiving it.

### Whether a pause survives a relaunch

A grant does not survive a relaunch, per ADR-14. Whether a pause lasts across a window close or a relaunch follows
from that. A pause that survives would be new stored state.

## Risks

- **The user forgets a pause** — likelihood: medium, impact: medium. A controller appears stuck and its work silently
  stops. Mitigation: the open question "How a pause shows".
- **Held commands pile up** — likelihood: medium, impact: low. A controller that keeps sending while paused fills a
  queue. The dispatcher bounds only applet commands and drivers' commands, and the other calls never enter it.
  Mitigation: the open question "What a command does while paused" sets the behavior for every path.
- **Held commands block other controllers** — likelihood: medium, impact: medium. If a hold keeps a paused
  controller's command in the window's one queue, every later command waits behind it. Mitigation: a constraint on
  the holding candidates in "What a command does while paused".
- **A pause misread as safety** — likelihood: low, impact: high. A page a controller loaded keeps running during a
  pause, and so does JavaScript it injected. Either can still read what the user types in that tab. A clipboard read
  may still run too. A user who pauses to type or copy a secret could expose it. Mitigation: "What a pause covers" and "'Pause at the next action'
  and work already running" decide what a pause stops, and the wording must say what it does not stop.
- **The revisit hook fires too late** — likelihood: high, impact: medium. Focus moves already interrupt typing, and
  UTERM-019 M3 adds dialogs and page JavaScript before M6. Accepted by the user on 2026-11-21: the deferral keeps the
  M6 hook, per "Whether the deferral still holds".
- **ADR-15 is proposed, not accepted** — likelihood: medium, impact: medium. The authority framing of a pause, and the
  conflict a hold has with ADR-15, depend on its final text. Mitigation: re-read ADR-15 when this proposal resumes.
- **A wire change** — likelihood: low, impact: medium. A paused-control event or a new error kind changes the exec
  wire, which ADR-13 binds. Mitigation: the open question "Whether the controller learns of a pause".

## Milestones

### M1: Pause and resume

**Status:** NOT STARTED

- The user pauses controllers from the entry point "How the user pauses and resumes" settles, and resumes them
- A paused controller keeps its grant, its groups, and its browser tabs, and resumes with all of them
- A command from a paused controller behaves as "What a command does while paused" settles, on every path, those
  outside the dispatcher included
- While paused, no command from a controller the pause covers moves keyboard focus, and none sends a synthesized
  keystroke or click
- The window shows that controllers are paused, as "How a pause shows" settles
- A UI test types into a pane while a paused controller tries to open a pane and a browser tab that loads a page. No
  key lands anywhere else
- When this milestone lands after UTERM-019 M6, the same test also has the paused controller send synthesized input,
  and none arrives

## Decision Log

- 2026-11-21: Drafted at the user's request during UTERM-041's review. The user chose that a pause never revokes or
  kills, and that the proposal stays deferred until controllers can send keystrokes or clicks, with UTERM-019 M6 as
  its revisit hook.
- 2026-11-21: Critique pass. Corrected the Motivation: controllers already move keyboard focus when they open panes
  and browser tabs, per UTERM-036. Disconnect Pane then Enable Remote Control keeps a grant and its groups, but it
  works per pane and a new control generation makes a browser drop every tab a controller owns. Corrected the wire
  notes: ScriptWire is exempt from ADR-13, and the exec wire is bound by it. Added the open question "Whether the
  deferral still holds", since the deferral's premise is narrower than the interruption it guards against. Added
  options and constraints from ADR-11, ADR-15, and the window's one dispatcher queue, and three risks.
- 2026-11-21: Re-check fixes. A controller's browser `open` puts focus in the page it loads, not the address field, so
  that page can read the user's keys today. The deferral question and the safety risk now say so. `busy` is dropped
  as a refusal kind for a pause, since its meaning is a retry. The M1 checks now cover only the controllers a pause
  covers.
- 2026-11-21: Whether the deferral still holds: the user kept the deferral and the UTERM-019 M6 hook, and accepted the
  risk that the hook fires after focus moves and pages already reach the user's typing.
- 2026-11-21: The critique loop converged in three passes. Its last pass routed two checks to M1: the UI test loads a
  page, and its synthesized-input half applies once UTERM-019 M6 has landed.
- 2026-11-21: "What a pause covers" now cites UTERM-042's settled answer on revoking one controller, which it had
  called an open question. UTERM-042 also renames the pane-wide revoke "Revoke All Controllers" and adds one revoke
  item per controller to the badge. This proposal's Motivation still names "Revoke Controller", since it describes
  today's command.
- 2026-11-21: Revisit audit: act. The hook "when UTERM-019 M6 'Trusted input' is scheduled or starts" fired when
  UTERM-019 M4-M6 was scheduled. The user chose to resume the design before M6 starts. The status moved from deferred
  to designing, and the `**Revisit:**` line was removed.

## References

- UTERM-004: pane control, Disconnect Pane, and Revoke Controller
- UTERM-019: M3 dialogs and page JavaScript, and M6 "Trusted input"
- UTERM-024: ScriptWire's version skew
- UTERM-036: "Keys in flight reach the new pane"
- UTERM-041: the authority marker
- UTERM-042: tab actions and palette commands
- [ADR-11](../adr/ADR-11-deferred-applet-replies-never-hide-effects.md): deferred replies never hide effects
- [ADR-13](../adr/ADR-13-outside-wires-stay-compatible-across-versions.md): outside wires stay compatible
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): grants, revocation, and queued work
- [ADR-15](../adr/ADR-15-a-programs-operation-is-the-users.md): authority is the one thing kept apart
- [ADR-04](../adr/ADR-04-uniterm-owns-key-bindings-and-terminal-config.md): key bindings
