# Images in Markdown a script sends resolve anywhere on the volume

**Status:** fixed 2026-11-19
**Fixed:** 2026-11-19
**Estimate:** medium; one non-trivial design decision. Every candidate fix needs the text viewer to know a file
came from a script, and `SourceReplacing.replaceSource(with:startDirectory:)` carries no origin. The candidates
differ in behavior a user or script can see, and they are equally correct. The decision is which rule wins.
Re-checked against the code on 2026-11-18. `MarkdownLoading` and `ConfinedFile` are unchanged, and
`replaceSource(with:startDirectory:)` still carries no origin.
**Found:** 2026-11-15, by the design critic reviewing UTERM-030

## Observed

A script with pane control and no file capability can make the text viewer read and show an image it names by path.
Nothing was run. The path below is traced through the code.

`ScriptSentContent.swift:5-8` states the contract: "A script sends bytes and a name, never a path, so what a script may
read stays under its own sandbox."

The code does not keep it for Markdown images:

1. `uniterm/send` writes the bytes to `~/Library/Application Support/uniterm/sent/<instance>/<uuid>/<name>`
   (`ScriptSentContent.swift:90-100`).
2. The viewer loads that file like a file the user opened. `MarkdownLoading.loadBlocking` sets the image folder to the
   file's parent (`MarkdownLoading.swift:18-21`).
3. The image walk confines a path to the folder's volume, not the folder. A `..` step passes on a device check alone
   (`ConfinedFile.swift:94-101`). That is the documented rule for documents the user opens, per UTERM-007's 2026-11-08
   ADR candidate.
4. So `![](../../../../../../Documents/x.png)` in sent Markdown climbs from the sent folder to `~` and reads
   `~/Documents/x.png`.

The script never sees the bytes. The image shows on screen, and the read uses uniterm's own macOS privacy grant for
Documents, or raises a privacy prompt under uniterm's name. UTERM-015 "The path-reading power" rules out exactly that:
a script with no file capability must not borrow uniterm's grants. Inline Markdown from `show-markdown` is not affected.
It has no folder, so its images show alt text (UTERM-007 "Control levels").

## Repro

Reproduced on 2026-11-18 with a throwaway package test, since removed. It wrote `note.md` containing
`![x](../../../secret.png)` three folders deep under a scratch folder, put a 5 px PNG at the scratch root, and opened the
note with `TextViewerApplet.replaceSource(with:startDirectory:)`, the call `WindowScripting.send(to:file:caller:)` makes
for sent content. The image loaded with a natural width of 5, where the contract expects none.

The test stood in for the sent folder with a scratch folder. It did not go through a live script connection. The code
path from `uniterm/send` to `replaceSource` was read, and it passes the file with no origin.

The original setup: a script with `{:kind :pane-control :version 1}` and no capability sends Markdown that names a test
image above the sent folder, to a remote-controlled text viewer pane.

- Expected, per `ScriptSentContent.swift:7`: the image does not load.
- Traced: the image loads.

## Fix

This needs a design call. The candidates:

- Give sent Markdown no image folder, as inline Markdown has. Sent documents lose relative images, which they cannot
  have in a useful way anyway, since the sent folder holds only the one file.
- Confine a sent document's images to its own sent folder, refusing any `..` that leaves it.
- Refuse `..` in image paths for every document that did not come from the user.

UTERM-030 "Slide images" designs scoped image loading for controllers. It should use whichever rule
this settles.

## Fix note

Markdown a script sends through `uniterm/send` now opens with no image folder, as inline Markdown does. A sent
note's images keep no source, so the page shows their alt text. A note the user opens still resolves relative images,
including ones above it. `SourceReplacing` gained `replaceSource(withSent:startDirectory:)`, which opens a file like
any other unless the applet overrides it. `WindowScripting.send` calls it, and the text viewer overrides it.

The rule that settled the fix was the first candidate above. UTERM-030 "Slide images" should reuse it for sent decks.

Files changed: `Packages/UnitermKit/Sources/AppletKit/SourceReplacing.swift`,
`Packages/UnitermKit/Sources/TextViewerApplet/MarkdownLoading.swift`,
`Packages/UnitermKit/Sources/TextViewerApplet/TextViewerApplet.swift`, and
`Packages/UnitermKit/Sources/WindowKit/WindowScripting.swift`. The regression test is
`MarkdownAppletTests.testSentMarkdownLoadsNoImageAboveItsFolderAndTheUsersOwnFileDoes`.
