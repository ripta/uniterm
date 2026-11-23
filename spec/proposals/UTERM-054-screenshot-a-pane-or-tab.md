# UTERM-054: Screenshot a Pane or Tab

**Status:** draft
**Created:** 2026-11-22
**Updated:** 2026-11-22

## Dependencies

- UTERM-004, for the control framework a program's capture is granted under, and its clipboard-write power
- UTERM-005, for the browser's tabs and web views
- UTERM-019, for the browser's full-page snapshot, the handle and chunked result reads, and the per-result byte cap

## Impacts

- UTERM-019 — "Full-page snapshot" and M4. The user's full-page capture uses the same route and the same clamp on pixel
  area. Whichever proposal builds it first owns the code, and the other reuses it.
- UTERM-019 — the browser capture permission. A program's capture of any applet needs a capture power. See "How a
  program's capture power relates to browser capture".
- UTERM-048 — the pane inspector lists a pane's facts. A capture of the inspector's pane is an ordinary capture, and
  the inspector needs no change.

## Summary

The user copies a screenshot of the current pane or tab to the clipboard as a PNG, or saves one to a file. Each applet
captures its own content through an optional capability, so no screen capture and no Screen Recording permission is
involved. The browser also captures a full-length page. Scripts and controllers take the same captures under a granted
power.

## Motivation

There is no way to capture a pane today. macOS's own screenshot tool needs the user to frame the pane by hand, picks up
the host's focus border and badges, and cannot see a web page past its viewport. Sharing a terminal's output, a map, or a
page as an image takes several steps and a crop.

The capture has to come from each applet. A screen capture needs Screen Recording permission. Generic AppKit view
capture renders ordinary views, but it misses content that a view does not draw itself. A web view, a map view, and the
terminal's Metal surface are all of that kind. Applied by default, it would save a blank area and report success.

No production code captures images today. The UI tests capture panes with `XCUIElement.screenshot()`, which is test-only.
UTERM-019 M4 plans a browser snapshot for controller scripts, with a handle, chunked reads, and a full-page route.

## Design Decisions (Settled)

### Each applet captures through an optional capability

Decision: capture is an optional capability sub-protocol on the applet contract, as `AppletCommandHandling` and
`TabOpening` are. The host checks for it with `as?`. An applet that does not adopt it offers no screenshot command, and
its menu items and palette entries are disabled or absent. The capability returns an image, or an error that says what
could not be captured. Capture never reads the screen, so it needs no Screen Recording permission.

Rationale: from the idea's chosen design. Each applet knows which of its views draw their own content and which do not.
ADR-05 lets each applet decide how it responds. A capability the applet lacks is unrepresentable as a command, so no
applet reports a blank capture as success.

### AppKit view capture is an opt-in helper

Decision: a shared helper renders an AppKit view hierarchy into a bitmap, through `bitmapImageRepForCachingDisplay` and
`cacheDisplay`. An applet calls it for views it knows draw themselves. It is never the default for an applet that does
not adopt the capability. An applet whose view mixes kinds, such as a toolbar over a web view, composites its own parts.

Rationale: from the idea's chosen design. The helper would save a blank area for a web view, map view, or Metal layer.
Making it opt-in keeps that failure out of every applet that did not check.

### A tab is its content; a pane is the applet's view

Decision: a tab screenshot is the selected tab's content alone, without the tab bar or toolbar. A pane screenshot is the
whole applet view, including the applet's own tab bar and toolbar. Both leave out what the host draws around and above
the applet: the gutter, the focus border, the control and asking badges, and the exec strip. The window's status bar
belongs to the window and is never part of a pane.

Rationale: from the idea's chosen design. The host places its frame and overlays as siblings of the applet view, so
capturing the applet view already leaves them out. The user's screenshot then shows what the applet shows, with no host
state in it.

### Copy and save are separate commands

Decision: the user gets Copy Screenshot, which puts a PNG on the general pasteboard, and Save Screenshot As…, which opens
a save panel for a PNG file. The save writes atomically off the main thread, through the map viewer's Save As route: a
uniquely named temp file beside the target, swapped in with `replaceItemAt`. A failed write raises an alert that names
the file and keeps the earlier one.

Rationale: the user chose both. Copy serves pasting into a chat or a document. Save serves keeping a file.

### The browser captures the viewport, and offers a full page

Decision: the browser's tab and pane screenshots capture the visible viewport through `WKWebView.takeSnapshot`. A
separate full-page command captures the whole document, through UTERM-019's "Full-page snapshot" route: `takeSnapshot`
with a rect covering the content size, or rasterized `createPDF` output when WebKit leaves the off-screen part blank. The
pixel area is clamped before rendering, as UTERM-019 settles. The full-page command exists only for the browser, and
captures the tab's content without chrome.

Rationale: the user chose this. The plain command matches every other applet. A full-length page is the one capture the
macOS tool cannot take. Reusing UTERM-019's route keeps one full-page implementation and one clamp.

### Capture never blocks the main thread

Decision: a capture starts on the main thread and returns. View rendering and WebKit's completion handlers run on the
main thread, as AppKit and WebKit require. PNG encoding and the file write run off it. While a capture is pending, the
pane shows a pending state, and a second capture of the same pane is refused until it finishes. A capture has a time
bound, and its pending state can be cancelled. A capture that fails or times out shows an alert that names the pane and
the reason. Taking a screenshot never moves focus.

Rationale: ADR-08. A full-page snapshot and a large PNG encode take time uniterm does not bound. ADR-07 keeps a failed
capture to that pane.

### Scripts and controllers capture too

Decision: a script or controller can capture a pane or tab of any applet that has the capability, and the browser's full
page. A capture needs an authenticated requester and an explicit, revocable grant under ADR-14 P7. The grant names the
operation, its targets, and a bound under ADR-14 P15. The reply follows ADR-11, and "Where a program's capture command
lives" settles its shape: a handle with a completion event, or a pending reply for a capture that only reads. Retained
results are capped per result and per run. A program's copy
to the clipboard also needs the clipboard-write power, which is separate under ADR-14 P8. A capture behaves as the
user's command does, under ADR-15, except for authority. "Where a program's capture command lives" settles the command,
the handle's home, and the event stream. Amended 2026-11-22; see Decision Log.

Rationale: the user added this to the scope. One capture path serves the user and programs, so the two cannot drift.

### Version skew

Decision: the deploy units are the app, external exec drivers and controllers, controller descriptors, and the
controller policy file. The Janet helper and ScriptWire ship together in the app bundle, so they are not skewed. A
newer user script on an older app gets an unbound-symbol error.

- New driver, old app: the capture command rides the existing `command` or `paneCommand` frame, so the old app answers
  with its error for an unknown command or `unsupported-version` for a newer schema, under ADR-13. The terminal, REPL,
  questions, and data viewer take no commands today, so an older app answers a capture of them with `refused` and "this
  pane's applet takes no commands". `refused` is also the code for a failed authority check, so the message text is
  what tells a driver that the app is too old. A new frame type
  would end the driver on an older app, since the exec protocol treats an unknown type as malformed. So a new frame
  type waits for UTERM-028's version negotiation.
- Old driver, new app: no earlier command changes meaning.
- New descriptor, old app: a descriptor that names the capture power is refused at load, as UTERM-004 format 2 refuses
  every unknown kind. A controller that needs capture states it, and runs only on an app that knows it.
- Old descriptor, new app: a descriptor without the capture power gets none. A grant stored before the power existed
  covers none of it, under ADR-14 P10.
- New policy file, old app: once the user approves the capture power, the policy file holds a kind the older app lacks.
  An older uniterm then loads no policies, marks the file read-only, and remembers no trust until the user upgrades.
  This is UTERM-004's designed behavior for every new kind, and UTERM-019 states the same direction. Accepted.

## Design Decisions (Open)

### How the terminal captures

libghostty v1.4.0 has no call that reads back the rendered frame. It installs its own layer on the view uniterm passes
it, so the AppKit helper will likely capture a blank area. It can read back the screen's text, as the accessibility value
already does. Candidates:

- Read the surface's layer contents. If the layer is IOSurface-backed, copy the IOSurface into a bitmap. Needs a spike
  on the pinned build. Reaches into a layer libghostty owns, so the read stays inside the terminal surface module behind
  a protocol addition, per ADR-01. Leaves undone: a libghostty upgrade can change the layer silently.
  The renderer thread may write the surface while uniterm reads it, so a read can tear unless it locks the surface. An
  occluded or minimized view may hold a stale frame.
- Add a readback call to libghostty as a local patch, beside the three in `ThirdParty/ghostty-patches/`. Draws the
  frame into a caller's buffer on the renderer's terms. Adds patch upkeep on every upgrade.
- The same patch, also sent upstream, so the upkeep ends once a release carries it.
- Render the screen's text and styles into an image in uniterm. Loses images drawn by the terminal, ligatures, and the
  exact font rendering, so it is not a screenshot of what the user sees.
- The terminal and REPL do not adopt the capability. Leaves undone: the most common pane gets no screenshot.

### Which commands the user sees

A tab capture leaves out the applet's tab bar and toolbar, so a tab and a pane differ in any applet with chrome. The map
viewer has a pin list, and the text viewer has a find bar and a contents sidebar. The terminal hides its tab bar below
two tabs, so a single-tab terminal gives the same image for both. Candidates:

- Four commands for every capable applet: Copy and Save for each of tab and pane, with no hiding rule. A tab and a pane
  may give the same image.
- Two commands, Copy and Save, that capture the pane, plus tab variants only where the applet has a tab bar.
- Tab variants that follow whether the tab bar shows, so a single-tab terminal offers only the pane pair.
- Two commands that capture the tab, with the pane variant in the palette only.

Whichever is chosen, each applet's milestone states what its tab content is.

The browser's full page adds a Copy and a Save of its own under each candidate.

### What an unselected tab or a hidden pane captures

The user always captures the selected tab of a showing pane. A program can name an unselected tab, a pane in a
background window, or a pane whose window is minimized. A web view not in a window may have nothing current to render,
and the terminal may have no current frame. Candidates:

- Capture what the applet can render, and return a structured error that names the reason when it cannot. Each
  applet's milestone records which cases work.
- Refuse every capture that is not of a selected tab in a showing pane.
- A program's capture always takes the pane's selected tab, as the user's command does. A program that wants another tab
  selects it first with the existing select command, under pane control. Leaves undone: in a browser pane that mixes
  owners, that select switches the tab the user is looking at.
- Make the tab show itself before the capture. One call then silently does two operations, a select and a capture.

UTERM-019 M4 requires a snapshot of an unselected tab or a tab in a detached pane to work or return a structured error.
The answer here must agree with it. A stale frame that reports success is a risk under every candidate.

### How a program's capture power relates to browser capture

UTERM-019 adds a typed "browser capture" permission for a controller's own browser tabs. It also covers PDF output and
find in page. It has not shipped, so no descriptor names it yet. Candidates:

- One pane capture power covers every applet. UTERM-019 is amended before its M1 ships, since M1 creates the browser
  capture kind. Browser capture then never exists as a separate kind. The amendment says where PDF output and find in
  page go.
- One pane capture power covers every applet, and UTERM-019 M1 ships browser capture first. A grant stored for browser
  capture must not carry over to other applets, under ADR-14 P10, so the user approves the new power again.
- A new pane capture power for every applet besides the browser, and browser capture stays as UTERM-019 defines it.
  Two powers for one operation.
- A per-applet capture power. More review text, finer grants.

Every candidate names the power's bound under ADR-14 P15.

### Which panes a program may capture

A screenshot reads content the user sees, which can include other programs' panes and the user's own work. One pane can
mix owners. A browser pane holds the user's tabs beside a controller's, and UTERM-019 limits every browser command to
tabs the controller opened. A questions pane holds up to 8 requesters' tabs, with any answer the user has typed so far.
`ControlDispatcher` already refuses a command without authority over the pane. Candidates:

- Panes among the program's targets under ADR-14 P1 to P3, plus owner-level scope where a pane mixes owners. A tab
  capture needs the tab to be the program's own, and a pane capture of a mixed pane is refused.
- Panes among the program's targets, with no tab-level scope. Leaves undone: a controller reads the user's selected
  browser tab and another requester's form, which reopens UTERM-019's settled scope.
- Panes the program targets unattended, and any other pane only after the user confirms each capture. One-use consent
  is the bound.
- Any pane, under the capture power alone, with review text that says so. Names no target bound, against ADR-14 P7 and
  P15.

### How a program saves a file

Candidates:

- The program reads the bytes under the handle, and writes them with its own file access. uniterm writes nothing on its
  behalf.
- A `save-screenshot` command shows the user's save panel, as UTERM-049's `save-tabs` does. The user's pick authorizes
  the write. A program-raised panel needs a P15 bound on how often it claims the user's attention.
- Both.

### Where a program's capture command lives

Everything the program decision borrows from UTERM-019 is scoped to a browser tab: its commands are named per applet
type, its event buffer is per tab, and its handle cap is per tab. A terminal pane has none of these. Candidates:

- A host-level pane command, such as `capture-pane`, that works for every capable applet. The handle lives on the pane.
  One command name, one schema. Remote callers receive no applet events under UTERM-004, and exec drivers get events
  only from the pane they drive. So this candidate names its carrier for the completion event: a new push stream, or a
  host-level next-events buffer. The push stream adds scope: it amends UTERM-004's "remote callers receive no applet
  events" and the exec and remote wires.
- A capture that only reads holds a pending reply under ADR-11, and the reply carries the handle once the PNG is ready.
  No completion event is needed. A capture that also copies to the clipboard has an effect, so it keeps the
  handle-plus-event shape.
- Per-applet commands, such as `:terminal/capture`, each added to that applet's command schema with a schema minor bump.
  Each applet then needs its own handle slot and event delivery, which the terminal lacks.
- The browser keeps UTERM-019's per-tab snapshot, and every other applet uses a host-level command. Two shapes for one
  operation.

Every candidate rides the existing `command` or `paneCommand` frame, or waits for UTERM-028's version negotiation. See
"Version skew". The PNG bytes read back in chunks under a byte type. UTERM-019's "Result encoding" defines that type,
and it has not been built.

### How the map viewer captures

`MKMapView` draws its tiles in its own layers, so the AppKit helper may capture blank tiles. Candidates:

- `MKMapSnapshotter` with the view's region, camera, and size, plus the pins drawn over it. Re-renders the map, which
  may fetch tiles over the network and fail offline. Its image can differ from the screen, and it needs its own pin
  drawing.
- AppKit view capture, if a check shows it renders the tiles on the oldest supported macOS.
- The map viewer does not adopt the capability.

The pin list is plain AppKit and captures through the helper either way.

### Output scale, name, and place

- Scale: the window's backing scale, so a Retina screen gives a 2x image, or always 1x.
- Default file name: the pane's title with a timestamp, as macOS screenshots are named, or a fixed name.
- Default folder: the system screenshot folder, the last folder used, or Desktop.

### A default shortcut

Candidates: no default key, reached through the menu and palette and bindable in App Shortcuts, as UTERM-049's Save
Tabs As is. Or a window key under ADR-04, reserved so no page or terminal can take it. A key reserved for every pane
takes it from every web page and terminal program.

## Risks

- **A capture saves a blank or partial image and reports success** — likelihood: medium, impact: medium.
  Mitigation: capture is opt-in per applet, and each applet's milestone checks its image against what is on screen,
  including web, map, and Metal content.
- **The terminal route depends on libghostty's internals** — likelihood: high, impact: medium.
  Mitigation: the terminal milestone opens with a spike, and its result picks the route. The route stays behind the
  terminal surface protocol under ADR-01, so a libghostty upgrade breaks only that module, and a test catches a blank
  capture.
- **A program reads the user's screen content** — likelihood: medium, impact: high.
  Mitigation: a capture needs its own grant under ADR-14 P7 and P8, and review text that says it reads what a pane shows.
  "Which panes a program may capture" settles the targets.
- **A huge page or pane exhausts memory** — likelihood: low, impact: high.
  Mitigation: the pixel area is clamped before rendering, as UTERM-019 settles, and results are capped per result and per
  run.
- **The capture power becomes a published name** — likelihood: high, impact: low.
  Mitigation: the power is versioned in the descriptor format, as UTERM-004 does for every power. See "Version skew".
- **Copy Screenshot replaces what the clipboard held** — likelihood: medium, impact: low.
  Accepted: Copy Screenshot is an explicit user command, as every Copy is. A program's copy needs the clipboard-write
  power.
- **The browser and program milestones rest on UTERM-019, which has built nothing** — likelihood: high, impact: medium.
  Mitigation: the full-page route, the clamp, handles, and the byte type are all UTERM-019's. M2 builds the full-page
  route and its clamp if UTERM-019 M4 has not, and UTERM-019 reuses them. M5 waits for UTERM-019 M3 and its byte type.
- **The program decisions rest on ADR-15, which is proposed** — likelihood: medium, impact: medium.
  Mitigation: a capture's authority stays under ADR-14, which is accepted. Only the rule that a program's capture behaves
  as the user's rests on ADR-15. If ADR-15 changes, that decision is revisited before M5.
- **A stale frame reports success** — likelihood: medium, impact: medium.
  Mitigation: an occluded or minimized web view or terminal can hold its last frame. Each applet's milestone checks a
  capture of a hidden or minimized pane, and "What an unselected tab or a hidden pane captures" settles the behavior.

## Milestones

### M1: Capture contract, copy, and save

**Status:** NOT STARTED

- An applet without the capability offers no screenshot command in the menu or the palette
- Copy Screenshot puts a PNG on the pasteboard, and a test checks it through an injected private pasteboard, never the
  general one
- Save Screenshot As… writes a PNG atomically, off the main thread, and a failed write alerts and keeps the earlier file
- Replacing an existing file keeps its permissions, and two saves to one path at once each report their own result,
  including when neither found a file there
- A completion that arrives after the time bound or a cancel is dropped, and never reaches the pasteboard, a file, or a
  later capture's result
- A capture of a hidden or minimized pane returns a current frame or a structured error, never a stale frame as success.
  The test changes the content after a first capture, then hides the pane, so a stale frame would fail it
- A pane capture leaves out the host's gutter, focus border, badges, and exec strip
- A pending capture shows its state, refuses a second capture of the same pane, and never moves focus
- The pending state never appears in the captured image
- A capture past its time bound fails with an alert, and the user can cancel a pending capture
- When two copies overlap, the clipboard holds the image of the Copy the user ran last
- The image viewer, text viewer's plain text and PDF, data viewer, and questions applet capture, and each image matches
  what is on screen
- Each applet's check names its capture route, and the image viewer's names how its layer tiles render
- Each applet's check states what its tab content is
- The user takes a screenshot of each of those applets in the real app and confirms the images

### M2: Browser

**Status:** NOT STARTED

- A tab and a pane screenshot capture the viewport through `takeSnapshot`, and the pane's tab bar and toolbar appear in
  the pane capture only
- The full-page command captures the whole document through UTERM-019's route, and a page past the clamp gets a clamped
  image or a structured error
- A clamped image tells the user it was cut or scaled, and never reports a plain success
- A capture while the error page or a page dialog shows gives the image the screen shows
- A WebKit snapshot that never completes ends at the time bound, and a later capture of the pane works
- A capture of a hidden or minimized browser pane returns a current frame or a structured error
- The text viewer's Markdown, which renders in a web view, captures through the same route
- The user takes a viewport and a full-page screenshot of a long page in the real app and confirms both

### M3: Map viewer

**Status:** NOT STARTED

- The map viewer's capture shows its tiles and pins as the screen does, by the route "How the map viewer captures"
  settles
- The pin list appears in the pane capture
- A capture of a hidden or minimized map pane returns a current frame or a structured error

### M4: Terminal and REPL

**Status:** NOT STARTED

- A spike on the pinned libghostty records what each route in "How the terminal captures" produces, in the Decision Log,
  and the user picks the route from that record
- A capture taken while the terminal redraws shows no tearing
- A capture of a hidden or minimized terminal returns a current frame or a structured error
- A terminal capture matches what is on screen, including colors and a terminal-drawn image, and a test catches a blank
  capture
- No libghostty type appears outside the terminal surface module
- The REPL captures through the same route

### M5: Scripts and controllers

**Status:** NOT STARTED

Waits for UTERM-019 M3, which builds handles and read-result, and for the byte type that UTERM-019's "Result encoding"
adds.

- A user's cancel, a time-out, or a revocation of a program's pending capture fails its pending reply or frees its
  handle with a structured error, under ADR-11
- A capture without the capture grant returns a structured error that names the power
- A capture of a tab the program does not own, or of a pane that mixes owners, follows "Which panes a program may
  capture"
- A capture replies in the shape "Where a program's capture command lives" settles, and its PNG reads back in chunks
- Retained results are capped per result and per run, and a result over its cap is refused
- A program's copy to the clipboard needs the clipboard-write power as well
- A program's capture of a pane outside its allowed targets is refused
- A newer driver on an older uniterm gets a clear error for the unknown command, under ADR-13. A capture of an applet
  that took no commands gets `refused` with text that lets the driver tell an old app from a denied grant

## Decision Log

- 2026-11-22: Drafted from the "Screenshot of a pane or tab" idea. The user chose copy and save as separate commands, a
  viewport capture plus a full-page variant for the browser, and capture by scripts and controllers for every applet.
- 2026-11-22: (addition) The user added program capture for every applet to the scope.
- 2026-11-22: (addition) The user chose Save Screenshot As… beside Copy. The idea named only taking a screenshot, so
  file writing, the save panel, and the default name and folder come with it.
- 2026-11-22: Revised after the draft's design critique. "Scripts and controllers capture too" said the PNG bytes read
  back "under UTERM-019's read-result shape". That shape is scoped to browser tabs, so the command, handle, and event
  stream became the open question "Where a program's capture command lives". The grant now names a bound under ADR-14
  P15. "Version skew" was added. The save route was corrected: it said Save writes through `AtomicFile` as the map
  viewer does, but the map viewer uses its own temp-and-swap write. The thread rule was corrected: it said WebKit's
  completion handlers run off the main thread, but WebKit and view rendering run on it. A time bound and cancel were
  added to pending captures. The open questions gained options for an upstreamed terminal patch, tab commands that
  follow the tab bar, a capture of the selected tab, owner-level tab scope, and an amendment to UTERM-019 before its M4
  ships. "Or a setting" was dropped from output scale. Risks were added for UTERM-019's unbuilt parts, ADR-15's status,
  and stale frames.
- 2026-11-22: Revised after the re-check. "Version skew" said a new driver on an old app gets an unknown-command error.
  That holds only on the existing `command` or `paneCommand` frame, since an unknown frame type ends the driver, so the
  bullet now says so. It gained the policy file direction. The host-level capture candidate now names its event
  carrier, and a pending-reply candidate was added. The browser capture amendment's gate moved from UTERM-019 M4 to M1,
  which creates the kind.
- 2026-11-22: Revised after the third critique pass. "Scripts and controllers capture too" said "the command replies at
  once with a handle, and a completion event names the handle". That reply shape was this draft's own mechanism, not
  the user's choice. It contradicted the pending-reply candidate, so the shape moved to "Where a program's capture
  command lives". "Version skew" now names the `refused` answer an older app gives for an applet that takes no
  commands. These fixes were not re-checked, since the proposal loop allows three passes.

## References

- ADR-01: libghostty stays behind the terminal surface protocol
- ADR-04: uniterm owns key bindings
- ADR-05: each applet decides how it responds
- ADR-07: failure isolation
- ADR-08: UI responsiveness
- ADR-11: deferred applet replies never hide effects
- ADR-13: outside wires stay compatible across versions
- ADR-14: a controller controls what it opened
- ADR-15: a program's operation is the user's
- `spec/ideas.md`, "Screenshot of a pane or tab"
