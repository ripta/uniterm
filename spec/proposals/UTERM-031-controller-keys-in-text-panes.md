# UTERM-031: Controller Keys Outside Opted-In Panes

**Status:** retracted
**Created:** 2026-11-15
**Updated:** 2026-11-16

## Dependencies

- UTERM-024, for controller commands, keys, and the opt-in rule
- UTERM-013, for reserved keys, remaps, and the menu's key route

## Impacts

- UTERM-024 — "Scope: what the presenter requires", "Where a controller lives", and its risk "The third-key-owner rule
  shifts under UTERM-031": each names this proposal as the home for keys in panes that do not opt in. No such work
  exists, and nothing in UTERM-024 changes. Those lines now point at a retracted proposal.
- UTERM-025 — the risk "Stepping needs focus in the slide pane": its text says this proposal "declines that for now".
  This proposal is retracted, so the risk stands on its own. Its next review restates the line.
- UTERM-033 — the risk "In-flight proposals widen what Allow turns on": this proposal widens nothing.

## Summary

This proposal would have let a controller's keys work in panes that do not opt in, such as a terminal. It is
retracted. Key routing under UTERM-024 already does the right thing in every pane. A key pressed in a pane that does not
opt in belongs to that pane, and a controller has no claim on it. See "Retracted: key routing is already correct".

## Motivation

During a live demo, the presenter's user types in the terminal and then has to click back into the slide pane to step.
A key that worked from the terminal would save the click.

## Design Decisions (Settled)

### A key never takes typed input

Decision: in a pane that takes typed text, a controller key never takes a key that pane treats as input. Control and
Option keys are input to a terminal: Ctrl-C interrupts, and Ctrl-U and Ctrl-W edit the line. Plain keys are typed text.

Rationale: the design critic found that a controller binding Ctrl-C in a terminal member would take the interrupt and
learn line-editing keys.

### Retracted: key routing is already correct

Decision: this proposal is retracted. No key reaches a controller from a pane that does not opt in, and none should.
The user chose this.

uniterm routes each key press in this order:

1. **uniterm's shortcuts.** A key that matches one of uniterm's own items, such as Cmd-W or Cmd-D, or a user's App
   Shortcuts remap, runs that item first. This holds in every pane, whatever has focus. No applet, content, or
   controller can take such a key, per ADR-04 and UTERM-013 "Which keys uniterm reserves".
2. **The active pane.** Every other key goes to the pane that has keyboard focus. That pane's own keys, such as the
   terminal's Cmd-T or the text viewer's Cmd-F, run there.

What the active pane does with the key depends on what it is:

- **A terminal pane.** The key goes to the program in the terminal's foreground. With no program running, the shell
  gets it, and Right Arrow moves the cursor on the command line.
- **The controller's own terminal.** A controller runs as a program in the terminal it was started from. That terminal
  is not a member of the controller's group, so it never opts in. A key typed there goes to the terminal's foreground,
  as in any terminal:
  - When the controller runs in the foreground, the controller is that program. It reads the key from its own
    terminal directly, with no help from UTERM-024 or this proposal. UTERM-024's Motivation already says a script can
    read its own terminal while that terminal has focus.
  - When the controller runs in the background, the shell or the program in the foreground gets the key. The
    controller has no claim on it. UTERM-025's presenter runs in the foreground, and the demo runs in another pane.
- **A slide pane that opts in.** UTERM-024 lets a body kind opt in to giving a controller's keys to the controller
  instead of to itself. The text viewer's Markdown body opts in, under UTERM-030, since it never takes typed text. A
  key reaches the controller only when all of these hold:
  - the key is one the controller declared, such as Right Arrow for Next Slide;
  - the pane is a member of that controller's group;
  - the pane's content has keyboard focus;
  - the content's kind opts in.

  The controller then receives the key as a command event, such as Next Slide, and steps the slide.
- **A slide pane that does not opt in.** The pane keeps every key, and the controller never sees it. For example, the
  text viewer's PDF and plain text bodies do not opt in, so Right Arrow there moves through the document. The same
  holds for any pane whose content does not opt in, including terminals, the REPL, and the browser. A web page gets
  its own keys, and a PDF view gets its own keys.

Rationale: in each case, the key goes where the user pressed it. In the controller's own terminal, the controller
already gets keys when it is the foreground program. In the slide pane, UTERM-024 delivers them. In every other pane,
the key belongs to that pane's program or content. A controller that took it would take the user's input from the
program the user is talking to. So no pane is left where a controller needs a key and cannot already get it, and this
proposal has nothing to add.

The click in the Motivation is real. Stepping from the slide pane, after a click on it, is the intended behavior.
UTERM-025 owns that cost as its risk "Stepping needs focus in the slide pane".

### Which keys

Original question: Command keys only, on the premise that they are never terminal input, or Command keys plus keys each
applet type declares it never treats as input.

Decision: closed by the retraction. No key is live outside opted-in panes.

### Menu placement and remaps

Original question: a Command key and a user's remap reach a command through a menu item today. Whether controller
commands gain menu items for this, against UTERM-024's palette-only decision.

Decision: closed by the retraction. UTERM-024's palette-only decision stands.

### The source pane

Original question: whether a key is live in the source terminal, which is not a group member.

Decision: closed by the retraction. The source terminal's keys go to its foreground program, as "Retracted: key
routing is already correct" describes.

### Nested groups

Original question: only if keys are live outside members, which controller wins a key in a nested pane.

Decision: closed by the retraction. Keys are live only in members, so UTERM-024's rule that no pane has two
controllers' keys stands.

## Design Decisions (Open)

None.

## Risks

None identified: the proposal is retracted and ships nothing.

## Milestones

### M1: Keys outside opted-in panes

**Status:** DROPPED

- A controller's key invokes its command where this proposal makes it live
- No key reaches the controller as a terminal's typed input

**As built:**

- Nothing was built. Dropped by the retraction. See the Decision Log entry of 2026-11-16 that retracts this proposal.

## Decision Log

- 2026-11-15: Split from UTERM-024. The presenter binds no chord, so chords are not required.
- 2026-11-16: Narrowed to panes that do not opt in. UTERM-024 now takes any key, with or without modifiers, in opted-in
  panes, so chords there are no longer this proposal's.
- 2026-11-16: Review start: 1 milestone, 1 settled decision, 1 risk, no `**Live after:**` lines or row gates, 4 open
  questions. No out-of-scope statements. At commit "Take the deck as an argument and keep the input channel general".
  The user asked for an autonomous review of the open questions.
- 2026-11-16 (autonomous, provisional): deferred the proposal, on the ground that no key in a terminal, browser, or
  PDF body is safe for a controller. Overturned at the review gate, below.
- 2026-11-16 (autonomous, provisional): deferred "Menu placement and remaps", "The source pane", and "Nested groups"
  with "Which keys". Overturned at the review gate, below.
- 2026-11-16 (autonomous): amended the Motivation to say Focus Pane chords avoid the click. Reverted the same day. The
  user pointed out that nobody steps a talk with a chord before and after every slide, so the real cost is the click.
- 2026-11-16: filed the bug "A Command key that no menu item takes reaches the terminal program, against the surface's
  own comment". It stays open on its own, and this retraction does not settle it.
- 2026-11-16: Review gate: the deferral changed to a retraction. The user walked through where a key goes: uniterm's
  shortcuts first, then the active pane. A terminal's key goes to its foreground program. The controller's own terminal
  gives the controller its keys when it runs in the foreground. An opted-in slide pane gives them to the controller
  through UTERM-024, and a pane that does not opt in keeps them. That is already correct, so this proposal has nothing
  to do. The review's earlier framing was wrong. It treated "the terminal" as one pane that needed a controller's keys,
  when the controller's own terminal already has them and any other terminal's keys belong to its program.
- 2026-11-16: Retracted. M1 is dropped. No ADR candidate.

## References

- ADR-04: uniterm owns key bindings
- ADR-09: control authority requires authenticated identity and explicit scope
