# UTERM-024: Controller Input Channel

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-15

## Dependencies

- UTERM-002, for the command registry, the palette, and the one dispatch point that keys, menus, and the palette share
- UTERM-003, for the `uniterm` Janet module, ScriptWire, and its scope note that defers script-registered commands
- UTERM-004, for controller runs, exec drivers, groups and their owners, revocation, and the permission kinds
- UTERM-013, for command owners, reserved keys, and the order in which a key finds its command
- UTERM-021, for the `declare-permissions` spelling a new permission kind must define

## Impacts

- UTERM-003 — "Scope": its out-of-scope line "Invoking or registering UTERM-002 registry commands from scripts" is the
  registering half of what this proposal builds. Invoking registry commands from scripts stays out of scope.
- UTERM-013 — "What one shortcut declaration is" and "Which keys uniterm reserves": a controller joins uniterm and
  applet types as a third command owner. Its keys come after uniterm's and the user's, per "Plain keys in the
  controller's own panes".
- UTERM-004 — "Exec wire format": an invocation is a host event, not an applet event. "Remote callers receive no applet
  events" stands. The exec protocol and ScriptWire versions go up.
- UTERM-019 — "Page events": the event read here takes the same cursor, timeout, and dropped-count shape, if Open
  question "The event model" settles that way.
- UTERM-022 — "Where the form calls live": a host-side waiting call is the precedent this proposal weighs in Open
  question "Where the read lives".

## Summary

A controller declares commands. They appear in the command palette, and may carry shortcuts, while one of the
controller's panes has focus. When the user invokes one, uniterm records an event. The controller reads its events and
acts on them. A controller here is a Janet controller run or an exec driver.

## Motivation

A program can already drive applets. A Janet script can lay out panes and send commands to the text viewer. An exec
driver can command the members of its group. What no program can do is hear the user. A script gets no events at all.
A driver hears only its own pane's applet, and the built-in applets emit no input events.

The motivating case is a presentation. A presenter controller lays out a text viewer for slides and another for notes.
It shows each slide with `show-markdown`. Today it has no way to learn that the user wants the next slide. The only
workaround is reading lines from the script's own terminal. That needs Enter, works only while the terminal has focus,
and cannot take arrow keys or a clicker.

The same gap blocks other controllers: a build dashboard with Rerun, a review tool with Approve and Next File, a
debugger with Step. Each is a small set of named actions that the user triggers and the program handles. A general
input channel serves all of them, so none needs its own applet.

## Design Decisions (Settled)

### Scope: commands and their events, not screen control

Decision: this proposal covers commands that a controller declares, their palette entries and shortcuts, and the events
their invocations produce. Screen control is out of scope: zooming one pane to fill its window, full screen, and placing
a second window on another display.

- Screen control needs its own power under ADR-09, changes UTERM-004's "Same window only", and falls under ADR-12's
  focus rules. Those are separate questions from input.
- A presenter works without it. The user can make the window full screen by hand.
- What screen control adds is showing only the slide pane to an audience, and a presenter view with notes on one
  display and slides on another. Neither is possible today.

Decision to defer: file a screen-control proposal once M4's presenter example runs. Revisit hook: M4 of this proposal.

**Revisit:** when M4's presenter example passes

### Who may declare commands

Decision: a Janet controller run and an exec driver may both declare commands. Both are authenticated controllers
under UTERM-004. Each gets the same commands, events, and limits. The transport is all that differs.

### When commands are live

Decision: a controller's commands are live only while the focused pane belongs to a group the controller owns.

- "Live" covers the palette, the menu, and shortcuts together. A command that is not live is not listed in the palette.
  Its keys reach the pane as if it did not exist.
- Group membership is by stable node ID, per ADR-02.
- A controller's commands never act in panes it does not own, so it cannot take keys from the user's other panes.

Whether the group's source pane counts is an open question. See "The source pane".

### Plain keys in the controller's own panes

Decision: a controller may bind plain keys with no modifier, such as Page Down, the arrow keys, and Space, so a
presentation clicker works.

- While a pane the controller owns has focus, the controller's key wins over that pane's own handling of the key.
- uniterm's reserved keys still win over the controller, per UTERM-013. A user's remap still wins over every default.
  A controller key that loses is dropped, and the user is told, as UTERM-013 does for an applet key.
- Each pane where a controller's keys are live shows that the controller is taking keys. The badge names the
  controller and lists its keys. The user can revoke the controller from there.

Rationale: a clicker sends plain keys. A rule that allowed only chords would make the motivating case need a remap
on every machine. The visible indicator and the scope to the controller's own panes bound the surprise.

### Powers, lifecycle, and the ADRs

Decision: these follow from accepted ADRs.

- Declaring commands is a power of its own. Pane control does not grant it, per ADR-09. Its name and spelling are open.
  See "Names".
- An invocation is recorded when the user acts. The read only waits for recorded events, so it may hold a pending
  reply, per ADR-11. Recording never waits on the controller, per ADR-08.
- When the run ends, the driver exits, the grant is revoked, or the window closes, the controller's commands leave the
  palette, the menu, and the keys at once. Pending reads fail, and any buffered events are discarded, per ADR-09 and
  ADR-11.
- A controller that stalls or crashes ends only itself. The palette and the keys never wait on it, per ADR-07.
- No command, key, or event is saved with a layout. A restored group has no commands until a live controller declares
  them, per ADR-03.
- Invoking a command is the user's choice. A change the controller makes in response may move focus within ADR-12's
  rules for chosen changes. A shortcut pressed before such a change never counts as the choice that arms input after it.

### Version skew

Decision: each wire refuses an unknown version at the hello, as it does today.

- A new helper with an old app: the app refuses ScriptWire's new version at the hello. The run fails before any
  effect, with the message to relaunch uniterm.
- An old helper with a new app: the same refusal in the other direction.
- An exec driver that speaks an older exec protocol than the app is refused at the hello. A driver that speaks the new
  one with an old app is refused the same way.
- A descriptor or declared file that names the new permission kind is refused whole by an older build, which does not
  know the kind. A policy file holding an approval of the new kind makes an older build treat the whole file as newer,
  so every remembered approval goes inert. That fails closed, as UTERM-022 found for `ask-user`.

## Design Decisions (Open)

### Where the read lives

- **A host call, like UTERM-022's form calls.** ScriptHost holds the pending read for the connection. It knows the
  caller, needs no applet behind it, and does not count against the per-window cap of 64 pending applet replies.
- **A pending reply in the applet dispatcher, like UTERM-019's `next-events`.** It reuses `PendingReply` and the
  authority recheck. There is no applet behind a controller's commands, so it would need a stand-in target, and it
  would share the per-window cap with browser reads.

An exec driver has a second choice:

- **Pushed events.** The app sends an `invoked` message on the driver's stdout pipe, as it sends applet events. The
  exec wire already carries pushed events, so a driver needs no read loop.
- **The same read as Janet.** One model for both transports, at the cost of a read loop in every driver.

### The event model

- **A per-run cursor buffer, like UTERM-019.** Bounded by count. It drops the oldest events and reports how many were
  dropped. Several readers can each keep a cursor.
- **A single-reader queue.** Each event is delivered once. Simpler, but a helper that reads from two places loses
  events.

Either way: the bound, whether a drop raises an error in Janet by default as UTERM-019's helpers do, and whether an
event carries the pane that had focus and the input that triggered it, such as palette, menu, or key.

### When commands are declared

- **Statically**, in `declare-permissions` or the controller descriptor. The approval prompt can list the commands and
  keys before the run starts.
- **At runtime**, through a call. A controller can change its commands as its state changes, such as Resume replacing
  Pause.
- **Both**: static declarations bound what runtime calls may enable.

### Registry mechanism

- The registry and the menu are fixed after launch today. Registering a type twice trips a precondition, and the menu
  is built once. Controller commands need adding and removing at runtime, without disturbing uniterm's and the
  applets' commands.
- Availability is keyed by applet type today. Controller commands need it keyed by group membership.
- Where they appear in the menu bar: a per-controller menu, a Controller menu, or palette only.
- How the palette labels them, so a controller titled "Close Window" cannot pass for uniterm's command. UTERM-022's
  requester chrome is a precedent.

### How plain keys reach the controller

Plain keys arrive through `keyDown`, not as key equivalents. Several views take them first, such as the terminal
surface, the REPL, and the image viewer. Options:

- Route plain keys through the window before the focused view, only while controller keys are live in that pane.
- Give each applet a hook that offers unmodified keys to the window first.

### The source pane

The terminal that started a script is the group's source. It is not a member. Options:

- **It counts.** The presenter can drive slides from the terminal. The controller's plain keys then take keys the shell
  would get.
- **It does not count.** Clicking into the terminal turns the commands off. The terminal keeps every key.
- **It counts for chords only.**

### Nested groups

Two controllers can own nested groups, and both claim a key in the inner pane. Options: the innermost owner wins, or
both lose the key with a warning, as two commands of one applet do under UTERM-013.

### Names

The permission kind and its declaration spelling, the Janet functions, and the exec message names. Each follows
UTERM-021's "The declaration's data shape" and UTERM-003's verb-noun naming.

### How ADR-04 changes

ADR-04 says an applet binds keys only for its own actions. A controller is a third key owner. Options:

- A new ADR that supersedes ADR-04, restating its rules with three owners.
- A narrower ADR that adds controller keys and leaves ADR-04's text in force for the other two.

## Risks

- **New ScriptWire, exec protocol, and permission-kind versions are published contracts** — likelihood: high,
  impact: medium. Mitigation: each wire refuses an unknown version at the hello, and an unknown permission kind fails
  closed. See "Version skew".
- **Plain-key capture confuses the user** — likelihood: medium, impact: medium. A pane stops scrolling or typing on
  Space, and the user does not know why. Mitigation: the indicator on each affected pane, the scope to the controller's
  own panes, and revoking from the badge.
- **A controller's palette entry passes for uniterm's** — likelihood: medium, impact: medium. Mitigation: attribution
  in the palette. See "Registry mechanism".
- **Changing the registry at runtime destabilizes the menu** — likelihood: medium, impact: medium. The menu and key
  resolution assume a fixed set today. Mitigation: M1 tests adding and removing controller commands while uniterm's
  and the applets' commands keep their keys and menu places.
- **A waiting read blocks the Janet thread** — likelihood: high, impact: low. A controller cannot serve other work while
  it waits. Accepted: the read takes a timeout. A controller that needs both reads with short timeouts. A Janet event
  loop is out of scope.
- **The deferred screen control is never filed** — likelihood: low, impact: low. Mitigation: the revisit hook on M4.

## Milestones

### M1: Commands and the event read

**Status:** NOT STARTED

- A Janet controller run declares commands. They show in the palette, attributed to the controller, only while a pane
  it owns has focus
- Invoking one from the palette records an event, and the controller's read returns it
- A run without the new power is refused before any command is registered
- Ending the run, revoking it, or closing the window removes its commands at once and fails its pending read
- A stalled controller never delays the palette, and its read times out
- Adding and removing controller commands leaves uniterm's and the applets' commands with the same keys and menu places
- A restored layout has no controller commands

### M2: Shortcuts

**Status:** NOT STARTED

- A controller binds a chord and a plain key. Each invokes its command while a pane the controller owns has focus,
  including a terminal pane
- In panes it does not own, the same keys reach the pane as before
- A reserved uniterm key and a user's remap win over a controller key. The dropped key is reported to the user
- Each pane where controller keys are live shows the controller and its keys
- The ADR for the third key owner is accepted

### M3: Exec drivers

**Status:** NOT STARTED

- An exec driver declares commands and receives their invocations
- A driver that speaks an older exec protocol is refused at the hello, before any effect

### M4: Presenter example

**Status:** NOT STARTED

- A Janet script in the real app lays out two text viewers for slides and notes, and advances and goes back from the
  palette and from Page Down and Page Up
- A UI test runs the example and captures it on screen
- The screen-control proposal is filed, per "Scope: commands and their events, not screen control"

## Decision Log

- 2026-11-15: Screen control moved to a follow-up proposal, filed once M4 runs.
- 2026-11-15: Controllers may bind plain keys in their own panes, winning over the pane's own handling.
- 2026-11-15: Controller commands are live only while a pane the controller owns has focus.
- 2026-11-15: ADR candidate (cuts across the system): a program that is neither uniterm nor an applet may own keys,
  only in panes it controls, and only after uniterm's keys and the user's remaps. Pending: its form is the open
  question "How ADR-04 changes".

## References

- ADR-02: stable pane IDs
- ADR-03: restored state never runs a program
- ADR-04: uniterm owns key bindings
- ADR-07: failure isolation
- ADR-08: UI responsiveness
- ADR-09: control authority requires authenticated identity and explicit scope
- ADR-11: deferred applet replies never hide effects
- ADR-12: unchosen changes never move focus or arm input
