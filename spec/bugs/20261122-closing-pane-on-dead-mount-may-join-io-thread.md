# Closing a pane whose shell is stuck on a dead mount may freeze the app

**Status:** open
**Validation:** not reproduced; traced only. The wait is confirmed by reading libghostty's teardown (see Trace). That
a child on a dead mount ignores SIGHUP is assumed, and it needs a mount that stops answering to check.
**Estimate:** medium; one non-trivial design decision. Where the teardown stops waiting is open: free the surface off
the main thread, or patch libghostty so teardown does not wait on the child.

## Observed

A shell's directory sits on a network share that stops answering, and the shell or the IO thread is stuck on it. The
user closes the pane. The app may stop responding until the mount answers.

## Cause

- Freeing a surface calls `Surface.deinit` in the pinned libghostty, which stops and joins the IO thread on the
  caller's thread (`src/Surface.zig`, about lines 840-845). uniterm frees surfaces on the main thread
  (`Packages/UnitermKit/Sources/TerminalSurface/GhosttySurfaceView.swift`, about lines 196-202).
- The IO thread's stop path kills the child and may wait on it (`src/termio/Exec.zig`, about lines 1118-1170). Whether
  that wait can block on a child stuck in uninterruptible I/O on a dead mount is not traced.

## Trace

Read against the libghostty sources cached under `.cache/`, 2026-11-23.

- `Surface.deinit` notifies the IO thread to stop and then calls `io_thr.join()` on the caller's thread. The renderer
  thread is joined first.
- The IO thread's `threadExit` calls `subprocess.stop()`. That calls `killPid`, which loops. Each pass sends SIGHUP to
  the process group, then calls `waitpid` with `WNOHANG`, and sleeps 10 ms when the child has not exited. It leaves the
  loop only when the child is reaped. There is no deadline.
- A shell blocked in uninterruptible I/O on a dead mount does not act on SIGHUP until the call returns. The loop then
  never ends, and the join on the main thread never returns.
- `GhosttySurfaceView.close()` calls `ghostty_surface_free` on the main actor, so the main thread is the one stuck.

## Repro

Mount a network share, `cd` into it in a uniterm terminal, run a command that reads from it, then make the server
unreachable. Close the pane. Expected: the pane closes and the app stays responsive. Suspected actual: the app stops
responding until the mount times out.

## Fix

Needs a design call. Both candidates change what the user can observe. Freeing off the main thread needs libghostty's
free to be safe there, and leaves a parked thread and a lingering shell behind a closed pane. A patch drops the wait
and may leave a child unreaped. The candidates are freeing the surface off the main thread, if libghostty allows it, or a
libghostty patch whose teardown does not wait on the IO thread. UTERM-050 carries the related race at a session's start
as an accepted risk.
