# Ideas

Future improvements worth keeping that are not proposals yet, plus unsettled
refinements to revisit through use. An idea leaves this file when a numbered
proposal covers it.

## OAuth2 support: access and refresh tokens

uniterm obtains, stores, and refreshes OAuth2 tokens. This is the most important
idea here, and none of it exists today. It needs the authorization-code flow with
PKCE, a way to receive the redirect, token storage in Keychain, refresh before and
after expiry, revocation or sign-out, and a place to configure providers. Still
open: what uses the tokens, such as the browser, Janet scripts, or terminal tools.

SSO belongs with this. Sites' own sign-in pages are a separate, smaller concern:
they run as ordinary pages and pop-ups in the browser, and none has been tried
against a real provider. Risks there, none tested in uniterm yet: providers that
reject embedded browsers, as Google does based partly on the user agent; WebKit's
block on third-party cookies, which can break SSO flows that use a hidden iframe;
and passkeys, which need Apple entitlements.

## Browser: microphone and camera support

The browser rejects every microphone and camera request, so video calls and
voice features do not work. Real support needs usage strings in the app, a
per-site question, and a recording indicator. The strings make WebKit expose the
native API and ask macOS before the browser's permission delegate, and the
stand-in `navigator.mediaDevices` script has to go. What a page sees after someone
answers the macOS prompt has not been measured.

## Browser: manage profiles

Add, list, and remove profiles, and switch between them. Every browser pane
shares one default profile today. The profile button's popover is the expected
home for these controls. A second profile needs its own website data store, and
its ID would flow through the pane's description.

## Browser: custom search engines

Let the user add a search engine of their own. The search engine setting offers
a fixed list today.

## Browser: history in the address bar

Suggest pages from the user's history while typing in the address bar. The
browser keeps no history across tabs today, only each tab's own back and
forward list.

## Browser: file upload pickers

Let a page's `<input type=file>` open a file picker. An upload input does
nothing today, so sites that take a file upload do not work.

## Browser: HTTP login dialogs

Ask for a username and password when a server requests HTTP authentication. The
browser answers no such request today, so a page behind a basic-auth login shows
the server's own 401.

## Browser: custom URL scheme

Let a scheme such as `corp://` serve pages through a `WKURLSchemeHandler`. This
is the least settled idea here, and no use for it is decided yet. A Janet script
is the most likely thing to serve it, which would make it wait on Janet
scripting. Still open: who defines a scheme, and what a scheme page can reach,
including whether ordinary web pages can link to it.

## Terminal: call out a bell

When a terminal rings its bell, call out its pane and its tab. A highlight is one
option, and the form is still open.

## Scripting: type text into a terminal pane or tab

Let a Janet script send literal text to a named terminal pane or tab as input to
the running program. This is separate from sending keystrokes: text supplies
characters, while a key can represent an action such as Enter or an arrow.
Still open: whether text uses paste semantics, including bracketed paste.

This would change UTERM-003's explicit decision that no host function writes to
terminal input. That change is welcome; the existing decision is not a reason
to rule the idea out. UTERM-004 preserves the restriction today, so a proposal
would revisit it there too and settle the required control and trust grants.

## Scripting: send keystrokes to a terminal pane or tab

Let a Janet script send keys and modifier combinations to a named terminal pane
or tab, including Enter, arrows, Escape, and Ctrl-C. This complements literal
text input for interacting with shells and terminal programs. Still open: how
keys are represented and translated for the terminal's current input mode.

This also changes UTERM-003's explicit decision against terminal input
injection, which is fine. A proposal would revisit UTERM-004's matching
restriction and settle authorization alongside text input.

## Scripting: read a terminal pane or tab's screen

Let a Janet script read the current terminal screen of a named pane or tab,
including a full-screen program's display. This means terminal contents rather
than a screenshot. Still open: plain text versus cells with attributes and
cursor position, and how the active screen differs from a viewport scrolled
back into history.

This extends UTERM-003's host API with terminal content access it does not
provide today. A proposal would settle the control and trust grants for reading.

## Scripting: read a terminal pane or tab's scrollback

Let a Janet script read retained scrollback from a named terminal pane or tab,
including output no longer on the current screen. This is separate from reading
the screen: history can be much larger and full-screen programs may use an
alternate screen without adding their display to scrollback. Still open: ranges,
size limits, and how callers handle history changing or being cleared.

This also extends UTERM-003's host API. A proposal would settle authorization
and the distinction between access to the current screen and retained history.

## Terminal: Kitty clipboard protocol

Support the Kitty clipboard protocol, OSC 5522, which libghostty handles from
Ghostty 1.4. uniterm denies its reads and writes today, and the program gets an
`EPERM` reply. A paste-event listing is the one part served now. When a program
turns on Kitty paste events, libghostty turns the user's own paste into a request
for the clipboard's type names, and uniterm answers it so the paste keeps working.

The protocol goes further than OSC 52 in several ways:

- A read or write can carry several MIME types, such as an image beside its text.
  uniterm reads and writes only plain text today.
- A request can name the primary selection. macOS has none, so uniterm reports it
  as unsupported.
- A program can name itself and ask to be remembered for the session. The
  permission prompt would show that name, and a remembered grant would skip later
  prompts.
- A write can be large. libghostty caps one write at 64 MiB by default.

UTERM-004's per-session clipboard policy and ADR-09's clipboard powers cover OSC
52 today. Support would need them to cover Kitty requests too.

## Screenshot of a pane or tab

Take a screenshot of the current browser tab, and of the current pane or tab of
any applet. Nothing here has been tried yet. The browser can use `takeSnapshot`,
though a full-length page needs more work. AppKit's view capture should cover
ordinary views, and will likely miss web, map, and Metal content. The terminal is
the open question: its Metal drawing needs a libghostty call, if one exists. A tab
that is not showing may have nothing current to capture.

Chosen so far. Each applet handles its own screenshots through an optional method
on the applet contract, since capturing the screen would need Screen Recording
permission. An applet with no method does not offer the command. AppKit capture is
a shared helper that an applet opts in to, never an automatic default, since it
would save a blank area for content it cannot see. A screenshot of a tab is just
the tab's content. A screenshot of a pane includes the pane's chrome, such as its
tab bar and toolbar, and leaves out the host's frame around the pane, such as the
focus border.

## Reorder tabs within a pane

Drag a tab to a new place in its own pane's tab bar. This covers one pane only.
Tabs cannot be reordered today. The gesture belongs in the shared `AppletTabBar`,
and each applet with tabs moves its own tab. The applet contract does not change.
Saving a layout already writes tabs in their current order. The selection is a
position, so a move has to keep the same tab selected.

Move Tab Left and Move Tab Right commands would give the palette a keyboard route.
They need no default shortcut. Tabs past the edge of a full bar are clipped, so a
drag cannot reach them.

## Move tabs between panes

Drag a live tab from one pane to another of the same type. The work starts with a
spike, then a proposal. The spike moves a live terminal surface and a live web
view between panes in one window, and watches for rendering, focus, and video
problems. Nothing has been tried yet, and only this could rule the idea out.

The proposal covers terminals first, since they hold far less state, then browsers
and any other applet with tabs. It changes the applet contract: a pane gives up a
tab and another adopts it. Rebuilding a tab from its description is no substitute,
since that kills the shell and reloads the page.

Still open for the proposal:

- Browser downloads, pending dialogs, and the script-opened tab limit belong to the
  pane. Opener links can end up pointing at a tab in another pane.
- Dragging a pane's last tab away should close the pane with no question and no
  undo entry. That path does not exist today.
- What undo means after a move.
- Moving between windows, since close stamps are per window.
- Control and trust in UTERM-004 depends on which pane a process runs in, so a move
  has to deal with existing grants.
- Browser profiles from the idea above fix a web view's data store at creation, so
  a live move between profiles has to be refused.

## Scriptable sidebar

A sidebar that scripts can program. It is a UI component, the way the palette and
the status bar are, and not a pane. Each window has at most one, and the user can
set it to the left or the right. This is not well fleshed out yet. It would come
after uniterm has proper scripting support.

The sidebars in the map viewer and the text viewer plans are a different thing:
each belongs to one applet and lives inside its pane.

## Automations scriptable from Bash

Let Bash scripts invoke automation operations and consume their results without
writing a Janet adapter. Launching an existing Janet file with arguments is
already possible, but does not provide a uniform command interface. Explore
direct CLI operations and explicit callable operations exposed by running Janet
scripts, controllers, or exec drivers. These are possible interfaces, not a
settled design. Structured input, output, errors, and exit statuses should make
the interface useful in shell workflows.

A design must assess compatibility with UTERM-004's security model rather than
assume a shell command inherits the automation's authority. Identify which parts
can use existing grants, which need new mechanisms, and which would require
explicit changes to settled decisions. The refinements below capture the open
questions.

## Refinements

Unsettled details to resolve as we gain user experience, try different use cases,
and iterate on future proposals. These are questions, not decisions or promises
of support. Record concrete examples and observations here as they arise. Move
a refinement into a proposal when it is ready for a decision, and link that
proposal from any related ideas that remain.

### Terminal scripting: permissions and target scope

The four terminal scripting ideas above need refinements to UTERM-004's control
and trust model. Its existing caller identity, explicit ownership, target access
mode, same-window scope, and revocation rules provide a starting point. Current
pane-control permission does not already authorize terminal input or content
access. Input support would explicitly revise UTERM-003's prohibition, which is
an acceptable change.

Questions to test against real workflows:

- Should typing text, sending keystrokes, reading the screen, and reading
  scrollback each require a separate declared power and approval?
- Should access to the caller's own terminal session differ from access to
  another session? How should this work for different tabs in the same pane?
- Are existing source-pane and owned-group scopes sufficient for useful
  automation? Which use cases need an explicit grant to an existing unrelated
  pane or tab, and how should the user select and revoke that grant?
- How should ordinary scripts, interactive REPL evaluations, and packaged
  controllers request these powers? Which approvals should last for an
  operation, a connection or run, a verified version, or a signing identity?
- What should pane chrome show when a program can read terminal contents or
  supply input? Is the current remote-control marker enough for users to
  understand the granted access?

### Terminal scripting: input and read behavior

The API behavior also needs experience from shell automation, interactive
programs, and full-screen applications:

- Should literal text use paste semantics, including bracketed paste? How does
  a caller deliberately submit a command or send a control key?
- How are keys and modifiers represented and translated for the terminal's
  current input mode?
- Does a screen read return plain text, cells and attributes, cursor position,
  or several representations? Does it read the active terminal screen or the
  user's currently scrolled viewport?
- How are scrollback ranges and size limits expressed? What happens when output
  arrives, history is trimmed, or the user clears history during a read?
- What ordering or snapshot guarantees let a script send input and then inspect
  the result? Which workflows need to wait for output or a screen change?

### Bash automation: caller identity and authority

The current model authenticates a live process and binds it to a source session.
A shell-facing interface introduces another caller when it invokes a running
automation. Design needs to establish whose authority each resulting operation
uses and prevent an approved controller from unintentionally lending its powers
to an unauthorized caller.

- How is a Bash caller authenticated and bound to its source pane or tab? How
  do calls from outside uniterm obtain an explicit source grant?
- Does an invocation use the caller's grants, the automation's grants, an
  intersection, or an explicit delegation? Which use cases require delegation,
  and how would its scope, lifetime, approval, and revocation work?
- What operations can an automation expose? How are arguments, target panes,
  and returned information constrained so a callable operation does not bypass
  pane ownership, disconnected mode, same-window scope, or separate powers?
- How do discovery and results avoid revealing unauthorized panes, terminal
  contents, or other private state? Permission to invoke an action may need to
  differ from permission to receive its output.
- How do remembered controller approvals apply to operations triggered by
  external callers? Trust in a verified controller must not silently become
  trust in arbitrary Bash code or mutable request contents.
- What happens to queued and in-flight requests when a caller disconnects, an
  automation restarts, a source session closes, or a grant is revoked?

Existing pane provenance and target checks may cover direct CLI operations.
Calling an already-running automation may need additional invocation or
delegation rules. Whether the current model is sufficient remains unsettled;
a proposal should name any gaps and proposed changes explicitly.

### Bash automation: interface and lifecycle

- Which workflows need direct pane commands, one-shot automation invocations,
  or calls into a long-running automation? Which need inline Janet or Janet
  source from stdin as a separate convenience?
- How does a caller identify a live automation and discover its supported,
  versioned operations without relying on focus or stale process identifiers?
- How are requests and replies encoded for pipelines? Settle stdout versus
  diagnostics, exit statuses, streaming, timeouts, and cancellation.
- Can callers retry safely after losing a reply? Which operations need request
  IDs or another way to avoid repeating an effect?
- How would external invocations coexist with an exec driver's app-owned
  stdin/stdout protocol? Attaching a driver alone does not provide an external
  command endpoint.
