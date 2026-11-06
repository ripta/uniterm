# UTERM-016: Map Pin Editing

**Status:** accepted
**Created:** 2026-11-05
**Updated:** 2026-11-05

## Dependencies

- UTERM-008 M2: the file layer, its GeoJSON reader, and its pin IDs
- UTERM-008 M3, and through it UTERM-004 M2 and M3: M4's command target needs the map's command schema and its
  transport
- UTERM-015: File > Open routing and the path-reading power
- UTERM-013: applet commands and their keys

## Impacts

- UTERM-015 — "Scope": its out-of-scope list said every viewer is read-only. The map is the first applet that writes a
  user's file. Amended there.
- UTERM-008 — "Where pins come from": the user's edits change the file layer, and M4 gives authorized callers an edit
  target on it. Amended there.
- UTERM-008 — M3: `pin selected` for a file pin, once M4 lets a caller that holds the file's read scope see its IDs.
- UTERM-013 — "Cmd-Shift-T reopens, and Cmd-Z undoes text edits only": superseded in part. Cmd-Z also undoes a
  focused map's pin edits.
- UTERM-005 — "Running something" for edited form input: the browser can move its unsent-form warning onto the unsaved
  work member when it is built. Not amended now.
- UTERM-001 — the applet contract gains one optional member. Its default changes nothing for other applets.

## Summary

The map viewer edits the GeoJSON file it shows. The user adds, moves, relabels, restyles, and removes pins by hand,
lists them in a sidebar, and writes them back with Save and Save As. Pins live only in GeoJSON files. The pane's
saved layout never holds them.

## Motivation

The map shows pins from a file, but the user cannot add one, remove one, or see them as a list. The only way to change
a pin is to edit the file in another program and open it again. A map of places the user cares about is something they
build up by hand, and a GeoJSON file is the natural place to keep it. It is plain text, it works with other tools, and
it can live in version control.

UTERM-008 kept program pins out of the layout file because they can hold secrets. The same reasoning applies to pins
the user places. Their home is a file the user chose, not the layout.

## Design Decisions (Settled)

### Pins persist only in GeoJSON files

Hand-placed pins are saved to a GeoJSON file the user names, never to the pane's description. A pane with unsaved pins
holds them in memory. A closed pane's unsaved pins ride in the description's undo-only part, so Cmd-Shift-T brings them
back within the launch. The layout file never holds them.

Rationale: the user asked that pins not be saved with the pane. A file the user chose is visible, portable, and
deletable. The layout file is none of those.

### Save and Save As

The map's File menu gains Save on Cmd-S and Save As on Cmd-Shift-S. Save writes the open file. Save As writes a new
file the user names in a save panel, and the pane then shows that file. A map with pins and no file has Save act as
Save As.

Rationale: these are the user's words, and the standard Mac behavior every document app follows.

### A save patches the file's bytes

Original question: what a save keeps that the map cannot show, such as lines, polygons, unknown properties, foreign
members, and the author's formatting.

Decision: a save changes only the values an edit names. Every other byte of the file stays as it was.

- The patcher reads where values sit in the file and skips everything else. It finds a pin's feature by UTERM-008's
  pin ID rule.
- Moving a Point rewrites its coordinates and keeps an altitude. Moving a MultiPoint member rewrites that member.
- A label replaces the first non-blank of `name`, `title`, and `label`, or adds `name`. A blank label removes it.
- An accent or a glyph sets `uniterm:accent` or `uniterm:glyph`. The default removes the key, and a simplestyle value
  then applies again.
- Restyling one member of a MultiPoint moves it out to its own Point feature, with a copy of the properties.
- A removal cuts the feature, or the member, with its separator. An add appends a feature with the file's separator.
- A single Feature or bare geometry is wrapped in a FeatureCollection, with its own bytes inside unchanged.
- A pin inside a GeometryCollection cannot be changed. The edit is refused, and the status bar says why. Amended
  2026-11-05; see Decision Log.

Rationale: the user chose this over rewriting the document or refusing mixed files. Formatting and version-control
diffs stay clean, and nothing the map cannot show is lost.

### What the map shows is what Save writes

Every edit produces new bytes first. The map then reads its pins from those bytes with the same reader a load uses.
The pins on screen are always the pins the file will hold.

Rationale: a second model of the pins beside the file's bytes could drift from what Save writes. Reading the bytes
back makes that impossible.

### Unsaved work on close and quit

Original question: what closing a pane, a window, or the app does with unsaved pins.

Decision: it asks Save, Don't Save, or Cancel, and names the file. The applet contract gains one optional member,
`unsavedWork`, and a `saveUnsavedWork()` call. Their defaults report nothing unsaved, so other applets change nothing.

- A pane close, the last pane, the window's close button, and quit each ask first.
- Save saves each pane in turn. A save the user cancels, or one that fails, stops the close.
- Unsaved work is asked about before running work. A pane with both asks twice, Save first.

Rationale: asking now and loosening it later is the safe direction. Autosave would rewrite the user's files without
an explicit Save, which cannot be undone, and adding a prompt later would feel like a regression. The member serves
the one applet with real unsaved work. It is shaped so the browser's unsent-form warning can adopt it later. That
amendment waits for the browser to be built.

### Cmd-Z undoes pin edits

Each add, move, edit, and removal is one undo step in the pane's own undo stack. Cmd-Shift-Z redoes it. The window
routes Undo to a focused view's own stack after a text field being edited.

Rationale: the user chose undo over a confirmation on remove. Recovery from a mistaken move or edit needs it.

### Scripts may edit the file, and only the user saves

UTERM-008's command schema gains a file-layer target for its edit commands. A command changes the pane's unsaved
document, as the user's own edits do, and undoes like one. A caller may target the file only when its scope holds the
file under UTERM-015's path-reading power, since the commands and their replies reveal the file's pin IDs. Writing the
file stays a user action. No new write power is needed.

### A file that changes on disk while open

The map watches its file, and follows an editor that saves by renaming a new file over the old one. A pane with no
edits reads the file again. A pane with edits keeps them. The status bar says the file changed, and a "Changed on
disk" segment shows until the next save or read. Save then asks Save As, Cancel, Overwrite, or Revert. Amended
2026-11-05; see Decision Log.

### Adding and editing pins

A right-click on the map offers Add Pin Here. A right-click on a file pin offers Edit Pin and Remove Pin. A file pin
drags to a new place. Its callout has an Edit button, which opens a popover for the label, color, and glyph. The Map
menu holds Edit Pin and Remove Pin on Cmd-Delete. A plain click on the map still selects and pans, as before.

### The pin list

View > Show or Hide Pin List, on Cmd-Shift-L, toggles a sidebar at the map's trailing edge. It lists the file's pins in
file order with a filter. Selecting a row selects the pin and moves the map to it. A double-click edits it. Add Pin
drops one at the map's center, and Remove removes the selected one. The list's visibility is not saved with the pane.

## Design Decisions (Open)

None.

## Risks

- **A save destroys or corrupts the user's file** — likelihood: medium, impact: high. Mitigation: nothing is written
  without an explicit Save. The write goes to a file beside the target and is swapped in, keeping the old file's
  permissions. Byte-exact tests cover every edit kind against files with lines, foreign members, escapes, and odd
  spacing. The edited bytes are read back by the shipped reader before the map shows them.
- **The written file is invalid for other tools** — likelihood: low, impact: medium. Mitigation: removals take their
  separator with them, and tests parse every edited fixture as JSON. Coordinates are written with the shortest text
  that reads back to the same number.
- **A contract member every applet carries** — likelihood: low, impact: low. Its defaults report nothing unsaved, so
  no other applet changed. Accepted.

## Milestones

### M1: An editable document and Save

**Status:** DONE

- The map holds the open file as an editable document, separate from the pins it shows
- Save writes the file in place, and Save As writes a new one and makes it the pane's file
- A save keeps every byte the user did not change, and a test proves it on files with lines, unknown properties,
  foreign members, and escapes
- A save is atomic, and a failed write leaves the old file whole and says why
- A file changed on disk since load is detected before Save overwrites it, and a clean pane reloads it

**As built:**

- The patcher and its span reader live in `GeoData`, with no AppKit or MapKit. The review said the data viewer's JSON
  scanner would be reused. It is internal to `TableData` and built around table capture caps, so `GeoData` got its own
  small span reader instead. It checks the syntax it skips and bounds nesting at 512.
- A save swaps the new file in with `FileManager.replaceItemAt`, which keeps the old file's permissions. A test holds a
  file at mode 600 across a save.
- The watcher re-arms after a delete or rename event, so a write-then-rename save by another editor is followed. A
  change that matches the bytes the map last read or wrote is ignored, so the map's own save does not reload it.
- Choosing the default accent removes `uniterm:accent`. A file's `marker-color`, when it has one, then sets the color
  again, as the reader's rule says.
- An edit whose bytes the reader refuses is taken back, and the undo stack is cleared, since it points at those bytes.
  The status bar says the edit was not applied. Save can therefore never write bytes the map could not read.
  Amended 2026-11-05; see Decision Log.
- Clear File Pins and opening another file into the pane both ask before they drop unsaved pins.
- Residuals. Each undo step keeps a whole document, and the stack holds 50 steps. A file near the 32 MiB bound can
  hold over a gigabyte of undo. Save and the disk-change check read the file on the main thread, within the same
  bound. A dirty pane's description base64-encodes the whole document each time the host asks for it. None was
  measured, and each is a candidate for its own change if a large file shows the cost.

### M2: Editing pins by hand

**Status:** DONE

- The user adds a pin from the map's context menu and from the sidebar, moves one by dragging, edits its label, accent,
  and glyph, and removes it
- Each edit is one Cmd-Z step, and Cmd-Shift-Z redoes it
- Closing a pane, a window, or the app with unsaved pins asks Save, Don't Save, or Cancel, and names the file
- A map with no file accepts pins, and Save asks where to write them

**As built:**

- MapKit's inner views never ask the map view for a menu, so the map's own event monitor takes a right-click on the
  map and shows the menu. A right-click on the place search is left to it.
- An edit is refused while the previous edit's pins are still being read. Pin IDs come from file order, and a removal
  or a split renumbers them. A second edit on stale IDs could hit the wrong pin.
- A pane closed with unsaved pins carries them in the undo-only part. A reopen shows them as still unsaved.
- Opening another file into a pane with unsaved pins asks first, through the host's confirmation.
- The UI test adds a pin by right-click, undoes it, adds another, sees Cmd-W ask, and saves. It checks that the file
  still holds its line. The drag and the popover are covered in the package tests, since XCUITest cannot drag a map
  annotation reliably.
- Left to the user: the look of the popover, the callout's Edit button, and a drag on a live map.

### M3: The pin sidebar

**Status:** DONE

- The View menu shows and hides a sidebar that lists the pins, with a filter
- Selecting a row selects the pin and moves the map to it

Amended 2026-11-05; see Decision Log.

**As built:**

- No program layers exist until UTERM-008 M3, so the list shows the file's pins only. The read-only program-layer rows
  move to M4's checks.
- A pin selected on the map is selected in the list without moving the map back.
- Left to the user: the sidebar's look in both flavors.

### M4: Scripts and the file layer

**Status:** NOT STARTED

- The map's command schema gains a file-layer target for its edit commands, under the path-reading power
- A command's edit is unsaved until the user saves, and it undoes like the user's own
- The pin list shows program layers read-only, with their Clear action

## Decision Log

- 2026-11-05: Drafted after the user's review of UTERM-008. The user asked that pins be added and removed by hand,
  saved to GeoJSON with Save and Save As, never saved with the pane, and reachable through the map's script interface.
- 2026-11-05: A save patches the file's bytes. The user chose it over rewriting the whole document and over Save As
  only for mixed files.
- 2026-11-05: Unsaved work asks Save, Don't Save, or Cancel through one small optional contract member. The user asked
  whether other applets would use it, and whether a contract should be proven before it is added. The browser's form
  warning is the only other case, and it is unbuilt. Asking now and loosening later is the safe direction, so the user
  chose the small member over autosave and over amending UTERM-005 now.
- 2026-11-05: Cmd-Z undoes pin edits. The user chose it over no undo. UTERM-013 is superseded in part.
- 2026-11-05: Scripts edit the open document under the path-reading power, and only the user saves. The user chose it
  over scripts saving and over no change.
- 2026-11-05: A changed file reloads a clean pane and warns an edited one; pins are added by right-click and from the
  sidebar; the sidebar toggles from the View menu. These were stated as the plan with the questions above, and the user
  did not object. (autonomous)
- 2026-11-05: Accepted when the user asked for every unimplemented part to be built. M1 to M3 built the same day. M4
  waits on UTERM-008 M3.
- 2026-11-05: M3's program-layer check moved to M4, since program layers do not exist before UTERM-008 M3.
- 2026-11-05: Amended M3. Its third check, "Program layers show read-only, with their Clear action", moved to M4,
  since program layers do not exist before UTERM-008 M3.
- 2026-11-05: The user approved the map's keys as built: Cmd-1 to Cmd-3, Cmd-+, Cmd--, Cmd-0, Cmd-Shift-N, Cmd-L,
  Cmd-S, Cmd-Shift-S, Cmd-Delete, and Cmd-Shift-L. They are applet keys under UTERM-013's rules, live only while a map
  has focus.
- 2026-11-05: A review found and fixed: restored unsaved pins could land on another file; a move of an unlabeled pin
  wrote properties or split a MultiPoint; a refused drag left the pin off its place; pins in a geometry collection were
  offered for editing; a save replaced a symlink with a plain file; an edit held across a renumbering could hit another
  pin; two saves at once could see their own write as a conflict; and the watcher gave up on a file that came back. The
  UI tests now run with place names off, so they send no map center to Apple.
- 2026-11-05: Edit refusals and the file-changed notice are said in the status bar, not the pane. The text said "the
  pane says", but the code has posted them to the status bar since M2. A file that changed on disk under edits also
  shows a "Changed on disk" warning segment. Unsaved pins that cannot come back after a reopen now post an error, under
  UTERM-008's rule for notice levels.

## References

- UTERM-008: Map Viewer Applet
- RFC 7946: The GeoJSON Format
