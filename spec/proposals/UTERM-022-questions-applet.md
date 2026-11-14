# UTERM-022: Questions Applet

**Status:** draft
**Created:** 2026-11-14
**Updated:** 2026-11-14

## Dependencies

- UTERM-003, for the `uniterm` command, the `uniterm` Janet module, and ScriptWire
- UTERM-004, for connection binding, the permission kinds, the call-boundary check, and Pending Requests limits
- UTERM-021, for the `declare-permissions` spelling a new permission kind must define

## Impacts

- UTERM-004 — "Permission scopes and approval flow": a new permission kind, `ask-user`, joins the descriptor's
  permission set. A bare terminal-session caller may use it without a prompt, per "The ask power".
- UTERM-021 — "The declaration's data shape": `ask-user` is spelled `{:kind :ask-user :version 1}`, with no other
  fields.
- UTERM-019 — "Commands that wait" and "Large results": this proposal also needs ADR-11's handle and pending reply.
  Neither exists in code yet. Whichever proposal lands first builds the shared mechanism, and the other adopts it.
- UTERM-003 — "The API is one Janet module": `uniterm/ask` and its helpers join the module. ScriptWire's version goes
  up, per "Version skew".

## Summary

A bash script or a Janet program asks the user a form and waits for the answers. A form holds numbered questions,
display-only content blocks, and buttons. The user answers in a Questions pane, where each requester has its own tab.
uniterm draws each tab's chrome, so the user always knows which program is asking. Bash uses short `uniterm ask`
commands or a full JSON spec. Janet passes the same spec as a struct. Answers are checked live as the user types.

## Motivation

Scripts often need a decision or a few values from the user. Today a script reads the terminal, or a bash script calls
`osascript` for a modal dialog. Terminal prompts cannot check answers as the user types, and they cannot show choices,
colors, or files well. Modal dialogs block the whole app and do not say which pane asked.

uniterm already knows which pane a caller runs in, and it already binds powers to callers. A form that travels
through that channel can name its requester truthfully. It can wait without blocking anything, and it ends when the
script ends.

## Design Decisions (Settled)

### The Questions pane

Decision: one Questions pane per window holds every open form in that window.

- When a form arrives, uniterm uses the window's Questions pane if one exists. Otherwise it splits the asking pane and
  opens a Questions pane beside it.
- Each requester gets one tab. The tab bar shows even when there is only one form. The tab title is the one place
  uniterm, not the script, names the form.
- The asking pane gets a badge while its form is open. The badge names the pane by its stable ID, per ADR-02. When the
  asking pane is gone, the chrome says so, and it never points at another pane.
- The applet uses the existing pane tab bar, `AppletTabBar`. Tab switching uses the same keys as other tabbed panes,
  and those keys stay declared applet commands under ADR-04.
- The pane's description holds no form content and no requester binding. A restored or reopened Questions pane is
  empty, per ADR-03.

Rationale: one inbox per window keeps several askers in one place. Opening beside the asker keeps the form near its
context. Tabs that always show give uniterm a title the script cannot draw.

### Requester chrome

Decision: uniterm draws a header on every form. The script cannot style it, hide it, or put text in it beyond the
form's title, which appears below it.

- The header names exactly what the transport established, per ADR-09. A controller package or declared file shows
  its verified name. A bare terminal-session caller shows "Terminal session in <pane>". The header never implies a
  specific script for a caller that could not be identified.
- The header and the form body look clearly different from uniterm's permission prompts and the Pending Requests
  window. A form can ask a permission-style question, but it cannot pass for uniterm asking.
- Question text and content blocks are plain text. They hold no links.

Rationale: a script controls everything in its form but the header. The header is how the user tells who is asking.

### One form at a time

Decision: a requester has at most one open form.

- A second form sent while one is open is refused as busy, with a structured error. Nothing changes on screen.
- After the user answers, the requester's next form reuses the same tab. A multi-step script does not open and close a
  tab for each step.
- The Questions pane caps its tabs. A form past the cap is refused as busy, with the same busy error that UTERM-004's
  Pending Requests limits use.

### Two API layers

Decision: a full form spec, plus bash shorthands for single questions.

The full spec is JSON on stdin for bash, and a struct for Janet:

```json
{
  "title": "Deploy settings",
  "items": [
    {"block": "notice", "level": "warning", "text": "This deploys to production."},
    {"id": "region", "text": "Which region?", "type": "choice",
     "choices": ["us-east", "eu-west"], "other": true, "required": true},
    {"id": "replicas", "text": "How many replicas?", "type": "integer",
     "default": 3, "validate": {"minimum": 1, "maximum": 20}},
    {"id": "notes", "text": "Anything else?", "type": "text", "multiline": true,
     "validate": {"maxLength": 500}}
  ],
  "actions": [
    {"id": "deploy", "label": "Deploy", "role": "primary"},
    {"id": "skip", "label": "Skip", "validates": false},
    {"id": "cancel", "role": "cancel"}
  ]
}
```

```bash
uniterm ask form < form.json
uniterm ask confirm "Delete 3 files?"
uniterm ask text "Branch name?" --default main --pattern '^[a-z0-9/-]+$'
uniterm ask choose "Which region?" us-east eu-west [--multiple] [--other]
uniterm ask number "Replicas?" --integer --min 1 --max 20
uniterm ask color "Accent color?"
uniterm ask file "Pick a config" [--directory] [--save] [--type public.json]
```

- `uniterm ask form` prints the result as JSON on stdout. Each shorthand prints only its value. A multi-value answer
  prints one value per line, and `--json` prints JSON instead.
- Exit codes: 0 means an action was chosen, and for `confirm` it means yes. 1 means `confirm` got no. 2 means a usage
  or spec error. 3 means dismissed. 4 means ended or revoked. The command prints a one-line reason on stderr for codes
  2 through 4.
- Janet calls `(uniterm/ask spec)`, which returns the result struct. Helpers mirror the shorthands, such as
  `uniterm/ask-confirm`.

Rationale: a one-line question should not need JSON. A form with several questions should not need a dozen flags.

### Questions and answer types

Decision: each question has an `id`, its `text`, and a `type`. Answers are keyed by `id`.

| Type | Answer | Notes |
|---|---|---|
| `boolean` | `true`, `false`, or `null` | Optional with no default gives three states |
| `choice` | one choice | `"other": true` adds a free-text entry |
| `multi` | array of choices | `widget` hint: `checkboxes`, `chips`, or `select` |
| `string` | string | one line |
| `text` | string | `"multiline": true` |
| `integer`, `number` | number | |
| `color` | `#rrggbbaa` | sRGB |
| `file` | path, or array of paths | `mode`: `open`, `directory`, or `save`; `multiple`; `types` as UTIs |

- `required` defaults to false. An optional unanswered question returns `null`.
- `default` fills the field. `placeholder` is a separate hint and never becomes an answer.
- `detail` holds a longer paragraph under the question text.
- uniterm numbers the questions, as "Question 1 of 7". Content blocks take no number.
- Without a `widget` hint, uniterm picks the widget from the number of choices.

Rationale: separating the answer type from the widget lets uniterm choose a good default. The script still gets the
same answer shape either way.

### File answers are paths

Decision: a file question returns a path, never the file's contents. Picking a file grants nothing.

- A bash script uses the path as it would any argument.
- A Janet script that reads the file needs file read declared, like any other read.

Rationale: returning contents would mean uniterm reads a file for a script that may not hold file read. ADR-09 forbids
one power silently granting another. Contents also bring large files, binary data, and memory bounds that a path
avoids.

### Content blocks

Decision: a form item with `block` in place of `type` is display-only. It has no answer and no number, and it may
appear anywhere among the questions.

- `paragraph`: plain text.
- `list`: an array of strings, shown as a bulleted list.
- `code`: monospaced text, such as a command preview.
- `table`: key and value pairs, such as a summary.
- `notice`: text with `level` `info`, `warning`, or `danger`.

Rationale: question text belongs to its question. A form that shows what it will do before it asks needs structure
that question text cannot carry.

### Buttons

Decision: buttons belong to the form. Each has an `id`, an optional `label`, and a `role`.

- `primary`: Return activates it outside a multiline field. At most one per form.
- `normal`: no special key.
- `cancel`: Escape activates it once no picker or popup is open. It never validates.
- `destructive`: styled as a warning. It is never the default button, and Return never activates it.
- `validates` defaults to true, except for `cancel`. A button with `validates: false` submits whatever is filled in,
  unchecked.
- A form with no `actions` gets OK as `primary` and Cancel as `cancel`.
- Choices such as "Yes to all" are plain buttons. The script gives them their meaning.

Return inserts a newline in a multiline field. Escape first closes an open color picker, file panel, or popup. These
are unmodified keys inside the applet's own view, so they do not touch window keys under ADR-04.

### Validation

Decision: validation uses a subset of JSON Schema's keywords. uniterm checks each field as the user types and shows
errors beside it.

- Keywords: `minLength`, `maxLength`, `pattern`, `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`,
  `multipleOf`, `minItems`, and `maxItems`. "Positive" is `exclusiveMinimum: 0`. "Non-negative" is `minimum: 0`.
- A keyword that does not apply to its type refuses the spec.
- Every keyword except `pattern` runs in linear time over bounded input, on the main thread.
- `pattern` runs off the main thread with a time cap and an input-length cap. When a check times out, the field shows
  "could not check", and a validating button stays disabled. A pattern that fails to compile refuses the spec.
- A validating button stays disabled until every required field has an answer and every field passes.

Rationale: the script's own validator may be slow or hostile. ADR-08 forbids the main thread waiting on work whose
time uniterm does not bound. Full JSON Schema brings `$ref` and composition that a form cannot show.

### Spec limits and strict decoding

Decision: the spec is read with the strict JSON reader that `controller.json` uses. Any unknown key, at any level,
refuses the spec.

- The spec has caps on total bytes, the number of items, string lengths, choices per question, and nesting depth.
- A Janet struct is converted to the same JSON shape and read by the same reader.

Rationale: a script written for a later uniterm must fail loudly on an older one. A field that an older host ignored,
such as a later script-side review flag, would close the form while the script believed its check had run.

### Lifecycle and results

Decision: sending a form and waiting for its answer are two calls, per ADR-11.

- `open-form` has an effect, since the form appears. It replies at once with a handle.
- `wait-form` only reads, so it may hold a deferred reply. It returns once the form resolves. Reading does not consume
  the result. The caller discards the handle, and the Janet helpers and the `uniterm ask` command do this on every
  exit path.
- A submitted form returns `{"form": <handle>, "submission": 1, "action": <id>, "answers": {...}}`.
- Closing the form's tab or the Questions pane returns `{"form": <handle>, "outcome": "dismissed"}`. Closing never
  asks for confirmation, since the caller is notified.
- A run end, a revocation, or a closed connection closes the form, fails a pending wait as ended, and frees the
  handle. Since the form had no effect beyond showing, "ended" truthfully means nothing was submitted.
- Result slots have the same caps and lifetimes as other ADR-11 handles.

Rationale: a handle keeps the first answer honest at once. A script that is interrupted still gets a clear outcome.

### Room for script-side review

Decision: this proposal does not build a round trip where the script accepts or rejects a submission. Three choices
keep it possible later.

- Strict decoding, so a later `review` flag fails loudly on this version.
- Submission numbers, so a later reject call can name the submission it refers to.
- A shared error shape, `{"errors": {"<id>": "<message>"}}`. Live validation already uses it, and a script's
  rejection would show the same way.

A later review mode applies only to validating buttons. Cancel, closing the tab, and `validates: false` buttons always
close at once, so the user is never stuck waiting on a script.

### The ask power

Decision: asking the user is a permission kind, `ask-user`, version 1.

- A controller package declares `{"kind": "ask-user", "version": 1}` in `controller.json`. A declared file declares
  `{:kind :ask-user :version 1}`.
- The power has no scope fields. It covers opening the window's Questions pane, so asking needs no pane-control grant.
- A bare terminal-session caller, such as bash running `uniterm ask`, may ask without a prompt for forms that name its
  own pane as the asker, as `post-status` works today. The one-form rule and the tab caps limit spam.
- A package or declared file that does not declare `ask-user` is refused, with a message that names the missing kind.

Rationale: the bash case is the main use, and a prompt before every `uniterm ask confirm` defeats it. Declared callers
still state the power up front, so the review shows it.

### Out of scope

- Password and other masked fields.
- The script-side review round trip.
- Granting a script read access to a file the user picked.
- Conditional questions that show or hide on other answers. A script sends a second form instead.
- One-question-at-a-time wizard layout.
- Links and rich text in question text and content blocks.

### Version skew

Decision: the change follows UTERM-004's skew rules.

- The command and the app: `open-form` and `wait-form` are new calls, and ScriptWire's version goes up. The hello
  requires an exact match, so an older command and a newer app refuse each other before any effect.
- An older build reading a `controller.json` or a declaration with `ask-user` refuses the unknown kind. That fails
  closed.
- An older app receiving a spec with a newer key refuses it as a spec error.
- Forms are never persisted, so no stored format changes.

## Design Decisions (Open)

None.

## Risks

- **The form spec becomes a published contract** — likelihood: high, impact: medium.
  Mitigation: strict decoding refuses unknown keys, so a newer spec fails loudly on an older host. New keys are
  additive. A change in a key's meaning needs a new key, never a new reading of an old one.
- **A script spoofs a uniterm prompt or phishes for secrets** — likelihood: medium, impact: medium.
  Mitigation: the header is drawn by uniterm and names the established requester. Forms look clearly different from
  permission prompts. Text carries no links, and there are no password fields.
- **A hostile pattern or spec stalls the app** — likelihood: low, impact: high.
  Mitigation: `pattern` runs off the main thread with time and input caps. Every other check is linear over capped
  input. The spec's size caps are checked before the form appears.
- **A bare caller floods the user with forms** — likelihood: low, impact: low.
  Accepted: one open form per requester and the tab caps bound it. Closing the tab dismisses the form at once.
- **The pending-reply mechanism is built twice** — likelihood: medium, impact: medium.
  Mitigation: the Impacts entry on UTERM-019 names one shared mechanism. M3 adopts it if UTERM-019 built it first, and
  builds it in the applet contract, not in this applet, otherwise.

## Milestones

### M1: Form spec and validation

**Status:** NOT STARTED

- The strict reader refuses every unknown key, a misapplied keyword, a bad pattern, and each cap, with a message
  that names the field
- Fixtures cover every answer type, content block, and button role, including the default OK and Cancel
- Validation tests cover each keyword, required fields, and the error shape
- A catastrophic-backtracking pattern times out off the main thread and leaves the field as "could not check"

### M2: Questions applet UI

**Status:** NOT STARTED

- The Questions pane shows a tab per form, with a tab bar even for one form, and uniterm-drawn requester chrome
- Every answer type, widget hint, and content block renders and returns the answer shape in the table
- Return, Escape, and the button roles behave as "Buttons" says, including in multiline fields and open pickers
- Live errors appear beside their fields, and validating buttons stay disabled until the form passes
- The user looks at the pane in light and dark mode and confirms the layout and the chrome's contrast with permission
  prompts

### M3: The ask power and the form calls

**Status:** NOT STARTED

- `ask-user` is a permission kind in `controller.json` and in declarations. An undeclared use is refused with the
  kind named
- `open-form` replies with a handle at once, and `wait-form` holds a deferred reply through the shared ADR-11
  mechanism
- A form opens in the window's Questions pane or in a split beside the asker, and the asking pane shows a badge
- A second form while one is open, and a form past the tab cap, are refused as busy
- Tab close and pane close return dismissed. Run end, revocation, and a dropped connection fail the wait as ended and
  free the handle
- A bare terminal-session caller asks without a prompt, and its header reads "Terminal session in <pane>"
- An older command and a newer app refuse each other at the hello

### M4: `uniterm ask` and Janet helpers

**Status:** NOT STARTED

- `uniterm ask form` and each shorthand print the documented output and exit with the documented codes
- `uniterm/ask` and its helpers return the result struct and discard the handle on every exit path, including an error
- Script fixtures exercise each shorthand and the full spec through the real command and app
- The user runs a bash script and a Janet script that ask forms in the running app and confirms the flow

## Decision Log

- 2026-11-14: Drafted from the user's applet idea. The user chose the tabbed Questions pane and the two API layers.
- 2026-11-14: The user left password fields out of scope. The user chose uniterm-drawn requester chrome on every form,
  distinct from permission prompts, and a tab bar that shows even for one form.
- 2026-11-14: The user chose asking the user as a declarable power.
- 2026-11-14: The user chose a path for file answers, with no read granted by picking.
- 2026-11-14: The user chose to keep the script-side review round trip out of scope, with a protocol that leaves room
  for it.
- 2026-11-14 (addition): The user added display-only content blocks and the `destructive` button role, along with
  the other button roles.
- 2026-11-14: The user chose `pattern` checks off the main thread with time and input caps.
- 2026-11-14: The user chose to let a bare terminal-session caller ask without a prompt.
- 2026-11-14: The user chose to reuse the window's Questions pane, or split beside the asker when there is none.
- 2026-11-14: The user chose to never confirm closing a Questions pane, since each caller is notified. A confirmation
  trains the user to accept it. Undo or reopen is the real fix, and forms cannot be reopened.
- 2026-11-14: ADR candidate (cuts across the system): uniterm draws requester chrome on any form a script supplies.
  Declined: ADR-09 already requires the requester scope to match what the transport established, and only this applet
  shows script forms.
- 2026-11-14: ADR candidate (hard to reverse): refusing unknown keys in a script-facing spec. Declined: strict
  decoding is already the convention for `controller.json`, layouts, and applet command arguments.

## References

- [ADR-02](../adr/ADR-02-pane-tree-nodes-have-stable-ids.md): the asking pane is named by its stable ID
- [ADR-03](../adr/ADR-03-restored-state-never-runs-a-program.md): forms are never restored
- [ADR-04](../adr/ADR-04-uniterm-owns-key-bindings-and-terminal-config.md): form keys stay inside the applet's view
- [ADR-07](../adr/ADR-07-failure-isolation.md) and [ADR-08](../adr/ADR-08-ui-responsiveness.md): bounded validation
- [ADR-09](../adr/ADR-09-control-authority-requires-authenticated-identity-and-explicit-scope.md): the ask power and
  truthful requester chrome
- [ADR-11](../adr/ADR-11-deferred-applet-replies-never-hide-effects.md): the handle and the deferred wait
