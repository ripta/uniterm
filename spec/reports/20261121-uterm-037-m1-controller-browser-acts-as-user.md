# UTERM-037 M1: a controller's browser commands act as the user's

Started 2026-11-21. The user ruled that ADR-12's retraction must be followed through in the browser's remote commands,
which the UTERM-005 M8 run had just built. See [the M8 report](20261120-uterm-005-m8-browser-remote-control.md),
"Left for the user". The user chose "Everything" in scope, and a superseding proposal over an in-place edit of frozen
UTERM-005. The run filed UTERM-037 in "File UTERM-037 so a controller's browser commands act as the user's", queued
its one row, and works it here. Every commit is in this repo, on `agent/petunia`.

## Run state

The row's base is "File UTERM-037 so a controller's browser commands act as the user's". It has no dependency and no
`Live after` line.

| Milestone | Run status | Commits |
|---|---|---|
| UTERM-037 M1: Commands act as the user's | DONE | See "Commits" |

The row is finished. UTERM-037 is `implemented`, and its row moved to `history.md`.

## Commits

1. "File UTERM-037 so a controller's browser commands act as the user's"
2. "Draft UTERM-038 so a program's map move is saved as the user's is", from the audit below
3. "Carry ADR-12's retraction into the unbuilt browser and routing proposals", from the audit below
4. "Make a controller's browser commands the user's own actions", which carries M1, its review fixes, and this report
5. "Mark UTERM-037 implemented now that browser commands act as the user's"

## UTERM-037 M1

### What was built

- `open` runs the user's New Tab and then the user's typed-address commit. Its tab is selected and takes the keyboard.
  In a pane without focus, it pulls the keyboard from the pane that had it, as the user's New Tab does.
- `navigate` is the typed address in that tab. Search and app handoff resolve as typed input does. Downloads follow the
  typed-load rules. On a tab behind another, an app address opens nothing, as the user's rule lets only the shown page
  ask.
- `reload`, `back`, and `forward` run the toolbar's own path. A form reload asks to resend as the user's does.
- `select` is the user's tab click and is never refused.
- The `key-focused` and `unsent-input` codes, the intent-free history, the controller-only download and handoff asks,
  and the owned-tab loading on reattach are gone.
- An address that cannot load is refused before any tab opens. An `open` whose load still fails replies with its tab,
  so the caller owns what it made.
- UTERM-005 carries "Superseded in part by UTERM-037" markers on the replaced "Control" bullets, its Rationale, M8's
  checks, M8's error-code mapping, and the "Unsent input" line, plus one Decision Log entry.

### Checks

- `make lint`, `make check`: pass.
- `caffeinate -dimsu make test-package`: 2990 tests, 10 skipped, 0 failures, after the review fixes.
- `make fuzz`: pass before the review fixes. The fixes touched no fuzzed reader, so it did not run again.
- `build-for-testing`: pass.
- `BrowserRemoteUITests` and `BrowserUITests`, run by the coordinator: 13 tests, 0 failures, before and after the review
  fixes.
- `proposals.py check` and `freeze`: only the row-finish findings, and the UTERM-004 References hunk with origin
  `other`.

### Test cost

| Class | Tests | Wall time |
|---|---|---|
| `BrowserRemoteTests` | 26 | 3.0 s |
| `BrowserWindowTests` | 9 | 0.85 s |
| `SchemePolicyTests`, `AddressPolicyTests` | | under 0.01 s each |

### Best guesses

Each is in UTERM-037's Decision Log.

1. Navigate on a tab behind another loads normally. An app address there opens nothing and posts the tab's usual
   notice.
2. A layout `url` seed uses the typed scheme rule, but still refuses search text and app addresses. A seed is a stored
   address with no engine or handoff to run. Left for the user.
3. An `open` in a detached pane loads at once with media suspended, as `navigate` always did.
4. Owned-tab loading on reattach is gone, since an `open` now selects and loads its tab.

### Review findings

Reviewer:

1. A failed `open` left an owned blank tab that counted toward the cap (PLAUSIBLE). The only post-open failure is a
   search with no URL, which the trace found unreachable. It is now refused before any effect, and an `open` that
   still fails replies with its tab. No failing-first test was possible, since the path cannot be reached.
2. No skew statement. Added. UTERM-005 M8 never reached main, so no released build sent the removed codes.
3. Three UTERM-005 passages stated removed behavior without a marker. Fixed with markers, and added to Impacts.
4. Comment wraps in three files. Fixed.
5. A test asserted only "not unowned" for reload, back, and forward. Tightened.
6. Coverage of refused schemes on the command path. Widened.
7. The layout seed's refusal of search and app addresses. Left for the user.

ADR impact: no conflict. It noted the schema stayed at 1.0 while behavior changed, now covered by the skew statement.
It also noted that "a program's operation behaves as the user's" lives only in the retraction notice and in proposals.
That passes the bar for a cross-cutting rule. Per the standing rule against inventing ADRs, it goes to the user
instead of becoming an ADR candidate entry.

## The retraction audit

The user asked for a cheaper reviewer to audit the remaining proposals, and a verifier to check its list. A Sonnet
auditor found four candidates. A verifier confirmed them against the text and the user's own code paths, and found four
misses. Confirmed and handled:

- UTERM-019 "Trusted input": a synthesized click moves focus as the user's does, and is not refused on a focused pane.
  Amended in place.
- UTERM-019 dialogs: a controller tab's dialog takes focus as any tab's does. Amended in place.
- UTERM-019 M6: a synthesized click counts as the user's for the download, pop-up, and handoff gates. Amended in place.
- UTERM-019 run-end rationale: it claimed a reload protects drafts. The user's reload does not. Wording corrected.
- UTERM-020: the focused-pane restriction and the focus safeguard are gone. Amended in place.
- UTERM-018 M5: a script's URL open lands selected and takes focus. Amended in place.
- UTERM-005 "Unsent input": marked as superseded by UTERM-037.
- UTERM-008 `set-region` is never saved, while every user move is. UTERM-008 is frozen, so the fix is drafted as
  UTERM-038.

Refuted: the run-end rebuild in UTERM-019 is grant cleanup with no user counterpart. A fresh web view taking focus back
matches the user's path.

Left for the user:

- Whether to accept and build UTERM-038.
- UTERM-019: whether text only the controller typed counts as the user's draft, or as grant cleanup.
- UTERM-019: whether a key command to a tab nobody clicked focuses it as a click would.
- UTERM-018: a script's open with no capable pane fails, where the user's open creates a pane or hands off. The
  verifier leans to calling it authority.
- The layout seed's refusal of search and app addresses.
