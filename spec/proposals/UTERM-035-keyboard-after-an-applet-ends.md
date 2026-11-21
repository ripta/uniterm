# UTERM-035: Keyboard After an Applet Ends

**Status:** retracted
**Created:** 2026-11-19
**Updated:** 2026-11-19

Retracted 2026-11-19. The user decided that every close works the same way: the pane closes, and the neighbor takes
the keyboard. The design below is kept only as history. See Decision Log.

## Dependencies

- UTERM-001, for the close path of a pane and a window, and for focus after a close
- UTERM-026, for the "Focus" decision that leaves this rule to the filed bug
- The bug `20261118-script-opened-tab-takes-keyboard`, whose fix an M1 check needs

## Impacts

- UTERM-001 — "Focus after a close": the rule that focus moves to a neighbor when the closed pane had it changes for an
  end the user did not cause. Its rules that a shell that exits closes its own pane, that closing the last pane closes
  the window, and that an exited shell closes its tab change for a pane or tab that held focus.
- UTERM-026 — "Focus" and its Impacts line on UTERM-001's exit rule: a window whose last applet ends now stays open,
  so that line's "unchanged" no longer holds. Its popped-out window case waits on this rule. Its M1 check that zoom
  ends when the zoomed pane's applet ends on its own no longer holds: the zoomed pane holds focus, so it stays, dead,
  and stays zoomed. M4 has a check that needs the fix of the bug
  `20261116-ended-applet-close-gives-neighbor-keyboard`.

## Summary

Settles where the keyboard goes when a focused pane's or a window's applet ends without the user's doing. ADR-12 says
an unchosen close never lets the keyboard fall to a neighbor. The close path still hands it to one.

## Motivation

A terminal whose last session ends calls `appletDidExit` (`TerminalApplet.swift:828`). So does a terminal whose first
session fails to start (`:354`), and a REPL whose helper closes its connection with no reason (`ReplApplet.swift:533`).
A REPL that ends with a reason keeps its pane and offers a restart.

The window closes the pane through `closePane(_:appletEnded: true)` and `describeAndClose`. That method ends with
`paneArea.focus(next, keyboard: !isPaletteVisible)`. When the ending pane held focus, the neighbor takes the keyboard. A
user who was typing into the ending pane has the rest of their keys land in the neighbor, which can be a shell. A
background pane's end moves nothing today.

The launcher also reports through `appletDidExit` (`LauncherApplet.swift:49`), but its end is the user's Escape.
`closePane` sends a launcher to `discard`, which also hands the keyboard to the neighbor. That is a close the user
chose, so `discard` is not an instance of this bug.

The same seems to happen across windows. A window whose only pane ends closes, and AppKit makes another window key.
That window's focused pane would take the keyboard. This is traced in code and never watched.

The bug `20261116-ended-applet-close-gives-neighbor-keyboard` holds the trace and a throwaway test that reproduced the
pane case with two fake applets. The calls below are not settled, so the bug moved here.

## Design Decisions (Settled)

### Scope: ends the user did not cause

Decision: this proposal covers an applet that ends without the user's doing. A close the user asked for keeps today's
path, where the keyboard follows the focus mark.

Rationale: ADR-12 limits itself to unchosen changes. A user's close made through uniterm's own commands is a choice,
and the neighbor taking keys is what they expect. A command typed into the program, such as `exit`, is not one of
those. See "Whether an `exit` counts as chosen". Amended 2026-11-19; see Decision Log.

The `appletEnded` flag cannot carry this boundary alone, since the launcher's Escape travels on it.

### Where the keyboard rests after an unchosen close

Original question: ADR-12 forbids the neighbor taking the keyboard. It does not say who holds it instead. Four paths
hand the keyboard back to `paneArea.focusedPane`. Menu commands act on it. The focus marker hides with one pane left.
The window has no `keyDown` sink. Scripts read `focusedPane` as `focused`. A focused pane's end in a window that is not
key still makes the neighbor that window's first responder. The candidates were a window-owned held state with the mark
on the neighbor, no focus mark at all, a delay, and keeping every ended pane in place.

Decision: a pane whose applet ends stays in place, inert, only when closing it would move the keyboard. That is a pane
that held its window's focus, whether or not the window is key. It shows that its session ended, keeps its last output
on screen, and swallows keys. A close the user chooses, such as Cmd-W, removes it. A pane without focus closes as it
does today, since that moves nothing. A window's only pane always holds focus, so that window stays open too. (autonomous)

- Nothing moves, so no neighbor and no other window is exposed. The four hand-back paths, the menu commands, and the
  script `focused` field all keep pointing at the pane the user was in.
- A Cmd-W typed before the end closes the dead pane, which is the pane the user meant. It closes without a question,
  since a dead applet reports nothing running and no unsaved work. Amended 2026-11-19; see Decision Log.
- A Cmd-D typed before the end splits the dead pane, and the new pane is the user's choice.
- Every typed `exit` or Ctrl-D in a focused pane now leaves a pane that needs a Cmd-W. This departs from Ghostty and
  iTerm2, which close the pane on exit. Terminal.app and WezTerm keep the pane only on an unclean exit.
- This changes UTERM-001's shipped rule that a shell that exits closes its own pane, for a pane that held focus.

Rationale: this is the only candidate that meets every clause of ADR-12 with no new state to guard. The held state put
the mark on a neighbor whose keys were swallowed, with five call sites that had to check it by convention, and refused
a Cmd-D while a focused pane showed. No focus mark made `focusedPane` optional across commands, restore, the saved
layout, and the public `focused` field. A delay is the alternative ADR-12 rejects. Keeping every ended pane, focused or
not, gives the same correctness but also changes background ends, which expose no keyboard. That would add scope.
Keeping the pane also keeps the last output of a failed start, or of a program-mode pane's program, such as `ssh`, the reason the REPL already keeps its
pane. Converged in 1 pass.

### Whether an `exit` counts as chosen

Original question: a user who types `exit` chose the close. A background job that hangs up the shell did not. The
terminal's exit event carries no code or reason. The candidates were every end unchosen, an exit reason from the
applet, a recent-typing heuristic, and classifying a close by where the request came from.

Decision: a close is chosen only when it comes through uniterm's own Close command. Every end an applet reports through
`appletDidExit` is unchosen, including a typed `exit`. The launcher's Escape runs the window's Close command, the same
path as Cmd-W, instead of reporting an end. So `appletDidExit` means only an end. (autonomous)

- The Close command reaches `closePane(appletEnded: false)` only through `closeTabOrPane`
  (`MainWindowController+Commands.swift:81-91`). It is dispatched only from the menu and key bindings, the palette, and
  a status bar segment click. A driver's command goes to applets, not to window commands, and scripts have no call that
  removes a pane.
- Whatever lets the launcher run the Close command is only for input the launcher's own view took from the user. It
  never runs on a program's request.

Rationale: the exit status comes from the program in the pty, or a remote host over ssh, so trusting it as chosen puts
the trust decision on the program's side. A timing heuristic and an exit reason both send type-ahead and a repeated
Ctrl-D to the neighbor. ADR-12 says input that merely repeats never counts as a choice. Counting every end as unchosen
alone would treat the launcher's Escape as an end and, under the pane decision, leave a dead launcher pane. Routing
Escape through the Close command adds no host call that an applet could use to claim the user asked. Converged in 1
pass.

### The window that closes when its last pane ends

Original question: a window whose only pane ends closes, and AppKit picks the next key window. That window restores
its own saved first responder, often a terminal view, so its pane takes the keyboard. The candidates were holding the
next key window, leaving it to macOS, reordering the close, keeping the window open with its dead pane, and holding only
when the ending window is key.

Decision: the window does not close. Its only pane held its focus, so the settled pane decision keeps that pane in
place, dead, and the window stays open with it. The key window does not change. Cmd-W on the dead pane closes the
window through the last-pane path, with no question. (autonomous)

Rationale: no window closes, so AppKit never picks a next key window, and no hand-off has to be watched or held. Holding
the next key window brings back the held state the pane decision rejected, at window scope. It also races the terminal
surface's own key-window observer (`GhosttySurfaceView.swift:548`). Holding only when the ending window is key fails
when the app is inactive: the user returns with Cmd-Tab, AppKit makes another window key, and keys reach its shell.
Leaving it to macOS breaks ADR-12's last rule and UTERM-026 "Focus". Keeping the dead pane only in the most recently
key window would close background windows as today. It was not taken, since a window that lingers dead costs one Cmd-W
and the narrower rule adds a second predicate whose AppKit behavior no one has watched. Converged in 1 pass.

### Whether tab ends join this proposal

Original question: a terminal with several tabs removes a tab whose session ends (`TerminalApplet.swift:819-830`).
`removeTab` calls `focus()` when the terminal had focus (`:657-683`), so the next tab's shell takes the keys. ADR-12's
Context names "the pane or tab it owned closes". The candidates were bringing tab ends in, or leaving them to the bug
`20261119-ended-tab-gives-next-tab-keyboard`.

Decision: bring tab ends in, with the host owning the focus test. When the selected tab's session ends, the terminal
asks its host whether to keep it. The host answers keep exactly when the pane is the window's focused pane, the test
the pane decision uses. A kept tab stays selected, inert, showing that its session ended, until the user closes it. A
tab the host does not keep closes as today. A background tab's end moves no keyboard, so the terminal closes it as
today without asking. This adds a member to `AppletHost`, which has no focus query today
(`AppletKit/Applet.swift:87-100`). The member has no default, so a host cannot answer by omission. Amended 2026-11-19;
see Decision Log. (autonomous, addition)

Rationale: leaving tabs out keeps a known ADR-12 violation. It also gives one command two opposite behaviors: `exit` in
a focused one-tab pane leaves a dead pane, while `exit` in a two-tab pane sends the next keys to the other tab's shell.
The terminal's own `hasFocus` reads first-responder state, which leaks. With the palette open, the selected tab's end
removes the tab without refocus, and the palette's Escape then focuses the pane and arms the next tab
(`MainWindowController+Palette.swift:54-71`). Only the host's focused pane avoids that. Whatever M1 builds for a dead
terminal pane is a dead tab in the terminal, so the added cost is small. Adds scope: the terminal applet's tab removal
and a new host member join this proposal. Converged in 1 pass.

### When a dead pane comes back to life

Original question: A dead pane can get live content again. Cmd-T, the tab bar's new-tab button, reopen-tab, and a script's `open-tab` all
start a new session in a dead terminal pane (`TerminalApplet.swift:484-524`, `:616`, `WindowScripting.swift:206-238`).
A REPL whose helper left with no reason calls `appletDidExit` but stays in its running phase, so a later pty exit draws
its ended state with a Restart button (`ReplApplet.swift:527-543`).

The host records an ended applet in `exitedApplets` when `appletDidExit` arrives (`MainWindowController.swift:1434`),
and only a close removes it. `closePane` checks that set before the unsaved-work and running questions (`:975-979`).
Scenario: a focused shell exits and leaves a dead pane. The user presses Cmd-T, runs `vim` in the new tab, closes the
dead tab, and presses Cmd-W. The pane closes with no question, and `vim` is killed.

The contract also says the opposite of the settled decisions. `appletDidExit` reads "its pane should close"
(`Applet.swift:98`), and the lifecycle doc says the host never keeps an applet after closing it (`:199-202`). No text
says who owns the dead state.

The candidates were refusing revival, asking the applet through a new read-only property, and a second contract call
that clears the host's record.

Decision: the host keeps no record of an end, and the contract gains no member. `exitedApplets` is deleted, along with
its stale doc comment, which says closing one adds no undo entry while `describeAndClose` pushes one
(`MainWindowController.swift:164-166`, `:1104`). `closePane` asks the applet's existing `unsavedWork` and
`isRunningSomething`, which a dead or revived applet answers truthfully. The applet owns its dead state: it enters it
before reporting the end, and leaves it when it gets live content again. A terminal is dead when it has no live tab. A
REPL whose helper leaves with no reason shows its ended view with Restart before reporting the end, so a REPL has one
ended state. The `appletDidExit` doc comment and the lifecycle doc say the host may keep the pane. (autonomous)

Rationale: the record's only reader is `closePane` (`MainWindowController.swift:975`). The last-pane path and quit
already ask the applet. A dead terminal tab reports not running, since `Tab.isRunningSomething` checks
`session.hasExited` (`TerminalApplet.swift:68-72`), and a REPL whose helper left reports not running. So the record
only skips questions the applet already skips, and its staleness is what let a revived `vim` die without a question.
Removing it fixes the structure that made the bug possible. Refusing revival gives Cmd-T opposite behaviors in a pane
with a dead selected tab and a live background tab, needs a third REPL ended state, and leaves a dead popped-out window
no way back to a shell short of closing it. A read-only property would have no caller once the record is gone. A
second call keeps the record, and any revival path that misses the call brings the bug back. Converged in 1 pass.

### What a dead pane restores as

Original question: A saved layout records each pane's description. A terminal description in shell mode starts a fresh shell at relaunch,
per ADR-03. A dead window stays in the window set, and quitting does not ask about it (`WindowSet.swift:185-219`).

The candidates were restoring it live from its description, leaving it out of the saved layout, and saving it with a
dead marker.

Decision: a dead pane saves its description like any pane, and relaunch restores it live. A terminal in shell mode
starts a fresh shell, a program-mode terminal waits for Run, and a REPL starts fresh. Dead tabs come back as fresh
shells with the selected tab kept. The ended state and its last output are not kept. The layout format does not
change. (autonomous)

Rationale: every pane's session and output already die at quit and come back fresh, and a dead pane's undo entry
already reopens it live, so undo and relaunch match, as ADR-03's consequence asks. Leaving the pane out hides at
relaunch a pane the user saw at quit, and moves the restored focus away from where the user was. A dead marker bumps
the envelope under ADR-06, so a downgrade then upgrade can lose the layout. It cannot mark a dead tab in a live pane,
and it saves the dead state without the output that justified keeping it. Converged in 1 pass.

## Design Decisions (Open)

None.

## Risks

- **A dead pane looks like a frozen one** — likelihood: medium, impact: medium.
  Mitigation: M1 has a check that a dead pane or tab shows its session ended, with one pane left as well as several.
- **A dead pane beeps on each key** — likelihood: medium, impact: low.
  Mitigation: M1 has a check that keys typed into a dead pane reach no program and do not beep.
- **Dead panes pile up** — likelihood: medium, impact: low. A program-mode pane whose program ends, such as a dropped
  `ssh`, and a typed `exit` in a focused pane now leave a pane, a tab, or a window that needs a Cmd-W.
  Accepted: one Cmd-W is small next to keys reaching a shell the user did not choose. Background ends still close.
- **A script's `open-tab` puts a live shell under the user's keys in a dead pane** — likelihood: low, impact: high.
  `TerminalApplet.openTab` calls `focus()` unconditionally (`TerminalApplet.swift:521`), so type-ahead into a dead pane
  runs in the new shell. Mitigation: the bug `20261118-script-opened-tab-takes-keyboard` covers it. M1 has a check that
  needs that fix.
- **UTERM-026 is built against the old close rule** — likelihood: medium, impact: medium. Its M1 zoom check and M4
  popped-out check assume an ended pane closes. Mitigation: Impacts names both, and UTERM-035 M1 has a zoom check, so
  whichever lands second updates the other.

## Milestones

### M1: A focused pane's or tab's unchosen end stays in place

**Status:** NOT STARTED

- A test ends a focused pane's applet and checks that the pane stays and no neighbor's applet became first responder
- The user watches the repro from the bug in the running app and confirms the pane stays and their keys land nowhere
- A focused pane whose applet ends shows that its session ended and keeps its last output on screen, with one pane
  left as well as several
- Each of the three applet ends in the Motivation, and a typed `exit`, leaves a dead pane when the pane held focus
- An end in a pane without focus closes the pane as before, and moves no keyboard
- Keys typed into a dead pane reach no program, do not beep, and do not close the pane, including libghostty's
  any-key close after its child exits
- Cmd-W closes a dead pane without a question, and a Cmd-D typed before the end splits it
- Cmd-T and reopen-tab in a dead terminal pane behave as the dead-tab rule says
- A dead pane's pending permission requests can revive nothing
- The launcher's Escape closes its pane through the window's Close command, and the launcher no longer calls
  `appletDidExit`
- A close the user asks for still moves the keyboard to the neighbor
- A selected tab's end in the focused pane keeps the tab, dead, and arms no other tab, including after the palette's
  Escape
- A tab's end in a pane without focus closes the tab as before
- A user's tab close still focuses the newly selected tab
- The terminal reports its end through `appletDidExit` when its last live tab ends, whatever dead tabs remain
- A background tab's end closes the tab without asking the host
- The launcher's Escape closes the launcher's own pane, not the palette's target or another pane
- `focus()` on a dead REPL never puts Restart under keys already in flight
- A script's `send` to a dead pane fails with an error that says the session ended
- A dead pane announces its end to assistive technology
- A script's `open-tab` on a dead pane does not take the keyboard. This needs the fix of the bug
  `20261118-script-opened-tab-takes-keyboard`
- The `appletDidExit` doc comment and the applet lifecycle doc describe a pane that stays
- A dead pane brought back by Cmd-T, reopen-tab, a script's `open-tab`, or a REPL restart asks before a close kills
  its live work, with one pane or several
- A pane that comes back and ends again follows the pane rule again
- A script-opened tab in a dead pane gets no keys typed before it appeared, however its selection is decided
- A zoomed focused pane whose applet ends stays zoomed and dead, and no hidden pane takes focus
- `PaneStatusHost` answers the keep question from its own bound pane, and answers not to keep when its window is gone
  or its pane has left the tree

### M2: A window whose only pane ends stays open

**Status:** NOT STARTED

- A window whose only pane's applet ends stays open with that pane dead, and the key window does not change
- The user watches a popped-out window whose shell is ended by a background job and confirms it stays and no other
  window's pane takes keys
- Cmd-W on a dead only pane closes the window with no question, for each applet kind that can end
- Quitting does not ask about a dead window
- A dead pane or window restores live at relaunch from its description. Its dead tabs come back as fresh shells with
  the selected tab kept, and its ended state and last output are gone
- A pane whose start fails again at relaunch follows the pane rule, and a window holding only that pane stays open

## Decision Log

- 2026-11-19: moved the open calls out of the bug `20261116-ended-applet-close-gives-neighbor-keyboard` into this
  proposal. The bug is proposed and links here.
- 2026-11-19: a critic pass on the draft added option D to the first three questions and option E to the window
  question. It added the question on tab ends, and filed the bug `20261119-ended-tab-gives-next-tab-keyboard`. It
  moved the accepted cost of a click after `exit` under that question's options, since it presumed option A. It
  corrected the Motivation on the launcher, the REPL, and the cross-window claim.
- 2026-11-19: two re-check passes moved option-specific milestone checks into the options. They added the script
  readers of `focusedPane`, and said what each pane option does for an end in a pane without focus or a window that is
  not key. They gave window option A the pane held state's end rule. The loop ran its three passes without
  converging. At the user's request, a fourth pass re-checked the last two fixes and converged. It routed checks into
  pane option A and window option A.
- 2026-11-19: Review start: 2 milestones, 1 settled decision, 3 risks, no Live after lines or row gates, no out-of-scope
  statements; the user asked for an autonomous review of the four open questions, from commit "Record UTERM-035's
  converged fourth critic pass".
- 2026-11-19 (autonomous): a focused pane whose applet ends stays in place, inert, until the user closes it. A pane
  without focus closes as before. This changes UTERM-001's rule that a shell that exits closes its own pane.
- 2026-11-19 (autonomous): a close is chosen only through uniterm's Close command. Every applet end is unchosen,
  including `exit`. The launcher's Escape runs the Close command instead of reporting an end.
- 2026-11-19 (autonomous): a window whose only pane ends stays open with its dead pane. The key window does not change.
  The risk that the AppKit hand-off cannot be held is gone, since no window closes, so it was removed.
- 2026-11-19 (autonomous, addition): tab ends join this proposal. The host decides whether to keep an ended tab, by
  the same focused-pane test as the pane rule, through a new `AppletHost` member.
- 2026-11-19 (autonomous): the coherence review found that the tab decision, read literally, kept a background tab.
  Amended it so only the selected tab's end asks the host. It said before: "When a tab's session ends, the terminal
  asks its host whether to keep the tab." Added the open questions on a dead pane that comes back and on what a dead
  pane restores as, and the risk on a script's `open-tab`.
- 2026-11-19 (autonomous): the host keeps no record of an applet's end. `exitedApplets` is deleted, and closes ask the
  applet's own state. The applet owns its dead state, and a REPL whose helper left shows its ended view.
- 2026-11-19 (autonomous): a dead pane restores live from its description at relaunch. The layout format does not
  change.
- 2026-11-19 (autonomous): amended the pane decision's Cmd-W bullet, which named the `exitedApplets` path. It said
  before: "It closes without a question, through the existing path for an applet that already ended (`exitedApplets`,
  `MainWindowController.swift:167`)."
- 2026-11-19 (autonomous): the re-check pass converged. Routed three checks to M1: zoom under a dead pane, the
  wrapper host's keep answer, and the dependency on the script `open-tab` bug.
- 2026-11-19 (autonomous): risk review. Every risk carries a likelihood, an impact, and a mitigation or acceptance. No
  decision is a one-way door: the layout format does not change, and the contract changes stay inside one process.
  Added the risk that UTERM-026 shifts under this proposal.
- 2026-11-19 (autonomous): rewrote M1 and M2 for the settled decisions, and replaced the two risks about a held
  keyboard with risks about a dead pane. Accepted the risk that dead panes pile up.
- 2026-11-19 (autonomous): amended the Scope rationale to say a chosen close is one made through uniterm's own
  commands. It said before: "A user's close is a choice, and the neighbor taking keys is what they expect. The open
  question on `exit` decides whether "the user asked" means a uniterm close command or also a command typed into the
  program. Settling it rewords this rationale to match."
- 2026-11-19: Review gate: the user overturned the pane decision and every decision built on it. A pane that closes
  closes, the same way however it closes, and the neighbor takes the keyboard. No close is special-cased. Retracted the
  proposal. ADR-12 was rewritten without its close rule. The bugs `20261116-ended-applet-close-gives-neighbor-keyboard`
  and `20261119-ended-tab-gives-next-tab-keyboard` were removed, since both describe the intended behavior.

## References


- ADR-12: unchosen changes never move focus or arm input
- UTERM-001: close path and focus after a close
- UTERM-026: "Focus", which leaves this rule to the filed bug
