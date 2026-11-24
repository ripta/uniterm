# UTERM-028 says no exec-capable applet ships, but two do

**Status:** fixed 2026-11-23
**Found:** 2026-11-22, during the UTERM-055 critique
**Fixed:** 2026-11-23, by a correction of fact in UTERM-028
**Estimate:** small; the risk's rating was resolved as low, with true reasons.

## Observed

UTERM-028's "Version skew" rationale says "No exec-capable applet ships today". Its Risks accept a deployed version 4
driver refusing the new hello partly because "no exec-capable applet ships today and no driver documentation exists, so
few if any such drivers exist". The map viewer and the image viewer accept exec drivers today, so drivers for them may
be deployed.

## Cause

`Packages/UnitermKit/Sources/MapViewerApplet/MapViewerCommands.swift:10` and
`Packages/UnitermKit/Sources/ImageViewerApplet/ImageViewerCommands.swift:13` declare
`controlSupport: ControlCombination.all`, which includes `.disconnectedExec` and `.remoteControlledExec`.
`MainWindowController.runExecDriver` admits them. UTERM-028 was written on 2026-11-15. The image viewer gained exec
support on 2026-11-17 and the map viewer on 2026-11-20, so the claim was true when written.

## Repro

Read `ControlCombination.all` in `AppletKit/PaneControl.swift:46` and the two declarations above.

## Fix

UTERM-028's rationale and risk now name the map and image viewers. The risk stays at low likelihood. Exec drivers have
been possible only since 2026-11-17, and nothing documents the exec wire for third parties: the only driver in the repo
is the test fixture `Tests/ExecTestSupport/Fixtures/driver.pl`. The proposal's line about opted-in bodies still holds,
since no applet body opts into driver keys yet.
