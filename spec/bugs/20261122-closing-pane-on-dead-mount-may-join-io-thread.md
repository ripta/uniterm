# Closing a pane whose shell is stuck on a dead mount may freeze the app

**Status:** not-reproducible
**Validation:** `TerminalSessionIntegrationTests.testCloseReturnsWhenTheChildIgnoresSIGHUP` runs `trap '' HUP; sleep
1000` in a shell and closes the session. `close()` returned at once, and the test passed in 0.56 s on 2026-11-23. The
child libghostty reaps is `login(1)`, not the shell. A dead mount was not set up, so the test shows the chain breaks
at `login`, not the mount case itself.

## Observed

A shell's directory sits on a network share that stops answering, and the shell or the IO thread is stuck on it. The
user closes the pane. The app may stop responding until the mount answers.

## Cause

Refuted. See "Triage 2026-11-23" below. The text under this heading and under Trace is the original report.

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

## Triage 2026-11-23

The libghostty part of the trace still matches the pinned v1.4.0 source. `killPid` in `src/termio/Exec.zig`, about lines
1177-1216, loops with no deadline until `waitpid(pid, WNOHANG)` reaps the child. `GhosttySurfaceView.close()` still calls
`ghostty_surface_free` on the main actor.

The step that fails is "the shell does not act on SIGHUP, so the loop never ends". The `pid` that loop waits on is the
surface's direct child. On macOS that is `login(1)`, in shell mode and in program mode alike.
`testProcessStartedEventReportsTheDirectChild` and its program-mode twin pin that. `login` sits in `wait4` on the
shell, which a signal interrupts. It does no I/O on the shell's directory, so a dead mount cannot hold it. On SIGHUP it
exits, `waitpid` reaps it, the IO thread ends, and the join returns. The shell stays stuck on the mount, as an orphan.
That matches what happens to `nohup` work when any terminal closes.

`testCloseReturnsWhenTheChildIgnoresSIGHUP` has been in the suite since the terminal applet first landed. Its shell
ignores SIGHUP, as the report assumes a stuck shell would. The close returns at once. The test kills the tree after 8 s
so that a regression fails without hanging the suite. It is the regression guard for this report.

What stays unproved: a `login` that is itself stuck. That would need `login` to block on file system I/O after it starts
the shell, and nothing found here shows that it does.
