# UTERM-024: Controller Input Channel

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-15

## Dependencies

- UTERM-002, for the command registry, the palette, and the one dispatch point that keys, menus, and the palette share
- UTERM-003, for the `uniterm` Janet module, ScriptWire, and its scope note that defers script-registered commands
- UTERM-004, for controller runs, groups and their owners, revocation, and the permission kinds
- UTERM-013, for command owners, reserved keys, and the order in which a key finds its command
- UTERM-021, for the `declare-permissions` spelling a new permission kind must define

## Impacts

- UTERM-025 — the whole proposal: this is the presentation controller's required prerequisite. Its Next Slide and
  Previous Slide are commands declared here.
- UTERM-027 — "Chord shortcuts": plain keys for controllers build on the key ownership settled here.
- UTERM-028 — "Who may declare commands": exec drivers gain the same commands and events.
- UTERM-003 — "Scope": its out-of-scope line "Invoking or registering UTERM-002 registry commands from scripts" is the
  registering half of what this proposal builds. Invoking registry commands from scripts stays out of scope.
- UTERM-013 — "What one shortcut declaration is" and "Which keys uniterm reserves": a controller joins uniterm and
  applet types as a third command owner. Its keys come after uniterm's and the user's.
- UTERM-004 — "Exec wire format": an invocation is a host event, not an applet event. "Remote callers receive no applet
  events" stands. ScriptWire's version goes up.
- UTERM-019 — "Page events": the event read here takes the same cursor, timeout, and dropped-count shape, if Open
  question "The event model" settles that way.
- UTERM-022 — "Where the form calls live": a host-side waiting call is the precedent this proposal weighs in Open
  question "Where the read lives".

## Summary

A Janet controller declares commands. They appear in the command palette, and may carry chord shortcuts, while one of
the controller's panes has focus. When the user invokes one, uniterm records an event. The controller reads its events
and acts on them.

This is the required prerequisite for the presentation controller, UTERM-025. Plain keys, exec drivers, and screen
control are not required, and live in UTERM-027, UTERM-028, and UTERM-026.

## Motivation

A program can already drive applets. A Janet script can lay out panes and send commands to the text viewer. What no
script can do is hear the user. A script gets no events at all, and the built-in applets emit no input events.

A presentation controller shows each slide with `show-markdown`. Today it has no way to learn that the user wants the
next slide. The only workaround is reading lines from the script's own terminal. That needs Enter, and works only while
that terminal has focus.

The same gap blocks other controllers: a build dashboard with Rerun, a review tool with Approve and Next File, a
debugger with Step. Each is a small set of named actions that the user triggers and the program handles.

## Design Decisions (Settled)

### Scope: what the presenter requires

Decision: this proposal holds only what UTERM-025 cannot work without. That is Janet controller commands, their palette
entries, chord shortcuts, and the events their invocations produce.

- Plain keys with no modifier, for clickers, are UTERM-027.
- Commands declared by exec drivers are UTERM-028.
- Pane zoom, full screen, and presenter windows are UTERM-026.

Chord shortcuts are in scope because stepping through a talk from the palette alone is not usable.

### When commands are live

Decision: a controller's commands are live only while the focused pane belongs to a group the controller owns.

- "Live" covers the palette, the menu, and shortcuts together. A command that is not live is not listed in the palette.
  Its keys reach the pane as if it did not exist.
- Group membership is by stable node ID, per ADR-02.
- A controller's commands never act in panes it does not own, so it cannot take keys from the user's other panes.

Whether the group's source pane counts is an open question. See "The source pane".

### Chord shortcuts

Decision: a controller may bind chords, keys with Command, Control, or Option.

- uniterm's reserved keys win over the controller, per UTERM-013. A user's remap wins over every default. A controller
  key that loses is dropped, and the user is told, as UTERM-013 does for an applet key.
- A controller chord that the focused pane's applet also binds goes to the controller, while that pane is the
  controller's.

### Powers, lifecycle, and the ADRs

Decision: these follow from accepted ADRs.

- Declaring commands is a power of its own. Pane control does not grant it, per ADR-09. Its name and spelling are open.
  See "Names".
- An invocation is recorded when the user acts. The read only waits for recorded events, so it may hold a pending
  reply, per ADR-11. Recording never waits on the controller, per ADR-08.
- When the run ends, the grant is revoked, or the window closes, the controller's commands leave the palette, the menu,
  and the keys at once. Pending reads fail, and any buffered events are discarded, per ADR-09 and ADR-11.
- A controller that stalls or crashes ends only itself. The palette and the keys never wait on it, per ADR-07.
- No command, key, or event is saved with a layout. A restored group has no commands until a live controller declares
  them, per ADR-03.
- Invoking a command is the user's choice. A change the controller makes in response may move focus within ADR-12's
  rules for chosen changes. A shortcut pressed before such a change never counts as the choice that arms input after it.

### Version skew

Decision: ScriptWire refuses an unknown version at the hello, as it does today.

- A new helper with an old app, or an old helper with a new app: the run fails at the hello before any effect, with
  the message to relaunch uniterm.
- A declared file that names the new permission kind is refused whole by an older build, which does not know the kind.
  A policy file holding an approval of the new kind makes an older build treat the whole file as newer, so every
  remembered approval goes inert. That fails closed, as UTERM-022 found for `ask-user`.

## Design Decisions (Open)

### Where the read lives

- **A host call, like UTERM-022's form calls.** ScriptHost holds the pending read for the connection. It knows the
  caller, needs no applet behind it, and does not count against the per-window cap of 64 pending applet replies.
- **A pending reply in the applet dispatcher, like UTERM-019's `next-events`.** It reuses `PendingReply` and the
  authority recheck. There is no applet behind a controller's commands, so it would need a stand-in target, and it
  would share the per-window cap with browser reads.

### The event model

- **A per-run cursor buffer, like UTERM-019.** Bounded by count. It drops the oldest events and reports how many were
  dropped. Several readers can each keep a cursor.
- **A single-reader queue.** Each event is delivered once. Simpler, but a helper that reads from two places loses
  events.

Either way: the bound, whether a drop raises an error in Janet by default as UTERM-019's helpers do, and whether an
event carries the pane that had focus and the input that triggered it, such as palette, menu, or key.

### When commands are declared

- **Statically**, in `declare-permissions`. The approval prompt can list the commands and keys before the run starts.
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

### The source pane

The terminal that started a script is the group's source. It is not a member. Options:

- **It counts.** The presenter can step slides from the terminal. Its chords then take keys the shell would get.
- **It does not count.** Clicking into the terminal turns the commands off. The terminal keeps every key.

### Nested groups

Two controllers can own nested groups, and both claim a key in the inner pane. Options: the innermost owner wins, or
both lose the key with a warning, as two commands of one applet do under UTERM-013.

### Names

The permission kind and its declaration spelling, and the Janet functions. Each follows UTERM-021's "The declaration's
data shape" and UTERM-003's verb-noun naming.

### How ADR-04 changes

ADR-04 says an applet binds keys only for its own actions. A controller is a third key owner. Options:

- A new ADR that supersedes ADR-04, restating its rules with three owners.
- A narrower ADR that adds controller keys and leaves ADR-04's text in force for the other two.

## Risks

- **A new ScriptWire version and permission kind are published contracts** — likelihood: high, impact: medium.
  Mitigation: ScriptWire refuses an unknown version at the hello, and an unknown permission kind fails closed. See
  "Version skew".
- **A controller's palette entry passes for uniterm's** — likelihood: medium, impact: medium. Mitigation: attribution
  in the palette. See "Registry mechanism".
- **Changing the registry at runtime destabilizes the menu** — likelihood: medium, impact: medium. The menu and key
  resolution assume a fixed set today. Mitigation: M1 tests adding and removing controller commands while uniterm's
  and the applets' commands keep their keys and menu places.
- **A waiting read blocks the Janet thread** — likelihood: high, impact: low. A controller cannot serve other work while
  it waits. Accepted: the read takes a timeout. A controller that needs both reads with short timeouts. A Janet event
  loop is out of scope.

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

### M2: Chord shortcuts

**Status:** NOT STARTED

- A controller's chord invokes its command while a pane the controller owns has focus
- In panes it does not own, the same chord reaches the pane as before
- A reserved uniterm key and a user's remap win over a controller chord. The dropped key is reported to the user
- The ADR for the third key owner is accepted

## Decision Log

- 2026-11-15: Screen control moved to its own proposal, UTERM-026. The presenter moved to UTERM-025.
- 2026-11-15: Controller commands are live only while a pane the controller owns has focus.
- 2026-11-15: Narrowed to what UTERM-025 requires. Plain keys moved to UTERM-027, keeping the user's choice that a
  controller may bind them in its own panes. Exec driver commands moved to UTERM-028. The previous text settled both
  here, with milestones M2 and M3 for them.
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
