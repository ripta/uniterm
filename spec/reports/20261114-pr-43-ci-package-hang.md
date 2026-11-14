# The package job hang on PR #43

Written 2026-11-14. This report records why CI's package job hung on PR #43, the Janet scripting batch of a landing run,
and how the cause was found. It also folds in what the landing run posted as comments on PRs #39, #41, and #43, so the
record lives in the repo and not only on GitHub.

The local machine was a 14-core Mac on macOS 26.6.2. CI ran on GitHub's `macos-26-arm64` image, version 20261102.0473.1,
with Xcode 26.6. GitHub documents three vCPUs for that runner. This session did not measure the runner's core count.

## Summary

The package job froze partway through the script tests on CI and ran into the job's 30-minute limit. It never froze
locally. The cause was two leaks in the test support code, not in the product:

1. A released `ReplProcess` left its pipe readability handlers in place. A pipe at its end stays readable, so each
   handler ran in a tight loop for the rest of the run. Every REPL test left one or two behind.
2. The listener's flood test sent from a `Task.detached`. Its last `send` blocked and outlived the disconnect, so it
   held a cooperative pool thread for the rest of the run.

By the time `ScriptRunAppQuitTests.testAHelperBusyInALoopStillExitsWhenTheConnectionCloses` ran, the spinning handlers
had taken the runner's CPU. The test's async work never finished. On a 14-core machine the same leaks cost about six
cores and nobody noticed.

The fix is the commit "Stop REPL test pipes and the listener flood from starving CI's threads". With it, the REPL tests
use 0.32 s of system CPU locally instead of 23.7 s, and CI's package job finishes.

The same PR also fixed a flake that failed four CI runs, in the commit "Assert that a folder watch notes no neighbor's
change, not one note per write".

| Finding | Status |
|---|---|
| The package job hung, not failed, on PR #43's original head | Confirmed: two runs reached the 30-minute limit |
| The REPL and reply reader tests were the stuck ones | Refuted: markers showed every one of them finishing |
| The test process was killed partway through | Refuted: a sample showed it alive and waiting |
| About 40 threads spun in `ReplProcess`'s readability handler | Confirmed by a CI stack sample |
| One cooperative thread was blocked in the listener flood test's `send` | Confirmed by the same sample |
| The spinning starved the stuck test's async work | Inferred from the sample and from the fix. Not observed directly |
| The leaks cost about six cores of system time locally | Confirmed: 23.7 s of system CPU in a 3.9 s run |

## Why it was hard to find

Three things hid the cause, and each one sent the search the wrong way.

XCTest writes its results to a pipe on CI, so its standard output is block-buffered. When the job was cancelled, the log
ended at whatever chunk had last been flushed. Each run's log seemed to stop at a different test. The real stuck test
sat in the unflushed buffer and never appeared.

The first two diagnostics ran inside the test process, on GCD. They were meant to sample the process after a timeout.
The threads they needed were the ones the leak had taken, so they never fired. That silence read as a process that had
died.

Locally the machine had cores to spare. The full package suite passed in about three minutes, and every narrowed run
passed too. The leak was there the whole time. It only showed as system CPU time, which no test checks.

## The investigation

Each step below is one CI run of the package job, in order. The run IDs are GitHub Actions run IDs.

### The original head, twice

Run 43583251466 hung. Its log stopped right after
`ScriptReplTests.testACtrlCByteStopsARunningFormWhenTheHelperIsTheTargetOfExecDashL` passed. The app job failed one
unrelated UI test, `DataViewerUITests.testCommandORoutesACSVFileToTheDataViewer`, whose go-to-folder sheet never closed.

A rerun of the failed jobs hung at exactly the same spot. The UI test passed. Two hangs at one spot ruled out a one-off
flake. In test order the next test was the `stty -isig` Ctrl-C test, and it became the first suspect. It passed 20 of 20
locally.

### Markers in the REPL tests

Run 43624926225 carried step markers on standard error, which is not buffered, and an in-process watchdog in
`ScriptReplTests`. Every REPL test, the ISIG one included, ran to the end. The log then showed
`ScriptReplyReaderTests.testTruncatedRepliesAreRefused` as the last test to start. The watchdog never fired, since no
REPL test ran long.

The reply reader became the second suspect. Its C reader checks bounds correctly, and the suite passed 20 of 20 alone
and 5 of 5 after the REPL tests.

### Markers in the reply reader tests

Run 43628144147 moved the watchdog into `ScriptReplyReaderTests`. None of its markers appeared. The run froze before
that suite started, earlier than the previous run. The freezing point moved between runs, and neither in-process
watchdog fired. That pointed at the process itself rather than at any one test.

A local check of a watchdog shell started outside the test process then went wrong in an instructive way. The test
process exited normally, but `swift test` kept waiting because the shell still held its output pipe. That looked like a
killed test process, and the next diagnostic was built to catch one.

### A watchdog outside the process

Run 43632022248 started a plain shell outside the test process and made the test process's standard output
line-buffered. The shell would report if the process ended, or sample it and abort it after eight minutes.

The process did not end. After eight minutes the shell sampled it. The line-buffered log named the stuck test:
`ScriptRunAppQuitTests.testAHelperBusyInALoopStillExitsWhenTheConnectionCloses`. The sample showed:

- The main thread waiting in `XCTWaiter` for the async test to finish.
- About 40 threads busy in `ReplProcess`'s readability handler at `ReplSupport.swift:78`, each on its own
  `NSFileHandle.fd_monitoring` queue.
- One cooperative pool thread blocked in `FramedSocket.sendOnce`, called from
  `ScriptListenerTests.testAPeerThatNeverReadsIsDisconnectedWhenItsQueueFills` at `ScriptListenerTests.swift:352`. That
  test had ended minutes earlier.

### The fix, then a flake

Run 43634578234 carried the fix and none of the diagnostics. The package job finished in about 11 minutes with no hang.
It failed one test, `FileWatcherTests.testChangesToOtherFilesInTheFolderDeliverNothing`, for the fourth time on CI.

Run 43635844226 carried the FileWatcher fix too. Every check passed, and PR #43 merged.

## The leaks

### Readability handlers that never cleared

`ReplProcess` reads its helper's output with a readability handler on each pipe. The handler captured `[weak self]` and
called `self?.take(...)`. Only `take` cleared the handler at the pipe's end. Once a test released its `ReplProcess`,
`self` was nil, so `take` never ran and the handler stayed. The pipe's end is permanently readable, so the handler fired
again at once, forever.

The fix reads and clears in a static function that does not need `self`, and appends to the buffers only when `self` is
still there. `deinit` also clears both handlers.

### A flood sender that held a pool thread

The listener test floods a raw peer with requests that it never reads, to prove the app disconnects it. The sender ran
in `Task.detached`, on the cooperative pool. Once the socket's buffer filled, `send` blocked. The app's disconnect did
not wake it, and neither did `shutdown`. The thread stayed blocked for the rest of the run.

The fix runs the sender on its own thread with a one-second send timeout, so a blocked send always fails and the loop
ends. The test waits for that thread to end before it closes the socket. That keeps the sender from writing to a
descriptor that was closed and reused, which an `await` on the task's result guarded against before.

### Measured locally

| Run of `ScriptReplTests` alone | Wall time | System CPU | Involuntary context switches |
|---|---|---|---|
| Before the fix | 3.9 s | 23.7 s | 44,292 |
| After the fix | 3.4 s | 0.32 s | 3,255 |

## The flakes logged along the way

The landing run met these in CI. Each is recorded in `spec/flaky-tests.md`. The notes here are what the PR comments said.

`LaunchOpenCoordinatorTests.testABatchOpensOnePanePerFileAndSummarizesFailures` failed once on PR #39, a branch that
changed only tab keys. It saw no folder panes open. Its `settle()` yields 50 times rather than waiting for the opens to
finish, so a slow runner can assert too early. A rerun with no change passed. It is still a potential flake.

`FindTests.testSearchingTheDecodedCapNeverBlocksTheMainThread` failed once on PR #41. It counted 3 main-actor turns
during the search, where it expects more than 100. The test took 6.6 s on CI and 1.2 s locally. The main actor was
likely busy laying out the four-million-character text. Counting turns measures time, not where the search runs. It is
still a potential flake.

`FileWatcherTests.testChangesToOtherFilesInTheFolderDeliverNothing` failed on PR #41 and three times on PR #43. It
expected exactly one note for the file's own write, and a write can make two. The coalescer merges them, so the watcher
was right. The test now drains the watcher's queue after the neighbor churn, requires that the churn made no note, and
then requires at least one note for the write. A watcher made to note every folder event fails it with three churn
notes. After the fix it passed 30 of 30 locally. It is now under "Fixed".

`DataViewerUITests.testCommandORoutesACSVFileToTheDataViewer` failed once on PR #43, in the same shared open-panel
helper as the `MapViewerUITests` potential flake. A rerun passed. It is not logged separately.

## What the investigation got wrong

The search took six CI rounds of up to 30 minutes each, and long waits between them. Some of that was the problem's
fault and some was not.

- A log's last test name was taken as the stuck test twice. Block-buffered output made that guess wrong both times.
- Diagnostics were built inside the process that was starving. They could not report on the starvation.
- A local run where the diagnostic itself held the pipe open was read as a killed test process. It cost one CI round.
- The landing run asked whether to keep diagnosing instead of diagnosing, and later stopped at its time budget. Both
  cost hours of waiting. A failing check on an open PR is the loop's job to fix.

The step that worked was to watch the process from outside it, with line-buffered output. It should have come first.

## Gaps in CI

These gaps turned one leak into a multi-hour hunt. Closing them is outside PR #43 and needs its own decision.

- No test has its own time limit, so one stuck test uses up the whole 30-minute job and never fails by name.
- Test output is block-buffered, so a cancelled job's log does not name the last test that ran.
- Nothing samples the test process before a timeout kills it, so a hang leaves no stack.
- No test notices leaked threads or handlers. The leak showed only as system CPU time, which nothing checks.
