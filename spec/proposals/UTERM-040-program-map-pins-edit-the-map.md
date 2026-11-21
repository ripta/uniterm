# UTERM-040: A Program's Map Pins Edit the Map as the User's Do

**Status:** draft
**Created:** 2026-11-21
**Updated:** 2026-11-21

## Dependencies

- UTERM-008, for the map's pin commands and its command layers
- UTERM-016, for the editable document, Save, undo, and the unsaved-work prompt. M1 to M3 are built. M4 is not
  started. See question 11.
- UTERM-015, for the path-reading power

## Impacts

- UTERM-008 — "Where pins come from": the command-source bullets. Every command names a layer. A command cannot touch
  the file layer. `set-layer` replaces a whole layer. The default layer is shared by every caller. The per-layer cap, the
  32 KiB script bound on a layer, and Clear Program Pins. Superseded in part.
- UTERM-008 — the description section: the bullets that command layers ride in the undo-only part, show "From an
  earlier run" after a reopen, and count in the payload's `commandLayerCount` with a relaunch notice. Superseded in
  part.
- UTERM-008 — M3 and its As built: the layer store, the layer caps, the per-layer accents, the `pin-selected` event's
  layer field, and the "From an earlier run" callout. Superseded in part.
- UTERM-016 — "Scripts may edit the file, and only the user saves", M4, and the Impacts line on UTERM-008's "Where pins
  come from". May be superseded in part, depending on question 11.

## Summary

A program's `add`, `remove`, `clear`, and `set-layer` edit the map's document, as the user's pin actions do. The edits
undo, mark the map unsaved, prompt at close, and are written by Save. Command layers retire. Authority gates which
programs may edit.

## Motivation

ADR-15 says a program's operation is the user's operation, carried out through the program. It behaves as the user's
does. Only authority stays apart. The user ruled on 2026-11-21 that this applies to a program's pins on the map.

Today the two differ in every way a user can see. A program's pins live in named command layers
(`Packages/UnitermKit/Sources/GeoData/CommandPins.swift`, `MapViewerApplet+Remote.swift`). A user's pins are edits to
the open GeoJSON document, from UTERM-016.

- The user's edit is one undo step. A program's command has no undo.
- The user's edit marks the map unsaved, and closing asks. A program's pins never mark it unsaved.
- Save writes the user's pins to the file. Save never writes a program's pins.
- A closed pane's program pins show "From an earlier run" after a reopen
  (`MapViewerApplet+Remote.swift:185`). They are gone at relaunch.
- A command cannot touch the file layer. The command refuses `source: file`
  (`MapViewerApplet+Remote.swift:81-86`). The user can edit only file pins.

A program's pins then look like a different kind of pin. They sit in a separate set the user can only clear in bulk.
ADR-15 names this pattern: a guard on one source that makes the same action mean two things.

UTERM-008 and UTERM-016 hold related text. UTERM-008 is implemented, so its text is frozen. UTERM-016 is accepted, and
its M4 is not started. Question 11 asks how this proposal and M4 fit.

## Design Decisions (Settled)

### A program's pin commands edit the document

Decision: `add`, `remove`, `clear`, and `set-layer` edit the map's document, through the path the user's pin actions use.

- Each command is undoable, as the user's edit is. A command is one undo step.
- A command marks the map unsaved. Closing a pane, a window, or the app asks Save, Don't Save, or Cancel, as UTERM-016
  "Unsaved work on close and quit" sets.
- Save writes a program's pins to the file, byte-patched as UTERM-016 "A save patches the file's bytes" sets.
- A program may edit the file's pins, and the user may edit a program's pins. After this change there is one set of
  pins.
- Command layers retire. The layer store, the undo-only layer snapshot, the "From an earlier run" mark, and Clear Program
  Pins go away. The user's Clear File Pins and Undo remain.
- Only the user saves. A program has no write command. Writing the file stays the user's Save. This is UTERM-016's rule
  and needs no new write power.

Rationale: a program's operation behaves as the user's, per ADR-15. The user's pin action is the same operation. An
action means one thing, whoever starts it. What it leaves behind is the same, so a program's work never goes missing at
the next launch because of who did it. Chosen by the user on 2026-11-21.

### Authority gates writing

Decision: whether a program may edit the document is decided before it edits, by authority, and an edit that is allowed
is not weakened.

Rationale: this is ADR-15's authority carve-out. UTERM-016 "Scripts may edit the file, and only the user saves" already
gates a script's edit on the path-reading power, since the commands and their replies reveal the file's pin IDs. The
shape of the gate here is open. See "What power lets a program edit the document".

## Design Decisions (Open)

### What power lets a program edit the document

Settled: authority gates writing. Open: which power.

- Option A: the path-reading power over the open file, as UTERM-016 M4 settled it. A map with no file, and a file outside
  the caller's scope, are then not editable by that caller. Today's pin commands need only pane control, so a driver
  that edits a map it started would now need a path grant.
- Option B: pane control alone, as today's commands need. A program with control of the pane edits the document. The
  commands and replies then reveal file pin IDs to a caller with no path grant. UTERM-015 "The path-reading power"
  says that a caller outside the scope gets no path or content detail from the source.
- Option C: pane control, and the path-reading power only when the pane holds a file. A pane with no file has no
  content to protect.

### A map with no file, and a file out of scope

The user's pins on a map with no file are unsaved pins, and Save asks where to write them (UTERM-016 M2). Whether a
program's pins on such a map behave the same, and what a caller out of the file's scope sees, depends on the gate above.
Candidates:

- A program edits the unsaved document of a map with no file. Save asks where to write.
- A program edits only a map that shows a file.
- A caller outside the file's scope edits, and its replies carry no pin IDs or content from the file.

### The `layer` and `source` arguments

Every pin command takes `layer` and an optional `source` today (`MapViewerApplet+Remote.swift:30-53`, `:81-86`).
Layers retire, so these need a meaning. Candidates:

- Ignore both. A command is accepted and the argument has no effect. A driver written for layers keeps running, and
  its layers merge.
- Accept both and refuse any value but the default. A driver that names a layer gets a structured error. Nothing is
  silently merged.
- Remove both, as a new schema version. See "Wire compatibility".
- Keep `layer` as a free-text tag a pin carries in a property of the GeoJSON feature. `set-layer`, `clear`, and `remove`
  then act on pins with that tag.

The tag candidate also decides where a layer's default accent comes from.

### Pin IDs

A command pin has a caller-chosen ID, unique within its layer. `add` requires one and replaces an existing pin with it
whole, and `remove` takes one. A file pin's ID comes from file order, and a removal or a split renumbers the later pins
(UTERM-016 M2 As built). Candidates:

- Keep caller IDs as a property in the feature, such as `uniterm:id`. A command finds a pin by that property. A pin the
  user placed has none, and cannot be removed by a command.
- Use file-order IDs for every pin. A command's ID is then unstable across edits, and a program must read the IDs back
  after each edit.
- Give each pin a stable ID that the file stores. Every pin the user places also gets one.

### What `clear` and `set-layer` act on

`clear` empties a layer and `set-layer` replaces a layer's whole contents in one command. With no layers, either can
reach the user's own pins. Candidates:

- Both act on every pin in the document, including the user's. One undo step restores them.
- Both act on pins the program placed, found by the tag or ID property in the candidates above. The user's pins stay.
- Drop `set-layer` and `clear`. A program uses `remove` for each pin. A rerun script then cannot replace its earlier
  pins atomically, which UTERM-008 "Where pins come from" built `set-layer` to allow.

Also open: whether a `set-layer` is one undo step, and whether it is refused whole past a cap, as today.

### The `pin-selected` event

`pin-selected` names a command pin by layer and ID today. For a file pin it carries only a source marker, never the pin's
ID or any value from the file (`MapViewerApplet+Remote.swift:270-287`). Candidates:

- Every pin sends its ID, to a driver whose scope allows the document's pins. Other drivers get the marker.
- Every pin sends the marker only, and a program learns IDs from its own edits.
- Keep the event as it is while a pin carries a layer tag, and send the marker for a pin with none.

### The payload's `commandLayerCount` and the relaunch notice

The payload holds `commandLayerCount`, and a restore with a count above zero posts a notice that program layers were not
restored (`MapViewerDescription.swift:38-61`, `MapViewerApplet+Remote.swift:235-240`). ADR-06 gives the map its own
payload version. Candidates:

- Bump the payload version, drop the field, and drop the notice. An older build reads the new payload as unknown and
  keeps its bytes, per ADR-06.
- Keep reading the field and never write a count above zero. No bump, and an older build still reads the payload. The
  field stays as dead data.
- Bump the version, and keep a one-time notice for a layout that still holds a nonzero count from before this change.

### Wire compatibility for existing drivers

A map's command schema is versioned, and an older driver must keep working, per UTERM-008 "Risks" and ADR-13. `add`,
`remove`, `clear`, and `set-layer` at schema 1.0 mean "act on a command layer". The new meaning acts on the document.
Candidates:

- Redefine them at 1.0. This breaks UTERM-008's rule that a version keeps its meaning.
- Publish the new meaning as schema 2.0, and keep 1.0 working. The map then keeps a layer store for 1.0 drivers, which
  contradicts retiring command layers.
- Publish 2.0, and refuse 1.0 commands with a structured error that says why. This is a change under ADR-13, which
  requires a proposal that names the direction that fails and the programs it breaks.
- Keep the command names at 1.0 and add the edits as new commands. Existing drivers are unchanged, and the old commands
  are retired later by their own proposal.

### The caps

Commands are capped today at 624 pins per layer, 2,500 per pane, and 13 layers (`CommandPinLimits`). The per-layer cap
fits one exec frame, and a script's call stops at 32 KiB. Candidates:

- Drop the layer count and keep a per-pane cap of 2,500, with the per-command frame bound.
- Keep only the frame bound per command and use the file's existing bounds for the whole document (UTERM-016 M1).
- Keep all caps for commands, and leave the user's edits uncapped.

### A command that arrives during an edit

An edit is refused while the previous edit's pins are being read, since IDs come from file order (UTERM-016 M2 As
built). A command can arrive in that window. Candidates:

- Queue the command until the read ends, and reply after.
- Refuse it with `busy`, and the program retries.

### Whether this proposal folds in UTERM-016 M4, or depends on it

UTERM-016 M4 is accepted and not started. It adds a file-layer target to the command schema, gated by the path-reading
power, and a pin list that shows program layers read-only with a Clear action. This proposal also changes how a program
edits pins.

- Fold. This proposal takes over M4's script editing, and UTERM-016 is amended to point here. One design gives one edit
  path, one ID rule, and one gate. No program ever has two ways to edit pins. M4's third check has no layers left to show,
  so it goes. The cost is amending an accepted proposal on the strength of a design that is still open, and M4's checks
  move to this proposal's M1.
- Depend. M4 is built first as written. A program then has a file-layer target beside the command layers. This proposal
  retires the command layers after, and its commands move onto the file-layer target. UTERM-016 stays untouched, and M4
  ships on its own schedule. The cost is a second edit path built only to be removed, with two ID rules and two
  behaviors in between, and M4's read-only layer rows built only to be removed.

## Risks

- **A program's pins reach the user's file** — likelihood: medium, impact: medium. UTERM-008 kept program pins out of the
  layout because they can hold secrets, such as a host name or a location from a log. Save now writes them to a file the
  user chose. Mitigation: the layout file still never holds them, and nothing is written without the user's Save.
  Accepted by the user's ruling, since a user's pin is written the same way.
- **A command rewrites or removes the user's pins** — likelihood: depends on the ID and `clear` decisions, impact: high.
  Mitigation: one undo step restores an edit, and the open questions on IDs and `clear` bound what a command reaches.
- **Existing drivers change behavior** — likelihood: high, impact: medium. Drivers and scripts built on command layers
  see a changed meaning or a refusal. Mitigation: the wire compatibility decision names the direction that fails.
- **A pin from a program has no mark** — likelihood: medium, impact: low. After this change the user cannot tell which
  pins a program placed, except by the tag candidate. Accepted: ADR-15 says the user can reproduce a program's work by
  hand.

## Milestones

### M1: A program's pin commands edit the document

**Status:** NOT STARTED

Blocked on the open decisions above.

- `add`, `remove`, `clear`, and `set-layer` edit the map's document, and each is one undo step
- A command marks the map unsaved, and closing asks Save, Don't Save, or Cancel
- Save writes a program's pins to the file, and a test proves the bytes outside the edit are unchanged
- A caller without the authority the gate requires is refused before any edit
- Command layers, the "From an earlier run" mark, Clear Program Pins, and the layer snapshot are gone
- UTERM-008 carries the markers for the replaced text, and UTERM-016 does too if question 11 changes it

## Decision Log

- 2026-11-21: Drafted after the user ruled that a program's pin commands edit the map's document as the user's pin
  actions do. They are undoable, make the map unsaved, prompt at close, and Save writes them. Command layers retire.
  Authority gates writing, as UTERM-016's path-reading rule for scripts does. The user left the mechanisms open.
- 2026-11-21: Whether to fold UTERM-016 M4 into this proposal or depend on it is open, as question 11. UTERM-016 is
  accepted and is not amended until the user decides.

## References

- UTERM-008: the map viewer and its program commands
- UTERM-016: map pin editing, whose document, Save, and undo this proposal reuses
- UTERM-015: the path-reading power
- [ADR-06](../adr/ADR-06-layout-file-versioning-and-schema-ownership.md): the payload's own version
- [ADR-13](../adr/ADR-13-outside-wires-stay-compatible-across-versions.md): wire compatibility for drivers
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): authority
- [ADR-15](../adr/ADR-15-a-programs-operation-is-the-users.md): the decisions above rest on its rule that a program's
  operation is the user's, and on its authority carve-out
