# A pane a script opens with open-pane leaves its first tab unowned

**Status:** open
**Found:** 2026-11-22, during the UTERM-054 review
**Estimate:** small; no open design decisions. Two files: `MainWindowController.swift` and `AppletKit/TabOpening.swift`.

## Observed

A script that opens a remote-controlled browser pane through `open-pane` may find its browser commands refused on the
pane's first tab, as if it were the user's. The same pane opened through a layout starts with its first tab owned by the
script.

## Cause

`MainWindowController.stageLayout` calls `CallerOwning.adoptFirstTab` for every pane a layout opens with control
(`Packages/UnitermKit/Sources/WindowKit/MainWindowController.swift:879`). The controller split that `open-pane` uses,
`MainWindowController.openPane(_:typeID:axis:from:directory:owner:access:)` at line 747, sets the pane's control and
never calls `adoptFirstTab`. `WindowScripting` calls it at `WindowKit/WindowScripting.swift:219`.

`CallerOwning.adoptFirstTab` documents only the layout case: "A pane the caller's layout created starts with its first
tab owned by the caller."

## Repro

Reproduced 2026-11-23 with a throwaway WindowKit test, since deleted. It opened a remote-controlled browser pane through `ScriptingFixture.openPane`, the same path as `open-pane`. `BrowserApplet.tabOwners.count` was 0, where the layout path gives 1.

Expected: a script opens a remote-controlled browser pane with `open-pane`, then navigates its first tab with
`send-command`, and the command runs. Actual: the command is refused, since the browser's `tabOwners` holds
no owner for that tab.

## Fix

Call `adoptFirstTab` in the controller split when the pane starts with control, as the layout path does, and widen the
protocol's doc comment to cover every pane a program opens. Check first whether `open-pane` is meant to give the script
the first tab. If it is not, the doc comment should say why the two paths differ.

## Estimate

Small. The intent is settled. The screenshot proposal's As built block says a pane any program opens with `open-pane` starts with its first tab owned by that program, through the shared open-pane path, and names this bug as closed by that.

The fix touches:

- `Packages/UnitermKit/Sources/WindowKit/MainWindowController.swift`: in `openPane(_:typeID:axis:from:directory:owner:access:)`, inside the `access != .disconnected` branch, call `(applet as? any CallerOwning)?.adoptFirstTab(for: AppletCaller(grant: owner.description))`, as `stageLayout` does.
- `Packages/UnitermKit/Sources/AppletKit/TabOpening.swift`: widen the `adoptFirstTab` doc comment to every pane a program opens.
- `Packages/UnitermKit/Tests/WindowKitTests/BrowserWindowTests.swift`: a test that opens a browser pane through `openPane` and asserts one `tabOwners` entry for the connection's grant, and none for a disconnected pane.
