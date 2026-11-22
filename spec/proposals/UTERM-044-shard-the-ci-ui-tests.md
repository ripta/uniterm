# UTERM-044: Shard CI's UI Tests Across macOS Runners

**Status:** draft
**Created:** 2026-11-21
**Updated:** 2026-11-21

## Summary

CI's `app` job runs every UI test on one macOS runner. This proposal splits the UI tests into shards that run side by
side on separate runners. A full run gets shorter, and so does the rerun after a flaky failure, since only the failed
shard reruns.

## Motivation

The `app` job sets the length of every CI run. In the first `app` run of #90, the job started at 04:39:46 and ended at
05:15:29. About 5 minutes went to the build and the helper sandbox checks before the first UI test. The 176 UI tests in
33 classes then ran for 1831 seconds, about 30.5 minutes, one class after another.

A flaky UI test costs a full `app` run again. `gh run rerun --failed` reruns the whole job. On 2026-11-21 the launcher
scroll flake alone cost #83, #87, and #90 one or two extra 35-minute runs each. A landing run lands its batches one
after another, so each extra run delays every batch behind it.

The repository is public, and the space-armada organization is on GitHub's Free plan. Standard GitHub-hosted runners,
macOS included, are free and unlimited for public repositories. The constraint is concurrency: the Free plan runs at most
5 macOS jobs at once across the organization, out of 20 jobs in total. A CI run already uses 3 macOS jobs: `package`,
`app`, and `ghostty-offline`.

## Design Decisions (Settled)

### Local runs keep the whole suite

Decision: `make test-app` and `make ci-app` keep running every UI test. Sharding is a property of the CI workflow only.

Rationale: a local run is how a developer proves a change before pushing. A shard there would add a way to skip tests
by accident.

### One required check

Decision: the `ci` job stays the only required check. `scripts/ci-result.sh` learns every shard's result and fails
unless each one matches the build decision, as it does for the three macOS jobs today.

Rationale: branch protection names `ci`. Keeping one aggregate check means a new shard count never touches the
repository's settings.

### Every skip covers every shard

Decision: a documentation-only change skips every shard, as it skips the `app` job today. A tree that a merged PR
already passed skips every shard too, once that skip is on `main`. The commit "Skip main's package and app jobs when a
merged PR passed the same tree" adds it for the `package` and `app` jobs, and has not landed yet.

### The helper sandbox checks run once

Decision: `make test-helper-sandbox` runs in exactly one CI job, never split and never repeated. That job runs it against
the signed app, as `make ci-app` does today.

Rationale: ADR-10 makes the helper sandbox checks the proof that each helper is sandboxed and the app is not. A split
that dropped them, or ran them in a job without the signed app, would weaken that proof.

## Design Decisions (Open)

### How many shards

- **Two.** A run uses 4 macOS jobs. One other run can start beside it only after one of its jobs ends. The UI tests take
  about 15 minutes per shard, plus each shard's build.
- **Three.** A run uses all 5 macOS jobs, so any second run at the same time queues. The UI tests take about 10 minutes
  per shard, plus each shard's build.

A fix PR next to a batch PR, as on 2026-11-21, is the common case for two runs at once. Pushes to `main` add a third.

### How the tests are divided

- **Fixed class lists.** Each shard names its test classes with `-only-testing`. Easy to read. Shards drift out of
  balance as classes grow.
- **Xcode test plans.** One plan per shard. The same drift, kept in Xcode's format.
- **By measured duration.** A script assigns classes to shards from recorded durations. Balanced, but it needs a place
  to keep the durations and a fallback when one is missing.

### Build once or build per shard

- **Build per shard.** Each shard builds the app, about 5 minutes. Simple, and each shard stands alone.
- **Build once.** One job runs `build-for-testing` and uploads the products. Each shard downloads them and runs
  `test-without-building`. Saves the repeated build. Adds an artifact upload and download, and a job every shard waits
  for.

### How a new test class finds a shard

A class that no shard names would silently stop running in CI. Candidates:

- A check in `make test-ci` that every UI test class appears in exactly one shard.
- A last shard that runs every class the others do not name, with `-skip-testing` for the rest.

## Risks

- **A test class runs in no shard** — likelihood: medium, impact: high.
  Mitigation: whichever answer the open question above picks, a check fails CI when a class is missing.
- **Runs queue behind the concurrency cap** — likelihood: medium, impact: medium.
  Mitigation: the shard count is chosen against the cap. A queued run is slower, not wrong.
- **The Free plan's limits change** — likelihood: low, impact: medium.
  Mitigation: shards are a workflow setting. Reverting the workflow returns to one `app` job.
- **Splitting moves a flake rather than fixing it** — likelihood: high, impact: low.
  Accepted: a shorter rerun is the goal. Fixing flakes is UTERM-045 and UTERM-046.

## Milestones

### M1: Shard the app job

**Status:** NOT STARTED

- Every UI test class runs in exactly one shard, and a check fails CI when one does not
- The helper sandbox checks run once per CI run, against the signed app
- `ci` fails when any shard fails, and passes only when every shard matches the build decision
- A documentation-only change and an already-tested tree skip every shard
- The measured length of a full CI run, and of a one-shard rerun, are recorded in the As built block

## Decision Log

- 2026-11-21: Filed after a landing run that lost several hours to UI flake reruns. The user chose to pursue sharding,
  and asked whether the Free plan allows it. The repository is public, so macOS minutes are free, and the cap of 5
  concurrent macOS jobs is the constraint.

## References

- ADR-10: App unsandboxed, helpers sandboxed
- `spec/flaky-tests.md`
- [GitHub Actions limits](https://docs.github.com/en/actions/reference/limits)
