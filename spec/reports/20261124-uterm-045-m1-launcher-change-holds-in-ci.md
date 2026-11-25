# UTERM-045 M1: the launcher change holds in CI

Started 2026-11-24, as a `/work-queue` run of `next 1`. The run took one row, UTERM-045 M1, and skipped none. Every
commit is in this repo, on `agent/petunia`.

## Run state

The row's base is "Schedule UTERM-056 through UTERM-059 in the queue", under the snip that follows it. The row has no
dependency and no `Live after` line.

| Milestone | Run status | Commits |
|---|---|---|
| UTERM-045 M1: The launcher change holds in CI | IN PROGRESS | See "Commits" |

A second `/work-queue` run on 2026-11-24 recounted from the first run's cutoff. The status is unchanged.

M1 stays `IN PROGRESS`. The Rule section, the help text, and the recount are committed. The recount's count is not
met: 22 of 33 clean CI runs, so 11 remain. M2 stays gated on that count, and its row is not in this run.

### Third run: `next 7`, started 2026-11-25

A third `/work-queue` run took seven rows. This report carries that run's state, and the other rows' reports link
here. The run's base is the snip after "Schedule UTERM-060 M1-M3 after UTERM-044 M1". The branch already sat on
`upstream/main`, so no rebase ran. No redundant snip was found.

| Row | Milestone | Run status | Report |
|---|---|---|---|
| UTERM-045 M1 | M1: The closing rule and the launcher recount | DONE | this report |
| UTERM-044 M1 | M1: Shard the app job | DONE | [report](20261125-uterm-044-m1-shard-the-app-job.md) |
| UTERM-060 M1-M3 | M1: A failed run keeps where its input went | DONE | [report](20261125-uterm-060-m1-m3-keep-input-evidence.md) |
| | M2: The app records the input it receives | DONE | [report](20261125-uterm-060-m1-m3-keep-input-evidence.md) |
| | M3: The flaky entries say what to look for | DONE | [report](20261125-uterm-060-m1-m3-keep-input-evidence.md) |
| UTERM-046 M1-M2 | M1: The browser hung-process tests | DONE | [report](20261125-uterm-046-m1-m2-deterministic-package-test-flakes.md) |
| | M2: The script fixture's helper exit | QUEUED | |
| UTERM-046 M4 | M4: The product's kills signal by audit token | QUEUED | |
| UTERM-046 M3 | M3: Every test signal goes through a guarded sender | QUEUED | |
| UTERM-045 M2 | M2: One way to send a wheel | HELD | |

UTERM-045 M2 is held. M1's clean count moves to a new milestone, UTERM-045 M3, and M2 waits on it. The count stood at
22 of 33 through 2026-11-25T05:48Z.

The run's plan splits each CI-only check into a new milestone by amendment, since the run never pushes:

- UTERM-045 M3 takes M1's clean count.
- UTERM-044 M2 takes the shards' proof on a real runner and their measured lengths.
- UTERM-060 M4 takes M1's CI upload checks and M2's grant check on the CI image.

UTERM-060 M2 split once more. No run of the shortcut test stalled, so its two Cmd-T checks moved to a new UTERM-060 M5,
"The recorder sees a Cmd-T stall". M5 waits for a stall with recording on.

Step 0 removed one uncommitted `.cg.yaml` rule that named an absolute `/Users/...` path. The file then matched `HEAD`.

## Commits

1. "Close a flaky entry only after enough clean CI runs", which carries M1's work, its review fix, and this report.
2. "Record a 22nd clean launcher run toward UTERM-045 M1's count", which carries the second run's recount and this
   report's amendment.

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

### Row and final review

The run had one row, so the row review and the final review covered the same range, from the base to "Close a flaky
entry only after enough clean CI runs". One reviewer pass served as both, with an ADR review. It found no findings.
It confirmed the figures agree in all six places they appear. It also confirmed that a later session knows to count
12 more clean runs from 2026-11-25T04:05Z. The `adr-impact` agent again found no ADR touched and no candidate.

M1 is not finished, so the row stays in `queue.md`, and UTERM-045 stays `accepted`. A later `/work-queue` run picks the
row up again once CI has run the launcher test enough times. That run recounts from the cutoff above.

### Recount method

Each `app` job log of the `ci` workflow in `space-armada/uniterm`, from 2026-11-14 on, was fetched with `gh api`. The
recount read the launcher test's own `started`, `passed`, and `failed` lines in each log. A PR job tests the merge of
its head into its base, which the log's `HEAD is now at ... Merge <head> into <base>` line names. A fix counts as held
when it is an ancestor of either parent. A push job tests its head SHA. Jobs cancelled before the test started are
neutral. The windows and the streak follow the closing rule. The scripts and logs stayed in the session's temp
directory, uncommitted.

## Second run: recount

The first run's cutoff was job 138961135380, which finished at 2026-11-25T04:05Z. During planning, the coordinator found
one `app` job that finished after it: 138998184972, which finished at 2026-11-25T05:48Z. The launcher test passed there.
The implementer re-listed the `ci` runs and found no other. Five other runs skipped the `app` job, so they are neutral.

The tested tree was a PR merge. Its head holds "Settle the pointer on the launcher list before the scroll test's
wheels", by ancestry. The new figures are a streak of 22, 11 runs left, and a cutoff of 2026-11-25T05:48Z. The recount
used the method in "Recount method" above.

### Checks and review

- Checks: `make check`, `make lint`, `proposals.py check` pass. No Swift changed, so no package or UI tests ran.
- Review: the reviewer confirmed the figures agree in every place. It found five prose findings, all fixed. Three were
  parenthetical asides and a stacked sentence in the new Decision Log entry and this report. The other was a Method
  subsection that repeated "Recount method".
- The coordinator also sent back the report's wording. It named the pointer change as "the settlement commit" and
  credited the whole recount to the coordinator. It also said the coordinator found the first run's cutoff job. All
  three were fixed.
- `adr-impact` found no ADR touched and no uncovered decision. No ADR candidate is recorded.
- `proposals.py freeze` reported the same UTERM-004 ADR-14 References hunk as the first run, with origin `other`. It is
  left for the user.
- Row and final review: the run has one milestone commit, so this review served as the row and final review. It
  included an ADR review. The row stays in `queue.md`, and UTERM-045 stays `accepted`, since M1's count is not met.

## Third run: recount and split

### Recount

Three `ci` runs finished after the 2026-11-25T05:48Z cutoff:

- Run 259, job 139008918170, finished 2026-11-25T05:49:46Z. It skipped the `app` job, so it is neutral.
- Run 260, job 139036554483, finished 2026-11-25T07:27:48Z. The launcher test passed. The tested tree was a PR merge,
  and both parents hold "Settle the pointer on the launcher list before the scroll test's wheels".
- Run 261, job 139049211184, finished 2026-11-25T07:29:27Z. It skipped the `app` job, so it is neutral.

The streak is 23 clean runs through 2026-11-25T07:27:48Z, so 10 remain. The new cutoff is job 139036554483. No run
spans UTERM-044's landing, since that row has not landed. The recount used the method in "Recount method".

### Split

The count is not met, so the plan's split ran. M1 is renamed "The closing rule and the launcher recount", and it is
`DONE`. Its title read "The launcher change holds in CI". The new M3, "The launcher count is met", takes four bullets
verbatim:

- the consecutive-clean-runs bullet, with its 33-run figure and its 2026-11-24 amendment marker
- the launcher entry staying under Potential
- the CI failure with the pointer inside the list
- the CI failure with a timed-out settle

M1 keeps every bullet about the Rule section, the help text, and how the recount reads attempts. M3 is `IN PROGRESS`,
since each recount advances it. The Risks entry "The launcher hypothesis is wrong" now names M3's count. The queue
gains a `UTERM-045 M3` row before `UTERM-045 M2`, and M2 now depends on `UTERM-045 M3, UTERM-044 M1`.

Best guess: the split itself. The approved plan rests it on the `/work-queue` rule that a check the run cannot perform,
when the proposal makes it a condition of `DONE`, splits into a new milestone by amendment. If it is wrong, M1 goes
back to `IN PROGRESS` with M3's bullets. UTERM-046 M1-M2 would then wait on M1 again.

### Checks

- `make check` and `make lint` pass.
- `proposals.py check` reports only that the finished M1 row moves to `history.md`. The row's finishing commit does
  that.
- No Swift changed, so no package or UI tests ran.

### Review

- The reviewer found that M1's queue note still said "its count gates M2". Fixed.
- The coordinator sent back five more findings, each checked against the diff, and all were fixed:
  - The moved count bullet had dropped ", as built," and its 2026-11-24 marker. It is now verbatim.
  - The split entry misquoted a moved bullet. It now names the bullets without quoting them.
  - M1's title named the work M3 now holds, so M1 was renamed.
  - M3 sat before M2, so it moved after M2.
  - M1's As built block carried an amendment marker it does not need. The marker was removed.
- `adr-impact` found that no ADR covers this diff, and no uncovered decision.
- `proposals.py freeze` reported the same UTERM-004 ADR-14 References hunk as the earlier runs, with origin `other`.
  It is left for the user.
- Row review: the row has one milestone commit, which the milestone review covered, so that pass served as the row
  review.
