# A Command key that no menu item takes reaches the terminal program, against the surface's own comment

**Status:** fixed 2026-11-19
**Fixed:** 2026-11-19. An unclaimed Command key is terminal input, and the comment now says so.
**Found:** 2026-11-16, while reviewing UTERM-031

## Observed

The terminal surface's doc comment says a Command key that no menu item takes "is not terminal input". The code sends
that key to libghostty anyway, with the super modifier set. A program that turns on the kitty keyboard protocol, such as
an editor that maps `<D-s>`, can then receive it. No spec states either rule. UTERM-013 and ADR-04 say nothing about
where an unmatched Command key goes, and no test pins it.

The comment also contradicts itself. Its first paragraph says such a key "comes back as a plain key down", which is
what the code does.

## Cause

1. `MainWindow.performKeyEquivalent` returns false when no menu item matches (`WindowKit/MainWindow.swift:90-121`).
2. `GhosttySurfaceView.performKeyEquivalent` returns false for every Command key except two Control rewrites
   (`TerminalSurface/GhosttySurfaceView.swift:711-754`).
3. AppKit then calls `keyDown`, which sends the key through `sendKey` to `ghostty_surface_key` with no modifier filter
   (`GhosttySurfaceView.swift:756`, `:893-920`). `mods()` maps Command to `GHOSTTY_MODS_SUPER` (`:946`). `keyUp` and
   `flagsChanged` forward it too (`:816-828`).
4. Ghostty's kitty encoder carries super into the CSI u modifier bits (`src/input/KeyEncoder.zig` `KittyMods`).

## Repro

Reproduced 2026-11-18 with a throwaway package test, since deleted. It ran a program in a session with
`sh -c 'printf "\033[>1u"; stty raw -echo min 0 time 30; dd bs=64 count=1 of=FILE'`, then called
`performKeyEquivalent` and `keyDown` with Command-J (keyCode 38). `performKeyEquivalent` returned false. With the kitty
protocol on, the program read `ESC [ 1 0 6 ; 9 u`, which is `j` with the super bit. In legacy mode it read nothing.
So the key reaches a kitty-mode program and not a legacy one. Key-up was not exercised.

Expected repro in the app:

1. In a uniterm terminal, run a program that enables the kitty keyboard protocol with `CSI > 1 u` and prints what it
   reads, such as `kitten show-key -m kitty`.
2. Press Cmd-J, which no uniterm or terminal item takes.
3. Expected, per the comment: nothing reaches the program. Actual, per the trace: the program reads a CSI u sequence
   with the super bit set.

Legacy mode was checked above. It reads nothing for Command-J.

## Fix

The fix needed a design call on what an unclaimed Command key is in a terminal. Two answers were weighed:

- Not terminal input. The surface would drop every super-modified press, repeat, release, and modifier change that no
  menu item takes. Programs that map Command keys through the kitty protocol would lose them.
- Terminal input. The surface keeps forwarding, and the comment is corrected to say so.

The user chose terminal input on 2026-11-19. Forwarding is the behavior kitty-protocol programs already get, and it
matches Ghostty upstream. The menu still sees every Command key first.

An earlier draft of this report said forwarding leaves no Command key safe for a controller to take from a terminal.
That came from UTERM-031's original design and no longer holds. UTERM-031 was retracted on 2026-11-16. Under its
routing, no key reaches a controller from a pane that does not opt in, and a terminal never opts in. A controller still
reacts through uniterm's commands, from an opted-in slide pane, and in its own terminal as the foreground program.
Forwarding changes none of these.

The code was already right. The fix is to the comment and the proof:

- `TerminalSurface/GhosttySurfaceView.swift`: the `performKeyEquivalent` doc comment no longer says an unclaimed
  Command key is not terminal input. It now says uniterm leaves out only upstream's Command-period replay. The plain
  key down reaches the program with the super modifier.
- `TerminalSessionIntegrationTests.testAnUnclaimedCommandKeyReachesAKittyProgramAndNotALegacyOne` pins the contract.
  The surface declines Command-J in `performKeyEquivalent`. A kitty-protocol program then reads `ESC [ 106 ; 9 u`, and a
  legacy program reads nothing.

The test pins the fix, not the bug. The bug was a comment that disagreed with the code, so no test could fail on it.
The test was checked against a mutation instead. With `keyDown` returning early for Command keys, the kitty case failed
with an empty read.
