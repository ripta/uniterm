# UTERM-049: Save and Open Browser Tab Sets

**Status:** draft
**Created:** 2026-11-22
**Updated:** 2026-11-22

## Dependencies

- UTERM-004, for the control framework a program's call is granted under
- UTERM-005, for the browser's tabs, their stored URL and title filters, and the scheme policy
- UTERM-015, for the file router, type declarations, and the `Info.plist` drift test
- UTERM-018, for where a routed file opens when no pane can take it in place
- UTERM-021, for the powers a script file declares

## Impacts

- UTERM-005 — "Schemes" and the layout payload's URL and title filters. A tab file is a second writer and reader of the
  same filtered values.
- UTERM-015 — "How a file type maps to an applet". The browser declares its first opened types, and the app exports
  its first types.
- UTERM-018 — "Applets whose open makes a new pane". The browser joins the terminal as an applet whose panes never take
  a file in place.

## Summary

A browser pane saves its tabs to a file. The save panel's format control offers a uniterm tab-set JSON format, the
default, plus `text/uri-list` and Netscape bookmark HTML. A tab-set JSON or `text/uri-list` file opens back into a new
browser pane, and only its selected tab loads. Scripts and controllers get the same save and open under a granted power.

## Motivation

A set of open pages cannot leave uniterm today. The layout file records each tab's committed URL and title and the
selected tab, but it is one autosaved file under Application Support, so its tabs cannot be kept, shared, or reopened
on their own. No browser command copies or exports a URL.

No standard format covers a tab set fully. `text/uri-list`, from RFC 2483, is registered with IANA and suggests the
`.uris` extension. It holds one URL per line with `#` comments, and has no titles or selected tab. The Netscape
Bookmark File Format is HTML that every browser imports. It carries titles and folders, but it is a bookmark format
with a plain `.html` extension. Firefox's session files and OneTab's export are each tied to one product. A uniterm
format keeps titles and the selected tab through a round trip, and the two standard formats let the tabs reach other
tools.

## Design Decisions (Settled)

### Save Tabs As is a browser command

Decision: the browser adds a Save Tabs As… command. Its home is the File menu, beside New Tab and Open Location, and it
appears in the palette. It acts on the target pane's browser, as every browser command does. It saves every tab of
that pane.

Rationale: the browser already owns its File items through `AppletCommand` with `home: .file`. The map viewer's Save As
is the precedent for an applet's own save. ADR-04 lets an applet bind keys only for its own actions; whether this one
has a key is open.

### The save panel picks the format

Decision: the save panel shows its own format control, through `NSSavePanel.showsContentTypes` with
`allowedContentTypes` listing the tab-set type, `text/uri-list`, and Netscape bookmark HTML, in that order. The tab-set
type is the default. The written format is the panel's `currentContentType` when the user clicks Save.

Rationale: the control and its extension handling are AppKit's own from macOS 15, and uniterm targets macOS 26. A
custom accessory view would rebuild what the panel already does.

### The tab-set format carries an extension and an in-file tag

Decision: the tab-set format has a uniterm-specific extension and a `UTType` under `dev.uniterm` that conforms to
`public.json`. The file opens with a tag and a version, such as `{"type": "uniterm.tabs", "version": 1, ...}`.

- The tag decides what the file is. When the extension and the tag disagree, the tag wins.
- A build reads every version up to its own. A newer version than the build knows is an error that names the version.
- The format holds tab sets only. A shared envelope for other uniterm data waits for a second payload, and the tag
  leaves room for one.

Rationale: the extension and its type are what macOS works with: Finder, the save panel, and UTERM-015's router. The
tag keeps a renamed file, a piped script output, or pasted text self-describing. Conforming to `public.json` keeps
editors and `jq` working. The version rule follows ADR-06's pattern for the layout file and ADR-13's spirit for
outside formats, though neither governs this file.

### Saved values reuse the layout's filters

Decision: each tab saves its committed URL through `BrowserDescription.storableURL` and its title through the same
512-character bound the layout payload uses. The file records which tab is selected. A tab that has not loaded since
restore saves its stored URL and title. The save reads the browser's tabs through the applet, never its web views
directly.

Rationale: one filter keeps a saved file and a saved layout in agreement on which URLs are storable. Only http, https,
and `about:blank` pass, so a `blob:` or `data:` page never reaches a file that other tools read. ADR-05 has the applet
own its own state.

### The write is atomic and bounded

Decision: the file is written atomically, through a temporary file beside the target and a replace, as the map
viewer's Save As does. A failed write raises an error alert that names the file and keeps the user's earlier file. The
write is small and bounded, so it may run on the main thread under ADR-08.

### The browser opens tab-set and `text/uri-list` files

Decision: the browser declares the tab-set type and `text/uri-list` at the owner rank. Both are exported or imported
in `Info.plist`, as UTERM-015 requires. Netscape bookmark HTML is export-only.

- The browser's "opens no file" rule narrows. It still opens no local page, since `file:` never loads, and the text
  viewer keeps local documents.
- The tab-set type conforms to `public.json`, so it is more specific than the data and text viewers' `.json` claim and
  wins by UTERM-015's specificity rule.

Rationale: the user chose this pair. A bookmark file uses `.html`, so claiming it would take every HTML file away from
its other handlers or need sniffing.

### An opened file makes a new pane and loads lazily

Decision: an opened tab file makes a new browser pane beside the origin, by UTERM-018's rule for a file that no pane
takes in place. The browser does not replace a source, so its existing panes never take a file. The new pane holds
every tab the file lists, in order. Only the selected tab loads. Every other tab loads when first selected, as a
restored layout's tabs do.

- Each URL passes the scheme policy as a restored URL does. A refused URL keeps its tab, shows `about:blank` and an
  explanation, and keeps the URL, as a restored tab does.
- A `text/uri-list` file has no titles or selection. Its tabs show their URLs until they load, and the first tab is
  selected.

Rationale: the user chose a new pane with lazy loading. A file with hundreds of URLs then fetches one page, so the
open is bounded by the user's own selections, under ADR-03 and ADR-14 P15, without a cap or a prompt. UTERM-018
already derives "never in place" from the applet contract, so no declaration field is added.

### URLs are written as they are

Decision: export writes each storable URL unchanged. No query string or fragment is stripped, and the panel shows no
token warning.

Rationale: the user chose the file and its place. UTERM-005 accepted the same exposure for the layout file. Stripping
queries breaks pages whose query is the page, such as a search, and guessing which parameters are tokens is
unreliable.

### Scripts and controllers can save and open tab files

Decision: a script or controller can save a browser pane's tabs to a tab file and open a tab file into browser tabs.
Both behave as the user's commands do, per ADR-15. Writing the user's files is not a C1 effect under ADR-14, so the
save needs an authenticated requester and an explicit, revocable grant under P7. How the call is granted and shaped is
open.

Rationale: the user added this to the proposal's scope.

## Design Decisions (Open)

### The extension and the type identifier

Original question: what are the tab-set format's extension and its `UTType` identifier?

- `.unitabs`, with `dev.uniterm.tabs`.
- `.uniterm-tabs`, with `dev.uniterm.tabs`. Longer, and plainly uniterm's.
- Another uniterm-specific name. A generic name such as `.urljson` invites a collision with another tool.

The extension becomes a published name once a file is saved, so it is a one-way door. See Risks.

### The tab-set format's fields

Original question: what does the JSON hold beyond each tab's URL and title and the selected tab?

- **URL, title, selected only.** The minimum a round trip needs. Version 1 stays small, and later fields bump the
  version.
- **Also a save time and a set name.** A name could default to the pane's title. Helps a user with many saved sets,
  and a reader can show the name.
- **Also per-tab extras**, such as a favicon URL or a last-visited time. More to keep correct, and no current reader
  needs them.

### Tabs with nothing storable

Original question: a tab whose committed URL fails `storableURL`, or that never loaded, has no URL to save. What does
the file hold for it, and what happens to the selection when the selected tab is such a tab?

- **Skip the tab.** The file lists only storable tabs. When the selected tab is skipped, the nearest kept tab before it
  is selected, or the first.
- **Write an empty entry.** The tab-set file keeps the tab count and position, and opening it back makes a blank tab.
  `text/uri-list` and bookmark HTML cannot carry an empty entry, so they skip it either way.

### Bounds on opening a file

Original question: a tab file can list any number of URLs. Lazy loading bounds the fetches. What bounds the file's
size and the pane's tab count?

- **A byte limit on the file, no tab cap.** Like the viewers' size limits, a file over the limit is refused with a
  message that names the limit. The user can have as many tabs as they choose.
- **A byte limit and a tab cap.** Tabs past the cap are dropped, and a status line says how many.
- **No limit.** The file is read whole. A huge file stalls the main thread while it parses, against ADR-08.

### A default shortcut for Save Tabs As

Original question: does Save Tabs As get a default key?

- **None.** The palette and the File menu reach it. A later key can be added without a contract change.
- **Cmd-Shift-S.** The map viewer uses it for its Save As. It is an applet key, so the two never conflict, and it
  matches the macOS convention.

### The program call

Original question: how does a script or controller save or open a tab file?

- Which power does it use? Saving writes the user's files and reads URLs that can hold tokens. The browser-read power
  covers reading URLs and titles. A write to a path needs a power of its own under ADR-14 P8, which says one granted
  power never silently grants another. Opening a path needs UTERM-015's path-reading power.
- Does the program get the save panel, or name a path? ADR-15 asks that the operation behave as the user's, which
  shows the panel. A named path has no user counterpart, which ADR-15 allows, but the grant then needs a write scope.
- How does a program's open make a pane? UTERM-018 says a script open never creates a pane, citing UTERM-004. A tab
  file always opens in a new pane. Candidates: the program opens into a browser pane it controls, it opens into a new
  pane only with a grant that covers pane creation, or a program cannot open a tab file.
- What is the wire command, and how does it handle version skew? A new ScriptWire or controller command follows
  ADR-13: a newer program on an older uniterm must get a clear error, not a misread.

## Risks

- **The extension and format become published names** — likelihood: high, impact: medium.
  Mitigation: the in-file version lets the format change without renaming. A build reads every earlier version. The
  extension cannot change once files exist, so its open question settles it before any milestone ships.
- **Saved URLs leak tokens** — likelihood: medium, impact: medium.
  Accepted: the user picks the file and its place, as for the layout file under UTERM-005. A file the user shares is
  shared by the user's choice.
- **A program call widens what a script can write** — likelihood: medium, impact: high.
  Mitigation: the call needs an explicit, revocable grant under ADR-14 P7, and its power is its own under P8. "The
  program call" settles the power before its milestone starts.
- **The browser's new type claim surprises an existing route** — likelihood: low, impact: low.
  Mitigation: the tab-set type is uniterm's own, and `text/uri-list` had no claimant. The drift test and the
  same-rank test catch a collision. A `.uris` file previously opened nowhere.
- **A huge file stalls the app** — likelihood: low, impact: medium.
  Mitigation: "Bounds on opening a file" settles a limit, and lazy loading bounds the network work.

## Milestones

### M1: Save tabs in three formats

**Status:** NOT STARTED

- Save Tabs As… appears in the File menu and the palette for a browser pane, and nowhere else
- The save panel offers the tab-set type, `text/uri-list`, and Netscape bookmark HTML, with the tab-set type first and
  selected, and the extension follows the chosen format
- A saved tab-set file holds the `type` tag, the version, each storable tab's URL and title, and the selected tab
- A saved `.uris` file is valid `text/uri-list` per RFC 2483, with CRLF line ends
- A saved bookmark file imports into Safari and Firefox with each tab's title
- A tab with a `blob:` or `data:` URL, or a URL over 32 KiB, is handled as "Tabs with nothing storable" settles
- A restored tab that never loaded saves its stored URL and title
- A failed write raises an error alert naming the file, and leaves an earlier file intact
- The tab-set type is exported in `Info.plist` and conforms to `public.json`, and the drift test passes
- A UI test screenshot of the save panel shows the format control

### M2: Open tab files back into a pane

**Status:** NOT STARTED

- A tab-set file and a `.uris` file each open into a new browser pane beside the origin, from Finder, File > Open, and
  a drop
- The new pane holds every listed tab in order, only the selected tab loads, and each other tab loads when first
  selected
- A tab-set file round-trips: saving, then opening, gives the same URLs, titles, and selection
- A URL the scheme policy refuses keeps its tab, shows `about:blank` with an explanation, and keeps its URL
- The tag wins over the extension: a tab-set file renamed to `.json` still opens in the browser when routed to it, and
  a `.json` file whose tag names another type is refused with a message
- A version newer than the build is refused with a message naming the version, and every earlier version opens
- A file past the settled bound behaves as "Bounds on opening a file" settles
- A plain `.json` file still opens in the data or text viewer, and an `.html` file opens where it did before

### M3: Program save and open

**Status:** NOT STARTED

- A script or controller with the settled grant saves a browser pane's tabs with the same content as the user's save
- A program without the grant is refused with an error that names the missing power, and nothing is written
- A program's open makes tabs as "The program call" settles, and the same tabs open as for the user's open
- The grant appears in the approval review and the Controllers window, and revoking it stops further calls
- An older uniterm answers the new command with a clear error, per ADR-13

## Decision Log

- 2026-11-22: Drafted from the "Browser: save tab URLs to a file" idea. The user chose a uniterm tab-set JSON as the
  default, with `text/uri-list` and Netscape bookmark HTML offered through the save panel's format control. The user
  chose an extension plus an in-file `type` and `version` tag, with the tag winning, and a format for tab sets only.
- 2026-11-22: The user chose to open tab-set and `text/uri-list` files back, with Netscape HTML export-only. The user
  chose a new pane with lazy loading for an opened file, and URLs written unchanged.
- 2026-11-22 (addition): The user added a program call for saving and opening tab files. It brings in an ADR-14 power,
  a wire command under ADR-13, and the UTERM-018 rule that a script open never creates a pane. Its shape is open.

## References

- [ADR-03](../adr/ADR-03-restored-state-never-runs-a-program.md): an opened file only makes tabs, and loads lazily
- [ADR-04](../adr/ADR-04-uniterm-owns-key-bindings-and-terminal-config.md): an applet binds keys only for its own
  actions
- [ADR-05](../adr/ADR-05-applet-lifecycle-events-and-applet-responses.md): the applet owns its tabs
- [ADR-06](../adr/ADR-06-layout-file-versioning-and-schema-ownership.md): the version pattern this format follows
- [ADR-08](../adr/ADR-08-ui-responsiveness.md): a small, bounded write may run on the main thread
- [ADR-13](../adr/ADR-13-outside-wires-stay-compatible-across-versions.md): the program call's wire versions
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): P7 grants, P8 separate powers, P15 bounded reach,
  C1 effects that need no grant
- [ADR-15](../adr/ADR-15-a-programs-operation-is-the-users.md) (proposed): a program's save and open behave as the
  user's
- RFC 2483, `text/uri-list`: https://datatracker.ietf.org/doc/html/rfc2483
- IANA `text/uri-list`: https://www.iana.org/assignments/media-types/text/uri-list
- Netscape Bookmark File Format:
  https://learn.microsoft.com/en-us/previous-versions/windows/internet-explorer/ie-developer/platform-apis/aa753582(v=vs.85)
