# A revoked controller that keeps its connection open stays listed on the badge

**Status:** fixed 2026-11-22
**Fixed:** 2026-11-22
**Estimate:** small; no open design decisions. One file changes, `ScriptHost.swift`. The fix follows the neighbor
`controllers(actingIn:)`. Its callers need no revoked connection: the badge, Revoke Controller, and
`removeSessionRoot`, whose revoked connections already had their authority ended.
**Found:** 2026-11-21, during the UTERM-041 review

## Observed

After the user clicks Revoke Controller on a pane, a script bound by process ancestry that keeps its connection open,
such as one waiting on events, may still show as "Controller:" in the badge's tooltip and menu. Revoke Controller may
stay enabled.

## Cause

- `ScriptHost.controllers(actingFrom:pane:)` (`Packages/UnitermKit/Sources/ScriptHost/ScriptHost.swift`, about line
  797) lists every open connection acting for the pane. It does not subtract `revokedControllers`.
- Its neighbor `controllers(actingIn:)` (about line 803) does subtract them, "since their calls are refused".
- `revokeControllers` (about line 824) ends explicit grants, but a connection bound by ancestry keeps its binding
  until it closes.
- `MainWindowController.controllers(of:)` reads `controllers(actingFrom:)`, so the badge may keep the revoked
  connection.

It is not known whether leaving revoked connections in `controllers(actingFrom:)` is deliberate.

## Repro

Run a script with `uniterm run` that binds and then waits on events, in a remote-controlled terminal pane. Click the
pane's badge and choose Revoke Controller. Expected: the badge no longer lists the script. Suspected actual: it still
lists "Controller:" with the script's name.

## Fix

Subtract `revokedControllers` in `controllers(actingFrom:)`, as `controllers(actingIn:)` does. Check first whether any
caller relies on seeing revoked connections there. UTERM-041 M2's chip follows the same check, so its "revoking removes
the chip" check exercises this path.

## Fix note

Triage on 2026-11-22 confirmed the bug. `ScriptBindingTests.testARevokedAncestryBoundConnectionIsNotListedForItsPane`
binds a relay by ancestry, keeps it open, and revokes it. On the unfixed code the pane still listed the connection.

`controllers(actingFrom:pane:)` in `Packages/UnitermKit/Sources/ScriptHost/ScriptHost.swift` now subtracts the revoked
set, as `controllers(actingIn:)` does. The badge and Revoke Controller both read that list through
`MainWindowController.controllers(of:)`, so a revoked connection no longer counts for either. The redraw itself was not
checked in the running app. The full package suite passes.
