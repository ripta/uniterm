# The terminal's tab bar ignores the control badge

**Status:** fixed 2026-11-22
**Fixed:** 2026-11-22
**Estimate:** small to medium; no open design decisions. The Fix section already picks the shared tab bar taking the reach.
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

UTERM-041's review did not take the fix on, since the badge covers the new-tab button and not the marker slot. When
this bug is fixed, the shared tab bar taking the reach is the fix that serves every applet with a bar.

## Fix note

Triage on 2026-11-22 reproduced it in a package test. With two tabs, a 400-point applet, and a badge reach of 24, the
new-tab button ended at 394 points. The badge's clear edge was at 376.

The shared tab bar now takes the reach. `AppletTabBar.trailingReserve` keeps the tabs and the new-tab button clear of
the badge. The bar's background still runs under the badge. The terminal forwards `hostBadgeReachDidChange` to its bar.
The browser and the questions applet set the same property and pin their bars to full width, in place of their own
trailing constraints. `testTheNewTabButtonStaysClearOfTheControlBadge` in `TerminalAppletTests.swift` covers it.
