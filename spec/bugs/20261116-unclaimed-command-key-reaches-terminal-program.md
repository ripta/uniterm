# A Command key that no menu item takes reaches the terminal program, against the surface's own comment

**Status:** open, not reproduced, traced only
**Validation:** not confirmed; nothing was run. The uniterm side is traced through the code. Whether a program sees the
key depends on libghostty's kitty keyboard encoder, which was read in a Ghostty checkout that is not the pinned commit.
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

Not run. Expected repro:

1. In a uniterm terminal, run a program that enables the kitty keyboard protocol with `CSI > 1 u` and prints what it
   reads, such as `kitten show-key -m kitty`.
2. Press Cmd-J, which no uniterm or terminal item takes.
3. Expected, per the comment: nothing reaches the program. Actual, per the trace: the program reads a CSI u sequence
   with the super bit set.

Also check what a legacy-mode program reads for the same key, since `keyDown` passes the key's text.

## Fix

The fix needs a design call on what an unclaimed Command key is in a terminal:

- Not terminal input. The surface drops every super-modified press, repeat, release, and modifier change that no menu
  item takes. The comment becomes true. Programs that map Command keys through the kitty protocol lose them. UTERM-031
  weighs this as the ground for controller Command keys in terminals.
- Terminal input. The surface keeps forwarding, and the comment is corrected to say so. Then no Command key is safe for
  a controller to take from a terminal.
