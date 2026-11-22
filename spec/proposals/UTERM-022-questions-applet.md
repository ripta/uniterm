# UTERM-022: Questions Applet

**Status:** accepted
**Created:** 2026-11-14
**Updated:** 2026-11-21

## Dependencies

- UTERM-003, for the `uniterm` command, the `uniterm` Janet module, and ScriptWire
- UTERM-004, for connection binding, the permission kinds, the call-boundary check, and Pending Requests limits
- UTERM-021, for the `declare-permissions` spelling a new permission kind must define, and for the bundled command's
  begins, strict mode, and the authentication of the bundled command that the question-only session builds on

## Impacts

- UTERM-004 — "Permission scopes and approval flow": a new permission kind, `ask-user`, joins the descriptor's
  permission set. A bare terminal-session caller may use it without a prompt, per "The ask power".
- UTERM-021 — "The declaration's data shape": `ask-user` is spelled `{:kind :ask-user :version 1}`, with no other
  fields. "Strict and unsafe modes" and "Where the declaration is read": the bundled command gains a
  question-only session, which strict mode admits, per "The question-only session".
- UTERM-019 — "Commands that wait": both proposals follow ADR-11. UTERM-019's pending reply lives in the applet
  contract and this one's in the host, per "Where the form calls live", so neither builds the other's.
- UTERM-003 — "The API is one Janet module": `uniterm/ask` and its helpers join the module. ScriptWire's version goes
  up, per "Version skew". The command's exit codes gain the ones in "`uniterm ask` outcomes and exit codes".

## Summary

A bash script or a Janet program asks the user a form and waits for the answers. A form holds numbered questions,
display-only content blocks, and buttons. The user answers in a Questions pane, where each requester has its own tab.
uniterm draws each tab's chrome, so the user always knows which program is asking. Bash uses short `uniterm ask`
commands or a full JSON spec. Janet passes the same spec as a struct. Answers are checked as the user fills the form.

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
- Each requester gets one tab. The tab bar shows even when there is only one form. uniterm writes the tab title. It
  names the requester, as the header does, and the script cannot set it.
- The asking pane gets a badge while its form is open. The badge names the pane by its stable ID, per ADR-02. When the
  asking pane is gone, the chrome says so, and it never points at another pane.
- The applet uses the existing pane tab bar, `AppletTabBar`. Tab switching uses the same keys as other tabbed panes,
  and those keys stay declared applet commands under ADR-04.
- The pane's description holds no form content and no requester binding. A restored or reopened Questions pane is
  empty, per ADR-03. It shows an empty state that says so, and it stays until the user closes it. Amended 2026-11-21;
  see Decision Log.

Rationale: one inbox per window keeps several askers in one place. Opening beside the asker keeps the form near its
context. Tabs that always show give uniterm a title the script cannot draw.

### Requester chrome

Decision: uniterm draws a header on every form. The script cannot style it, hide it, or put text in it beyond the
form's title, which appears below it.

- The header names exactly what the transport established, per ADR-14. A controller package or declared file shows
  its verified ID, since the descriptor's display name proves nothing. A bare terminal-session caller shows "Terminal
  session in <pane>". The header never implies a specific script for a caller that could not be identified. Amended
  2026-11-21; see Decision Log.
- The header and the form body look clearly different from uniterm's permission prompts and the Pending Requests
  window. A form can ask a permission-style question, but it cannot pass for uniterm asking.
- Question text and content blocks are plain text. They hold no links.

Rationale: a script controls everything in its form but the header. The header is how the user tells who is asking.

### One form at a time

Decision: a requester has at most one open form.

- A second form sent while one is open is refused as busy, with a structured error. Nothing changes on screen.
- After the user answers, the requester's next form reuses the same tab. A multi-step script does not open and close a
  tab for each step.
- The Questions pane caps its open forms. A form past the cap is refused as busy, with the same busy error that
  UTERM-004's Pending Requests limits use. A resolved tab never counts toward the cap. When a new requester's form
  arrives and the pane already holds as many tabs as the cap, the oldest resolved tab that is not selected closes to
  make room. When the selected tab is the only resolved one, it closes. The arriving form opens its tab as
  "Focus when a form arrives" describes. Amended 2026-11-20; see Decision Log.

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
- Exit codes follow "`uniterm ask` outcomes and exit codes". The command prints a one-line reason on stderr for every
  code but 0 and 1. Amended 2026-11-14; see Decision Log.
- Janet calls `(uniterm/ask spec)`, which returns the result struct. The helpers mirror the shorthands:
  `uniterm/ask-confirm`, `ask-text`, `ask-choose`, `ask-number`, `ask-color`, and `ask-file`. Each takes the prompt,
  names the shorthand's flags as named arguments, and returns the answer. It returns nil when the user cancelled or
  closed the form. `ask-confirm` returns true for Yes, false for No, and nil when the form was closed. Amended
  2026-11-21; see Decision Log.
- A Janet spec uses keywords for its keys, for question and button `id`s, and for closed-set values such as `:type`,
  `:role`, `:block`, `:level`, and `:mode`. A string in one of those places refuses the spec. Text, choices,
  and string defaults stay strings. A boolean or number default is a Janet boolean or number. The result struct keys
  its answers by the same keywords, and spells its `action` and `outcome` as keywords. This follows UTERM-021's rule
  that kinds are keywords. Amended 2026-11-14; see Decision Log.

Rationale: a one-line question should not need JSON. A form with several questions should not need a dozen flags.

### Questions and answer types

Decision: each question has an `id`, its `text`, and a `type`. Answers are keyed by `id`.

| Type | Answer | Notes |
|---|---|---|
| `boolean` | `true`, `false`, or `null` | Optional with no default gives three states |
| `choice` | one choice | `"other": true` adds a free-text entry |
| `multi` | array of choices | |
| `string` | string | one line |
| `text` | string | `"multiline": true` |
| `integer`, `number` | number | |
| `color` | `#rrggbbaa` | sRGB |
| `file` | path, or array of paths | `mode`: `open`, `directory`, or `save`; `multiple`; `types` as UTIs |

- `required` defaults to false. An optional unanswered question returns `null`.
- `default` fills the field. `placeholder` is a separate hint and never becomes an answer.
- `detail` holds a longer paragraph under the question text.
- uniterm numbers the questions, as "Question 1 of 7". Content blocks take no number.
- uniterm picks each question's widget from its type and its number of choices. A script cannot choose the widget,
  and the choice-count thresholds are not part of the contract. Amended 2026-11-14; see Decision Log.

Rationale: separating the answer type from the widget lets uniterm choose a good default. The script still gets the
same answer shape either way.

### File answers are paths

Decision: a file question returns a path, never the file's contents. Picking a file grants nothing.

- A bash script uses the path as it would any argument.
- A Janet script that reads the file needs file read declared, like any other read.

Rationale: returning contents would mean uniterm reads a file for a script that may not hold file read. ADR-14 forbids
one power silently granting another. Contents also bring large files, binary data, and memory bounds that a path
avoids.

### Content blocks

Decision: a form item with `block` in place of `type` is display-only. It has no answer and no number, and it may
appear anywhere among the questions.

- `paragraph`: plain text.
- `list`: an array of strings, shown as a bulleted list.
- `code`: monospaced text, such as a command preview.
- `table`: key and value pairs, such as a summary. The pairs are an object under `rows`, in the order the spec
  gives them. Amended 2026-11-21; see Decision Log.
- `notice`: text with `level` `info`, `warning`, or `danger`.

Rationale: question text belongs to its question. A form that shows what it will do before it asks needs structure
that question text cannot carry.

### Buttons

Decision: buttons belong to the form. Each has an `id`, an optional `label`, and a `role`.

- `primary`: Return activates it outside a multiline field. At most one per form.
- `normal`: no special key.
- `cancel`: Escape activates it once no picker or popup is open. It never validates. At most one per form.
- `destructive`: styled as a warning. It is never the default button, and Return never activates it.
- `validates` defaults to true, except for `cancel`. A button with `validates: false` submits whatever is filled in,
  unchecked.
- A form with no `actions` gets OK as `primary` and Cancel as `cancel`.
- A form whose buttons are all `cancel` is refused, since the user could not submit it. Amended 2026-11-21; see
  Decision Log.
- Choices such as "Yes to all" are plain buttons. The script gives them their meaning.

Return inserts a newline in a multiline field. Escape first closes an open color picker, file panel, or popup. These
are unmodified keys inside the applet's own view, so they do not touch window keys under ADR-04.

### Validation

Decision: validation uses a subset of JSON Schema's keywords. uniterm checks each field as the user types, so a
validating button's state is always current. Amended 2026-11-14; see Decision Log.

- A field's error shows when the user leaves the field or tries to submit, never on every keystroke. A shown error
  clears as soon as the input becomes valid. This follows the form rules in the UI design standard.
- Errors sit beside their fields.

- Keywords: `minLength`, `maxLength`, `pattern`, `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`,
  `multipleOf`, `minItems`, and `maxItems`. "Positive" is `exclusiveMinimum: 0`. "Non-negative" is `minimum: 0`.
- A keyword that does not apply to its type refuses the spec.
- Every keyword except `pattern` runs in linear time over bounded input, on the main thread.
- `pattern` runs off the main thread with a time cap and an input-length cap. The match stops when the cap fires, so a
  runaway pattern stops using CPU and stays in-process under ADR-07. When a check times out, the field shows "could not
  check", and a validating button stays disabled. A pattern that fails to compile refuses the spec.
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
  asks for confirmation, since the caller is notified. An open form is not the running work that ADR-05 asks about
  before a close. Closing it loses nothing but the unsent answers, and the caller learns of it at once.
- `wait-form` is the form's completion mechanism. ADR-11's completion event serves callers that read an event stream,
  and a form's caller waits on its handle instead.
- A run end, a revocation, or a closed connection closes the form, fails a pending wait as ended, and frees the
  handle. Since the form had no effect beyond showing, "ended" truthfully means nothing was submitted. The wire spells
  it as its own failure kind, `ended`. Amended 2026-11-21; see Decision Log.
- Result slots have the same caps and lifetimes as other ADR-11 handles. A connection holds at most 32, and a new one
  drops its oldest settled one. Amended 2026-11-21; see Decision Log.

Rationale: a handle keeps the first answer honest at once. A script that is interrupted still gets a clear outcome.

### Room for script-side review

Decision: this proposal does not build a round trip where the script accepts or rejects a submission. Three choices
keep it possible later.

- Strict decoding, so a later `review` flag fails loudly on this version.
- Submission numbers, so a later reject call can name the submission it refers to.
- A shared error shape, `{"errors": {"<id>": "<message>"}}`. uniterm's own validation already uses it, and a script's
  rejection would show the same way.

A later review mode applies only to validating buttons. Cancel, closing the tab, and `validates: false` buttons always
close at once, so the user is never stuck waiting on a script.

### The ask power

Decision: asking the user is a permission kind, `ask-user`, version 1.

- A controller package declares `{"kind": "ask-user", "version": 1}` in `controller.json`. A declared file declares
  `{:kind :ask-user :version 1}`.
- The power has no scope fields. It covers opening a Questions pane in the caller's own window, beside the caller's
  own pane, and showing forms in it. It grants no other pane action, so asking needs no pane-control grant, and
  holding `ask-user` gives no pane control.
- Every caller that is not a declared run may ask without a prompt, for forms that name its own pane as the asker, as
  `post-status` works today. That covers a bare terminal-session caller such as bash running `uniterm ask`, a REPL, a
  connection the user granted a pane, and an unsafe undeclared run. The one-form rule and the open-form cap limit
  spam. Amended 2026-11-21; see Decision Log.
- A package or declared file that does not declare `ask-user` is refused, with a message that names the missing kind.

Rationale: the bash case is the main use, and a prompt before every `uniterm ask confirm` defeats it. Declared callers
still state the power up front, so the review shows it.

### Where the form calls live

Original question: the design named `open-form` and `wait-form` as new ScriptWire calls, and also said the pending
reply is built in the applet contract. A script reaches an applet only through `send-command`, which needs pane
control and a target pane. No call discarded a handle.

Decision: host calls. `open-form`, `wait-form`, and `discard-form` are ScriptWire calls with their own codes, gated by
`ask-user`. (autonomous)

- The host drives the Questions applet in-process. It holds `wait-form`'s reply the way it holds a reply that waits on
  a permission question. Revocation, run end, and a closed connection fail it through the host's one path for ended
  authority.
- Before a pending `wait-form` completes, the host checks the caller's authority and binding again. A caller that now
  acts for another pane, or lost its binding, gets the wait failed as ended, never the answers.
- `discard-form` frees a handle. Discarding the handle of an open form closes the form as ended.
- UTERM-019's pending reply lives in the applet contract. This one lives in the host. They share ADR-11's rule, not a
  mechanism.

Rationale: each host call already maps to its own power by call code, so `ask-user` needs no special case. The host
knows the caller, so it can draw the header from what the transport established. An applet's `perform` receives only
a command name and arguments, so an applet command could not. `send-command` also decodes its arguments through
Foundation into a value where the last of two equal keys wins, which breaks strict decoding. Converged in 1 pass.

### How the spec is decoded

Original question: `controller.json`'s strict reader accepts only strings, unsigned whole numbers, arrays, and
objects. The spec needs booleans, null, negative numbers, and fractions.

Decision: widen the shared strict reader to the full JSON value grammar, keeping today's integers as they are.
(autonomous)

- Today's integer case keeps exactly its current domain: unsigned, at most nine digits. Booleans, null, and every other
  number each get their own case.
- Unknown and duplicate keys are still refused, and depth stays capped.
- Readers that match the integer case directly, such as the policy file's format and version checks, keep their
  meaning. `controller.json` and policy files accept exactly the values they accept today.
- The spec reader reports errors in its own terms, naming the spec field, not as a `controller.json` error.

Rationale: one grammar keeps the UTF-8, duplicate-key, and depth rules in one place. A new case for each new value
kind means no existing match can read a negative or a fraction as a version. Widening the integer case instead would
let a policy file with `"version": -1` read as newer, and the trust store would stop saving. A second reader would copy
the rules, and a fix to one would miss the other. A grammar mode is a parameter a caller can pass wrong. Converged in 1
pass.

### What a requester is

Original question: one form per requester, tab reuse, the tab cap, and the header all depend on what counts as one
requester. Each `uniterm ask` is its own process and connection.

Decision: a run, a terminal session, or a connection. (autonomous)

- A declared file run or a package run is one requester.
- A bare caller acting from a terminal is keyed by its terminal session: one terminal tab's session root and its
  generation. Each terminal tab in a pane is its own requester.
- Every other connection is its own requester. That covers a connection the user granted a pane and a REPL helper. Its
  header names the program the transport established, never "Terminal session".
- A resolved tab stays, showing its outcome, until the requester's next form reuses it, the requester ends, or the
  user closes it. A terminal session ends when its shell ends. The Questions pane closes with its last tab. Amended
  2026-11-19; see Decision Log.

Rationale: keying by terminal session lets a multi-step bash script reuse one tab, and keeps two terminal tabs in one
pane from refusing each other as busy. Keying a granted connection by its pane would put it under "Terminal session in
<pane>", which names the wrong requester under ADR-14. Keying by session root would put a declared run and the shell's
bare calls under one header, which cannot name both. Converged in 1 pass.

### The question-only session

Original question: how does `uniterm ask` begin its session? UTERM-021 gives the bundled command three begins: a file
begin, an undeclared begin that strict mode refuses, and a generic peer's plain begin. `uniterm ask` runs no script
code.

Decision: `uniterm ask` opens a question-only session. (autonomous)

- The session opens with a new message, the question-only begin. It says the bundled command runs no script code.
  The app admits it in strict and unsafe mode as a terminal-session caller.
- A call on a question-only session other than `open-form`, `wait-form`, or `discard-form` ends the connection as a
  protocol violation. The command never sends one, so no reply is owed. Amended 2026-11-21; see Decision Log.
- The bundled command is authenticated as UTERM-021 requires, so a generic peer cannot send the question-only begin.

Rationale: strict mode is the default, and the undeclared begin refuses every `uniterm ask` there. In unsafe mode it
shows a review before each one, which breaks the settled no-prompt rule for bare callers. UTERM-021 M4 refuses a plain
begin from the bundled command, so the plain begin would undo an accepted check. This is not an addition: the settled
scope already has bash asking without a prompt, and only a question-only session meets it. Converged in 1 pass.

### `uniterm ask` outcomes and exit codes

Original question: the command already publishes sysexits codes: 64 usage, 66, 69 unavailable, 70 protocol mismatch,
74 connection lost, and 78. Cancel was an action, so "0 means an action was chosen" exited 0 when the user pressed
Cancel. Busy and an unreachable app had no code.

Decision: sysexits for failures, small codes for answers. (autonomous)

| Exit | Meaning |
|---|---|
| 0 | A non-cancel action was chosen. For `confirm`, Yes |
| 1 | `confirm` got No |
| 3 | Cancelled or dismissed |
| 4 | Ended or revoked |
| 64 | Usage error |
| 65 | Spec error |
| 69 | The app is unreachable |
| 70 | Hello mismatch |
| 74 | The connection was lost, or stdout could not be written |
| 75 | Busy |
| 77 | The app refused the call, such as when a caller bound to no pane was denied a pane |
| 130 | Ctrl-C |

- A `cancel`-role press returns `{"form": <handle>, "outcome": "cancelled", "action": <id>}` with no answers. It is not
  a submission.
- `confirm` shows Yes as `primary` and No as `cancel`. For `confirm` alone, No exits 1.
- A form has at most one `cancel` button, since Escape activates it.
- A shorthand prints nothing on stdout for exits other than 0. `uniterm ask form` prints nothing then either.
- `confirm` prints nothing on exit 0, and `--json` makes it print `true`.
- Every wire failure kind maps to a code of its own meaning: a refused spec is 65, a refusal is 77, a busy refusal is
  75, an ended form and a handle the app does not know are 4, a call the app does not support is 70, a reply that was
  lost is 74, and a failure inside the app is 69. Exit 74 also covers an answer that could not be written to a closed
  stdout, with a line on stderr that says so. The command keeps the default SIGPIPE, so a pipe that closes early ends
  it as it ends any Unix tool, and the app closes the form when the connection closes. Amended 2026-11-21; see
  Decision Log.

Rationale: a Cancel that exits 0 lets `b=$(uniterm ask text ...) && git checkout -b "$b"` run after the user said no.
UTERM-003 already publishes 64 for usage, so a second usage code would split one command's contract. Sysexits names
every failure the command can hit, and a script can tell busy, which it may retry, from a spec error. Converged in 1
pass.

### Waiting and Ctrl-C

Original question: the Janet VM blocks until a reply arrives, and Ctrl-C does not free that wait. UTERM-019 keeps
Ctrl-C working by capping next-events' timeout.

Decision: free the wait with `discard-form`. `wait-form` has no deadline. (autonomous)

- On Ctrl-C, the helper stops waiting for `wait-form`'s reply and sends `discard-form` for the pending handle. The app
  closes the form as ended and fails the wait.
- The helper's wait looks for an interrupt itself, every 50 milliseconds, since a signal does not wake a thread that
  waits on a condition. The look reads a flag and sends nothing. The session matches replies by request ID with two
  calls in flight. A wait that an interrupt cut short returns nil to the script. The interrupt then stops the script at
  its next call or backward jump, where the VM looks for it. Amended 2026-11-21; see Decision Log.
- In a REPL, the app's own stop request fails the connection's pending wait, so the REPL keeps its VM state. The form
  stays open until the helper discards it. Amended 2026-11-21; see Decision Log.
- `uniterm ask` keeps the default SIGINT. Ctrl-C ends it with 130, and the closed connection ends the form.

Rationale: Ctrl-C takes effect at once with no new message and no capped wait. A capped wait would leave a REPL user's
first Ctrl-C unanswered until the cap. A second press 0.5 to 5 seconds later kills the helper and loses the VM state,
per UTERM-003. A new stop message would do what `discard-form` already does. An unbounded wait breaks UTERM-003's rule
that the first Ctrl-C stops a run. Converged in 1 pass, on an option the critic added.

### Focus when a form arrives

Original question: Return activates the `primary` button. A form that takes focus while the user types elsewhere can
receive a keystroke the user meant for another pane.

Decision: a form opens as the user's own open does. Amended 2026-11-20; see Decision Log.

- A split that opens a Questions pane takes focus as a split the user makes does.
- A new requester's form opens its tab in the window's Questions pane. The tab takes focus as a tab the user opens
  does.
- A form's content is live at once. No input arms it.
- A tab that closes, however it closes, leaves the pane as a tab the user closes does. When it was the last tab, the
  pane closes like any pane.
- A requester's next form reuses its own tab, per "One form at a time". The reused tab is selected and takes focus,
  as a tab the user opens does, and its content is live at once.
- Resolving a form leaves focus in its tab, which shows the outcome.
- Arrival posts a status line, as Pending Requests does.

Rationale: a program's operation behaves exactly as the user's. Opening a form beside the asker is a split or a tab
open, so it takes focus as those do. Keys the user is typing elsewhere then reach the form, as they reach any pane that
opens.

### The `pattern` dialect

Original question: Validation calls itself a subset of JSON Schema, whose `pattern` is ECMA-262. The app has no regex
engine yet. NSRegularExpression uses ICU syntax, and its progress callback stops a runaway match in-process.
JavaScriptCore's public API has no time limit.

Decision: ECMA-262 with the `u` flag, translated onto NSRegularExpression. (autonomous)

- uniterm parses `pattern` with the ECMA-262 grammar in Unicode mode. It searches unanchored, as JSON Schema does.
- It rebuilds each accepted pattern as ICU syntax from the parse tree, rewriting every token whose ICU meaning differs.
  Examples are `\d` as `[0-9]`, `\w`, `\s`, `\b`, `.`, and `$` as end of input. Source text never passes through.
- A construct with no proven translation refuses the spec, with a message naming the construct and the field. Every
  backreference refuses, and so does every lookbehind. A `\p{...}` name outside the supported table refuses, and the
  table holds the general categories, ECMA-262's binary properties, and a curated list of scripts. The documentation
  lists the accepted grammar. Amended 2026-11-21; see Decision Log.
- Widening the accepted set later is additive, since a refused pattern had no meaning before.

Rationale: JSON Schema 2020-12 says `pattern` SHOULD be ECMA-262 with Unicode support, so a pattern copied from a
schema keeps its meaning. ICU's own meaning differs on common tokens. `^[a-z]+$` accepts "abc\n", and `^\d+$` accepts
Arabic-Indic digits. ICU's meaning would also become permanent under strict decoding. JavaScriptCore would give the
exact meaning, but a runaway match needs a helper process, which reopens the settled in-process rule. Non-Unicode mode
matches UTF-16 code units, which ICU cannot express. RFC 9485's I-Regexp treats `^` and `$` as literal characters, so
the proposal's own `--pattern '^[a-z0-9/-]+$'` would never validate. Converged in 2 passes, on an option the critic
added. The second pass weighed the `u` flag and I-Regexp.

### Out of scope

- Password and other masked fields.
- The script-side review round trip.
- Granting a script read access to a file the user picked.
- Conditional questions that show or hide on other answers. A script sends a second form instead.
- One-question-at-a-time wizard layout.
- Links and rich text in question text and content blocks.

### Version skew

Decision: the change follows UTERM-004's skew rules.

- The command and the app: `open-form`, `wait-form`, and `discard-form` are new calls, and the question-only begin
  is a new begin. ScriptWire's version goes up. The hello requires an exact match, so an older command and a newer
  app refuse each other before any effect.
- An older build reading a `controller.json` or a declaration with `ask-user` refuses the unknown kind. That fails
  closed.
- An older app receiving a spec with a newer key refuses it as a spec error.
- Forms are never persisted. The trust store is the one stored format the change reaches. A newer build can save an
  approval that includes `ask-user`. An older build reading that policy file finds an unknown (kind, version). It then
  treats the whole file as newer and authorizes nothing in it, so every remembered controller approval goes inert in
  that build until the newer build runs again. This fails closed, as UTERM-019's policy changes do.

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
  Accepted: one open form per requester and the open-form cap bound it. A bare requester is a terminal session, so a
  loop of background `uniterm ask` calls in one shell holds one tab. Closing the tab dismisses the form at once. A script that
  asks again after each close can keep reopening its tab, and the user has no Deny for a bare caller. Ending the
  script ends it.
- **`uniterm ask`'s output and exit codes become a published contract** — likelihood: high, impact: medium.
  Mitigation: the exit codes reuse the command's sysexits contract, and each outcome has its own code. A new outcome
  takes a new code, never a new reading of an old one. The JSON result shape follows the spec's rule that new keys are
  additive.
- **`pattern`'s meaning becomes permanent through the translator** — likelihood: medium, impact: medium.
  Mitigation: the meaning is ECMA-262's, an external contract, so a translation bug is fixed toward it. Constructs with
  no proven translation refuse the spec, and M1's differential tests against JavaScriptCore pin the known divergences.
- **UTERM-021 is accepted but not built** — likelihood: low, impact: medium.
  Mitigation: the question-only session builds on UTERM-021's begins, strict mode, and command authentication.
  Dependencies name them, so M3 waits for UTERM-021's strict mode. A change to those during UTERM-021's build updates
  "The question-only session".
- **A downgrade leaves remembered approvals inert** — likelihood: low, impact: medium.
  Accepted: an older build reading a policy file that holds `ask-user` authorizes nothing in it, per "Version skew".
  It fails closed, and the newer build reads the file again unchanged.
- **Two layers enforce ADR-11's rule** — likelihood: high, impact: low.
  Accepted: UTERM-019's pending reply lives in the applet contract and this one's in the host, per "Where the form
  calls live". Each layer fails its pending replies on revocation, run end, and a closed connection. M3's checks pin
  the host side.

## Milestones

### M1: Form spec and validation

**Status:** DONE

- The strict reader refuses every unknown key, a misapplied keyword, a bad pattern, and each cap, with a message
  that names the field
- Fixtures cover every answer type, content block, and button role, including the default OK and Cancel
- Validation tests cover each keyword, required fields, and the error shape
- A catastrophic-backtracking pattern times out off the main thread and leaves the field as "could not check"
- A timed-out match stops using CPU, and each field has at most one check in flight
- `minLength` and `maxLength` count characters the way JSON Schema does, and a test pins the count for a string with
  combining marks and an emoji
- A spec whose text fields, choices, and answers are all at their caps still produces a result that fits one reply.
  The caps keep every answer string, the item count, and every `id` within the reply encoder's string, field-count,
  and key limits, so no answer is ever cut short
- The widened strict reader accepts and refuses exactly the `controller.json` and policy files it did before, except
  that the policy file `{"format": 2, "policies": [], "flag": true}` now reads as newer, which fixes
  [the policy-file bug](../bugs/20261114-policy-file-newer-format-read-as-broken.md). The fixtures that pin its
  parse messages are updated to the new field-level messages
- `minimum`, `maximum`, and `multipleOf` compare decimals exactly, so `multipleOf: 0.1` accepts 0.3
- A differential test runs translated patterns against JavaScriptCore with the `u` flag. It covers `\d` against
  Arabic-Indic digits, `$` before a trailing newline, `.` against U+0085, `\w` against "café", `\s` against U+FEFF, and
  a class containing `&&`
- Every backreference, every lookbehind, and every `\p{...}` name outside the supported table refuses the spec with a
  message naming the construct and the field

**As built:**

- The form model, strict reader, validation, and `pattern` engine are a new pure target, `QuestionForm`, with
  `QuestionFormTests`. It depends on `ControllerPackage` and `ScriptWire` and links no AppKit and no Janet. The tests
  link JavaScriptCore, and the app does not.
- The reader widening was already built by "Keep a newer policy file that holds a boolean, null, or fraction", which
  fixes [the policy-file bug](../bugs/20261114-policy-file-newer-format-read-as-broken.md). This milestone only
  verified it. `ControllerPolicyTests`, `ControllerDescriptorTests`, and the fuzzers pass unchanged in the full package
  run. The spec reader uses `StrictJSONReader` and the `StrictJSON` cases directly. It does not use `members`, since
  that throws a `controller.json` error. Its own field helper names the spec field instead.
- The caps are in `FormLimits`. The spec is at most 32 KiB, with at most 64 items, 8 buttons, and 64 choices a
  question. Ids are 1 to 32 visible ASCII bytes. A `string` answer is at most 1024 bytes, a `text` answer at most 4096,
  a choice's free-text entry at most 256, a path at most 1024, and a `file` answer at most 16 paths. Number literals
  have at most 20 digits and an exponent within 20. A `maxLength` below the type's cap lowers the answer cap, at four
  bytes a character. The reader refuses a spec whose worst-case answers exceed one reply payload, and names the first
  item that tips it over. It measures the worst case with the reply encoder itself. Fifteen `text` questions with no
  `maxLength` fit, and the sixteenth is refused. Widgets read each question's `answerByteLimit` and
  `answerEntryLimit`.
- A field's check is `FormChecker.verdict`, which runs every keyword but `pattern` in linear time. `FieldValidator`
  runs `pattern` on the field's own serial queue, and it reports `checking`, then `valid`, `invalid`, or `couldNotCheck`.
  A match has a 0.5 second limit and a 4096-unit input cap. A newer value stops the older match at its next progress
  report, and the older result is never reported. A match that ICU cannot finish, such as when its backtracking stack
  runs out, is `couldNotCheck`, never a no match. The error shape is `FormErrors`. The result shapes are
  `FormOutcome`. Its `ended` case has no script value, since M3 delivers ended as a failed wait. Every cap also holds
  in the result itself: a string is cut at its byte limit, a list keeps its first entries up to the limit, and a
  color or number that does not read becomes `null`.
- The `pattern` parser refuses lookbehind and every backreference. Its property table holds the general categories,
  ECMA-262's binary properties, and 13 common scripts. A test compiles every emitted name in ICU. The differential
  test compares about 100 pattern and input pairs with JavaScriptCore, including every case the check lists.
- The spec defines what the proposal left open. A `table` block's pairs are an object under `rows`. A `notice` has
  `level` `info` by default. A `text` question is single-line unless `multiline` is true. A `choice` takes `other`, and
  a `multi` does not. A default must pass its question's own rules, except `pattern`. A form needs a button that is not
  `cancel`. See the Decision Log.
- A fuzz test for the spec reader and the pattern parser is in `make fuzz`'s filter list. A scoped run of 20,000
  mutations under the address sanitizer passes.
- `make test-cost` does not exist in this project. The new test files run in about 1.2 seconds together. Most of that
  is the catastrophic-pattern test, which waits in real time to prove the stopped match uses no CPU.

### M2: Questions applet UI

**Status:** DONE

Amended 2026-11-21; see Decision Log.

- The Questions pane shows a tab per form, with a tab bar even for one form, and uniterm-drawn requester chrome
- Every answer type and content block renders and returns the answer shape in the table
- Return, Escape, and the button roles behave as "Buttons" says, including in multiline fields and open pickers
- Return, or a click on a disabled validating button, counts as trying to submit. It shows every error and moves focus
  to the first one
- A restored or reopened Questions pane has no tab and shows an empty state, and never sits blank
- A new requester's form opens its tab, which takes focus as a tab the user opens does. Its fields take keys at once
- A tab that closes, however it closes, leaves the pane as a tab the user closes does
- A requester's next form in its own tab selects that tab and takes focus, and its fields take keys at once, with no
  arming input
- A pane whose last tab closes, however it closes, closes like any pane
- Arrival posts a status line. Resolving a form leaves focus in its tab
- A field's error appears beside it when the user leaves the field or tries to submit, not while typing, and clears
  as soon as the input is valid. Validating buttons stay disabled until the form passes

**As built:**

- The pane is a new AppKit target, `QuestionsApplet`, with no SwiftUI. Its type is `questions`. It opens no file and
  takes no remote control. It has no launcher entry and no New Tab. Its commands are the tab keys the terminal and the
  browser share, so a user's remap of a tab item covers it.
- The in-process API for M3 opens a form for a requester key, with the requester's name and asking pane as the host
  established them, and reports the outcome once through a callback. A requester with an open form and a pane at its cap
  are refused as busy, and a closed pane is refused as unavailable. A requester's next form reuses its tab. `end`
  resolves an open form as ended and closes the tab. `discard` resolves it as ended and keeps the tab. The pane's close
  resolves every open form as dismissed.
- The tab rules are a pure tab book that the tests drive without a window. It holds the cap, the order in which tabs
  resolved, and the pick of the tab that gives way, which is the oldest unselected resolved tab. The applet applies the
  pick when a new requester arrives at the cap, so M3 only has to open forms. The cap is 8 tabs unless the host passes
  another.
- Widgets follow the type and the number of choices. A `choice` of up to five entries, `other` included, shows radio
  buttons, and more show a pop-up. A `multi` of up to eight shows checkboxes, and more scroll in a box. A `boolean` is a
  checkbox, with a third state for no answer when it has no default. A `color` is the system color well. A `file` opens
  the system open or save panel as a sheet. Every widget holds the caps from the spec reader.
- Return, Escape, and the button roles work as "Buttons" says. A click on a disabled validating button and a Return
  that cannot submit both show every failing error and send the keyboard to the first one. A pop-up and a file panel
  close on Escape without help. The color panel closes through a key monitor, since it is a window of its own.
- A closed pane ignores every later call, and its close frees each panel, so a late `end` at run end never exits the
  applet twice. A dimmed validating button offers the try to submit as an accessibility action. A shown error is tied
  to its field's help text, and a failed try to submit announces what it found. Return and Escape go on to the next
  responder when the form has no primary or cancel button to press. The color panel's Escape monitor acts only on keys
  sent to the panel or to the form's window.
- A form that opens in a pane whose first control refuses the keyboard, such as a pop-up without full keyboard access,
  gives the keyboard to the form's panel. Return and Escape still reach the form.
- The UI tests open forms through a debug-only hook, `UNITERM_TEST_QUESTIONS_DIR`, since no wire call opens a form yet.
  The asking-pane badge and the host's choice of pane are M3's.
- The package tests run in about a second together. About half of that is the first AppKit window of the test process.
  `make test-cost` does not exist in this project.
- The coordinator viewed the UI-test screenshots of one form and of two forms, in light and in dark, and the layout
  looked right. The user's own look at the pane in both appearances is M5's first check.
- Residuals: a file sheet that is open when its form ends stays attached until the user answers it, and the answer is
  then dropped. Nothing else was found.

### M3: The ask power and the form calls

**Status:** DONE

Amended 2026-11-21; see Decision Log.

- `ask-user` is a permission kind in `controller.json` and in declarations. An undeclared use is refused with the
  kind named
- `open-form` replies with a handle at once, and `wait-form` holds a deferred reply in the host
- A pending `wait-form` whose caller now acts for another pane, or lost its binding, fails as ended and never
  delivers the answers
- `discard-form` frees a handle, and discarding an open form's handle closes the form as ended
- A question-only session is admitted in strict and in unsafe mode, and any call but a form call on it is refused
- A question-only begin from a process that already has a session, such as a declared run that opened a second
  connection, is refused under UTERM-021's one-run rule
- An unsafe undeclared run's header names it as unverified and never implies a verified file
- Filling the tab cap with resolved tabs never refuses a new requester. The oldest unselected resolved tab gives way,
  and the selected one gives way only when it is the only resolved tab. A form never evicts its own requester's
  resolved tab, which it reuses instead
- A resolved tab that gives way leaves its handle's result readable by `wait-form` until the caller discards it or
  the slot's lifetime ends
- A bare terminal-session caller's `open-form` is allowed without a prompt, though the host prompts for other powers
  such a caller lacks
- Two terminal tabs in one pane each hold their own form, and a resolved tab stays until its requester's next form,
  its shell ending, or the user closing it
- A form opens in the window's Questions pane or in a split beside the asker, and the asking pane shows a badge. The
  split takes focus as a split the user makes does
- A REPL's stop request fails its connection's pending `wait-form`, and the REPL keeps its VM state
- A second form while one is open, and a form past the open-form cap, are refused as busy
- Tab close and pane close return dismissed. Run end, revocation, and a dropped connection fail the wait as ended and
  free the handle
- A bare terminal-session caller asks without a prompt, and its header reads "Terminal session in <pane>"
- A REPL caller's header names the REPL pane, never a terminal session
- A caller bound to no pane is refused or granted a pane as other calls are, and its form opens in that pane's window
- A Questions pane split beside a member of an owned group survives the owner's next layout request. The owner's layout
  of that group is refused whole, as for any pane the user split off, and no form in the Questions pane is dismissed.
  This is a run best guess. See the Decision Log.
- A busy refusal reaches the script as the wire's `busy` failure kind
- An older command and a newer app refuse each other at the hello

**As built:**

- `ask-user` is a permission kind at version 1 in descriptor format 2. It takes no field, joins the policy file as
  a kind of its own, and covers only itself. The lint maps the three form calls to it. A declared run that lacks it is
  refused with the kind named, and a declared run holds it as it holds any other power. A bare terminal-session caller,
  a REPL, a granted connection, and an unsafe undeclared run pass without a prompt, while the same caller's clipboard
  calls still ask.
- ScriptWire is at version 14. It adds the three form calls, the question-only begin and its admitted reply, and the
  `ended` failure kind. The Janet module offers `uniterm/open-form`, `uniterm/wait-form`, and `uniterm/discard-form`
  as the plain calls. `open-form` takes the spec as JSON text. See the Decision Log entry for this milestone.
- The host keeps one result slot for each form, in a table with a cap of 32 for a connection. `open-form` answers with
  the handle at once. `wait-form` holds its reply in the slot, and the answer comes from the slot whatever became of the
  tab. A wait reads the caller's authority, binding, and pane again before it answers, and a caller that fails any of
  them gets `ended` and no answers. A REPL's stop request fails the connection's pending wait and keeps its connection.
  The form stays open until the helper discards it.
- A requester is a run, a terminal session, or a connection. A run's or a connection's end closes its tab. A terminal
  session's tab stays when its program ends, and it closes when the shell ends or the user closes it. A program that
  ends with its form open leaves that tab showing the ended form.
- The question-only session is admitted in strict and in unsafe mode after the full check of the command, with no
  review. It allows only the form calls, and any other call ends the connection as a protocol violation. A second begin
  from one process is refused under the one-run rule, whichever session came first.
- The window layer opens a form in the window's Questions pane, or splits beside the asker with the placement a routed
  open uses. The split takes focus, and so does a new tab. The asker shows a badge beside the control badge, and the
  badge names the Questions pane in its tooltip and accessibility label. The header says so when the asker closes.
- An owner's layout of a group that holds a Questions pane is refused whole, so a form asked from a member of an owned
  group stays open. The owner can lay the group out again once the user closes the Questions pane. See the Decision Log
  entry for this milestone.
- The debug hook of the UI tests now opens forms through the window layer's own entry, so the placement, the focus,
  and the badge are the real ones. `QuestionsWireUITests` drives a declared script through the wire and the real app.
- The found bug [held requests](../bugs/20261121-held-requests-grow-without-bound.md) does not occur. The connection
  stops reading at its in-flight limit, and a test pins that. The file is `not-reproducible`.
- For M4: the Janet wrapper must discard the handle on every unwind, or the REPL's next `open-form` is busy, since a
  requester has one open form at a time.
- `make test-cost` does not exist in this project. The 52 new package tests run in about 1.5 seconds together.
- The owned-group refusal outlasts the answer. A resolved tab keeps the Questions pane open, and the pane sits in the
  group's content until the user closes it or its last tab goes. A run's tab goes when the run ends, and a terminal
  session's tab stays until the shell ends. The refusal names the Questions pane and says to close it, but only when
  that pane is the group's one unowned pane. A layout that fails for another reason reports its own error. See the
  Decision Log entry for the trace.
- A stopped host ends its open forms through the path a closed connection takes. A form asked from a program that no
  longer descends from its session root gets `ended` and no answers, since no call passes `authorize` while a wait
  waits.
- Residuals: the owned-group refusal above blocks an owner's relayout while a Questions pane sits in its group. A
  `uniterm ask` run from a pane the user granted shows the program's executable name and PID, which the transport
  established.

### M4: `uniterm ask` and Janet helpers

**Status:** DONE

Amended 2026-11-21; see Decision Log.

- `uniterm ask form` and each shorthand print the documented output and exit with the documented codes, including 77
  for a denied pane and 130 for Ctrl-C
- Ctrl-C during a Janet `wait-form` sends `discard-form` and stops the script at once. The session matches both
  replies by request ID in either order. When the user submits at the same moment, the tab shows only what the host
  knows: that the answers were sent
- `uniterm/ask` and its helpers return the result struct and discard the handle on every exit path, including an error
- A Janet spec with keyword keys, `id`s, and closed-set values converts to the JSON spec. A string in one of those
  places refuses the spec, and the result keys answers by keyword. A `table` block's pair keys are display text and
  stay strings
- A Janet number converts to the shortest decimal that round-trips, so `multipleOf: 0.1` accepts 0.3 from Janet as it
  does from JSON
- `uniterm ask` outside the bundle exits 78, and every wire failure kind maps to a documented code other than 0 and 1
- Script fixtures exercise each shorthand and the full spec through the real command and app

**As built:**

- `uniterm ask` is a new subcommand of the bundled command. It opens the question-only session, opens the form, waits,
  and discards the handle, on every exit that leaves the process running. Its flags are the ones in "Two API layers",
  plus `--json` and `--socket`. Each shorthand sends one required question whose id is `answer`, and `confirm` sends a
  paragraph with the buttons `yes` and `no`. The command reads the whole form from standard input for `form`, and
  refuses a form past the wire's size with 65 before it connects. The app reads every form, so the command checks only
  the shape of its flags. A number flag must be a JSON number.
- Outside the bundle the command exits 78 through the entry point's one check. Every wire failure kind exits with a
  documented code other than 0 and 1, and a test walks every kind. Ctrl-C keeps the default action, so the process dies
  of SIGINT, which a shell reports as 130, and the app closes the form when the connection closes. The test asserts the
  signal, not the shell's number.
- The Janet module offers `uniterm/ask` as a C function, and the six helpers as Janet source that runs once for each
  run, over `ask`. The converter in the shim writes the struct as the spec's JSON and refuses a string where a keyword
  belongs, or a keyword where text belongs, before any call. A table block's `:rows` keys and values must be strings. A
  number is the shortest decimal that reads back as the same double. Only spelling is checked in the shim. The app still
  reads the form strictly, so a number where text belongs reaches the app and is refused there.
- `ask` discards the handle after a result, and after a failed wait it discards first and raises the failure as it was.
  A discard that itself fails is dropped. A wait that an interrupt cut short is the exception, since the session
  already discarded the handle. The script lint counts every ask helper as a use of `ask-user`.
- The session keeps its replies in a mailbox keyed by request ID, and rejects a reply that answers no call in flight. A
  wait for a form looks for an interrupt every 50 milliseconds. On one, it sends `discard-form`, reads the wait's reply
  and the discard's in either order, and ends the wait as interrupted. A test plays an app that sends them in each
  order. A user's answer that lands before the discard is delivered to the wait and dropped. The host leaves the tab as
  the submit left it, and a test pins that. A REPL that is stopped during an ask discards the form, keeps its
  definitions, and can ask again.
- The Janet VM looks for the interrupt at a call, a tail call, a fiber resume, and a jump that goes back or stays in
  place. Interrupting a wait therefore stops the script at its next call or backward jump, and not at its next
  instruction.
- The shipped command's sandbox test passes unchanged. The UI tests run a declared script with a helper and a bash
  script with the command through the running app. The coordinator runs them, and the user's own run of both flows is
  M5's second check.
- The 44 new package tests run in about 5 seconds together, most of it in the process starts of the run and Ctrl-C
  tests. `make test-cost` does not exist in this project.
- The shim roots the module and the helpers' scope while the helpers are defined, since defining them runs Janet code
  that can collect. A test forces a collection there through a hook, and it crashed with the module unrooted.
- Residuals: a script that Ctrl-C stops during an `ask` returns nil from it for an instant before the interrupt takes
  effect, so a `protect` around `ask` does not see an error. A number where text belongs passes the shim and fails in
  the app as a refused spec.

### M5: The user's checks

**Status:** NOT STARTED

Amended 2026-11-21; see Decision Log.

Only the user can run these. The coordinator already viewed the UI-test screenshots of one form and of two forms, in
light and in dark. The coordinator also ran `QuestionsWireUITests`, whose bash and Janet flows drive the real app. The
user's own runs below confirm what those covered.

- The user looks at the pane in light and dark mode and confirms the layout and the chrome's contrast with permission
  prompts
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
- 2026-11-14: Review start: 4 milestones, 14 settled decisions plus the out-of-scope list of 6 items, 5 risks, no
  `**Live after:**` lines or row gates; no open questions; the user asked for an autonomous review of the draft at
  "Draft UTERM-022: Questions applet for script-asked forms".
- 2026-11-14: The user chose the UI design standard's validation timing. A field's error shows when the user leaves
  the field or submits, and clears once the input is valid. Checks still run as the user types, so button state stays
  current. The Validation decision said "checks each field as the user types and shows errors beside it", and the
  Summary said "Answers are checked live as the user types". Confirmed at the review gate.
- 2026-11-14 (autonomous): Clarified, with no change in meaning, that closing an open form is not ADR-05's running
  work, that `wait-form` is the form's completion mechanism under ADR-11, that `ask-user` opens a Questions pane only
  in the caller's own window beside its own pane, that a timed-out `pattern` match stops in-process under ADR-07, and
  that the tab title names the requester. A spike confirmed NSRegularExpression's progress callback stops a runaway
  match in about 0.2 seconds.
- 2026-11-14 (autonomous): Version skew now covers the trust store. An older build reading a policy file with
  `ask-user` authorizes nothing in it. It said "Forms are never persisted, so no stored format changes."
- 2026-11-14 (autonomous): Raised eight open questions from the review: where the form calls live, how the spec is
  decoded, what a requester is, how `uniterm ask` begins, its outcomes and exit codes, waiting and Ctrl-C, focus on
  arrival, and the `pattern` dialect. The status moved to `designing`.
- 2026-11-14 (autonomous): Where the form calls live: host calls `open-form`, `wait-form`, and `discard-form`, gated
  by `ask-user`. Only the host knows the caller, and `send-command` would lose strict decoding. The Risk that said the
  pending reply is built once in the applet contract became an accepted risk of two layers. The UTERM-019 Impacts
  entry changed to match.
- 2026-11-14 (autonomous): How the spec is decoded: widen the shared strict reader, keeping today's integer case and
  giving each new value kind its own case, so no existing reader changes what it accepts.
- 2026-11-14 (autonomous): What a requester is: a run, a terminal session, or a connection. Each terminal tab is its
  own requester, and a granted or REPL connection is named as itself.
- 2026-11-14 (autonomous): How `uniterm ask` begins: a new question-only session that strict mode admits, limited to
  the form calls. Dependencies now name UTERM-021's begins and strict mode.
- 2026-11-14 (autonomous): `uniterm ask` outcomes and exit codes: sysexits for failures and small codes for answers.
  A cancel press returns `cancelled` and exits 3, `confirm`'s No exits 1, and a form has at most one `cancel` button.
  This amends "Two API layers", which said "Exit codes: 0 means an action was chosen, and for `confirm` it means yes.
  1 means `confirm` got no. 2 means a usage or spec error. 3 means dismissed. 4 means ended or revoked."
- 2026-11-14 (autonomous): Waiting and Ctrl-C: Ctrl-C frees the wait by sending `discard-form`. `wait-form` keeps no
  deadline, and a REPL's stop request fails the pending wait.
- 2026-11-14 (autonomous): Focus when a form arrives: never take focus, and a replaced form's keys stay inert until
  the user's next deliberate input in it.
- 2026-11-14 (autonomous): The `pattern` dialect: ECMA-262 with the `u` flag, translated onto NSRegularExpression
  from the parse tree. Every backreference refuses for now, and so does any construct with no proven translation.
- 2026-11-14 (autonomous): Risk review: added the published `uniterm ask` contract, the `pattern` translator's
  permanent meaning, the unbuilt UTERM-021 dependency, and the downgrade of remembered approvals. Rated each on the
  evidence. The flood and spoofing risks now name the requester key and the focus rule. The pending-reply risk became an
  accepted risk of two layers.
- 2026-11-14 (autonomous): Re-check fixes. The tab cap counts open forms, and the oldest resolved tab gives way to a
  new requester. "One form at a time" said "The Questions pane caps its tabs. A form past the cap is refused as busy".
  Resolving a form moves no focus. A Janet spec uses keywords for keys, `id`s, and closed-set values, and refuses
  strings there. "Two API layers" said only that Janet passes the same spec as a struct.
- 2026-11-14 (autonomous): Final re-check fix, not re-checked, since the proposal loop's three passes were spent. The
  oldest resolved tab that is not selected gives way. The inert-keys rule now covers any change to the form shown in a
  focused pane that the user did not choose. Otherwise closing a selected resolved tab could select another
  requester's open form with live keys. The rule said it covered "a new form" that "replaces one in a Questions pane
  that has focus".
- 2026-11-14 (autonomous): The user asked for flagged items to go back for a recheck, not to the gate. The recheck
  found that typing in a field could still arm a different requester's form after its neighbor's run ended. Now only a
  click or Tab arms a different requester's form after an unchosen change, and no field takes focus. A requester's
  own next form still arms on a typed character. Return, Escape, and Space never arm a form. The rule said a form's
  keys went live on "the user's next deliberate input in it, such as a click, Tab, or typing in a field".
- 2026-11-14 (autonomous): A second recheck found that Tab, the next key in filling a form, armed a different
  requester's form the same way. Each patch to the arming keys left a neighbor path open. The cause was selecting a
  neighbor tab the user did not choose. Now an unchosen close or eviction shows a placeholder with no control, and the
  pane never shows a different requester's form until the user picks its tab. A requester's own next form arms on a
  typed character only after the user resolved the previous one. This replaces the arming rule for a different
  requester's form, which said "Only a click or Tab arms it".
- 2026-11-14 (autonomous): A third recheck found two more paths. A focused pane closing with its last tab handed the
  keyboard to the asker's terminal. Tab armed a terminal session's next form after the previous one ended. Now a focused
  pane whose last tab closes without the user stays open on the placeholder. After an ended form, only a click arms the
  next one. "What a requester is" said "The Questions pane closes with its last tab", with no exception. The fourth
  recheck converged.
- 2026-11-14: Review gate, first part: the user kept the `pattern` dialect.
- 2026-11-14: Review gate: the user kept the question-only session, untagged. The user named it, replacing "the ask
  begin", which read as protocol jargon.
- 2026-11-14: Review gate: nothing reopened. The user kept the question-only session and the `pattern` dialect,
  confirmed the validation timing, and dropped the `widget` hint. The tab eviction fix went back for rechecks, as the
  user asked, and converged after the focus rules gained the placeholder.
- 2026-11-14: ADR candidate (cuts across the system): a change the user did not choose never moves keyboard focus or
  puts live input under the user's keystrokes. Written as ADR-12.
- 2026-11-14: The user accepted the proposal.
- 2026-11-14: The user dropped the `widget` hint from `multi` questions for now. No record justifies it: the Decision
  Log never named a script or request that needs it. It is also ambiguous: nothing said whether uniterm may override
  it, and `choice` had no matching hint. Under strict decoding a later proposal can add the key without breaking
  scripts, and removing a published one would break them. The type table's `multi` row said "`widget` hint:
  `checkboxes`, `chips`, or `select`", and the list under it said "Without a `widget` hint, uniterm picks the widget
  from the number of choices."
- 2026-11-14 (autonomous): Routed checks to M1 (pattern differential tests and refusals, match CPU and in-flight
  checks, length counting, result size and reply limits, reader compatibility, exact decimals), M2 (focus and
  arrival), M3 (REPL header, unbound callers, owned-group layouts, busy kind, wait rechecks, the question-only session,
  terminal-tab requesters, the REPL stop), and M4 (Janet keyword spelling, exit codes, Ctrl-C and reply matching).
- 2026-11-14: Scheduled as UTERM-022 M1-M4 in queue.md.
- 2026-11-19: ADR-12 no longer has a rule on closes. Every close hands the keyboard to the neighbor. The Questions pane
  now closes with its last tab, however it closes. "What a requester is" said: "The Questions pane closes with its last
  tab, except that a focused pane whose last tab closes without the user keeps its placeholder until the user moves
  focus or closes it". "Focus when a form arrives" said: "When the closed tab was the last one, the focused pane stays
  open on the placeholder, so the keyboard never falls to a neighbor pane." M2 lost the checks that kept that pane
  open and that kept it from closing the window. The placeholder for a selected tab that closes while other tabs remain
  is unchanged.
- 2026-11-20: ADR-12 was retracted. The user set that a program's operation behaves as the user's. "Focus when a form
  arrives" now opens a form as the user's own open does. It said "never take focus". An arriving form moved no focus,
  and a split left focus where it was. When the selected tab closed because its requester ended or it was evicted, the
  pane showed a placeholder with no control and selected no neighbor. A requester's next form armed on a click, Tab,
  or typed character, or only on a click after an ended form. Return, Escape, and Space never armed a form. An
  arriving form never switched the selected tab away from another requester's open form. Arrival was announced to
  assistive technology. A form in an unfocused pane needed a click or the pane-focus key. Its rationale argued from a
  `sudo` password typed into a background script's field. Now a split or a new tab takes focus as the user's does, and
  a form's content is live at once. A tab close leaves the pane as the user's close does. The status line stays. A
  requester's next form that reuses its own tab has no user equivalent, so whether it selects the tab or moves focus
  is open, as "Reusing a requester's tab". "One form at a time" said that evicting the selected tab, when it was the
  only resolved one, showed "the placeholder that 'Focus when a form arrives' describes". The tab now just closes. The
  spoofing risk lost "An arriving form never takes focus, so a background script cannot capture keystrokes meant for
  another pane." M2 lost its placeholder, arming, inert-click, and VoiceOver checks. Its focus check said "An arriving
  form takes no focus and switches no tab away from an open form". M3's eviction check lost the placeholder and the
  unselected arriving tab. Its split check said "The split leaves focus where it was". References lost ADR-12.
- 2026-11-20: Settled "Reusing a requester's tab". A requester's next form that reuses its own tab selects it and
  takes focus, as a newly opened tab does. "Focus when a form arrives" said whether the reuse selects the tab or moves
  focus was open. M2's reuse check now pins the selection and the focus. The open question is removed.
- 2026-11-21 (autonomous): M1 settled what the spec left open. A `table` block's pairs are an object under `rows`,
  since the Janet rule says a table's pair keys are display strings. A `notice` defaults to `info`. A `text` question
  is single-line unless `multiline` is true. `other` applies to `choice` only. A default must pass its own rules. A form
  with only `cancel` buttons is refused. Empty answers are `null`. The caps are 32 KiB for the spec, 64 items, 8
  buttons, and 64 choices of at most 256 bytes. A `string` answer is at most 1024 bytes and a `text` answer at most
  4096. A path is at most 1024 bytes, with at most 16 paths. A number literal has at most 20 digits and an exponent
  within 20. A `pattern` is at most 512 bytes, with at most 2048 parse nodes, 16 levels of groups, and repeat counts of
  at most 1000. A pattern check runs for at most 0.5 seconds on at most 4096 UTF-16 units. The reader reads
  through `StrictJSONReader` and the `StrictJSON` cases directly, not `StrictJSON.members`, since that throws a
  `controller.json` error. `ended` has no script value, and M3 delivers it as a failed wait. The `pattern` table
  narrowed: it refuses lookbehind, since ICU supports only
  bounded lookbehind, and it accepts general categories, ECMA-262's binary properties, and 13 common scripts. The
  Content blocks, Buttons, and `pattern` dialect text changed in place. "Content blocks" said "`table`: key and value
  pairs, such as a summary." "The `pattern` dialect" said "Every backreference refuses. The documentation lists the
  accepted grammar." "Buttons" had no rule for a form with only cancel buttons.
- 2026-11-21 (autonomous, work-queue best guess): M2 settled what the proposal left open. A restored or reopened
  Questions pane has no tab and shows an empty state. It stays until the user closes it. It does not close on its own,
  since a window whose layout holds only a Questions pane would close at restore. "The Questions pane" said "A restored
  or reopened Questions pane is empty, per ADR-03." M2 said "A restored or reopened Questions pane with no tab closes,
  or shows an empty state, and never sits blank." The pane holds at most 8 tabs unless its host says otherwise. A new
  requester's tab joins the end of the bar. `discard` ends an open form and keeps its tab, which then says so, and `end`
  closes the tab. The `questions` type declares no remote control and has no launcher entry. A layout request for it is
  refused as a REPL's is, since a program opens the pane through its form. A `boolean` is a checkbox with a third
  state for no answer when it has no default. Each question's caption says Required or Optional. The tab key commands
  carry the terminal's and the browser's titles. An optional pop-up keeps a "Choose…" item beside its default, so
  Clear shows what the script receives. The header's pane line reads "Asked from Pane 3", and "Pane 3 closed, so the pane
  that asked is gone" after the pane closes.
- 2026-11-21 (autonomous, work-queue best guess): M3 settled what the proposal left open. The wire gains its own
  failure kind, `ended`, since the command must tell a form that ended from any other failure to exit 4, and no
  existing kind says it. The three form calls are Janet functions too, `uniterm/open-form`, `uniterm/wait-form`, and
  `uniterm/discard-form`, because the script lint's table and the module must list the same calls. `open-form` takes
  the spec as JSON text. M4's `uniterm/ask` converts a Janet struct and wraps them. A requester's header shows its
  verified ID, `<id> (declared file)` for a declared file, and `<name> (unverified script)` for an unsafe undeclared
  run. The second names the file the command announced and proves nothing. The descriptor's display name proves
  nothing either, so it appears nowhere. A REPL is `REPL in <pane>`, and a connection the user granted a pane is
  `<program> (PID n), granted <pane>`. Result slots hold at most 32 for a connection, the cap the text viewer's handle
  table keeps. A Questions pane that opens beside an asker in an owned group joins the group's content and not its
  members, as any pane the user splits there does. So the owner's next layout of that group is refused whole until the
  user closes the Questions pane, and no form is dismissed. The M3 check said "A Questions pane split beside a member
  of an owned group survives the owner's next layout request, and no form in it is dismissed by that layout". "Requester
  chrome" said "A controller package or declared file shows its verified name." "Lifecycle and results" said "Result
  slots have the same caps and lifetimes as other ADR-11 handles." and named the failed wait only as "ended".
- 2026-11-21 (autonomous, work-queue best guess): The review of M3 kept four choices and amended the text to match.
  "The ask power" said "A bare terminal-session caller, such as bash running `uniterm ask`, may ask without a prompt for
  forms that name its own pane as the asker, as `post-status` works today." Every caller that is not a declared run
  passes now, since M3's checks need a REPL caller and an unsafe undeclared run to ask. "The question-only session" said
  "The app refuses every call on a question-only session except `open-form`, `wait-form`, and `discard-form`." The
  listener ends the connection for such a call, since the command never sends one. "Waiting and Ctrl-C" did not say that
  a REPL's stop leaves the form open. The helper discards it. The `ended` sentence in "Lifecycle and results" gained its
  marker.
- 2026-11-21 (autonomous, work-queue best guess): The refusal of an owner's layout, traced. The Questions pane is in the
  group's content for as long as it is open, so the refusal outlasts the answer. A resolved tab keeps the pane. A run's
  tab goes when the run ends, and a terminal session's tab stays until its next form, its shell ending, or the user
  closing it. The refusal ends when the last tab goes and the pane closes with it. The refusal message now names the
  Questions pane as the cause and says to close it. A test pins both ends. A split the user makes in an owned group
  behaves the same way, and ADR-15 says a program's operation behaves as the user's. The user may rule that an owner's
  layout should go ahead around the pane. That needs a tree rule that this milestone does not change.
- 2026-11-21 (autonomous, work-queue best guess): M4 settled what the proposal left open. The Janet helpers are
  `uniterm/ask-confirm`, `ask-text`, `ask-choose`, `ask-number`, `ask-color`, and `ask-file`, and each returns the
  answer or nil. `ask-confirm` returns true for Yes, false for No, and nil when the form was closed. "Two API layers" said
  "Helpers mirror the shorthands, such as `uniterm/ask-confirm`." Each shorthand's one question is required and has the
  id `answer`, so the user cannot submit nothing. `confirm` prints nothing, and `--json` prints `true`. `uniterm ask
  form` prints the whole result record, and prints nothing for a cancel or a close. The wire failure kinds map to codes
  as "`uniterm ask` outcomes and exit codes" now lists, with a failure inside the app as 69, a handle the app does not
  know as 4, an unsupported call as 70, and a lost reply as 74. A table block's `:rows` keys and values must be strings
  in Janet, so a keyword there refuses the spec. The helpers are Janet source over a C `ask`, and the script lint counts
  each as `ask-user`. The helper's wait looks for an interrupt every 50 milliseconds, since a signal does not wake a
  thread that waits on a condition. "Waiting and Ctrl-C" said Ctrl-C took effect "with no new message and no polling".
  The flag look sends nothing and reads one value. A wait that an interrupt cut short returns nil to the script, so the
  interrupt and not an error stops it. The module-function test now expects the wire calls, `api-version`, and the
  helpers. `ScriptValue.decode` is public, since the command reads a form's result with it.
- 2026-11-21 (autonomous, work-queue best guess): The review of M4 settled three more things. A standard output that
  cannot be written exits 74 with a line on stderr, and the command writes with POSIX `write` so that a caller that
  ignores SIGPIPE gets a code and not an abort. The command keeps the default SIGPIPE. The exit table's 74 row said
  "The connection was lost". Its 77 row said "A caller bound to no pane was denied a pane", and now covers every
  `refused`, with the pane denial as its example. "Waiting and Ctrl-C" said "The helper's wait wakes on an interrupt by
  itself", and now says the wait looks for one itself, to match the 50 millisecond look.
- 2026-11-21: ADR candidate (cuts across the system, hard to reverse): which callers a power that controls no pane
  passes without a prompt. `ask-user` passes for every connection that is not a declared or package run. Later powers
  would copy that tier. ADR-14 requires explicit grants for separate powers, but it does not say what a user's own
  session may do without one. Undecided.
- 2026-11-21 (autonomous, work-queue best guess): The row review moved the two checks that only the user can run out
  of M2 and M4 and into a new milestone, M5, since a check that only the user can run blocks `DONE`. M2 and M4 stay
  `DONE`, and M5 is `NOT STARTED`. M2's last check said "The user looks at the pane in light and dark mode and confirms
  the layout and the chrome's contrast with permission prompts". M4's last check said "The user runs a bash script and
  a Janet script that ask forms in the running app and confirms the flow". Their As built lines said the user's look
  and run were "left to the user", and now point at M5. M5 names what the coordinator already verified: the light and
  dark screenshots of one form and of two forms, and the bash and Janet flows of `QuestionsWireUITests`.
- 2026-11-21 (autonomous, work-queue best guess): The row review merged the two edits of "Waiting and Ctrl-C" into one
  bullet with one marker, and corrected how soon an interrupt stops the script. The text said "The helper's wait looks
  for an interrupt every 50 milliseconds, since a signal does not wake a thread that waits on a condition. The look
  reads a flag and sends nothing. A wait that an interrupt cut short returns nil to the script, and the interrupt stops
  the script at its next instruction." Janet's VM checks for the interrupt only at a call, a tail call, a fiber resume,
  and a jump that goes back or stays in place, so the script stops at its next call or backward jump. The rationale's
  second marker went, since it marked the same edit.
- 2026-11-21: Correction of fact. "Requester chrome", "File answers are paths", "What a requester is", and References
  cited ADR-09, which ADR-14 supersedes. They cite ADR-14 now, where its text carries the same principles: a requester
  scope no narrower than the transport can establish, and one power never silently granting another. The entries above
  that name ADR-09 are unchanged.

## References

- [ADR-02](../adr/ADR-02-pane-tree-nodes-have-stable-ids.md): the asking pane is named by its stable ID
- [ADR-03](../adr/ADR-03-restored-state-never-runs-a-program.md): forms are never restored
- [ADR-04](../adr/ADR-04-uniterm-owns-key-bindings-and-terminal-config.md): form keys stay inside the applet's view
- [ADR-05](../adr/ADR-05-applet-lifecycle-events-and-applet-responses.md): closing an open form needs no confirmation
- [ADR-07](../adr/ADR-07-failure-isolation.md) and [ADR-08](../adr/ADR-08-ui-responsiveness.md): bounded validation
- [ADR-11](../adr/ADR-11-deferred-applet-replies-never-hide-effects.md): the handle and the deferred wait
- [ADR-14](../adr/ADR-14-a-controller-controls-what-it-opened.md): the ask power and truthful requester chrome
- [ADR-15](../adr/ADR-15-a-programs-operation-is-the-users.md): proposed. A form that opens beside its asker behaves
  as the user's own open
