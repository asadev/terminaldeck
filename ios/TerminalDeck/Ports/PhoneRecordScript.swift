/**
 * The click-flow recorder that runs **inside** the tunnelled page, as source text.
 *
 * The phone's version of `src/main/browser-record-preload.ts`, and it keeps that
 * file's two rules exactly:
 *
 *  - **report facts, decide nothing.** It produces the payload shape
 *    `Inspect.parseCapture` validates — `{v:1, path, text, attributes}` under a
 *    `target` key — because every judgement about that data (which selector wins,
 *    what may reach a terminal, what a password field is allowed to say) belongs
 *    on the Swift side, where it is tested against hostile input instead of hoped
 *    about;
 *  - **recording observes, it does not intervene.** The inspector swallows the
 *    events it sees, because a click on a link would navigate away from the
 *    element being inspected. The recorder is the opposite: the person is *using*
 *    the page, and a recorder that ate its own clicks would record a flow the
 *    page never performed. Every listener is capture-phase and passive, and
 *    nothing is re-dispatched.
 *
 * ## Why it is not folded into `InspectScript`
 *
 * They are two features that must be able to be on at different times, and one
 * of them cancels events while the other must not. The desktop keeps them in two
 * preloads for the same reason, and the two scripts there talk through the DOM
 * rather than through a shared scope — `document.querySelector('[data-terminal
 * deck-inspector]')` is how the recorder knows the inspector is swallowing a
 * click. That is copied here verbatim, so a tap made to *point at* something is
 * never also recorded as a click somebody made.
 *
 * ## Which world it runs in
 *
 * `WKContentWorld.defaultClient`, the same world `InspectScript` uses and for the
 * same reasons: the page can neither call `__terminaldeckRecord` nor reach
 * `webkit.messageHandlers`, because in the page's own world neither exists. The
 * Swift side still validates everything and still supplies the URL itself — a
 * door that cannot be opened is not a reason to stop checking who came through
 * it.
 *
 * ## The badge is not decoration
 *
 * *"A recorder that can be running without the user knowing is a surveillance
 * bug, not a feature."* That sentence is `browser-record-preload.ts`'s and it is
 * as true on a phone, where the page fills the screen and the app's own chrome is
 * a strip at the bottom that is easy to stop looking at. So the page carries the
 * same corner badge the machine's pages carry, re-asserted on every step rather
 * than only when recording starts — a framework that reconciles
 * `documentElement` would otherwise leave a recorder running with no visible
 * sign of itself.
 */

import Foundation

enum PhoneRecordScript {

    /// The name the page-side recorder posts to. Registered in the client world
    /// only, so it does not exist in the page's own world. A second handler
    /// beside `InspectScript.messageHandler` rather than one with a `kind` field:
    /// the two scripts have different lifetimes and the bridge switches on the
    /// name it was given.
    static let messageHandler = "terminaldeckRecord"

    /// The badge's dot, written out literally — the page is a different document
    /// and cannot read this app's colours. `Theme.accent`, the icon's own blue;
    /// if that changes, change this and `InspectScript.highlightBorder` together.
    private static let accent = "#3b8fee"

    /// Longest value carried out of a field. `MAX_VALUE` in
    /// `src/main/browser-record-preload.ts`; the Swift side clamps again.
    private static let maxValue = 200

    static let source = """
    'use strict';
    (function () {
      if (window.__terminaldeckRecord) return;

      var TEST_ATTRS = ['data-testid', 'data-test-id', 'data-test', 'data-qa', 'data-cy', 'data-automation-id'];
      var ATTR_KEYS = ['aria-label', 'alt', 'placeholder', 'title', 'role', 'type', 'name', 'href'];
      var NOTABLE_KEYS = ['Enter', 'Escape', 'Tab'];

      var MAX_DEPTH = 64;
      var MAX_TEXT = 300;
      var MAX_ATTR = 300;
      var MAX_IDENT = 200;
      var MAX_VALUE = \(maxValue);

      var BADGE_STYLE =
        'position:fixed;right:12px;bottom:12px;z-index:2147483647;pointer-events:none;' +
        'display:flex;align-items:center;gap:6px;padding:5px 9px;border-radius:6px;' +
        'font:600 11px/1.2 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;' +
        'letter-spacing:0.06em;background:Canvas;color:CanvasText;border:1px solid CanvasText;' +
        'box-shadow:0 1px 4px color-mix(in srgb, CanvasText 25%, transparent);';

      var active = false;
      var badge = null;

      function post(payload) {
        try {
          window.webkit.messageHandlers.\(messageHandler).postMessage(payload);
        } catch (err) {
          /* The handler is torn down with the view; a page mid-teardown must not throw. */
        }
      }

      function flatten(value, max) {
        if (typeof value !== 'string') return '';
        /* Cut first, collapse second. textContent on a real page is megabytes,
           and an unbounded collapse would hang the page on the very interaction
           being recorded. */
        var raw = value.length > max * 8 ? value.slice(0, max * 8) : value;
        var flat = raw.replace(/\\s+/g, ' ').trim();
        return flat.length > max ? flat.slice(0, max) : flat;
      }

      function printable(value) {
        return !/[\\u0000-\\u001f\\u007f]/.test(value);
      }

      function isUnique(selector) {
        try {
          return document.querySelectorAll(selector).length === 1;
        } catch (err) {
          return false;
        }
      }

      function cssStringOf(value) {
        return '"' + value.replace(/\\\\/g, '\\\\\\\\').replace(/"/g, '\\\\"') + '"';
      }

      function describe(el) {
        var d = { tag: typeof el.localName === 'string' ? el.localName : '' };

        var id = el.getAttribute('id');
        if (typeof id === 'string' && id !== '' && id.length <= MAX_IDENT && printable(id)) {
          d.id = id;
          d.idUnique = isUnique('#' + CSS.escape(id));
        }

        for (var i = 0; i < TEST_ATTRS.length; i++) {
          var name = TEST_ATTRS[i];
          var value = el.getAttribute(name);
          if (typeof value === 'string' && value !== '' && value.length <= MAX_IDENT && printable(value)) {
            d.testAttr = name;
            d.testValue = value;
            d.testUnique = isUnique('[' + name + '=' + cssStringOf(value) + ']');
            break;
          }
        }

        var count = 1;
        var index = 1;
        var parent = el.parentElement;
        if (parent) {
          var kids = parent.children;
          count = 0;
          for (var j = 0; j < kids.length; j++) {
            var kid = kids[j];
            /* :nth-of-type counts by element type, which is local name plus
               namespace — an <a> in SVG is not an <a> in HTML. */
            if (kid.localName === el.localName && kid.namespaceURI === el.namespaceURI) {
              count++;
              if (kid === el) index = count;
            }
          }
          if (count < 1) count = 1;
        }
        d.ofTypeCount = count;
        d.nthOfType = index;
        return d;
      }

      function isSecretField(el) {
        /* The property wins where it exists — a page can set input.type without
           touching the attribute — and the attribute covers the fake-DOM case.
           `file` belongs here with `password`: its value is a path on the user's
           own device, and it is the first thing a label falls back to. */
        var type = typeof el.type === 'string' && el.type !== '' ? el.type : el.getAttribute('type');
        if (typeof type !== 'string') return false;
        var kind = type.toLowerCase();
        return kind === 'password' || kind === 'file';
      }

      function attributesOf(el) {
        var out = {};
        for (var i = 0; i < ATTR_KEYS.length; i++) {
          var name = ATTR_KEYS[i];
          var value = el.getAttribute(name);
          if (typeof value === 'string' && value !== '') out[name] = flatten(value, MAX_ATTR);
        }
        /* What a control currently holds, which its attribute does not track.
           Never for a password or file field: that value would be shown in the
           step list and pasted into a prompt that is written to disk. */
        if (typeof el.value === 'string' && el.value !== '' && !isSecretField(el)) {
          out.value = flatten(el.value, MAX_ATTR);
        }
        return out;
      }

      /*
       * The text a person can actually read on this element.
       *
       * `innerText`, not `textContent`, and the difference is a bug he hit on
       * camera: textContent concatenates every descendant — including ones the
       * page has hidden — with no separator, so a wrapper around a collapsed
       * country picker came back as one unbroken word, the whole list of
       * countries run together, as the element's "text".
       *
       * Form controls report no text at all. A <select>'s is the concatenation of
       * its options and a <textarea>'s is whatever it was seeded with; neither
       * names the field, and `PhoneClickFlow.fieldLabel` names those from their
       * naming attributes instead.
       *
       * The size guard is not tidiness: innerText forces a layout pass and builds
       * the whole rendered string before anything can be sliced.
       */
      function visibleText(el) {
        var tag = typeof el.localName === 'string' ? el.localName : '';
        if (tag === 'select' || tag === 'textarea' || tag === 'input' || tag === 'option') return '';
        var raw = typeof el.textContent === 'string' ? el.textContent : '';
        if (raw.length <= 20000) {
          try {
            if (typeof el.innerText === 'string' && el.innerText !== '') raw = el.innerText;
          } catch (err) {
            /* A detached or exotic node can throw. textContent is already a true,
               if uglier, answer. */
          }
        }
        return flatten(raw, MAX_TEXT);
      }

      function describeElement(el) {
        var path = [];
        var node = el;
        var depth = 0;
        while (node && node.nodeType === 1 && depth < MAX_DEPTH) {
          path.push(describe(node));
          node = node.parentElement;
          depth++;
        }
        return { v: 1, path: path, text: visibleText(el), attributes: attributesOf(el) };
      }

      function ensureBadge() {
        /* isConnected, not a null check: a single-page app can replace the whole
           document, and a detached badge would silently stop being shown while
           recording carried on. */
        if (badge && badge.isConnected) return badge;
        var box = document.createElement('div');
        box.setAttribute('data-terminaldeck-recording', '');
        box.setAttribute('aria-hidden', 'true');
        box.style.cssText = BADGE_STYLE;
        var dot = document.createElement('span');
        dot.style.cssText = 'width:8px;height:8px;border-radius:50%;background:\(accent);';
        box.appendChild(dot);
        box.appendChild(document.createTextNode('RECORDING'));
        if (document.documentElement) document.documentElement.appendChild(box);
        badge = box;
        return box;
      }

      function removeBadge() {
        if (badge && badge.parentNode) badge.parentNode.removeChild(badge);
        badge = null;
      }

      function ours(el) {
        /* Our own badge, and the inspector's overlay, are not part of the page. */
        return !!(el.closest && el.closest('[data-terminaldeck-recording],[data-terminaldeck-inspector]'));
      }

      function inspecting() {
        /* The inspector swallows clicks so somebody can point at an element
           without driving the page. Those clicks are not part of any flow, and
           this overlay is the one signal both scripts can see: they share a DOM
           and not a scope. */
        return document.querySelector('[data-terminaldeck-inspector]') !== null;
      }

      function targetOf(event) {
        var el = event.target;
        if (!el || el.nodeType !== 1) return null;
        if (ours(el)) return null;
        return el;
      }

      function send(kind, el, extra) {
        /* Re-assert the badge on every step rather than only when recording
           starts: a page that removed our node — a framework reconciling
           documentElement, or a site doing it on purpose — would otherwise get a
           recorder with no visible sign of itself. The check is a cheap identity
           test on a node we already hold. */
        ensureBadge();
        var payload = { v: 1, kind: kind, target: describeElement(el) };
        if (extra) {
          for (var key in extra) {
            if (Object.prototype.hasOwnProperty.call(extra, key)) payload[key] = extra[key];
          }
        }
        post(payload);
      }

      function onClick(event) {
        if (inspecting()) return;
        var el = targetOf(event);
        if (!el) return;
        send('click', el);
      }

      function onChange(event) {
        if (inspecting()) return;
        var el = targetOf(event);
        if (!el) return;
        var tag = typeof el.localName === 'string' ? el.localName : '';
        if (tag !== 'input' && tag !== 'textarea' && tag !== 'select') return;

        var type = typeof el.type === 'string' ? el.type.toLowerCase() : '';
        if (type === 'password') {
          /* The step still exists — a replay has to know a password was entered
             — but the value never leaves the page. */
          send('type', el, { secret: true });
          return;
        }
        if (type === 'checkbox' || type === 'radio') {
          send('check', el, { checked: el.checked === true });
          return;
        }
        if (type === 'file') {
          /* File pickers cannot be replayed and the path is the user's disk. */
          send('type', el, { secret: true });
          return;
        }
        if (tag === 'select') {
          var option = el.options && el.selectedIndex >= 0 ? el.options[el.selectedIndex] : null;
          send('select', el, { value: flatten(option ? option.textContent : el.value, MAX_VALUE) });
          return;
        }
        send('type', el, { value: flatten(el.value, MAX_VALUE) });
      }

      function onKeyDown(event) {
        if (inspecting()) return;
        if (NOTABLE_KEYS.indexOf(event.key) === -1) return;
        var el = targetOf(event);
        if (!el) return;
        send('press', el, { key: event.key });
      }

      function onSubmit(event) {
        if (inspecting()) return;
        var el = targetOf(event);
        if (!el) return;
        send('submit', el);
      }

      /* Capture phase so a page that stops propagation on its own handlers
         cannot hide what the user did; passive so the recorder can never delay
         or cancel the interaction it is watching. */
      var EVENTS = [
        ['click', onClick],
        ['change', onChange],
        ['keydown', onKeyDown],
        ['submit', onSubmit]
      ];
      var OPTIONS = { capture: true, passive: true };

      window.__terminaldeckRecord = {
        enable: function () {
          if (active) {
            ensureBadge();
            return;
          }
          active = true;
          for (var i = 0; i < EVENTS.length; i++) {
            document.addEventListener(EVENTS[i][0], EVENTS[i][1], OPTIONS);
          }
          ensureBadge();
        },
        disable: function () {
          if (!active) return;
          active = false;
          for (var i = 0; i < EVENTS.length; i++) {
            document.removeEventListener(EVENTS[i][0], EVENTS[i][1], OPTIONS);
          }
          removeBadge();
        }
      };
    })();
    """
}
