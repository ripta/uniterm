# A driver that owns no group keeps its clipboard grant until its run ends

**Status:** open
**Validation:** not confirmed in the running app; traced in code. No shipped applet declares exec support, so the repro
needs a test applet that does.
**Found:** 2026-11-16, by the design critic reviewing UTERM-028

## Observed

An exec driver asks for a clipboard read or write, and the user chooses Allow for This Run. The driver never requests a
layout, so it owns no group. Its pane's chrome then offers no Revoke Controller. The Pending Requests panel cannot revoke
the grant either. The only way to take the clipboard power back is to stop the driver or close its pane. UTERM-004 says
pane chrome exposes revoke, and that revocation removes current authority.

## Cause

- `canRevokeController` (`Packages/UnitermKit/Sources/WindowKit/MainWindowController+Control.swift:39-43`) is true only
  when `controllers(of:)` is not empty.
- `controllers(of:)` (lines 48-65) collects the owners of groups that hold the pane as a member or source, plus script
  connections. A group-less driver's owner is in neither set.
- `revokeController` (lines 114-135) ends a driver's clipboard powers only for an attachment whose owner is in that set.
- The panel's Revoke (`PendingRequestsWindowController.swift:531-537`) covers script grants, undeclared runs, and launch
  grants. A driver's clipboard grant lives on its attachment (`MainWindowController+Exec.swift:51`) and has no row.

## Repro

With a test applet that declares exec support, attach a driver that sends `clipboard-read`. Choose Allow for This Run.

- Expected: the pane's badge or the panel offers a revoke that ends the grant, and the driver's next read asks again.
- Suspected: no revoke is offered, and the driver keeps reading the clipboard until its run ends.

## Fix

Offer Revoke Controller on a driver's own pane whenever its run holds a per-run grant. UTERM-028 settles this for the
command grant. The design call is whether the same rule covers clipboard grants, or whether the panel lists a driver's
per-run grants with a Revoke of their own.
