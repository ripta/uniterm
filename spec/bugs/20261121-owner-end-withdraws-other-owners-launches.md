# An owner's end withdraws every launch waiting in its panes, whoever staged it

**Status:** open
**Triaged:** 2026-11-22 (filed repro cannot happen; nested-group variant unconfirmed; see investigation notes)
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

## Investigation notes

Triage run on 2026-11-22.

- The filed repro does not hold. A launch waiting for approval comes only from the user's Run on the pane. No controller
  stages one, so controller C cannot have a launch waiting in a pane that A's group holds.
- A pane holds at most one waiting request, because `request` withdraws the pane's earlier one first. The cover check
  asks the pane's single innermost group owner, through `owner(of:)`.
- Withdrawing a waiting launch when that owner ends is deliberate. The doc comment on `ownerEnded` says so, and
  `testOnlyTheLiveRunThatOwnsThePaneCoversItsLaunch` pins it. That test passes on the current build.
- One variant remains, by trace only. A pane sits in nested groups. An outer owner A ends while the innermost owner D
  stays. `releaseOwner` returns the pane, and `ownerEnded` withdraws D's waiting launch. D's user then sees "Not allowed.
  Choose Run to ask again." A fix would withdraw only when the pane's innermost owner was the one that ended.
- The variant was not reproduced. Reproducing it needs a fixture with nested owned groups and a waiting launch.
