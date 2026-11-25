# UTERM-028 says no exec-capable applet ships, but two do

**Status:** open
**Found:** 2026-11-22, during the UTERM-055 critique
**Validation:** confirmed by reading the code
**Estimate:** small; one non-trivial decision. The two passages (the Version skew rationale near line 129 and the
Risks entry near line 258 of the UTERM-028 proposal) are a plain correction of fact. The risk's rating is a judgment
call: keep likelihood low with a new reason, or raise it because map viewer and image viewer exec drivers may be
deployed. Line 154 ("No exec-capable applet has an opted-in body today") is about opted-in bodies, not about accepting
drivers, and was not checked for staleness.

## Observed

UTERM-028's "Version skew" rationale says "No exec-capable applet ships today". Its Risks accept a deployed version 4
driver refusing the new hello partly because "no exec-capable applet ships today and no driver documentation exists, so
few if any such drivers exist". The map viewer and the image viewer accept exec drivers today, so drivers for them may
be deployed.

## Cause

`Packages/UnitermKit/Sources/MapViewerApplet/MapViewerCommands.swift:10` and
`Packages/UnitermKit/Sources/ImageViewerApplet/ImageViewerCommands.swift:13` declare
`controlSupport: ControlCombination.all`, which includes `.disconnectedExec` and `.remoteControlledExec`.
`MainWindowController.runExecDriver` admits them. The claim in `spec/proposals/UTERM-028-exec-driver-commands.md`,
around lines 126 and 255, was likely true when written and is now stale.

## Repro

Read `ControlCombination.all` in `AppletKit/PaneControl.swift:46` and the two declarations above.

## Fix

Correct UTERM-028's two passages as a correction of fact. The risk's rating then needs a call: keep it low with a new
reason, or raise it now that map viewer and image viewer drivers may exist.
