# UTERM-046 M4: the product's kills signal by audit token

Started 2026-11-25, as the fifth row of a `/work-queue` run of `next 7`. The run's state is in
[the UTERM-045 M1 report](20261124-uterm-045-m1-launcher-change-holds-in-ci.md). Every commit is in this repo, on
`agent/petunia`.

The row's base is "Move UTERM-046 M1-M2's finished row to history". The row has no dependency, and it waits only for
the earlier row of its proposal, UTERM-046 M1-M2, which this run finished. It lands before UTERM-046 M3, since M3's
sender wraps M4's guarded call. No milestone has a `Live after` line.

## Best guesses from the plan

- Implementers run the touched package test classes. The coordinator runs a full `make test-package` and the helper
  sandbox checks before the commit, since M4 changes the product's kill paths.
- Every command runs through `cg_run`. A Bash call that auto mode denies stalls the run until the user steps in.

## UTERM-046 M4

### What was built

- `ProcessInspection` gains a microsecond start-time reader and one guarded signal call. The call reads a fresh audit
  token, then reads the start time again. It signals by the token when the start time matches. With no token, it
  confirms the start time and signals by pid.
- After a token signal returns ESRCH, the call retries with a fresh token while the start time still matches, up to
  three tries. It never falls back to the pid after ESRCH. It refuses pid 1 and below, and the caller's own pid.
- The task name port is released on every path. The token stays inside `ProcessInspection`, and `FileRouting`'s
  `AuditToken` is unchanged.
- The browser's hung-page kill reads the content process's identity at the tab's close, and signals through the call
  with that identity. It keeps its path check, and returns false when the process is gone, unreached, or refused.
- The REPL helper's reaper records the helper's microsecond start time, and its live kill goes through the call.
- Both kills log each pid-path kill, and log an error for unreached and refused. They never log for a gone process.
- In the test host, both the browser's content process and the REPL helper took the token path.

### Checks

- Each guard was proven by mutation, then restored:
  - a start time compared to the second
  - a pid fallback after ESRCH
  - a missing port release
  - no refusals
  - a zombie read as live
  - two tries, or one
  - `kill` without its path check
  - the watch reading the identity at the fire
  - each kill signalling the stored pid alone
  - a missing pid-path log
- M4 pins the fix, not the bug, since no test can force a pid's reuse.
- The coordinator ran the full `make test-package` twice, before and after the review fixes. Each ran 3264 tests,
  with 10 skipped and no failures. The last ran at about 01:38Z. `make test-helper-sandbox` passed against the built
  app.
- `make fmt-check`, `make lint`, `make check`, `make build`: pass.

### Implementer findings

- The token signal answers EINVAL for signal 0. So a signal-0 probe through the call reports unreached with a token.
  With no token, the pid path sends it. UTERM-046 M3's sender already exempts signal-0 probes.
- A live reaper whose peer is its own process is now refused, where it used to send SIGKILL to itself.
- The watch now arms no bound when it cannot read the content process's identity at the close.

### Review

The reviewer found no plan gap, and no security or stability defect. It traced the start-time race, the ESRCH retry
bound, the port release, and the errno mapping, and found each sound. Its findings:

- The signal-0 claim held only on the token path. The doc and the proposal now say what shipped.
- M4's As built block listed symbols, which the Decision Log entry already names. It now points to the entry.
- A marker read "Amended 2026-11-25, twice". It now uses the single-marker form.
- The two `OSLogStore` tests did not say what they need, or what they cost. Their docs now say both. Each also read
  the store once, right after logging, and Apple documents no guarantee that such a read sees the entry. Twenty probe
  reads all found it, but each test now reads until its last entry appears or 10 s pass, then asserts.
- Three comments packed several ideas into one block.

This review also served as the row review, since the row holds one milestone.

`adr-impact` found M4 consistent with ADR-05, ADR-07, ADR-08, and ADR-10, and no uncovered decision. The new calls on
the main thread are local kernel calls, capped at three tries. `proposals.py freeze` reported only the UTERM-004
ADR-14 hunk with origin `other`.

### For the user

- `ProcessInspection.signal` with signal 0 behaves differently on the two paths. With a token it reports unreached,
  and without one the pid path sends it. A guard that refuses any signal number at or below 0 would make it behave the
  same way on both paths. It would be a contract change, so the run leaves it as built.
- The two `OSLogStore` tests read the process's own log store. They pass through cg, and a sandboxed read found the
  store empty. Whether CI's runner can read it is unknown until a pushed run. If it cannot, those tests fail there.
