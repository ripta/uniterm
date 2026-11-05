# UTERM-016: Map Pin Editing

**Status:** draft
**Created:** 2026-11-05
**Updated:** 2026-11-05

## Dependencies

- UTERM-008 M2: the file layer, its GeoJSON reader, and its pin IDs
- UTERM-015: File > Open routing and the path-reading power
- UTERM-013: applet commands and their keys

## Impacts

- UTERM-015 — "Scope": its out-of-scope list says "Editing files. Every viewer is read-only." The map becomes the first
  applet that writes a user's file. That statement is updated when this proposal settles.
- UTERM-008 — "Where pins come from": the file layer is changed by the user's edits as well as by loading. The answer to
  "Scripts and the file layer" may also amend the rule that no command reaches the file layer.
- UTERM-008 — M3: `pin selected` for a file pin, if scripts gain any access to the file layer.
- UTERM-013 — "Cmd-Shift-T reopens, and Cmd-Z undoes text edits only": pin edits would be the first non-text edit that
  Cmd-Z undoes.
- UTERM-001 — the applet contract: closing a pane, a window, or the app may need to ask about unsaved pins.
- UTERM-004 — "Permission scopes and approval flow": only if scripts may save, which needs a path-writing power.

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
holds them in memory only.

Rationale: the user asked that pins not be saved with the pane. A file the user chose is visible, portable, and
deletable. The layout file is none of those.

### Save and Save As

The map's File menu gains Save and Save As. Save writes the open file. Save As writes a new file the user names in a save
panel, and the pane then shows that file. A map with hand-placed pins and no file has Save act as Save As.

Rationale: these are the user's words, and the standard Mac behavior every document app follows.

### Hand editing on the map

The user adds, moves, and removes pins on the map itself. Selecting a pin offers its label, accent, and glyph for editing.

### A sidebar lists the pins

A sidebar in the pane lists the pins, so the user can find, select, and remove them without hunting on the map.

### The map's script interface is UTERM-008's

UTERM-008 already defines the map's commands, `add`, `remove`, `clear`, `set-layer`, and setting the region. They reach
the map over UTERM-004's transport and `uniterm/send-command`. This proposal extends that schema where scripts need
the new features. It defines no second interface.

## Design Decisions (Open)

### What a save keeps that the map cannot show

A GeoJSON file can hold lines, polygons, properties the map ignores, foreign members, and the author's formatting. The
map shows only points. A save must not silently drop the rest.

- **A. Patch the file's bytes (recommended).** Re-read the file with TableData's JSON scanner, which reports each
  token's byte offsets. Replace only the features the user changed, append new ones, and cut removed ones. Every other
  byte stays as it was, so formatting, key order, and a version-control diff stay clean.
- **B. Rewrite the whole document.** Keep the parsed document as an order-preserving tree, and serialize it whole. No
  value is lost, but formatting, whitespace, and number spelling change, so every save shows as a full-file diff.
- **C. Refuse Save for files the map cannot fully show.** Offer only Save As to a new points-only file. It is safe, but
  editing a mixed file means making a copy.

Leaves undone, B: clean diffs. Leaves undone, C: editing a mixed file in place.

### Unsaved edits on close and quit

Pins are never saved with the pane, so closing a pane with unsaved edits would lose them.

- **A. Ask, as document apps do (recommended).** Closing a pane, a window, or the app asks Save, Don't Save, or Cancel,
  and names the file. This adds an "unsaved changes" member to the applet contract beside `isRunningSomething`. A
  closed pane's unsaved pins ride in the undo-only part, so Cmd-Shift-T brings them back within the launch.
- **B. Reuse the running-something prompt.** It needs no contract change, but the dialog would say the pane is
  "running" and offer no Save. It leaves undone: a correct prompt, and saving from it.
- **C. Save automatically.** It writes the user's file without asking, which the user's file-as-storage choice argues
  against. It leaves undone: the user's control over when their file changes.

### Undo for pin edits

UTERM-013 settled that Cmd-Z undoes text edits only, after it moved pane reopen to Cmd-Shift-T.

- **A. Cmd-Z undoes pin edits in a focused map (recommended).** Add, move, edit, and remove each make one undo step in
  the pane's own undo manager. UTERM-013's text gains "and a focused map's pin edits".
- **B. No undo.** Remove asks for confirmation instead. It leaves undone: recovery from a mistaken move or edit.

### Scripts and the file layer

UTERM-008 keeps the file layer outside the command namespace. No command can reach the file's pins, and an event never
reveals a value from the file.

- **A. Scripts edit the open document, and only the user saves (recommended).** A `file` layer target joins the schema
  for `add`, `remove`, and the move and edit commands. The commands change the pane's unsaved document, as the user's
  own edits do. A controller may target it only when its scope holds the file under UTERM-015's path-reading power,
  since the commands and their replies reveal the file's pin IDs. Writing the file stays a user action.
- **B. Scripts also save.** Add a `save` command. It needs a new path-writing power in UTERM-004, with its own approval.
  It leaves nothing undone for scripts, at the cost of a write power that no caller has asked for yet.
- **C. No change.** Scripts write GeoJSON files themselves and open them with `uniterm open`. The map reloads a file
  that changes on disk. It leaves undone: a script cannot add to the file the user is editing.

### A file that changes on disk while open

- **A. Reload a clean pane, and ask on a dirty one (recommended).** The map watches the file. With no unsaved edits it
  reloads quietly. With unsaved edits it shows a notice. Save then asks Overwrite, Save As, or Revert.
- **B. Check only at Save.** Save compares the file's size, date, and content hash with what was loaded, and asks on a
  mismatch. It leaves undone: a clean pane goes stale until reopened.

### How a pin is added

- **A. Right-click "Add Pin Here", and an Add Pin button in the sidebar that drops one at the map's center
  (recommended).** Neither changes what a plain click on the map does.
- **B. A pin-drop mode.** A toolbar toggle makes each click add a pin. A forgotten mode adds stray pins.
- **C. Option-click adds a pin.** It is fast but hidden, so it needs a second, visible way anyway.

### The sidebar

- **A. A pane-local sidebar, toggled from the View menu (recommended).** It lists the file's pins with a filter field,
  and the program layers read-only with their Clear action. Selecting a row selects and shows the pin.
- **B. Pins in the command palette only.** The palette lists pins as entries. It has no room for remove or edit.

## Risks

- **A save destroys or corrupts the user's file** — likelihood: medium, impact: high. Mitigation: never write without
  an explicit Save. Write to a temporary file and swap it in atomically, keeping the file's permissions and extended
  attributes. Round-trip tests cover every GeoJSON shape the reader accepts, plus files with content the map cannot
  show. A fuzz run feeds random edits through save and reload.
- **The written file is invalid for other tools** — likelihood: low, impact: medium. Mitigation: writes follow RFC 7946.
  A test re-parses every saved fixture with `MKGeoJSONDecoder` and with a plain JSON parser. Coordinates are written
  with the shortest text that reads back to the same number.
- **A contract change ripples to every applet** — likelihood: medium, impact: medium. This applies only if "Unsaved
  edits on close and quit" picks A. Mitigation: the new member has a default of "nothing unsaved", so other applets
  change nothing.

## Milestones

Drafted against the recommended options. They change when the open questions settle.

### M1: An editable document and Save

**Status:** NOT STARTED

- The map holds the open file as an editable document, separate from the pins it shows
- Save writes the file in place, and Save As writes a new one and makes it the pane's file
- A save keeps every byte the user did not change, and a test proves it on files with lines, polygons, unknown
  properties, and foreign members
- A save is atomic, and a failed write leaves the old file whole and says why
- A file changed on disk since load is detected before Save overwrites it

### M2: Editing pins by hand

**Status:** NOT STARTED

- The user adds a pin from the map's context menu and from the sidebar, moves one by dragging, edits its label, accent,
  and glyph, and removes it
- Each edit is one Cmd-Z step, and Cmd-Shift-Z redoes it
- Closing a pane, a window, or the app with unsaved pins asks Save, Don't Save, or Cancel, and names the file
- A map with no file accepts pins, and Save asks where to write them

### M3: The pin sidebar

**Status:** NOT STARTED

- The View menu shows and hides a sidebar that lists the pins, with a filter
- Selecting a row selects the pin and moves the map to it
- Program layers show read-only, with their Clear action

### M4: Scripts and the file layer

**Status:** NOT STARTED

- The map's command schema gains a file-layer target for its edit commands, under the path-reading power
- A command's edit is unsaved until the user saves, and it undoes like the user's own

## Decision Log

- 2026-11-05: Drafted after the user's review of UTERM-008. The user asked that pins be added and removed by hand,
  saved to GeoJSON with Save and Save As, never saved with the pane, and reachable through the map's script interface.
  The settled decisions record those requests. Everything else is open.

## References

- UTERM-008: Map Viewer Applet
- RFC 7946: The GeoJSON Format
