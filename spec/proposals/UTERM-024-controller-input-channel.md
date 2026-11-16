# UTERM-024: Controller Input Channel

**Status:** draft
**Created:** 2026-11-15
**Updated:** 2026-11-16

## Dependencies

- UTERM-002, for the command registry, the palette, and the one dispatch point that keys, menus, and the palette share
- UTERM-003, for the `uniterm` Janet module, ScriptWire, and its scope note that defers script-registered commands
- UTERM-004, for controller runs, groups and their members, the disconnected mode, revocation, and the permission kinds
- UTERM-013, for command owners, reserved keys, and the order in which a key finds its command
- UTERM-021, for the `declare-permissions` spelling a new permission kind must define

## Impacts

- UTERM-025 — the whole proposal: this is a required prerequisite of the presentation controller. Its Next Slide and
  Previous Slide are commands declared here, bound to the arrow keys and Page Up and Page Down.
- UTERM-028 — "Any key" and "When commands are live": exec drivers gain the same commands and events.
- UTERM-031 — "Which panes take a controller's keys": keys in panes that do not opt in, such as the source terminal.
- UTERM-029 — "When commands are declared": Go to Slide needs runtime declaration, which this proposal leaves out.
- UTERM-003 — "Scope": supersedes in part its out-of-scope line "Invoking or registering UTERM-002 registry commands
  from scripts". Registering becomes in scope. Invoking stays out. UTERM-003 is implemented, so its text stays, and it
  gains a "Superseded in part by UTERM-024" marker when this proposal is accepted.
- UTERM-013 — "What one shortcut declaration is" and "Which keys uniterm reserves": supersedes in part its two-owner
  model. A controller joins uniterm and applet types as a third key owner, after uniterm's keys and the user's remaps.
- UTERM-004 — "Exec wire format": an invocation is a host event, not an applet event, so "remote callers receive no
  applet events" stands and nothing there is superseded. ScriptWire's version goes up.
- UTERM-007 — "Control levels": the text viewer opts in to controller keys, per "Which panes take a controller's keys".
- UTERM-019 — "Page events": the event read here takes the same cursor, timeout, and dropped-count shape, if Open
  question "The event model" settles that way.
- UTERM-022 — "Where the form calls live": a host-side waiting call is the precedent this proposal weighs in Open
  question "Where the read lives".

## Summary

A Janet controller declares commands. They appear in the command palette while one of the controller's panes has
focus. A command may be bound to a key, with or without modifiers. When the user invokes one, uniterm records an
event. The controller reads its events and acts on them.

This is a required prerequisite of the presentation controller, UTERM-025. Exec drivers, keys in panes that do not opt
in, and screen control are not required, and live in UTERM-028, UTERM-031, and UTERM-026.

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

Decision: this proposal holds only what UTERM-025 cannot work without. That is Janet controller commands declared in
the controller's file, their palette entries, their keys, and the events their invocations produce.

- Commands declared by exec drivers are UTERM-028.
- Keys in panes that do not opt in, such as the source terminal, are UTERM-031.
- Declaring commands at runtime serves only Go to Slide, UTERM-029.
- Pane zoom, full screen, and presenter windows are UTERM-026.

Rationale: people step through slides with the arrow keys and Page Up and Page Down, and clickers send the same keys.
Stepping from the palette alone is not usable for a talk.

### Where a controller lives

Decision: a Janet controller runs in the process the user started in a terminal pane, its source. It commands the
members of the groups it owns, which are the panes its layout requests opened. It does not live in those panes.

- The controller's keys and commands are live only in members of its own groups. A pane the user split off inside the
  group's area is not a member, and neither is a pane of another controller's nested group, per UTERM-004 "Group node
  kind". So no pane has two controllers' keys.
- The source pane is not a member, so the controller's commands are not live there. Its terminal keeps every key.
  UTERM-031 weighs keys there.
- Group membership is by stable node ID, per ADR-02.

Rationale: a controller acts only on what it opened. Keying liveness to membership reuses the rule UTERM-004 already
enforces for commands, and settles nested groups with no extra rule.

### Which panes take a controller's keys

Decision: a controller's keys reach it only in applet types that opt in, and only while the pane's content has keyboard
focus.

- An applet type opts in when its content never takes typed text. The text
  viewer's rendered page opts in. The terminal, the REPL, and the browser do not, since each takes typed text the host
  cannot always see.
- Keyboard focus must be in the content itself. A find field, a sheet, or the command palette has focus elsewhere, so
  it keeps its keys.
- A pane the user disconnects through its chrome keeps all its keys, per ADR-09's rule that remembered permission does
  not override a disconnected pane.

Rationale: uniterm cannot tell in general when a pane is taking text input. A browser cannot see focus inside a web
page without page script. Opting in pane types that are known safe means a controller never takes keys from a pane type
nobody vetted. Because a key reaches a controller only where nothing is typed, any key may be bound without the
controller learning typed text.

### Any key

Decision: a controller may bind any key, with or without modifiers. Each controller binds the keys its job needs, such
as UTERM-025's arrows and Page Up and Page Down.

- uniterm's reserved keys and the user's remaps win over a controller's key, as for applet keys under UTERM-013. The
  menu's key route lives in the window's key-equivalent handling. Whether plain arrows reach it is unverified, so the
  check runs where the controller's keys arrive, and M2 proves a remap onto a plain arrow still wins. A key that loses
  is dropped, and the user is told.

Rationale: the input channel is general. The opt-in rule, not a key list, keeps typed text from a controller, so a
list would only limit controllers with no safety gain. The user chose this.

### When commands are live

Decision: a controller's palette entries and its keys go live on the same rule. They are live while keyboard focus is
in the content of a member pane that is not disconnected. A key is live only in an opted-in applet type.

- A command goes live when keyboard focus moves into such a pane, never while focus is already there. A layout request
  that makes an open pane a member, or a declaration that arrives while the user is typing, waits for the next focus
  change, per ADR-12.
- A command that is not live is not listed in the palette. Its keys reach the pane as if it did not exist.
- The palette judges liveness by the pane whose content had keyboard focus when the palette opened, since opening the
  palette moves focus out of the pane.
- Each pane where a controller's keys are live shows that the controller is taking keys, and the user can revoke the
  controller from there. How it shows is open. See "The key indicator".

### Palette only, with the controller named

Decision: controller commands appear in the palette and are bound to keys. They have no menu bar item. Every palette row
for a controller command names the controller it came from, using the name the transport verified, per ADR-09. A
controller cannot style that name or leave it out.

Rationale: a palette row that names its controller cannot pass for uniterm's own command, and the user knows which
program acts. UTERM-022's requester header is the precedent. A command's key is carried where the key arrives, so it
needs no menu item. The user chose palette only, and asked that rows say where they came from.

### Powers and lifecycle

Decision: these follow from accepted ADRs.

- Declaring commands is a power of its own. Pane control does not grant it, per ADR-09. Its name and spelling are open.
  See "Names".
- An invocation is recorded when the user acts. The read only waits for recorded events, so it may hold a pending
  reply, per ADR-11. Recording never waits on the controller, per ADR-08.
- When the run ends, the grant is revoked, or the window closes, the controller's commands leave the palette and the
  keys at once. Pending reads fail, and any buffered events are discarded, per ADR-09 and ADR-11.
- A controller that stalls or crashes ends only itself. The palette and the keys never wait on it, per ADR-07.
- No command, key, or event is saved with a layout. A restored group has no commands until a live controller declares
  them, per ADR-03.

### Version skew

Decision: ScriptWire refuses an unknown version at the hello, as it does today.

- A new helper with an old app, or an old helper with a new app: the run fails at the hello before any effect, with
  the message to relaunch uniterm. The helper is the bundle's own, so a relaunch heals it.
- A declared file that names the new permission kind or declares commands is refused whole by an older build.
- A policy file holding an approval of the new kind makes an older build treat the whole file as newer, so every
  remembered approval goes inert until the user is back on the new build. That fails closed, as UTERM-022 found for
  `ask-user`. See Risks.

Rationale: the helper and the app ship in one bundle, so exact-match refusal costs nothing but a relaunch.

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
event carries the pane that had focus and the input that triggered it, palette or key.

### Registry mechanism

- The registry is fixed after launch today. Registering a type twice trips a precondition. Controller commands need
  adding and removing at runtime, without disturbing uniterm's and the applets' commands.
- Availability is keyed by applet type today. Controller commands need it keyed by group membership.
- How the controller's name looks in a palette row, and how a search matches it.

### How keys reach the controller

Plain keys arrive through each view's `keyDown`, and keys with modifiers may arrive as key equivalents first. Options:

- The window offers a key to the controller before the focused view, only while the controller's keys are live there.
- The opted-in applet's content view offers its keys to the window first.

### The key indicator

The slide pane is the pane being projected, so a badge listing the controller's keys shows to the audience. Options: a
small mark in the pane chrome with the list on hover, the list in the status bar while the pane has focus, or both.

### Names

The permission kind and its declaration spelling, the spelling for declaring commands and their keys, and the Janet
functions. Each follows UTERM-021's "The declaration's data shape" and UTERM-003's verb-noun naming.

### How ADR-04 changes

ADR-04 says an applet binds keys only for its own actions. A controller is a third key owner, and its keys
pre-empt a pane's ordinary handling of those keys, not only its bindings. Options:

- A new ADR that supersedes ADR-04, restating its rules with three owners.
- A narrower ADR that adds controller keys and leaves ADR-04's text in force for the other two.

## Risks

- **A new ScriptWire version and permission kind are published contracts** — likelihood: high, impact: medium.
  Mitigation: ScriptWire refuses an unknown version at the hello, and an unknown permission kind fails closed. See
  "Version skew".
- **Downgrading leaves every remembered approval inert** — likelihood: low, impact: medium. After an approval of the
  new kind is saved, an older build treats the whole policy file as newer. Accepted: it fails closed, as UTERM-022
  accepted, and the approvals come back on the new build.
- **Navigation-key capture confuses the user** — likelihood: medium, impact: medium. A viewer stops scrolling on the
  arrow keys, and the user does not know why. Mitigation: the key indicator, the scope to the controller's own members,
  and revoking from the pane.
- **An applet opts in that takes typed text** — likelihood: low, impact: high. Any key may be bound, so a controller
  would read what the user types there. Mitigation: opting in a type is a decision in that type's proposal, and M2
  checks that the terminal, the REPL, and the browser never deliver a key to a controller.
- **A controller's palette entry passes for uniterm's** — likelihood: medium, impact: medium. Mitigation: attribution
  in the palette. See "Registry mechanism".
- **Changing the registry at runtime destabilizes the menu and keys** — likelihood: medium, impact: medium.
  Mitigation: M1 tests adding and removing controller commands while uniterm's and the applets' commands keep their
  keys and menu places.
- **A waiting read blocks the Janet thread** — likelihood: high, impact: low. A controller cannot serve other work while
  it waits. Accepted: the read takes a timeout. A controller that needs both reads with short timeouts. A Janet event
  loop is out of scope.

## Milestones

### M1: Commands and the event read

**Status:** NOT STARTED

- A Janet controller's declared commands show in the palette, each row naming the controller, only when the palette
  opened from a member pane's content
- Invoking one from the palette records an event, and the controller's read returns it
- A run without the new power is refused before any command is registered
- Ending the run, revoking it, or closing the window removes its commands at once and fails its pending read
- A stalled controller never delays the palette, and its read times out
- Adding and removing controller commands leaves uniterm's and the applets' commands with the same keys and menu places
- A restored layout has no controller commands

### M2: Keys

**Status:** NOT STARTED

- A controller's plain keys and keys with modifiers invoke its commands while a text viewer member's page has focus
- The same keys reach the pane as before in a pane that is not a member, including one split off inside the group's
  area and the source terminal
- The same keys reach the pane as before in a disconnected member, a terminal, REPL, or browser member, a find field,
  and the command palette
- A letter key bound by a controller never reaches it from a terminal, REPL, or browser member, or a find field
- A command never goes live while keyboard focus is already in the pane
- A reserved uniterm key and a user's remap win over a controller key, including a remap onto a plain arrow. The
  dropped key is reported to the user
- The key indicator shows on each pane where the controller's keys are live
- The ADR for the third key owner is accepted

## Decision Log

- 2026-11-15: Screen control moved to its own proposal, UTERM-026. The presenter moved to UTERM-025.
- 2026-11-15: Controller commands are live only while a pane the controller owns has focus.
- 2026-11-15: Plain keys came back from UTERM-027 as required. People step slides with the arrow keys, so a presenter
  without them fails its job.
- 2026-11-15 (addition): lifts the registering half of UTERM-003's out-of-scope line on registry commands.
- 2026-11-15: Removed the claim that a response to a command may move focus "within ADR-12's rules for chosen changes".
  ADR-12 has no rules for chosen changes, and the presenter moves no focus. UTERM-026 owns the question.
- 2026-11-15: Chords moved to UTERM-031. The presenter binds none, and Control chords would let a controller take Ctrl-C
  and line-editing keys from a terminal member. The user chose this. Superseded on 2026-11-16 by "Any key": keys with
  modifiers are back, and UTERM-031 narrows to panes that do not opt in.
- 2026-11-15: Navigation keys reach a controller only in applet types that opt in, while their content has keyboard
  focus. The user chose this over a per-applet text-input hook and a plain focus check.
- 2026-11-16: Any key may be bound, with or without modifiers. The user corrected an agent trim that had limited
  UTERM-024 to the presenter's six keys. The input channel stays general, and UTERM-025 binds only what it needs. The
  opt-in rule keeps typed text from a controller. Keys with modifiers come back too, since the Ctrl-C finding was about
  terminals, which never opt in.
- 2026-11-15: commands are declared in the controller's file only. The user confirmed it on 2026-11-16. Runtime declaration serves only UTERM-029's
  Go to Slide. The source pane is never live, since it is not a member and chords left. Nested groups need no rule,
  since liveness is by membership.
- 2026-11-16: Controller commands appear in the palette only, with no menu item. The user chose this, after the design
  critic flagged that the agent had settled it without asking. Left undone: menu discoverability, and remapping a
  controller command by its menu title.
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
