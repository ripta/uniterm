# An owner's end withdraws every launch waiting in its panes, whoever staged it

**Status:** open
**Validation:** not confirmed; traced in code only. The repro needs a pane that one owner's group holds while another
owner has a launch waiting in it.

## Observed

When a controller's authority ends, each pane its groups released loses every launch waiting for approval there. A
launch another controller staged in the same pane is withdrawn too. That controller never lost its authority.

## Cause

`ownerEnded` (`Packages/UnitermKit/Sources/WindowKit/MainWindowController+Control.swift`, about lines 154-170) calls
`launchAuthority.withdraw(target:)` for each released pane. `withdraw(target:)`
(`Packages/UnitermKit/Sources/WindowKit/ExecLaunchAuthority.swift`, about lines 140-145) removes every request whose
target matches. A request (`ExecLaunchAuthority.swift`, about lines 24-29) holds an ID, a target, a pane title, and the
launch. It records no owner, so the withdrawal cannot tell owners apart.

The badge's Revoke Controller ends every controller of the pane, so it hides the fault. A connection that ends on its
own, or a one-controller revoke, would show it.

## Repro

1. Open a pane that controller A's group holds as a member.
2. Have controller C, which also has authority over the pane, stage a launch there that waits for approval.
3. End A's connection without revoking C.

Expected: C's launch still waits for approval. Actual, per the trace: C's launch is withdrawn.

## Fix

Record the staging owner on each launch request. Withdraw by owner and target when one owner ends. A pane-wide revoke
still withdraws every owner's request, since it ends every owner.
