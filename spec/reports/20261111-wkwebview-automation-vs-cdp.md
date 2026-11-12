# WKWebView automation compared with the Chrome DevTools Protocol

Written 2026-11-11. This note records a design discussion about letting scripts drive uniterm's browser applet. The
question was whether WebKit has an equivalent of Chrome's `--remote-debugging-port`, and if not, how much of the Chrome
DevTools Protocol (CDP) uniterm could build itself. CDP is the JSON protocol that Chrome exposes on that port. Tools
such as Puppeteer and the chrome-devtools MCP server speak it.

Every observation below came from one machine: macOS 26.6.2, build 25G83, with the system WebKit. The code citations
are from the uniterm working tree on the `agent/petunia` branch, as of 2026-11-11.

## Summary

WKWebView has no CDP and no debugging port. Most of what CDP is used for can still be built on public WebKit API. The
remaining gaps are engine-level: full network visibility and interception, the debugger and profilers, workers, and some
emulation. Private WebKit API exists on this machine that would likely close most of those gaps, chiefly by driving a
hidden Web Inspector frontend. That route is unproven and needs a spike.

The findings, by status:

| Finding | Status |
|---|---|
| No remote debugging port or CDP in Apple's WebKit | Confirmed from documentation knowledge. Not tested in this session |
| uniterm's browser applet is not inspectable today | Confirmed by code search |
| Public API covers navigation, lifecycle, dialogs, cookies, snapshots, script injection | Known from Apple's API. Not exercised in this session |
| Private classes and methods for an inspector bridge exist on macOS 26.6.2 | Confirmed by runtime probe. Behavior not tested |
| The inspector bridge can send protocol commands from the host | Hypothesis. Needs a spike |
| `_WKAutomationSession` and injected bundles are usable by uniterm | Hypothesis that they are not. Not tested |

## Context in the repo

The browser applet lives in `Packages/UnitermKit/Sources/BrowserApplet/`. The Markdown viewer in the text viewer applet
also uses WKWebView.

`UTERM-005` is the browser applet proposal, at `spec/proposals/UTERM-005-browser-applet.md`. Its milestone "M8: Remote
control" is not started. M8 gives controller scripts navigate, reload, back, forward, select, and read. It gates them
behind two permissions from `UTERM-004`, the control-and-trust proposal at
`spec/proposals/UTERM-004-control-and-trust.md`. The two permissions are browser navigation and browser read. M8 starts
after UTERM-004 M6, which builds consent and permission management.

Any work described here builds on UTERM-005 M8. It does not replace it.

## Findings

### Web Inspector is the only built-in debugging surface

Apple's WebKit offers Web Inspector through `WKWebView.isInspectable`, on macOS 13.3 and later. When a web view is
inspectable, Safari's Develop menu lists it under the Mac's name. Safari must have "Show features for web developers"
turned on in Settings, under Advanced. The connection runs over the `webinspectord` XPC service, not a socket. Only
Safari can act as the client.

Other routes look close but do not apply:

- `WEBKIT_INSPECTOR_SERVER=host:port` opens a remote inspector socket only in the Linux WebKit ports, GTK and WPE.
- `safaridriver` implements WebDriver for Safari itself. It cannot drive a WKWebView inside another app.
- Playwright's WebKit browser is its own patched WebKit build, not the system WKWebView.
- `ios-webkit-debug-proxy` works only for iOS devices.

### uniterm's web views are not inspectable today

Command, run from the repo root:

```sh
grep -rnE "isInspectable|WKWebView\(|developerExtras" App Packages/UnitermKit/Sources
```

Output:

```text
Packages/UnitermKit/Sources/TextViewerApplet/MarkdownView.swift:203:    webView.isInspectable = false
```

The Markdown viewer turns inspection off on purpose, at `Packages/UnitermKit/Sources/TextViewerApplet/MarkdownView.swift:203`.
The browser applet never sets `isInspectable`, so it keeps the default. For apps on macOS 13.3 and later the default is
off.

### Public WKWebView API

This inventory comes from Apple's public API. Nothing here was exercised in this session.

Navigation and lifecycle:

- `load(URLRequest)` carries custom headers, a method, and a body. They apply only to that one top-level request.
- `loadHTMLString`, `loadFileURL`, and `loadSimulatedRequest` cover the other ways to load content.
- `goBack`, `goForward`, `go(to:)` over `backForwardList`, `reload`, `reloadFromOrigin`, and `stopLoading`.
- Observable state: `url`, `title`, `isLoading`, `estimatedProgress`, `hasOnlySecureContent`, and `serverTrust`.
- `WKNavigationDelegate` allows, cancels, or downloads each navigation, including subframe navigations. It reports
  start, commit, finish, failure, server redirects, and web content process termination.
- Its authentication challenge callback covers HTTP auth and server trust. Accepting a bad certificate there matches
  CDP's `Security.setIgnoreCertificateErrors`.

Scripting:

- `callAsyncJavaScript(_:arguments:in:in:)` passes typed arguments, awaits promises, and targets a specific frame.
- `WKContentWorld` isolates host scripts from page scripts.
- `WKUserScript` injects at document start or end, in all frames including cross-origin frames. This matches CDP's
  `Page.addScriptToEvaluateOnNewDocument`.
- `WKScriptMessageHandlerWithReply` lets page scripts call into the host and get a reply.

Page operations:

- `takeSnapshot`, `createPDF`, `createWebArchiveData`, and print operations.
- `find(_:configuration:)`, `pageZoom`, `magnification`, `customUserAgent`, and `mediaType`, which can emulate `print`.
- The web view's `NSAppearance` drives `prefers-color-scheme`.
- `WKUIDelegate` handles `alert`, `confirm`, and `prompt`. This matches CDP's `Page.handleJavaScriptDialog`. It also
  handles pop-up windows, file pickers, and camera and microphone permission.
- Media control: pause all playback, set camera and microphone capture state, and query playback state.

Storage and network policy:

- `WKHTTPCookieStore` reads and writes every cookie, including HttpOnly cookies.
- `WKWebsiteDataStore` clears data by type and provides separate persistent profiles. On macOS 14 and later it also
  takes `proxyConfigurations`.
- `WKContentRuleList` blocks or upgrades requests by compiled, declarative rules. It cannot decide per request in code.
- `WKURLSchemeHandler` serves custom schemes only. It refuses `http` and `https`.
- `WKDownload` manages downloads.

### What page JavaScript can and cannot do

Page JavaScript has full DOM access. It can read and fill forms, scroll, read `localStorage` and IndexedDB, observe
mutations, and read Resource Timing entries.

Its limits:

- Events from `el.click()` or `dispatchEvent` have `isTrusted == false` and carry no user activation. Pop-ups, clipboard
  writes, fullscreen, file pickers, and autoplay with sound need user activation.
- The host can instead synthesize AppKit `NSEvent` mouse and key events into the web view. WebKit treats them as real
  input. This is the route to CDP's `Input.dispatchMouseEvent` and `Input.dispatchKeyEvent`. Coordinates must be mapped
  by the host.
- Capturing `console.*`, `fetch`, XHR, or WebSocket traffic means wrapping those functions in the page's own world. The
  page can detect the wrappers.
- Those wrappers see only requests made by page script. Requests from `<img>`, `<script>`, CSS, preloads, and service
  workers bypass them.
- Closed shadow roots are unreachable unless a document-start script hooks `attachShadow`.
- Web workers and service workers cannot be targeted from the host.

### CDP areas compared with public WebKit API

| CDP area | Buildable on public API |
|---|---|
| Page navigation, lifecycle events, reload, history | Yes |
| Runtime evaluation, inject on new document | Yes, with content worlds and frame targeting |
| Dialogs, pop-ups and new targets, downloads, permissions | Yes, through the delegates. The host models tabs |
| DOM query and edit, form filling | Yes, through JavaScript |
| Trusted input: clicks, typing, scrolling | Yes, through `NSEvent` synthesis into the view |
| Screenshot, PDF | Viewport snapshot and PDF, yes. A full-page screenshot probably needs scroll-and-stitch or PDF |
| Cookies, clearing storage, profiles | Yes |
| Emulation: user agent, print media, color scheme, viewport size, zoom | Yes |
| Emulation: geolocation, timezone, locale, touch, reduced motion, CPU throttling | No |
| Console and exceptions | Partly, through page-world hooks. Worker logs are missed |
| Network: every request and response with headers and bodies | No. This is the largest gap |
| Fetch: intercept, modify, or mock `http` and `https` requests | No |
| Network throttling, disabling the cache | No |
| CSS matched rules and style sources | Mostly no. `getComputedStyle` and same-origin stylesheets work |
| Debugger, Profiler, HeapProfiler, Tracing | No |
| Accessibility tree | Maybe, through the web view's NSAccessibility children. Unverified |

### Private WebKit API present on macOS 26.6.2

The probes below look up classes and selectors through the Objective-C runtime. They prove that a name exists. They do
not prove what it does, or that its signature matches the open-source WebKit headers.

Prerequisites: Xcode command-line tools with `swiftc`. The module cache flag keeps the build out of the system temp
directory, which uniterm's sandboxed agent sessions cannot write.

#### Probe 1: specific names

Source, saved as `probe.swift`:

```swift
import Foundation
import WebKit

let classes = [
  "_WKInspector", "_WKResourceLoadInfo", "_WKAutomationSession", "_WKProcessPoolConfiguration",
  "_WKInspectorExtension", "_WKRemoteObjectRegistry", "WKWebProcessPlugInController",
  "_WKWebsiteDataStoreConfiguration", "_WKInspectorConfiguration",
]

for name in classes {
  print("class \(name): \(NSClassFromString(name) != nil)")
}

let webViewSelectors = [
  "_inspector", "_setResourceLoadDelegate:", "_resourceLoadDelegate", "_setOverrideDeviceScaleFactor:",
  "_setRemoteInspectionEnabled:", "_evaluateJavaScriptWithoutUserGesture:completionHandler:",
  "_setTextZoomFactor:", "_isBeingInspected", "_inspectorAttachmentView",
]

for sel in webViewSelectors {
  print("WKWebView \(sel): \(WKWebView.instancesRespond(to: NSSelectorFromString(sel)))")
}

if let cls = NSClassFromString("_WKInspector") as? NSObject.Type {
  for sel in ["show", "showConsole", "showResources", "connect", "close", "inspectorWebView",
              "_webView", "webView", "showMainResourceForFrame:", "attach", "detach",
              "togglePageProfiling", "isProfilingPage", "setDelegate:", "extensionHost"] {
    print("_WKInspector \(sel): \(cls.instancesRespond(to: NSSelectorFromString(sel)))")
  }
}

if let cls = NSClassFromString("_WKProcessPoolConfiguration") as? NSObject.Type {
  for sel in ["setInjectedBundleURL:", "setTimeZoneOverride:", "timeZoneOverride"] {
    print("_WKProcessPoolConfiguration \(sel): \(cls.instancesRespond(to: NSSelectorFromString(sel)))")
  }
}

for sel in ["_setAutomationDelegate:", "_setAutomationSession:", "_setGeolocationProvider:"] {
  print("WKProcessPool \(sel): \(WKProcessPool.instancesRespond(to: NSSelectorFromString(sel)))")
}

for sel in ["_setOverrideLanguages:", "_setMediaCaptureEnabled:"] {
  print("WKWebViewConfiguration \(sel): \(WKWebViewConfiguration.instancesRespond(to: NSSelectorFromString(sel)))")
}
```

Command, run from the directory that holds the file:

```sh
swiftc -module-cache-path ./mc -o probe probe.swift
./probe
```

Output, minus a deprecation warning for `WKProcessPool`:

```text
class _WKInspector: true
class _WKResourceLoadInfo: true
class _WKAutomationSession: true
class _WKProcessPoolConfiguration: true
class _WKInspectorExtension: true
class _WKRemoteObjectRegistry: true
class WKWebProcessPlugInController: true
class _WKWebsiteDataStoreConfiguration: true
class _WKInspectorConfiguration: true
WKWebView _inspector: true
WKWebView _setResourceLoadDelegate:: true
WKWebView _resourceLoadDelegate: true
WKWebView _setOverrideDeviceScaleFactor:: true
WKWebView _setRemoteInspectionEnabled:: false
WKWebView _evaluateJavaScriptWithoutUserGesture:completionHandler:: true
WKWebView _setTextZoomFactor:: true
WKWebView _isBeingInspected: true
WKWebView _inspectorAttachmentView: true
_WKInspector show: true
_WKInspector showConsole: true
_WKInspector showResources: true
_WKInspector connect: true
_WKInspector close: true
_WKInspector inspectorWebView: true
_WKInspector _webView: false
_WKInspector webView: true
_WKInspector showMainResourceForFrame:: true
_WKInspector attach: true
_WKInspector detach: true
_WKInspector togglePageProfiling: true
_WKInspector isProfilingPage: true
_WKInspector setDelegate:: true
_WKInspector extensionHost: false
_WKProcessPoolConfiguration setInjectedBundleURL:: true
_WKProcessPoolConfiguration setTimeZoneOverride:: true
_WKProcessPoolConfiguration timeZoneOverride: true
WKProcessPool _setAutomationDelegate:: true
WKProcessPool _setAutomationSession:: true
WKProcessPool _setGeolocationProvider:: false
WKWebViewConfiguration _setOverrideLanguages:: false
WKWebViewConfiguration _setMediaCaptureEnabled:: true
```

#### Probe 2: method lists

Source, saved as `dump.swift`:

```swift
import Foundation
import ObjectiveC
import WebKit

func methods(_ cls: AnyClass) -> [String] {
  var count: UInt32 = 0
  guard let list = class_copyMethodList(cls, &count) else { return [] }
  defer { free(list) }
  return (0..<Int(count)).map { NSStringFromSelector(method_getName(list[$0])) }.sorted()
}

func protocolMethods(_ name: String) -> [String] {
  guard let proto = objc_getProtocol(name) else { return ["<no protocol \(name)>"] }
  var out: [String] = []
  for required in [true, false] {
    var count: UInt32 = 0
    if let list = protocol_copyMethodDescriptionList(proto, required, true, &count) {
      out += (0..<Int(count)).compactMap { list[$0].name.map(NSStringFromSelector) }
      free(list)
    }
  }
  return out.sorted()
}

print("== _WKInspector")
print(methods(NSClassFromString("_WKInspector")!).joined(separator: "\n"))

print("== WKWebView filtered")
let keys = ["nspect", "esource", "ime", "eolocation", "verride", "ser", "Network", "ache", "utomation", "ttach", "ocale", "anguage"]
print(methods(WKWebView.self).filter { m in keys.contains { m.contains($0) } }.joined(separator: "\n"))

print("== _WKResourceLoadDelegate")
print(protocolMethods("_WKResourceLoadDelegate").joined(separator: "\n"))

print("== _WKAutomationSession")
print(methods(NSClassFromString("_WKAutomationSession")!).joined(separator: "\n"))

print("== _WKInspectorDelegate")
print(protocolMethods("_WKInspectorDelegate").joined(separator: "\n"))
```

Command:

```sh
swiftc -module-cache-path ./mc -o dump dump.swift
./dump
```

The relevant slices of the output:

```text
== _WKInspector
_fetchURLForTesting:
_openURLExternallyForTesting:useFrontendAPI:
_setDiagnosticLoggingDelegate:
attach
close
connect
delegate
detach
extensionHostWebView
hide
inspectorWebView
isConnected
isElementSelectionActive
isFront
isProfilingPage
isVisible
navigateExtensionTabWithIdentifier:toURL:completionHandler:
printErrorToConsole:
registerExtensionWithID:extensionBundleIdentifier:displayName:completionHandler:
setDelegate:
show
showConsole
showExtensionTabWithIdentifier:completionHandler:
showMainResourceForFrame:
showResources
toggleElementSelection
togglePageProfiling
unregisterExtension:completionHandler:
webView
```

```text
== WKWebView filtered
_allowsRemoteInspection
_evaluateJavaScript:asAsyncFunction:withSourceURL:withArguments:forceUserGesture:inFrame:inWorld:completionHandler:
_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:
_evaluateJavaScriptWithoutUserGesture:completionHandler:
_getMainResourceDataWithCompletionHandler:
_horizontallyAttachedInspectorWebView
_inspector
_inspectorAttachmentView
_isBeingInspected
_overrideDeviceScaleFactor
_remoteInspectionNameOverride
_resourceLoadDelegate
_setAllowsRemoteInspection:
_setCustomUserAgent:
_setInspectorAttachmentView:
_setOverrideDeviceScaleFactor:
_setRemoteInspectionNameOverride:
_setResourceLoadDelegate:
```

```text
== _WKResourceLoadDelegate
<no protocol _WKResourceLoadDelegate>
```

```text
== _WKAutomationSession
configuration
delegate
init
initWithConfiguration:
isPaired
isPendingTermination
isSimulatingUserInteraction
markEventAsSynthesizedForAutomation:
sessionIdentifier
setDelegate:
setSessionIdentifier:
terminate
wasEventSynthesizedForAutomation:
```

```text
== _WKInspectorDelegate
<no protocol _WKInspectorDelegate>
```

The two protocol lookups return nothing. That is expected. The Objective-C runtime registers a protocol only when some
loaded code references it. A missing protocol at runtime does not mean WebKit dropped it.

### What the private names could close

| Gap | Private route | Certainty |
|---|---|---|
| Every request and response, with bodies | Web Inspector protocol `Network` domain, including `getResponseBody` | Hypothesis. Depends on the inspector bridge |
| Observing resource loads without bodies | `-[WKWebView _setResourceLoadDelegate:]`. Observes only. Cannot modify | Names confirmed. Behavior untested |
| Intercepting and mocking requests | Inspector protocol `Network` interception, which backs Safari's Local Overrides | Hypothesis |
| Throttling, disabling the cache | Inspector protocol `Network` commands | Hypothesis |
| Console and exceptions, including workers | Inspector protocol `Console`, `Runtime`, and `Worker` domains | Hypothesis |
| Debugger, profilers, heap, timeline | Inspector protocol `Debugger`, `ScriptProfiler`, `Heap`, and `Timeline` domains | Hypothesis |
| CSS matched rules | Inspector protocol `CSS` domain | Hypothesis |
| User activation for host scripts | `_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:` | Name confirmed. Behavior untested |
| Main resource bytes | `_getMainResourceDataWithCompletionHandler:` | Name confirmed. Behavior untested |
| Timezone override | `_WKProcessPoolConfiguration.timeZoneOverride` | Name confirmed. Behavior untested |
| Device scale override | `_setOverrideDeviceScaleFactor:` | Name confirmed. Behavior untested |
| Geolocation, locale | No direct name found. `_setGeolocationProvider:` and `_setOverrideLanguages:` are absent | Confirmed absent under those names |

The inspector bridge is the central idea. `-[WKWebView _inspector]` returns a `_WKInspector`. Its `inspectorWebView`
returns the Web Inspector frontend, which is itself a WKWebView in the host process. The frontend is JavaScript that
talks to the inspected page through WebKit's inspector protocol. If uniterm keeps the inspector hidden and injects a
bridge script into the frontend, the bridge could send protocol commands and receive protocol events. This depends on
the frontend's internal JavaScript objects, roughly `InspectorFrontendHost` and `InspectorBackend`. Those are less
stable than the Objective-C names. None of it was tried in this session.

Two other private routes probably will not work:

- `_WKAutomationSession` is the backend that `safaridriver` uses. `isPaired` suggests a session pairs through
  `webinspectord`. That service likely checks for an Apple-only entitlement.
- `setInjectedBundleURL:` would load a bundle into the web content process, where it could modify requests. That
  process is Apple-signed. Library validation likely refuses a third-party bundle.

Neither was tested.

## Failure modes of private API

When a private name changes, the failure shows up at a point that depends on how uniterm calls it:

- Compile time, almost never. Private API has no SDK headers. uniterm declares the interfaces itself, so the build does
  not depend on the installed WebKit. One exception: a direct reference to a private class symbol usually fails to link,
  because the SDK's WebKit stub does not export it. That error appears at build time.
- Launch time, only when linking against a private symbol that a later macOS removes. dyld then refuses to start the
  app. Dynamic lookup avoids this: `NSClassFromString`, `respondsToSelector:`, and `dlsym`.
- Runtime, for everything looked up dynamically. A missing method is safe when each call checks `respondsToSelector:`
  first. An unchecked call throws an unrecognized-selector exception, which crashes the app.

The dangerous case is a name that still exists with a changed signature or meaning. No name probe catches it. It shows up
as a crash or silent misbehavior the first time a script uses that path. The inspector protocol and the frontend's
JavaScript can change the same way, without notice. Apple ships WebKit with macOS, so uniterm cannot pin its version.

## Agreed design points

The discussion settled these:

- Every private call checks `respondsToSelector:`, or the equivalent class or symbol lookup, before calling. The cost
  is a cached method lookup and does not matter for uniterm.
- A private API failure at runtime reaches the script as an error returned to the caller. It never crashes uniterm.
- The scripting API has one function that returns the set of available capabilities as symbols. It covers both public
  and private paths. Public capabilities always report as available.
- A startup probe checks every private class, selector, and protocol domain, and records the result. Missing support
  shows up as a capability that is off, never as a crash.
- Name probes are fast, in milliseconds, so they may run with the normal unit tests.
- Behavioral smoke tests drive a real web view and take seconds. They run in a separate target, not on every test run.
  They should run on each new macOS beta and point release to catch signature and meaning changes.
- The work is phased. Public API comes first. Then a spike on the inspector bridge. Then console and exceptions,
  network observation, interception, and the rest of the private surface.
- The goal is to cover as much of the CDP comparison as possible, including console, exceptions, and network.
- uniterm will not ship on the App Store. Private API is acceptable on that ground.

## Proposal split

The agreed split is two proposals plus this note:

1. Proposal A: browser automation on public API. It depends on UTERM-005 M8. It holds the capabilities function and the
   "capability unavailable" error contract, JavaScript evaluation with frames and content worlds, lifecycle events,
   dialogs, cookies, snapshots and PDF, and trusted input. Its design depends on no unknowns, so it can be accepted
   without waiting for the spike.
2. Proposal B: the inspector bridge. Its first milestone is the spike. Later milestones cover the private API
   compatibility layer and smoke tests, console and exceptions, network observation, interception, and the remaining
   private capabilities. Its open questions stay open until the spike reports.

One proposal would hold the public work hostage to the spike. More than two would split B along seams the spike has not
shown yet.

## Open questions

- Can a script in the hidden inspector frontend send protocol commands and receive events? This is the spike's question.
- Does the inspector need to be visible, or attached to a window, to connect?
- Which new UTERM-004 permissions do these abilities need? At least running JavaScript, reading response bodies, and
  synthesizing input look like separate grants. Reading response bodies exposes data signed in as the user.
- Does a full-page screenshot need scroll-and-stitch, or does `takeSnapshot` with a large rect work?
- Is the web view's accessibility tree reachable through NSAccessibility from the host process?
- How does a script name a tab or a frame? UTERM-005 M8's tab ownership rules apply. Frames are new.
- Does a local proxy through `WKWebsiteDataStore.proxyConfigurations` still matter if the inspector bridge works? A
  proxy that reads HTTPS needs a uniterm CA that the user trusts.

## Status

This is analysis only. No source code changed. The note adds this file. The probe sources and binaries live outside the
repo, in the session's scratch directory. Their sources are reproduced above.

Next: draft proposal A and proposal B, each citing this note.
