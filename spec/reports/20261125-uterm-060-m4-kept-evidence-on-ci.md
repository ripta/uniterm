# UTERM-060 M4: the kept evidence on CI

Started 2026-11-25, as the second row of a `/work-queue` run of `next 2`. The run's state is in
[the UTERM-044 M2 report](20261125-uterm-044-m2-shards-run-on-ci.md). Every commit is in this repo, on
`agent/petunia`. All CI times below are UTC.

The row's base is "Move UTERM-044 M2's finished row to history". The row depends on UTERM-060 M3, which is DONE. It
has no `Live after` line.

## UTERM-060 M4

### Plan

- No shard has failed on CI since UTERM-060 M1 landed. No run has uploaded an artifact. The run cannot push or rerun
  CI.
- M4 proves "CI's upload path matches the kept log" statically. It records that the passing runs kept nothing.
- The tap bullet does not apply, since no tap code ships.
- The three bullets that need a failed shard move into a new M6, "A failed CI shard keeps its evidence", by
  amendment.

### What was done

- M4 is `DONE`. Its As built block traces one path from start to end, and the path agrees everywhere:
  - The Makefile's `test-app-shard` sets `UNITERM_UI_KEPT_LOG` to
    `.build/DerivedData-test/ui-test-kept-log-shard-$(SHARD).txt.gz`.
  - `run-ui-tests.sh` passes that path to `collect-ui-test-log.sh`.
  - The workflow's follow-up collection step writes the same file for `strategy.job-index`.
  - The upload glob `ui-test-kept-log-shard-*.txt.gz` matches it.
  - CI passes `strategy.job-index` as `SHARD`.
  - The start-time file lands where the follow-up step reads it.
- Run 45749818748 predates the collection step. Runs 45752629043, 45755641410, and 45760228289 skipped both the
  collection and the upload on every shard. The main pushes skipped `app`. All eight artifact lists are empty.
- The tap bullet stays in M4. Its As built block says it does not apply, and a Decision Log entry records why.
- The new M6 holds three bullets, moved verbatim: the failed `app` job's upload, the CI `log show` time and the upload
  at the time limit, and each failing shard's own kept log. A Decision Log entry quotes them.
- The three Risks that named M4 for those checks now name M6. The queue gains `UTERM-060 M6` after `UTERM-060 M5`.

### Checks

- `proposals.py check`: only the expected "finished row moves to history" finding.
- `proposals.py freeze`: only the UTERM-004 hunk with origin `other`.
- `make lint` and `make check`: pass.

### Best guesses

- The failure in run 45755641410's first attempt was in `package`, not a shard. It does not count as a failed shard
  for M6.
- M4 keeps the static path proof. A real upload from a failed shard is M6's to prove.

### Review

- adr-impact: no ADR touched. No uncovered decision.
- The reviewer checked the path proof against the Makefile, the scripts, and the workflow, and the run claims against
  the evidence. Both held. It had three wording findings, all fixed:
  - The path bullets listed files and steps, which "As Built" leaves out. They are now two sentences. They also say that
    the upload's `if-no-files-found: ignore` would let a mismatch pass silently, so M6 holds the only live proof.
  - The run-count bullet contradicted itself about run 45749818748. It now says eight runs were inspected, and that one
    predates the collection step.
  - The tap bullet's note now says plainly that the bullet does not apply.
- Checks after the fixes: `make lint` passes. `proposals.py check` shows only the expected history move.
