# A read scope written through a link hides every path from its own controller

**Status:** fixed 2026-11-20
**Fixed:** 2026-11-20
**Found:** 2026-11-17, while building the image viewer's control commands
**Estimate:** medium; one non-trivial design decision, when the scope's links are resolved. See "Triage 2026-11-18".

## Observed

A controller whose read scope names a directory through a symlink, such as `/tmp/pics` or a folder under `/var`, can make
a pane show an image inside it. The reply to its own `wait` then says the image is outside its scope, with no path,
index, or count. Every later reply about that pane reads the same. The controller never sees what it showed.

The open itself works, since the scoped open resolves the scope's links before it compares.

## Cause

`ReadAccess.mayShow(source:)` compares the scope's directories as written against the path it is given
(`Packages/UnitermKit/Sources/SourceAccess/ReadScope.swift:178`, through `ReadScope.contains`). The comparison is
lexical and reads no disk. The image viewer, and the text viewer, hand it real paths, which have no links in them. A
scope written through a link holds none of them. `/tmp` is `/private/tmp`, and a temporary folder under `/var/folders` is
`/private/var/folders`.

The failure is safe, since it hides too much and never too little. It breaks the controller's own use of what it opened.

## Repro

1. Run a controller with a read scope of `/tmp/pics`, where `/tmp/pics/a.png` exists.
2. Send the image viewer `show` with `/tmp/pics/a.png`, then `wait` on the handle.
3. Expected: `{state: shown, path: "/private/tmp/pics/a.png", ...}`.
4. Actual: `{state: shown, outside-scope: true}`.

## Fix

Compare against the scope's resolved directories too, as `ScopedOpen` does with its `roots`. It needs one design call:

- Resolve the scope when `ReadAccess` is made, off the main thread. The scope then carries both spellings, at the cost of
  one `realpath` per directory per access.
- Resolve inside `mayShow`. That reads the disk on the main thread, which `ScopedOpen`'s comments rule out.
- Keep the comparison as it is and tell the user at approval that a scope through a link hides what it shows. Nothing
  breaks, and the confusion stays.

## Workarounds

Write the scope with its real path, such as `/private/tmp/pics`.

## Triage 2026-11-18

Still reproduces. A throwaway test built a directory under `NSTemporaryDirectory()`, which is `/var/folders/...`, and
took the file's `realpath`, which is `/private/var/folders/...`. `ReadAccess(scope: [the directory as written])
.mayShow(source: <real path>)` returned false. The test is removed.

`ScriptConsent.readAccess(for:)` is synchronous and builds `ReadAccess` with the scope as approved. It resolves nothing.
`ReadScope.resolvedDirectories()` exists but only the approval panel uses it, off the main thread. Its callers are
`ScriptConsent.resolveReads(ofReview:)` and `ControllersWindowController`.

Files a fix would touch: `SourceAccess/ReadScope.swift`, `ScriptHost/ScriptConsent.swift`, and tests in
`SourceAccessTests/ReadScopeTests.swift`.

Decision that is not trivial: when to resolve. Resolving once at run admission is cheap per call, but it freezes a
resolution that a later retarget of the link makes stale, and `readAccess(for:)` is synchronous on the main thread, so
admission needs an async step. Resolving per `mayShow` reads the disk on the main thread, which the bug rules out. A
related question is whether a resolved directory that lands in a protected place should hide what it shows, as
`ScopedOpen` decides at open time.

## Fix

Fixed 2026-11-20 by resolving at run admission, the first option under "Fix".

`ScriptHost` resolves the links in every read-scope directory a live run holds, off the main actor, each time the set of
runs changes. It drops the resolutions no run needs. `readAccess(for:)` hands the result to `ReadAccess`, and `mayShow`
compares the scope's resolved directories as well as the ones as written. Files changed:
`SourceAccess/ReadScope.swift`, `ScriptHost/ScriptHost.swift`, `ScriptHost/ScriptConsent.swift`, and the regression test
in `ScriptHostTests/ControllerConsentTests.swift`.

A reply that arrives before the resolution finishes still hides the path. That is the safe direction. The resolution
freezes while the run lives, so a link retargeted mid-run is not followed. `ScopedOpen` still decides protected places
at open time.
