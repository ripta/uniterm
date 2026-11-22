# The terminal's tab bar ignores the control badge

**Status:** open
**Validation:** found by reading the code during the UTERM-041 critique, not reproduced in the app.
**Found:** 2026-11-21, during the UTERM-041 critique

## Observed

When a remote-controlled terminal pane shows its tab bar, the control badge covers the last tab's close button or the
new-tab button.

## Cause

- The terminal uses the default no-op `hostBadgeReachDidChange`
  (`Packages/UnitermKit/Sources/AppletKit/Applet.swift:307-313`).
- Its tab bar reserves no trailing width (`TerminalApplet.swift:727-740`).
- The browser handles it. `BrowserApplet+Remote.swift` (about line 241) sets `content.badgeReach`, and
  `BrowserView.swift` (about lines 65-68) sets `tabBarTrailing.constant = -badgeReach`.

## Options

- The terminal forwards the reach to its tab bar, as the browser does.
- The shared tab bar takes the reach, and the browser's own trailing constraint is removed.

## Fix

Waits on UTERM-041's badge-clearance question, which asks whether that proposal takes the fix on.
