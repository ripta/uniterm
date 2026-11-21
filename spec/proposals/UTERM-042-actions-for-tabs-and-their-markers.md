# UTERM-042: Actions for Tabs and Their Markers

**Status:** draft
**Created:** 2026-11-21
**Updated:** 2026-11-21

## Dependencies

- UTERM-041, for the marker slot, the controlling chip, the kind table, and the call that performs a marker's action
- UTERM-004, for pane control, the control badge, and Revoke Controller
- UTERM-019, for the run-end marker and its "Rebuild Tab" action

## Impacts

- UTERM-041 — "Interactive markers" says the authority marker has no actions, and "What a click on the chip does"
  makes the chip inert. Both change once this proposal settles its entry point. UTERM-041 is amended then, with a
  Decision Log entry.
- UTERM-019 — "What a run leaves in its tabs". Its run-end marker's "Rebuild Tab" menu, which UTERM-041 builds, may
  fold into this proposal's menu. See "How marker-kind actions join the menu".

## Summary

A tab and its markers get one menu of actions. It holds revoking one controller, going to the tab a controller runs
in, going to the tabs a controller can act on, and ordinary tab actions such as Close Tab. Every action is also a
command in the command palette, so the keyboard reaches it.

## Motivation

UTERM-041 marks which tabs a controller can act on, with two gears, and which tab a controller runs in, with the chip.
Both markers are inert. The user can see the relationship but cannot act on it from where it shows.

Today the only control actions sit in the pane badge's menu (`WindowKit/PaneFrameView.swift`, about lines 348-374).
Its Revoke Controller ends every controller of the pane at once (`revokeController(_:)`,
`MainWindowController+Control.swift`, about line 121). The host can already revoke a single connection
(`ScriptHost.revokeControllers(_:)`, which takes a set). Nothing in pane chrome offers that.

Nothing takes the user from a controlled tab to the tab driving it, or the other way. The palette's `chooseTab`
(`MainWindowController+Palette.swift`, about line 203) already focuses a pane and selects a tab. A go-to action can
build on that.

Tab items take no right-click today. `AppletTabBar.swift` has no `rightMouseDown`, `menu(for:)`, or context menu. A
click on the item selects the tab, and its close button takes its own click.

The palette already lists commands beside tabs. Each command runs against the palette's target pane through a
`CommandContext` (`MainWindowController+Palette.swift`, about lines 87-104).

## Design Decisions (Settled)

### Which actions are in scope

Decision: the menu holds four kinds of action. Chosen by the user on 2026-11-21.

- Revoke one controller, rather than every controller of the pane.
- Go to the tab a controller runs in, from a tab it controls.
- Go to the tabs a controller can act on, from the tab it runs in.
- Ordinary tab actions, such as Close Tab. See "Which general tab actions".

Rationale: the markers show a relationship between tabs. These actions let the user follow it and end it where it
shows.

### Every action is a palette command

Decision: each action in the menu is also a command in the command palette, so the keyboard reaches it. Chosen by the
user on 2026-11-21.

Rationale: a menu opened by a click leaves keyboard users out. The palette already runs commands against its target
pane.

## Design Decisions (Open)

### Where the menu opens

Candidates:

- A left-click on a marker opens its menu. Tabs get no right-click.
- A right-click on a tab opens one menu for the tab, its markers' actions included. Markers stay inert on left-click,
  as UTERM-041 settled.
- Both.

The user leans toward one of the first two, since two mouse interactions for one menu are not needed. A right-click on
a tab is the only entry that can carry general tab actions, unless markers carry them too. A left-click on a marker
reaches only tabs that carry one.

### What revoking one controller ends

ADR-14 says "Revocation ends the grant in every window it reaches." Candidates:

- The controller's whole grant, in every window, the same as the badge's Revoke Controller for that controller. Its
  groups lose their owner, and its waiting calls fail.
- Only its reach into this pane. Disconnect Pane already does that for the pane, so this adds a second way.

A driver keeps its attached channel to its own pane after revoke (`MainWindowController+Control.swift`, about line
126). Whether "revoke this driver" says so needs deciding too.

### Going to a tab across windows, and targets that close

A controller's tabs can sit in several windows, per ADR-14. Questions:

- Does go-to raise another window?
- When a controller controls several tabs, does "go to controlled tabs" list them, or cycle through them?
- What does an action do when its target closes while the menu is open? ADR-02 requires stable node IDs, and the
  target is held by pane and tab identity, never by index.
- A controller granted a pane explicitly is bound to the pane's newest session, per UTERM-041 "How an explicit grant
  picks its tab". Go-to lands on that tab.

### How marker-kind actions join the menu

UTERM-041 gives a marker kind its actions, and its run-end kind has "Rebuild Tab" in a small menu at the marker.
Candidates:

- Fold every marker kind's actions into this menu, so a tab has one menu.
- Keep each marker's own menu, and add this menu beside it.

The run-end marker's action runs in the applet. Revoke and go-to are host actions. ADR-08 says the main thread never
waits on an applet or a script, so the menu builds from host state and an applet action returns at once.

### Which general tab actions

Candidates include Close Tab, Close Other Tabs, Close Tabs to the Right, Duplicate Tab, and Move Tab to a New Pane.
Which belong here, and whether each applet adds its own items, needs deciding. ADR-04 governs any key binding. A menu
item needs none.

### Palette commands: wording and target

The palette runs a command against its target pane. Questions:

- Does a command act on the target pane's selected tab?
- How does "Revoke Controller" for one controller read beside the badge's pane-wide one, so the two are not confused?
- When a tab has several controllers, how does the user pick one from the palette?

### Panes with no tab bar

UTERM-041 shows a one-tab pane's markers at the pane level, beside the badge. How the user opens this menu there, and
whether it merges with the badge's menu, follows from "Where the menu opens".

### VoiceOver

UTERM-041 makes each marker its own accessibility element, and the tab's value stays "selected" or "unselected". How
the menu is reached by VoiceOver, such as through the tab element's actions, needs deciding.

## Risks

- **Two revokes with different reach** — likelihood: medium, impact: medium. The badge's Revoke Controller ends every
  controller of the pane, and this proposal's ends one. A user who learns one may misjudge the other. Mitigation: the
  open question on palette wording names them apart.
- **A revoke from the wrong tab** — likelihood: low, impact: medium. A menu opened on one tab that ends a grant
  reaching many windows can surprise the user. Mitigation: the item names the controller and says the grant ends
  everywhere, per "What revoking one controller ends".
- **An action on a target that is gone** — likelihood: medium, impact: low. A tab or pane can close while the menu is
  open. Mitigation: actions hold stable identities, per ADR-02, and do nothing when the target is gone.

## Milestones

### M1: The tab action menu

**Status:** NOT STARTED

- The menu opens from the entry point "Where the menu opens" settles, on a tab and on a pane-level marker
- Revoke for one controller ends that controller's grant as "What revoking one controller ends" settles, and leaves
  every other controller of the pane in place
- Go to the controlling tab focuses that pane and selects that tab, and go to controlled tabs reaches each tab the
  controller can act on
- The general tab actions "Which general tab actions" settles work from the menu
- Every action is a command in the palette, and runs against the palette's target pane
- An action whose target closed while the menu was open does nothing
- Building the menu never waits on an applet or a script
- A UI test opens the menu on a controlled browser tab and on a controller's terminal tab, and runs go-to both ways

## Decision Log

- 2026-11-21: Drafted at the user's request during UTERM-041's review, which kept that proposal's markers inert. The
  user chose the four kinds of action and that every action is a palette command. The user leans toward one mouse
  entry point rather than two.

## References

- UTERM-041: the marker slot, the chip, and the call that performs a marker's action
- UTERM-004: pane control, the badge, and Revoke Controller
- UTERM-019: the run-end marker and "Rebuild Tab"
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): revocation ends a grant in every window it reaches
- [ADR-02](../adr/ADR-02-pane-tree-nodes-have-stable-ids.md): stable node identity
- [ADR-08](../adr/ADR-08-ui-responsiveness.md): the main thread never waits on another process
- [ADR-04](../adr/ADR-04-uniterm-owns-key-bindings-and-terminal-config.md): key bindings
