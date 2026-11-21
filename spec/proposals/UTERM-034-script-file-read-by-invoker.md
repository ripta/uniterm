# UTERM-034: Who Reads a Script File

**Status:** draft
**Created:** 2026-11-19
**Updated:** 2026-11-19

## Dependencies

- UTERM-003, for `uniterm run`, the command, and the wire between the command and the app
- UTERM-015, for "The path-reading power", which says a program never borrows uniterm's macOS privacy grants
- UTERM-021, for a declared file's snapshot, hash, and sidecar signature
- UTERM-032, for the precedent that the command reads the input file with the invoker's own access

## Impacts

- UTERM-021 — "The file is snapshotted and hashed": the app reads the file today. This proposal decides who does.
- UTERM-021 — the sidecar signature section: the app opens the `.sig` beside the same program-chosen path.
- UTERM-003 — "Where scripts run": the app reads and snapshots a declared script before the command runs it.
- UTERM-032 — "How the text reaches the script": this proposal applies the same rule to the script file itself.

## Summary

Closes a gap where the app opens a script path that the program chose. The app reads with its own macOS privacy
grants, so the copy can hold a file the program could not read itself.

## Motivation

A program can make `uniterm run` name any absolute path. The command resolves the path and sends it in the file begin.
The app opens that path and copies it into a declared file's snapshot before the user reviews anything. The snapshot
lands under `~/Library/Application Support/uniterm`, which the program can read.

The app holds the user's grants for Documents, Desktop, and Downloads when the user gave them. A program without those
grants can name `~/Documents/secret.txt`. The app copies it. The command then reads the copy. The command refuses the
declaration afterward, but the copy is already made.

UTERM-015 rules this out for path reads. UTERM-032 rejected a host call for the same reason, and made the command read
the input file with the invoker's access. The script file itself was left on the old path.

The cause is traced in the code, not run. The grant difference needs a Documents grant for uniterm and none for the test
program. A parent folder swapped for a link between the command's resolve and the app's open reaches the same result.

Existing tests copy arbitrary absolute paths on purpose, so none of them covers this.

## Design Decisions (Settled)

None yet.

## Design Decisions (Open)

### Who reads the script

The app must not open a path the program chose, with the app's grants. Two ways to get there.

- Option A: the command reads the file with the invoker's own access and sends the bytes to the app. The app hashes
  and snapshots the bytes. The app never opens the program's path. This is UTERM-032's rule applied to the script. It
  changes the file begin on the wire, so it needs the skew analysis below. It leaves no list to keep.
- Option B: the app keeps the open, after a check that the path lies in no protected location. This reuses the
  protected-location list from UTERM-015. That list is not built yet. It would refuse a script kept in Documents,
  which users do. The check and the open stay two steps unless the open also re-checks the real path.
- Option C: the command opens the file and passes the open descriptor to the app, as UTERM-032 does for a PDF. The app
  never names the path. This needs the same wire change as A, and avoids copying bytes through the socket.

Recommendation, pending the design critic: A or C. Both keep the invoker's access as the only authority. B ranks lower
on correctness, because a list of protected locations lags the OS.

### Where the sidecar signature is read

The app opens `<script>.sig` from the same program-chosen path. It needs the same answer as the script.

- Read it in the command and send it beside the script bytes. One reader for both files.
- Read it in the app, beside a path the command has already vouched for. Two readers, one rule each.

### Whether a refused run keeps its snapshot

Check what happens today. A refused run may leave a copy under Application Support. If it does, say when it is
deleted. This is a question to answer first, and a decision only if the answer is that it stays.

## Risks

- **The file begin changes on the wire** — likelihood: high, impact: medium. A newer command and an older app, and the
  reverse, must both refuse or tolerate the change. A one-way door once shipped.
  Mitigation: a ScriptWire version bump, with the skew analysis in the settled decision before acceptance.
- **A fix that checks and then opens leaves a window** — likelihood: medium, impact: high. Applies to option B only.
  Mitigation: option A or C removes the app's open, so no window remains.
- **A script kept in a protected folder stops running** — likelihood: medium, impact: medium. Applies to option B only.
  Mitigation: option A or C reads with the invoker's access, so a script in Documents still runs for an invoker who
  can read it.

## Milestones

Drafted once the open decisions settle.

## Decision Log

- 2026-11-19: Filed from a bug, which found the app reading a program-chosen script path. The bug is
  `spec/bugs/20261116-script-snapshot-reads-program-chosen-path.md`.

## References

- ADR-14: the path-reading power as its own typed permission
