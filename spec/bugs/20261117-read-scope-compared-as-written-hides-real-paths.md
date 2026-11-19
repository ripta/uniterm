# A read scope written through a link hides every path from its own controller

**Status:** open
**Found:** 2026-11-17, while building the image viewer's control commands

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
