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
- UTERM-015 — "Who may run `uniterm open`" and "Which file types uniterm registers with Finder". A program's open of a
  tab file can load a page, per "A program-chosen open of a tab file". uniterm's own exported type may need a rank
  other than Alternate.
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

Decision: each tab saves the URL and title its layout record holds, which is its last storable page. A tab that has
not loaded since restore saves its stored URL and title. Every URL passes `BrowserDescription.storableURL` again at
save time, and every title the same 512-character bound the layout payload uses, whatever its source. The file records
which tab is selected. The save reads the browser's tabs through the applet, never its web views directly. Amended
2026-11-22; see Decision Log.

- Opening a file applies the same bounds when it fills each tab's record. A URL over 32 KiB is not stored, and a title
  is cut to 512 characters.

Rationale: one filter keeps a saved file and a saved layout in agreement on which URLs are storable. Only http, https,
and `about:blank` pass, so a `blob:`, `data:`, or `javascript:` URL never reaches a file that other tools read, even
when an opened file put one in a tab. ADR-05 has the applet own its own state.

### The write is atomic and bounded

Decision: the file is written atomically, through a temporary file beside the target and a replace, as the map
viewer's Save As does. A failed write raises an error alert that names the file and keeps the user's earlier file. The
write runs off the main thread, as the map viewer's does, since a pane's tab count has no cap and each URL may be up to
32 KiB. Amended 2026-11-22; see Decision Log.

### The browser opens tab-set and `text/uri-list` files

Decision: the browser declares the tab-set type and `text/uri-list` at the owner rank. Both are exported or imported
in `Info.plist`, as UTERM-015 requires. Netscape bookmark HTML is export-only.

- The browser's "opens no file" rule narrows. It still opens no local page, since `file:` never loads, and the text
  viewer keeps local documents.
- The tab-set type conforms to `public.json`, so it is more specific than the data viewer's `public.json` claim and
  wins by UTERM-015's specificity rule.
- The router matches on the file's system type, from its extension. A tab-set file renamed to `.json` resolves to
  `public.json`, so the browser is not a claimant for it. See "How the tag wins on open".

Rationale: the user chose this pair. A bookmark file uses `.html`, so claiming it would take every HTML file away from
its other handlers or need sniffing.

### An opened file makes a new pane and loads lazily

Decision: an opened tab file makes a new browser pane beside the origin, by UTERM-018's rule for a file that no pane
takes in place. The browser does not replace a source, so its existing panes never take a file. The new pane holds
every tab the file lists, in order. Only the selected tab loads. Every other tab loads when first selected, as a
restored layout's tabs do.

- Each URL passes the scheme policy as a restored URL does. A refused URL keeps its tab, shows `about:blank` and an
  explanation, and keeps the URL, as a restored tab does.
- A `text/uri-list` file has no titles or selection. Its tabs show their hosts until they load, as an untitled
  restored tab does, and the first tab is selected.
- An open a program chose, through `uniterm open` or Launch Services, still loads the selected tab today. See "A
  program-chosen open of a tab file".

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

`text/uri-list` needs an identifier too. The system has no type for it: `UTType(mimeType: "text/uri-list")` returns a
dynamic type with no extension. uniterm imports one under an identifier it picks, with `.uris` and `.uri` and the MIME
type. Saved Open With choices key on the exact type, so this identifier is also a published name.

The extension and both identifiers become published names once a file is saved, so they are one-way doors. See Risks.

### The tab-set format's fields

Original question: what does the JSON hold beyond each tab's URL and title and the selected tab?

- **URL, title, selected only.** The minimum a round trip needs. Version 1 stays small.
- **Also a save time and a set name.** A name could default to the pane's title. Helps a user with many saved sets,
  and a reader can show the name.
- **Also per-tab extras**, such as a favicon URL or a last-visited time. More to keep correct, and no current reader
  needs them.

Constraint: a build refuses a version newer than its own. If every added field bumps the version, an older build
refuses a file it could read whole. ADR-06 bumps the layout's version for a field an older reader would drop, because
the layout is written back. A tab file is never written back by its reader. One candidate rule: readers ignore keys
they do not know, and only a change in meaning bumps the version.

### Tabs with nothing storable

Original question: a tab whose record holds no storable URL has nothing to save. What does the file hold for it, and
what happens to the selection when the selected tab is such a tab?

Each tab saves its record's last storable page, per "Saved values reuse the layout's filters". A tab that moved from
an https page to a `blob:` page still saves the https page. The empty cases are narrower: a tab that never loaded, a
pop-up that opened straight on `blob:` or `data:`, a tab whose only page was over 32 KiB, and a tab an opened file
filled with a refused URL.

- **Skip the tab.** The file lists only tabs whose record has a storable URL. When the selected tab is skipped, the nearest kept tab before it
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

### How the tag wins on open

Original question: the settled format decision says the tag decides what a file is. The router picks an applet from
the file's system type, which comes from its extension, and reads no content. How does the tag win on open?

- **The browser's reader checks the tag.** A file routed to the browser is refused unless its tag is a tab set. A tab
  set renamed to `.json` goes to the data viewer, and the user must rename it back, since uniterm's Open With lists
  only the data viewer for `public.json`. Leaves undone: the
  renamed-file direction of "the tag wins", and piped or pasted text, which have no entry point here.
- **The browser also claims `public.json` at the alternate rank.** Open With then lists the browser for any `.json`
  file, and the data viewer stays the owner, so the equal-rank test passes. The browser's reader refuses a `.json`
  file whose tag is not a tab set. This adds scope: a second claimed type, and a browser entry in every `.json` file's
  Open With list.
- **The router reads content.** It checks a JSON file's tag before matching. This contradicts UTERM-015's rule that
  the router resolves a file's type through the system, and would amend it.

### A program-chosen open of a tab file

Original question: a session approval for `uniterm open` covers every program in that session. Its text says "asks to
open this path in a new pane", and names no page load. A program in an approved session can write a `.uris` file and
open it. The new pane then loads its selected tab with uniterm's website data, signed in as the user. Elsewhere,
uniterm gates a program's browser page loads behind browser navigation: a seeded browser page in a layout request
needs that power, and UTERM-018 limits a program's URL opens to browser panes the program created. Any local process
can already make Safari load a URL through macOS `open`. What is new is uniterm's own website data.

- **A program-chosen open loads no tab.** Every tab waits for the user to select it. The tabs are the same as for the
  user's open. Leaves undone: ADR-15, which is proposed, says a permitted action "is not weakened, delayed, or hidden".
  This open does less than the user's, so it needs an ADR Deviations entry or an ADR-15 amendment.
- **A program cannot open a tab file through these paths.** Browser navigation is a controller power. A `uniterm open`
  approval and a Launch Services sender hold no controller grant, so no caller on either path can hold it. The open is
  refused with a message that names the missing power. A program that needs it uses the controller call in "The
  program call".
- **The `uniterm open` approval also grants browser navigation for the open.** Its review then says the open may load
  a page signed in as the user. This adds scope: a new power on UTERM-015's approval. Launch Services still has no
  grant to carry it.
- **The approval text names the page load.** The session approval stays as it is, and its review says the open may
  load a page signed in as the user.

The Launch Services path has the same question for an open another app chose.

### The program call

Original question: how does a script or controller save or open a tab file?

- Which power does it use? Saving writes the user's files and reads URLs that can hold tokens. The browser-read power
  reads only tabs the controller opened itself, through `ownedTab`, so reading the user's tabs is a new power. No
  path-write power exists among the controller powers. A write to a path needs a power of its own under ADR-14 P8,
  which says one granted power never silently grants another. Opening a path needs UTERM-015's path-reading power.
- Is a new open call needed at all? A controller with its own file access can already open a tab set: it parses the
  file, sends a layout request with a seeded browser URL under browser navigation, then opens the rest as tabs. That
  is the "no new open call" candidate. Leaves undone: the browser's `open` command loads each tab at once, so lazy
  loading is lost. It refuses past 16 tabs per controller per pane until UTERM-039 is built. It carries no title. So
  it cannot reproduce the user's open, which ADR-15 asks for.
- Does the program get the save panel, or name a path? ADR-15 asks that the operation behave as the user's, which
  shows the panel. A named path has no user counterpart, which ADR-15 allows, but the grant then needs a write scope.
- How does a program's open make a pane? UTERM-018 says a script open never creates a pane, citing UTERM-004. A tab
  file always opens in a new pane. Candidates: the program opens into a browser pane it controls, it opens into a new
  pane only with a grant that covers pane creation, or a program cannot open a tab file.
- What is the wire command, and how does it handle version skew? ADR-13 lets ScriptWire refuse every version but its
  own, since its two sides ship together. The controller wire must give a newer program on an older uniterm a clear
  error. A new browser applet command gets that for free: an older build answers an unknown name with
  `unknownCommand`.

## Risks

- **The extension, the format, and the type identifiers become published names** — likelihood: high, impact: medium.
  Mitigation: the in-file version lets the format change without renaming. A build reads every earlier version. The
  extension, the tab-set identifier, and the imported `text/uri-list` identifier cannot change once files and saved
  Open With choices exist, so their open question settles them before any milestone ships.
- **A program's open loads a page signed in as the user** — likelihood: medium, impact: high.
  Mitigation: "A program-chosen open of a tab file" settles the gate before M2 ships. Lazy loading already limits such
  an open to one page.
- **Finder may not pick uniterm for its own type** — likelihood: medium, impact: low.
  Mitigation: UTERM-015 registers every document type at the Alternate rank, so a double-clicked tab-set file might go
  to another app that edits `public.json`. M2 checks a double-click in Finder. When it fails, the follow-up is an
  amendment to UTERM-015 that gives uniterm's own exported types the Owner rank.
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
- A saved bookmark file imports into Safari and Firefox with each tab's title, and page-chosen titles and URLs are
  HTML-escaped
- The bookmark format shows in the save panel's control under a name that says it is a bookmark file, and declaring
  its type leaves how an `.html` file opens unchanged
- A tab that moved from an https page to a `blob:` page saves the https page
- A tab with no storable page is handled as "Tabs with nothing storable" settles
- A restored tab that never loaded saves its stored URL and title, after the same `storableURL` and title bounds
- A tab that an opened file filled with a `javascript:` URL, or a URL over 32 KiB, never writes it to any format
- The tab-set format's version is its own, independent of the browser's layout payload version, and a golden test pins
  the version-1 bytes
- A save of a large pane never blocks the main thread
- A second Save Tabs As while a write is in flight, or a pane that closes during the write, behaves as the map viewer's
  save does: one write runs at a time, and a failure alert still reaches the user
- A stored URL string that does not parse counts as nothing storable, and never traps
- A failed write raises an error alert naming the file, and leaves an earlier file intact
- The tab-set type is exported in `Info.plist` and conforms to `public.json`, and the drift test passes
- A UI test screenshot of the save panel shows the format control

### M2: Open tab files back into a pane

**Status:** NOT STARTED

- A tab-set file and a `.uris` file each open into a new browser pane beside the origin, from File > Open, a drop on
  the Dock icon, and a drop on a pane, each by the route that entry point uses for other files
- A double-click in Finder opens a tab-set file in uniterm, or the result is recorded for the Finder rank risk
- Opened tabs carry the user's load origin, not the quiet origin of a restored tab
- A `.uris` file is read with CRLF or LF line ends, and its `#` comments are skipped
- A `.uris` file with no URLs, and a tab-set file with no tabs or a `selected` value out of range, are refused with a
  message
- A URL over 32 KiB is not stored in an opened tab, and a title is cut to 512 characters
- The imported `text/uri-list` type conforms only to a text type no other applet claims, and a `.uris` file whose
  preferred type comes from another app still reaches the browser through its extension
- The new pane holds every listed tab in order, only the selected tab loads, and each other tab loads when first
  selected
- A tab-set file round-trips: saving, then opening, gives the same URLs, titles, and selection
- A URL the scheme policy refuses keeps its tab, shows `about:blank` with an explanation, and keeps its URL
- A file with the tab-set extension whose tag names another type is refused with a message, and a renamed tab-set
  file behaves as "How the tag wins on open" settles
- A program's open of a tab file behaves as "A program-chosen open of a tab file" settles
- A version newer than the build is refused with a message naming the version, and every earlier version opens
- A file past the settled bound behaves as "Bounds on opening a file" settles
- A plain `.json` file still opens in the data viewer, and an `.html` file opens where it did before

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
- 2026-11-22 (autonomous): The draft's critique found that a tab's stored URL and an opened file's refused URL skipped
  the save filter, so a `javascript:` URL from a `.uris` file could reach a bookmark file. "Saved values reuse the
  layout's filters" now filters every URL and title at save time and bounds them on open. It said "each tab saves its
  committed URL through `BrowserDescription.storableURL`" and "A tab that has not loaded since restore saves its stored
  URL and title", with no filter on the stored URL.
- 2026-11-22 (autonomous): The critique found the map viewer's write runs off the main thread, and a tab set has no
  size bound. "The write is atomic and bounded" now writes off the main thread. It said "The write is small and
  bounded, so it may run on the main thread under ADR-08."
- 2026-11-22 (autonomous): The critique found that the router cannot read the tag, so a renamed tab-set file never
  reaches the browser, and that a program's `uniterm open` of a tab file loads a page signed in as the user. Both go
  against settled choices, so they became the open questions "How the tag wins on open" and "A program-chosen open of
  a tab file". It also found that `text/uri-list` has no system type, that adding a field could make older builds
  refuse files, and that Finder may not pick uniterm. These joined the open questions and Risks. Its edge cases were
  routed to M1 and M2 checks.
- 2026-11-22 (autonomous): The re-check found four misstatements in the new open questions. The "loads no tab" option
  conflicts with ADR-15 rather than fitting it. "Needs browser navigation" had two readings, now two options, one of
  them an addition. The "no new open call" candidate loads eagerly and is capped, so it gained a leaves-undone line.
  "Tabs with nothing storable" repeated a settled choice as a candidate, so its two skip options merged. These fixes
  were not re-checked, since the loop's passes were limited to what the draft needed. Its concurrency, parsing, and
  `.uris` type edge cases were routed to M1 and M2 checks.

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
