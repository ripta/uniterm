import WebKit

/// The script that gives a secure page a stand-in `navigator.mediaDevices`, whose requests for the
/// camera, the microphone, or the screen fail at once with `NotAllowedError`.
///
/// WebKit hides `mediaDevices` from an app with no camera or microphone usage strings, and uniterm
/// has none, so a site that does not check first hits a script error and shows nothing. Adding the
/// strings is not the way out: WebKit then asks macOS first, so a page could raise a system prompt
/// for capture the browser would deny. The stand-in lets a site show its ordinary "blocked" message,
/// and no page can reach a native call that would raise that prompt.
///
/// It runs in the page's own world, since the page must see it, at document start in every frame. A
/// pop-up's web view gets it with the rest of the configuration. An insecure page has no
/// `mediaDevices` on any browser, and the script leaves it without one. The script defines the
/// property in every host, so a host that has the native API, such as a test runner with usage
/// strings of its own, runs the same code as the app.
enum MediaCaptureScript {
  static let source = """
    (function () {
      'use strict';

      if (!window.isSecureContext) { return; }

      function denied() {
        return new DOMException('Permission denied by the browser', 'NotAllowedError');
      }

      var devices = new EventTarget();

      function define(name, value) {
        Object.defineProperty(devices, name, {
          value: value, configurable: true, writable: true, enumerable: true
        });
      }

      define('getUserMedia', function () { return Promise.reject(denied()); });
      define('getDisplayMedia', function () { return Promise.reject(denied()); });
      define('enumerateDevices', function () { return Promise.resolve([]); });
      define('getSupportedConstraints', function () { return {}; });
      define('ondevicechange', null);

      Object.defineProperty(navigator, 'mediaDevices', {
        value: devices, configurable: true, enumerable: true
      });
    })();
    """

  /// Adds the script to `controller`. Every web view has its own controller.
  @MainActor
  static func install(in controller: WKUserContentController) {
    controller.addUserScript(
      WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
  }
}
