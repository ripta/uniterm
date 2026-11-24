# UTERM-057: Who Reads a Controller Package

**Status:** draft
**Created:** 2026-11-23
**Updated:** 2026-11-23

## Dependencies

- UTERM-004, for controller packages, `controller.json`, the signature file, and the run snapshot
- UTERM-015, for "The path-reading power", which says a program never borrows uniterm's macOS privacy grants
- UTERM-034, whose "Who reads the script" and "Where the sidecar signature is read" settle the declared-file case

## Impacts

- UTERM-034 — its line "A package keeps its snapshot. It is outside this proposal." This proposal is where that gap
  lands.
- UTERM-056 — any change to the controller begin changes ScriptWire, and moves its version. Until UTERM-056 settles,
  that refuses every native controller built against the earlier version.

## ADR Deviations

None identified yet.

## Summary

Decide who reads a controller package's files when `uniterm run <folder>` starts it. Today the app opens the folder the
command names, with uniterm's own macOS privacy grants.

## Motivation

`uniterm run <folder>` runs a controller package. The command checks that the path is a folder, resolves it with
`realpath`, and sends the path in the controller begin (`ControllerCommands.swift`, `runJanet` and `runNative`).
The command never reads the package.

The app opens that folder in `ControllerSnapshot.create`. It opens the last component with `O_NOFOLLOW`, reads
`controller.json` and the optional signature file, and verifies the signature. It walks the folder in `checkTree`,
which refuses any file the descriptor does not list, since an unlisted file could be code the descriptor does not
cover. It copies each listed file into a run folder under uniterm's caches, and checks each file's digest on the bytes
it copied. For a native entry it checks the entry's load commands. Then `verifyCopy` walks and reads the copy again,
and the copy is made read-only.

So the app reads the folder with its own privacy grants. A program outside uniterm's process tree can name a folder it
cannot read itself. It can name it directly, or swap a parent folder for a link after the command resolves the path.
The copy lands in a run folder the program can read as the same user. UTERM-015 says a program never borrows uniterm's
macOS privacy grants.

The leak is narrower than the declared-file case. The app copies only the files `controller.json` lists, and each must
match its listed digest. What leaks is a privacy prompt under uniterm's name, whether a protected folder holds a
package, and a copy of a real package the user keeps in a protected place.

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

- The command opens the folder with the invoker's own access, and passes its descriptor to the app over the socket.
  The app walks that descriptor with its existing `openat` code, so `checkTree`, the digest checks, and the load check
  stay as they are. Adds a descriptor-passing path on the socket, and an app that walks a descriptor it did not open.
- The command reads the descriptor, the signature, and each listed file with the invoker's own access, and sends their
  bytes, as UTERM-034 does for a declared file. The app writes the snapshot from those bytes, and the digest checks,
  the load check, and `verifyCopy` run on the copy as today. Changes `ControllerBegin`, and needs chunked transfer for
  a package of up to `ControllerDescriptor.maxPackageBytes`, which is 128 MiB. The app no longer sees the source folder, so the walk
  that refuses unlisted files moves to the command, or goes. See the next question.
- No rule. The app keeps opening the folder the command names. This is the bug, and it conflicts with UTERM-015.

### Where the unlisted-file check and the signature read happen

Applies to the bytes candidate above. Today `checkTree` walks the source folder in the app and refuses any file
`controller.json` does not list. The signature file is read from the same folder.

Open: whether the command walks the folder and refuses unlisted files before it sends, whether the command reports the
listing and the app checks it, or whether the check is dropped because the snapshot holds only listed files. Whether
the signature read moves to the command, as UTERM-034 moves the `.sig` read. The choice should match UTERM-034 where
the cases are alike.

### Version skew

The controller begin is a ScriptWire message. The command and the app ship in one bundle, so either candidate above
moves ScriptWire's version under exact match, per UTERM-024 "Version skew". Open: how this lands beside UTERM-056,
which decides what that move does to native controllers.

## Risks

- **Reading a whole package in the command moves a large transfer onto the socket** — likelihood: medium, impact:
  low, if the bytes candidate wins. Mitigation: the package size is already bounded by
  `ControllerDescriptor.maxPackageBytes`, and UTERM-034's chunk messages are a precedent.
- **A passed descriptor is walked by a process that did not open it** — likelihood: low, impact: medium, if the
  descriptor candidate wins. Mitigation: the walk already opens every component with `O_NOFOLLOW` relative to a
  directory descriptor, so it never resolves a path from the root.

## Milestones

To be written once the open questions settle.

## Decision Log

- 2026-11-23: Filed as a draft from bug `20261122-package-snapshot-opens-program-chosen-folder`. The user asked for a
  new proposal at its triage, over adding packages to UTERM-034. The bug's two fix options became candidates under
  "Who opens the package", and "No rule" was added as the plain behavior. The tree check and signature read became a
  follow-up question, and version skew became a third.

## References

- [UTERM-034](UTERM-034-script-file-read-by-invoker.md): the declared-file precedent
- [UTERM-015](UTERM-015-cross-applet-file-opening.md): "The path-reading power"
- [UTERM-056](UTERM-056-native-controllers-across-scriptwire-versions.md): native controllers across ScriptWire
  versions
- Bug [20261122-package-snapshot-opens-program-chosen-folder](../bugs/20261122-package-snapshot-opens-program-chosen-folder.md)
