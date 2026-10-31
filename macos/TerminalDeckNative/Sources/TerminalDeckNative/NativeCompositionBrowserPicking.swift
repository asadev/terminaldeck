import Foundation
import WebKit
import TerminalDeckNativeCore

/// The closed source PICK_SCRIPT and PREAMBLE from browser-drive-script.ts.
/// Native arguments are values, never source text. Document CSS coordinates
/// use the page's live scroll; picking never scrolls/reveals the page or reads
/// an input's value. Native annotation converts its frozen-image point first.
@MainActor
enum NativeCompositionBrowserPicking {
    static func run(_ view: WKWebView, x: Double, y: Double, up: Double) async throws -> NativeRPCValue {
        guard x.isFinite, y.isFinite else { throw NativeRPCError.invalidArguments("Picking needs a finite document point.") }
        let climbed = up.isFinite && up > 0 ? min(64, up.rounded(.down)) : 0
        let raw = try await view.callAsyncJavaScript(script, arguments: ["pointX": x, "pointY": y, "ancestorSteps": climbed], in: nil, contentWorld: .defaultClient)
        return clean(try NativeRPCValue.fromFoundation(raw))
    }
    static func geometry(_ view: WKWebView) async throws -> NativeRPCValue {
        let raw = try await view.callAsyncJavaScript("return {width:window.innerWidth||0,height:window.innerHeight||0,scrollX:window.scrollX||0,scrollY:window.scrollY||0};", arguments: [:], in: nil, contentWorld: .defaultClient)
        return try NativeRPCValue.fromFoundation(raw)
    }
    static func clean(_ raw: NativeRPCValue) -> NativeRPCValue {
        func finite(_ value: NativeRPCValue) -> Double {
            guard let number = value.number, number.isFinite else { return 0 }; return number
        }
        func counted(_ value: NativeRPCValue) -> Double { max(0, finite(value).rounded(.down)) }
        let kind = raw["type"].string ?? ""
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let secret = raw["secret"].bool == true || normalizedKind == "password" || normalizedKind == "file"
        let source = raw["labelSource"].string ?? "none"
        let suppress = secret && source == "text"
        return .object([
            .init("found", .bool(raw["found"].bool == true)), .init("moved", .bool(raw["moved"].bool == true)),
            .init("tag", .string(raw["tag"].string ?? "")), .init("type", .string(kind)),
            .init("selector", .string(raw["selector"].string ?? "")), .init("secret", .bool(secret)),
            .init("label", .string(suppress ? "" : raw["label"].string ?? "")),
            .init("labelSource", .string(suppress ? "none" : source)),
            .init("rect", .object([.init("x", .number(finite(raw["rect"]["x"]))), .init("y", .number(finite(raw["rect"]["y"]))),
                .init("w", .number(finite(raw["rect"]["w"]))), .init("h", .number(finite(raw["rect"]["h"])))])),
            .init("depth", .number(counted(raw["depth"]))), .init("maxUp", .number(counted(raw["maxUp"])))
        ])
    }
    private static let script = #"""
    return (function () {
    
    var D = Document.prototype, E = Element.prototype, H = HTMLElement.prototype;
    var qs = function (sel) { try { return D.querySelector.call(document, sel) } catch (e) { return null } };
    var qsa = function (sel) { try { return Array.prototype.slice.call(D.querySelectorAll.call(document, sel)) } catch (e) { return [] } };
    var attr = function (el, name) { try { var v = E.getAttribute.call(el, name); return typeof v === 'string' ? v : '' } catch (e) { return '' } };
    var box = function (el) { try { var r = E.getBoundingClientRect.call(el); return { x: r.x, y: r.y, width: r.width, height: r.height } } catch (e) { return null } };
    /*
     * The text a person would actually read.
     *
     * `innerText` and not `textContent`, and the difference is not cosmetic. It
     * was measured on example.com: `textContent` answered "Example DomainThis
     * domain is for use in documentation examples…", running the heading straight
     * into the paragraph, and on a search-results page it returned the contents of
     * every inline `<script>` — a model reading that is reading minified
     * JavaScript and calling it the page. `innerText` is layout-aware: it skips
     * script, style and anything not rendered, and it puts a break where the layout
     * puts one.
     *
     * The cost is that it forces layout, which is why it is not used for anything
     * that runs inside the actionability loop. `textContent` remains the fallback,
     * because SVG and XML elements do not have `innerText` at all.
     */
    var text = function (el) {
      try {
        var t = typeof el.innerText === 'string' && el.innerText !== '' ? el.innerText : el.textContent;
        return typeof t === 'string' ? t.replace(/[ \t\u00a0]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim() : '';
      } catch (e) { return '' }
    };
    var line = function (el) { return text(el).replace(/\s+/g, ' ').trim() };
    var tagOf = function (el) { try { return String(el.localName || '').toLowerCase() } catch (e) { return '' } };
    var typeOf = function (el) { return attr(el, 'type').trim().toLowerCase() };
    
    /*
     * A field whose value belongs to the person and not to the page.
     *
     * Four cases, and every one of them is a case that has actually bitten
     * somebody rather than a category invented for symmetry:
     *
     *  - type=password, the obvious one.
     *  - autocomplete naming a password or a one-time code. A site that renders
     *    its 2FA box as type=text — and many do, so the numeric keypad appears on
     *    a phone — would otherwise have its code read back and logged.
     *  - type=file, because the value is a path on his own disk, usually starting
     *    with his name. `browser-steps.ts` already treats it as secret for
     *    exactly that reason.
     *  - type=hidden is not secret, it is invisible, and is dropped elsewhere.
     */
    var SECRET_AUTOCOMPLETE = /(current-password|new-password|one-time-code|cc-number|cc-csc)/i;
    var isSecret = function (el) {
      var t = typeOf(el);
      if (t === 'password' || t === 'file') return true;
      if (SECRET_AUTOCOMPLETE.test(attr(el, 'autocomplete'))) return true;
      return false;
    };
    
    var visible = function (el) {
      var r = box(el);
      if (!r || r.width <= 0 || r.height <= 0) return false;
      try {
        var s = window.getComputedStyle(el);
        if (s.visibility === 'hidden' || s.visibility === 'collapse' || s.display === 'none') return false;
        if (Number(s.opacity) === 0) return false;
      } catch (e) { /* a page with no computed style for a node is a node we cannot judge; the rect stands. */ }
      return true;
    };
    
    var enabled = function (el) {
      try {
        if (el.disabled === true) return false;
        if (attr(el, 'aria-disabled') === 'true') return false;
        if (typeof E.closest === 'function' && E.closest.call(el, '[disabled],fieldset[disabled]')) return false;
      } catch (e) { /* fall through: unknown is treated as enabled, and the hit test still has to pass. */ }
      return true;
    };
    
    /*
     * A short, stable way to name this element again next turn.
     *
     * Ordered by how likely it is to survive a re-render, which is the only
     * property that matters for a driver: a test hook is put there on purpose, an
     * id is usually stable, a name attribute is part of the form contract, and a
     * structural path is the last resort because it changes when anything above it
     * does.
     */
    var uniq = function (sel) { try { return D.querySelectorAll.call(document, sel).length === 1 } catch (e) { return false } };
    var cssEscape = function (v) {
      try { return window.CSS && typeof window.CSS.escape === 'function' ? window.CSS.escape(v) : v.replace(/[^a-zA-Z0-9_-]/g, '\\$&') }
      catch (e) { return v }
    };
    var selectorFor = function (el) {
      var hooks = ['data-testid', 'data-test-id', 'data-test', 'data-cy'];
      for (var i = 0; i < hooks.length; i++) {
        var v = attr(el, hooks[i]);
        if (v) { var s = '[' + hooks[i] + '="' + v.replace(/["\\]/g, '\\$&') + '"]'; if (uniq(s)) return s }
      }
      var id = attr(el, 'id');
      if (id) { var s2 = '#' + cssEscape(id); if (uniq(s2)) return s2 }
      var name = attr(el, 'name');
      if (name) { var s3 = tagOf(el) + '[name="' + name.replace(/["\\]/g, '\\$&') + '"]'; if (uniq(s3)) return s3 }
      var aria = attr(el, 'aria-label');
      if (aria) { var s4 = tagOf(el) + '[aria-label="' + aria.replace(/["\\]/g, '\\$&') + '"]'; if (uniq(s4)) return s4 }
      // Structural path, shortest first: walk up until the accumulated selector is
      // unique, or the body is reached. A path that is not unique is still
      // returned — it is honest, and the driver reports how many it matched.
      var parts = [], node = el, depth = 0;
      while (node && tagOf(node) && tagOf(node) !== 'html' && depth < 8) {
        var part = tagOf(node);
        var parent = node.parentElement;
        if (parent) {
          var sibs = Array.prototype.filter.call(parent.children, function (c) { return tagOf(c) === tagOf(node) });
          if (sibs.length > 1) part += ':nth-of-type(' + (sibs.indexOf(node) + 1) + ')';
        }
        parts.unshift(part);
        var joined = parts.join(' > ');
        if (uniq(joined)) return joined;
        if (tagOf(node) === 'body') break;
        node = parent; depth++;
      }
      return parts.join(' > ');
    };
    
    /*
     * The label, and the word for where it came from.
     *
     * One function, because the two answers are one decision. The outline needs only
     * the label; {@link PICK_SCRIPT} needs both, because the sheet a person reads
     * says *text "Sign in"* or *aria-label "Close"* and that second word is the
     * difference between a name the page shows and a name only a screen reader ever
     * says. Splitting them into two functions would be two copies of the fallback
     * order, and a fallback order that disagrees with itself puts one word beside
     * another element's name.
     *
     * The vocabulary is `selector.ts`'s `LabelSource` plus two the desktop's own
     * capture cannot produce because it starts from a click rather than from a
     * field: `name`, and `label` for a `<label for="…">` somewhere else in the
     * document. `value` is in that list and deliberately never returned here —
     * see the note below on why a field never wears its own contents.
     */
    var labelWithSource = function (el) {
      var t = tagOf(el);
      if (t === 'input' || t === 'textarea' || t === 'select') {
        // Never the element's own text or value for a field. A <select>'s
        // textContent is all of its options concatenated, and an input's value is
        // whatever he last typed — `browser-steps.ts` records both mistakes.
        var order = ['aria-label', 'placeholder', 'title', 'name'];
        for (var i = 0; i < order.length; i++) {
          var named = attr(el, order[i]);
          if (named) return { label: named, source: order[i] };
        }
        var id = attr(el, 'id');
        if (id) {
          var lab = qs('label[for="' + id.replace(/["\\]/g, '\\$&') + '"]');
          if (lab) { var written = line(lab); if (written) return { label: written, source: 'label' } }
        }
        return { label: '', source: 'none' };
      }
      var own = line(el);
      if (own) return { label: own, source: 'text' };
      var rest = ['aria-label', 'title', 'alt'];
      for (var j = 0; j < rest.length; j++) {
        var other = attr(el, rest[j]);
        if (other) return { label: other, source: rest[j] };
      }
      return { label: '', source: 'none' };
    };
    
    var labelFor = function (el) { return labelWithSource(el).label };
    
    var args = { x: pointX, y: pointY, up: ancestorSteps } || {};
    var MAX_UP = 64;
    var num = function (v) { return typeof v === 'number' && isFinite(v) ? v : 0 };
    var x = num(args.x), y = num(args.y);
    var want = Math.floor(num(args.up));
    if (!(want > 0)) want = 0;
    if (want > MAX_UP) want = MAX_UP;
    
    /*
     * Document point to viewport point, with the scroll the page has right now.
     * Read from the isolated world's own `window`, which the page cannot redefine.
     */
    var sx = window.scrollX || 0, sy = window.scrollY || 0;
    var vx = x - sx, vy = y - sy;
    var vw = window.innerWidth || 0, vh = window.innerHeight || 0;
    /*
     * Only when there is a viewport to be outside of. A document that reports no
     * size — one still laying out, or one with no body at all — cannot be judged
     * this way, and saying *the page has scrolled* about it would send somebody to
     * scroll a page that never moved. The hit test below answers honestly for it.
     */
    if (vw > 0 && vh > 0 && (vx < 0 || vy < 0 || vx >= vw || vy >= vh)) {
      return { found: false, moved: true };
    }
    
    var at = null;
    try { at = D.elementFromPoint.call(document, vx, vy) } catch (e) { at = null }
    if (!at || at.nodeType !== 1) return { found: false, moved: false };
    
    /*
     * The element and everything above it, in one pass.
     *
     * Collected before anything is measured, because `maxUp` is a fact about the
     * chain rather than about the element — a sheet that had to ask again to find
     * out whether Wider is live would be a second round trip per press.
     */
    var chain = [];
    var node = at;
    while (node && node.nodeType === 1 && chain.length <= MAX_UP) {
      chain.push(node);
      try { node = node.parentElement } catch (e) { node = null }
    }
    var depth = want >= chain.length ? chain.length - 1 : want;
    var el = chain[depth];
    var r = box(el);
    var named = labelWithSource(el);
    return {
      found: true,
      moved: false,
      tag: tagOf(el),
      type: typeOf(el),
      selector: selectorFor(el),
      label: named.label,
      labelSource: named.source,
      secret: isSecret(el),
      /*
       * Back into document coordinates, so the phone can draw the outline over the
       * next frame it receives without knowing when this was measured.
       */
      rect: r ? { x: r.x + sx, y: r.y + sy, w: r.width, h: r.height } : { x: 0, y: 0, w: 0, h: 0 },
      depth: depth,
      maxUp: chain.length - 1 - depth,
    };
    })();
    """#
}
