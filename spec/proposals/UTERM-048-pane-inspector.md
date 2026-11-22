# UTERM-048: Pane Inspector

**Status:** draft
**Created:** 2026-11-22
**Updated:** 2026-11-22

## Dependencies

- UTERM-003, for `list-panes`, whose builder M1 moves onto the shared snapshot. It is implemented
- UTERM-004, for pane control, groups, owners, and controller runs. It is implemented
- UTERM-013, for the command registry that places the inspector in the menu and the palette, and for shortcut
  ownership
- UTERM-041 M1, for M5: the markers a published tab carries

## Impacts

- UTERM-041 — "One snapshot, and scripts see a fixed subset" and M5. Once its markers exist, the snapshot carries them
  and the inspector shows them. `list-panes` does not gain them through this proposal. M3's tab hit-test also touches
  the shared tab bar that its M1 changes, per "Who answers a tab hit-test".
- UTERM-042 — M3 "Pick mode". Pick mode swallows every mouse-down, so a right-click in pick mode never opens its tab
  menu.
- UTERM-003 — "One snapshot, and scripts see a fixed subset". The `list-panes` builder moves onto the shared snapshot,
  and its output does not change.

## Summary

A floating Pane Inspector panel shows everything uniterm knows about a pane and its tabs. That covers the applet
contract fields, the window's state for the pane, and the applet's own internals. It shows hidden state raw, such as
the layout and undo payloads, so the user can debug what flows between panes and launches. The panel follows the
focused pane by default. A target button picks any pane or tab with a click, as an eyedropper picks a color.

## Motivation

uniterm holds a lot of per-pane state the user cannot see. Some of it is shown in pieces. The title shows in the tab
bar, and the control badge's menu summarizes control. The rest shows nowhere:

- An applet's description, which a layout file saves and undo restores (`AppletDescription.swift`, about lines 7-59).
  Its undo-only part never reaches a file, so no tool shows it today.
- Which controller owns a pane's group, and which controllers may act on it. The badge's menu shows a name only. The
  Controllers & Permissions window lists every run's ID, version, key fingerprint, scopes, and PID
  (`ControllersWindowController.swift`, about lines 243-296). Nothing links a pane to those runs.
- The pane's control generation, which decides whether a permission asked for earlier is stale (`PaneControl.swift`,
  about line 59).
- Each tab's search details, its closed-tab stamps, and whether the applet counts as running something.
- Applet internals, such as a terminal tab's PID, its OSC 7 directory, and its ssh or mosh detection
  (`TerminalApplet.swift`, about lines 33-73), or a browser tab's committed URL, security warning, and owning grant
  (`BrowserTab.swift`, about lines 195-221; `BrowserApplet.swift`, about line 87).

The project's rules say hidden state flow must be raised as an explicit decision whenever it turns up. Finding it today
means reading code or adding logging. An inspector makes it visible in the running app.

Scripts see a slice of this already through `list-panes` (`WindowScripting.swift`, about lines 115-166). The user has
no equivalent.

## Design Decisions (Settled)

### A floating panel

Decision: the inspector is one app-wide floating panel, not an applet in a pane and not a popover. Chosen by the user on
2026-11-22.

- It floats above uniterm's windows and never takes key status from the pane it inspects. A window that resigns key
  tells its terminal surfaces they lost focus (`GhosttySurfaceView.swift`, about lines 178 and 548). A program that
  watches focus reports, such as an editor that saves on focus loss, would then act.
- Since the panel is never key, keys typed while it is in front still reach the key window. Cmd-C always copies the
  key window's selection. Only pick mode installs an app-level key monitor, and only for Esc.
- It opens from a Window menu item and a palette command, registered as an app-scoped command like Show Controllers
  (`StandardCommands.swift`, about lines 150-157).
- AppDelegate owns it, as it owns the Controllers window (`AppDelegate.swift`, about lines 849-865).

Rationale: an applet would take a pane and change the layout it inspects. A popover closes as soon as focus moves, so
it cannot follow focus.

### The panel follows focus, and a target button picks

Decision: by default the panel shows the focused pane of the most recently key main window, and it moves as focus
moves. A target button enters pick mode. A click on a pane or on a tab in a tab bar picks it, and picking turns off
focus following. A follow toggle turns following back on. Chosen by the user on 2026-11-22.

- The target is held by window and node ID, never by a path or an index. A picked pane that closes shows as gone. The
  panel never moves to another pane on its own, since node IDs are never reused (ADR-02).
- Following uses `WindowSet`'s key-window order (`WindowSet.swift`, about lines 229-254), so the panel keeps its target
  while the app is in the background.
- Esc leaves pick mode without picking.
- Picking needs a point-to-pane and point-to-tab hit-test. None exists today. Focus follows the first responder instead
  (`PaneAreaView.swift`, about lines 302-328).

### Pane first, then every tab

Decision: the panel shows pane-level data, then one section per tab. The tab that is selected, or the one picked, is
expanded. The others are collapsed. Chosen by the user on 2026-11-22.

Rationale: inspecting a background tab must not require selecting it, since selecting it changes what is inspected.

### What the panel shows

Decision: contract fields come first. They are the priority. Hidden state is shown raw on purpose, as a goal of the
feature. Chosen by the user on 2026-11-22.

Pane level:

- From the window: window number, node ID, whether the pane is focused, the access mode, the driver kind, the control
  generation, the owning group and its owner, and every controller `controllers(of:)` reports, each with its run's
  identity when it has one (`MainWindowController+Control.swift`, about lines 50-78). A plain script with no run and
  a driver have no verified identity
- From the applet contract: type ID, title, status segments, `isRunningSomething`, `runningLabels`, `unsavedWork`,
  `currentDirectory`, and `closedTabStamps`
- The description: type, version, the payload, the undo-only part, and the verbatim bytes of a pane that could not be
  restored. `AppletDescription`'s Codable form drops the last two, so the panel encodes each part itself

Tab level:

- ID, title, details, and whether it is selected
- Markers, once UTERM-041 adds them (M5)

Titles, details, directories, labels, segments, controller names, payloads, and applet sections are untrusted text,
since a program may set them. How the panel draws them is open, per "Drawing untrusted text raw".

### One snapshot, and scripts see a fixed subset

Decision: one snapshot type holds everything the panel shows. `list-panes` builds on it and projects a fixed set of
fields, which are today's fields. It keeps its ReadAccess gate, its per-caller and per-window scoping, and its
`reported` handling of untrusted text. A field the snapshot gains does not reach scripts without its own decision.
Chosen by the user on 2026-11-22.

Rationale: two builders for the same reads would drift. Passing every snapshot field to scripts would silently widen
what an approved controller may read, which ADR-14 P8 and P10 forbid.

- Skew: `list-panes` output is unchanged, so no wire changes. ScriptWire's two sides ship together in any case
  (ADR-13).

### Refreshing

Decision: the panel updates at once on announced changes: focus, title or segments, tabs, and control. While it is
visible, it also rereads its target about once a second, coalesced into one read per turn. Nothing runs while it is
hidden. Chosen by the user on 2026-11-22.

- Today's change hooks are per window, through `PaneStatusHost` and `MainWindowController`'s callbacks
  (`MainWindowController.swift`, about lines 296-310 and 1443-1459). Control changes have no event, only
  `refreshControlMarks()` (`MainWindowController+Control.swift`, about lines 180-221). The panel needs one app-level
  feed that carries all of them.
- The poll covers description changes, which announce nothing.
- Reading the snapshot is a local main-thread read and changes nothing. It never sends a lifecycle event (ADR-05). It
  never runs a program and never touches an inert restored pane beyond reading it (ADR-03).

### Every applet publishes its own section

Decision: the applet contract gains an optional member that publishes applet-specific internals as labeled sections.
It defaults to empty. Every applet type implements it, in M4. Chosen by the user on 2026-11-22.

- Each applet publishes only what it already holds, and the member is a synchronous read. Every value M4 lists is
  already in memory (`TerminalApplet.swift`, about lines 33-73; `BrowserTab.swift`, about lines 195-221;
  `BrowserApplet.swift`, about line 87). A future section that needs outside work, such as a foreground-process lookup,
  brings its own decision. Amended 2026-11-22; see Decision Log.
- uniterm does not reach into an applet's internals itself (ADR-05).
- The member does not throw. Every listed value is a plain in-memory read with no failing case. A section that can
  fail arrives with the decision that brings its outside work.

The user asked for this in a separate milestone if it was much work, and folded in otherwise. It is a contract change
with one implementation and one set of checks per applet type, so it is its own milestone.

## Design Decisions (Open)

### Who answers a tab hit-test

Pick mode must find the tab under a click. Tab bars live inside applet views. `AppletTabBar` exposes only
`update(titles:selected:canOpenTab:)` and an index-based `onSelect` (`AppletTabBar.swift`, about lines 121-170). It
holds no `AppletTabID`. Two accepted proposals change that. UTERM-041 M1 has `update` take published tabs, which carry
tab IDs. UTERM-042 targets its tab menu by tab ID, which needs a point-to-tab mapping in the same bar. Today the
terminal, browser, and Questions applets use the shared bar. The candidates:

- The shared `AppletTabBar` maps a point to a tab ID, and the host asks the pane's bar. This is mostly what UTERM-041
  M1 and UTERM-042 already build, so M3 would depend on UTERM-041 M1. An applet without the shared bar answers
  nothing, so a click there picks the pane.
- The applet contract gains a `tab(at:)` call with a nil default. Each applet answers for its own view. This is a
  second contract change beside M4's.
- Pick mode picks panes only. The panel's tab sections let the user expand any tab. Leaves undone: picking a tab by
  clicking it, which the user asked for.

### Drawing untrusted text raw

The panel shows hidden state raw, on purpose. Program-set text can still hold bidirectional overrides such as U+202E,
newlines, and control characters. A title or payload string could then draw a fake line, such as a forged key
fingerprint, beside real identity data. `list-panes` and the status bar bound such text with `StatusText.bounded`
(`StatusText.swift`, about lines 5-12). The candidates:

- Show the text raw, but draw control and bidirectional scalars as visible escapes, such as `\u{202E}`. Nothing is
  hidden, and nothing reorders or breaks a line. `LaunchApprovalText.escaped` already does this
  (`LaunchApprovalText.swift`, about lines 46-67), and the Controllers window uses it for controller names.
- Draw each field in its own cell as plain text. A spoof stays inside its cell, but reordering still applies within it.
- Apply `StatusText.bounded`, as the status bar does. It drops what the user came to see.

### A keyboard shortcut

The candidates:

- No shortcut. The menu item and the palette command are enough for a debugging tool. The user can still bind one in
  macOS App Shortcuts, which ADR-04 lets win.
- An app-scoped chord, such as Cmd-Option-I, which browsers use for their inspector. App-scoped commands already carry
  keys (`StandardCommands.swift`). UTERM-013 decides who owns it, and the browser applet may want the chord for the
  Web Inspector UTERM-020 hides.

### What a pick click does

The candidates:

- The click only picks. The pane under it gets no click and no focus, as an eyedropper takes no click from the app
  beneath it. A click on a window that is not key must not activate it either.
- The click picks and also focuses the pane, but sends nothing to the applet.

### A cap for raw payloads

A description payload can be large, such as a map's pins or a data viewer's table state. The candidates:

- Show it whole, in a scrolling, lazily drawn text view. M2 already redraws nothing when a poll reads no change.
- Cap what the panel draws, such as at 256 KB, and say how much was cut.

The browser's undo part is the large case. It holds each tab's WebKit interaction state as base64
(`BrowserDescription.swift`, about lines 65-72).

### Copying the snapshot

This adds scope. The candidates:

- No addition. Leaves undone: the panel is never key, so Cmd-C copies the inspected window's selection, not the
  panel's text. Without an addition there is no reliable way to copy from the panel.
- A Copy button per field, which works without key status.
- A Copy as JSON button that copies the whole snapshot. The snapshot may hold paths, URLs, REPL history, and base64
  WebKit state the user would not paste by accident.

## Risks

- **The panel shows state the user treats as private** — likelihood: medium, impact: low.
  Accepted: showing hidden state is the feature's goal, and the panel only shows the user what their own app process
  already holds. It never sends anything anywhere.
- **A snapshot field leaks to scripts** — likelihood: low, impact: high.
  Mitigation: `list-panes` projects named fields only. A test pins its exact field set, so a new snapshot field that
  reaches it fails the test.
- **Polling costs main-thread time** — likelihood: low, impact: medium.
  Mitigation: the poll runs only while the panel is visible, reads one target, and coalesces. The description of a
  pane with a large payload is the costliest read. The cap question decides how much of it the panel draws.
- **The panel takes key status through a slip** — likelihood: medium, impact: medium.
  Opening it with `makeKeyAndOrderFront`, or a selectable text view in it, would make it key. Terminal programs in the
  inspected window then get a focus-out report.
  Mitigation: an M2 check that opening, clicking, and scrolling the panel sends no focus change to the inspected
  terminal.
- **The shared tab bar changes under three proposals at once** — likelihood: medium, impact: low.
  UTERM-041 M1, UTERM-042, and this proposal's M3 all change `AppletTabBar`.
  Mitigation: M3 lands after UTERM-041 M1, or rebases its hit-test onto the bar's new layout.
- **The inspection member becomes a contract every applet must keep** — likelihood: high, impact: low.
  Accepted: the member is optional with an empty default, and its sections are for display only. Nothing parses them,
  so a section's shape can change freely. It is not a wire.

## Milestones

### M1: The shared snapshot

**Status:** NOT STARTED

- One snapshot type holds a pane's window state, its contract fields, its description, and its tabs
- `list-panes` builds its records from the snapshot, and its output is unchanged for every existing test and fixture
- A test pins the exact field set of a `list-panes` pane record and tab record
- Building a snapshot sends no lifecycle event and changes no applet state
- The snapshot holds tab IDs, not script tab numbers. `list-panes` maps IDs to numbers when it projects, and a panel
  read mints no script tab number
- `list-panes` reads no description and no applet section

### M2: The panel, following focus

**Status:** NOT STARTED

- A Window menu item and a palette command open and close the panel
- The panel floats above uniterm's windows and never takes keyboard focus from the inspected pane
- It shows the focused pane of the most recently key window, and it moves when focus moves, within a window and across
  windows
- It shows every pane-level and tab-level field in "What the panel shows", with the selected tab expanded
- The description's payload, undo-only part, and verbatim bytes each show raw
- Each controller the pane lists says what kind it is. A run shows its verified identity. A plain script or a driver is
  never labeled verified, and a descriptor's display name is shown as the controller's claim
- A title, segment, tab, or control change shows in the panel on the same turn
- A description change with no announced event shows within about one second while the panel is visible
- A poll whose read is unchanged redraws nothing
- No poll runs while the panel is hidden, including when it hides because the app is inactive
- Verbatim bytes that are not UTF-8 show as hex
- Untrusted text draws as "Drawing untrusted text raw" settles
- Opening, clicking, and scrolling the panel sends no focus change to the inspected terminal
- The panel shows over a full-screen uniterm window
- A UI test captures the panel beside a terminal pane and a browser pane with two tabs

### M3: Pick mode

**Status:** NOT STARTED

- The target button enters pick mode, and the pointer shows it
- A click on a pane picks it, and a click on a tab in a tab bar picks that tab and expands it
- Picking turns off following, and the follow toggle turns it back on and shows the focused pane at once
- Esc leaves pick mode without picking, and the focused applet receives no key
- Pick mode swallows every mouse-down, right-clicks included, so no tab menu or applet action runs
- A pick click on a window that is not key does what "What a pick click does" settles, and activates nothing else
- Pick mode ends when the app deactivates, the panel closes, or the window under the pointer closes
- A picked pane that closes shows as gone, and the panel does not move to another pane
- A picked tab that closes while its pane stays shows as gone, and the pane stays shown
- A pick in another uniterm window works the same way
- A UI test picks a background tab and shows it expanded without selecting it in its pane

### M4: Per-applet inspection

**Status:** NOT STARTED

- The applet contract has an optional member for inspection sections, with an empty default
- Every applet type publishes a section of what it holds. The terminal shows each tab's PID, start time, OSC 7
  directory, remote client, and exit code. The browser shows each tab's current and committed URL, security warning,
  load state, load origin, error page, and owning grant. The viewers show their source file and their position in it
- Reading a section is synchronous and starts no outside work
- `list-panes` output does not change

### M5: Markers

**Status:** NOT STARTED

- The snapshot carries each tab's markers, with their kind and actions, once UTERM-041 M1 adds them
- The panel shows them in each tab's section
- `list-panes` output does not change

## Decision Log

- 2026-11-22: Filed as a draft. The user chose a floating panel, following focus with a target pick button, contract
  fields first, hidden state shown raw, one snapshot with a fixed script subset, events plus a slow poll, every tab
  shown, and a section from every applet type.
- 2026-11-22 (addition): moving `list-panes`'s builder onto the shared snapshot changes UTERM-003's script path, which
  the Summary does not name. The user chose the shared snapshot with a fixed script subset.
- 2026-11-22: "Every applet publishes its own section" amended. It said a section needing outside work is read off the
  main thread and shows as pending. Every listed value is already in memory, so that path had no caller and
  contradicted "publishes only what it already holds". The member is now a synchronous read. Its rule "A section that
  fails shows as errored. It never ends the panel or the app" is dropped too, since no in-memory read can fail. The
  member does not throw.
- 2026-11-22: the critique added "Who answers a tab hit-test" and "Drawing untrusted text raw" as open questions. The
  first has no owner in the design. The second weighs the raw-display goal against spoofed lines near identity data.
  The Motivation now credits the Controllers window with showing run identity. What is missing is the link from a pane
  to its runs.

## References

- ADR-02: node IDs are stable and never reused, so a picked target cannot resolve to another pane
- ADR-05: applets own what their content means, so each publishes its own inspection section
- ADR-08: refreshes stay bounded on the main thread
- ADR-14: P8 and P10 bound what `list-panes` may expose
