# UTERM-057: Who Reads a Controller Package

**Status:** draft
**Created:** 2026-11-23
**Updated:** 2026-11-23

## Dependencies

- UTERM-004, for controller packages, `controller.json`, the signature file, and the run snapshot
- UTERM-015, for "The path-reading power", which says a program never borrows uniterm's macOS privacy grants
- UTERM-034, whose "Who reads the script" and "Where the sidecar signature is read" settle the declared-file case
- UTERM-034 M1, if a bytes candidate wins. That milestone builds the chunk messages, and it has not started.

## Impacts

- UTERM-004 — its controller begin "names … the package path", and the app "independently verifies the artifact".
  Every candidate except "No rule" supersedes that in part. The candidate that skips the Janet snapshot also
  supersedes in part "Retain the read-only snapshot for the run". UTERM-004 is implemented, so it takes a "Superseded
  in part by UTERM-057" marker.
- UTERM-034 — its line "A package keeps its snapshot. It is outside this proposal." This proposal is where that gap
  lands.
- UTERM-056 — any change to the controller begin changes ScriptWire, and moves its version. Until UTERM-056 settles,
  that refuses every native controller built against the earlier version.
- UTERM-019, UTERM-029, UTERM-032, UTERM-034, and UTERM-054 — each also moves ScriptWire's version. Whichever lands
  later bumps again.

## ADR Deviations

None identified yet.

## Summary

Decide who reads a controller package's files when `uniterm run <folder>` or `uniterm controller run <folder>` starts
it. Today the app opens the folder the command names, with uniterm's own macOS privacy grants.

## Motivation

`uniterm run <folder>` and `uniterm controller run <folder>` run a controller package. `uniterm run` checks that the
path is a folder. Both resolve it with `realpath` and send the path in the controller begin (`ControllerCommands.swift`,
`runJanet` and `runNative`). The command never reads the package.

The app opens that folder in `ControllerSnapshot.create`. It opens the last component with `O_NOFOLLOW`, reads
`controller.json` and the optional signature file, and verifies the signature. It walks the folder in `checkTree`,
which refuses any file the descriptor does not list, since an unlisted file could be code the descriptor does not
cover. It copies each listed file into a run folder under uniterm's caches, and checks each file's digest on the bytes
it copied. For a native entry it checks the entry's load commands. Then `verifyCopy` walks and reads the copy again,
and the copy is made read-only.

So the app reads the folder with its own privacy grants. A program outside uniterm's process tree can name a folder it
cannot read itself. It can swap a parent folder for a link after the command resolves the path. It may also name the
folder directly, though the command's own `realpath` runs with the invoker's access and may already be refused there.
The copy lands in a run folder the program can read as the same user. UTERM-015 says a program never borrows uniterm's
macOS privacy grants.

The leak is narrower than the declared-file case. The app copies only the files `controller.json` lists, and each must
match its listed digest. What leaks is a privacy prompt under uniterm's name, whether a protected folder holds a
package, and a copy of a real package the user keeps in a protected place.

The app's read also has no bound. It runs in a detached task with no deadline. A package on a mount that never answers
leaves the admission pending and the command hung. See bug
[20261123-package-admission-read-has-no-bound](../bugs/20261123-package-admission-read-has-no-bound.md).

UTERM-034 fixes the declared-file form: the command reads the file once with the invoker's own access and sends its
bytes, and it reads the `.sig` beside the script itself. It leaves packages out and points at this gap.

Filed from bug
[20261122-package-snapshot-opens-program-chosen-folder](../bugs/20261122-package-snapshot-opens-program-chosen-folder.md).
The trace was confirmed against the tree on 2026-11-23. It was not reproduced, since the result depends on whether
uniterm holds a Documents, Desktop, or Downloads grant on the Mac.

## Design Decisions (Settled)

None.

## Design Decisions (Open)

### Who opens the package

Candidates:

- Bytes, with no snapshot for a Janet package. The command reads `controller.json`, the signature file, and each
  listed file once, with the invoker's own access, and sends their bytes. The app verifies the signature and each
  digest on the bytes it received. It refuses on the descriptor, for entry kind or an undeclared `--allow`, before it
  accepts any file. For a Janet entry the app writes no snapshot, and the command runs the bytes it sent, as UTERM-034
  does for a declared file. For a native entry the app writes the snapshot from the received bytes, since `execve`,
  the code identity, and `realpath` need the entry on disk. `MachOLoadCheck` already works on bytes. Changes
  `ControllerBegin` and needs chunked transfer. Supersedes in part UTERM-004's "Retain the read-only snapshot for the
  run" for Janet packages.
- Bytes, keeping the snapshot for every entry. As above, except the app writes a snapshot for a Janet package too, and
  the digest checks, the load check, and `verifyCopy` run on the copy as today. Leaves undone: the command reads a
  package of up to 128 MiB twice, once to send and again in `ControllerSnapshot.load`, and the app keeps a copy no
  Janet run needs.
- The command copies into a run folder the app made. The app creates the run folder and sends its path. The command
  copies the listed files into it with its own access. The app then runs `checkTree`, the digest checks, the load
  check, `verifyCopy`, and the lock on a folder it chose. No bytes cross the socket. Leaves undone: the app trusts
  files another same-user process wrote, so safety rests on argument rather than construction, and the begin becomes a
  two-step contract.
- The command opens each listed file and passes one descriptor per file. The descriptors carry the invoker's access, so
  this avoids the privacy-grant problem a passed folder has. Leaves undone: the app still reads from a file system the
  program chose, with no bound, which UTERM-034 rejected for a declared file. Up to 514 descriptors ride one per frame,
  and the socket holds at most 4 unclaimed.
- The command opens the folder with the invoker's own access, and passes its descriptor to the app over the socket.
  The socket already carries descriptors with `SCM_RIGHTS`, so only the message is new. The app walks that descriptor
  with its existing `openat` code, so `checkTree`, the digest checks, and the load check stay as they are. Leaves
  undone: every `openat` beneath the passed folder is likely charged to uniterm's privacy grants, not the invoker's, so
  this may not fix the bug. The app's read also stays unbounded.
- No rule. The app keeps opening the folder the command names. This is the bug, and it conflicts with UTERM-015.

Under either bytes candidate, the signature file moves to the command with `controller.json`. An app read of the
signature from the folder would bring back the program-chosen open, as UTERM-034 found for the `.sig`.

Under either bytes candidate, `controller.json` needs its own transfer path. `ControllerDescriptor.maxBytes` and
`ScriptProtocol.maxControlBody` are both 64 KiB, so a largest-allowed descriptor plus its signature cannot ride in one
begin frame. Either the descriptor is chunked too, or its cap drops. Dropping the cap refuses packages that are valid
today.

### Where the unlisted-file check happens

Applies to the bytes candidates. Today `checkTree` walks the source folder in the app and refuses any file
`controller.json` does not list.

Candidates:

- The command runs the existing `checkTree` on the source folder before it sends. The command already links that code
  through `descriptorForSigning`. A stray file such as a Finder `.DS_Store` is still refused, which matches
  `controller sign`. This is a pre-check. The app still enforces that exactly the listed files arrived, each matching
  its digest. Under the no-Janet-snapshot candidate no `verifyCopy` runs, so that per-file check is the enforcement.
- Drop the source check. Only listed files are sent or copied, so an unlisted file never reaches the run. Leaves
  undone: a package with a stray file now runs while `controller sign` still refuses it.
- The command reports a listing and the app checks it. Leaves undone: the listing proves nothing the command could not
  refuse itself, so it adds a message with no check behind it.

### Version skew

The controller begin is a ScriptWire message. Only the bundled command sends it. A native entry's own connections are
adopted, never begun, so this change crosses only the command and the app, which ship in one bundle.

Candidates:

- Bump ScriptWire's version, as UTERM-034 does. Old command to new app, and new command to old app, both refuse at the
  hello with the relaunch text. No deploy order is needed. A revert and a redeploy undo the change, since no stored data
  changes: a package's version is still the SHA-256 of `controller.json`. Native controllers built against the earlier
  version are refused until UTERM-056 settles, as UTERM-054 accepts.
- Add a new begin message without a bump. Native controllers are spared for this change. Leaves undone: a new command
  against an old app gets a dropped connection instead of the mismatch text, and the other proposals that bump
  ScriptWire take the natives' refusal anyway.

## Risks

- **macOS may charge the command's reads to uniterm** — likelihood: medium, impact: high. The bundled command runs from
  inside uniterm's bundle. If macOS attributes its file reads to uniterm rather than to the process that started it,
  every candidate still borrows uniterm's grants. UTERM-034 carries the same risk. Mitigation: the first milestone
  carries the same manual check UTERM-034 M1 does, run on a Mac where uniterm holds a Documents grant and the invoking
  program does not.
- **A large package moves a large transfer onto the socket** — likelihood: medium, impact: low, if a bytes candidate
  wins. UTERM-034's single deadline from begin to declaration does not scale to 128 MiB on a slow disk. Mitigation: the
  package size is already bounded by `ControllerDescriptor.maxPackageBytes`. The milestone names a bound sized for it.
  The app refuses on the descriptor before it accepts file bytes, and streams each file to disk and the hash rather
  than holding the whole package.
- **The app reads a file system the program chose, with no bound** — likelihood: low, impact: medium, if a descriptor
  candidate or "No rule" wins. Mitigation: none in those candidates. See bug
  [20261123-package-admission-read-has-no-bound](../bugs/20261123-package-admission-read-has-no-bound.md).

## Milestones

To be written once the open questions settle.

## Decision Log

- 2026-11-23: Filed as a draft from bug `20261122-package-snapshot-opens-program-chosen-folder`. The user asked for a
  new proposal at its triage, over adding packages to UTERM-034. The bug's two fix options became candidates under
  "Who opens the package", and "No rule" was added as the plain behavior. The tree check and signature read became a
  follow-up question, and version skew became a third.
- 2026-11-23: Design critique. Added three candidates under "Who opens the package": bytes with no Janet snapshot, the
  command copying into an app-made folder, and one descriptor per file. Labeled what each candidate leaves undone. The
  folder-descriptor candidate is now marked as likely still charged to uniterm's grants. That is not confirmed. Moved
  the signature read out of the second question, since the bytes candidates force it to the command, and renamed that
  question. Added candidates to the unlisted-file and version-skew questions. Noted the 64 KiB descriptor cap that
  matches the frame cap. Added the macOS attribution risk and the unbounded-read risk, and filed bug
  `20261123-package-admission-read-has-no-bound`. Added UTERM-004 and the other ScriptWire bumps to Impacts, UTERM-034
  M1 to Dependencies, and `uniterm controller run` to the scope. Nothing was settled.

## References

- [UTERM-034](UTERM-034-script-file-read-by-invoker.md): the declared-file precedent
- [UTERM-015](UTERM-015-cross-applet-file-opening.md): "The path-reading power"
- [UTERM-056](UTERM-056-native-controllers-across-scriptwire-versions.md): native controllers across ScriptWire
  versions
- Bug [20261122-package-snapshot-opens-program-chosen-folder](../bugs/20261122-package-snapshot-opens-program-chosen-folder.md)
- Bug [20261123-package-admission-read-has-no-bound](../bugs/20261123-package-admission-read-has-no-bound.md)
