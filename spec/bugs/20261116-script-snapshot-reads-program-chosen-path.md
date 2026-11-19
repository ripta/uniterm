# The app copies any path a command names into a script snapshot, with uniterm's privacy grants

**Status:** open, not reproduced, traced only
**Validation:** not confirmed; nothing was run. The path below is traced through the code. Whether uniterm holds a
grant for Documents, Desktop, or Downloads depends on the user's Mac.
**Estimate:** large; two non-trivial design decisions. Who reads the script: the command (sends bytes over the wire,
which changes `FileBegin` in `ScriptProtocol.swift`) or the app (keeps the open behind an unbuilt protected-location
list that would refuse scripts kept in Documents). Where the sidecar `.sig` is read: it is opened by the app from the
same program-chosen path (`DeclaredFile.swift`, `readSignature`), so it needs the same answer.
**Found:** 2026-11-16, by the design critic reviewing UTERM-032

## Observed

A program can make `uniterm run` name any absolute path, such as a file under `~/Documents`. The app opens that path
and copies it into a declared file's snapshot before the user reviews anything. The app reads with its own macOS
privacy grants, so the copy can hold a file the program could not read itself. The snapshot lands under
`~/Library/Application Support/uniterm`, which the program can read.

UTERM-015 "The path-reading power" rules this out: a program never borrows uniterm's macOS privacy grants. UTERM-032
"How the text reaches the script" rejected a host call for the same reason.

## Cause

1. The command resolves the script's path and sends it in the file begin (`DeclaredFileCommands.swift:19-28`).
2. The app copies the file it names (`DeclaredFile.swift:178-215`). It refuses relative paths and `/dev`, and opens with
   `O_NOFOLLOW` on the last component only (`DeclaredFile.swift:358`). Nothing checks who could read the file.
3. The command then reads the snapshot to parse its declaration (`DeclaredFileCommands.swift:47-68`).

No race is needed: the program names the protected file directly. A parent folder swapped for a link between the
command's resolve and the app's open reaches the same result.

## Repro

Not run. Expected repro on a Mac where uniterm holds a Documents grant and a test program does not:

1. Put `secret.txt` in `~/Documents`.
2. From a program without Documents access, run `uniterm run ~/Documents/secret.txt`.
3. Expected: the run is refused before the app reads the file. Actual, per the trace: the app copies it into a run
   folder under Application Support, and the command reads the copy before it refuses the declaration.

Also check whether a refused run deletes its snapshot, and when.

## Triage notes, 2026-11-18

Re-read the code against the trace. It holds. `DeclaredFileCommands.run` sends the resolved path in `FileBegin`.
`ScriptFiles.swift:174` passes `request.path` to `DeclaredFileSnapshot.create`, which opens any absolute path outside
`/dev` as the app. Existing tests in `DeclaredFileTests.swift` already copy arbitrary absolute paths. The macOS grant
difference cannot be reproduced without a TCC grant, so no run showed it. The cause is traced, not run.

## Fix

The fix needs a design call on who reads the script:

- The command reads the file with the invoker's own access and sends its bytes to the app, which hashes and snapshots
  them. The app never opens the program's path. This matches UTERM-032's input file.
- The app keeps the open, but only after a check that the path lies in no protected location, under UTERM-015's list.
  That list is unbuilt, and it would refuse scripts kept in Documents.

## Triage notes, 2026-11-19

Re-checked against the current code. `ScriptFiles.snapshotFile` still passes `request.path` from the peer's `FileBegin`
to `DeclaredFileSnapshot.create`. The cause is unchanged and still traced only. No ADR or proposal settles who reads
the script, so the two non-trivial decisions above stay open. The estimate stands.
