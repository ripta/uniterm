# UTERM-041: A Uniform Marker Slot for Every Tab

**Status:** draft
**Created:** 2026-11-21
**Updated:** 2026-11-21

## Dependencies

- UTERM-005, for the browser's tab ownership by a controller's grant
- UTERM-037, for the browser's remote commands as they now behave
- UTERM-004, for pane control, grants, and the pane's control badge

## Impacts

- UTERM-019 — "What a Run Leaves in Its Tabs". Its sentence that a tab's "remote-control marker goes away" at run end
  (about line 502) most likely refers to the pane badge. UTERM-004 CONTROL-1 and UTERM-005 "Control" define the
  "remote-control marker" as the pane badge. Separately, UTERM-019 designs a second, per-tab marker for tabs not
  rebuilt at run end (about lines 509, 522, and 888). That marker says a controller's code may still run in the tab,
  offers a rebuild, and outlives the grant. This proposal's slot must hold it, so UTERM-019 M3's marker waits on this
  proposal's M1. UTERM-019 is updated once this proposal is decided.
- The terminal and browser applets: the shared tab bar they use gains a marker slot.

## Summary

Every tab of every pane gets one place to show markers, drawn the same way everywhere. A pane whose tab bar is hidden,
or whose applet has no tabs, counts as its one tab and shows its markers beside the pane's control badge. The first
marker shows authority: a tab is marked while a controller's live grant can act on it.

## Motivation

A controller can drive some of a browser pane's tabs and not others. UTERM-005 lets a controller act only on tabs it
opened, and the user's own tabs sit beside them. Today the pane's control badge says only that the pane is under
control. Nothing says which tabs the controller can reach.

UTERM-019 designs a second per-tab marker for tabs a run leaves behind. It warns that a controller's code may still
run in the tab, and it outlives the grant. That marker is the reason the slot holds a list. The authority marker and
the run-end marker can sit on one tab at once.

The user asked for a uniform slot rather than a browser-only mark. Any tab of any pane can show markers, even in pane
types that do not use them yet. When markers are needed, there is one way to display them.

Today the shared tab bar (`Packages/UnitermKit/Sources/AppletKit/AppletTabBar.swift`) takes plain titles through
`update(titles:selected:canOpenTab:)`. Each tab item holds only a title and a close button. A published tab
(`AppletTab`, in `AppletKit/AppletTab.swift`) carries an ID, a title, and search details, and nothing else. The pane's
control badge (`WindowKit/PaneFrameView.swift`) is a 20-point antenna in the pane's top-right corner, drawn by the
window.

The badge also covers the tab bar's trailing end. The browser already makes room for it. `BrowserApplet+Remote.swift`
sets `content.badgeReach`, and `BrowserView.swift` sets `tabBarTrailing.constant = -badgeReach`. The terminal ignores
`hostBadgeReachDidChange`. See the open question on badge clearance and the linked bug.

## Design Decisions (Settled)

### A published tab carries its markers, and shared code draws them

Decision: a published tab carries a list of markers. The shared tab bar draws them in a fixed slot in each tab item.
The host draws the markers of a pane's one tab when the pane shows no tab bar. Chosen by the user on 2026-11-21.

- An applet reports markers through the tabs it already publishes. The host learns of a change through the existing
  tab change notice. Drafting detail, not the user's choice. See "Who computes the authority marker".
- An applet with no tabs publishes one tab, as today, and its markers show at the pane level. Drafting detail, not the
  user's choice.
- An applet never draws a marker itself. Drafting detail, not the user's choice.

Rationale: one look everywhere, and a new applet gets the slot by publishing tabs, as it already must.

### The authority marker follows what a live grant can act on

Decision: the first marker is authority. A tab carries it while a controller's live grant can act on that tab, and it
clears when the grant ends. Chosen by the user on 2026-11-21.

- In a browser pane, only the tabs the controller opened carry it, per UTERM-005 "Control". Drafting detail, not the
  user's choice.
- In an applet whose grant covers every tab, such as a terminal, every tab of a remote-controlled pane carries it.
  Drafting detail, not the user's choice. See "Access mode or live controller".
- The marker follows the grant, never the content. A tab the controller opened loses it when the grant ends, and a tab
  the user opened never carries it. Drafting detail, not the user's choice.

Rationale: the marker states exactly what the program can reach. It shows authority, which ADR-15 keeps apart from how
an action behaves, so it does not make a program's work look different.

### A pane with no tab bar shows its marker beside the control badge

Decision: when the tab bar is hidden for a single tab, or the applet has no tabs, the pane's one tab shows its markers
just to the leading side of the pane's control badge. Chosen by the user on 2026-11-21.

- Clicking a marker there opens the same control menu the badge opens. Drafting detail, not the user's choice. See
  "Interactive markers".

Rationale: the badge says the pane is under control, and the marker says its content is the controller's. Folding the
two into one icon would give one icon two meanings. See "Whether the pane-level marker shows when it repeats the
badge", which questions the second half of that rationale.

## Design Decisions (Open)

### Access mode or live controller

Decision 2 marks a tab while a live grant can act on it. Its terminal bullet and the M1 check say every tab of a
remote-controlled pane. The two differ when remote control is enabled and no controller is connected.
`controllers(of:)` is empty then (`MainWindowController+Control.swift`, about line 50). Candidates:

- Follow a live controller's grant. A pane with remote control enabled and no controller shows no marker. This matches
  decision 2's wording.
- Follow the pane's access mode. A pane with remote control enabled shows markers whether or not a controller is
  connected. This matches the terminal bullet and the M1 check, and it states what a controller could do, not what one
  does.

### Who computes the authority marker

Decision 1 says an applet reports markers. Only `CallerOwning` applets hear about grants, today just the browser,
through `adoptFirstTab` and `grantDidEnd` in `TabOpening.swift`. Every other applet gets only
`controlDidChange(PaneControl)`, which holds access, driver, and generation, with no controller set. A terminal, text
viewer, image viewer, map, or REPL cannot know a live grant. Candidates:

- The host computes the marker for every applet. `CallerOwning` applets expose their owned tab IDs. This matches the
  badge, which `PaneFrameView.swift` builds from the window's own control table. Each applet draws its own tab bar
  from its own state, and no host call hands tab data back down. So for the shared tab bar to draw a host-computed
  marker, the host needs a new call that gives each applet its authority markers by tab ID, which the applet then
  republishes. That is an `Applet` protocol change for every applet with tabs. If the host instead keeps the marker
  outside the published tab, it changes decision 1's "a published tab carries a list of markers", and the user would
  confirm that.
- `PaneControl` gains live-controller state. This changes the contract for every applet. Like the first candidate,
  it adds a channel from the host down to the applet. The two differ only in its shape.
- The marker keys to the access mode. See "Access mode or live controller".

### Whether the pane-level marker shows when it repeats the badge

The badge shows when any of these holds (`PaneFrameView.swift`, about lines 43-45): the pane is not disconnected, an
exec driver is attached, an owner or an unowned group is set, a controller is connected, or a control intent is saved.
The authority marker follows a grant, per "Access mode or live controller", so the two do not always appear together.
A disconnected terminal pane with an exec driver shows the badge and no authority marker. In a single-tab pane whose
grant covers the whole applet, they agree whenever a grant is live. A one-tab browser pane can differ even then, when
the user opened its tab. This question depends on "Access mode or live controller".

Decision 3's rationale says the marker shows "its content is the controller's". Decision 2 says the marker "follows
the grant, never the content". Those two conflict. Candidates:

- Show the pane-level marker only when it adds information beyond the badge.
- Show it always, so the slot looks the same in every pane.
- Fold it into the badge for panes where the two always agree.

### Interactive markers

UTERM-019's run-end marker offers a rebuild, and it outlives the grant, when the badge may be hidden. Decision 3 says
a click on a pane-level marker opens the control menu. That menu belongs to the badge and may have nothing to offer
once the grant has ended. Questions:

- What does clicking a marker do in the tab bar? Candidates: nothing, open the control menu, or open a per-marker
  action such as the rebuild.
- What does clicking a pane-level marker do when the marker has no badge to belong to?
- Where does a pane-level marker sit when no badge shows?

Without an answer, UTERM-019's rebuild marker cannot use this slot.

### What "can act on" covers

`listPanes` (`WindowScripting.swift`, about line 130) returns every tab's title in an authorized pane, the user's own
tabs included. So the marker cannot mean "everything the program can reach". Candidates:

- Define the marker as "the applet's tab commands accept this tab". Pane-level reads belong to the badge.
- Narrow `listPanes` to the tabs the grant covers. This is a scope addition, since it changes what a controller may
  read.

### Markers outside the tab bar

The palette lists published tabs (`MainWindowController+Palette.swift`, about line 138). Candidates:

- Show markers in palette rows.
- Leave them out, and say so in the proposal.

### How the host knows the tab bar is hidden

Decision 3 needs the host to know when a pane's tab bar is hidden. Today every applet already follows one rule. The
terminal hides its bar below two tabs (`TerminalApplet.swift`, about line 729), the browser does the same
(`BrowserView.swift`, about lines 232-235), and every other applet publishes exactly one tab and has no bar. The
question is whether to write that rule down. Candidates:

- A contract that one published tab means no bar, which is today's behavior.
- The applet reports bar visibility to the host.

### Marking the pane doing the controlling

Today the pane a controller acts from, such as the terminal running `uniterm run`, shows the same antenna badge as a
controlled pane. `PaneControlMark.controllers` holds "each controller with authority over the pane, the ones acting
from it included" (`WindowKit/PaneFrameView.swift`). Only the tooltip and menu text differ, with a "Controller:" line.
The icon does not say whether a pane drives others or is driven. The user asked whether the controlling pane gets a
marker, and which. This is an addition: it widens what the proposal marks. Candidates:

- No addition. The badge's text stays the only sign of a controlling pane.
- A controlling marker in the same slot, on the tab the controller runs in. Two pairings from the user's preferred
  glyphs: a steering wheel for the controlling pane and a robot for controlled tabs, or a game controller for the
  controlling pane and a robot for controlled tabs.

Fact to check first: a script's grant binds to its source pane. Whether the app knows which tab of that pane runs the
controller is unverified.

### The authority marker's look

The glyph, color, and size of the marker in a tab and beside the badge. A mockup shows candidates:
https://claude.ai/artifact/MNi6hZgjP6eBsqDc3rFVaP. The user's leading choice, not yet settled, is a cursor with
rays, the SF Symbol `cursorarrow.rays`, which reads as "a program can act here". The user also likes the robot, the
game controller, and the steering wheel, and the robot reads well for a controlled tab if the controlling pane gets
its own marker. Candidates:

- A cursor with rays, small and tinted peach, in the marker slot. The leading choice.
- A key, for "a grant reaches this tab".
- A game controller, a joystick (`arcade.stick`), or a steering wheel, for "control". All are SF Symbols.
- A vehicle or robot for "driven by a program": `car.top.radiowaves.rear` (a car under remote signal), `drone`, or
  `robotic.vacuum`, the only robot SF Symbol. A plain robot head has no SF Symbol and would ship as a custom glyph.
  Each was confirmed on macOS 26.6.2. The app's minimum is macOS 26.0, so M1 checks that the chosen symbol resolves
  there.
- The badge's own antenna glyph, small and tinted peach, leading the tab's title.
- A small peach dot leading the tab's title.
- A peach underline or edge on the tab.

Constraint: tab titles are untrusted text. A page or program sets them. The marker must sit in a region the title
cannot reach, or have a form that text cannot imitate. A glyph inside the title's own run fails that test.

Two candidates have a pane-level problem. The antenna candidate puts two antennas side by side at pane level, the
marker and the badge. The underline candidate has no pane-level form, since there is no tab to underline.

Leading choices from the user on 2026-11-21, not yet settled:

- Controlled tab, while a live grant can act on it: two gears, filled (`gearshape.2.fill`).
- UTERM-019's run-end marker: the same filled gears, set apart by shape. The user dropped the outlined form, since
  filled and outlined gears are hard to tell apart alone at tab size. Under color-blindness simulations, a yellow or
  red recolor collapses into the live marker, and gray nearly matches it in grayscale. A slash through the gears, or a
  warning triangle beside them, differs by shape and survives every simulation. The user chose the slash: the marker
  itself changes, rather than a second mark beside it that changes its meaning. No slashed gear exists as an SF
  Symbol, so the slash is drawn over the filled gears, with a gap in the tab's background color so it stays legible at
  12 points. Its accessibility label differs from the live marker's.
- The controlling tab or pane, if "Marking the pane doing the controlling" is kept: `cpu`, with `arcade.stick` as the
  backup.

Rendered at 10, 12, and 14 points beside tab text, all four stay recognizable from 12 points up. At 10 points the chip
reads as a plain square. Filled and outlined gears are easy to tell apart side by side. Seen alone in a tab, the
difference is a matter of stroke weight. The outlined form also reads as the quieter state, while the run-end marker
warns that a controller's code may still run.

### One marker or several in a slot

Whether a tab shows every marker it carries, side by side, or one at a time with an order between kinds. Two kinds are
designed, not one: authority, and UTERM-019's run-end marker. Candidates:

- Show every marker, in a fixed order by kind, up to a cap.
- Show every marker, each its own control when it has an action.
- Show the highest-ranked marker, with the rest in the tooltip. This hides an actionable marker, so it fits only if no
  marker has an action. See "Interactive markers".

### Keeping the tab bar clear of the control badge

This is a scope addition. It fixes a layout fault that this proposal does not create. The badge sits in the pane's
top-right corner, over the last tab or the new-tab button when a tab bar shows. The browser keeps clear of it. The
terminal does not. See `bugs/20261121-terminal-tab-bar-ignores-control-badge.md`. Candidates:

- No addition. This proposal leaves the bar as it is, and the bug waits.
- The terminal forwards the reach to the shared bar through `hostBadgeReachDidChange`, as the browser does.
- The shared bar takes the reach, and the browser's own trailing constraint is removed.
- The tab bar moves its new-tab button to the leading side. The last tab's close button stays covered.

### VoiceOver

How a marked tab and the pane-level marker read to VoiceOver. An actionable marker must be its own accessibility
element. Candidates:

- The tab's accessibility value names its markers, such as "selected, under controller control". This fits only
  markers with no action.
- Each marker is its own accessibility element.

Changing a tab's accessibility value from "selected" breaks `UITests/TabsUITests.swift` (about lines 58-89). Those
tests change with it.

## Risks

- **The marker misstates what a grant reaches** — likelihood: low, impact: high. A marker on a tab the grant cannot
  act on, or missing from one it can, tells the user the wrong thing about a program's power. Only the browser
  enforces per-tab grants today. Mitigation: whoever computes the marker reads the same ownership state the commands
  check. See "Who computes the authority marker".
- **A shared contract changes for every applet with tabs** — likelihood: high, impact: low. `AppletTab` and the tab
  bar gain a field and a slot that every applet compiles against. Accepted: a tab without markers draws as today.
- **ADR-15 is still proposed** — likelihood: low, impact: low. Decision 2's rationale leans on it. ADR-14 also carries
  the authority argument. Mitigation: the decision rests on ADR-14 if ADR-15 changes.
- **UTERM-019 M3 inherits this slot** — likelihood: medium, impact: medium. If this proposal settles the slot without
  an action, UTERM-019's rebuild marker cannot use it. Mitigation: the "Interactive markers" question.
- **A title imitates a marker** — likelihood: low, impact: medium. A page can set a title that looks like a marker,
  and the user reads authority that is not there. Mitigation: the look constraint in "The authority marker's look".

## Milestones

### M1: The marker slot and the authority marker

**Status:** NOT STARTED

M1 is blocked on the open questions above.

- A published tab carries a list of markers, and a tab without markers draws as today
- The shared tab bar draws a tab's markers in a fixed slot, and its title truncates to make room
- A browser tab the controller opened carries the authority marker while the grant lives, and loses it when the grant
  ends
- A browser tab the user opened never carries it
- A terminal's tabs carry it or not by the rule "Access mode or live controller" settles. This check is rewritten
  when that question settles
- A pane with no tab bar shows its one tab's markers beside the control badge. What a click does waits on
  "Interactive markers"
- A marker change publishes the tabs and sends `appletTabsDidChange`. The browser's `refresh()` compares titles, IDs,
  and selection only (`BrowserApplet.swift`, about line 1457), so it must compare markers too
- Every `tabOwners` change updates the marker on the same turn. That covers open, adopt, grant end, control change,
  and tab close
- The host redraws the pane-level marker from `appletTabsDidChange`, which today only refreshes the palette
- `AppletTabBar.update` takes published tabs, or titles with markers
- The reach reported through `hostBadgeReachDidChange` includes the pane-level marker
- A marker stays whole at the 80-point narrowest tab
- A UI test captures a browser pane with a marked and an unmarked tab, and a single-tab pane with its marker beside
  the badge

## Decision Log

- 2026-11-21: Drafted from the user's request for a uniform per-tab marker slot, with an authority marker first. The
  user chose that the marker follows what a live grant can act on, that a published tab carries its markers for shared
  code to draw, and that a pane with no tab bar shows its marker beside the control badge.
- 2026-11-21: Critique pass (autonomous). Fixed facts: the browser's tab bar already clears the badge, and only the
  terminal ignores it. UTERM-019's "remote-control marker" most likely means the pane badge, and UTERM-019 separately
  designs a per-tab run-end marker, so UTERM-019 is now a dependency. Marked the agent's mechanisms under each settled
  decision as drafting detail. Added open questions: access mode or live controller, who computes the authority
  marker, whether the pane-level marker repeats the badge, interactive markers, what "can act on" covers, markers
  outside the tab bar, and how the host knows the tab bar is hidden. Extended the questions on one marker or several,
  the look, badge clearance, and VoiceOver. Added three risks and the M1 implementation checks. Filed a bug for the
  terminal's tab bar. No settled decision was reversed.
- 2026-11-21: Re-check fixes. UTERM-019 moved out of Dependencies, since its run-end marker waits on this slot, not
  the reverse. Corrected three facts in open questions: the badge's show conditions, today's shared rule that one
  published tab means no bar, and what host-computed markers would change. The two M1 checks that drafting detail had
  settled now wait on their open questions. The user named cursor with rays as the leading look, not yet settled.
  (autonomous)
- 2026-11-21: Final re-check fixes, not re-checked: the host-computed candidate now names the host-to-applet call it
  needs, and the joystick is corrected to an SF Symbol. The critique loop ran three passes. What remains is open
  questions for `/proposal-reviewer`. (autonomous)
- 2026-11-21: Added "Marking the pane doing the controlling" at the user's question, labeled an addition. The user
  likes the robot, the game controller, and the steering wheel for the look.
- 2026-11-21: The user's leading look: filled two gears for a controlled tab, outlined two gears for UTERM-019's
  run-end marker, and the cpu chip for the controlling tab with the joystick as backup. Not yet settled.
- 2026-11-21: The user dropped outlined gears for the run-end marker and asked for a variant of the filled gears that
  stays legible at tab size and visible with color blindness. Simulations rule out a recolor. A slash or a warning
  badge remains.
- 2026-11-21: The user chose a slash drawn through the filled gears for UTERM-019's run-end marker, over a warning
  badge, since a badge adds a second mark that changes another marker's meaning. Still to be confirmed in review.

## References

- UTERM-004: pane control and the control badge
- UTERM-005: the browser applet's controller-owned tabs
- UTERM-019: the run-end marker this proposal's slot must hold
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): grants and what a controller opened
- [ADR-15](../adr/ADR-15-a-programs-operation-is-the-users.md): authority, the one thing kept apart
- `bugs/20261121-terminal-tab-bar-ignores-control-badge.md`: the terminal's tab bar under the badge
