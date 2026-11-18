# UTERM-006 M4: image viewer control work-queue run

Started 2026-11-17. This report covers a `/work-queue` run with no arguments, which means `next 1`. The run takes one
row, `UTERM-006 M4`, from `spec/proposals/UTERM-006-image-viewer-applet.md`. M4 lets a controller drive an image viewer
pane: show a file or folder, step through it, set zoom, and learn what is shown. The specs live in the code repo, so
every commit below is in this repo, on the `agent/petunia` branch.

## Run state

The run's base and the row's base are both the commit "8< --- snip ---" that follows "Join a driver's stderr line that
arrives in pieces, and show a lone partial line after a pause".

The row's one dependency, UTERM-015 M4, is met. No milestone carries a `Live after` line. Nothing is held, blocked, or
skipped, and no work is stashed.

| Milestone | Run status | Commits |
|---|---|---|
| UTERM-006 M4: Control | DONE | See "Commits" under M4 |

## The user's choice in the plan

M4's first check says an exec driver can `show` a path and step through it. The shipped code gives an exec driver no
path-reading power: it brings no opens and holds no read scope, per UTERM-015's decision 8. The user chose to split
exec reads out. M4 builds full remote control, plus exec `zoom` and a `shown` that withholds the path, index, and count
for a driver. A new M5, added by amendment, holds the exec `show` and stepping checks and waits on a driver path-read
power. That power goes into `spec/ideas.md` as an idea for a proposal.

## Run-level best guesses

1. A remote caller learns what is shown through the reply to `wait` on a handle. Remote callers have no event channel.
   This rests on ADR-11 and the text viewer's M5. If wrong, only the reply shape changes.
2. `zoom` takes `fit`, `actual`, or a positive number that is a multiple of actual size, so `1` is actual size. A scale
   below fit becomes fit. A scale past the 32 device-pixel ceiling is a bad argument. This rests on "Zoom" and M3's
   values. If wrong, only the argument's parser changes.
3. Inside the scope, "not an image" stays its own error, as UTERM-015's decision 6 keeps in-scope causes. Outside the
   scope, every failure is the dispatcher's one `unreadable` answer.
4. Gating events and event fields by the driver's schema minor is shared AppletKit code, since the rule is UTERM-004's
   for every applet.
5. The schema starts at 1.0. A step at either end answers with the current image, not an error, as manual stepping
   stops at the ends.

## UTERM-006 M4: Control

### Commits

All in this repo. In order:

1. "File the read scope that hides real paths when written through a link"
2. "Let a controller show, step, and zoom an image viewer pane", which carries the milestone, its review fixes, the
   proposal edits, the `ideas.md` entry, and this report

### What was built

The image viewer adopts the command hook at schema 1.0, with `show`, `next`, `previous`, `first`, `last`, `zoom`, and
`wait`, and a `shown` event. Effectful commands answer at once with a handle. `wait` settles with the event's fields,
under the same redaction. `show` hands the dispatcher's scoped open to a variant of the viewer's one load entry point. A
controller's folder opens its members through the scope, and a scoped listing never follows a link. AppletKit gained
shared gating of events and event fields by the driver's schema minor, and a hook that tells an applet when a driver's
hello is accepted.

### Checks

- `make lint`, which includes `fmt-check`: pass.
- `make check`: pass.
- `make test-package`: 2873 tests, 10 skipped, 0 failures.
- Focused runs: `ImageViewerControlTests` (23 tests), `ScopedFolderTests`, `AppletEventVersionTests`,
  `ExecDriverChannelTests`, `BuiltInAppletsTests`: pass.
- UI test `testAScriptShowsAFolderStepsAndZoomsAnImagePane`: it failed on the first run, and passed after the fix below.
  The coordinator viewed its screenshot. It shows the script's pane on image 2 of 2 at 100%, with the status bar
  reading 1,200 × 800.
- `make test-helper-sandbox` was not run. The helper is unchanged.

### Test cost

| Test file | Wall time, run alone |
|---|---|
| `ImageViewerControlTests` (23 tests) | 1.4 s |
| `ScopedFolderTests` | 0.011 s |
| `AppletEventVersionTests` | under 0.01 s |
| `ExecDriverChannelTests` (17 tests) | 5.5 s, about the same as before |
| UI test above | 19.3 s |

### Best guesses made during the milestone

The Decision Log's 2026-11-17 work-queue best-guess entry lists ten. The ones a reader should weigh:

1. A member of a controller's folder that links outside the scope is refused when the pane reaches it. The pane skips
   it like a deleted file, and the step's handle reads superseded. M4's check said `shown` withholds that image. That
   still holds for a folder the user opened. If wrong, the pane would read a file outside the scope to show the user.
2. A scoped folder lists without following links, so a controller cannot probe whether a link's target exists.
3. A zoom reply carries `fit` and `scale` only when the caller may see the image, since at fit the scale gives away the
   image's size. A caller that may not see the image is not refused past the 32 device-pixel ceiling. Its zoom holds at
   the ceiling instead, because the refusal would name the ceiling.
4. A driver's `shown` is deduplicated on the payload as delivered. A driver that attaches mid-session gets the image on
   screen once, when its hello is accepted. This adds `AppletEventOutlet.onAttached` to AppletKit. If wrong, drop the
   replay, and a driver stays blind until the next step.
5. A step before the first image shows answers `busy`, with the handle to wait on. A newer show or step replaces the
   running one.

### Review findings and dispositions

Reviewer:

1. The new UI test was not run. The coordinator ran it, and it failed: the status bar shows the focused pane's
   segments, and the script leaves focus in the terminal. Fixed: the test clicks the image pane first, then reads
   its segment. The product was right.
2. Zoom replies leaked image geometry to a caller outside the scope, through the scale at fit and the ceiling message.
   Plausible. The trace confirmed it. Fixed.
3. Duplicate `shown` frames flooded a driver while a listing grew. A driver that attached later heard nothing. Plausible.
   The trace confirmed both. Fixed.
4. A failure code on a linked image outside the scope revealed the cause. Plausible. The trace confirmed it. Fixed: such
   a failure reads `unreadable`.
5. The report was built on every refresh, tile, and frame, with a linear name lookup. Plausible. The trace confirmed it.
   Fixed: the lookup is gone, and nothing is built with no handle and no driver.
6. The As built text pointed at "the bugs the run reports". Fixed: it links the bug file.

adr-impact found no conflicts. Its one note was that `show` started its handle after the effect, against ADR-11's "an
error means nothing ran". Fixed: the handle starts first.

The regression tests for findings 2 to 5 were written after the fixes. None was seen failing on the unfixed code. The
traces argue each failure from the code, so the tests pin the fixes, not the bugs.

### Bugs found

- A read scope written through a link hides every path from its own controller. It needs a design call, so it is filed:
  `spec/bugs/20261117-read-scope-compared-as-written-hides-real-paths.md`. The text viewer has the same behavior.
- The text viewer and the image viewer each carry their own handle table and waiter, about a hundred duplicated lines.
  This is not a defect, so it is not filed. As built notes it.

### ADR candidates

Recorded as `Undecided` in UTERM-006's Decision Log:

1. A controller learns nothing about a user's file outside its read scope, from any reply, event, or error. This cuts
   across the system: every applet that reports file state to a controller must follow it.
2. A driver never receives an event or event field newer than the schema version it named in its hello. This is hard to
   reverse: it is a published contract that outside programs depend on.

The shared handle-and-wait shape was weighed and not recorded. It is a mechanism, and ADR-11 already holds the
principle behind it.

### Row review and final review

The row and the run cover the same range, so one reviewer ran both, with the run's ADR review. An adr-impact agent ran
beside it on the range and found no conflicts. The reviewer found nothing blocking.

1. Two test comments ran past the code width. Fixed.
2. The last As built bullet was over-long. It claimed the text viewer's window tests cover the image viewer's dispatch.
   Fixed: the claim now says what they cover, the shared dispatch with no per-viewer branch. It also says what they do
   not cover, the image viewer's type-table entry and its command switch. Only the UI test proves those.
3. A trailing blank line in `ideas.md`. Fixed.
4. Zoom told a caller outside the scope one bit: whether the user's pane held a decodable image. Plausible. The trace
   confirmed it. Fixed: such a caller gets a handle that settles `done` with nothing in it, whether or not an image is on
   screen. Exec drivers keep zoom. The new test failed on the unfixed behavior before the fix. Best guess 9 in the
   Decision Log carries the amendment.

The ADR review found no ADR added or edited. Both candidates pass the bar and stay `Undecided`. The reviewer noted the
second one may need lifting to UTERM-004's compatibility goal when the next proposal review weighs it.

Checks after the fixes: `make lint`, `make check`, the focused `ImageViewerControlTests` and `BuiltInAppletsTests`, and
`make test-package`, all exit 0. The UI test was not run again. The fix changes only zoom for a caller outside the
scope on a pane with no image, which the UI test does not reach.

Commit: "Hide whether an image pane holds an image from a zoom outside the scope".

### Left for the user

- A zoom from a caller outside the scope settles at once when the pane holds no image. With an image on screen, it
  settles after the pane does. A `wait` with a zero timeout could tell pending from done. That residue is timing only,
  and it is left as is.

- The freeze reports one hunk in UTERM-004 with origin `other`, in its References: an added ADR-14 line. Another
  session made it. The run did not touch it.
- M5, "Exec driver reads", is NOT STARTED and has no queue row. It waits on a driver path-read power, which is in
  `spec/ideas.md` and needs a proposal.
- How a script-driven pane feels by hand.
