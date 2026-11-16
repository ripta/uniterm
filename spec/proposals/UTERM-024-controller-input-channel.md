# UTERM-024: Controller Input Channel

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-15

## Dependencies

- UTERM-002, for the command registry, the palette, and the one dispatch point that keys, menus, and the palette share
- UTERM-003, for the `uniterm` Janet module, ScriptWire, and its scope note that defers script-registered commands
- UTERM-004, for controller runs, groups and their owners, the disconnected mode, revocation, and the permission kinds
- UTERM-013, for command owners, reserved keys, and the order in which a key finds its command
- UTERM-021, for the `declare-permissions` spelling a new permission kind must define

## Impacts

- UTERM-025 — the whole proposal: this is a required prerequisite of the presentation controller. Its Next Slide and
  Previous Slide are commands declared here, bound to navigation keys.
- UTERM-028 — "Navigation keys" and "When commands are live": exec drivers gain the same commands and events.
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

A Janet controller declares commands. They appear in the command palette while one of the controller's panes has
focus. A command may be bound to a navigation key, such as an arrow key, or to a chord. When the user invokes one,
uniterm records an event. The controller reads its events and acts on them.

This is a required prerequisite of the presentation controller, UTERM-025. Exec drivers and screen control are not
required, and live in UTERM-028 and UTERM-026.

## Motivation

A program can already drive applets. A Janet script can lay out panes and send commands to the text viewer. What no
script can do is hear the user. A script gets no events at all, and the built-in applets emit no input events.

A presentation controller shows each slide with `show-markdown`. Today it has no way to learn that the user wants the
next slide while the slide pane has focus. The script can read only its own terminal. That works only while the
terminal has focus, and a presenter steps from the slide, usually with the arrow keys.

The same gap blocks other controllers: a build dashboard with Rerun, a review tool with Approve and Next File, a
debugger with Step. Each is a small set of named actions that the user triggers and the program handles.

## Design Decisions (Settled)

### Scope: what the presenter requires

Decision: this proposal holds only what UTERM-025 cannot work without. That is Janet controller commands, their palette
entries, navigation keys and chords, and the events their invocations produce.

- Commands declared by exec drivers are UTERM-028.
- Pane zoom, full screen, and presenter windows are UTERM-026.

Rationale: people step through slides with the arrow keys and Page Up and Page Down, and clickers send the same keys.
Stepping from the palette alone is not usable for a talk.

### Where a controller lives

Decision: a Janet controller runs in the process the user started in a terminal pane, its source. It commands the panes
in the groups it owns, which are the panes its layout requests opened. It does not live in those panes.

- The controller's keys are live only in its own groups' panes. It never hears keys in any other pane.
- Group membership is by stable node ID, per ADR-02.

### When commands are live

Decision: a controller's commands are live only while the focused pane belongs to a group the controller owns, and
that pane is not disconnected.

- "Live" covers the palette, the menu, and keys together. A command that is not live is not listed in the palette.
  Its keys reach the pane as if it did not exist.
- A pane the user disconnects through its chrome keeps all its keys, per ADR-09's rule that remembered permission does
  not override a disconnected pane.

Whether the group's source pane counts is an open question. See "The source pane".

### Navigation keys

Decision: a controller may bind plain keys, with no modifier, only from a fixed list of navigation keys: the four
arrows, Page Up, Page Down, Home, End, Space, Return, and Escape.

- Letters, digits, and punctuation are never bindable as plain keys. A controller that owns a terminal therefore never
  learns what the user types in it.
- A pane taking text input keeps every key. That covers a text field with focus, such as the text viewer's find field
  or the browser's address bar, an input method composing text, and a terminal pane. The controller's navigation keys
  are not live there.
- A navigation key goes live only on the next focus change into the pane, never while the user is already typing in
  it, per ADR-12.
- uniterm's reserved keys and the user's remaps win over a controller's key, as for applet keys under UTERM-013.
  Plain keys do not pass through the menu's key route today, so this proposal adds the check where they arrive.
- Each pane where a controller's navigation keys are live shows that the controller is taking keys. The badge names
  the controller and lists its keys. The user can revoke the controller from there.

Rationale: the list holds the keys people move with, and nothing anyone types text with. The text-input carve-out keeps
find fields and terminals working inside a controller's panes.

### Chords

Decision: a controller may also bind chords, keys with Command or Control. uniterm's reserved keys and the user's remaps
win over them. A controller key that loses is dropped, and the user is told, as UTERM-013 does for an applet key.

### Powers and lifecycle

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

### Version skew

Decision: ScriptWire refuses an unknown version at the hello, as it does today.

- A new helper with an old app, or an old helper with a new app: the run fails at the hello before any effect, with
  the message to relaunch uniterm. The helper is the bundle's own, so a relaunch heals it.
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
  dropped. Several readers can each keep a cursor. A read only looks, so a failed or lost reply loses nothing.
- **A single-reader queue.** Each event is delivered once. Removing an event is an effect, so under ADR-11 a read that
  fails or loses its reply loses the event. This option must say how it avoids that.

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
- Where they appear in the menu bar: a per-controller menu or a Controller menu. Chords and user remaps reach a command
  only through a menu item today, so a palette-only option needs a new key route.
- How the palette and the menu label them, so a controller titled "Close Window" cannot pass for uniterm's command. A
  user's App Shortcuts remap matches menu items by title, so a controller item must not inherit a remap meant for
  another item. UTERM-022's requester chrome is a precedent for the label.

### A chord against the focused applet's key

Whether a controller chord wins over the focused applet's own binding of the same chord in the controller's pane, or
loses to it. Winning keeps the controller's keys predictable. Losing keeps every applet command reachable.

### The source pane

The terminal that started a script is the group's source. It is not a member. Options:

- **It does not count.** Clicking into the terminal turns the commands off. The terminal keeps every key.
- **It counts for chords only.** The presenter can step from the terminal with a chord. Navigation keys stay with the
  shell, since a terminal is a text-input pane under "Navigation keys".
- **It counts.** Same as chords only, since navigation keys are never live in a terminal.

### Nested groups

Two controllers can own nested groups, and both claim a key in the inner pane. Options: the innermost owner wins, or
both lose the key with a warning, as two commands of one applet do under UTERM-013.

### Names

The permission kind and its declaration spelling, and the Janet functions. Each follows UTERM-021's "The declaration's
data shape" and UTERM-003's verb-noun naming.

### How ADR-04 changes

ADR-04 says an applet binds keys only for its own actions. A controller is a third key owner, and its navigation keys
pre-empt a pane's ordinary handling of those keys, not only its bindings. Options:

- A new ADR that supersedes ADR-04, restating its rules with three owners.
- A narrower ADR that adds controller keys and leaves ADR-04's text in force for the other two.

## Risks

- **A new ScriptWire version and permission kind are published contracts** — likelihood: high, impact: medium.
  Mitigation: ScriptWire refuses an unknown version at the hello, and an unknown permission kind fails closed. See
  "Version skew".
- **Navigation-key capture confuses the user** — likelihood: medium, impact: medium. A viewer stops scrolling on the
  arrow keys, and the user does not know why. Mitigation: the indicator on each affected pane, the scope to the
  controller's own panes, and revoking from the badge.
- **A key list that grows leaks typed text** — likelihood: low, impact: high. A later change adding letters to the list
  would let a controller read what the user types. Mitigation: the list is settled here, and widening it is a decision
  for a later proposal.
- **A controller's palette entry passes for uniterm's** — likelihood: medium, impact: medium. Mitigation: attribution
  in the palette and the menu. See "Registry mechanism".
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

### M2: Keys

**Status:** NOT STARTED

- A controller's arrow key and its chord each invoke its command while a viewer pane it owns has focus
- In panes it does not own, in a disconnected pane, and in a text field or terminal it owns, the same keys reach the
  pane as before
- A letter, digit, or punctuation key without a modifier is refused when declared
- A key never goes live in a pane while the user is typing in it
- A reserved uniterm key and a user's remap win over a controller key. The dropped key is reported to the user
- Each pane where controller keys are live shows the controller and its keys
- The ADR for the third key owner is accepted

## Decision Log

- 2026-11-15: Screen control moved to its own proposal, UTERM-026. The presenter moved to UTERM-025.
- 2026-11-15: Controller commands are live only while a pane the controller owns has focus.
- 2026-11-15: Plain keys came back from UTERM-027 as required, limited to a fixed navigation-key list. People step
  slides with the arrow keys, so a presenter without them fails its job. The list, the text-input carve-out, and the
  disconnected-pane rule answer the design critic's finding that any plain key would let a controller read typed text.
  Exec driver commands stay in UTERM-028.
- 2026-11-15 (addition): lifts the registering half of UTERM-003's out-of-scope line on registry commands.
- 2026-11-15: Removed the claim that a response to a command may move focus "within ADR-12's rules for chosen changes".
  ADR-12 has no rules for chosen changes, and the presenter moves no focus. UTERM-026 owns the question.
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
