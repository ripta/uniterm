# UTERM-008: Map Viewer Applet

**Status:** accepted
**Created:** 2026-10-31
**Updated:** 2026-11-03

## Dependencies

- UTERM-001
- UTERM-004 M2 and M3: map M3's command source uses UTERM-004's shared dispatch and exec driver. It also needs the
  applet-side command and event hook and `uniterm/send-command`, which UTERM-004 "Exec wire format" names and its M3
  builds
- UTERM-013, and UTERM-002's command registry milestone: the map declares its style commands in the registry
- UTERM-015: app-level opening and Cmd-O, and the type declarations its router reads

## Impacts

- UTERM-004 — "Exec panes": the map is the write-up's example of an exec pane
- UTERM-004 — "Exec wire format" and M3: amended in this review to name the applet-side command and event hook and
  the remote applet-command call, which map M3 depends on
- UTERM-003 — "Host API": scripts place pins through `uniterm/send-command`, which UTERM-004 adds to the module
- UTERM-015 — "The path-reading power": no event reveals a value from the user's file, so the map needs nothing from
  that power

## Summary

A map viewer applet built on MapKit. It shows a map with custom points of interest.

## Motivation

Location data from scripts and logs is easier to read on a map. The write-up also uses the map as its main example of an
exec pane. A program places pins, and the user's clicks go back to the program.

## Design Decisions (Settled)

### MapKit

The applet uses MapKit's map view. Apple Maps data is available to apps this way.

### Points of interest

The applet shows custom pins, each with a coordinate and a label.

### Map styles

Original question: standard, satellite, hybrid, and whether a dark map follows the dark theme.

Decision: all three styles, chosen in the pane. Light or dark comes from the palette through the applet contract.

- The user picks standard, satellite, or hybrid in the pane. The choice uses MapKit's standard, imagery, and hybrid
  configurations, and is stored in the description.
- `apply(_ palette:)` sets the map view's appearance from the palette's light or dark flavor. Standard and hybrid
  labels follow the theme. Satellite imagery has no dark variant and does not change.
- There is no separate dark-map setting.

Rationale: the palette already reaches every applet through `apply(_:)`, so light or dark flows explicitly, as
CLAUDE.md asks. Letting the map view inherit its window's appearance would work today only because
`AppearanceController` forces the app's appearance to match the palette flavor. A per-window theme, or a sheet with its
own appearance, would split the map from the rest of the pane without anyone noticing. A per-pane always-light or
always-dark setting has no user asking for it, and would add a description field ADR-06 carries forever. Leaves undone:
nothing.

### Where pins come from

Original question: pins from a file such as GeoJSON, from a script through the UTERM-003 host API, or from an exec
program through UTERM-004, where clicks go to the program as JSON and the program adds and removes pins through its
output.

Decision: pins come from a GeoJSON file opened in the pane, and from commands over UTERM-004's shared transport. Every
pin belongs to a named layer.

- One pin store holds every pin. Loading goes through one source-taking entry point, as UTERM-009 builds it.
- File source: the user opens a GeoJSON file in the pane, with an open panel reached from an Open... registry command
  with no key in the File menu, or by dropping a file URL. The file is its own layer. Loading another file replaces
  only that layer. App-level opening belongs to UTERM-015. Its File > Open on Cmd-O routes files here by type, and this
  Open... is the pane-local open it keeps. The map declares the imported GeoJSON type, which conforms to `public.json`,
  at the owner rank. It binds no File > Open key.
- Command source: the map publishes a command schema and an event schema, both at version 1, per UTERM-004 "Exec wire
  format". The commands are `add`, `remove`, `clear`, `set-layer`, and setting the visible region. Exec drivers and
  authorized remote callers both use them, through UTERM-004's shared validation and serialized dispatch.
- Each command names its layer. An exec driver that names none uses a fixed default layer. Pin IDs are unique within a
  layer. `add` requires an ID, and an existing pin with that ID is replaced whole: an omitted accent or glyph takes the
  default, never the earlier value. `set-layer` replaces a layer's whole contents in one command. `clear` and `remove`
  act on the named layer only.
- The per-layer pin cap is sized so a full `set-layer` fits in one UTERM-004 frame. A `set-layer` past a cap is
  refused whole, with no effect.
- The file layer is outside the command namespace. No layer name a command can send refers to it, so commands cannot
  add to, remove from, or clear the file's pins. Only the user and file loading change it.
- Layers are namespaces, not authority. Every command is authorized against the pane at dispatch, per ADR-09. Any
  caller authorized for the pane may address any command layer. A layer name is never proof of who placed a pin.
- A script run again, or a driver restarted, sends `set-layer` for the same layer and replaces its own earlier pins.
  A restarted exec driver therefore finds the previous driver's pins in the default layer until it does. This is a
  stated rule of the schema, not state a library carries.
- The user can clear any layer from the map's own UI.
- Events go only to the exec driver, since UTERM-004 defines no other event channel. `map clicked` carries the
  coordinate of a click on the map. `pin selected` names a command pin by its layer and ID. For a file pin it carries
  only a file-source marker, never the pin's ID or any other value from the file. A click on a file pin sends that
  marker and no `map clicked`, so the pin's stored coordinate never reaches the driver.
- UTERM-004 owns the applet-side command and event hook, and the remote host call that carries applet commands,
  `uniterm/send-command`. Each remote command names the applet type and schema version it targets. UTERM-004 was
  amended in this review to name both, and its M3 builds them. Map M3 depends on both.

Amended 2026-11-03; see Decision Log.
- The map declares exec with disconnected or remote-controlled access, per UTERM-004 "Control modes and exec drivers".
- A script sending a whole GeoJSON document through `uniterm/send` is deferred.

**Revisit:** when a UTERM-003 or UTERM-004 milestone builds delivery of `uniterm/send` data to a viewer applet, decide
whether whole-document sends join the file source's entry point.

Rationale: the Motivation names both scripts and the exec example, so neither the file nor the command source can be
dropped. UTERM-004 already routes exec drivers and remote callers through one validation and dispatch path. A separate
path for `uniterm/send` would be a second route from program to pane, and no UTERM-003 milestone builds delivery to a
viewer. One shared pin namespace lets a driver's `clear` wipe the file's pins and lets IDs from two callers collide.
Owning pins per live connection fails the common case instead. UTERM-003 runs each `uniterm run` in its own process,
and a UTERM-004 restart starts a new one. Neither could then remove the pins of the run before it, so they would pile
up until the user cleared them by hand. `set-layer` makes a rerun atomic: clearing and then adding would draw a partial
layer that the user could click, and a driver dying midway would leave it partial. Keeping the file layer out of the
command namespace makes a collision with the user's file impossible to express, instead of a reserved name to check.
Leaves undone: events for scripts and remote callers, which UTERM-004 does not offer; whole-document script sends,
until the hook fires.

### Pin styling

Original question: colors, icons, and grouping of nearby pins.

Decision: each pin may carry a palette accent and a glyph. Colors are palette tokens only. Pins cluster within their
layer.

- A pin's color is one of the palette's accent tokens, so it follows the light or dark theme. Raw colors are never
  carried, per `ThemeToken`'s rule that applets read colors by token.
- A pin's glyph is an SF Symbol name, or one or two characters. The marker body is the pin's accent. The glyph sits on
  a small inner disc of the flavor's `base` in Latte or `crust` in Mocha, drawn in `text`. Contrast then rests on one
  token pair per flavor, about 7:1 in Latte and 13:1 in Mocha, whatever the accent. Cluster counts use the same disc.
  Amended 2026-11-03; see Decision Log.
- A pin with no accent uses its layer's default accent. A layer keeps its default accent for the pane's life, even
  after it is cleared and refilled.
- Pins with the same layer cluster together when zoomed out. Pins from different layers never share a cluster.
- Commands validate the accent against the closed set of accent tokens. An unknown accent is an invalid argument, and
  the command returns a structured error with no effect, per UTERM-004. An SF Symbol the running macOS lacks is not a
  schema error, so it falls back to the default glyph.
- From a GeoJSON file, a simplestyle `marker-color` maps to the nearest accent. A one-character `marker-symbol` becomes
  the glyph. Maki icon names are ignored. A uniterm-specific property can name an accent and a glyph directly. Values
  the map cannot use fall back to the defaults, and one pane message gives their count.

Rationale: a file is always one layer, so per-pin styling is the only way to show a file's own categories. Accent
tokens keep every pin readable in both flavors, and per-layer clustering keeps one caller's dense pins from merging
with another's. Hex colors would break the palette's token-only rule and could vanish against one of the two map
appearances. Per-layer styling alone would leave a file's categories one color, and adding per-pin fields later would
need a new schema version. A glyph drawn straight on the accent cannot be readable everywhere: Latte `base` falls below
3:1 on 9 of 14 Latte accents, and the better of `text` or `base` still leaves six below 3:1. A halo would thin that
margin to an outline, and dropping accents would narrow the set categories need. Leaves undone: two file colors
nearest the same accent show as one color, and Maki icons are not drawn.

### The applet contract

Original context and question: Context from UTERM-001, which shipped the applet contract. ADR-05 and ADR-06 cover its lifecycle and its description
versioning. An ADR for the rest of the contract is a candidate in UTERM-001's Decision Log. This proposal may reshape
it, so it is not written yet. Every applet implements:

- A view the pane hosts, a title, and status bar segments.
- `start`, `focus`, and a palette update.
- `detach`, `reattach`, and `close`. uniterm sends these lifecycle events, and each applet owns its response, per
  ADR-05. On detach an applet pauses audio, video, and alerts at once. uniterm keeps no closed applet alive. An applet
  that keeps work going after close owns its bound and a visible indicator.
- `isRunningSomething` and `runningLabels`. Closing a pane, a window, or the app asks first when an affected pane is
  running something, and the dialog names it.
- `describe()`, an inert description with a type and a per-type version. Undo and layout restore both rebuild the
  applet from it, in the same place. Undo is not a snapshot of running state. An applet that wants undo to bring back
  more saves it in its description. ADR-03 says restoring it never runs a program the user did not ask for. ADR-06
  says the applet owns its payload and its version. It upgrades its own older versions, and bumps the version on any
  change an older build cannot round-trip. A description this build cannot read is kept byte-for-byte.

For the map viewer: a description likely holds the visible region and where the pins came from. When pins came from a
program's output, restoring must not run that program again. "Where pins come from" adds constraints: pins in command
layers had no file, so the description must either hold them or restore without them and say so. The layer structure
and the payload version are fixed by whichever is chosen.

Decision: this proposal makes no change to the applet contract. Its input and event hook is UTERM-004's to add, per
"Where pins come from". Command layers are kept in memory for reopen only, and never written to the layout file.

- The payload has its own version, per ADR-06. It holds the visible region, the map style, and the file layer's
  default accent. For the file layer, it holds the file's absolute path, a macOS bookmark fallback, and the pane's start
  directory, following UTERM-009: the path wins while a regular file is there, bookmark resolution runs off the main
  thread in `start()`, and `describe()` never touches the disk.
- The pane reports `currentDirectory` as the open file's folder, or else its start directory. The open panel starts
  there, never in the panel's own remembered directory.
- Command layers, with their names, default accents, and pins, go into the description's undo-only part, which
  UTERM-013 added. Reopening a closed pane in the same launch brings them back, marked as from an earlier run until a
  source writes the layer again. A reopened exec pane shows UTERM-004's Run action. A new driver started by Run finds
  the earlier driver's pins in the default layer, under the rule "Where pins come from" states.
- The payload holds one number about command layers: how many distinct layers held pins in this launch. The set of
  counted names rides in the undo-only part, so a rerun or a reopen in the same launch does not raise it. Each launch
  starts counting from zero. `start()` reads the stored count only to show, when it is above zero, a notice that that
  many program layers from the last session were not restored. Amended 2026-11-03; see Decision Log.
- An exec declaration and its desired modes are the host's, saved outside the payload, per UTERM-004 "Saved layouts".
  Restore runs nothing, per ADR-03.

Rationale: pin labels and coordinates come from program output, which can hold secrets such as host names or a person's
location from a log. UTERM-001 kept scrollback off disk for that reason, and UTERM-013 kept closed tabs' directories off
disk. Writing pins into the layout would also persist them in older builds byte-for-byte after a downgrade, per ADR-06,
and every pin command would rewrite the layout file. Layer names are caller-chosen program output too, so they stay
off disk with the pins, and the count rewrites the layout at most once per new layer in a launch. The undo-only part
keeps an accidental close recoverable without any of that. A restore-time callback to the last source would restore nothing, since no source survives a close, and
would make the host track a hidden "last source" for each pane. A script that wants pins to outlast a relaunch writes a
GeoJSON file. Leaves undone: pins from a script are lost on relaunch unless the script is run again.

## Design Decisions (Open)

None.

## Risks

- **MapKit needs network access and may need an entitlement** — likelihood: medium, impact: low.
  Mitigation: confirm the entitlements in M1. Show a clear message when the map cannot load.
- **M3 rests on UTERM-004 parts that are designed but not built** — likelihood: medium, impact: medium. UTERM-004 is
  accepted but unbuilt. Its amended M3 builds the applet-side hook and `uniterm/send-command`, and their shape may
  shift while it is built. Mitigation: M1 and M2 depend only on built proposals and UTERM-009's gate. M3 starts only
  after UTERM-004's M2 and M3. Amended 2026-11-03; see Decision Log.
- **The command and event schema becomes a contract external programs depend on** — likelihood: high, impact: medium.
  Drivers and scripts written against version 1 break if its meaning changes. Mitigation: the schema is versioned from
  its first release, and UTERM-004's hello exchange refuses an unsupported version in both directions before any
  effect. A change an older driver cannot rely on adds a new version and never redefines an old one. The map keeps
  accepting every schema version it has published.
- **A hostile GeoJSON file corrupts or takes over the app** — likelihood: medium, impact: high. The file is parsed in
  uniterm's own process, with the App Sandbox off by design. The evidence does not settle the likelihood, so it is
  rated the higher of low and medium. Mitigation: `MKGeoJSONDecoder` and the JSON parser beneath it are OS frameworks
  that macOS updates patch. M2 bounds file size and point count, parses off the main thread, and fuzzes the parsing
  stack as shipped under a memory-error detector. This is the exposure UTERM-009 carries for its readers.
- **Map tiles reveal the regions the user views to Apple** — likelihood: high, impact: low. Pins stay local, but
  MapKit fetches tiles for every region shown, so opening a log of someone's locations sends the areas viewed.
  Accepted: tile fetching is how MapKit works, and the settled MapKit decision chose it. The map makes no network
  request of its own.
- **The payload is stored data** — every later build reads it. The design defuses the one-way door: the payload
  carries its own version per ADR-06, carries every field from its first version, and an unreadable description is
  kept, not dropped.

## Milestones

### M1: Basic map

**Status:** DONE

- A pane can run the map applet and show a map
- The user can pan and zoom
- The user can switch between standard, satellite, and hybrid, through registry commands the map declares per
  UTERM-013, and the choice survives reopen and relaunch
- Switching the theme flips a standard or hybrid map between light and dark without a relaunch, and every palette
  flavor maps to a light or dark appearance
- A stored style this build does not recognize shows the standard map
- Reopen and relaunch bring back the visible region and style. An empty pane reopens in its start directory
- A layout save never touches the disk to describe a pane, and an unchanged pane describes itself the same way twice
- The payload carries every stored field from its first version, so M2 and M3 need no version bump

**As built:**

- The map is two package targets. `GeoData` holds the region and style value types with no AppKit or MapKit. The applet
  target holds the MapKit view, the commands, and the description. The payload holds every field the later milestones
  use: region, style, file accent, path, bookmark, start directory, and the command-layer count. A test pins the stored
  key set. An absent key takes its default, and an unknown style name reads as the standard map.
- A region is checked when it is made, since MapKit raises an exception on one it cannot take. The checks are finite
  numbers, a center latitude on the globe, a positive span, and latitude edges between the poles. A longitude is wrapped,
  and a span past the globe is cut. A stored region out of range is corrupt. MapKit runs in uniterm's own process, as
  ADR-07 weighs. The guard keeps the one failure this milestone can cause from being an exception, and the app has no
  further bound on MapKit itself.
- A region is saved only after a user gesture on the map. MapKit also reports a region after one is set, after a resize,
  and for its own default on an empty pane, and none of those is saved, so an untouched pane never rewrites the layout.
  A local event monitor marks the gesture, and a settle within 0.1% of the stored region is not saved again. The gate
  was chosen over comparing reports with the applied region, because the default region of an empty pane matches no
  region the pane applied.
- The registry has no checked state for a command, so the three style commands show titles only. The status bar segment
  names the current style. A checked item would need state on `AppletCommand`, which this milestone did not add.
- `ThemeFlavor.isDark` is the explicit flavor-to-appearance rule. A test covers every flavor against its `base` surface.
  Other callers' flavor checks are unchanged.
- A failed map load shows a banner over the map and posts a warning. The banner clears when the map loads, and the map
  stays usable under it.
- MapKit needs no entitlement here. The App Sandbox is off and the project has no entitlements file, so nothing limits
  the network access that tile fetching uses. The map does not use Core Location. The app builds and links with the
  hardened runtime on. A tile fetch against the live service was not run in this milestone.
- The package tests cover the style commands, the palette appearance for every flavor, region settle, restore, and
  describe. The UI tests are built but not run by the implementer.
- Left to the user: the look of the map in both flavors and all three styles.

### M2: Pins from a file

**Status:** NOT STARTED

- The user opens a GeoJSON file from an open panel or by dropping a file URL on the pane, and its points show as pins
- Every load goes through the one source-taking entry point, and the map binds no File > Open key
- The Open... command with no key opens the panel, and the map declares the imported GeoJSON type at the owner rank,
  for UTERM-015's router
- Selecting a pin shows its label
- Point and MultiPoint features become pins. Other geometry is skipped, and a message gives the count
- One documented rule picks a feature's label from its properties
- Parsing runs off the main thread. A malformed, huge, or non-regular file shows a message in the pane and never stalls
  the UI
- A fuzzing run with malformed GeoJSON, through the parsing stack as shipped and under a memory-error detector, finds
  no crash and no memory error
- Loading a second file replaces only the file's layer
- The user can clear a layer from the map's own UI. Clearing the file layer drops its stored path and bookmark, so a
  relaunch does not bring the pins back
- File pins get IDs by one documented rule, unique within the file layer even when GeoJSON `id` values are missing or
  repeat
- The file layer has its own point bound, separate from the command caps, and a file past it loads its first points
  and says so
- `marker-color` maps to an accent once, against one reference flavor, so a pin keeps its accent across theme switches
- A feature's accent and glyph come from one documented rule over simplestyle and uniterm's own property keys.
  `marker-color` maps to the nearest accent by a documented perceptual rule, pinned by a test
- Layer default accents follow a fixed, documented order chosen so neighbors are distinct, such as never rosewater
  then flamingo
- Glyphs and cluster counts sit on the neutral disc and reach at least 4.5:1 on every accent in both flavors, as
  rendered, not only as computed. The disc and glyph colors come from `Theme`, with a contrast test there
- A theme switch re-tints existing pins and clusters without a reload
- Pins in one layer cluster when zoomed out, and pins from two layers never share a cluster
- Reopen and relaunch bring back the file's pins. A file moved after the save is found through its bookmark, and the
  pane says where. A new file at the stored path wins over the bookmark
- The open panel starts in the pane's `currentDirectory`, never in the panel's remembered one
- A missing, unreadable, or privacy-protected file shows a message that says which, never "corrupt"

### M3: Pins from programs

**Status:** NOT STARTED

- An exec driver adds, removes, clears, and replaces pins with `set-layer`, and sets the region, through the map's
  version 1 command schema
- An authorized remote caller does the same through the same validation and dispatch
- `clear` and `remove` touch only the named layer, and an exec driver with no layer named uses the default layer
- A restarted driver, or a script run again, replaces its own layer's pins instead of adding a second copy
- `map clicked` and `pin selected` reach the exec driver. `pin selected` names a command pin's layer and ID, or marks
  a file pin by its source field with no ID, coordinate, or other value from the file
- A click on a file pin sends no `map clicked`
- No command can add to, remove from, or clear the file layer, and a command naming the file's source gets a
  structured error
- `add` with an existing ID replaces the whole pin, and an omitted accent or glyph takes the default
- Pin ID, label, and glyph lengths are capped in code points or UTF-8 bytes, never graphemes. The per-layer cap is
  sized from their worst-case escaped JSON, with every code point escaped and numbers at a fixed canonical length, so a
  full layer always fits one `set-layer` frame and UTERM-004's decoded-memory and per-turn work bounds
- A `set-layer` is staged and swapped in whole, so a partial layer is never drawn. The per-pane cap counts it after
  removing the old pins of the layer it replaces
- A `set-layer` past the per-layer, per-pane, or layer cap is refused whole, with no effect
- A map with a live exec driver reports `isRunningSomething`, and the close dialog names the driver
- Pins per pane and per layer are capped, and an add past the cap returns a structured error
- A driver or caller with an unsupported schema version is refused before any pin changes, in both directions
- The published schema documents every command and event with examples, per UTERM-004
- An unknown accent token returns a structured error and changes nothing. A missing SF Symbol shows the default glyph
- A layer keeps its default accent after a clear and re-add
- Selecting a cluster expands or zooms it and sends no `pin selected`. Only a single pin sends one
- Reopen brings back command-layer pins, marked as from an earlier run until a source writes that layer
- No command layer name, accent, or pin is ever written to the layout file. Only a new layer holding pins rewrites
  the layout, at most once per layer per launch, plus one rewrite after a relaunch that resets a nonzero count. A
  rerun, or a reopen and rerun in the same launch, does not
- A reopen that carries the undo-only part shows no notice and keeps its count and counted names. Only a rebuild
  without that part shows the notice and resets the count
- After relaunch and rerun cycles, the notice gives exactly the number of layers that held program pins last session,
  worded so it never claims pins were lost from a layer the user had cleared
- After a relaunch, a notice gives how many program layers were not restored, and appears only when that count is
  above zero
- Layers per pane are capped, empty ones included, and layer names have a length cap. A new layer past the cap returns
  a structured error

## Decision Log

- 2026-10-31: Drafted from the original write-up without an interview. The open questions hold everything undecided.
- 2026-11-01: Added "The applet contract" with context from UTERM-001's implementation.
- 2026-11-03: Review start: 2 milestones, 2 settled decisions, 1 risk, no `**Live after:**` lines or row gates, no
  out-of-scope statements; proposal at commit "Merge pull request #14 from space-armada/agent/petunia". The user asked
  for a design review of the open questions, in autonomous mode, with one commit at the end.
- 2026-11-03: Map styles: standard, satellite, and hybrid, chosen in the pane. Light or dark is set from the palette in
  `apply(_:)`, never inherited from the window. No dark-map setting. Converged in 1 pass. Routed theme-switch, style
  persistence, and unknown-style checks to M1. (autonomous)
- 2026-11-03: Where pins come from: a GeoJSON file opened in the pane, and commands over UTERM-004's shared transport,
  with every pin in a caller-named layer. Layers are namespaces, not authority. Events reach only the exec driver.
  Whole-document `uniterm/send` is deferred under a revisit hook. The judge ruled after 3 passes on the budget trigger.
  The critic's top moved to a new missing option each pass: two sources, then per-connection ownership, then layers.
  Per-connection ownership was rejected because a rerun script or a restarted driver could not remove its
  predecessor's pins. Added M3 for program pins and dependencies on UTERM-004 M2 and M3. Routed GeoJSON parsing,
  pin caps, and schema-skew checks to M2 and M3. A restarted driver inheriting the default layer's pins is a stated
  schema rule, raised for the gate per CLAUDE.md "Applet Attributes". (autonomous, judge)
- 2026-11-03: Pin styling: per-pin palette accents and glyphs, with a stable per-layer default accent and clustering
  within each layer. Commands reject unknown accents. GeoJSON `marker-color` maps to the nearest accent, and a
  one-character `marker-symbol` becomes the glyph. Converged in 1 pass. Routed accent mapping, accent order, glyph
  contrast, re-tinting, and cluster-selection checks to M2 and M3. (autonomous)
- 2026-11-03: The applet contract: no contract change. The payload holds the region, style, layer accents, and the
  file's path, bookmark, and start directory, following UTERM-009. Command-layer pins live in the undo-only part, so
  reopen brings them back and the layout file never holds them. Converged in 1 pass, after the critic's data-safety
  objection moved the recommendation away from storing pins inline. Routed reopen marking, layer caps, the relaunch
  notice, and restore checks to M1 to M3. A driver started by Run after a reopen finds the earlier driver's pins in the
  default layer, raised for the gate per CLAUDE.md "Applet Attributes". (autonomous)
- 2026-11-03: Coherence review, full pass: SOUND WITH CAVEATS. Two weak decisions reopened and three design gaps
  opened. Each converged in 1 pass. Seven implementation findings routed to M1 to M3, and UTERM-009's file-opening
  gate added to Dependencies. (autonomous)
- 2026-11-03: Pin styling amended. A glyph on a bare accent could not be readable: Latte `base` falls below 3:1 on 9
  of 14 accents, and the better of `text` or `base` still leaves six. Glyphs and cluster counts now sit on a neutral
  disc of `base` or `crust`, drawn in `text`, at 7:1 or better on every accent. The text before said glyphs are drawn
  in the palette's on-accent color. (autonomous)
- 2026-11-03: The applet contract amended. Command-layer names and accents move to the undo-only part with their pins,
  since layer names are program output and any payload change rewrites the layout file. The payload keeps a count of
  command layers that held pins, which only grows, and the relaunch notice states that count. The text before stored
  every layer's accent and the names of command layers in the payload. (autonomous)
- 2026-11-03: Where pins come from amended. `add` requires an ID and replaces a pin whole. `set-layer` replaces a layer
  atomically and is the rerun pattern, with the per-layer cap sized to fit one frame. The text before had a driver
  clear its layer first, which could leave a partial layer. (autonomous)
- 2026-11-03: Where pins come from amended. The file layer is outside the command namespace, so no command can touch
  the file's pins. The text before let any caller address any layer. (autonomous)
- 2026-11-03: UTERM-004 owns the applet-side command and event hook and the remote host call for applet commands.
  Neither UTERM-004 nor UTERM-003 names them, so UTERM-004 needs an amendment, which this review leaves to the user's
  gate. Map M3 depends on both. The critic's top option was to amend UTERM-004 now; this review edits only UTERM-008.
  (autonomous, addition: a named remote applet-command host call in UTERM-004 and UTERM-003)
- 2026-11-03: Tagged the uniterm-specific GeoJSON accent and glyph property keys in "Pin styling" as an addition: they
  bring in a uniterm-owned file convention beside the command schema. (autonomous, addition)
- 2026-11-03: Risk review. Added risks for M3's reliance on unnamed UTERM-004 parts (high likelihood, medium impact,
  mitigated by gating M3 on the amendment), the command schema as an external contract (mitigated by versioning and
  keeping every published version), hostile GeoJSON parsed in-process (rated the higher of low and medium, mitigated
  by OS decoders, bounds, and fuzzing in M2), and tile fetches revealing viewed regions (accepted). Noted the
  payload's one-way door as defused. No risk is both high likelihood and high impact. (autonomous)
- 2026-11-03: Re-check pass: not converged. Defined the command-layer count per launch, with counted names in the
  undo-only part, since a count that only grew gave a false notice after relaunch and rerun cycles. The text before
  said it counted layers over the pane's life and only grew. Moved UTERM-009's file-opening gate from M2 to M1, as
  UTERM-009 gates a viewer's first milestone. Corrected the Latte figure to 9 of 14 accents below 3:1. Listed the
  UTERM-004 amendment and UTERM-003 in Impacts. Routed field-length and cap checks to M3. (autonomous)
- 2026-11-03: Final re-check pass: converged, with no new design-level defect. The proposal loop ran 3 passes: a full
  pass, a re-check that found two defects, and a final re-check. Routed reopen-versus-relaunch notice, rewrite bound,
  notice wording, cap measurement, staged swap, and per-pane counting checks to M3. (autonomous)
- 2026-11-03: Review gate: kept all; nothing reopened. The user kept the rule that a restarted exec driver finds the
  previous driver's pins in the default layer until it sends `set-layer`, including after a reopen, as CLAUDE.md
  "Applet Attributes" asks. The user chose to amend UTERM-004 in this review, naming the applet-side command and event
  hook and the remote applet-command host call.
- 2026-11-03: Amended UTERM-004 at the user's gate choice. A re-check found two defects in the first draft: remote
  commands carried no applet schema version, and declaring combinations through the command member would have stopped
  terminal and REPL panes from being remote-controlled. Both are fixed in UTERM-004. Updated this proposal's
  Dependencies, Impacts, "Where pins come from", and the UTERM-004 risk, whose likelihood drops from high to medium
  now the parts are named. Narrowed the `uniterm/send` revisit hook to its data-delivery condition: the user settled
  its other condition, a host function that issues applet commands, by choosing the amendment. (autonomous)
- 2026-11-03: Review gate: kept all. The user kept UTERM-004's combination declarations, versioned remote commands,
  the `uniterm/send-command` name, and the narrowed revisit hook.
- 2026-11-03: Accepted by the user after the review. Acceptance does not schedule M1 to M3.
- 2026-11-03: ADR candidate (cuts across the system): program-supplied content stays out of the layout file. Declined:
  whether an applet spools data to disk is that applet's own decision, not a rule for every applet.
- 2026-11-03: Review complete. Size against Review start: 2 to 3 milestones, 2 to 6 settled decisions, 1 to 6 risks.
  The review also amended UTERM-004 at the user's request. No ADR was written.
- 2026-11-03: Scheduled as UTERM-008 M1-M2 and UTERM-008 M3 in queue.md.
- 2026-11-03: Amended "Where pins come from". `pin selected` named a file pin by a file source field and its ID, and
  the decision did not say whether a click on a file pin also sent `map clicked`. Both let an exec driver learn values
  from the user's file, which UTERM-015's path-reading power keeps from a controller whose scope does not hold that
  file. A file pin is now only marked, and a click on one sends no `map clicked`. M3's check already marked file pins
  without an ID, so the decision now matches it. Carrying the ID when the driver's read scope covers the file was
  weighed. It would tie M3 to UTERM-015 for a need no caller has stated.
- 2026-11-03: Amended "Where pins come from" for UTERM-015, the cross-applet file-opening proposal. App-level opening
  waited on that proposal, and M1 waited for it to be filed. UTERM-015 is accepted. The map gains an Open... command
  with no key and declares the GeoJSON type as owner, checked in M2. The Dependencies line names UTERM-015.

## References

- Original write-up: `~/projects/private_specs/uniterm/spec/research/original-writeup.md`, APPLET-8 and CONTROL-3
