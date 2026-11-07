import WebKit

/// The script that makes a page's request for the camera, the microphone, or the screen fail at
/// once with `NotAllowedError`.
///
/// The UI delegate already denies every capture request, and that is the backstop. In practice the
/// delegate is never reached. On a real HTTPS page, `getUserMedia` returned a promise that never
/// settled: no error, no system prompt, no audio. Why WebKit stalls was not found. A page that
/// waits forever shows the user nothing, so the script rejects the call itself, and a site shows
/// its ordinary "blocked" message.
///
/// The script runs in the page's own world, since it must replace what the page calls. It runs at
/// document start in every frame, and a pop-up's web view gets it with the rest of the
/// configuration. It replaces a function only where WebKit exposes it. An insecure page has no
/// `navigator.mediaDevices`, and the script leaves it without one. Listing devices is untouched.
enum MediaCaptureScript {
  static let source = """
    (function () {
      'use strict';

      function denied() {
        return new DOMException('Permission denied by the browser', 'NotAllowedError');
      }

      function replace(target, name, replacement) {
        if (!target || typeof target[name] !== 'function') { return; }

        try {
          Object.defineProperty(target, name, {
            value: replacement, configurable: true, writable: true, enumerable: false
          });
        } catch (error) {}
      }

      var devices = navigator.mediaDevices;

      replace(devices, 'getUserMedia', function () { return Promise.reject(denied()); });
      replace(devices, 'getDisplayMedia', function () { return Promise.reject(denied()); });

      var legacy = function (constraints, success, failure) {
        if (typeof failure !== 'function') { return; }

        var error = denied();

        setTimeout(function () { failure(error); }, 0);
      };

      replace(navigator, 'getUserMedia', legacy);
      replace(navigator, 'webkitGetUserMedia', legacy);
    })();
    """

  /// Adds the script to `controller`. Every web view has its own controller.
  @MainActor
  static func install(in controller: WKUserContentController) {
    controller.addUserScript(
      WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
  }
}
