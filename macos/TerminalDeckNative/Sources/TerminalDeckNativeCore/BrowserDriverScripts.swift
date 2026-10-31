import Foundation

/// The scripts the native driver runs in a page, in WebKit's isolated client
/// world (the page's own JavaScript cannot see or replace them). Ported from the
/// Electron driver's (`src/main/browser-drive-script.ts`) so both read a page the
/// same way, with one addition: every element the outline lists is stamped with
/// `data-td-ref="eN"`, and when no short, unique selector exists the outline
/// names it by that ref — which stays true for as long as the element lives.
public enum BrowserDriverScripts {
    public static let argsToken = "/*__DECK_ARGS__*/null"

    /// Which script this is (`outline`, `probe`, …) — each starts with `/*td:<name>*/`.
    public static func name(of script: String) -> String? {
        guard script.hasPrefix("/*td:"), let end = script.range(of: "*/") else { return nil }
        return String(script[script.index(script.startIndex, offsetBy: 5)..<end.lowerBound])
    }

    /// The arguments a script was given (the JSON in place of the token).
    public static func arguments(of script: String) -> [String: Any] {
        guard let start = script.range(of: "var args = ") else { return [:] }
        let rest = script[start.upperBound...]
        guard let end = rest.range(of: " || {};") else { return [:] }
        let json = String(rest[..<end.lowerBound])
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    /// The script with its arguments in place (JSON, line separators escaped).
    public static func with(_ script: String, args: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data("{}".utf8)
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return script.replacingOccurrences(of: argsToken, with: json)
    }

    static let preamble = #"""
    var D = Document.prototype, E = Element.prototype, H = HTMLElement.prototype;
    var qs = function (sel) { try { return D.querySelector.call(document, sel) } catch (e) { return null } };
    var qsa = function (sel) { try { return Array.prototype.slice.call(D.querySelectorAll.call(document, sel)) } catch (e) { return [] } };
    var attr = function (el, name) { try { var v = E.getAttribute.call(el, name); return typeof v === 'string' ? v : '' } catch (e) { return '' } };
    var box = function (el) { try { var r = E.getBoundingClientRect.call(el); return { x: r.x, y: r.y, width: r.width, height: r.height } } catch (e) { return null } };
    var text = function (el) {
      try {
        var t = typeof el.innerText === 'string' && el.innerText !== '' ? el.innerText : el.textContent;
        return typeof t === 'string' ? t.replace(/[ \t\u00a0]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim() : '';
      } catch (e) { return '' }
    };
    var line = function (el) { return text(el).replace(/\s+/g, ' ').trim() };
    var tagOf = function (el) { try { return String(el.localName || '').toLowerCase() } catch (e) { return '' } };
    var typeOf = function (el) { return attr(el, 'type').trim().toLowerCase() };
    var SECRET_AUTOCOMPLETE = /(current-password|new-password|one-time-code|cc-number|cc-csc)/i;
    var isSecret = function (el) {
      var t = typeOf(el);
      if (t === 'password' || t === 'file') return true;
      return SECRET_AUTOCOMPLETE.test(attr(el, 'autocomplete'));
    };
    var visible = function (el) {
      var r = box(el);
      if (!r || r.width <= 0 || r.height <= 0) return false;
      try {
        var s = window.getComputedStyle(el);
        if (s.visibility === 'hidden' || s.visibility === 'collapse' || s.display === 'none') return false;
        if (Number(s.opacity) === 0) return false;
      } catch (e) {}
      return true;
    };
    var enabled = function (el) {
      try {
        if (el.disabled === true) return false;
        if (attr(el, 'aria-disabled') === 'true') return false;
        if (typeof E.closest === 'function' && E.closest.call(el, '[disabled],fieldset[disabled]')) return false;
      } catch (e) {}
      return true;
    };
    var uniq = function (sel) { try { return D.querySelectorAll.call(document, sel).length === 1 } catch (e) { return false } };
    var cssEscape = function (v) {
      try { return window.CSS && typeof window.CSS.escape === 'function' ? window.CSS.escape(v) : v.replace(/[^a-zA-Z0-9_-]/g, '\\$&') }
      catch (e) { return v }
    };
    var quoted = function (v) { return '"' + v.replace(/["\\]/g, '\\$&') + '"' };
    var REF = 'data-td-ref';
    var refFor = function (el) {
      var have = attr(el, REF);
      if (have) return have;
      var next = (window.__tdRefSeq = (window.__tdRefSeq || 0) + 1);
      var made = 'e' + next;
      try { E.setAttribute.call(el, REF, made) } catch (e) {}
      return made;
    };
    var selectorFor = function (el) {
      var hooks = ['data-testid', 'data-test-id', 'data-test', 'data-cy'];
      for (var i = 0; i < hooks.length; i++) {
        var v = attr(el, hooks[i]);
        if (v) { var s = '[' + hooks[i] + '=' + quoted(v) + ']'; if (uniq(s)) return s }
      }
      var id = attr(el, 'id');
      if (id) { var s2 = '#' + cssEscape(id); if (uniq(s2)) return s2 }
      var name = attr(el, 'name');
      if (name) { var s3 = tagOf(el) + '[name=' + quoted(name) + ']'; if (uniq(s3)) return s3 }
      var aria = attr(el, 'aria-label');
      if (aria) { var s4 = tagOf(el) + '[aria-label=' + quoted(aria) + ']'; if (uniq(s4)) return s4 }
      return null;
    };
    var labelFor = function (el) {
      var t = tagOf(el);
      if (t === 'input' || t === 'textarea' || t === 'select') {
        var order = ['aria-label', 'placeholder', 'title', 'name'];
        for (var i = 0; i < order.length; i++) { var named = attr(el, order[i]); if (named) return named }
        var id = attr(el, 'id');
        if (id) { var lab = qs('label[for=' + quoted(id) + ']'); if (lab) { var written = line(lab); if (written) return written } }
        return '';
      }
      var own = line(el);
      if (own) return own.length > 150 ? own.slice(0, 150) : own;
      var rest = ['aria-label', 'title', 'alt'];
      for (var j = 0; j < rest.length; j++) { var other = attr(el, rest[j]); if (other) return other }
      return '';
    };
    """#

    /// The page: its words, and every element that can be acted on, each with a
    /// selector to name it and its ref.
    public static let outline = "/*td:outline*/(function () {\n" + preamble + #"""
    var args = /*__DECK_ARGS__*/null || {};
    var limit = typeof args.limit === 'number' ? args.limit : 60;
    var textLimit = typeof args.textLimit === 'number' ? args.textLimit : 4000;
    var sel = 'a[href],button,input,select,textarea,summary,[role="button"],[role="link"],[role="checkbox"],[role="tab"],[contenteditable="true"]';
    var out = [], seen = 0, all = qsa(sel);
    for (var i = 0; i < all.length && out.length < limit; i++) {
      var el = all[i];
      if (typeOf(el) === 'hidden') continue;
      if (!visible(el)) continue;
      seen++;
      var t = tagOf(el);
      var kind = t === 'a' ? 'link' : (t === 'input' || t === 'textarea' || t === 'select') ? 'field' : 'button';
      var ref = refFor(el);
      var entry = {
        kind: kind, tag: t, type: typeOf(el), label: labelFor(el),
        selector: selectorFor(el) || '[' + REF + '="' + ref + '"]',
        ref: ref, secret: isSecret(el), enabled: enabled(el)
      };
      if (kind === 'field' && !entry.secret) {
        try { entry.value = typeof el.value === 'string' ? el.value.slice(0, 120) : '' } catch (e) { entry.value = '' }
      }
      out.push(entry);
    }
    for (var k = i; k < all.length; k++) { if (typeOf(all[k]) !== 'hidden' && visible(all[k])) seen++ }
    var full = '';
    try { full = document.body && typeof document.body.innerText === 'string' ? document.body.innerText : '' } catch (e) {}
    full = full.replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
    return {
      url: String(location.href), title: String(document.title || ''),
      text: full.length > textLimit ? full.slice(0, textLimit) : full,
      textTruncated: full.length > textLimit,
      elements: out, matched: seen, truncated: seen > out.length
    };
    })()
    """#

    /// One element: is it there, where, can it be acted on, is it what a click would hit.
    public static let probe = "/*td:probe*/(function () {\n" + preamble + #"""
    var args = /*__DECK_ARGS__*/null || {};
    var sel = typeof args.selector === 'string' ? args.selector : '';
    var invalid = false;
    try { D.querySelectorAll.call(document, sel) } catch (e) { invalid = true }
    var nodes = invalid ? [] : qsa(sel);
    if (nodes.length === 0) return { found: false, count: 0, invalid: invalid };
    var el = nodes[0];
    var r = box(el), hit = false;
    if (r && r.width > 0 && r.height > 0) {
      try {
        var at = D.elementFromPoint.call(document, r.x + r.width / 2, r.y + r.height / 2);
        hit = at === el || (at !== null && (E.contains.call(el, at) || E.contains.call(at, el)));
      } catch (e) { hit = false }
    }
    var tg = tagOf(el);
    return {
      found: true, count: nodes.length, tag: tg, type: typeOf(el), label: labelFor(el),
      secret: isSecret(el), visible: visible(el), enabled: enabled(el),
      editable: tg === 'input' || tg === 'textarea' || attr(el, 'contenteditable') === 'true',
      checked: el.checked === true, rect: r, hit: hit,
      viewport: { width: window.innerWidth || 0, height: window.innerHeight || 0 },
      url: String(location.href)
    };
    })()
    """#

    public static let scrollIntoView = "/*td:scrollIntoView*/(function () {\n" + preamble + #"""
    var args = /*__DECK_ARGS__*/null || {};
    var el = qs(typeof args.selector === 'string' ? args.selector : '');
    if (!el) return { found: false };
    try { H.scrollIntoView.call(el, { block: 'center', inline: 'center', behavior: 'instant' }) }
    catch (e) { try { H.scrollIntoView.call(el, true) } catch (e2) {} }
    return { found: true, rect: box(el) };
    })()
    """#

    public static let text = "/*td:text*/(function () {\n" + preamble + #"""
    var args = /*__DECK_ARGS__*/null || {};
    var sel = typeof args.selector === 'string' && args.selector !== '' ? args.selector : null;
    var limit = typeof args.limit === 'number' ? args.limit : 4000;
    var el = sel === null ? document.body : qs(sel);
    if (!el) return { found: false, text: '' };
    if (isSecret(el)) return { found: true, secret: true, text: '' };
    var t = text(el);
    return { found: true, secret: false, text: t.slice(0, limit), truncated: t.length > limit,
             url: String(location.href), title: String(document.title || '') };
    })()
    """#

    public static let select = "/*td:select*/(function () {\n" + preamble + #"""
    var args = /*__DECK_ARGS__*/null || {};
    var el = qs(typeof args.selector === 'string' ? args.selector : '');
    if (!el) return { ok: false, reason: 'no element matched that selector' };
    if (tagOf(el) !== 'select') return { ok: false, reason: 'that element is not a dropdown' };
    var wanted = String(args.value == null ? '' : args.value);
    var options = Array.prototype.slice.call(el.options || []);
    var found = -1;
    for (var i = 0; i < options.length; i++) { if (String(options[i].value) === wanted) { found = i; break } }
    if (found === -1) { for (var j = 0; j < options.length; j++) { if (line(options[j]) === wanted) { found = j; break } } }
    if (found === -1) {
      var names = [];
      for (var k = 0; k < options.length && k < 20; k++) names.push(line(options[k]) || String(options[k].value));
      return { ok: false, reason: 'no such option. The ones there are: ' + names.join(', ') };
    }
    el.selectedIndex = found;
    try { el.dispatchEvent(new Event('input', { bubbles: true })) } catch (e) {}
    try { el.dispatchEvent(new Event('change', { bubbles: true })) } catch (e) {}
    return { ok: true, value: String(el.value) };
    })()
    """#

    /// Where the secret fields are, to paint them out of a screenshot.
    public static let secretRects = "/*td:secretRects*/(function () {\n" + preamble + #"""
    var out = [], all = qsa('input,textarea');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (!isSecret(el) || !visible(el)) continue;
      var r = box(el); if (r) out.push(r);
    }
    return { rects: out, viewport: { width: window.innerWidth || 0, height: window.innerHeight || 0 } };
    })()
    """#

    /// Focus a field and select what is in it, so typing replaces it.
    public static let focusAndSelect = "/*td:focusAndSelect*/(function () {\n" + preamble + #"""
    var args = /*__DECK_ARGS__*/null || {};
    var el = qs(typeof args.selector === 'string' ? args.selector : '');
    if (!el) return { ok: false };
    try { H.focus.call(el) } catch (e) {}
    try {
      if (typeof el.select === 'function') el.select();
      else if (attr(el, 'contenteditable') === 'true') {
        var range = document.createRange(); range.selectNodeContents(el);
        var s = window.getSelection(); s.removeAllRanges(); s.addRange(range);
      }
    } catch (e) {}
    return { ok: true, focused: document.activeElement === el };
    })()
    """#

    /// Only when the page is not on screen to take real input: a scripted click,
    /// typing that sets the value the way frameworks listen for, or a key.
    public static let scriptedInput = "/*td:scriptedInput*/(function () {\n" + preamble + #"""
    var args = /*__DECK_ARGS__*/null || {};
    var el = qs(typeof args.selector === 'string' ? args.selector : '');
    if (!el) return { ok: false, reason: 'no element matched that selector' };
    var fire = function (type, init) { try { el.dispatchEvent(new (init && init.key ? KeyboardEvent : MouseEvent)(type, Object.assign({ bubbles: true, cancelable: true, composed: true }, init || {}))) } catch (e) {} };
    if (args.action === 'click') {
      fire('mousedown'); fire('mouseup');
      try { H.click.call(el) } catch (e) { fire('click') }
      return { ok: true };
    }
    if (args.action === 'type') {
      try { H.focus.call(el) } catch (e) {}
      var v = String(args.value == null ? '' : args.value);
      if (attr(el, 'contenteditable') === 'true') { el.textContent = v }
      else {
        var proto = tagOf(el) === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        var setter = Object.getOwnPropertyDescriptor(proto, 'value');
        try { setter && setter.set ? setter.set.call(el, v) : (el.value = v) } catch (e) { el.value = v }
      }
      try { el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: v })) } catch (e) { fire('input') }
      try { el.dispatchEvent(new Event('change', { bubbles: true })) } catch (e) {}
      return { ok: true };
    }
    if (args.action === 'key') {
      try { H.focus.call(el) } catch (e) {}
      var key = String(args.key || 'Enter');
      fire('keydown', { key: key }); fire('keyup', { key: key });
      if (key === 'Enter' && el.form && typeof el.form.requestSubmit === 'function') { try { el.form.requestSubmit() } catch (e) {} }
      return { ok: true };
    }
    return { ok: false, reason: 'unknown action' };
    })()
    """#

    /// Annotate: what is under a point (fractions of the visible page), with its
    /// box in the page's own pixels and the viewport to scale it by.
    public static let pickAt = "/*td:pickAt*/(function () {\n" + preamble + #"""
    var args = /*__DECK_ARGS__*/null || {};
    var vw = window.innerWidth || 0, vh = window.innerHeight || 0;
    var el = null;
    try { el = D.elementFromPoint.call(document, (args.x || 0) * vw, (args.y || 0) * vh) } catch (e) {}
    var viewport = { width: vw, height: vh };
    if (!el || el === document.documentElement || el === document.body) return { found: false, viewport: viewport };
    var ref = refFor(el);
    return { found: true, tag: tagOf(el), label: labelFor(el), id: attr(el, 'id'),
             selector: selectorFor(el) || '[' + REF + '="' + ref + '"]', rect: box(el), viewport: viewport };
    })()
    """#

    /// The message handler Record posts to (in WebKit's isolated world only, so
    /// the page's own scripts cannot post fake steps).
    public static let recordHandler = "tdRecord"

    /// Record: installed in every page of a tab; it posts a step for each click,
    /// change, notable key and submit while `window.__tdRecording` is true. A
    /// password or file field is posted as secret, never with its value
    /// (the web recorder's `browser-record-preload.ts`).
    public static let recorder = "/*td:recorder*/(function () {\n" + preamble + #"""
    if (window.__tdRecorder) return;
    window.__tdRecorder = true;
    var NOTABLE = ['Enter', 'Escape', 'Tab'];
    var flat = function (v) { return String(v == null ? '' : v).replace(/\s+/g, ' ').trim().slice(0, 200) };
    var describe = function (el) {
      var ref = refFor(el);
      return { selector: selectorFor(el) || '[' + REF + '="' + ref + '"]', label: labelFor(el), tag: tagOf(el), type: typeOf(el) };
    };
    var post = function (kind, el, extra) {
      if (window.__tdRecording !== true) return;
      var payload = { v: 1, kind: kind, target: describe(el) };
      for (var k in (extra || {})) payload[k] = extra[k];
      try { window.webkit.messageHandlers.tdRecord.postMessage(payload) } catch (e) {}
    };
    var target = function (event) { var el = event.target; return el && el.nodeType === 1 ? el : null };
    document.addEventListener('click', function (event) { var el = target(event); if (el) post('click', el) }, { capture: true, passive: true });
    document.addEventListener('change', function (event) {
      var el = target(event); if (!el) return;
      var tag = tagOf(el), type = typeOf(el);
      if (tag !== 'input' && tag !== 'textarea' && tag !== 'select') return;
      if (type === 'password' || type === 'file' || isSecret(el)) { post('type', el, { secret: true }); return }
      if (type === 'checkbox' || type === 'radio') { post('check', el, { checked: el.checked === true }); return }
      if (tag === 'select') {
        var option = el.options && el.selectedIndex >= 0 ? el.options[el.selectedIndex] : null;
        post('select', el, { value: flat(option ? option.textContent : el.value) }); return;
      }
      post('type', el, { value: flat(el.value) });
    }, { capture: true, passive: true });
    document.addEventListener('keydown', function (event) {
      if (NOTABLE.indexOf(event.key) === -1) return;
      var el = target(event); if (el) post('press', el, { key: event.key });
    }, { capture: true, passive: true });
    document.addEventListener('submit', function (event) { var el = target(event); if (el) post('submit', el) }, { capture: true, passive: true });
    })()
    """#
}
