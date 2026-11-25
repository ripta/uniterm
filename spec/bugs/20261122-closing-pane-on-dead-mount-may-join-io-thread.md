# Closing a pane whose shell is stuck on a dead mount may freeze the app

**Status:** open
**Validation:** not confirmed; suspected from reading libghostty's teardown during the UTERM-050 review. It needs a
mount that stops answering.

## Observed

A shell's directory sits on a network share that stops answering, and the shell or the IO thread is stuck on it. The
user closes the pane. The app may stop responding until the mount answers.

## Cause

- Freeing a surface calls `Surface.deinit` in the pinned libghostty, which stops and joins the IO thread on the
  caller's thread (`src/Surface.zig`, about lines 840-845). uniterm frees surfaces on the main thread
  (`Packages/UnitermKit/Sources/TerminalSurface/GhosttySurfaceView.swift`, about lines 196-202).
- The IO thread's stop path kills the child and may wait on it (`src/termio/Exec.zig`, about lines 1118-1170). Whether
  that wait can block on a child stuck in uninterruptible I/O on a dead mount is not traced.

## Repro

Mount a network share, `cd` into it in a uniterm terminal, run a command that reads from it, then make the server
unreachable. Close the pane. Expected: the pane closes and the app stays responsive. Suspected actual: the app stops
responding until the mount times out.

## Fix

Needs a design call. The candidates are freeing the surface off the main thread, if libghostty allows it, or a
libghostty patch whose teardown does not wait on the IO thread. UTERM-050 carries the related race at a session's start
as an accepted risk.
