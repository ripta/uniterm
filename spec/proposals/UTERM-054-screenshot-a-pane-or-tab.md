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
a save panel for a PNG file. The save writes atomically through `AtomicFile`, off the main thread, as the map viewer's
Save As does. A failed write raises an alert that names the file and keeps the earlier one.

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

Decision: a capture starts on the main thread and returns. WebKit's completion handlers, PNG encoding, and the file write
run off the main thread. While a capture is pending, the pane shows a pending state, and a second capture of the same
pane is refused until it finishes. A capture that fails, or produces an image over the cap, shows an alert that names
the pane and the reason. Taking a screenshot never moves focus.

Rationale: ADR-08. A full-page snapshot and a large PNG encode take time uniterm does not bound. ADR-07 keeps a failed
capture to that pane.

### Scripts and controllers capture too

Decision: a script or controller can capture a pane or tab of any applet that has the capability, and the browser's full
page. A capture needs an authenticated requester and an explicit, revocable grant under ADR-14 P7. The reply follows
ADR-11: the command replies at once with a handle, a completion event names the handle, and the PNG bytes are read in
chunks under UTERM-019's read-result shape. Retained results are capped per result and per run. A program's copy to the
clipboard also needs the clipboard-write power, which is separate under ADR-14 P8. A capture behaves as the user's
command does, under ADR-15, except for authority.

Rationale: the user added this to the scope. One capture path serves the user and programs, so the two cannot drift.

## Design Decisions (Open)

### How the terminal captures

libghostty v1.4.0 has no call that reads back the rendered frame. It installs its own layer on the view uniterm passes
it, so the AppKit helper will likely capture a blank area. It can read back the screen's text, as the accessibility value
already does. Candidates:

- Read the surface's layer contents. If the layer is IOSurface-backed, copy the IOSurface into a bitmap. Needs a spike
  on the pinned build. Reaches into a layer libghostty owns, so the read stays inside the terminal surface module behind
  a protocol addition, per ADR-01. Leaves undone: a libghostty upgrade can change the layer silently.
- Add a readback call to libghostty as a local patch, beside the three in `ThirdParty/ghostty-patches/`. Draws the
  frame into a caller's buffer. Adds patch upkeep on every upgrade.
- Render the screen's text and styles into an image in uniterm. Loses images drawn by the terminal, ligatures, and the
  exact font rendering, so it is not a screenshot of what the user sees.
- The terminal and REPL do not adopt the capability. Leaves undone: the most common pane gets no screenshot.

### Which commands the user sees

A pane and a tab differ only for applets with a tab bar: the terminal, the browser, and the questions applet. Candidates:

- Four commands everywhere: Copy and Save for each of tab and pane. For an applet with no tabs, the tab and pane
  captures are the same image, and the tab commands are hidden.
- Two commands, Copy and Save, that capture the pane, plus tab variants only where the applet has tabs.
- Two commands that capture the tab, with the pane variant in the palette only.

The browser's full page adds a Copy and a Save of its own under each candidate.

### What an unselected tab or a hidden pane captures

The user always captures the selected tab of a showing pane. A program can name an unselected tab, a pane in a
background window, or a pane whose window is minimized. A web view not in a window may have nothing current to render,
and the terminal may have no current frame. Candidates:

- Capture what the applet can render, and return a structured error that names the reason when it cannot. Each
  applet's milestone records which cases work.
- Refuse every capture that is not of a selected tab in a showing pane.
- Make the tab show itself before the capture. Moves selection under a program, which ADR-15 treats as the user's
  action, and changes what the user sees.

### How a program's capture power relates to browser capture

UTERM-019 adds a typed "browser capture" permission for a controller's own browser tabs. Candidates:

- One new pane capture power covers every applet. UTERM-019's browser capture is amended to be this power. A grant
  stored for browser capture carries over.
- A new pane capture power for every applet besides the browser, and browser capture stays as UTERM-019 defines it.
  Two powers for one operation.
- A per-applet capture power. More review text, finer grants.

### Which panes a program may capture

A screenshot reads content the user sees, which can include other programs' panes and the user's own work. Candidates:

- Only panes among the program's targets under ADR-14 P1 to P3, which is what it opened or was granted.
- Any pane, under the capture power alone, with review text that says so.
- Panes the program targets unattended, and any other pane only after the user confirms each capture.

### How a program saves a file

Candidates:

- The program reads the bytes under the handle, and writes them with its own file access. uniterm writes nothing on its
  behalf.
- A `save-screenshot` command shows the user's save panel, as UTERM-049's `save-tabs` does. The user's pick authorizes
  the write.
- Both.

### How the map viewer captures

`MKMapView` draws its tiles in its own layers, so the AppKit helper may capture blank tiles. Candidates:

- `MKMapSnapshotter` with the view's region, camera, and size, plus the pins drawn over it. Re-renders the map, which
  may fetch tiles over the network, and needs its own pin drawing.
- AppKit view capture, if a check shows it renders the tiles on the oldest supported macOS.
- The map viewer does not adopt the capability.

The pin list is plain AppKit and captures through the helper either way.

### Output scale, name, and place

- Scale: the window's backing scale, so a Retina screen gives a 2x image, or always 1x, or a setting.
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
  Mitigation: the power is versioned in the descriptor format, as UTERM-004 does for every power. ADR-13 keeps older
  drivers working.
- **A capture of the user's clipboard overwrites what was there** — likelihood: medium, impact: low.
  Accepted: Copy Screenshot is an explicit user command, as every Copy is. A program's copy needs the clipboard-write
  power.

## Milestones

### M1: Capture contract, copy, and save

**Status:** NOT STARTED

- An applet without the capability offers no screenshot command in the menu or the palette
- Copy Screenshot puts a PNG on the pasteboard, and a test checks it through an injected private pasteboard, never the
  general one
- Save Screenshot As… writes a PNG atomically, off the main thread, and a failed write alerts and keeps the earlier file
- A pane capture leaves out the host's gutter, focus border, badges, and exec strip
- A pending capture shows its state, refuses a second capture of the same pane, and never moves focus
- The image viewer, text viewer's plain text, data viewer, and questions applet capture, and each image matches what is
  on screen
- The user takes a screenshot of each of those applets in the real app and confirms the images

### M2: Browser

**Status:** NOT STARTED

- A tab and a pane screenshot capture the viewport through `takeSnapshot`, and the pane's tab bar and toolbar appear in
  the pane capture only
- The full-page command captures the whole document through UTERM-019's route, and a page past the clamp gets a clamped
  image or a structured error
- The text viewer's Markdown, which renders in a web view, captures through the same route
- The user takes a viewport and a full-page screenshot of a long page in the real app and confirms both

### M3: Map viewer

**Status:** NOT STARTED

- The map viewer's capture shows its tiles and pins as the screen does, by the route "How the map viewer captures"
  settles
- The pin list appears in the pane capture

### M4: Terminal and REPL

**Status:** NOT STARTED

- A spike on the pinned libghostty records which route in "How the terminal captures" produces the frame, in the
  Decision Log
- A terminal capture matches what is on screen, including colors and a terminal-drawn image, and a test catches a blank
  capture
- No libghostty type appears outside the terminal surface module
- The REPL captures through the same route

### M5: Scripts and controllers

**Status:** NOT STARTED

- A capture without the capture grant returns a structured error that names the power
- A capture replies at once with a handle, a completion event names it, and its PNG reads back in chunks
- Retained results are capped per result and per run, and a result over its cap is refused
- A program's copy to the clipboard needs the clipboard-write power as well
- A program's capture of a pane outside its allowed targets is refused
- A newer driver on an older uniterm gets a clear error for the unknown command, under ADR-13

## Decision Log

- 2026-11-22: Drafted from the "Screenshot of a pane or tab" idea. The user chose copy and save as separate commands, a
  viewport capture plus a full-page variant for the browser, and capture by scripts and controllers for every applet.
- 2026-11-22: (addition) The user added program capture for every applet to the scope.

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
