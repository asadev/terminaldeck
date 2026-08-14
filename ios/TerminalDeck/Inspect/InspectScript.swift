/**
 * The script that runs inside the tunnelled page, as source text.
 *
 * The phone's version of `src/main/browser-preload.ts` and
 * `src/main/browser-guest-dom.ts`, and it keeps their one rule: **report facts,
 * decide nothing**. It produces the exact payload shape `Inspect.parseCapture`
 * validates — `{v:1, path, text, attributes, depth, ancestors}` — because every
 * decision about that data (which selector wins, what may reach a terminal, what
 * a password field is allowed to say) belongs on the Swift side, where it is
 * tested against hostile input instead of hoped about.
 *
 * ## Which world it runs in, and why that is not cosmetic
 *
 * `WKContentWorld.defaultClient`, not the page's world. Two things follow, and
 * both matter more here than they do on the desktop, because the page on the far
 * end of the tunnel is somebody's dev server and its JavaScript is not ours:
 *
 *  - the page cannot see, call or replace `__terminaldeck`, so a site cannot turn
 *    inspection on for itself, feed the handler a payload naming a selector on a
 *    different site, or shadow `Element.prototype.getAttribute` under it;
 *  - the message handler is registered in that world too, so
 *    `window.webkit.messageHandlers.terminaldeckInspect` **does not exist** in
 *    the page's world at all. The desktop's equivalent runs in an isolated world
 *    with `ipcRenderer` exposed to it; this is the same shape with a narrower
 *    door.
 *
 * The Swift side still validates everything and still supplies the URL itself.
 * A door that cannot be opened is not a reason to stop checking who came through
 * it — that reasoning is how one changed line becomes a security bug.
 *
 * ## What a fingertip changes
 *
 * On the desktop `mouseover` highlights and `click` captures, so a wrapper caught
 * by mistake is corrected by moving the mouse two pixels. A phone has neither
 * gesture: there is no hover, and a tap lands wherever the topmost element
 * happens to be. So the tap does both jobs at once — highlight *and* capture —
 * and the correction is an explicit walk up the ancestor chain, driven from the
 * sheet by `step`. That is the whole reason `chain`, `depth` and `ancestors`
 * exist here and have no counterpart in the desktop's payload.
 *
 * ## Scrolling has to keep working
 *
 * Inspection must not also drive the page — a tap on a nav link would navigate
 * away from the thing being inspected — but it must not freeze it either, or
 * nothing below the fold can ever be inspected. So `click` is cancelled outright
 * and every other pointer event is only stopped from **propagating**: the page's
 * own handlers never see it, and the browser's native scrolling, which is not a
 * handler, is untouched.
 */

import Foundation

enum InspectScript {

    /// The name the page-side script posts to. Registered in the client world
    /// only, so it does not exist in the page's own world.
    static let messageHandler = "terminaldeckInspect"

    /**
     * The accent, written out literally.
     *
     * The page is a different document and cannot read this app's colours, so the
     * value has to travel. It is `Theme.accent` — `Color(red: 0.20, green: 0.62,
     * blue: 0.95)` — as hex; if that changes, change this too. There is no way to
     * share it.
     */
    private static let highlightBorder = "#339ef2"
    private static let highlightFill = "rgba(51, 158, 242, 0.16)"
    private static let capturedFill = "rgba(51, 158, 242, 0.34)"

    /// Everything the page-side half of inspect mode is.
    static let source = """
    'use strict';
    (function () {
      if (window.__terminaldeck) return;

      var TEST_ATTRS = ['data-testid', 'data-test-id', 'data-test', 'data-qa', 'data-cy', 'data-automation-id'];
      var ATTR_KEYS = ['aria-label', 'alt', 'placeholder', 'title', 'role', 'type', 'name', 'href'];

      var MAX_DEPTH = 64;
      var MAX_TEXT = 300;
      var MAX_ATTR = 300;
      var MAX_IDENT = 200;

      var BASE_STYLE =
        'position:fixed;top:0;left:0;width:0;height:0;margin:0;padding:0;' +
        'box-sizing:border-box;pointer-events:none;display:none;' +
        'z-index:2147483647;border:2px solid \(highlightBorder);border-radius:2px;' +
        'background:\(highlightFill);';
      var FILL_CAPTURED = '\(capturedFill)';

      var active = false;
      var overlay = null;
      /* The tapped element and every ancestor above it, so the sheet can walk up. */
      var chain = [];
      var depth = 0;
      var savedCursor = null;

      function post(payload) {
        try {
          window.webkit.messageHandlers.\(messageHandler).postMessage(payload);
        } catch (err) {
          /* The handler is torn down with the view; a page mid-teardown must not throw. */
        }
      }

      function flatten(value, max) {
        if (typeof value !== 'string') return '';
        /* Cut first, collapse second. textContent on a real page is megabytes —
           and tapping <body> asks for exactly that — so an unbounded collapse
           would hang the page on the very interaction being captured. */
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
           sheet and typed into a prompt that is written to disk. */
        if (typeof el.value === 'string' && el.value !== '' && !isSecretField(el)) {
          out.value = flatten(el.value, MAX_ATTR);
        }
        return out;
      }

      function ensureOverlay() {
        /* isConnected, not a null check: a single-page app can wipe the DOM out
           from under us, and a detached box would silently stop appearing. */
        if (overlay && overlay.isConnected) return overlay;
        var box = document.createElement('div');
        box.setAttribute('data-terminaldeck-inspector', '');
        box.style.cssText = BASE_STYLE;
        document.documentElement.appendChild(box);
        overlay = box;
        return box;
      }

      function place(el) {
        var box = ensureOverlay();
        var rect = el.getBoundingClientRect();
        box.style.transform = 'translate(' + Math.round(rect.left) + 'px,' + Math.round(rect.top) + 'px)';
        box.style.width = Math.max(0, Math.round(rect.width)) + 'px';
        box.style.height = Math.max(0, Math.round(rect.height)) + 'px';
        box.style.background = FILL_CAPTURED;
        box.style.display = 'block';
      }

      function hideOverlay() {
        if (overlay) overlay.style.display = 'none';
      }

      function removeOverlay() {
        if (overlay && overlay.parentNode) overlay.parentNode.removeChild(overlay);
        overlay = null;
      }

      function reposition() {
        var el = chain[depth];
        if (el && el.isConnected) place(el);
        else hideOverlay();
      }

      function report() {
        var el = chain[depth];
        if (!el) return;
        var path = [];
        for (var i = depth; i < chain.length && path.length < MAX_DEPTH; i++) {
          path.push(describe(chain[i]));
        }
        post({
          v: 1,
          path: path,
          text: flatten(el.textContent, MAX_TEXT),
          attributes: attributesOf(el),
          depth: depth,
          ancestors: Math.max(0, chain.length - 1 - depth)
        });
      }

      function buildChain(el) {
        var out = [];
        var node = el;
        var steps = 0;
        while (node && node.nodeType === 1 && steps < MAX_DEPTH) {
          out.push(node);
          node = node.parentElement;
          steps++;
        }
        return out;
      }

      function elementFrom(event) {
        var target = event.target;
        if (!target || target.nodeType !== 1) return null;
        if (overlay !== null && target === overlay) return null;
        return target;
      }

      function onTap(event) {
        var el = elementFrom(event);
        /* Cancelled outright: a tap on a link would navigate away from the very
           thing being inspected, and a tap on a submit button would post a form. */
        event.preventDefault();
        event.stopPropagation();
        if (typeof event.stopImmediatePropagation === 'function') event.stopImmediatePropagation();
        if (!el) return;
        chain = buildChain(el);
        depth = 0;
        if (chain.length === 0) return;
        place(chain[0]);
        report();
      }

      /* Propagation only. preventDefault here would take the page's scrolling
         with it, and a page that cannot be scrolled can only be inspected above
         the fold. */
      function muffle(event) {
        event.stopPropagation();
        if (typeof event.stopImmediatePropagation === 'function') event.stopImmediatePropagation();
      }

      var DOC_EVENTS = [
        ['click', onTap],
        ['pointerdown', muffle],
        ['pointerup', muffle],
        ['mousedown', muffle],
        ['mouseup', muffle],
        ['touchstart', muffle],
        ['touchend', muffle],
        ['dblclick', muffle],
        ['contextmenu', muffle]
      ];
      var WIN_EVENTS = [
        ['scroll', reposition],
        ['resize', reposition]
      ];

      function enable() {
        if (active) return;
        active = true;
        for (var i = 0; i < DOC_EVENTS.length; i++) {
          document.addEventListener(DOC_EVENTS[i][0], DOC_EVENTS[i][1], true);
        }
        for (var j = 0; j < WIN_EVENTS.length; j++) {
          /* Passive: these only move a box, and a non-passive scroll listener on
             a phone costs a frame of scrolling on every page. */
          window.addEventListener(WIN_EVENTS[j][0], WIN_EVENTS[j][1], { capture: true, passive: true });
        }
        var root = document.documentElement;
        /* Remembered rather than blanked, so turning inspection off cannot
           destroy a cursor the page set itself. Meaningless on a touchscreen and
           kept anyway: an iPad with a trackpad is the same code path. */
        savedCursor = root.style.cursor;
        root.style.cursor = 'crosshair';
        ensureOverlay();
      }

      function disable() {
        if (!active) return;
        active = false;
        chain = [];
        depth = 0;
        for (var i = 0; i < DOC_EVENTS.length; i++) {
          document.removeEventListener(DOC_EVENTS[i][0], DOC_EVENTS[i][1], true);
        }
        for (var j = 0; j < WIN_EVENTS.length; j++) {
          window.removeEventListener(WIN_EVENTS[j][0], WIN_EVENTS[j][1], { capture: true });
        }
        if (savedCursor !== null) document.documentElement.style.cursor = savedCursor;
        savedCursor = null;
        removeOverlay();
      }

      window.__terminaldeck = {
        enable: enable,
        disable: disable,
        /* Walk the ancestor chain. +1 is towards the document, -1 back towards
           the element the finger actually landed on. */
        step: function (delta) {
          if (chain.length === 0) return;
          var next = depth + delta;
          if (next < 0 || next >= chain.length) return;
          depth = next;
          place(chain[depth]);
          report();
        },
        clear: function () {
          chain = [];
          depth = 0;
          hideOverlay();
        }
      };
    })();
    """
}
