package dev.terminaldeck.android.ui

import android.os.Handler
import android.webkit.JavascriptInterface
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/**
 * The click-flow recorder that runs **inside** the tunnelled page, and the bridge that carries its
 * messages back to [PhoneClickFlow].
 *
 * A port of `ios/TerminalDeck/Ports/PhoneRecordScript.swift` — itself the phone's version of
 * `src/main/browser-record-preload.ts` — and it keeps that file's two rules exactly:
 *
 *  - **report facts, decide nothing.** It produces the payload shape [PhoneInspect.parseCapture]
 *    validates — a `path`, `text` and `attributes` under a `target` key — because every judgement about
 *    that data (which selector wins, what may reach a terminal, what a password field is allowed to
 *    say) belongs on the Kotlin side, where it is tested against hostile input rather than hoped about;
 *  - **recording observes, it does not intervene.** Every listener is capture-phase and passive, and
 *    nothing is re-dispatched — a recorder that ate its own clicks would record a flow the page never
 *    performed.
 *
 * ## The one honest difference from iOS: no world isolation
 *
 * On iOS the script runs in `WKContentWorld.defaultClient`, invisible to the page. Android's WebView
 * has no such second world: [android.webkit.WebView.addJavascriptInterface] exposes the bridge to the
 * page's own scripts, and the injected `window.__terminaldeckRecord` is visible too. This is safe for
 * the same reason iOS is safe even though *its* message handler is reachable — **every payload is
 * re-validated on the Kotlin side and the URL is supplied by the app, never the page** — so the worst
 * a hostile page can do is inject a fake step into a recording the person themselves started. The badge
 * below is the visible sign that a recording is running, re-asserted on every step.
 *
 * ## Written without a single backslash on purpose
 *
 * The desktop and iOS versions use regex escapes (`\s`, `\uXXXX`) and CSS-string escaping. Here the
 * whitespace collapse is a `charCodeAt` loop over the exact same code points [PhoneInspect] treats as
 * whitespace, and the CSS string is built with `String.fromCharCode` — so the source carries no
 * backslash a build step or a transport could quietly eat, and the two whitespace sets cannot drift.
 *
 * ## The badge is not decoration
 *
 * *"A recorder that can be running without the user knowing is a surveillance bug, not a feature."*
 * The page fills the screen and the app's chrome is a strip at the bottom, so the page carries a corner
 * badge, re-asserted on every step rather than only when recording starts.
 */
object PhoneRecordScript {

    /** The name the page-side recorder posts through — the Android JS interface registered on the web
     *  view. Guessable is harmless here: the Kotlin side validates every payload. */
    const val BRIDGE = "__terminaldeckRecordBridge"

    /** Turn the recorder on for the page loaded now. Injected after the script is present. */
    const val ENABLE = "window.__terminaldeckRecord && window.__terminaldeckRecord.enable()"

    /** Turn it off, and take the badge down with it. */
    const val DISABLE = "window.__terminaldeckRecord && window.__terminaldeckRecord.disable()"

    /**
     * The page-side recorder, as source text. Defines the hook and its listeners; nothing is recorded
     * until [ENABLE] is evaluated against it, and the guard at the top makes re-injection a no-op.
     */
    val source = """
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
      var MAX_VALUE = 200;

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
          window.__terminaldeckRecordBridge.post(JSON.stringify(payload));
        } catch (err) {
          /* The bridge is torn down with the view; a page mid-teardown must not throw. */
        }
      }

      function isWs(c) {
        return c === 32 || (c >= 9 && c <= 13) || c === 160 || c === 5760 ||
          (c >= 8192 && c <= 8202) || c === 8232 || c === 8233 || c === 8239 ||
          c === 8287 || c === 12288 || c === 65279;
      }

      /* value.replace(/\s+/g, ' ').trim(), over the set above and without a regex. */
      function collapseWs(s) {
        var out = '';
        var pending = false;
        for (var i = 0; i < s.length; i++) {
          if (isWs(s.charCodeAt(i))) {
            pending = out.length > 0;
            continue;
          }
          if (pending) { out += ' '; pending = false; }
          out += s[i];
        }
        return out;
      }

      function flatten(value, max) {
        if (typeof value !== 'string') return '';
        var raw = value.length > max * 8 ? value.slice(0, max * 8) : value;
        var flat = collapseWs(raw);
        return flat.length > max ? flat.slice(0, max) : flat;
      }

      /* No C0 control or DEL — the Kotlin side's isPrintable, as a loop. */
      function printable(value) {
        for (var i = 0; i < value.length; i++) {
          var c = value.charCodeAt(i);
          if (c <= 31 || c === 127) return false;
        }
        return true;
      }

      function isUnique(selector) {
        try {
          return document.querySelectorAll(selector).length === 1;
        } catch (err) {
          return false;
        }
      }

      /* A CSS string literal, backslash-escaped, built without writing a backslash. */
      function cssStringOf(value) {
        var bs = String.fromCharCode(92);
        var q = String.fromCharCode(34);
        var out = q;
        for (var i = 0; i < value.length; i++) {
          var ch = value.charAt(i);
          if (ch === bs || ch === q) out += bs;
          out += ch;
        }
        return out + q;
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
        if (typeof el.value === 'string' && el.value !== '' && !isSecretField(el)) {
          out.value = flatten(el.value, MAX_ATTR);
        }
        return out;
      }

      function visibleText(el) {
        var tag = typeof el.localName === 'string' ? el.localName : '';
        if (tag === 'select' || tag === 'textarea' || tag === 'input' || tag === 'option') return '';
        var raw = typeof el.textContent === 'string' ? el.textContent : '';
        if (raw.length <= 20000) {
          try {
            if (typeof el.innerText === 'string' && el.innerText !== '') raw = el.innerText;
          } catch (err) {
            /* A detached or exotic node can throw. textContent is already a true answer. */
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
        if (badge && badge.isConnected) return badge;
        var box = document.createElement('div');
        box.setAttribute('data-terminaldeck-recording', '');
        box.setAttribute('aria-hidden', 'true');
        box.style.cssText = BADGE_STYLE;
        var dot = document.createElement('span');
        dot.style.cssText = 'width:8px;height:8px;border-radius:50%;background:#3b8fee;';
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
        return !!(el.closest && el.closest('[data-terminaldeck-recording],[data-terminaldeck-inspector]'));
      }

      function inspecting() {
        return document.querySelector('[data-terminaldeck-inspector]') !== null;
      }

      function targetOf(event) {
        var el = event.target;
        if (!el || el.nodeType !== 1) return null;
        if (ours(el)) return null;
        return el;
      }

      function send(kind, el, extra) {
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
          send('type', el, { secret: true });
          return;
        }
        if (type === 'checkbox' || type === 'radio') {
          send('check', el, { checked: el.checked === true });
          return;
        }
        if (type === 'file') {
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
    """.trimIndent()

    /* -------------------------------------------------------------------- parsing -- */

    /** One page payload, JSON → a plain map/list tree the pure engine can validate. Null when the
     *  string is not the object the recorder posts. */
    fun parse(json: String): Map<String, Any?>? = try {
        toMap(JSONObject(json))
    } catch (e: JSONException) {
        null
    }

    private fun toMap(obj: JSONObject): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            out[key] = normalize(obj.get(key))
        }
        return out
    }

    private fun normalize(value: Any?): Any? = when (value) {
        is JSONObject -> toMap(value)
        is JSONArray -> (0 until value.length()).map { normalize(value.get(it)) }
        JSONObject.NULL -> null
        else -> value
    }
}

/**
 * The Android JS interface the page-side recorder posts through.
 *
 * Its one method runs on a WebView binder thread, so it marshals to [main] before touching the store —
 * [PhoneClickFlow] and the Compose state it drives are single-threaded. [pageUrl] is set by the screen
 * from the web view's own address, never read from the payload, so a page cannot name a site it is not
 * on. Registered under [PhoneRecordScript.BRIDGE].
 */
class PhoneRecordBridge(
    private val main: Handler,
    private val flow: PhoneClickFlow,
    private val tab: String,
    private val onChanged: () -> Unit,
) {
    /** The web view's own address, as the screen last saw it. Volatile because it is written on the
     *  main thread and read on the binder thread. */
    @Volatile
    var pageUrl: String = ""

    @JavascriptInterface
    fun post(json: String) {
        val payload = PhoneRecordScript.parse(json) ?: return
        val url = pageUrl
        main.post {
            flow.note(payload, url, tab)
            onChanged()
        }
    }
}
