/// The script that watches for edited form input. It runs in an isolated content world, in every
/// frame, so the page's own script can neither read it nor call the handler it reports to.
///
/// A trusted `input` event is the only thing that adds a field to the watched set. The page can
/// dispatch an `input` event of its own, and `isTrusted` is false on it. The script then re-reads
/// the watched fields' values against their defaults, so a field the user edits back to its
/// default stops counting.
///
/// The script posts only when the answer for its frame changes, and at most once per `gap`
/// milliseconds, so a page that flips a field's value in a loop costs a few posts, not one per
/// flip.
enum UnsentInputScript {
  /// The name the handler registers under, in the isolated world only.
  static let handlerName = "unsentInput"

  /// The most fields one frame watches.
  static let watchedLimit = 256

  /// The least time between two posts from one frame, in milliseconds.
  static let gap = 250

  static let source = """
    (function () {
      'use strict';

      var handler = window.webkit && window.webkit.messageHandlers
        && window.webkit.messageHandlers.\(handlerName);

      if (!handler) { return; }

      var bytes = new Uint8Array(16);
      crypto.getRandomValues(bytes);

      var frame = '';
      for (var i = 0; i < bytes.length; i++) {
        frame += (bytes[i] + 256).toString(16).slice(1);
      }

      var watched = new Set();
      var baselines = new WeakMap();
      var reported = false;
      var timer = 0;
      var lastPost = 0;

      function isField(element) {
        var name = element.localName;

        if (name === 'textarea' || name === 'select') { return true; }

        if (name !== 'input') { return false; }

        var type = element.type;

        return !(type === 'hidden' || type === 'submit' || type === 'button'
          || type === 'reset' || type === 'image' || type === 'file');
      }

      function editingHost(element) {
        if (!element.isContentEditable) { return null; }

        var host = element;

        while (host.parentElement && host.parentElement.isContentEditable) {
          host = host.parentElement;
        }

        return host;
      }

      function watchedElement(event) {
        var path = event.composedPath ? event.composedPath() : [];
        var target = path.length > 0 ? path[0] : event.target;

        if (!(target instanceof Element)) { return null; }

        if (isField(target)) { return target; }

        return editingHost(target);
      }

      function differs(element) {
        if (!element.isConnected) { return false; }

        var name = element.localName;

        if (name === 'textarea') { return element.value !== element.defaultValue; }

        if (name === 'select') {
          for (var i = 0; i < element.options.length; i++) {
            if (element.options[i].selected !== element.options[i].defaultSelected) {
              return true;
            }
          }

          return false;
        }

        if (name === 'input') {
          if (element.type === 'checkbox' || element.type === 'radio') {
            return element.checked !== element.defaultChecked;
          }

          return element.value !== element.defaultValue;
        }

        return baselines.has(element) && element.textContent !== baselines.get(element);
      }

      function isDirty() {
        var dirty = false;

        watched.forEach(function (element) {
          if (!element.isConnected) {
            watched.delete(element);
          } else if (differs(element)) {
            dirty = true;
          }
        });

        return dirty;
      }

      function flush() {
        timer = 0;

        var dirty = isDirty();

        if (dirty === reported) { return; }

        reported = dirty;
        lastPost = Date.now();
        handler.postMessage({ frame: frame, unsent: dirty });
      }

      function schedule() {
        if (timer) { return; }

        timer = setTimeout(flush, Math.max(0, \(gap) - (Date.now() - lastPost)));
      }

      function remember(event) {
        var host = editingHost(event.target instanceof Element ? event.target : document.body);

        if (host && !host.isConnected) { return; }

        if (host && !baselines.has(host)) { baselines.set(host, host.textContent); }
      }

      document.addEventListener('focusin', function (event) {
        if (event.isTrusted) { remember(event); }
      }, true);

      document.addEventListener('beforeinput', function (event) {
        if (event.isTrusted) { remember(event); }
      }, true);

      document.addEventListener('input', function (event) {
        if (!event.isTrusted) { return; }

        var element = watchedElement(event);

        if (element && (watched.has(element) || watched.size < \(watchedLimit))) {
          watched.add(element);
        }

        schedule();
      }, true);

      document.addEventListener('focusout', schedule, true);
      document.addEventListener('click', schedule, true);
      document.addEventListener('reset', schedule, true);

      document.addEventListener('submit', function (event) {
        if (!event.isTrusted) { return; }

        var form = event.target;

        if (form && form.elements) {
          for (var i = 0; i < form.elements.length; i++) { watched.delete(form.elements[i]); }
        }

        schedule();
      }, true);

      window.addEventListener('pagehide', function () {
        watched.clear();

        if (reported) {
          reported = false;
          handler.postMessage({ frame: frame, unsent: false });
        }
      }, true);
    })();
    """
}
