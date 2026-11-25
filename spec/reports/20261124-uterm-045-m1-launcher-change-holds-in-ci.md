# UTERM-045 M1: the launcher change holds in CI

Started 2026-11-24, as a `/work-queue` run of `next 1`. The run took one row, UTERM-045 M1, and skipped none. Every
commit is in this repo, on `agent/petunia`.

## Run state

The row's base is "Schedule UTERM-056 through UTERM-059 in the queue", under the snip that follows it. The row has no
dependency and no `Live after` line.

| Milestone | Run status | Commits |
|---|---|---|
| UTERM-045 M1: The launcher change holds in CI | IN PROGRESS | See "Commits" |

M1 stays `IN PROGRESS`. The Rule section, the help text, and the recount are committed. The recount's count is not
met: 21 of 33 clean CI runs, so 12 remain. M2 stays gated on that count, and its row is not in this run.

## Commits

1. "Close a flaky entry only after enough clean CI runs", which carries M1's work, its review fix, and this report.

## UTERM-045 M1

### Plan

The milestone writes the closing rule into the `spec/flaky-tests.md` Rule section. It recounts the launcher scroll
test's clean CI runs from the GitHub Actions logs. It adds a note to the `make test-app` and `make test-app-select`
help that a local UI run needs the pointer and keyboard left alone.

### Best guesses from the plan

- When the recount meets the count, M1 is `DONE`. When it does not, the rule, the help text, and the recount still
  commit, and M1 stays `IN PROGRESS` with the remaining count in its notes. M2 stays gated. Rests on M1's bullet "M2
  does not start before the count is met".
- A launcher wheel failure with the pointer inside the list sends the proposal to the user, as M1 says. The run would
  then leave M1 `IN PROGRESS`.
- The recount script is not committed, since "Test code only" scopes the diff. The method and run IDs go here.
- Window boundaries are the first CI attempt whose head holds each fix. The recount's exact figures replace the
  review's approximate ones.

### First recount, rejected by the coordinator

The implementer's first report said the count was met: 21 clean runs since the pointer change, against a count of 12.
A grep of its own downloaded logs refuted it, so the work went back before review:

- Two jobs it listed as clean in the pointer window, 136893840758 and 137057165518, hold a launcher wheel failure and
  no pass line.
- Nine logs hold a launcher failure. Its windows held six. The entry's own 2026-11-21 burst, 5 of 10 runs, does not
  fit its window of 3 in 19.
- It said logs before 2026-11-19 had expired. They had not. The 2026-11-14 jobs simply did not run the test.
- It left out the window from the first sighting to "Wait for the launcher's last entry to come into view after a
  scroll".

The same pass also fixes the docs: commit SHAs in committed text, a Rule bullet wrapped at 72 columns, a launcher
entry marked Fixed while under Potential, and an As built block placed above the milestone's bullets.

### Second recount, sent back once more

The second pass found all nine failures. It gave N as 5 and the count as 15, with 21 clean runs. Two problems remained:

- It decided whether a head held a fix from the API's head SHA. A PR job tests `refs/pull/N/merge`, the PR head merged
  into its base. A fix in the base but not the head was missed. The third pass classifies by the tested merge.
- Its history began at the first CI run of the test, not at the first sighting, as "Which observed rate sets the
  count" says.

Doc fixes went back with it. The M1 bullet's note about "Poll UI test waits every quarter second instead of XCTest's
second" had been deleted, which weakened a check. The amendment used strikethrough and edited a past Decision Log entry.
The Rule section still named a CI job and shard. The moved launcher entry had been reflowed.

The coordinator briefly suspected the TSV paired logs with the wrong jobs. That was a misreading. `grep` in this shell
is a function that interleaves output across files. Read with line numbers, the rows match their logs.

### Third recount: windows verified, N backwards

The coordinator rechecked all 117 rows. Each row's window was taken from the PR head and base its log names. Every row
matched. The streak since the pointer change is 21 clean runs. Three jobs in that window never started the test: two
were cancelled during the build, and one earlier. They are neutral.

The windows, with the history starting at the first sighting on 2026-11-15 at 17:20Z:

| From | To | Failures | Attempts | Rate |
|---|---|---|---|---|
| First sighting | "Wait for the launcher's last entry to come into view after a scroll" | 2 | 22 | 0.091 |
| "Wait for the launcher's last entry to come into view after a scroll" | "Scroll the short launcher either way the machine's wheel goes" | 4 | 20 | 0.200 |
| "Scroll the short launcher either way the machine's wheel goes" | "Settle the pointer on the launcher list before the scroll test's wheels" | 3 | 19 | 0.158 |

The implementer took N from the smallest N, which is the highest rate. The rule takes it from the lowest rate. That is 2
in 22, so N is 11 and the count is 33. The proposal's own example, 3 in 15 as the lowest of three rates, reads the same
way. With a streak of 21, the count is not met. 12 clean runs remain. M1 stays `IN PROGRESS`, per the plan's best
guess, and the launcher entry stays under Potential.

The third pass also added amendment markers without changing the amended text. It also put a marker into a past
Decision Log entry. Both went back in the fourth pass, with the exact replacement text.

### Fourth and fifth passes

The fourth pass corrected N and the count, and set M1 back to `IN PROGRESS`. It reported two `app` jobs without logs,
and said their logs had expired. The coordinator looked both up through the API:

- 137357662896 was cancelled 2 minutes after it started, on 2026-11-22, before the test. It is neutral.
- 138998184972 was still running. It started at 2026-11-25T05:21Z. The recount's cutoff is therefore the last
  finished job, 138961135380, at 2026-11-25T04:05Z.

The coordinator also confirmed by ancestry that 5 of the 21 clean runs came before "Poll UI test waits every quarter
second instead of XCTest's second". Five logs have no `HEAD is now at` line. They are push jobs, so the API's head
SHA is the tested commit.

The fourth pass left the 2026-11-22 Decision Log entry edited, kept the old Status line, and repeated the expiry claim.
The fifth pass received the final text verbatim.

### Checks

- `make help`: the `test-app` and `test-app-select` lines render with the new note.
- `make check`, `make lint`: pass, after the last edit.
- `make test-ci`: pass, 76 fixture tests, after the Makefile edit. Later passes did not touch the Makefile.
- `proposals.py check`: no findings.
- No Swift changed, so no package or UI tests ran.

### Review

The reviewer found every M1 bullet met for the not-met outcome. It found the figures consistent across the proposal,
the As built block, the Decision Log, and the launcher entry. The amendments follow the format, and past Decision Log
entries are untouched. Its findings:

- Two Rule-section sentences each did two jobs with "and". Fixed: each was split into two sentences.

The `adr-impact` agent found no ADR touched. Three decisions were weighed: the pointer-and-keyboard note, the 3N
closing rule, and the test-level clean run. They are test process, not product architecture, so none passes the ADR
bar. No ADR candidate is recorded.

`proposals.py freeze` reported one hunk this run did not make, with origin `other`. It is a References line for
ADR-14 in UTERM-004, the implemented control-and-trust proposal. It is left for the user.

### Recount method

Each `app` job log of the `ci` workflow in `space-armada/uniterm`, from 2026-11-14 on, was fetched with `gh api`. The
recount read the launcher test's own `started`, `passed`, and `failed` lines in each log. A PR job tests the merge of
its head into its base, which the log's `HEAD is now at ... Merge <head> into <base>` line names. A fix counts as held
when it is an ancestor of either parent. A push job tests its head SHA. Jobs cancelled before the test started are
neutral. The windows and the streak follow the closing rule. The scripts and logs stayed in the session's temp
directory, uncommitted.
