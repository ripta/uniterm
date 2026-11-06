# UTERM-001: Foundation

**Status:** implemented
**Created:** 2026-10-31
**Updated:** 2026-11-06

## Dependencies

- None

## Impacts

- UTERM-002, UTERM-011 — "Regions are separate from position": the palette and widget bar join as regions
- UTERM-003, UTERM-004 — "Panes and applets": scripts and control address panes and applets
- UTERM-003 — "Pane tree shape": the host API must address panes by stable ID, never by tree path, since
  normalization rewrites paths
- UTERM-004 — "Pane tree shape": normalization may merge a program's requested subtree into its parent, and a leaf pane
  has nothing beneath it. Trust should anchor on an explicit owner mark that a layout request creates, not on tree shape.
  A grouping node kind may define its own merge rule
- UTERM-004 — "What layout persistence restores": its "Saved layouts" question would ride on the per-applet description
  version, or bump the schema version for a new node kind
- UTERM-003, UTERM-004 — "Status message model": a posted message records its source, which scripts and exec stderr
  must supply
- UTERM-005 through UTERM-010 — "Panes and applets": every applet implements the applet contract
- UTERM-012 — "Terminal surface behind an internal protocol": blocks need shell integration through that boundary
- UTERM-013 — "Whether uniterm reads the user's Ghostty config" and "What undo close restores": applet actions move to
  applet-declared shortcuts, and Cmd-Shift-T replaces Cmd-Z for reopening

## Summary

This proposal builds the base of uniterm. The app opens one or more windows. Each window holds a tree of resizable split
panes. Each pane runs one applet. Each window has a status bar that can dock at the top or the bottom.

The first applet is a terminal built on libghostty. It runs the user's shell in tabs, or one program without tabs.

Closing a pane can be undone. Window and pane layouts are restored across launches.

## Motivation

uniterm aims to be more than a terminal emulator. Later work adds a command palette, a widget bar, more applets, Janet
scripting, and controls for scripts that drive panes. All of it needs the same base: windows, regions, a pane tree, an
applet contract, and a status bar.

A terminal is the first applet because it is the core use. It also tests the applet contract against a demanding case:
a live process, keyboard input, GPU rendering, and resizing.

## Design Decisions (Settled)

### Platform and UI framework

uniterm is a Swift app for macOS 26 and later. AppKit owns the windows, the pane tree, and applet hosting. SwiftUI is
allowed for small leaf views, such as status bar segments.

Rationale: a nested split tree that hosts AppKit views is easier in AppKit. Those views include a Metal terminal
surface, and later a web view, a QuickLook view, and a map. Targeting macOS 26 allows the newest AppKit APIs. Ghostty's
macOS build also needs Xcode 26 and the macOS 26 SDK.

### Window chrome

Each window is an `NSWindow` with a full-size content view. Content extends up under the title bar. The standard
traffic-light buttons stay.

### Regions are separate from position

A region is a logical part of a window. Its role never changes. Where it docks is a separate setting.

This proposal defines two regions:

- The main content area, which holds the pane tree.
- The status bar, which docks at the top or the bottom of the window.

The command palette and the widget bar become regions in later proposals. The region model must let them join without
changes to the status bar or the content area.

### Status bar

- Each window has one status bar. It is always docked.
- The bar is split into segments. A segment shows a small icon or one line of text, with light formatting such as color.
- Anything in the window may post a message to the window's status bar. Messages queue.
- The bar can open a history panel of past messages. The panel floats over the content area and grows away from the
  bar. Amended 2026-11-01; see Decision Log.

### Panes and applets

- The main content area holds a tree of panes. A pane splits horizontally or vertically, and splits nest.
- Panes are resizable. A pane has a minimum usable size. A split that would push a pane below it is refused.
- A pane runs exactly one applet. The same applet type may run in many panes.
- Opening a new pane asks the user which applet to start.
- Closing a pane closes its applet and every tab the applet has.

### One terminal applet with two modes

The terminal applet covers both APPLET-1 and APPLET-2 from the original write-up:

- Shell mode starts the user's default shell. It supports multiple tabs. Each tab is an independent tty.
- Program mode starts one given executable in one tab, with no new-tab action.

The tab bar is hidden when the applet has only one tab.

Rationale: the write-up says APPLET-2 can be APPLET-1 with a setting, if that is enough. The two modes differ only in
what they launch and whether new tabs are allowed.

### Terminal surface behind an internal protocol

The terminal applet talks to libghostty through an internal protocol owned by uniterm. No libghostty type appears
outside that boundary.

The protocol sits at the terminal-session level: spawn, input, resize, and events for title, working directory,
command-finished marks, notifications, clipboard requests, and exit. It does not sit at the VT level. libghostty's
surface spawns the child process and owns the pty, so a VT-level protocol could not host it. Amended 2026-10-31 and
2026-11-01; see Decision Log.

Rationale: libghostty's API is not stable. `ghostty.h` calls itself Ghostty's internal embedder API, built for its own
macOS app, and points external embedders to libghostty-vt. The boundary limits churn to one module. It also keeps a
fallback to SwiftTerm possible. See Risks.

### Theming

The light theme is Catppuccin Latte. A dark Catppuccin theme ships too. Colors are defined as named tokens in one
place. Applets and regions read the tokens, never raw colors. Amended 2026-10-31; see Decision Log.

### Dark theme flavor and switching

Original questions: which dark flavor, Frappé, Macchiato, or Mocha; and whether the theme follows the system
appearance, an explicit setting, or both.

Decision: the dark theme is Catppuccin Mocha. An appearance setting offers System, Light (Latte), and Dark (Mocha). It
defaults to System. The window chrome, every region, and the terminal palette all follow it, and switch live.

Rationale: following the system with an override is the macOS convention. An explicit-only setting keeps Latte when the
system turns dark at night. System-only gives no way to choose dark inside uniterm. Latte and Mocha are Catppuccin's
usual pair, and Mocha has the most contrast. Offering every dark flavor is a knob no user has asked for.

### Build system

Original question: SwiftPM plus a bundling script, a checked-in Xcode project, or a generated Xcode project from
XcodeGen or Tuist?

Decision: a checked-in Xcode project with synchronized folders, with feature code in a local SwiftPM package.

- The `.xcodeproj` holds only the app target and a UI test target. Synchronized folder groups mean adding a source file
  does not edit `project.pbxproj`.
- Feature code lives in a local package. Its targets are separate modules. The terminal surface module is the only
  target that depends on GhosttyKit.
- Signing and entitlements are project settings.
- `make build` and `make test` wrap `xcodebuild` and `swift test`.

Rationale: it meets the Swift standard's rule that signing lives in project settings, not the Makefile. It has a target
for `XCUIApplication` UI tests, which window drag and divider drag want. Module boundaries are `Package.swift` text,
easy to review. A SwiftPM-plus-script build signs in the Makefile and has no UI test target. XcodeGen and Tuist add a
tool whose Xcode 26 support is unconfirmed. They also discard settings changed in the Xcode UI on the next regeneration.
They solve `project.pbxproj` churn that synchronized folders already avoid.

### What undo close restores

Original question: keep the closed applet alive for a grace period, restore the layout and relaunch, or let each applet
define it? Also, how many closes undo remembers, and for how long.

Decision: undo reopens a closed pane from its description, in the same place, with the same applet type. Amended
2026-11-01; see Decision Log.

- Closing a pane closes its applet. Its description stays on a per-window undo stack of the last N closes. uniterm
  keeps no closed applet alive.
- The applet contract defines the lifecycle events: start, detach, reattach, and close. uniterm sends them, and each
  applet owns its response, per ADR-05. An applet that wants undo to bring back more saves it in its description.
- A description is inert state, never a launch recipe. A terminal in shell mode relaunches a fresh shell in each tab's
  working directory. A terminal in program mode reopens showing its command and a Run action. It does not run the
  command until the user asks.
- The undo stack belongs to its window and closes with it. Closing the last pane closes the window. Undoing a closed
  window is out of scope.

Rationale: undo restores the layout and each tab's working directory, which is what an accidental close loses most
often. It is not a snapshot of running processes. Keeping closed applets alive would make the host keep every applet's
hidden work quiet and bounded, which only the applet can do correctly. Persistence (M8) reuses the same description, so
this is not built for undo alone. An inert description keeps undo, and later relaunch, from
running `./deploy.sh` or a migration a second time.

### How to get libghostty

Original question: use a community prebuilt package, vendor Ghostty and build the xcframework from source, or wait for
the first-party Swift package?

Decision: build in-tree from pinned source, with a kept dependency cache.

- The repo pins Ghostty by commit hash, and by a hash over the extracted source tree. The build fails when the tree does
  not match, so a regenerated tarball cannot change the source unnoticed.
- `make build` builds GhosttyKit.xcframework and Ghostty's terminfo and shell-integration resources. It links the
  xcframework as a local SwiftPM binary target.
- The built artifact lives in a git-ignored cache. The cache key is the Ghostty commit, the Zig version, and the Xcode
  and SDK versions.
- A manifest in the artifact records the same values. The build fails when the manifest disagrees with the pin or the
  toolchain.
- The script fetches Ghostty's Zig dependencies into a cache that uniterm keeps. It does not rely on Zig's global
  cache. A cold rebuild of the current pin then works without the upstream URLs.
- The resources ship inside the `.app`, where libghostty finds them.
- No patch mechanism exists until the first patch does.
- Zig 0.15 cannot link against the macOS 26 SDK, whose libSystem stub lists only arm64e. The build runs Zig against the
  macOS 15.4 SDK from the Command Line Tools. The pin records it as `ZIG_SDK_VERSION`. Xcode's own tools keep the
  current SDK.
- Xcode 26's libtool silently drops the archive members that Zig writes. The build combines the loose objects instead.
  Both workarounds live in the build script, not in Ghostty's source.

Zig, the Command Line Tools with the macOS 15 SDK, Xcode 26, and its Metal toolchain are needed only on a machine with a
cold cache: the first build, and every upgrade. Amended 2026-10-31; see Decision Log.

Rationale: every byte traces to a pinned commit. It is the same GhosttyKit path that Ghostty's own app uses. It ships
terminfo and shell integration, which TERM, OSC 7 working directories, and UTERM-012's OSC 133 blocks need. A pin cannot
stop resolving later.

- `loeschg/GhosttyKit` ships a binary that cannot be traced to its source, into the process that sees every keystroke.
  It also ships no resources.
- `rijieli/libghostty-spm` has withdrawn 15 tags, so an exact pin can stop resolving.
- Hosting a prebuilt artifact needs a repository host, storage, credentials, and CI. The project has none of these, and
  no one else would consume the artifact.
- The first-party package has no ship date. It targets libghostty-vt plus a Swift renderer, a different API layer.

The fallback in every case is SwiftTerm, behind the same internal protocol.

### Pane tree shape

Original question: binary tree, where each split node has two children and one ratio, or N-ary tree, where each split
node has many children along one axis with a ratio per child?

Decision: a normalized N-ary tree with stable node IDs.

- A split node has two or more children along one axis. Each child has a weight.
- Splitting a pane along its parent's axis inserts a sibling. Any number of rows or columns is one node.
- A split node left with one child collapses into its parent. A child with the same axis as its parent merges into the
  parent.
- A divider drag moves space between the two adjacent children only. Closing a pane gives its space to its adjacent
  siblings.
- Every node has a stable ID. A node that survives a split, merge, or collapse keeps its ID. A node that is removed,
  such as a split that collapses, has its ID retired and never reused. A pane's ID never changes while the pane
  exists. A pane reopened by undo gets a new ID. Amended 2026-11-01; see Decision Log. Nothing may address a node by
  its path in the tree, since normalization rewrites paths.
- Merge and collapse rules belong to the node kind. This proposal has two kinds, split and pane, and both normalize. A
  later kind may define its own rule.

Rationale: in a binary tree, `[[A | B] | C]` and `[A | [B | C]]` look the same. Closing B gives all its space to A in
the first and to C in the second. The user cannot predict which. An unnormalized N-ary tree has the same flaw after
closes, since leftover nesting changes how a divider drag spreads space. Normalization makes behavior depend on what the
user sees, not on split history. Stable IDs are needed now by undo (M7) and persistence (M8).

Dissent left standing: the critic ranked a variant that also builds UTERM-004's owner-tagged group kind now. That is a
scope addition with no caller in this proposal. The per-kind rule above leaves room for it.

### Naming

Original question: "pane", "applet", and "region" are working names. Better names may still be found.

Decision: keep pane, applet, and region. The rest of the vocabulary is:

- **Split**: a node in the pane tree that holds two or more children along one axis
- **Tab**: one of an applet's switchable sessions, such as a terminal tty
- **Segment**: one slot of the status bar
- **Message**: one posted status bar entry

UTERM-004 names its own grouping concept.

Rationale: none of these names clash with Swift, AppKit, SwiftUI, or libghostty types. "Area" means width times height
in layout code. "Tool" overlaps with the toolbar and with script commands. "App" shadows SwiftUI's `App` protocol.

### Status message model

Original questions: whether messages carry a priority, a level, or both; how long a message stays; who owns a segment.

Decision:

- A message carries a level: info, warning, or error. The level sets its style. There is no priority.
- A message records its source: a pane, an applet, a script, or uniterm itself. The bar and the history show it.
- Each message shows for at least a minimum dwell time, then the next queued one replaces it.
- When the backlog grows, the bar skips to the newest message. Skipped messages stay in history.
- Errors are never skipped. A backlog of errors collapses to the newest error plus a count.
- An error stays until a newer message replaces it or the user dismisses it.
- A window segment shows an unseen-error indicator until the user opens the history.
- The window owns its segments, such as the message area. The focused pane's applet fills a set of applet segments,
  such as mode or line:col. They change when focus changes.

Superseded in part by UTERM-017; see Decision Log.

Rationale: a plain FIFO cannot show the write-up's "mode", "line:col", or "ok/error". It also falls minutes behind
when an exec pane floods stderr. A priority field would be set to the maximum by every untrusted poster, so it buys
nothing over the level. Segments claimed by unfocused applets overflow a one-line bar and show line:col for a pane
that does not have focus. Recording the source keeps an untrusted program from posting text that passes for uniterm's
own, and tells the user which pane failed.

### Where settings live

Original question: settings already exist, such as the status bar dock position, the appearance setting, and later
UTERM-002's palette mode and position. Where are they stored, how does the user change them, and how do they relate to
the layout file?

Decision: UserDefaults, changed in a Settings window.

- Global settings live in the app's UserDefaults domain.
- A standard Settings window opens with Cmd-,. It is an AppKit window. SwiftUI forms may sit inside it as leaf views.
- The status bar dock position is one global setting. Changing it moves the status bar in every open window at once.
- A value written from outside, such as with `defaults write`, applies live. An invalid value falls back to the default
  and posts a warning to the status bar.
- Settings never live in the layout file.

Rationale: UserDefaults is the macOS convention, with typed values, atomic writes, and one writer. A text config file
needs a parser that keeps the user's comments when the app rewrites it. It also has two writers, the app and the
user's editor. A shared settings-and-layout file would lose every setting whenever layout recovery resets the file. A
per-window dock position makes the Settings value a default for new windows only, so changing it would appear to do
nothing. No one has asked for per-window docking.

Leaves undone: settings are not a commented dotfile to keep in version control. Moving them to another machine means
`defaults export` and `defaults import`.

### Whether uniterm reads the user's Ghostty config

Original question: if the terminal surface loads `~/.config/ghostty`, its `theme` and `palette` lines override
uniterm's tokens. Its font and keybinding lines would also apply. Should uniterm read it?

Decision: read none. uniterm builds the libghostty config entirely from its own settings and tokens.

- The user's Ghostty files have no effect.
- uniterm clears Ghostty's built-in keybindings. Ghostty binds Cmd-Z, Cmd-W, Cmd-T, Cmd-D, and Cmd-Q by default, even
  with no file loaded. Left in place, they would catch uniterm's undo and close before uniterm sees them.
- uniterm owns every key binding. Terminal-local actions, such as copy, paste, select all, font zoom, and clear screen,
  are uniterm bindings that call into the surface through the terminal surface protocol.
- libghostty loads config only from a file. uniterm writes a generated file, private to the user, in its own directory.
  It escapes or rejects every value it writes.

Rationale: under this option every settled decision holds by construction. Reading Ghostty's file, or a uniterm-owned
file in Ghostty syntax, lets keys such as `term`, `shell-integration`, `command`, and `working-directory` break M2's
checks, OSC 7 and OSC 133, and the inert undo description. A deny list can never be complete across Ghostty versions.
Sharing Ghostty.app's file is also a contract between two apps that upgrade on their own schedules.

Leaves undone: Ghostty options that uniterm does not expose are out of reach. Fonts use libghostty's defaults. A font
or option such as `macos-option-as-alt` becomes a uniterm setting when a user asks for it.

Dissent left standing: the critic suggested exposing font family and size as settings now. That is a scope addition
with no stated need. Font zoom covers size within a session.

### What layout persistence restores, and in what format

Original questions: what is restored, given that windows, frames, the pane tree, applet types, and region docking are
the minimum, with terminal working directories, tab titles, and scrollback as candidates; the file format and its
location; and how it is versioned.

Decision: a uniterm-owned JSON file that holds descriptions only.

- **What is restored**: every window's frame and screen, its pane tree with stable node IDs, axes, and weights, each
  pane's applet type, and that applet's restorable description. The terminal's description already carries each tab's
  working directory.
- **What is not restored**: region docking, which is a global setting. Tab titles, since a fresh shell resets them.
  Scrollback. The undo stack. Amended 2026-11-01; see Decision Log.
- **Location and writes**: one file in `~/Library/Application Support/uniterm/`. It is written atomically, as a temp
  file then a rename, and is never readable by other users. It is saved after a short debounce on every layout change,
  and synchronously on quit.
- **Versioning**: a top-level integer schema version. Each applet description carries its own per-applet-type
  version. A reader upgrades older schema versions step by step. A new node kind bumps the schema version.
- **Recovery**: a newer or unreadable schema moves the file aside and starts a default layout. A single description
  that is unknown, corrupt, or newer becomes a placeholder pane that keeps its raw description and writes it back
  unchanged.
- **Restore policy**: launch restores the saved layout every time. It does not follow the macOS "Close windows when
  quitting an application" setting.
- **Crash-loop guard**: a launch marker is set before restore and cleared once launch succeeds. After a bounded number
  of crashed launches in a row, the file is moved aside and a default layout starts.
- **Single writer**: only one running instance writes the file. A second instance never overwrites the first one's
  layout.

Version skew: the file is stored data shared by versions of the one app.

- Old file, new app: the step-by-step upgrade reads it.
- New file, old app: the old app moves the file aside and starts a default layout. A later upgrade reads the
  downgraded layout, not the kept-aside file. Left undone: a downgrade-then-upgrade round trip loses the newer layout.
  This is accepted. The kept-aside file stays on disk for manual recovery.

Rationale: the file meets the settled mitigation of a version field and a kept-aside file. AppKit state restoration
cannot keep a file aside, silently discards an archive that fails to decode, and follows a system setting that may
restore nothing after Cmd-Q. Saving on quit only loses the layout on a crash or force quit, the moment users most want
it back. A property list is as correct, but harder to read and diff. Scrollback is a scope addition. It would write
terminal output, which often holds secrets, to disk. Replaying it would also open an escape-sequence injection path.

### Guarding a close that would kill running processes

Original question: closing the last pane closes the window, and undoing a closed window is out of scope. So a
single-pane window running vim with an unsaved buffer dies on Cmd-W, with no undo. M7 also mentions a running-process
check on quit that no decision defines.

Decision: confirm wherever undo cannot restore the session. Amended 2026-10-31; see Decision Log.

- Closing a window, including by closing its last pane, asks first when an affected terminal tab is running something.
- Quitting asks under the same rule, across every window.
- Closing a single terminal tab asks when that tab is running something. Tab closes are not undoable.
- Closing a pane asks when any of its tabs is running something, since undo reopens a fresh session. An idle pane
  closes without asking, since undo restores everything it held. Amended 2026-11-01; see Decision Log.
- Closing an applet's last tab is a pane close, and follows the pane rule.
- "Running something" is libghostty's `needs_confirm_quit`, reached through the terminal surface protocol. It is true
  unless the cursor sits at an idle shell prompt, which shell integration marks with OSC 133.
- The dialog lists the affected panes and tabs, by title, and by command for program mode.

Rationale: the guard sits on every close that destroys a running session with no exact undo available, and nowhere
else. Asking on every close makes the user confirm a reversible action and trains them to dismiss the dialog. Leaving
an empty window after the last pane breaks the convention that Terminal, Ghostty, and iTerm2 share, and adds a
zero-pane tree state.
Keeping closed windows alive narrows the out-of-scope statement on window undo, and a hidden window has no visible
indicator.

Leaves undone: a background job started with `&` at an idle prompt reports nothing, so it is hung up without a dialog.
Ghostty behaves the same. A prompt without OSC 133 marks, such as a remote shell over ssh, always asks. That fails
safe.

### Scope

In scope:

- Multiple windows
- Terminal tabs
- Undo for closing a pane
- Layout persistence across launches

Out of scope, for later proposals:

- The command palette
- The widget bar
- Janet scripting and the REPL applet
- Remote control and trust between panes (CONTROL-1, CONTROL-2, CONTROL-3)
- Shell blocks in the terminal
- Applets other than the terminal

## Design Decisions (Open)

## Risks

- **libghostty's API changes between releases** — likelihood: high, impact: medium.
  Mitigation: pin an exact Ghostty commit. Keep every libghostty call behind the internal terminal surface protocol,
  which sits at the session level. That keeps a SwiftTerm fallback possible if an upgrade becomes too costly. No
  milestone builds or tests the fallback.
- **The embedder API is Ghostty's internal one and may be withdrawn or restricted** — likelihood: low, impact: high.
  `ghostty.h` calls itself built for Ghostty's own macOS app, and points external embedders to libghostty-vt.
  Mitigation: the session-level protocol lets SwiftTerm, or the first-party package once it ships, replace libghostty
  in one module. Ghostty's own app depends on the same API, which makes sudden removal unlikely.
- **An Xcode update leaves the pinned Ghostty commit unbuildable** — likelihood: medium, impact: medium.
  Zig and new Apple SDKs have broken each other before, and the build refuses an artifact made with another Xcode.
  Mitigation: the repo records the Xcode version the pin was built with. `make build` names that version when the
  toolchain differs. Xcode upgrades go with a deliberate Ghostty pin bump, not an App Store update.
- **`TERM=xterm-ghostty` breaks programs on ssh hosts that lack its terminfo** — likelihood: high, impact: medium.
  Mitigation: the generated Ghostty config enables shell integration's `ssh-env` feature. It sets a fallback TERM for
  ssh sessions started from a shell. Program mode bypasses the shell wrapper, so a program-mode `ssh` needs its own
  fallback. M2 and M5 check both.
- **The applet contract becomes the base for every later applet** — likelihood: medium, impact: high.
  Mitigation: the contract is internal, not published. Exercise it with the terminal in M2 and M5 before other applets
  build on it. Expect to revise it when the second applet arrives.
- **The persisted layout format is a stored format that later versions must read** — likelihood: high, impact: medium.
  Mitigation: give the file a version field from the first release. Upgrade older versions step by step. On a version
  it cannot read, or after repeated crashed launches, uniterm starts with a default layout and keeps the old file
  aside. Accepted: a downgrade-then-upgrade round trip loses the newer layout. The kept-aside file stays for manual
  recovery.
- **Undo reopens a fresh session, so a confirmed close loses unsaved work** — likelihood: medium, impact: medium.
  Mitigation: closing a pane that is running something asks first and names its tabs. Amended 2026-11-01; see Decision
  Log.
- **The layout file stores working directories and program-mode commands** — likelihood: medium, impact: low.
  A command line can carry a secret, such as `mysql -pSECRET`. The file also reaches Time Machine backups.
  Accepted: the file is never readable by other users. The exposure matches the shell's own history file.
- **Full-size content conflicts with title bar dragging and the traffic lights** — likelihood: medium, impact: low.
  Mitigation: M1 checks that the window drags, and that the traffic lights stay clickable and unobscured.
- **The proposal is large and may stall before a usable app exists** — likelihood: medium, impact: medium.
  Mitigation: the milestones are ordered so a usable single-window terminal lands by M2. Later milestones can move to a
  new proposal if this one stalls.

## Milestones

### M1: App skeleton and theme tokens

**Status:** DONE

- `make build` produces a `.app` bundle that launches on macOS 26
- The app opens one window with a full-size content view and working traffic lights
- The window drags by its top edge, and content does not cover the traffic lights
- Catppuccin Latte and the dark theme are defined as named color tokens in one place
- `make test` runs and passes
- The Ghostty build fails unless the Zig version matches the pinned version exactly
- The libghostty manifest records the Xcode and SDK versions, and the build fails when they differ
- An interrupted or concurrent Ghostty build never leaves a partial artifact under a valid cache key
- A cold rebuild of the pinned Ghostty commit succeeds with the network off, using the kept dependency cache
- On a cold checkout, the xcframework path is a fixed location that `make build` fills. Opening the project before
  that shows an error that names `make build`
- A rebuilt GhosttyKit artifact is picked up without a manual cache clear
- `make test` runs both `swift test` and `xcodebuild test`. Without a GUI session or Accessibility permission, it
  reports that instead of hanging
- The package and the app target use the same Swift language mode
- Changing the appearance setting or the system appearance updates window chrome without a relaunch
- Cmd-, opens an AppKit Settings window that changes the appearance setting

**As built:**

- Pinned Ghostty v1.3.1, commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`, built with Zig 0.15.2, Xcode 26.6
  (17F113), and SDK 26.5. The v1.3.0 fallback was not needed. The build needed two workarounds and the Metal toolchain
  component. See the 2026-10-31 Decision Log entry on the libghostty build.
- `make ghostty-offline-check` sets the artifact aside and rebuilds it with the network off, from the kept source and
  the kept Zig package cache. A control run first shows that Zig cannot fetch a package through the dead proxy. The
  check only renames the original artifact and restores it on failure or SIGINT. `make ci` runs it.
- The build lock is a kernel `flock`, so a killed build leaves no stale lock. A `kill -9` in the middle of a build left
  nothing under the artifact key and one leftover work directory, which the next build removed. A SIGINT in the middle
  of the offline check restored the original artifact. Bad Zig and Xcode pins fail with a message.
- A rebuilt artifact is picked up with no cache clear. Rebuilding changed the library bytes, and the next `make build`
  reprocessed the xcframework and relinked the app without touching DerivedData.
- The tarball from codeload hashed the same on two downloads, but nothing guarantees it. The pin holds a tree hash
  instead, and the build fails on a mismatch. The libtool workaround fails when an archive has repeated member names.
- Xcode ignores hardened runtime for ad hoc signing, so the dev build runs without it. The setting is on for a real
  signing identity.
- The app builds against a static `libghostty` through the terminal surface module. The app logs the linked version at
  launch. The module declares the C++ runtime and the system frameworks the static library needs, since a binary
  target carries no link settings.
- The Settings window uses AppKit controls only. No SwiftUI is used yet.
- The UI tests read a throwaway plist inside the runner's container, so they never write the developer's preferences.
  An out-of-process `defaults write` cannot be proven by a UI test. The sandboxed runner's write never reaches the
  unsandboxed app as a change notification, and the runner cannot write the app's real domain. A write from a separate
  process is proven in `swift test`, against the settings store. The window's reaction to a `defaults write` was checked
  by hand on a launched binary. That reaction is the one gap in automated coverage.
- The UI tests ran in a background session on the developer's machine, and `make test` passed there. The report for a
  missing GUI session or missing Accessibility permission was not exercised.
- Left to the user: a live change of the system appearance with the setting on System, and opening the project in the
  Xcode UI on a cold checkout. The cold-checkout error was seen from `xcodebuild`, not from the Xcode UI.

### M2: Terminal applet in a single pane

**Status:** DONE

- The window's content area hosts one pane running the terminal applet
- The terminal starts the user's default login shell and accepts keyboard input
- The terminal resizes with the window, and the shell sees the new size
- No libghostty type is visible outside the terminal surface module. The module uses `internal import GhosttyKit`, and
  `make build` fails when another module imports GhosttyKit
- Ghostty's terminfo and shell-integration resources sit under `Contents/Resources`, where libghostty finds them
- Changing the appearance updates the palette of every running terminal surface
- With the terminal focused, Cmd-Z, Cmd-W, Cmd-T, Cmd-D, and Cmd-Q reach uniterm, not Ghostty's built-in bindings
- Copy, paste, select all, font zoom, and clear screen work in the terminal through uniterm's bindings
- A setting value that contains a newline or other unsafe character cannot add lines to the generated Ghostty config
- The generated Ghostty config is written atomically and is separate for each running instance
- An OSC 52 clipboard read is never answered without the user's confirmation
- An OSC 9 or OSC 777 notification posts to the status bar, with the pane as its source
- App Sandbox is off, and the shell can read and write `$HOME`
- The terminal surface protocol carries the running-state query, terminal actions, live palette updates, focus, and
  the hosted view, with no libghostty type
- Through the terminal surface protocol, "running something" is false at an idle prompt and true while vim runs
- The generated Ghostty config never sets `confirm-close-surface` to false
- An ssh session to a host without the `xterm-ghostty` terminfo entry gets a working fallback TERM
- `make build` names the recorded Xcode version when the installed one differs
- When the shell exits, the pane closes
- In the launched app, `$TERM` is `xterm-ghostty`, and `infocmp` finds it in the bundled terminfo
- Shell integration emits OSC 7 working directories and OSC 133 command-finished marks through the terminal surface
  protocol. The running-state query follows the OSC 133 prompt marks. libghostty passes no other prompt mark to its
  embedder. Amended 2026-11-01; see Decision Log.
- The app carries the license notices for Ghostty and the libraries it bundles

**As built:**

- The terminal sits behind a session-level protocol with a libghostty engine. No libghostty type is public, and the
  build fails when any other module reaches GhosttyKit. Leaking an import into another module, and re-exporting it from
  the terminal module, each made the check fail.
- uniterm reads no Ghostty config file. It writes its own config to a per-instance file in a private folder, by temp
  file and rename. The config comes from an allow list of keys. A value outside a small safe alphabet is rejected, not
  escaped. The close guard setting accepts only `true`.
- libghostty's built-in bindings are cleared. A test asks libghostty about Cmd-Z, Cmd-W, Cmd-T, Cmd-D, and Cmd-Q and
  gets no. With the clear removed, that test failed. uniterm's menu owns the keys, and the focused terminal answers Copy,
  Paste, Select All, font zoom, and Clear Screen on the responder chain. A test drives that path in-process.
- A palette change reaches every running surface. A test fails when the update call is removed. libghostty has no call
  to read a surface's colors, so the color on screen is a check for the user.
- Resources and licenses ship in the app bundle. In the launched app the shell reports `TERM=xterm-ghostty`, and
  `infocmp` finds the bundled entry. The notices cover Ghostty, its fonts, the libraries its build fetched, and
  Catppuccin. Three libraries ship no license file and are named in the notices.
- `make build` names the recorded Xcode version when another is installed. M1's toolchain check does it, and it was not
  run against a different Xcode here.
- The App Sandbox is off, checked in the project and on the built app. A spawned shell writes and reads a file in
  `$HOME`.
- ssh: the config enables `ssh-env`. In an integrated zsh, a program that ssh starts sees `TERM=xterm-256color` while
  the shell has `xterm-ghostty`. The probe used ssh's ProxyCommand, so no remote host was used.
- Status message bounds: minimum dwell 1.5 s, info and warning clear to idle after 5 s once the queue is empty, a backlog
  above 3 skips to the newest, history holds 500, and errors fold into the newest error with a count. Warnings follow the
  info rules. The window shows the current message in a 22 pt strip until M4 replaces it.
- OSC 9 and OSC 777 post as info with the pane as source. Notification text drops control characters and is capped at 200
  characters. libghostty allows one notification per second.
- An OSC 52 read and an unsafe paste each ask the user in an alert that names the pane, with Cancel as the default. An
  OSC 52 write is allowed without asking. A denied request still completes with empty data, since libghostty keeps the
  request until the embedder answers. A test shows the program receives nothing before the answer and nothing after a
  denial. Amended 2026-11-01; see Decision Log.
- The applet description is versioned and wrapped so an unreadable one can be kept and written back. Shell mode restores
  a fresh shell in the tab's directory. A program-mode description is refused until M5.
- `send(text:)` pastes, so a shell with bracketed paste does not run a pasted newline. Tests press Return through the
  hosted view.
- Tests that spawn a shell isolate it from the developer's dotfiles with a fixture `ZDOTDIR`, an empty
  `SSH_AUTH_SOCK`, and no `SSH_ASKPASS`. `ZDOTDIR` must be in the process environment, since a launch variable overrides
  the integration's own and the shell then never reports a prompt. `login(1)` resets `HOME`, so `HOME` does not isolate.
  Every UI test launches the app the same way, through one helper. Production starts the user's real login shell.
- A trace of closing a session whose shell ignores SIGHUP found no main-thread hang. libghostty tracks `login(1)`, which
  exits on SIGHUP, so the close returns at once. The shell and its children survive, as `nohup` work does. A test guards
  the close time.
- Not built: the close guard, which M7 owns, so Cmd-W and Cmd-Q close without asking even with vim running. Also not
  built: opening links, the scrollbar, and the selection clipboard.
- A shell that exits within 250 ms of launch leaves libghostty's error screen in the pane, waiting for a key.
- The UI suite passed in one run on a quiet desktop, 11 tests with no failure, after the shared launch helper landed.
  Earlier runs each failed one different test with "Failed to activate application" or a snapshot timeout. The cause was
  never isolated. The shared helper ends the app after each test and activates it before typing.
- XCUITest delivered `'` with the Control flag on the US Extended layout, so UI tests type no apostrophes. A test drives
  the apostrophe key through the real key path, and the user confirmed that a real keyboard types `'` and `"`.
- Left to the user: one real ssh session to a host without the `xterm-ghostty` terminfo entry, a live system appearance
  change reaching the terminal palette, and the on-screen colors after a palette change.

### M3: Pane tree

**Status:** DONE

- A pane splits horizontally and vertically, and splits nest
- Dragging a divider resizes the panes on either side
- A split that would push a pane below its minimum size is refused
- Keyboard focus moves between panes, and the focused pane is visible
- Opening a new pane asks which applet to start, and offers program mode with a command
- Closing a pane closes its applet and gives its space to its neighbors
- When a split merges into its parent, each child's weight is scaled by the merged split's weight, so no pane changes
  size. A divider takes room, so a pane merged from a split of m children can shift by less than (m - 1) divider
  thicknesses. Amended 2026-11-01; see Decision Log.
- The window's minimum size follows from the tree, so shrinking the window never pushes a pane below its minimum

**As built:**

- The pane tree is a pure model with no AppKit. Its weights sum to 1 in every split. A split lays its children along a
  row or a column. The menu calls the two splits Split Right and Split Down.
- A pane is at least 200 points wide and 100 points high. A divider is 5 points thick. A split is refused when either
  of its two panes would end up below that size at the sizes the weights give. It is also refused when the new tree's
  minimum size does not fit the current size, since the new divider shifts every sibling and the layout would then
  squeeze the two panes. A refusal changes nothing, uses no ID, and posts a warning to the status bar.
- Closing a pane gives half of its weight to the sibling on each side. A pane with one neighbor gives all of it to that
  neighbor. Focus moves to the neighbor nearest the closed pane. A divider drag stops where either side would drop below
  its subtree's minimum. Every expected value in the model tests was worked out by hand. Each mutation of the model
  that was tried made a named test fail.
- A merge scales the merged children's weights, so each pane keeps its share. A divider takes room that weights do not
  count, so with divider thickness a merged pane moves. A child of weight c in a merged split of m children and weight
  w shifts by c * (m - 1) * (1 - w) divider thicknesses, which is under (m - 1). A test checks the formula's values
  with a thickness of 10. The other merge tests use zero thickness to show exact sizes.
- A new pane takes a fresh ID. A split that is created for it takes the next one. IDs rise by one, a refused split
  burns none, and the model starts from a saved high-water mark when one is given. The persisted form is M8's.
- The window's minimum content size is the tree's minimum plus the title bar and the status strip. It has no fixed
  floor, so a single pane's window can shrink to 200 points wide. It grows and shrinks as panes come and go. A split
  is only allowed when the new tree's minimum fits the current size, so a split never forces the window to grow.
- Dividers drag with the mouse and show a resize cursor. The pane views are laid out from the model's frames, rounded
  to whole points. The focused pane shows a 2 point ring when the window has more than one pane. A click inside a pane
  moves the mark, since the mark follows the window's first responder.
- Key bindings, all in uniterm's menu: Cmd-D splits right, Cmd-Shift-D splits down, Cmd-W closes the focused pane,
  Cmd-] and Cmd-[ focus the next and previous pane in reading order, and Cmd-Option with an arrow key focuses the
  nearest pane in that direction. Ghostty and iTerm2 use the same keys. Terminal has no splits.
- Every split asks which applet to start, in a sheet. The default is the terminal in shell mode, so Cmd-D then Return
  opens a shell. The sheet also offers program mode with a command field, and Open waits for a command. Program mode
  does not start yet, since the terminal applet has no program launch. Choosing it opens no pane and posts an error to
  the status bar. M5 owns the launch.
- A shell that exits closes its own pane, and the last pane closes the window as before. Focus moves to a neighbor
  only when the closed pane had it, so an exit in a background pane never takes the keyboard. Closing a pane asks
  nothing, since M7 owns the close guard.
- While a sheet is up, such as the picker or a clipboard question, every pane action is disabled: split, close, and the
  focus moves. Cmd-W does not cancel the picker. Escape does.
- The UI suite passes, 21 tests with no failure. It covers splits, focus, dividers, close, the window minimum, a refused
  split, and the picker. Its first run failed 3 tests that waited on a pane ID the allocator never issues. The tests now
  wait on the pane count and order. The look of the focus ring and dividers on screen, the resize cursor, and a real
  mouse drag of a divider are checks for the user.

### M4: Status bar region

**Status:** DONE

- Each window has a status bar that docks at the top or the bottom
- Changing the dock position does not change what the status bar shows
- A top-docked status bar does not sit under the traffic lights or break dragging by the top edge
- A fallback for an unknown stored setting value is never written back over that value
- An invalid dock position written with `defaults write` falls back to the default and posts a warning
- An applet can post a message to its window's status bar, and messages queue
- The status bar shows segments with an icon or one line of styled text
- The status bar opens a history panel of messages that floats over the content area. Amended 2026-11-01; see Decision
  Log.
- An error is still shown after a burst of info messages arrives within its dwell time
- Info messages clear back to idle after a timeout once the queue drains
- The history is capped, and the oldest entries drop first
- Applet segments keep the last focused pane's content while focus is in another region
- Messages still queued from a closed pane leave the bar but stay in history

**As built:**

- A region has a fixed role and a separate dock edge. Docked regions stack inward from their edge, and the pane area
  fills what is left. A later region joins without a change to the status bar or the pane area.
- The status bar docks at the bottom by default. One global setting moves it to the top in every window, live, with a
  row in the Settings window. A move keeps the same bar and the same segments. A top-docked bar starts below the title
  bar, clear of the traffic lights, and the title bar still drags the window.
- The bar shows the message area, a dismiss control while an error is showing, the unseen-error indicator when an error
  is unseen, and the focused pane's applet segments, in that order. The leaf views are AppKit, with no SwiftUI.
- Applet segments follow pane focus. They keep the last focused pane's content while the keyboard is in Settings or a
  sheet.
- The terminal applet fills two segments: its working directory and the exit code of a failed command.
- Clicking the bar, or a menu item with Cmd-Shift-M, opens the history. It lists up to the 500 messages the model keeps,
  newest first, with level, source, and text. Opening it clears the unseen-error indicator. The panel floats over the
  pane area. See the 2026-11-01 Decision Log entries on M4.
- An error is dismissed by the menu item with Cmd-Option-Delete, or by a click on the dismiss control. Other messages
  clear themselves.
- A pane close drops that pane's queued messages from the bar and keeps them in history. Errors from other panes that
  were folded into a dropped error are queued again.
- An unknown stored dock value falls back to the bottom and is never written back. The window posts one warning for each
  new bad value.
- The dwell, the idle timeout, and the history cap are M2's, with M2's tests.
- The UI suite passes, 26 tests with no failure. Its first run failed the unseen-error test, whose query expected an
  image. The indicator is exposed as a plain element, and the test now matches any element type. The look of the bar at
  each edge and the history panel are checks for the user in M9.

### M5: Terminal tabs and program mode

**Status:** DONE

- A terminal applet in shell mode opens, switches, and closes tabs
- Each tab runs an independent tty
- The tab bar is hidden when the applet has one tab
- A terminal applet in program mode runs a given executable in one tab, with no new-tab action
- Closing a pane closes every tab in its applet
- Cmd-W in an applet with several tabs closes the current tab only
- Closing a tab that is running something asks first. Closing a tab at an idle prompt does not ask
- Closing an applet's last tab follows the pane rule: no dialog in a window that stays open. The dialog for a close that
  would close the window is M7's. Amended 2026-11-01; see Decision Log.
- A program-mode `ssh`, by name or full path, to a host without the `xterm-ghostty` terminfo entry gets a working
  TERM. Other routes, such as `mosh` or a wrapper script, are not covered

**As built:**

- Shell mode holds any number of tabs, each its own session and so its own tty. A new tab opens right after the
  selected one, in the directory that tab last reported. The tab bar is 28 points tall and shows only with two or more
  tabs. The terminal fills what the bar leaves.
- Keys are menu items: Cmd-T, Cmd-1 to Cmd-8, Cmd-9 for the last tab, and Cmd-Shift-] and Cmd-Shift-[ to step with wrap.
  The switching items are disabled with one tab. New Tab is disabled when the focused applet cannot open one.
- Cmd-W closes the selected tab while the applet has two or more. The menu item reads Close Tab then. With one tab it
  closes the pane, and closing a pane closes every tab. A shell that exits closes its own tab. The last one closes the
  pane.
- A tab running something asks first, naming the tab by its title, or by its command in program mode. An idle tab
  closes at once. Declining keeps the tab. The applet never closes its last tab, since that is a pane close.
- The applet's running-state query is true when any tab is running something, and it lists those tabs' labels. M7 uses
  both. The window, quit, and grace-slot guards are not built here.
- Program mode runs one program in one tab and opens no other. Its command line is split into words, and the shell
  never interprets the user's text. The picker's command now launches for real. A line with unquoted shell syntax, an unclosed quote, a second
  line, a NUL, or no program is refused with a message before anything starts. libghostty runs a command through
  `/bin/sh -c`, so every word is single-quoted on the way in, and a test reads the quoted string back through a real sh.
  libghostty keeps the pane open after the program ends until a key is pressed.
- A program whose basename is exactly `ssh` gets `TERM=xterm-256color`, by name or by path. The check used ssh's
  ProxyCommand with `-F /dev/null`, so no remote host was used. `mosh`, wrappers, and names that only contain ssh are
  not covered.
- The description carries each tab's directory and the selected tab, plus the mode and command. It is inert. A shell
  description restores a fresh shell in each tab's directory. A program-mode description is still refused on restore.
- Status segments follow the selected tab. A background tab's title and exit-code events leave the host and segments
  alone. Its directory change tells the host, so the layout saves, and leaves the segments alone. Its notifications and
  clipboard requests still post and ask the user. A tab's title shows in its tab and the applet title follows the
  selected tab. Amended 2026-11-01; see Decision Log.
- Mutation checks each failed the named tests, and each was undone: the ssh name match, Cmd-W taking a tab before a
  pane, closing the selected tab and not another, the guard asking only for a running tab, both ways, the bar hidden at
  one tab, program mode refusing a new tab, the description staying inert on restore, and "running" meaning any tab.
- Tests that start programs kill every process they started. A check after the package tests found none left.
- The UI suite passes, 31 tests with no failure, including the tab tests. Left to the user: how the tab bar looks, and
  one real ssh session to a host without the `xterm-ghostty` terminfo entry in program mode.

### M6: Multiple windows

**Status:** DONE

- The user can open more than one window
- Each window has its own pane tree and its own status bar
- A status message posted in one window does not appear in another
- Changing the dock position in Settings moves the status bar in every open window at once
- Appearance reaches every open window. Closing a window releases it and ends its sessions. Closing the last window
  leaves the app running, and Cmd-N or a Dock click opens a window again. Amended 2026-11-01; see Decision Log.

**As built:**

- File > New Window, with Cmd-N, opens another window. Each window has its own pane tree, status bar, and status center.
  A new window starts one step (28 points) right and down from the active window. It wraps to the top-left of the
  visible screen when that step would leave it. The first window is centered.
- The active window is the key window, else the main one, else the one opened last. Menu actions reach it through the
  responder chain. New Window goes to the app delegate, so it works with no window open. Settings stays one shared
  window.
- A message posted in one window shows in that window's bar and history only. Its unseen-error indicator stays in that
  window.
- The dock position and the appearance setting reach every open window, and a window opened later starts on the current
  values.
- Closing a window closes its applets, which ends their sessions, and releases its controller within one turn of the
  main actor. A window that had already closed leaves the open list at once. Window identifiers are `main-window` for
  the first and `main-window-N` for the Nth opened. A number is never reused.
- Closing the last window leaves the app running. A Dock click with no main window open, or Cmd-N, opens a new one. The
  close and quit guards are not built here. Those are M7's, and so a window with a running program still closes
  without asking.
- A window that fails to open posts an error in the active window. With no window open it shows an alert. A failed open
  uses no window number.
- An app-level error posted with no window open, such as a failed terminal color update, is held. The next window that
  opens shows it once.
- A Dock click opens a window when no main window is open. The Settings window does not count. The rule is unit-tested,
  and the real click is left to the user.
- Mutation checks each failed the named tests, and each was undone: a status center shared between windows, a pane tree
  shared between windows, a dock change that reaches only the first window, an appearance change that reaches only the
  first window, a window close that skips its applets, a closed controller kept alive, and a set that cannot open once
  empty. The last-window quit rule lives in the app delegate and is covered by the UI suite only.
- The package tests pass. The tests that start programs kill every process they started. A check after the package
  tests found none left. The existing UI tests that expected the app to end with its window now expect it to keep
  running. The UI suite passes, 37 tests with no failure. Left to the user: how stacked windows look as they cascade,
  and a real Dock click reopening a window.

### M7: Undo close pane

**Status:** DONE

Superseded in part by UTERM-014; see Decision Log.

The keep-alive checks below record what M7 built. M10 removes the keep-alive tier. Amended 2026-11-01; see Decision
Log.

- After closing a pane, undo reopens it in its former place in the tree
- The restored terminal behaves as the settled undo decision says
- Undo behaves as settled when the closed pane's neighbors have since changed
- Undo places the pane by a neighbor's stable ID, the axis, the side, and the weight. When that neighbor is gone, undo
  falls back to a defined placement
- The grace period shows in a window segment that stays visible during a message flood
- The grace segment offers an action that hangs up the hidden processes at once
- Cmd-Z in a focused editable text control undoes the edit, not a pane close
- A hidden pane whose processes all exit during the grace period drops to its description
- Closing the window or quitting during the grace period hangs up the hidden processes. Quit counts them in its
  running-process check
- Closing a window that has a hidden pane running something asks first
- Closing a window or quitting with vim running in any tab asks first, and the dialog names the affected tabs
- Closing a pane in a window that stays open asks only when no grace slot is free and the pane is running something
- When slots are full, an idle hidden pane drops to its description to free a slot before any dialog is shown
- A multi-tab pane counts as running something when any of its tabs is
- When the last visible pane closes and a hidden pane is running something, the window-close dialog appears. Cancel
  reattaches the hidden pane
- A pane reattached within the grace period keeps its ID. A pane reopened from its description gets a new ID
- The number of panes kept alive at once is bounded
- A pane that closed because its shell exited adds no keep-alive entry
- A shell relaunched from a description starts in its OSC 7 directory only when that path is absolute and still exists
  on this machine. Otherwise it starts in the tab's starting directory, then in the home directory. Amended 2026-11-01;
  see Decision Log.
- A program-mode pane restored from its description shows its command and a Run action, and runs nothing until asked

**As built:**

- Starting bounds are a 10 second grace period, 3 grace slots, and an undo stack 20 deep. They are a policy value the
  window takes at creation, with no setting. Undo, Cmd-Z, takes the newest close across both tiers. A pane still hidden
  returns as the same applet with the same node ID. A pane past its grace period reopens from its description with a new
  ID and a fresh session. Closes are ordered by a serial, not by the order they reached a tier. A pane that drops out
  of the hidden tier out of close order, through eviction, expiry, or an exit, still undoes in close order, and the
  stack trims the lowest serial. Amended 2026-11-01; see Decision Log.
- A description this build cannot restore, such as a newer version of a placeholder's bytes, reopens as a placeholder
  that keeps those bytes, the way a restored layout does. Its entry leaves the stack only once a pane opened. A pane
  that does not fit keeps its entry. Amended 2026-11-01; see Decision Log.
- A pane closes into a grace slot when one is free. With none free, an idle hidden pane drops to its description first.
  When every hidden pane is running something, a closing idle pane keeps only its description. A closing pane that is
  running something asks first, and declining keeps it open. A pane whose applet exited on its own is discarded, with no
  entry in either tier.
- A pane is placed by its recorded neighbor's stable ID, the axis, the side, and the weight. When that neighbor is gone,
  it goes on the recorded side of the root along the recorded axis, with an equal share when the weight does not fit.
  An undo that does not fit the window is refused with a status message, and the entry stays for a larger window.
- The window's grace segment shows the count and the seconds left, with a hang-up control beside it. Both belong to the
  window, not to the message queue, so a message flood does not displace them. Hang-up ends every hidden applet at once
  and keeps their descriptions on the stack. The deadline wakes at most once a second.
- A hidden pane whose applet exits drops to its description. Closing the window hangs up the hidden panes and drops the
  undo state. A quit hangs up the hidden panes of every window.
- Closing a window by its red button, by Cmd-W on the last pane, or quitting asks when any visible or hidden pane is
  running something. The dialog lists the running tabs by title, or by command in program mode, up to 8 and a count of
  the rest. Cancel is the default button. Cancelling a last-pane close reattaches the hidden panes that are running.
  A quit counts every window and asks once, and a second Cmd-Q while the question is open does not stack another.
- Cmd-Z goes to the window, which undoes the edit in a focused text control and undoes the pane close otherwise. The
  Edit menu item keeps the standard undo selector, so AppKit's own undo reaches the same place.
- A restored shell starts in the reported directory when it is an absolute path and still a directory here. Otherwise
  it starts in the tab's starting directory, then in the home directory. The description now carries each tab's starting
  directory, and an older description without it still reads.
- A program-mode description restores into a pane that shows the command and a Run button. It starts no session until
  Run is pressed. A stored command that does not parse, or is missing, is refused as corrupt.
- The pane tree parks the ID of every pane closed through it. Only a parked ID can be inserted again, and the window
  retires it when it discards the pane through expiry, hang-up, exit, eviction, or a close that keeps only the
  description. Insert refuses a retired ID, so a stale ID never reaches a different pane. A node that vanished in a
  collapse was never parked.
- The "local" in the OSC 7 check means an absolute path that exists on this machine, since the surface does not expose
  the OSC 7 host. Residual risk: a remote working directory that also exists locally is accepted. The shell then starts
  in the wrong directory, which is harmless.
- When the last visible pane's applet exited and the user cancels the close, the hidden running panes come back. If
  none fits, the dead pane stays so the window is not empty. It leaves when a hidden pane returns, for instance after
  the window grows and the user undoes. A pane that ends while a question is open waits for the answer. Cancel then
  discards it, or keeps it as the dead pane when it is the last one, with no second question. Confirming a pane-close
  question closes it as an exit would. Without that, the dead pane stayed. Amended 2026-11-01; see Decision Log.
- Mutation checks failed named tests and were undone: the grace slot bound off by one fails the slot and
  idle-eviction tests. The package tests pass, 299 run with 4 skipped, in 12.0 seconds. The UI suite passes, 39
  tests with no failure, in 301 seconds, including the undo and Cmd-Q tests. Left to the user: how the grace
  segment and the Run prompt look, and a real vim buffer surviving an undo.

### M8: Layout persistence

**Status:** DONE

- Quitting and relaunching restores every window's frame, pane tree, applet types, and applet descriptions
- The saved file carries a version field
- A saved file with an unreadable version leads to a default layout, and the old file is kept aside
- Layout restores after Cmd-Q whatever the macOS "Close windows when quitting" setting says
- A crash during restore, repeated past the bound, leads to a default layout with the old file kept aside
- A second running instance never overwrites the first instance's layout
- The saved file and every temp file are never readable by other users
- Changing the layout and quitting at once still restores the change
- A window whose saved screen is gone opens fully on a visible screen
- A corrupt or newer description becomes a placeholder pane, and its raw bytes are written back unchanged
- Restored node IDs never collide with IDs made after restore, and IDs retired before quit are never reissued
- Repeated keep-asides do not overwrite each other, and the number kept is bounded
- Relaunched shells follow M7's working-directory rule, and program-mode panes run nothing
- AppKit window restoration never opens a second copy of a restored window
- A saved layout with zero windows opens one default window
- A restored tree whose minimum size exceeds the visible screen still opens usable

**As built:**

- The file is `layout.json` in `~/Library/Application Support/uniterm/`. Its top level is the integer `version`, 1, and
  the windows. A window holds its frame, its screen's frame, its focused pane, its tree, and its own ID high-water
  mark. Each applet description inside carries its own type and version. The file, every temp file, and the folder are
  mode 0600, 0600, and 0700. A test clears the umask to prove it.
- Schema upgrades run one version at a time from a table of steps. The table is empty, since version 1 is the first.
  A file with no version, a non-integer version, or a version below 1 is unreadable. A version above 1 is newer. Both
  are moved aside, and a default layout starts with a warning in the first window.
- Starting bounds: 3 launches that began and never finished, a 1 second debounce, and 5 kept-aside files. They are
  policy values with no setting. The launch marker counts the launches that never finished. The fourth launch after
  three crashed ones moves the file aside. The marker is set after the file is read, so a launch that throws while
  reading it leaves none. A launch that opens no window clears it before the app quits. Neither counts as a crash.
  The marker clears one turn of the main loop after the windows are shown. Kept-aside files are numbered, so none
  replaces another, and the oldest are deleted past 5. Amended 2026-11-01; see Decision Log.
- The ID high-water mark is per window, since each window has its own tree. The undo stack is not saved. The IDs of
  closed panes stay below the window's mark, so a restored tree counts them as retired and never issues them again. A
  mark lower than the largest ID in the tree is raised to it. Amended 2026-11-01; see Decision Log.
- A description that is unknown, newer, or unreadable becomes a placeholder pane. The file bytes of every description
  are kept exactly, including key order, spacing, and numbers a double cannot hold, and a placeholder writes them
  back unchanged. A readable description that its applet refuses to restore does the same. The window posts one
  warning with the count.
- Only the instance that holds the lock on the folder reads, saves, or sets aside anything. A second running instance
  opens one default window, saves nothing, and says so in its status bar. A launch that cannot take the lock for any
  other reason, or cannot move an unreadable file aside, also saves nothing for the whole run.
- Saving stays off until the launch has opened its windows, so a half-restored layout never replaces the file. If one
  saved window fails to open, the rest restore, and a copy of the file is kept aside before any save can replace it.
  The layout saves after a layout change that is quiet for the debounce, and once, at once, in the quit path. Amended
  2026-11-01; see Decision Log.
- The window frame is clamped onto a screen that exists now. A frame already inside one screen stays. Otherwise the
  screen with the saved frame is used, then the one with the largest overlap, then the main one.
- A restored tree whose minimum size exceeds the visible screen opens inside the screen. The window's minimum content
  size is capped to the visible area, and the layout holds panes at their minimum and overflows. The user reaches the
  panes by keyboard and can close them. The window is never larger than the screen.
- AppKit window restoration is off for every window, and the app delegate refuses to restore secure state. A UI test
  launches with `-NSQuitAlwaysKeepsWindows NO`, which is what the "Close windows when quitting" setting does, and the
  layout comes back with exactly one copy of each window.
- UI tests and debug builds can set `UNITERM_LAYOUT_DIR` for the folder, and `UNITERM_LAYOUT_DEBOUNCE` for a long
  debounce so only the save on quit can write. Release builds ignore both, and `UNITERM_DEFAULTS_PATH` for the
  preferences file, which release builds ignore too. Each UI test gets its own layout folder.
  Amended 2026-11-01; see Decision Log.
- Saving has a maximum wait of 10 seconds. The first change after a save starts it, and later changes restart only the
  debounce. A stream of changes that never goes quiet still writes within 10 seconds. A title or segment change that
  leaves the pane's saved description the same is not a layout change.
- A layout folder that is not available opens one default window that saves nothing, with an error in its status bar.
  A launch that cannot open any window, or an engine that does not start, shows a critical alert that says what failed
  and to quit and open uniterm again. Then the app quits. Amended 2026-11-01; see Decision Log.
- A write flushes the temp file with `F_FULLFSYNC`, falling back to `fsync`, and flushes the folder after the rename.
  A weight that is not a positive finite number is written as an equal share, and an unusable frame as a default one,
  so one bad number never makes the next launch reject the file. A node ID above 2^48 is unreadable, and a mark above
  it is lowered to it. The allocator lowers any mark above 2^62, so it never overflows.
- Decoding makes one pass over each object. A first version rescanned each object once per field. It took 428 ms on a
  150-level tree in a debug build. One pass takes 185 ms in a debug build and 9 ms in a release build. A tree of 1,000
  panes takes 55 ms in debug and 14 ms in release. Nesting of 100,000 levels returns an error and does not crash.
- A process that lacks the lock gets a `notWriter` error from the store, never a trap. The quit path reports a failed
  save through the saver's failure path. A pane with no applet is left out of the saved window, and a split left with
  one child collapses, so the file stays valid.
- Mutation checks each failed named tests and were undone: the crash bound off by one, the launch marker not set, the
  lock weakened, the mode loosened, the verbatim bytes dropped, the mark ignored, both keep-aside rules, the frame
  clamp, the minimum-size cap, AppKit restoration, the debounce, saving while off, a skipped upgrade step, and the
  quit save. One mutation survived: loosening the mode in `open` alone. The `fchmod` that follows it sets 0600 before
  any data is written, so the two are equivalent.
- The package tests pass, 372 run with 4 skipped, in 14.1 seconds. The full UI suite passes, 46 tests with no failure,
  in 353 seconds.
  Left to the user: restoring after a real crash, a second real instance, and a real unplugged display.

### M9: User visual check

**Status:** DONE

The proposal ends with the user looking at the finished app.

- The user reviews the font, the font size, and the colors in both Latte and Mocha, and the result is recorded in the
  As built block
- The user reviews the window chrome, the status bar at the top and at the bottom, and a nested pane layout, and the
  result is recorded in the As built block

**As built:**

- The user reviewed the app on 2026-11-01. The font, the font size, and the colors in Latte and Mocha look good.
- The window chrome looks good. A nested pane layout looks good, and so does the warning when a split runs out of room.
- The status bar looks good at the top and at the bottom, with one bug. After the theme is switched to Dark, the
  directory segment moves from the trailing edge to the leading edge. Switching to Light or System, running commands,
  moving the bar, and resizing the window do not restore it. Opening a new pane does. The bug did not reproduce later
  and is filed in [the bug report](../bugs/20261101-status-bar-segment-leading-after-dark.md). Corrected 2026-11-01;
  see Decision Log.

### M10: Undo reopens from the description

**Status:** DONE

Superseded in part by UTERM-014; see Decision Log.

Added 2026-11-01 by amendment. It can run before or after the user records M9.

- Closing a pane closes its applet at once. No closed applet stays alive, and nothing hidden counts toward a close or
  quit guard
- Undo reopens the newest closed pane from its description, in its former place, with a new ID
- Closing a pane asks first when any of its tabs is running something, and the dialog names those tabs. An idle pane
  closes without asking
- Declining that dialog keeps the pane open. Confirming closes it and puts its description on the undo stack
- The grace segment, its hang-up control, the grace slots, and the reattach path are gone
- The pane tree has no parked IDs. An ID is retired when its node leaves the tree. Insert takes no ID, so a retired one
  cannot come back. Amended 2026-11-01; see Decision Log.
- The applet contract sends start, detach, reattach, and close, and documents each applet's duties per ADR-05
- The terminal applet pauses no output on detach, since it has none to pause. It holds back notifications until
  reattach, per ADR-05, and that is stated where it implements the contract. Amended 2026-11-01; see Decision Log.
  Superseded in part by UTERM-017; see Decision Log.
- Every M7 check that does not depend on keep-alive still holds: placement, the neighbor fallback, Cmd-Z in a text
  control, the working-directory rule, program-mode restore, and the window and quit guards

**As built:**

- Closing a pane ends its applet at once and puts its description on the undo stack, 20 deep, newest first. The grace
  slots, the grace segment and its hang-up control, the slot eviction, the reattach path, the pane tree's parked IDs,
  the dead-pane handling, and the quit and window counts of hidden panes are gone. Their tests went with them.
  Placement, the placeholder for a refused description, the working-directory rule, program-mode restore, and Cmd-Z
  deferring to a text control are unchanged.
- A pane close asks first when any of its tabs is running something. The dialog names those tabs, declining keeps the
  pane, and an idle pane closes without asking. A pane whose applet exited on its own closes with no entry. If the pane
  became the last one while the question was open, confirming closes the window without a second question.
- The pane tree's insert takes no ID and always issues a new one, so a retired ID cannot come back. A node's ID retires
  when it leaves the tree. The ADR-02 guarantees keep their tests, now phrased for a closed pane and for a collapsed
  split.
- The layout file did not change. A window still saves its own ID high-water mark, and a test closes a pane, quits,
  relaunches, and finds the closed ID retired and the next split above the mark.
- The applet contract documents the four lifecycle events and each applet's duties per ADR-05. Nothing in the host
  calls `detach` or `reattach` now, since the host closes a closed pane's applet and never hides one. They stay as part
  of the contract. The terminal applet pauses no output on detach, and holds back notifications until reattach.
- A last pane whose applet exits while the window-close question is open is not asked about again. Cancel leaves it in
  the window, and closing it then needs no question, since nothing is running. Closing it adds no undo entry, because
  the window remembers that its applet exited. The earlier replay that discarded it is gone with the hidden panes it
  served.
- Mutation checks each failed the named tests and were undone: no question for a running pane, no window close on a
  confirmed pane that became the last, and a second window question for the last pane. The package tests pass, 362 run
  with 4 skipped, in 13.8 seconds. The UI test for undo passes and expects the reopened pane to be pane 4 with no
  grace segment. The full UI suite is the coordinator's run.

## Decision Log

- 2026-10-31: Chose Swift, AppKit first with SwiftUI for leaf views, Janet for scripting, and libghostty for the
  terminal.
- 2026-10-31: Set macOS 26 as the minimum version.
- 2026-10-31: Put multiple windows, terminal tabs, undo close, and layout persistence in this proposal's scope.
- 2026-10-31: Review start: 8 milestones, 9 settled decisions, 6 risks, 0 live-after lines or row gates; 6
  out-of-scope items (palette, widget bar, Janet, control and trust, shell blocks, other applets); full review of the
  8 open questions, autonomous mode, at commit 03e40bc.
- 2026-10-31: libghostty is built in-tree from a pinned Ghostty commit, with a kept Zig dependency cache and a
  manifest check. Converged in 2 passes. (autonomous)
- 2026-10-31: Restated the Platform rationale's tie to Swift 6.2 community packages as Ghostty's Xcode 26 requirement,
  since the prebuilt packages were rejected. (autonomous)
- 2026-10-31: Pane tree is a normalized N-ary tree with stable node IDs and per-kind merge rules. Converged in 1 pass.
  (autonomous)
- 2026-10-31: Kept the names pane, applet, and region. Named split, tab, segment, and message. Converged in 1 pass.
  (autonomous)
- 2026-10-31: Status messages carry a level and a source, with no priority. Errors are never skipped, and an
  unseen-error indicator shows. The window and the focused applet own segments. Converged in 1 pass. (autonomous)
- 2026-10-31: Build with a checked-in Xcode project using synchronized folders, with feature code in a local SwiftPM
  package. Converged in 1 pass. (autonomous)
- 2026-10-31: Undo close has two tiers: a hidden live session for a short grace period, then an inert description on a
  per-window stack. Program mode never re-runs its command on undo. Converged in 1 pass. (autonomous)
- 2026-10-31: The dark theme is Mocha. An appearance setting offers System, Light, and Dark, and defaults to System.
  Converged in 1 pass. (autonomous)
- 2026-10-31: Amended Theming. It said "The default theme is Catppuccin Latte." It now says Latte is the light theme,
  since the appearance setting defaults to System. (autonomous)
- 2026-10-31: Added two open questions found in round 2's critique: where settings live, and whether uniterm reads the
  user's Ghostty config. (autonomous)
- 2026-10-31: Settings live in UserDefaults and change in an AppKit Settings window. The dock position is one global
  setting. Converged in 1 pass. (autonomous)
- 2026-10-31: uniterm reads no Ghostty config. It clears Ghostty's built-in keybindings and owns every key binding.
  Converged in 1 pass. (autonomous)
- 2026-10-31: Layout persists to a uniterm-owned JSON file of descriptions only. It always restores, and it has a
  crash-loop guard, a single writer, and a stated skew analysis. No scrollback or tab titles. Converged in 1 pass.
  (autonomous)
- 2026-10-31: Coherence review: added the open question on guarding closes that kill running processes. Restated the
  pane-tree stable-ID rule, since a removed split's ID cannot survive. Amended "Terminal surface behind an internal
  protocol": the protocol sits at the session level, since libghostty owns the pty, and `ghostty.h` is Ghostty's
  internal embedder API. Before, it did not say at what level the protocol sits. Added constraint notes to UTERM-003's
  pane-ID question and a "What anchors trust" open question to UTERM-004. Routed the other findings to milestone
  checks. (autonomous)
- 2026-10-31: Closes ask first wherever undo cannot restore the session: window close, quit, and tab close, counting
  hidden grace-tier panes. Pane closes do not ask. Converged in 1 pass. (autonomous)
- 2026-10-31: Amended the close guard after the re-check. It said pane closes in a window that stays open never ask.
  Now they ask when no grace slot is free and the pane is running something, since the grace tier is bounded.
  Closing an applet's last tab follows the pane rule. Accepted that an unnoticed grace expiry hangs up without a
  dialog. (autonomous)
- 2026-10-31: Risk review: the libghostty churn risk no longer claims a tested SwiftTerm fallback. Added risks for the
  internal embedder API (low, high, mitigated), Xcode updates (medium, medium, mitigated), `xterm-ghostty` over ssh
  (high, medium, mitigated with `ssh-env`), and stored commands (medium, low, accepted). Updated the layout-format and
  undo risks to match the settled decisions. Accepted the downgrade-then-upgrade layout loss. (autonomous)
- 2026-10-31: Amended M8's first check. It said relaunch restores "region docking". It now says applet descriptions,
  since docking is a global setting and settings never live in the layout file. (autonomous)
- 2026-10-31: Review gate: kept all. The user kept the close guard, window undo out of scope, no font settings (13pt
  suits them), and leaving the group node kind to UTERM-004. Added M9, a final visual check by the user. Asked that
  UTERM-004 define the group node kind.
- 2026-10-31: ADR candidate (cuts across the system): libghostty is reached only through the session-level terminal
  surface protocol. Written as ADR-01.
- 2026-10-31: ADR candidate (cuts across the system): pane tree nodes are addressed by stable ID, and retired IDs are
  never reused. Written as ADR-02.
- 2026-10-31: ADR candidate (cuts across the system): restored state never runs a program unasked. Written as ADR-03.
- 2026-10-31: ADR candidate (cuts across the system): uniterm owns every key binding and its terminal config. Written
  as ADR-04.
- 2026-10-31: ADR candidate (hard to reverse): the stored layout stays readable by later versions, and an unreadable
  file is kept aside. Declined: the user chose not to write it, and its Risks entry guards it.
- 2026-10-31: Accepted.
- 2026-10-31: Scheduled as M1-M9 in queue.md.
- 2026-10-31: Amended "How to get libghostty". It said Zig and Xcode 26 are the only extra tools on a cold cache. The
  Ghostty build also needs the macOS 15 SDK from the Command Line Tools, since Zig 0.15.2 fails to link against the
  macOS 26 SDK. It needs Xcode's Metal toolchain component. It also replaces Xcode's libtool, which drops Zig's archive
  members and leaves `ghostty_info` out of the combined library. The build script carries both workarounds as PATH
  shims, so Ghostty's source stays untouched. `ghostty.pin` gained `ZIG_SDK_VERSION`. The pin also gained
  `GHOSTTY_TREE_SHA256`, since the commit hash alone did not check the downloaded bytes. (work-queue best guess)
- 2026-10-31: M1 best guesses. The bundle identifier is `dev.uniterm.app`. The package modules are Theme, Preferences,
  WindowKit, SettingsKit, and TerminalSurface. The Settings window is plain AppKit. The package target links the
  Ghostty xcframework through a symlink inside the package, which keeps the binary path under the package root.
  Dev builds sign ad hoc. (work-queue best guess)
- 2026-11-01: M2 best guesses. The session protocol is `TerminalEngine` and `TerminalSession`, and the applet contract
  lives in AppletKit. The config builder takes an allow list of keys and rejects unsafe values. The close guard stays
  with M7. Amended "Terminal surface behind an internal protocol" and one of M2's checks. Both said shell integration
  emits "prompt marks" through the protocol, which read as every OSC 133 mark. libghostty's C API passes only
  command-finished to its embedder, so the text now names that mark. The running-state query still follows the OSC 133
  prompt marks. (work-queue best guess)
- 2026-11-01: M3 best guesses. The pane tree is its own module. A split lays children along a row or a column, and
  the menu says Split Right and Split Down. A pane is at least 200 by 100 points, and a divider is 5 points. Closing a
  pane gives half of its space to each adjacent sibling. Every split asks which applet to start, and Return accepts the
  shell default. Program mode is collected and refused until M5. The window's minimum size is the tree's minimum, with
  no fixed floor. Key bindings follow Ghostty and iTerm2. Amended the merge check. It said "so no pane changes size".
  A divider takes room that weights do not count, so a pane merged from a split of m children shifts by less than
  (m - 1) divider thicknesses. Exact sizes hold when dividers take no room. While a sheet is up, pane actions are
  disabled and Cmd-W does not cancel the picker. A split is also refused when the new tree's minimum size exceeds the
  current size. (work-queue best guess)
- 2026-11-01: M4 best guesses. The status bar docks at the bottom by default, where M2's strip sat. The setting is
  `statusBarPosition` with the values `top` and `bottom`. A region model has a role enum and a dock edge enum, and the
  window stacks docked regions inward from each edge, with no registry. The history is a panel that floats over the pane
  area, not a taller bar, so opening it resizes nothing and the minimum window size ignores it. Cmd-Shift-M toggles it.
  A pane close drops only the messages still queued from that pane. The message on the bar finishes its turn, since the
  user may not have read it, such as a shell's last error before it exits. The terminal applet's segments are its
  directory and a failed exit code. The leaf views are AppKit, since nothing here needs SwiftUI. An invalid dock value
  warns once for each new bad value, because every watched setting wakes the same observer. A good value in between
  resets the rule. A pane close queues again any error from another pane that had folded into a dropped error.
  (work-queue best guess)
- 2026-11-01: Amended "Status bar" and M4's history check. The bullet said "The bar can expand to show more than one
  line, such as a history of past messages", and the check said "The status bar expands to show the history of
  messages". The built history is a panel that floats over the content area and grows away from the bar, so the bar
  itself never changes height. Expanding the bar in place would resize the panes every time the history opens and
  would make the window's minimum size depend on it. Escape and a click away do not close the panel. The bar and the
  menu item toggle it. (work-queue best guess)
- 2026-11-01: M4 dismissing. A Dismiss Message menu item with Cmd-Option-Delete, and a dismiss glyph beside an error
  on the bar, clear an error. Escape is not used, since the terminal owns it. Info and warning messages clear
  themselves, so the item and the glyph are live only while an error is showing. Dismissing does not clear the
  unseen-error indicator, which only opening the history clears. The UI tests get their error from a debug-only
  launch variable, since no durable error path exists yet. (work-queue best guess)
- 2026-11-01: M5 best guesses. A program-mode command line is split like a shell splits quotes and backslashes, and
  nothing else. Pipes, redirects, globs, `$`, backticks, a leading `~` or `#`, and newlines are refused unless quoted,
  since reading them literally would run something other than what the user typed. A user who wants a pipeline runs
  `sh -c` with the script quoted. Program mode keeps Ghostty's `TERM` except for `ssh`. A new tab starts in the
  selected tab's directory and sits right after it. Cmd-9 selects the last tab, as Terminal and Ghostty do. Tab
  switching is disabled with one tab. The tab bar belongs to the applet, so a tabbed-applet protocol lets the window
  route the keys without knowing the terminal. The applet takes the palette from the window to draw its bar. The
  program-mode description is still refused on restore, and M7 owns the Run action. (work-queue best guess)
- 2026-11-01: Amended M5's check on the last tab. It said "a dialog when it would close the window". M5 builds the tab
  close and the any-tab running state only. The dialog for a close that would close the window, and for quit, is M7's
  with the other guards in "Guarding a close that would kill running processes", so one place decides when to ask.
  (work-queue best guess)
- 2026-11-01: Amended M6 with two checks: appearance reaches every window, and the last window closing leaves the app
  running with Cmd-N or a Dock click to reopen. The approved plan for the run named both, and the original four checks
  did not. (work-queue best guess)
- 2026-11-01: New windows cascade 28 points right and down from the active window, and wrap to the top-left of the
  visible screen at an edge. The active window is the key window, else the main one, else the last opened. Window
  identifiers are numbered and never reused, so UI tests and assistive tools can tell windows apart. New Window sits in
  the File menu with Cmd-N and targets the app delegate, so it works when no window is open. A Dock click reopens a
  window only when no main window is open. A failed open posts to the active window, or shows an alert when there is
  none. (work-queue best guess)
- 2026-11-01: An app-level error posted while no window is open is held and shown in the next window that opens, rather
  than shown in an alert. An alert would interrupt a user who closed every window on purpose. (work-queue best guess)
- 2026-11-01: M7 best guesses. Starting bounds are a 10 second grace period, 3 grace slots, and an undo depth of 20. A
  restored shell's directory is accepted when it is absolute and still a directory, since the surface passes only a
  path and the host is not visible here. The undo item targets the window with the standard undo selector, so a text
  control being edited gets Cmd-Z first. A declined close dialog leaves the pane open. Descriptions gained the tab's
  starting directory. Superseded M5's note that a program-mode description is refused on restore: it now restores into
  a Run prompt and runs nothing. (work-queue best guess)
- 2026-11-01: Amended M7's check on the restored shell's directory. It said the OSC 7 directory is used "only when that
  path is local and still exists". libghostty's surface passes a path and not the OSC 7 host, so "local" cannot be
  checked. The check now says an absolute path that still exists on this machine. A remote directory that also exists
  here is accepted, and the shell starts in the wrong but harmless directory. (work-queue best guess)
- 2026-11-01: Amended "Pane tree shape". It said a removed node's ID is retired and never reused. A closed pane kept
  alive for the undo grace period still exists, and undo must bring it back with its ID. The text now retires a closed
  pane's ID only when the pane is discarded. (work-queue best guess) The user confirmed this reading, and ADR-02's
  wording was clarified to match on 2026-11-01. Superseded later on 2026-11-01: the keep-alive tier was removed, and
  ADR-02's added sentence with it.
- 2026-11-01: A dead last pane that stays because no hidden pane fits after a cancel leaves when a hidden pane returns.
  The guard decision says cancel reattaches the hidden pane, so the window is kept usable until it can. (work-queue
  best guess)
- 2026-11-01: ADR candidate (cuts across the system): every applet implements one applet contract: hosted view,
  lifecycle, segments, detach and reattach, an inert versioned description, and a running-state query. Found in M2.
  Extended 2026-11-01 in M5: the running-state query covers every tab of an applet, since the close guards in M7
  depend on it. Extended 2026-11-01 in M7: window close and quit count hidden panes too. Extended 2026-11-01 in M8:
  descriptions round-trip byte-for-byte when unreadable. Narrowed 2026-11-01: the lifecycle is ADR-05, and description
  versioning is ADR-06. The rest waits on UTERM-005 to UTERM-010, which may reshape the contract. Extended
  2026-11-01 after the run: an optional current directory that a new split or window starts in, passed explicitly
  instead of through libghostty's own working-directory inheritance, which is now off.
- 2026-11-01: ADR candidate (cuts across the system): a terminal program never reads the clipboard without the user's
  confirmation naming its pane, and a denial sends it nothing. A program may write the clipboard with OSC 52 without
  asking, because the proposal requires confirmation only for reads and a write gives the program nothing back.
  Undecided. Found in M2. Extended 2026-11-01 in the row review for writes.
- 2026-11-01: ADR candidate (cuts across the system, hard to reverse): undo close has two tiers. A closed pane first
  stays alive and hidden for a grace period, under its own parked node ID, and then only its inert description
  remains. It interacts with ADR-02, whose wording now says a pane kept for undo keeps its ID, and with ADR-03. Found
  in M7. Reframed by the user on 2026-11-01: the two tiers are an implementation detail. The invariant is the applet
  lifecycle: uniterm sends the lifecycle events, and each applet owns its response. Written as ADR-05 on 2026-11-01.
- 2026-11-01: ADR candidate (cuts across the system): the main window answers the standard `undo:` selector. It undoes
  the edit in a focused text control, and the pane close otherwise. The Edit menu keeps the standard selector.
  Undecided. Found in M7.
- 2026-11-01: M8 best guesses. The starting bounds are 3 unfinished launches, a 1 second debounce, and 5 kept-aside
  files. The ID high-water mark is stored per window, since each window has its own tree. A second running instance
  opens a default window and saves nothing, and the first instance's layout is untouched. A restored tree that needs
  more room than the screen opens inside the screen with panes overflowing, instead of growing the window past the
  screen or dropping panes. The launch marker clears one turn after the windows show. A failed window restore keeps a
  copy of the file aside. The folder and a long debounce are debug-only launch variables for UI tests. A description
  is kept as its exact file bytes, so a placeholder writes it back unchanged. (work-queue best guess)
- 2026-11-01: ADR candidate (cuts across the system): node IDs are scoped to a window's pane tree, and a saved layout
  stores each window's ID high-water mark, so an ID retired before a quit is never reissued in that window. It reads
  ADR-02's "including after a relaunch" per window. A cross-window ID, such as one for scripting or control, would need
  its own rule. Undecided. Found in M8.
- 2026-11-01: ADR candidate (cuts across the system, hard to reverse): a stored applet description is kept as its exact
  file bytes. One that cannot be restored becomes a placeholder pane and is written back unchanged, so a newer or
  unknown description survives a round trip through an older build. Found in M8. Reframed by the user on 2026-11-01:
  placeholder panes are an implementation detail. The invariant is two-layer versioning. uniterm owns the envelope and
  its schema version. Each applet owns its payload and its version, and bumps it on any change an older reader cannot
  round-trip. Version skew is lossless per pane. Written as ADR-06 on 2026-11-01.

- 2026-11-01: Row review fixes, M7 and M8. Amended M7's As built, which said undo takes the newest close and trims the
  oldest description by arrival. Both now go by close serial, because panes drop out of the hidden tier out of close
  order and Cmd-Z reopened an older close first. Amended M7's As built on reopening, which dropped the entry and the
  bytes when the restorer refused a description. It now opens a placeholder that keeps the bytes. Added to M7's As
  built that a pane ending during a close question waits for the answer, since the exit was dropped. On Cancel the pane
  is discarded, or kept as the dead pane when it is the last. On Confirm of a pane-close question it is closed as an
  exit. Amended M8's As built: the launch marker is set after the file is read, and cleared when no window opens, since a launch that failed
  for another reason would otherwise count toward moving a valid layout aside. `UNITERM_DEFAULTS_PATH` is debug-only
  like the other test variables. (work-queue best guess)
- 2026-11-01: Amended M5's As built, which said a background tab's directory event leaves the host alone. It now tells
  the host without changing the segments, since the directory is part of the saved description and the layout would
  otherwise miss it. The title and exit-code events are unchanged. (work-queue best guess)
- 2026-11-01: A launch failure that leaves no window shows a critical alert and quits, as the engine start failure
  already did. An unavailable layout folder is different: a default window opens and saves nothing, the same as an
  unavailable lock does, so the user can still work. The app only quits when no window can open. (work-queue best
  guess)
- 2026-11-01: OSC 52 clipboard writes are allowed without asking. The proposal requires confirmation only for reads.
  The config already set `clipboard-write` to `allow`, so libghostty never raised the write question, and the dialog
  for it was unreachable. Amended M2's As built, which listed "a confirmed OSC 52 write" among the asked requests. The
  dialog and its request kind are removed. A write question that did arrive from libghostty is answered yes. Writes
  can replace the clipboard with text the user did not choose. The cost is accepted, since terminals such as tmux and
  vim over ssh depend on it. (work-queue best guess)
- 2026-11-01: Amended "What undo close restores", "Pane tree shape", "What layout persistence restores", "Guarding a
  close that would kill running processes", and the undo risk, and added M10. The undo decision had two tiers: a closed
  pane's applet stayed alive and hidden for a grace period so undo could reattach the exact session, and only then
  dropped to its description. The pane tree parked a closed pane's ID for that reattach. Pane closes asked only when no
  grace slot was free. The user ruled that undo reopens the same applet in the same place, not a snapshot of running
  processes. uniterm sends lifecycle events and each applet owns its response, per ADR-05, which was rewritten to say
  so. So undo now reopens from the description only, and closing a pane that is running something asks first. The user
  chose to remove the keep-alive tier and to ask on a running pane close.
- 2026-11-01: M10 best guesses. The undo stack is depth 20, and the policy is that depth alone. A pane that exits while
  the window-close question is open is ignored. Cancel then leaves the dead pane, and closing it asks nothing. The
  earlier handling discarded it and reattached hidden panes, which no longer exist. Confirming a pane-close question
  for a pane that has become the last one closes the window. Nothing in the host calls `detach` or `reattach`, and the
  contract keeps both. Amended M10's check on the terminal's detach, which said it pauses nothing. The terminal applet
  holds back alerts on detach, per ADR-05. Notifications that arrive while
  detached are kept, only the newest is posted on reattach, and older ones are dropped. The terminal posts no bell
  alert, so the bell has nothing to hold. A pane whose applet exited on its own never adds an undo entry, even when it
  stays in the window after a cancelled window question and is closed later. (work-queue best guess)
- 2026-11-01: Amended two bullets of M8's As built block, the one on the ID high-water mark and the one on the quit
  save, and M10's check on the pane tree's IDs. The "What layout persistence restores" decision was amended in the
  entry above, not here. M8 said panes hidden for undo are not saved and that their IDs are refused on insert, and that the quit save
  runs before the hidden panes are hung up. M10 removed hidden panes and the ID an insert accepts. The text now says
  the IDs of closed panes stay below the mark and are never issued again, and the quit save has no hang-up step after
  it. M10's check said insert never accepts a retired ID. Insert now takes no ID. (work-queue best guess)
- 2026-11-01: Correction of fact in M9's As built. It said the status bar bug was fixed as a UI change outside this
  proposal. Neither the user nor the implementer could reproduce it, so no fix was made. It is filed as an open bug.
- 2026-11-02: Superseded in part by UTERM-013. M7 and M10 bound pane reopen to Cmd-Z. UTERM-013 moves reopen to
  Cmd-Shift-T, which reopens the newest closed tab or pane in the window, and limits Cmd-Z to text edits.
- 2026-11-02: Superseded in part by UTERM-014. M7 and M10 said a pane whose applet exited on its own closes with no
  undo entry. UTERM-014 makes every close reopenable, so an exited pane goes on the reopen list without a question.
- 2026-11-06: Superseded in part by UTERM-017. "Status message model" said an error stays until a newer message
  replaces it or the user dismisses it, kept the unseen-error indicator for errors only, set no rule for repeats, and
  bounded the history only by a 500-message cap. UTERM-017 settles that a message reporting lost work never times
  out and that a replacing message leaves unseen-error attention until acknowledged. It adds a lesser unseen signal
  for warnings, coalesced presentation of repeats, and a history of two bounded pools with a pane filter. M10 said the
  terminal holds back notifications until reattach. UTERM-017 keeps that, and also records each held alert in the
  history when it occurs, so a close before reattach loses nothing. The queue changes ship in UTERM-017 M2 and M3.

## References

- [ADR-01](../adr/ADR-01-libghostty-behind-terminal-surface-protocol.md): libghostty is reached only through the
  terminal surface protocol
- [ADR-02](../adr/ADR-02-pane-tree-nodes-have-stable-ids.md): pane tree nodes are addressed by stable ID
- [ADR-03](../adr/ADR-03-restored-state-never-runs-a-program.md): restored state never runs a program unasked
- [ADR-04](../adr/ADR-04-uniterm-owns-key-bindings-and-terminal-config.md): uniterm owns every key binding and its
  terminal config
- [ADR-05](../adr/ADR-05-applet-lifecycle-events-and-applet-responses.md): uniterm owns the applet lifecycle events,
  and each applet owns its response
- [ADR-06](../adr/ADR-06-layout-file-versioning-and-schema-ownership.md): the layout file is versioned in two layers,
  each with one owner

- Original write-up: `~/projects/private_specs/uniterm/spec/research/original-writeup.md`
- [Ghostty](https://ghostty.org/docs/about): libghostty is not yet a stable API
- [loeschg/GhosttyKit](https://github.com/loeschg/GhosttyKit)
- [rijieli/libghostty-spm](https://github.com/rijieli/libghostty-spm)
- [Mitchell Hashimoto on the Swift renderer package](https://x.com/mitchellh/status/2072724957902381319)
