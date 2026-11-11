# UTERM-004: Pane Control and Trust

**Status:** accepted
**Created:** 2026-10-31
**Updated:** 2026-11-10

## Dependencies

- UTERM-001
- UTERM-003

## Impacts

- UTERM-005, UTERM-006, UTERM-007, UTERM-008, UTERM-009, UTERM-010 — "Control levels": each applet declares which
  access-mode and driver combinations it supports
- UTERM-001 — "What layout persistence restores": saved layouts record inactive control intent, never grants
- UTERM-003 — "Sandboxing", "Host API", and "REPL features": this proposal supplies fresh-helper capability grants,
  scoped discovery, authenticated pane binding, and the `uniterm/send-command` host function. Its M1-M2 replace broad same-user control when they land
- UTERM-005 through UTERM-010 — exec schemas and supported combinations stay with each applet's design; this
  proposal supplies the shared transport and tests it with presentation fixtures

## Summary

Programs and scripts can drive panes. This proposal defines who may control which pane, and how. Controller approvals
can last for one operation, one run, one verified version, or a signing identity across versions. It covers two
access modes, remote-controlled and disconnected, and an independent exec driver. It also lets a program request a
layout for the panes it owns.

## Motivation

The write-up's best ideas need panes that talk to each other. One example is telling the nearest browser pane to open a
page. Another is a presentation program showing slides, notes, and charts in separate panes. Each needs rules, so that
one program cannot take over panes it has no business touching.

## Design Decisions (Settled)

### Control modes and exec drivers

- **Remote-controlled (CONTROL-1).** Other programs may drive the pane, within the trust rules. The pane shows a visible
  marker, such as a robot icon.
- **Disconnected (CONTROL-2).** Other programs cannot address the applet through remote control. Host lifecycle
  events and the user's own actions still work.
- **Exec (CONTROL-3).** Independently of access mode, the applet can attach a program as its driver. Applet events go to
  the program's stdin. Its stdout drives the applet. Its stderr goes to the window history as info-level diagnostic text
  and takes no turn on the status bar. The host sanitizes, coalesces, and bounds it before the main-thread queue admits
  it. A driver exit or protocol failure that the host observes is a separate typed warning, or an error when user work
  is lost. Level never comes from matching words in stderr. The attached driver is not an ambient remote caller, so
  disconnected does not sever this explicitly attached channel. Amended 2026-11-06; see Decision Log.

Each applet declares which access-mode and driver combinations it supports. Unsupported combinations are refused
before anything starts. Window shortcuts reach uniterm before applet events reach a driver, per ADR-04.

Amended 2026-11-02; see "Is exec a control level?" and the Decision Log.

### How uniterm knows which pane a program runs in

Original question: how uniterm knows which pane a program runs in. Options were an environment variable, process
ancestry, or a per-tab socket or file descriptor passed to the shell.

Decision: use the peer identity on UTERM-003's listener and validate its live process ancestry against an explicitly
recorded terminal session root. A pane token is not authority.

- TerminalSurface supplies the actual spawned child's process identity, including its generation. Its protocol grows
  a typed identity event, `TerminalEvent.processStarted`. The pinned libghostty backend needs a narrow patch to
  expose the child. ThirdParty/ghostty-patches/001-child-started-action.patch adds a `child_started` action that
  carries the child's PID. libghostty's public API does expose `ghostty_surface_foreground_pid`, but that is the
  pty's foreground process group, not the spawned child. No other module reaches through the terminal boundary.
- The spawned child is setuid-root `/usr/bin/login`, which becomes the session root. `proc_pidinfo` refuses a root
  process for a non-root caller, so ProcessInspection reads start times and parents with sysctl(KERN_PROC_PID). The
  listener reads the peer's uid with LOCAL_PEERCRED and its PID with LOCAL_PEERPID.
- Each connection is bound to the authenticated peer process instance, the source tab/session, and UTERM-003's
  launch-scoped window and pane references. A reused PID is a different instance. Check the live identity and ancestry
  before granting automatic authority and before dispatch. An unavailable, changed, or ambiguous chain fails closed.
- App-created REPL and exec processes bind through the same recorded spawn identity. UTERM-003's REPL environment
  token may correlate a pending connection, but never grants authority without the process check.
- An unbound caller has no pane access. The user can explicitly grant that connection a named source pane in one
  window. The dialog names the requesting executable and scope. A grant binds to the pane's session. A pane with
  several tabs runs several sessions, and the grant binds to the newest one still running. A grant ends on disconnect,
  process exit, source session close, revocation, or window close. A denied or revoked connection is not asked about
  again. A reconnect needs fresh admission; verified controller policies may supply its permissions. An ordinary
  unbound caller asks again. An outside caller never receives every window. Amended 2026-11-10; see Decision Log.
- Ordinary descendants of a terminal session may act for that source pane. A daemon that loses its ancestry needs an
  explicit grant. Focus, a claimed PID, environment state, and a tty name never establish authority.
- This is application authorization, not an OS sandbox against malicious processes of the same user. Deliberate
  socket transfer, terminal-device injection, or process injection can relay another process's authority. Such work
  needs OS isolation to be a security boundary. The risks state this limitation.

Rationale: ancestry establishes pane provenance without a copyable bearer secret. An inherited descriptor instead
establishes delegable possession. Asking on every normal connection leaves automatic identification undone. The
explicit-grant fallback handles callers whose provenance cannot be established without guessing.

### Is exec a control level?

Original question: the write-up notes that exec might be a separate dimension from control. Options: one level among
three, or a separate setting that combines with the others.

Decision: access mode and driver are independent, as "Control modes and exec drivers" defines. An exec driver and an
authorized remote caller use the same command validation and serialized dispatch. A disconnected pane keeps its
attached driver and refuses ambient ingress.

Rationale: selecting a program to drive events says nothing about which other programs may address that pane. Three
exclusive states conflate those two contracts. Three presets backed by two dimensions would still omit the supported
remote-plus-exec combination.

### Trust follows the pane tree

A program may address its own source pane and panes in groups it explicitly owns. Geometry alone grants nothing.
It is not trusted with ancestors or unrelated siblings. Every operation also checks the target's access mode and
supported commands.

Rationale: the presentation program owns its explicitly created subtree and may lay it out. Normalized split-tree
shape cannot represent that authority. Amended 2026-11-02; see "What anchors trust" and the Decision Log.

### Same window only

A program may control panes only in its own window.

### Layout requests

A trusted program may request a layout for its own subtree. For example, it may ask for three panes holding a slide, a
set of notes, and a chart.

### Group node kind

This proposal defines a group node kind for UTERM-001's pane tree. A program's first pane request creates a group, and a
layout request creates one too. The group records its owner and never merges into its parent. UTERM-001's pane tree
lets a node kind define its own merge rule. Its layout file bumps the schema version for a new node kind, to version 2.
M2 builds the group and its saved form, since its checks need owned members. M4 builds layout requests on it. The
details are part of "What anchors trust" below. Amended 2026-11-10; see Decision Log.

### What anchors trust

Original question, raised by the UTERM-001 review on 2026-10-31. The settled "Trust follows the pane tree" reads trust
from tree shape.
UTERM-001 settled a normalized N-ary pane tree. In it, a leaf pane has nothing beneath it. A program's requested
subtree can also merge into a same-axis parent. And a user split can put new panes under a program's pane. Trust
likely needs an explicit owner mark that a layout request creates, with a grouping node kind that does not merge. This
may revise the settled decision.

Context from UTERM-001's implementation, in support of an ADR candidate on ID scope:

- Node IDs are unique only within one window, and a trust grant keyed by ID must carry the window too.
- A pane reopened by undo gets a new ID, so a grant keyed by ID does not follow it.

Decision: explicit ownership and membership anchored by a nonmerging group, never ordinary split-tree shape.

- A group's owner is a live connection bound to its source process and session. Group and pane IDs carry UTERM-003's
  launch-scoped window reference. A group never merges or collapses into its parent, including with one child. A
  group left with no member is removed and its ID retires. The source pane is placement metadata, not a member.
- The first layout wraps only the source pane and newly created panes. It preserves the source pane and applet.
  Later requests rearrange only still-owned members and create new ones. They cannot import unrelated panes,
  replace existing applets, or silently discard members.
- Nested layouts create explicit nested groups. Authority intersects the live connection's grant, window, explicit
  membership, target access mode, and supported operation at dispatch. Children gain no authority over parents or
  siblings by being nested. An ancestor owner retains only its existing explicit scope.
- User splits create panes outside the owned group boundary. A user split of a member puts the new pane beside it,
  inside the group's area but not among its members. A user move cannot add a pane to program ownership. Removing a
  pane from a group removes that group's authority over it. A new move UI is not required here.
- Disconnect, process exit, source-session close, window close, or user revocation removes the owner's authority.
  Group and content remain visible with no live owner. Another process cannot claim them by presenting their IDs.
  An attached exec driver retains only its explicitly attached channel, subject to its own lifetime.
- Scope checks apply to discovery and reads as well as mutations. Callers cannot list unrelated windows or pane
  metadata. Stale and out-of-scope references return no target data. Programs cannot enable control on existing
  disconnected panes. The user can revoke through pane chrome independently of applet content.
- Layout requests stage and validate a candidate tree and applet preparation, then revalidate authority at publication.
  Invalid references, unsupported combinations, insufficient space, or preparation failure publish nothing. Existing
  applet identities and content stay intact. External process effects cannot roll back: approved programs start only
  after the tree commits. A later launch failure reports in its pane without automatic retry or a claim of rollback.

Rationale: per-pane marks alone do not delimit structural edits. The wrapper preserves the boundary through
normalization. Explicit membership prevents unrelated user panes from gaining an owner by changing position. Amended
2026-11-10; see Decision Log.

### Exec wire format

Original questions:

- The message format on stdin and stdout, such as JSON lines.
- How each applet documents its events and commands.

Decision: UTF-8 JSON objects, one per LF-terminated line, on separate stdin and stdout pipes. Newlines inside strings
are escaped. Stdout carries protocol only; stderr carries diagnostic text.

- Both sides exchange hello messages with protocol version, applet type, and command/event schema version. No applet
  commands or user events flow until both versions are supported. Old driver/new app and new driver/old app refuse
  unsupported versions before effects, with an actionable error. In-place updates need no deployment order. Remote
  host calls retain UTERM-003's handshake and use the same command validation.
- Envelopes distinguish events, commands, successful replies, and structured errors. Request IDs correlate replies.
  Commands execute in order through shared serialized dispatch. Each applet publishes supported combinations,
  schemas, versions, and examples. Unknown commands and invalid arguments return errors without applet effects.
- A frame is at most 1 MiB. Retained queued bytes are at most 4 MiB per driver in each direction. Parsing also bounds
  nesting, decoded memory, and work per UI turn. A driver exceeding a bound fails visibly; commands are never silently
  dropped. A malformed frame or partial frame at EOF closes the channel. A stalled reader cannot block the UI or
  grow an unbounded queue. Limits apply before a complete line has been buffered.
- The applet owns a separate direct-argv child and its streams. Terminal program mode's pty cannot supply this
  protocol. Lifecycle events remain ADR-05's: the applet starts and cleans up its work. Close ends authority at once
  and shuts the child down asynchronously. Exit or protocol failure leaves the pane with a reason and an explicit
  restart action. There is no automatic restart.
- Stderr is drained with bounded retained text, sanitized and coalesced into source-labelled status messages. It
  cannot flood the main thread or masquerade as a host message.
- Terminal and REPL input injection remains unavailable, as UTERM-003 settles. An applet without an appropriate
  command schema or exec support refuses before launch.
- The applet contract gains one command and event hook, which this proposal adds. Shared dispatch delivers each
  validated command to the target applet through it, and the applet emits its events through it to its exec driver.
  An applet publishes its command and event schemas and their versions through the same member. Events emitted with no
  exec driver attached go nowhere and are not queued.
- Supported combinations are declared separately from commands, by every applet. An applet that declares nothing
  supports disconnected access with no exec driver. The terminal and REPL applets declare disconnected and
  remote-controlled access with no exec driver and no commands, as "Clipboard access from controlled panes" and M2
  assume.
- A remote host call carries one applet command to a target pane, with its reply or structured error. It uses UTERM-003's
  handshake and the same authorization, validation, and serialized dispatch as an exec driver's commands. Its authority
  is the caller's own grant, never an attached driver's channel. In UTERM-003's Janet module it is
  `uniterm/send-command`, following that module's verb-noun naming. Remote callers receive no applet events.
- Each remote command names the applet type and the command schema version it was written for. An unsupported type or
  version is refused before any effect, as the exec hello refuses. Skew: an old script or controller against a new
  app, and a new one against an old app, are both refused when the app does not support the named version. No deploy
  order is needed.

Amended 2026-11-03; see the Decision Log.

Rationale: JSON already serves the applet boundary and is easy for external drivers. CBOR can be equally correct,
but brings another serialization ecosystem without a stated need. Unversioned text leaves old commands liable to new
meanings. The applet schemas define semantics; JSON syntax alone does not.

### Clipboard access from controlled panes

Original question and context from UTERM-001. A terminal program's OSC 52 clipboard read asks the user, in a dialog
that names the pane. A write goes through without asking. The generated config sets `clipboard-write` to `ask`, and the
terminal surface allows every OSC 52 write that libghostty sends it. It denies every Kitty clipboard protocol read and
write. So a program in a remote-controlled or exec pane can replace the clipboard silently. Decide whether a control
level changes either rule. A write prompt would go in the surface's write callback, where an OSC 52 write arrives with
libghostty's confirm flag set. An ADR candidate on clipboard trust in UTERM-001's Decision Log may be shaped by this
decision.

Decision: remote-controlled and exec-driven panes require explicit permission for programmatic clipboard reads and
writes. A valid scoped approval can cover repeated requests. Attributable controller requests use the typed clipboard
API; shared-terminal OSC 52 offers only once/session permission for programs in that terminal session. A control grant
alone grants neither clipboard power. Amended 2026-11-07; see the Decision Log.

- Ordinary disconnected interactive terminals keep their existing read-ask, write-allow policy. Direct user Copy and
  Paste retain current rules. An attached exec driver triggers the controlled policy even when disconnected.
- TerminalSurface receives clipboard policy explicitly per session. The confirm callback enforces it for reads. The
  write callback enforces it for OSC 52 writes, which arrive there with libghostty's confirm flag set. Kitty clipboard
  requests stay denied in the confirm callback. Updating an existing session's policy completes before enabling
  ingress or an exec driver. A host-dispatch check alone cannot govern OSC 52.
- Answers revalidate the request's session, mode, and authority generation. Stale requests are denied. A denied read
  sends no data; a denied write leaves the clipboard untouched.

Rationale: a pane-scoped grant does not authorize silently replacing a global clipboard. Confirmation keeps deliberate
tmux, vim, and ssh workflows available. Denying all controlled clipboard use removes those workflows.

### REPL capabilities and host-side execution

Original question: UTERM-003 defers how a REPL receives Janet sandbox capabilities until this proposal settles control
modes. Decide how the user grants them, and how a layout or exec request avoids bypassing a helper's denied process
capability.

Decision: only a local user action starts or restarts a REPL with explicitly selected Janet capability names. The
fresh helper shows its grants. The default is none. Restart warns that live VM definitions will be lost; a live
sandbox is never widened. Revocation ends that helper and its pane authority. Grants are tied to that helper's
process generation, never inherited through pane ownership or restored from a layout. UTERM-003's explicit
`uniterm run --allow` behavior stays.

Host-side exec and program-mode launches need separate execution authority. A scoped grant can cover repeated
launches of named packaged entries with varying inputs. Without one, a local Allow once approval binds immutable
argv, directory, environment, and live target. Pane control and a helper's runtime process capability never imply host
execution permission. Scripts cannot activate Run or approve their own requests. Ordinary interactive-shell restore
remains ADR-03's exception. Approved programs are not claimed to be OS-sandboxed by this policy.

Amended 2026-11-02; see "Permission scopes and approval flow".

Rationale: pane ownership, runtime capabilities, and executing a host-side program are distinct permissions. Equating
them lets a script bypass its denied process capability through a layout request. Keeping every REPL unprivileged
would leave the deferred in-pane grant workflow unavailable.

### How control is enabled

Decide the defaults for user-created and program-created panes, who changes modes, and what a caller may request
when its source pane is disconnected.

Decision: user-created panes start disconnected with no exec driver. A local pane-chrome action enables remote
control. It never follows focus or a neighboring pane's mode. Identity alone permits no target metadata, applet
commands, or rearrangement of a disconnected pane. A connection can obtain only its own binding information and an
error explaining the local enable action. Ordinary denied calls do not open enable dialogs.

Once enabled, a source program may explicitly create remote-controlled panes in its owned group. Creation and
ownership authorize that mode on new panes; enabling an existing disconnected pane remains user-only. A program launch
still needs the separate execution authority in "REPL capabilities and host-side execution".

Disconnecting a target invalidates queued ambient calls to it before the action returns. Revoking a controller ends
its live grant, including queued calls and owned-group authority. These are distinct actions: a disconnected source
may still issue outbound calls to other targets it already owns, but cannot rearrange its disconnected source pane.
Pane chrome shows mode, owner, and driver, and exposes enable, disconnect, and revoke without relying on applet input.

Rationale: remote-by-default grants ordinary descendants authority before consent. Prompting on the first denied call
lets untrusted traffic create unsolicited dialogs. Local enablement separates provenance from permission.

### Exec launch context

Original question: how exec argv, working directory, and environment are supplied without hidden inheritance from
uniterm or a neighbor pane.

Decision: a declaration supplies literal argv with an absolute executable path, an optional absolute working directory,
and an explicit environment map. No shell interprets argv. Missing directory means the user's home. The base
environment contains only HOME, USER, LOGNAME, and TMPDIR from the OS user/session, plus
`PATH=/usr/bin:/bin:/usr/sbin:/sbin`. Extra variables come only from the explicit map. Nothing comes implicitly from
uniterm's environment or another applet's directory.

An Allow once launch approval shows and binds resolved argv, directory, and environment overrides. A reusable scoped
approval instead covers the declared entry and its allowed directory and environment-key scopes; runtime values may
vary within them. Environment values remain runtime-only: layouts retain required key names, never values. A restored
Run action waits for those values and current execution authority, which a matching policy can supply. The user must
still choose Run. Command and directory remain inert saved state. Amended 2026-11-02; the explicit context and defaults
are unchanged.

Rationale: full inheritance can leak credentials and makes identical declarations behave differently depending on
how uniterm launched. Requiring every ordinary OS variable individually adds friction without removing a further
state dependency. The documented base is explicit. CLAUDE.md requires the user to confirm this choice at the gate.

### "Nearest" pane

- How "the nearest browser pane" is defined: closest in the tree, most recently focused, or explicit.
- What happens when no such pane exists: fail, or open one.

Decision: filter to authorized remote-enabled targets of the requested applet type in the caller's window first.
Rank by shortest edge distance from the source pane in the current normalized pane tree, treating group wrappers as
transparent. Break ties by reading order, then stable pane ID. This is tree distance, not physical screen distance.
Explicit references remain available when the caller needs a fixed target. A script names a nearest target as
`{:nearest kind}` wherever a pane reference goes, and the caller's own pane counts as a candidate. Amended 2026-11-10;
see Decision Log.

Resolve and revalidate at dispatch. No match returns a structured not-found error. It never falls back to an
unauthorized pane or creates one implicitly. Creating a pane or layout is a separate explicit request.

Rationale: focus-based selection changes with unrelated user activity. Explicit references alone leave the requested
convenience unavailable. Filtering before ranking prevents proximity from becoming authority.

### Saved layouts

Original questions:

- How a program's requested layout is remembered and restored.
- Whether a restored layout keeps its trust, or asks again.

Context from UTERM-001: the layout file stores each window's tree with its node IDs and a per-window ID high-water
mark. Windows are stored by order only, with no saved identity. A description this build cannot read round-trips
byte-for-byte. A new node kind, such as the group, bumps the schema version, and an older build moves a newer file
aside.

Decision: save layout intent, never live authority.

- Save group structure, geometry, source/member node IDs as inert placement metadata, desired access/driver modes,
  and applet descriptions. An exec declaration saves argv, directory, and required environment key names only.
  Connections, process generations, live owners, live grants, sandbox capabilities, and environment values are not
  saved in the layout. Durable controller policies live separately.
- Relaunch and undo have no active owner or ambient control. Effective access starts disconnected; saved desired
  modes are shown as inactive intent. Exec runs nothing until a local Run action and current execution authority.
  A matching verified policy can provide that authority without another permission dialog. A restored REPL starts with
  no capabilities. Undo's new pane ID never inherits an old grant, even within a surviving group.
- The user may explicitly grant a new live connection the exact restored member set through pane chrome and enable
  the desired targets. The grant binds current identities, not historical process names or file claims. A new exec
  attachment alone grants no ownership of restored siblings. Reopened panes stay unowned until explicitly assigned.
- The group and host-owned mode/driver metadata bump the envelope schema version. Old layouts migrate to no grants
  and disconnected modes. Applet payloads keep their own versions and unreadable bytes, per ADR-06. A corrupt group
  or cross-window membership can never enlarge a grant.
- Stored-data skew follows ADR-06: a new app upgrades an old envelope step by step. An old app keeps a newer file aside
  unchanged and starts a default layout. A downgrade then upgrade can lose the active newer arrangement; the kept
  copy remains available for manual recovery. No new deployment gate is needed.

Rationale: restoring geometry should not let a different process inherit a former program's authority. Dropping
program-created layouts entirely loses the requested remembered arrangement. Inert intent keeps both properties.

### Controller trust and approval choices

Original question: how to avoid repeated permission interruptions while knowing which controller requests access.
The user chose a common framework for binary and script controllers, including optional persistent identity trust.

A controller description has a stable controller ID, display name, binary or script entry, packaged code and
dependency digests, and declared typed permissions. The display name is not proof of identity. Script identity never
comes from trusting the shared interpreter or Janet helper.

Approval choices:

- Allow once: the pending operation only.
- Allow for this session: the requested permissions for the current authenticated controller run.
- Trust this version: remember approval for this exact verified artifact, including packaged code and dependencies.
- Trust this identity: remember approval for the signing key and controller ID across correctly signed versions.

Signing is optional. Unsigned controllers can receive version trust. Local signing keys and signing tooling do not
require a paid Apple developer certificate or installation of a system-wide trusted root. Key continuity identifies
an approved signer, not a verified real-world person. A new signing key needs approval.

A durable approval records its identity or version selector and normalized, typed permission scopes. A startup request
covered by that approval proceeds without another dialog, including a narrower request. New powers or broader scope
need one review showing the difference. Runtime capabilities, clipboard reads, clipboard writes, host launches, and
pane-control authority remain separate permissions. Undeclared effects are refused. Semantic permission containment and
verified-artifact-to-run binding are required; a client cannot assert its own approved script name or digest.

Approvals live outside layout state. Controllers & Permissions provides inspection and revocation. Each run creates a
fresh authenticated process/connection binding and current pane/group scope. Saved approval cannot restore an old
connection or adopt arbitrary restored panes. Layout restore still runs no controller automatically.

Rationale: users can approve a useful stretch of work and remember trusted controllers without repetitive dialogs.
Version trust supports unsigned tools; identity trust preserves approval across signed updates. Neither is blanket
trust in every script run by a shared interpreter. Amended 2026-11-02; replaces the earlier run-only consent direction.

### Permission scopes and approval flow

Original question: integrate startup declarations and remembered approvals with clipboard attribution, host-launch
scopes, control enablement, REPL capabilities, revocation, and inert restore without repeated modal interruptions.

Decision: approve typed authority ceilings, rather than exact launch inputs. A controller declares its requested
powers once at startup. Normalize permissions and compare their semantic version and scopes against the approval.
An unchanged or narrower request is covered. An unknown permission meaning, additional power, or broader scope
requires a local review before effects. Undeclared effects fail even when the controller's identity is trusted.

- A host-launch grant names packaged entry IDs, current owned-group targets, allowed environment keys, and permitted
  directory scope. The approval explicitly says that arguments and environment values may vary within these bounds.
  Values remain runtime inputs and are not saved as approval secrets. Another executable/entry or broader scope needs
  approval. Arbitrary host-program execution is not implied by permission to launch a declared packaged entry.
- Allow once binds one identified pending effect and its immutable inputs. A session grant binds the authenticated
  live run. Version and identity policies can cover later freshly authenticated runs. A pathname, claimed digest,
  process name, or old pane ID cannot activate a remembered policy.
- Attributable controller clipboard reads and writes use new typed requests over the existing listener or exec
  channel. Each checks the live controller grant at the actual access boundary. Reads and writes are separate powers.
  Shared-terminal OSC 52 has no persistent script-specific attribution: it offers once/session terminal approval,
  honestly labelled as covering programs in that session. Ordinary disconnected interactive terminal behavior stays.
- Permission requests are bounded and coalesced into a host-owned pending indicator. The user opens the local panel;
  repeated protocol messages cannot spawn repeated modal dialogs. The indicator is the window's pending-permissions
  slot, a typed window state that sits before the focused applet's segments. Denial suppresses automatic re-prompting
  until a local retry. Coalescing cannot widen Allow once into approval of multiple different operations. Amended
  2026-11-06; see Decision Log.
- A user's Run action supplies execution intent. A matching policy can supply permissions without a second dialog.
  Saved layout state alone never executes a controller. Remembered permission does not override an existing pane's
  disconnected mode or adopt restored group members. Source enablement and restored-member adoption remain local.
- REPL capabilities apply before a fresh VM starts, never by widening an existing sandbox. Mutable interactive REPL
  evaluations cannot borrow an approved packaged script's identity. Helper runtime capabilities, host execution,
  clipboard powers, and pane control remain separate dimensions.
- Durable policies live in a separate versioned private file, written atomically. Corrupt files and unknown policy
  semantics authorize nothing and are kept for recovery. Layout files contain no policy or signing key. Optional
  local signing keys use Keychain. Controllers & Permissions shows trusted selector/fingerprint, approved scopes, and
  active runs. Revocation removes remembered policy and current authority, including queued work. It cannot undo
  external effects already performed by an approved program.
- Admission and typed clipboard contracts are versioned. Old controller/new app and new controller/old app refuse
  unsupported semantics before effects. Permission scopes refer to current roles and owned groups, not persisted
  window or pane references.

Rationale: varying a chart's document argument does not request more authority. Exact-input matching would repeat
prompts despite unchanged powers. Identity trust alone must never authorize undeclared powers. The typed clipboard
API adds an attributable path; anonymous escape sequences cannot gain controller-specific persistent trust.

### Verified artifact and run binding

Original question: bind approval to verified packaged code and dependencies, without loading different bytes later or
mistaking an interpreter's identity for its script.

Decision: verify a completed private per-run snapshot and bind admission to its actual execution. Preserve the CLI-owned
Janet VM and existing listener; do not add a CLI terminal-I/O or signal relay.

- A small versioned descriptor lists controller ID, binary or Janet entry, packaged file digests, and declared
  permissions. Version trust covers descriptor and packaged code/dependencies. An optional signature covers the
  descriptor and its file digests; identity trust pins the signing public key plus controller ID. Signing and loading
  share one interpretation of the exact descriptor bytes. Unverified display metadata conveys no authority.
- Copy to a fresh private snapshot, then verify its completed contents against the descriptor. Reject missing or
  unlisted code, escapes, symlinks, special files, and ambiguous paths or fields. Retain the read-only snapshot for
  the run. Ordinary edits or updates to the source cannot change later normal loading. User-owned read-only files
  are not OS-immutable against a malicious process of the same user.
- Managed script modules and native packaged libraries resolve only inside the snapshot. Uniterm's bundled runtime
  and standard library, and OS system libraries, are explicit platform exceptions. Runtime contract versions are part
  of approval semantics. Cwd searches, ambient module paths, startup hooks, and loader injection cannot select
  substitute dependencies. Reject conflicting explicit environment keys with an error. An entry whose dependency
  boundary cannot be established is refused persistent admission; there is no silent downgrade of its guarantee.
- Native entries start from the verified snapshot. Record the actual spawned executable's execution generation and
  code binding before granting authority. Janet's CLI remains the VM process: it owns stdin, stdout, stderr, working
  directory, arguments, signals, and exit status. Before user code runs, the app authenticates the bundle helper,
  independently verifies the artifact, and supplies its verified snapshot/run binding over the existing connection.
  The fixed helper loader evaluates only after admission and sandbox selection. No script output relay is added.
- A client-supplied digest or script path proves nothing. A foreign interpreter cannot borrow persistent script
  trust by claiming an approved artifact. The initial managed script loader is Janet. Other interpreters need an
  equally verifiable loader before receiving script-specific persistent trust. Generic peers retain explicit
  once/session admission without claiming such identity.
- Record artifact, entry, controller identity, approved scopes, peer execution generation, connection, source session,
  and current window/group. Execution generation includes successful exec, not merely PID and start time. Exit,
  executable replacement, disconnect, or revocation invalidates the live binding. It does not delete durable trust.
  Revalidate generation and revocation at dispatch, with exec/exit notifications for prompt invalidation.
- Unix-stream peer lookup is not immutable per-message sender attestation. Generation checks and notifications do
  not make check-and-effect atomic against exec or deliberately transferred sockets. Such races and injection remain
  within the stated same-user limitation. No atomic per-message or OS-sandbox guarantee is claimed.
- Verification identifies initial packaged execution, not arbitrary future behavior. Native dynamic loading or code
  interpreted from separately authorized filesystem/network input can exceed the initial artifact's contents.
  Managed import/image/native-module paths stay restricted; explicit runtime and OS privileges still permit a
  trusted program to interpret external input as code. Approval never asserts that future signed versions are benign.

Rationale: hashing an original path then reopening it leaves a replacement race. Trusting the helper alone fails to
identify its script. Verified snapshots and a fixed admission loader address ordinary substitution without changing
UTERM-003's CLI semantics. Moving every VM into the app would add relay and lifecycle obligations without a stronger
boundary under this threat model.

## Design Decisions (Open)

None.

## Risks

- **A process gains control of panes it should not** — likelihood: medium, impact: high.
  Mitigation: deny by default. Mark controlled panes visibly. Scope trust to the caller's subtree and window. Test
  denied cases. Revalidate live grants at effect dispatch and invalidate queued work on revoke.
- **The exec wire format becomes a contract external programs depend on** — likelihood: high, impact: medium.
  Mitigation: version the format from its first release.
- **Trust rules are too strict to be useful** — likelihood: medium, impact: medium.
  Mitigation: M4 exercises the presentation example through the real control transport and hosted slide, notes, and
  chart fixtures. Adjust any failure before M4 passes. Production applet support remains in each applet proposal.

- **Same-user processes can relay authority outside the pane model** — likelihood: medium, impact: high.
  Accepted: the control model is application authorization, not OS isolation. Descriptor transfer, terminal-device
  injection, or process injection can relay an authorized process's actions. No same-user security boundary is claimed.
  Mitigation within that boundary: no bearer-secret authority, live process checks, explicit target scope, visible
  owners, revocation, and separate local approval for host execution and controlled clipboard use.
- **The terminal backend identity extension changes with the Ghostty pin** — likelihood: medium, impact: medium.
  Mitigation: keep the narrow patch and its process-generation tests with the pin and cache identity. Unknown or
  unavailable identity denies automatic control and offers the explicit-grant path. No module bypasses TerminalSurface.
- **Applet and scripting designs are still in flight** — likelihood: medium, impact: medium.
  UTERM-003 is accepted but unimplemented. UTERM-005 through UTERM-010 may reshape their command schemas.
  Mitigation: use UTERM-003's single listener and references, validate shared contracts before M1, and keep each
  applet's schema and supported combinations in its proposal. M3-M4 use hosted fixtures, not assumed production APIs.
- **Saved intent or a downgrade is mistaken for live authority or a lossless restore** — likelihood: medium,
  impact: high. Mitigation: never put live grants, capabilities, or environment values in layouts. Store remembered
  controller approvals separately. Restore disconnected and bind live authority only after fresh admission and required
  local scope selection. Bump the envelope schema and preserve unknown applet bytes. Accepted:
  ADR-06's downgrade-then-upgrade layout loss remains; the kept-aside file permits manual recovery. Saved argv and
  directories remain private on disk, but can contain secrets, as terminal program declarations already can.
- **An explicitly approved program has the user's OS privileges** — likelihood: medium, impact: high.
  Accepted: exec programs and terminal programs are normal user programs, not sandboxed by pane authority. Local
  approval displays either immutable once-only inputs or the reusable authority ceiling and target scope. Runtime
  capabilities, control grants, and host execution approval remain separate. Mitigation: no implicit environment
  inheritance or host launch outside approved scope; no automatic retry; bounded protocol streams and asynchronous
  cleanup. The app cannot undo external side effects.

- **A remembered identity trusts future signed code** — likelihood: medium, impact: high.
  Accepted: identity trust deliberately delegates update continuity to the approved signing key and controller ID.
  A compromised key or malicious signed update can misuse already approved powers. Mitigation: offer exact-version
  trust, require review for broader permissions or a new key, show selectors in Controllers & Permissions, and revoke
  both active authority and remembered policy. No signature is presented as proof of harmless behavior.
- **Verification and actual loading diverge** — likelihood: medium, impact: high.
  Mitigation: verify the completed snapshot and actual run binding; use fixed packaged dependency resolution and
  explicit platform exceptions. M5 exercises source replacement, delayed imports, native libraries, helper identity,
  and executable generation changes. Accepted: OS/runtime privileges and deliberate same-user tampering exceed the
  initial packaged-code guarantee. Read-only snapshots are not an OS security boundary.
- **Policy or artifact formats gain a broader meaning in another version** — likelihood: medium, impact: high.
  Mitigation: version descriptor, admission, permission semantics, and policy storage. Unsupported meanings authorize
  nothing; corrupt/newer policy files remain recoverable. A downgrade never imports trust from layout state. Both
  controller/app protocol skew directions fail before effects. Compatible policy readers compare semantic scopes.
- **Permission requests become a source of interruption or misleading attribution** — likelihood: medium,
  impact: medium. Mitigation: one startup review, bounded host-owned pending UI, sticky denial, and no automatic modal
  flood. Typed controller clipboard access is attributable; OSC 52 remains honestly scoped to a terminal session.

## Milestones

### M1: Caller identity

**Status:** DONE

- uniterm identifies which window and pane a calling program runs in
- A call from outside any uniterm pane is rejected unless the user allows it
- TerminalSurface reports a real spawned process identity through a tested backend patch, never from caller claims
- PID reuse, a dead peer, inherited sockets after peer exit, ancestry loss, and closed source tabs grant no authority
- A stolen REPL environment token cannot bind a different process to that pane
- Live grants are scoped, revocable, and lost on reconnect; remembered policies require fresh verified admission
- Replacing or revoking a REPL helper invalidates its pending calls and grants
- REPL capability selection starts a fresh helper, warns about lost definitions, and restores no grants

**As built:**

- The Ghostty patch adds a `child_started` action that carries the PID of the child libghostty spawns.
  TerminalSurface reads the child's start time when the report arrives and reports both as
  `TerminalEvent.processStarted`. The fork has returned by then, so the read cannot miss a live child. A child that
  already exited gets no identity, so nothing binds to it. An earlier retry loop, left from diagnosing `proc_pidinfo`,
  was removed. In shell and program mode alike, the child is setuid-root `/usr/bin/login`, which becomes the session
  root. Two integration tests check that the reported PID is a direct child named `login` with the reported start
  time.
- Process records come from sysctl(KERN_PROC_PID), because `proc_pidinfo` refuses a root process. A PID that does not
  exist returns an empty record, and an exited process that its parent has not yet collected still has one. Both read
  as not running. The second was found and fixed in this milestone, with a regression test.
- Applets report each session's start and end to the window, the window set, and the script host. The script host
  alone keeps which pane each session root runs in. A closed window also tells the host, which forgets that window's
  roots and ends grants to its panes even when an applet never reported its end.
- Admission binds a connection to a recorded root through its peer's ancestry. Each call checks the peer's identity,
  the root's generation, and, for a binding found through ancestry, that the ancestry still leads to that root. A
  process whose parent exited loses its pane and asks like an outside program. A call that waits on a directory
  check is checked again after the wait and before the layout changes. An unbound call is refused, and the
  connection's request appears in the Pending Requests panel. A connection holds one request however many calls it makes. Requests are held per connection, and
  the listener holds at most 32 connections, so the list holds at most 32. A process that has exited cannot ask.
- The panel opens from Window > Pending Requests… and from the palette. It lists waiting requests and live grants. Its
  grant sheet names the program and its PID, offers only panes with a running session, and names each way the grant
  ends.
  The pending-permissions slot shows in every window while any request waits. An outside caller has no window, so the
  slot is not per window.
- A grant ends on disconnect, process exit, the source session's end, revocation, and window close. A program that
  forks and exits does not pass its grant to the child that keeps its socket. A grant needs a waiting request and an
  unbound connection, so a bound connection cannot be moved to another pane. Grant scope for panes with tabs, and the end of asking after a
  denial or revocation, are best guesses; see the 2026-11-10 Decision Log entry.
- A REPL helper that attaches before the terminal reports its session root waits for the root, and is then checked
  against it. A token presented from outside the channel's session is refused before or after the root arrives. The
  earlier draft refused every attach that arrived first, which would fail a REPL whose helper outran the report. A
  call made while the attach waits is refused without asking the user, and a completed attach drops any request the
  connection left.
- Ending a REPL channel unbinds its helper's connection, so a call the helper sent but the host had not read never
  runs. A restart ends the old session in the host, so the old helper's binding fails too.
- Restart REPL with Capabilities… is in the REPL menu while a helper runs. Its sheet warns that definitions are lost
  and offers every capability `--allow` can grant, none selected. The fresh helper gets a new channel and token and
  only the chosen `--allow` flags. It prints the capabilities it may use. An unknown name ends the helper before it
  connects. The capabilities are not saved, and a later restart or a restored pane starts with none.
- Package tests record the test process as a session root only through the ScriptTestSupport target, which the
  script host's tests and the REPL applet's tests share. Grant tests use a `sleep` process as the granted pane's
  session. The forked-and-exited and lost-ancestry cases use a small perl relay fixture, since a Swift test cannot
  fork. The process readers' tests sit in their own target beside the module. Two UI tests, for the panel and for the capability restart, compile and are run by the
  coordinator.

### M2: Remote-controlled and disconnected panes

**Status:** DONE

- The group node kind, open-pane's owned members, and layout envelope version 2 land here, ahead of M4's layout
  requests. Amended 2026-11-10; see Decision Log.
- A remote-controlled pane shows a visible marker
- Controlled clipboard policy covers background, newly opened, and reopened tabs before those sessions emit output
- New user panes start disconnected; enable and revoke remain accessible when applet content consumes input
- Clipboard policy is installed before a live mode transition enables remote ingress
- Disconnect rejects queued target calls; revoke also removes the controller's outgoing group authority
- A disconnected pane rejects ambient control calls while preserving its attached driver and host lifecycle events
- A program cannot control an ancestor or unrelated sibling; explicit owned group members remain eligible
- Nearest selection filters by authority first, uses tree distance and deterministic ties, and never creates on failure
- Each applet type's supported combinations are readable before a pane is created or a driver launches, and a type
  that declares none resolves to disconnected with no driver
- Controlled OSC 52 writes check once/session permission through real backend callbacks; denial changes nothing
- Pending clipboard approvals cannot release data or write after revocation, mode change, or session replacement

**As built:**

- The window holds each pane's access mode, keyed by pane ID, and issues it a new generation on every change. A pane
  with no entry is disconnected, so every new pane, and every pane reopened by undo, starts disconnected. The applet
  contract gained a hook that tells the applet its pane's control. The window calls it as the applet takes the pane,
  before it starts, and on every change. Enabling tells the applet first and records the mode after, with nothing
  suspended between.
- Enable Remote Control, Disconnect Pane, and Revoke Controller are pane commands in the File menu and the palette, with
  no key. They work while a sheet shows. There is no pane context menu, so the badge's own menu carries the same three
  actions. The badge is the `antenna.radiowaves.left.and.right` symbol in the pane's top right corner, since SF Symbols
  has no robot. It shows on a pane that is remote-controlled, owned, driven, in an unowned group, or restored with
  saved intent. Its tooltip and menu name the mode, the owner, every controller with authority over the pane, and the
  driver. The host reports each binding, grant, REPL attach, and end of one, and every window refreshes its badges.
  The menu also rebuilds from live state as it opens. Review found the badge's Revoke going stale while a controller
  bound by ancestry, and its test failed with the report's wiring removed.
- `AppletTypeDeclaration` carries the supported combinations. The terminal and the REPL declare remote control with no
  driver. Every other type declares nothing and resolves to disconnected. Open-pane checks the requested access against
  the kind's declaration before it checks the directory or builds anything.
- The group node never splices or collapses. Its content normalizes as a root, and members that are not panes of its
  content drop out. A group with no member dissolves into its parent. Tree distance counts split edges only, so a group
  is transparent. An owner's split extends the innermost group it owns that holds the target as source or member, and
  otherwise wraps the target in a new nested group.
- The layout envelope is version 2. The upgrade from version 1 keeps the windows list byte for byte. A group saves its
  source and members, never an owner. A pane saves its mode only when it is not disconnected. A damaged member list can
  only shrink a group, and a damaged or unknown mode reads as disconnected. A restored pane starts disconnected, and
  its badge shows the saved mode as inactive until the user acts on the pane.
- The host passes every call's caller, its connection and the pane it acts for, to the window layer. The window layer
  checks every target there, for lists, reads, and changes alike. A target out of scope answers as one that is not
  open. Revoke Controller ends every controller that acts from the pane or owns a group holding it. The host refuses
  the revoked connections' calls from then on, and every window releases their groups. A closed connection, an ended
  grant, a lost binding, and a closed source session release them too. The host API's rules, nearest targets, and the
  open-pane `:control` option are best guesses in the 2026-11-10 Decision Log entries. ScriptWire is at version 5.
- TerminalSurface takes a clipboard policy per session, at creation and on change. The write callback reads
  libghostty's confirm flag, so an OSC 52 write asks in a controlled session and a user's copy never asks. The prompt
  offers Deny, Allow Once, and a session button named for the tab. Session permission is kept per kind and ends with
  the policy. An answer counts only while the session is open and its policy is the one it was asked under. A session
  holds at most one waiting prompt per kind. A later read or write of that kind is denied at once and its text dropped,
  until M6's coalesced permission panel replaces this bound. Review found each OSC 52 write queuing its own sheet. The
  flood test saw 20 prompts for 20 writes before the bound, and 1 after. Both
  prompts now name the tab that asked, not the selected one. The window's and the terminal's naming tests failed with
  the fix reverted.
- Two new real-backend tests drive OSC 52 through libghostty's callbacks. With the policy check removed, the stale-answer
  test failed on both its read and its write. `PaneControlUITests` and the updated `ScriptRunUITests` and `ReplUITests`
  compile and are run by the coordinator. No layout codec fuzz target exists, so the codec changes have no fuzz run.

### M3: Exec panes

**Status:** NOT STARTED

- An exec pane starts a program and sends applet events to its stdin
- Hosted fixture applets receive validated commands and emit events through the applet contract's command and event
  hook, and an applet with no commands refuses every command
- Remote and exec commands share authorization, argument validation, and serialized dispatch
- Adding the remote applet-command call bumps UTERM-003's app-to-helper protocol version, so an old `uniterm` command
  with a new app, or the reverse, is refused at the handshake
- A remote caller, a Janet script through `uniterm/send-command` included, sends an applet command to an authorized
  target pane and receives its reply or structured error, with no effect on an error. A script gets the error as a
  Janet value, and the app never crashes
- A remote command naming an unsupported applet type or schema version is refused before any effect, for old and new
  callers alike
- A remote command to a disconnected pane is refused even while that pane's exec driver runs its own commands
- Authority is revalidated when the hook delivers a command, so a grant revoked after validation leaves no effect
- Events emitted with no exec driver attached reach no one and never grow a queue
- Terminal and REPL panes can still be made remote-controlled, and refuse every applet command
- The program's stdout drives the applet
- The program's stderr appears in the history as info, sanitized and coalesced, and takes no turn on the status bar. A
  driver exit or protocol failure is a typed warning or error, never a level guessed from stderr text. Amended
  2026-11-06; see Decision Log.
- Window shortcuts keep working while an exec driver is stalled
- Old/new protocol and applet schema mismatches in both directions execute no commands
- Stalled stdin, endless small stdout frames, malformed frames, and partial EOF stay bounded and fail visibly
- Child shutdown and stderr floods never block the UI
- Allow once binds immutable launch inputs; reusable grants enforce entry, directory, env-key, and live target scopes
- Varying arguments within an approved launch scope prompts nothing; a broader scope requires approval
- Scripts cannot approve their own permission requests or activate Run
- An exec child receives only the declared environment and documented base, in the declared or home directory
- Restored Run waits for required values and valid execution authority; layouts contain no environment values

### M4: Layout requests

**Status:** NOT STARTED

- Layout requests build on the group node kind and layout envelope version 2 from M2. Amended 2026-11-10; see Decision
  Log.
- A program can request a layout for its own subtree
- A request for panes outside its subtree is refused
- Publication rechecks grants after asynchronous preparation; revocation or source close leaves no partial layout
- Relaunch preserves group geometry and inert declarations while restoring no owner, grants, or automatic exec launch
- Undo assigns a new unowned pane identity even inside an existing group
- Malformed, duplicate, or cross-window saved membership cannot expand a grant
- Old layouts migrate without grants; older readers keep the newer envelope aside; unknown applet bytes round-trip
- The presentation example works end to end through real control transport with hosted slide, notes, and chart
  fixtures in separate panes; the test does not require implementing the production applet proposals

### M5: Verified controller artifacts and run binding

**Status:** NOT STARTED

- Binary and Janet controller fixtures verify descriptor, packaged entry, and dependencies before persistent admission
- Ordinary source replacement before, during, or after snapshot creation cannot substitute unverified packaged code
- Duplicate descriptor fields, path aliases, escapes, symlinks, missing files, and unlisted code fail closed
- Real native and Janet loaders reject ambient dependencies, delayed external imports, and startup injection paths
- Loader variables cannot execute substitute code before helper admission or silently override the declared boundary
- The bundle helper evaluates no user code before verified admission and sandbox selection
- The CLI retains its own stdin/stdout/stderr, signals, directory, and exit status without an app-side I/O relay
- An arbitrary interpreter claiming an approved script digest receives no persistent script authority
- PID reuse and successful exec invalidate live bindings; queued calls from the old generation have no authority
- Optional local signing works without an Apple developer certificate; bad signatures and changed keys do not reuse
  trust
- App, signer, and loader share deterministic descriptor interpretation and signature verification fixtures
- Original-path updates cannot alter the retained snapshot used by an admitted run

### M6: Consent, remembered trust, and permission management

**Status:** NOT STARTED

- Startup shows requested powers once, with Allow once, Session, Trust this version, and eligible Trust this identity
- Unchanged or narrower scoped requests reuse approval; new powers, wider scopes, or unsupported meanings do not
- Runtime argument/environment values vary within approved launch scopes without repeated prompts or saved secrets
- Typed controller clipboard reads and writes enforce separate grants at the actual access boundary
- Shared-terminal OSC 52 offers once/session permission without claiming persistent controller identity
- Coalesced requests never widen Allow once, and repeated or denied requests cannot create modal floods
- Controllers & Permissions shows version/key selectors, approved scopes, active runs, and usable revocation
- Revocation, disconnect, and session replacement invalidate queued clipboard access and staged host launches
- The separate policy file is private and atomic; corrupt or newer policy state grants nothing and stays recoverable
- Signing tooling creates optional local keys in Keychain; losing a key never silently substitutes another identity
- Old/new admission and typed clipboard versions refuse unsupported contracts in both directions before effects
- Remembered trust neither overrides disconnected existing panes nor adopts restored group members or activates Run

## Decision Log

- 2026-10-31: Drafted from the original write-up without an interview. The open questions hold everything undecided.
- 2026-10-31: This proposal defines the group node kind, at the user's request during the UTERM-001 review.
- 2026-11-01: Added context from UTERM-001's implementation to "What anchors trust" and "Saved layouts", and
  added "Clipboard access from controlled panes".
- 2026-11-02: Review start: 4 milestones, 5 settled decisions, 3 risks, no Live after lines or row gates,
  no explicit out-of-scope statements; at commit
  "Merge pull request #13 from space-armada/agent/cg-and-worktree-ignore".
  The user requested a full autonomous review and one commit at the end.
- 2026-11-02: Exec is an independent driver setting, combinable with remote-controlled or disconnected access.
  Converged in 1 pass (autonomous). Revised the settled three-level definition and M2's blanket rejection wording.
  Routed shared dispatch and host-shortcut checks to M2 and M3.
- 2026-11-02: Caller identity uses authenticated peer identity and live ancestry to a recorded session root, with
  explicit connection grants when unbound. Requires a narrow libghostty identity patch. Converged in 1 pass
  (autonomous). Routed backend identity and connection-lifecycle findings to M1.
- 2026-11-02: Fired UTERM-003's REPL-capability hook. User-selected grants require a fresh helper; host-side program
  launches need separate local approval. Converged in 1 pass (autonomous, addition). Routed approval binding and
  generation revocation to M1-M3. Added the mode-default question to finish the control boundary.
- 2026-11-02: Controlled clipboard reads and writes require local confirmation (autonomous, addition).
  Adds per-session terminal policy and restores OSC 52 write confirmation. Converged in 1 pass; M2 checks both paths.
- 2026-11-02: Exec uses versioned JSON lines with applet schemas, bounded pipes, and source-labelled stderr.
  Converged in 1 pass (autonomous). Routed skew, overload, and asynchronous cleanup checks to M3.
- 2026-11-02: Trust anchors to explicit membership in a nonmerging owner group. Converged in 1 pass (autonomous).
  Amended the settled tree-shape trust rule. Routed publication revalidation to M4.
- 2026-11-02: New user panes default disconnected; local chrome enables control and separately revokes a controller.
  Authorized new group panes may explicitly start remote-controlled. Converged in 1 pass (autonomous).
  Routed accessible enablement and policy-transition checks to M2. Added exec launch context for explicit state flow.
- 2026-11-02: Exec declares argv, directory, and environment explicitly, with home and a documented OS base as defaults.
  No app or neighbor inheritance; environment values are not saved. Converged in 1 pass (autonomous). Routed restore
  and launch-context checks to M3. Raised for the user per CLAUDE.md "Applet Attributes".
- 2026-11-02: Nearest means authorized tree-distance selection with deterministic ties; no match fails without
  creation. Converged in 1 pass (autonomous). Routed tree-distance behavior to M2.
- 2026-11-02: Save program layout intent but no live authority, capabilities, or environment values. Relaunch and undo
  require explicit regrant, and exec requires Run. Bump the envelope schema and retain ADR-06's downgrade behavior.
  Converged in 1 pass (autonomous). Routed restore and malformed-membership checks to M4.
- 2026-11-02: Risk review recorded same-user relay exposure, terminal backend patch maintenance, in-flight applet and
  scripting contracts, inert-restore/downgrade exposure, and approved programs' OS privileges (autonomous). Existing
  mitigations and explicit residual acceptances cover each; no high-likelihood/high-impact risk remains unmitigated.
- 2026-11-02: Clarified M4's end-to-end presentation check to use hosted slide, notes, and chart fixtures through the
  real transport, leaving production applets in their own proposals. This interpretation is for the user's review gate.
- 2026-11-02: Coherence review found no conflicting or weak decisions. Routed multi-tab clipboard policy to M2.
  Marked separate host-launch approval as an addition because it introduces a permission boundary for host execution.

- 2026-11-02: Whole-proposal review converged in 2 passes. No design questions or contested rulings remain. Across
  the review, 17 findings were routed to checks in M1-M4. No milestone, Live after line, or queue gate was added.
  Review size: 4 to 4 milestones, 5 to 15 settled decisions, and 3 to 8 risks. Clipboard policy, host-launch approval,
  exec state flow, and the M4 fixture interpretation remain for the user's gate.
- 2026-11-02: Review gate, partial: the user kept explicit exec launch context and defaults, and kept M4's hosted
  fixture end-to-end check. Clipboard confirmation and separate host-launch approval remain under discussion.
- 2026-11-02: The user found the permission boundaries sane but raised habituation from repeated dialogs. Reopened
  consent granularity for discussion; no replacement consent policy is chosen yet.
- 2026-11-02: The user confirmed that approval once at startup is the goal and asked how grants identify their
  requester. Requester identity and consent scope remain under discussion.
- 2026-11-02: Requester replacement discussion identified that process lifetime, executable lifetime, interpreter
  code identity, and terminal-session scope are distinct. macOS exposes exec notifications, but notification alone
  does not prove race-free per-request identity. No stronger requester-identity guarantee is settled yet.
- 2026-11-02: The user clarified that the goal is durable executable trust across sessions when requested grants
  remain the same. Earlier run-only recommendations misunderstood the requirement. Reopened persisted approval
  policy, executable recognition across updates, and permission comparison; live connections still need fresh binding.
- 2026-11-02: The user chose three consent durations: once, this session, and persistent controller trust. Required
  that users need not buy an Apple developer certificate. Asked how binary and script controller identities relate
  to signing; that mechanism remains open.
- 2026-11-02: The user approved the version-trust versus identity-trust distinction and requested its structure.
  Reviewed a common binary/script descriptor, optional local signing, durable permission policies, and fresh run
  binding. The critic ranked it first, with dependency coverage and execution binding still open. No detailed
  signing or packaging mechanism is settled. These additions follow the user's persistent-trust requirement.

- 2026-11-02: The user accepted the controller framework, four approval choices, packaged-code/dependency coverage,
  verified run binding, and Controllers & Permissions (addition). Persistent trust, optional local signing, and
  management UI are now approved scope. Detailed artifact loading and integration of permission scopes remain open.

- 2026-11-02: The user chose scoped powers over exact launch-input matching. Converged in 1 critic pass. Runtime
  arguments and values may vary within approved entry, directory, environment-key, and target scopes. Added typed
  controller clipboard requests (addition); shared-terminal OSC 52 retains once/session scope. Updated the previous
  per-operation consent, reconnect, launch, and restore wording to separate saved policy from live authority.

- 2026-11-02: The user chose verified snapshots while preserving the CLI-owned Janet VM. Converged in 1 critic pass.
  Added M5 for artifact verification, fixed loading, optional local signing, and actual run binding. The accepted
  threat model does not claim atomic Unix-stream sender attestation or same-user isolation.
- 2026-11-02: Added M6 for the user-approved consent framework, scoped powers, durable approvals, typed clipboard
  access, and Controllers & Permissions. M5-M6 implement approved additions, with no scheduling or deployment gate.
  Risk review added signed-update continuity, load divergence, policy semantics/skew, and prompt/attribution exposure.

- 2026-11-02: Final coherence review of the revised framework is SOUND in 1 full pass, with no new findings, dissent,
  or open questions. The user-resolved mechanism reviews each converged in 1 pass. Across the full review, 22 findings
  were routed to M1-M6 checks. Size against Review start: 4 to 6 milestones, 5 to 18 settled decisions, 3 to 12 risks.
  M5-M6 implement the user-approved durable-trust scope; no Live after line, queue row, or deployment gate was added.

- 2026-11-02: Review gate: the user kept the completed design with nothing reopened and accepted the proposal.
  Acceptance does not schedule M1-M6; the queue is unchanged.
- 2026-11-02: ADR candidate (cuts across the system): control authority requires an authenticated requester and
  explicit scope; reusable trust is verified afresh for each run and cannot silently widen permissions.
  Written as ADR-09 on 2026-11-02.
  This includes the user-approved durable-controller-trust addition. The invariant is settled and independent of
  package syntax, signing format, or applet-specific command schemas.

- 2026-11-02: The user selected ADR-09 and authorized including the required proposal-index update in the single
  final commit. ADR-09 records the authenticated-requester and explicit-scope invariant, including durable controller
  trust, after consulting the Architecture, Decision, and Record requirements.

- 2026-11-02: Final ADR review passed Architecture, Decision, and Record and found no unsupported clauses, format,
  or linking defects. It surfaced the permission and durable-trust additions becoming architectural rules; the user
  had explicitly approved those additions and selected the disclosed ADR candidate. Review complete: proposal and
  ADR-09 accepted, M1-M6 unscheduled, and the required index update included in the one final commit.


- 2026-11-03: Amended at the user's request during the UTERM-008 review. "Exec wire format" now names the applet
  contract's command and event hook and a remote host call, `uniterm/send-command`, that carries one applet command.
  The text before said only that exec and remote commands share dispatch and that remote host calls use the same
  validation; neither part was named or built by a milestone. Supported combinations are declared by every applet,
  apart from commands, and remote commands name the applet type and schema version they target. Added checks to M3,
  which builds the hook. The map's program-pin
  milestone depends on both. A re-check converged on the second pass. Moved the shared-dispatch check from M2 to M3,
  since exec drivers and the hook are built there. (addition: the command and event hook, a combination declaration on
  every applet type, and a host function in UTERM-003's module)
- 2026-11-03: ADR candidate (hard to reverse): every applet command, exec or remote, names its applet schema version,
  and an unsupported version is refused before any effect. Declined: the user judged it does not rise to an ADR.
- 2026-11-03: Scheduled as UTERM-004 M1-M6 in queue.md.
- 2026-11-06: Amended driver stderr and the pending-permission indicator (work-queue best guess). "Control modes" said
  stderr goes to the status bar, and its check said stderr appears there, with no level, no coalescing, and no word on
  failures. The permission indicator was "host-owned" with no named place. UTERM-017 settles that raw stderr is
  info-level text, bounded and coalesced before admission, and that host-observed failures are typed warnings or errors.
  It also gives the indicator a slot, the pending-permissions window state. The slot is built there, and this proposal
  fills it when its permission panel exists. The driver wire format does not change. UTERM-017 M2 later settled that
  stderr goes to the history only, with no turn on the bar, so a flood cannot bury a real notice. The text and check
  above were amended to match.
- 2026-11-07: Amended "Clipboard access from controlled panes" at the user's request, after the Ghostty 1.4.0 bump.
  The context said writes go through because the config sets `clipboard-write` to `allow`, and that a write prompt
  means restoring a removed write case. The surface bullet said both the confirm and write callbacks enforce policy and
  to restore the write request case. The bump sets `clipboard-write` to `ask` so that Kitty writes reach the confirm
  callback, which denies them. OSC 52 writes now arrive at the write callback with a confirm flag and are allowed
  there, so M2's write gate belongs in that callback. The earlier "Amended 2026-11-02" marker pointed at "Permission
  scopes and approval flow", which still holds the 2026-11-02 change. The decision itself does not change.
- 2026-11-10: Amended "How uniterm knows which pane a program runs in" during M1 implementation (work-queue best
  guess). The proposal said libghostty's public API exposes no PID. It does expose `ghostty_surface_foreground_pid`,
  but that is the pty's foreground process group, not the spawned child, so the backend patch is still needed. The
  patch adds a `child_started` action that reports the spawned child. The spawned child is setuid-root `/usr/bin/login`.
  `proc_pidinfo` refuses a root process for a non-root caller, so ProcessInspection uses sysctl(KERN_PROC_PID) instead
  to read kinfo_proc for start time and parent relationships, avoiding EPERM. The peer's uid comes from
  LOCAL_PEERCRED and its PID from LOCAL_PEERPID. The bullet keeps its generation, its typed identity event, and the
  rule that no other module reaches through the terminal boundary.
- 2026-11-10: Amended the grant bullet of "How uniterm knows which pane a program runs in" during M1 implementation
  (work-queue best guess). It said the user grants "a named source pane" and that a grant ends on revocation, and was
  silent on tabs and on asking again. A terminal pane with several tabs runs several sessions, and the script host
  knows panes, not tabs. A grant now binds to the newest session still running in the pane. A denied or revoked
  connection is not asked about again, so a program that keeps retrying cannot keep the panel full. It must reconnect
  to ask again. If the user wants a grant to name a tab, the grant sheet would list tabs and the host would track
  roots by tab. The Amended marker moved here from the backend-patch bullet, whose 2026-11-10 entry is above.

- 2026-11-10: Moved the group node kind into M2 (work-queue best guess). The proposal had M4 build groups with layout
  requests, and "Group node kind" said only a layout request makes one. M2's checks need owned members, and a live group
  must save, so M2 builds the group, open-pane's owned members, and layout envelope version 2. M4 keeps layout requests
  and the restore checks. A user split of a member puts the new pane inside the group's area, not among its members,
  and a group is removed once it has no member. The source pane is not a member. "What anchors trust" said "An empty
  group is removed and its ID retires." It now says a group left with no member is removed, and that the source is
  placement metadata. It said "User splits create panes outside the owned group boundary." It now adds that a user
  split of a member puts the new pane beside it, inside the group's area but not among its members. If the user wants
  user splits placed outside the group's area instead, a split of a member would split beside the whole group.
- 2026-11-10: Put UTERM-003's host API behind pane authority (work-queue best guess). The proposal settles the scope
  rules but not each call's answer. `list-windows` returns the caller's own window, with its pane and that pane's mode,
  and adds the title only once the pane is enabled. `list-panes`, reads, `send`, `open-tab`, and `open-pane` reach the
  caller's own remote-controlled pane and remote-controlled members of groups it owns. A target out of scope answers as
  one that is not open. A caller whose pane is disconnected and owns no group gets an error naming Enable Remote
  Control. One that owns a group keeps its members but cannot act on its own pane. `post-status` stays open to bound
  callers. Open-pane takes `:control :disconnected`, the default, or `:remote-controlled`. If the user wants another
  default, scripts that send to a pane they open would change.
- 2026-11-10: Named nearest targets `{:nearest kind}` in place of a pane reference (work-queue best guess). "Nearest"
  pane did not say how a script names one, or whether the caller's own pane counts. It counts. The form changes the
  wire, so ScriptWire went from version 4 to 5 here, and M3's bump becomes 6. The hello is one 16-bit version in every
  version, and each side refuses any version but its own before a call runs. An old `uniterm` command with a new app,
  and a new command with an old app, are both refused at the hello. No deploy order is needed. If the user wants
  a separate call, the wire would carry a new call code instead.
- 2026-11-10: Settled controlled-terminal clipboard details (work-queue best guess). The prompt offers Deny, Allow Once,
  and a button that allows reads, or writes, in the tab. Each kind's session permission ends with any policy change,
  including a new generation from a revoke. An unsafe paste keeps its own question. If the user wants a session
  permission to survive a revoke, the generation check would narrow to the mode. A session holds at most one waiting
  prompt per kind: a later read or write of that kind is denied at once, with no prompt, and its text dropped. That
  bounds the prompts "Permission scopes and approval flow" forbids flooding until M6's coalesced panel can replace it.

## References

- [ADR-09](../adr/ADR-09-control-authority-requires-authenticated-identity-and-explicit-scope.md): authenticated
  requester, explicit scope, and verified reuse of remembered approval

- [ADR-01](../adr/ADR-01-libghostty-behind-terminal-surface-protocol.md): terminal-engine boundary
- [ADR-02](../adr/ADR-02-pane-tree-nodes-have-stable-ids.md): stable node identities
- [ADR-03](../adr/ADR-03-restored-state-never-runs-a-program.md): inert restored state
- [ADR-04](../adr/ADR-04-uniterm-owns-key-bindings-and-terminal-config.md): window shortcut ownership
- [ADR-05](../adr/ADR-05-applet-lifecycle-events-and-applet-responses.md): applet lifecycle ownership
- [ADR-06](../adr/ADR-06-layout-file-versioning-and-schema-ownership.md): envelope and applet versioning
- [Apple's Unix socket definitions](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/un.h):
  peer identity
- [Apple's process identity structures](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h):
  parent and process-start identity fields
- [Apple's exec identity update](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exec.c):
  execution generation changes on exec
- [Apple's Unix socket peer lookup](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/uipc_usrreq.c):
  live peer lookup and its limits
- [Janet modules](https://janet-lang.org/docs/modules.html): source, image, and native module loading
- [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259): JSON syntax and UTF-8 interoperability

- Original write-up: `~/projects/private_specs/uniterm/spec/research/original-writeup.md`, CONTROL-1 to CONTROL-3
  and groups
