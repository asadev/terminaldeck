import Foundation

/// The scripts the native driver runs in a page, in WebKit's isolated client
/// world (the page's own JavaScript cannot see or replace them). Ported from the
/// Electron driver's (`src/main/browser-drive-script.ts`) so both read a page the
/// same way, with one addition: every element the outline lists is stamped with
/// `data-td-ref="eN"`, and when no short, unique selector exists the outline
/// names it by that ref — which stays true for as long as the element lives.
///
/// Browser 27 (Asad, 4 Nov: "as much as possible all the capabilities that the
/// Playwright browser can do"): every script finds elements through one selector
/// engine. A selector is CSS by default and may also be `text=…`, `role=…[name=…]`,
/// `xpath=…` (or any `//…`), `label=…`, `placeholder=…`, `alt=…`, `title=…`,
/// `testid=…`, chained with ` >> ` (`#cart >> text=Remove`), narrowed with
/// `nth=N` or `visible=true`. CSS looks in the page first, then inside open shadow
/// roots, then inside same-origin frames; a chain step that lands on an `<iframe>`
/// continues inside it. Boxes are in the top page's CSS pixels, frames included.
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
    var tagOf = function (el) { try { return String(el.localName || '').toLowerCase() } catch (e) { return '' } };
    var attr = function (el, name) { try { var v = E.getAttribute.call(el, name); return typeof v === 'string' ? v : '' } catch (e) { return '' } };
    var norm = function (s) { return String(s == null ? '' : s).replace(/\s+/g, ' ').trim() };
    var winOf = function (el) { try { return (el.ownerDocument && el.ownerDocument.defaultView) || window } catch (e) { return window } };
    var styleOf = function (el) { try { return winOf(el).getComputedStyle(el) } catch (e) { return null } };
    var frameOffset = function (el) {
      var x = 0, y = 0;
      try {
        var w = winOf(el);
        while (w && w !== window && w.frameElement) {
          var f = w.frameElement, r = f.getBoundingClientRect(), s = w.parent.getComputedStyle(f);
          x += r.x + f.clientLeft + (parseFloat(s.paddingLeft) || 0);
          y += r.y + f.clientTop + (parseFloat(s.paddingTop) || 0);
          w = w.parent;
        }
      } catch (e) {}
      return { x: x, y: y };
    };
    var localBox = function (el) { try { var r = E.getBoundingClientRect.call(el); return { x: r.x, y: r.y, width: r.width, height: r.height } } catch (e) { return null } };
    var box = function (el) {
      var r = localBox(el); if (!r) return null;
      var o = frameOffset(el);
      return { x: r.x + o.x, y: r.y + o.y, width: r.width, height: r.height };
    };
    var text = function (el) {
      try {
        var t = typeof el.innerText === 'string' && el.innerText !== '' ? el.innerText : el.textContent;
        return typeof t === 'string' ? t.replace(/[ \t\u00a0]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim() : '';
      } catch (e) { return '' }
    };
    var line = function (el) { return text(el).replace(/\s+/g, ' ').trim() };
    var typeOf = function (el) { return attr(el, 'type').trim().toLowerCase() };
    // contenteditable="" counts as on; a missing attribute (attr gives '') does not.
    var editableAttr = function (el) {
      try { if (!el.hasAttribute || !el.hasAttribute('contenteditable')) return false } catch (e) { return false }
      var v = attr(el, 'contenteditable').toLowerCase();
      return v === '' || v === 'true' || v === 'plaintext-only';
    };
    var SECRET_AUTOCOMPLETE = /(current-password|new-password|one-time-code|cc-[a-z-]+)/i;
    var isSecret = function (el) {
      var t = typeOf(el);
      if (t === 'password' || t === 'file') return true;
      return SECRET_AUTOCOMPLETE.test(attr(el, 'autocomplete')) || /(?:card.?num|credit.?card|cc.?num|cvv|cvc|csc|one.?time.?code|password|passwd)/i.test(attr(el, 'name') + ' ' + attr(el, 'id'));
    };
    var visible = function (el) {
      var r = localBox(el);
      if (!r || r.width <= 0 || r.height <= 0) return false;
      var s = styleOf(el);
      if (s && (s.visibility === 'hidden' || s.visibility === 'collapse' || s.display === 'none' || Number(s.opacity) === 0)) return false;
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
    // Elements below a root, open shadow roots included (document order, then each shadow root).
    var shadowRoots = function (root) {
      var out = [];
      var walk = function (r) {
        var all; try { all = r.querySelectorAll('*') } catch (e) { return }
        for (var i = 0; i < all.length; i++) { var sr = all[i].shadowRoot; if (sr) { out.push(sr); walk(sr) } }
      };
      walk(root);
      return out;
    };
    var frameDocs = function (root) {
      var out = [];
      var walk = function (r) {
        var frames; try { frames = r.querySelectorAll('iframe,frame') } catch (e) { return }
        for (var i = 0; i < frames.length; i++) {
          var d = null; try { d = frames[i].contentDocument } catch (e) { d = null }
          if (d && d.documentElement) { out.push(d); walk(d) }
        }
      };
      walk(root);
      return out;
    };
    var cssAll = function (root, css, deep) {
      var list = Array.prototype.slice.call(root.querySelectorAll(css)); // a bad selector throws here, on purpose
      if (list.length || !deep) return list;
      var roots = shadowRoots(root);
      for (var i = 0; i < roots.length; i++) list = list.concat(Array.prototype.slice.call(roots[i].querySelectorAll(css)));
      if (list.length || root.nodeType !== 9) return list;
      var docs = frameDocs(root);
      for (var j = 0; j < docs.length; j++) {
        list = list.concat(Array.prototype.slice.call(docs[j].querySelectorAll(css)));
        var inner = shadowRoots(docs[j]);
        for (var k = 0; k < inner.length; k++) list = list.concat(Array.prototype.slice.call(inner[k].querySelectorAll(css)));
      }
      return list;
    };
    // Every element under a root, shadow roots included, in tree order.
    var everyElement = function (root, visit) {
      var stack = [root];
      while (stack.length) {
        var node = stack.pop();
        var kids = node.children || (node.nodeType === 11 ? node.children : null) || [];
        for (var i = kids.length - 1; i >= 0; i--) stack.push(kids[i]);
        if (node.nodeType === 1) {
          if (visit(node) === false) { stack.length = stack.length - kids.length; continue }
          if (node.shadowRoot) stack.push(node.shadowRoot);
        }
      }
    };
    var matcher = function (body, loose) {
      body = String(body || '').trim();
      var re = /^\/([\s\S]+)\/([dgimsuy]*)$/.exec(body);
      if (re) { var rx = new RegExp(re[1], re[2].replace('g', '')); return { test: function (s) { return rx.test(norm(s)) }, prune: null } }
      var q = /^(["'])([\s\S]*)\1([is]?)$/.exec(body);
      if (q) {
        var want = norm(q[2]);
        if (loose && q[3] !== 's') { var lw = want.toLowerCase(); return { test: function (s) { return norm(s).toLowerCase().indexOf(lw) !== -1 }, prune: lw } }
        if (q[3] === 'i') { var li = want.toLowerCase(); return { test: function (s) { return norm(s).toLowerCase() === li }, prune: li } }
        return { test: function (s) { return norm(s) === want }, prune: want.toLowerCase() };
      }
      var low = norm(body).toLowerCase();
      return { test: function (s) { return norm(s).toLowerCase().indexOf(low) !== -1 }, prune: low };
    };
    var ownText = function (el) {
      var t = tagOf(el);
      if (t === 'input') { var ty = typeOf(el); if (ty === 'button' || ty === 'submit' || ty === 'reset') return attr(el, 'value') || el.value || '' }
      return el.textContent || '';
    };
    var byText = function (root, body) {
      var m = matcher(body, false), out = [];
      var walk = function (r) {
        everyElement(r, function (el) {
          var t = tagOf(el);
          if (t === 'script' || t === 'style' || t === 'noscript' || t === 'template' || t === 'head') return false;
          var own = ownText(el);
          if (m.prune !== null && own.toLowerCase().replace(/\s+/g, ' ').indexOf(m.prune) === -1 && !el.shadowRoot) return false;
          if (!m.test(own)) return;
          var kids = el.children || [];
          for (var i = 0; i < kids.length; i++) { if (m.test(ownText(kids[i]))) return }
          out.push(el);
        });
      };
      walk(root);
      return out;
    };
    var IMPLICIT = { a: 'link', area: 'link', article: 'article', aside: 'complementary', blockquote: 'blockquote', button: 'button',
      dialog: 'dialog', details: 'group', fieldset: 'group', figure: 'figure', footer: 'contentinfo', form: 'form', h1: 'heading', h2: 'heading',
      h3: 'heading', h4: 'heading', h5: 'heading', h6: 'heading', header: 'banner', hr: 'separator', img: 'img', li: 'listitem', main: 'main',
      math: 'math', menu: 'list', meter: 'meter', nav: 'navigation', ol: 'list', optgroup: 'group', option: 'option', output: 'status', p: 'paragraph',
      progress: 'progressbar', section: 'region', summary: 'button', table: 'table', tbody: 'rowgroup', thead: 'rowgroup', tfoot: 'rowgroup',
      td: 'cell', textarea: 'textbox', th: 'columnheader', tr: 'row', ul: 'list', dl: 'list', dt: 'term', dd: 'definition', code: 'code', svg: 'img' };
    var roleOf = function (el) {
      var explicit = attr(el, 'role').trim().split(/\s+/)[0];
      if (explicit) return explicit.toLowerCase();
      var t = tagOf(el);
      if (t === 'a' || t === 'area') return attr(el, 'href') ? 'link' : '';
      if (t === 'input') {
        var ty = typeOf(el) || 'text';
        if (ty === 'hidden') return '';
        if (ty === 'button' || ty === 'submit' || ty === 'reset' || ty === 'image') return 'button';
        if (ty === 'checkbox') return 'checkbox';
        if (ty === 'radio') return 'radio';
        if (ty === 'range') return 'slider';
        if (ty === 'number') return 'spinbutton';
        if (ty === 'search') return attr(el, 'list') ? 'combobox' : 'searchbox';
        if (ty === 'file') return 'button';
        return attr(el, 'list') ? 'combobox' : 'textbox';
      }
      if (t === 'select') return el.multiple || Number(attr(el, 'size')) > 1 ? 'listbox' : 'combobox';
      if (t === 'img') return attr(el, 'alt') === '' && el.hasAttribute('alt') ? 'presentation' : 'img';
      if (t === 'section') return attr(el, 'aria-label') || attr(el, 'aria-labelledby') ? 'region' : '';
      if (t === 'form') return attr(el, 'aria-label') || attr(el, 'aria-labelledby') || attr(el, 'name') ? 'form' : '';
      if (t === 'header' || t === 'footer') { try { if (E.closest.call(el, 'article,aside,main,nav,section')) return '' } catch (e) {} }
      if (t === 'th') return attr(el, 'scope') === 'row' ? 'rowheader' : 'columnheader';
      if (t === 'svg') return attr(el, 'aria-label') || attr(el, 'aria-labelledby') ? 'img' : '';
      if (editableAttr(el)) return 'textbox';
      return IMPLICIT[t] || '';
    };
    var FROM_CONTENT = { button: 1, link: 1, heading: 1, cell: 1, columnheader: 1, rowheader: 1, tab: 1, menuitem: 1, menuitemcheckbox: 1,
      menuitemradio: 1, option: 1, checkbox: 1, radio: 1, switch: 1, treeitem: 1, tooltip: 1, row: 1, term: 1, listitem: 0 };
    var byId = function (el, ids) {
      var doc = el.getRootNode ? el.getRootNode() : el.ownerDocument, out = [];
      String(ids || '').split(/\s+/).forEach(function (id) {
        if (!id) return; var found = null;
        try { found = doc.getElementById ? doc.getElementById(id) : doc.querySelector('#' + cssEscape(id)) } catch (e) {}
        if (!found) { try { found = el.ownerDocument.getElementById(id) } catch (e) {} }
        if (found) out.push(line(found));
      });
      return norm(out.join(' '));
    };
    var labelsOf = function (el) {
      var out = [];
      try { var labels = el.labels; if (labels) for (var i = 0; i < labels.length; i++) out.push(line(labels[i])) } catch (e) {}
      return norm(out.join(' '));
    };
    var nameOf = function (el, role) {
      var by = attr(el, 'aria-labelledby'); if (by) { var n0 = byId(el, by); if (n0) return n0 }
      var aria = attr(el, 'aria-label'); if (aria.trim()) return norm(aria);
      var t = tagOf(el);
      if (t === 'input' || t === 'textarea' || t === 'select') {
        var ty = typeOf(el);
        if (ty === 'button' || ty === 'submit' || ty === 'reset') return norm(attr(el, 'value') || el.value || (ty === 'submit' ? 'Submit' : ty === 'reset' ? 'Reset' : ''));
        if (ty === 'image') return norm(attr(el, 'alt') || attr(el, 'value') || 'Submit');
        var lab = labelsOf(el); if (lab) return lab;
        return norm(attr(el, 'title') || attr(el, 'placeholder'));
      }
      if (t === 'img' || t === 'area') return norm(attr(el, 'alt') || attr(el, 'title'));
      if (t === 'fieldset') { try { var lg = el.querySelector('legend'); if (lg) return line(lg) } catch (e) {} }
      if (t === 'table') { try { var cap = el.querySelector('caption'); if (cap) return line(cap) } catch (e) {} }
      if (t === 'figure') { try { var fc = el.querySelector('figcaption'); if (fc) return line(fc) } catch (e) {} }
      if (FROM_CONTENT[role || roleOf(el)]) { var c = line(el); if (c) return c.length > 200 ? c.slice(0, 200) : c }
      return norm(attr(el, 'title'));
    };
    var states = function (el, role) {
      var out = {};
      var ac = attr(el, 'aria-checked');
      if (role === 'checkbox' || role === 'radio' || role === 'switch' || role === 'menuitemcheckbox' || role === 'menuitemradio') {
        out.checked = ac ? (ac === 'mixed' ? 'mixed' : ac === 'true') : el.checked === true;
      }
      var ex = attr(el, 'aria-expanded'); if (ex) out.expanded = ex === 'true';
      var se = attr(el, 'aria-selected'); if (se) out.selected = se === 'true'; else if (tagOf(el) === 'option') out.selected = el.selected === true;
      var pr = attr(el, 'aria-pressed'); if (pr) out.pressed = pr === 'mixed' ? 'mixed' : pr === 'true';
      if (!enabled(el)) out.disabled = true;
      if (role === 'heading') { var lv = Number(attr(el, 'aria-level')) || Number(String(tagOf(el)).replace('h', '')) || 2; out.level = lv }
      return out;
    };
    var parseRole = function (body) {
      var m = /^\s*([a-zA-Z]+)\s*([\s\S]*)$/.exec(body);
      if (!m) throw new Error('bad role selector');
      var role = m[1].toLowerCase(), rest = m[2], want = [];
      var rx = /\[\s*([a-z-]+)\s*(?:=\s*("(?:[^"\\]|\\.)*"[is]?|'(?:[^'\\]|\\.)*'[is]?|\/(?:[^\/\\]|\\.)+\/[a-z]*|[^\]\s]+))?\s*\]/gi, part;
      while ((part = rx.exec(rest))) want.push({ key: part[1].toLowerCase(), value: part[2] === undefined ? null : part[2] });
      return { role: role, want: want };
    };
    var byRole = function (root, body) {
      var spec = parseRole(body), out = [];
      var nameTest = null;
      spec.want.forEach(function (w) { if (w.key === 'name' && w.value !== null) nameTest = matcher(w.value, true) });
      everyElement(root, function (el) {
        var t = tagOf(el); if (t === 'script' || t === 'style' || t === 'head' || t === 'template') return false;
        var r = roleOf(el); if (r !== spec.role) return;
        if (nameTest && !nameTest.test(nameOf(el, r))) return;
        var st = states(el, r);
        for (var i = 0; i < spec.want.length; i++) {
          var w = spec.want[i]; if (w.key === 'name' || w.key === 'include-hidden') continue;
          var have = st[w.key]; var v = w.value === null ? true : String(w.value).replace(/^["']|["']$/g, '');
          if (w.key === 'level') { if (Number(have) !== Number(v)) return; continue }
          if (String(have === undefined ? false : have) !== String(v)) return;
        }
        out.push(el);
      });
      return out;
    };
    var byXPath = function (root, expr) {
      var doc = root.nodeType === 9 ? root : root.ownerDocument, out = [];
      var res = doc.evaluate(expr, root.nodeType === 11 ? root.host : root, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
      for (var i = 0; i < res.snapshotLength; i++) { var n = res.snapshotItem(i); if (n && n.nodeType === 1) out.push(n) }
      return out;
    };
    var byLabel = function (root, body) {
      var m = matcher(body, true), out = [];
      everyElement(root, function (el) {
        var t = tagOf(el), r = roleOf(el);
        if (!(t === 'input' || t === 'textarea' || t === 'select' || r === 'textbox' || r === 'combobox' || r === 'checkbox' || r === 'radio' || r === 'slider' || r === 'spinbutton' || r === 'searchbox' || r === 'switch')) return;
        var names = [labelsOf(el), attr(el, 'aria-label')];
        var by = attr(el, 'aria-labelledby'); if (by) names.push(byId(el, by));
        for (var i = 0; i < names.length; i++) { if (names[i] && m.test(names[i])) { out.push(el); return } }
      });
      return out;
    };
    var byAttr = function (root, name, body, exact) {
      var m = exact ? { test: function (s) { return s === String(body).replace(/^["']|["']$/g, '') } } : matcher(body, true), out = [];
      everyElement(root, function (el) { if (el.hasAttribute && el.hasAttribute(name) && m.test(attr(el, name))) out.push(el) });
      return out;
    };
    var splitChain = function (sel) {
      var parts = [], depth = 0, quote = null, cur = '';
      for (var i = 0; i < sel.length; i++) {
        var c = sel.charAt(i);
        if (quote) { cur += c; if (c === '\\') { cur += sel.charAt(++i); continue } if (c === quote) quote = null; continue }
        if (c === '"' || c === "'") { quote = c; cur += c; continue }
        if (c === '[' || c === '(') depth++; else if (c === ']' || c === ')') depth = Math.max(0, depth - 1);
        if (depth === 0 && c === '>' && sel.charAt(i + 1) === '>') { parts.push(cur.trim()); cur = ''; i++; continue }
        cur += c;
      }
      if (cur.trim()) parts.push(cur.trim());
      return parts;
    };
    var ENGINE = /^(css|text|role|xpath|label|placeholder|alt|title|testid|nth|visible)\s*=\s*([\s\S]*)$/;
    var enter = function (el) {
      if (el && el.nodeType === 1) {
        var t = tagOf(el);
        if (t === 'iframe' || t === 'frame') { try { return el.contentDocument || null } catch (e) { return null } }
      }
      return el;
    };
    // All matches, in order; throws for a selector that cannot be read.
    var resolveAll = function (sel, scope) {
      var parts = splitChain(String(sel || ''));
      if (!parts.length) throw new Error('empty selector');
      var current = [scope || document];
      for (var p = 0; p < parts.length; p++) {
        var seg = parts[p], m = ENGINE.exec(seg), kind = m ? m[1] : 'css', body = m ? m[2] : seg;
        if (!m && /^\(*\.{0,2}\/\//.test(seg)) { kind = 'xpath'; body = seg }
        else if (!m && /^"[\s\S]*"$/.test(seg)) { kind = 'text'; body = seg }
        if (kind === 'nth') {
          var n = parseInt(body, 10); if (isNaN(n)) throw new Error('bad nth');
          var pick = n < 0 ? current[current.length + n] : current[n];
          current = pick && pick.nodeType === 1 ? [pick] : []; continue;
        }
        if (kind === 'visible') { var wantVisible = body.trim() !== 'false'; current = current.filter(function (el) { return el.nodeType === 1 && visible(el) === wantVisible }); continue }
        var next = [];
        for (var i = 0; i < current.length; i++) {
          var root = enter(current[i]); if (!root) continue;
          var found;
          if (kind === 'css') found = cssAll(root, body, true);
          else if (kind === 'text') found = byText(root, body);
          else if (kind === 'role') found = byRole(root, body);
          else if (kind === 'xpath') found = byXPath(root, body);
          else if (kind === 'label') found = byLabel(root, body);
          else if (kind === 'testid') found = byAttr(root, 'data-testid', body, true);
          else found = byAttr(root, kind, body, false);
          for (var j = 0; j < found.length; j++) if (next.indexOf(found[j]) === -1) next.push(found[j]);
        }
        current = next;
      }
      return current.filter(function (el) { return el && el.nodeType === 1 });
    };
    var firstOf = function (list) {
      for (var i = 0; i < list.length; i++) if (visible(list[i])) return list[i];
      return list.length ? list[0] : null;
    };
    var qs = function (sel, scope) { try { return firstOf(resolveAll(sel, scope)) } catch (e) { return null } };
    var qsa = function (sel, scope) { try { return resolveAll(sel, scope) } catch (e) { return [] } };
    var deepQsa = function (css) {
      var list = [];
      try { list = Array.prototype.slice.call(document.querySelectorAll(css)) } catch (e) { return [] }
      var roots = shadowRoots(document).concat(frameDocs(document));
      for (var i = 0; i < roots.length; i++) {
        try { list = list.concat(Array.prototype.slice.call(roots[i].querySelectorAll(css))) } catch (e) {}
        if (roots[i].nodeType === 9) { var inner = shadowRoots(roots[i]); for (var k = 0; k < inner.length; k++) { try { list = list.concat(Array.prototype.slice.call(inner[k].querySelectorAll(css))) } catch (e) {} } }
      }
      return list;
    };
    var uniq = function (sel, el) { try { var all = resolveAll(sel); return all.length === 1 && (!el || all[0] === el) } catch (e) { return false } };
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
        if (v) { var s = '[' + hooks[i] + '=' + quoted(v) + ']'; if (uniq(s, el)) return s }
      }
      var id = attr(el, 'id');
      if (id) { var s2 = '#' + cssEscape(id); if (uniq(s2, el)) return s2 }
      var name = attr(el, 'name');
      if (name) { var s3 = tagOf(el) + '[name=' + quoted(name) + ']'; if (uniq(s3, el)) return s3 }
      var aria = attr(el, 'aria-label');
      if (aria) { var s4 = tagOf(el) + '[aria-label=' + quoted(aria) + ']'; if (uniq(s4, el)) return s4 }
      return null;
    };
    var refSelector = function (el) { return selectorFor(el) || '[' + REF + '="' + refFor(el) + '"]' };
    var labelFor = function (el) {
      var t = tagOf(el);
      if (t === 'input' || t === 'textarea' || t === 'select') {
        var order = ['aria-label', 'placeholder', 'title', 'name'];
        for (var i = 0; i < order.length; i++) { var named = attr(el, order[i]); if (named) return named }
        var lab = labelsOf(el); if (lab) return lab;
        return '';
      }
      var own = line(el);
      if (own) return own.length > 150 ? own.slice(0, 150) : own;
      var rest = ['aria-label', 'title', 'alt'];
      for (var j = 0; j < rest.length; j++) { var other = attr(el, rest[j]); if (other) return other }
      return '';
    };
    var composedContains = function (outer, inner) {
      var n = inner;
      while (n) { if (n === outer) return true; n = n.parentNode || n.host || null }
      return false;
    };
    var hitTest = function (el) {
      var r = localBox(el); if (!r || r.width <= 0 || r.height <= 0) return false;
      try {
        var root = el.getRootNode ? el.getRootNode() : el.ownerDocument;
        var finder = root && typeof root.elementFromPoint === 'function' ? root : el.ownerDocument;
        var at = finder.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
        return at !== null && (composedContains(el, at) || composedContains(at, el));
      } catch (e) { return false }
    };
    var center = function (el) { var r = localBox(el) || { x: 0, y: 0, width: 0, height: 0 }; return { x: r.x + r.width / 2, y: r.y + r.height / 2 } };
    """#

    /// The page: its words, and every element that can be acted on, each with a
    /// selector to name it and its ref. Open shadow roots and same-origin frames count.
    public static let outline = "/*td:outline*/(function () {\n" + preamble + #"""
    var args = /*__DECK_ARGS__*/null || {};
    var limit = typeof args.limit === 'number' ? args.limit : 60;
    var textLimit = typeof args.textLimit === 'number' ? args.textLimit : 4000;
    var sel = 'a[href],button,input,select,textarea,summary,[role="button"],[role="link"],[role="checkbox"],[role="radio"],[role="switch"],[role="tab"],[role="menuitem"],[role="option"],[role="combobox"],[role="textbox"],[role="searchbox"],[contenteditable="true"],[contenteditable=""]';
    var out = [], seen = 0, all = deepQsa(sel);
    for (var i = 0; i < all.length && out.length < limit; i++) {
      var el = all[i];
      if (typeOf(el) === 'hidden') continue;
      if (!visible(el)) continue;
      seen++;
      var t = tagOf(el), r = roleOf(el);
      var kind = t === 'a' ? 'link' : (t === 'input' && typeOf(el) !== 'button' && typeOf(el) !== 'submit' && typeOf(el) !== 'reset') || t === 'textarea' || t === 'select' || r === 'textbox' || r === 'combobox' || r === 'searchbox' ? 'field' : 'button';
      var entry = {
        kind: kind, tag: t, type: typeOf(el), label: labelFor(el),
        selector: refSelector(el), ref: refFor(el), secret: isSecret(el), enabled: enabled(el)
      };
      if (el.ownerDocument !== document) entry.frame = true;
      if (el.getRootNode && el.getRootNode() !== el.ownerDocument) entry.shadow = true;
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

    public static let activeSecret = "/*td:activeSecret*/(function () {\n" + preamble + #"""
    var active = document.activeElement;
    for (var depth = 0; active && depth < 20; depth++) {
      if (isSecret(active)) return { secret: true };
      if (active.shadowRoot && active.shadowRoot.activeElement) { active = active.shadowRoot.activeElement; continue }
      if (tagOf(active) === 'iframe' || tagOf(active) === 'frame') {
        try { active = active.contentDocument.activeElement; continue } catch (e) { return { secret: true } }
      }
      break;
    }
    return { secret: false };
    })()
    """#

    /// One element: is it there, where, can it be acted on, is it what a click would hit.
    public static let probe = "/*td:probe*/(function () {\n" + preamble + #"""
    var args = /*__DECK_ARGS__*/null || {};
    var sel = typeof args.selector === 'string' ? args.selector : '';
    var invalid = false, nodes = [];
    try { nodes = resolveAll(sel) } catch (e) { invalid = true }
    if (nodes.length === 0) return { found: false, count: 0, invalid: invalid };
    var el = firstOf(nodes);
    var r = box(el), tg = tagOf(el);
    var answer = {
      found: true, count: nodes.length, tag: tg, type: typeOf(el), label: labelFor(el),
      secret: isSecret(el), visible: visible(el), enabled: enabled(el),
      editable: tg === 'input' || tg === 'textarea' || editableAttr(el),
      checked: el.checked === true, rect: r, hit: hitTest(el), multiple: el.multiple === true,
      draggable: (function () { try { return !!E.closest.call(el, '[draggable="true"]') } catch (e) { return false } })(),
      inFrame: el.ownerDocument !== document,
      viewport: { width: window.innerWidth || 0, height: window.innerHeight || 0 },
      url: String(location.href)
    };
    if (tg === 'input' && typeOf(el) === 'file') { answer.accept = attr(el, 'accept'); answer.files = el.files ? el.files.length : 0 }
    return answer;
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
    var wanted = Array.isArray(args.values) ? args.values.map(String) : [String(args.value == null ? '' : args.value)];
    if (wanted.length > 1 && !el.multiple) return { ok: false, reason: 'that dropdown takes one option, not ' + wanted.length };
    var options = Array.prototype.slice.call(el.options || []);
    var picks = [];
    for (var w = 0; w < wanted.length; w++) {
      var found = -1;
      for (var i = 0; i < options.length; i++) { if (String(options[i].value) === wanted[w]) { found = i; break } }
      if (found === -1) { for (var j = 0; j < options.length; j++) { if (line(options[j]) === wanted[w]) { found = j; break } } }
      if (found === -1) {
        var names = [];
        for (var k = 0; k < options.length && k < 20; k++) names.push(line(options[k]) || String(options[k].value));
        return { ok: false, reason: 'no such option as ' + wanted[w] + '. The ones there are: ' + names.join(', ') };
      }
      picks.push(found);
    }
    if (el.multiple) { for (var m = 0; m < options.length; m++) options[m].selected = picks.indexOf(m) !== -1 }
    else el.selectedIndex = picks[0];
    try { el.dispatchEvent(new Event('input', { bubbles: true })) } catch (e) {}
    try { el.dispatchEvent(new Event('change', { bubbles: true })) } catch (e) {}
    return { ok: true, value: String(el.value), values: options.filter(function (o) { return o.selected }).map(function (o) { return String(o.value) }) };
    })()
    """#

    /// Where the secret fields are, to paint them out of a screenshot.
    public static let secretRects = "/*td:secretRects*/(function () {\n" + preamble + #"""
    var out = [], all = deepQsa('input,textarea');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (!isSecret(el) || !visible(el)) continue;
      var r = box(el); if (r) out.push(r);
    }
    return { rects: out, viewport: { width: window.innerWidth || 0, height: window.innerHeight || 0 } };
    })()
    """#

    /// How many password, one-time-code or card fields hold a value right now
    /// (never the values). Page scripts and PDFs are refused while any does.
    public static let secretState = "/*td:secretState*/(function () {\n" + preamble + #"""
    var filled = 0, fields = 0, all = deepQsa('input,textarea');
    var CARD = /(cc-number|cc-csc|cc-exp)/i, NAMED = /(card.?num|cc.?num|cvc|cvv|csc)/i;
    for (var i = 0; i < all.length; i++) {
      var el = all[i], ty = typeOf(el);
      if (ty === 'file') continue;
      if (!(isSecret(el) || CARD.test(attr(el, 'autocomplete')) || NAMED.test(attr(el, 'name') + ' ' + attr(el, 'id')))) continue;
      fields++;
      try { if (typeof el.value === 'string' && el.value !== '') filled++ } catch (e) {}
    }
    var blind = 0;
    try { var frames = document.querySelectorAll('iframe,frame'); for (var f = 0; f < frames.length; f++) { var d = null; try { d = frames[f].contentDocument } catch (e) {} if (!d) blind++ } } catch (e) {}
    return { fields: fields, filled: filled, unreadableFrames: blind };
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
      else if (editableAttr(el)) {
        var range = el.ownerDocument.createRange(); range.selectNodeContents(el);
        var s = winOf(el).getSelection(); s.removeAllRanges(); s.addRange(range);
      }
    } catch (e) {}
    return { ok: true, focused: el.ownerDocument.activeElement === el };
    })()
    """#

    /// Only when the page is not on screen to take real input: a scripted click,
    /// typing that sets the value the way frameworks listen for, or a key.
    public static let scriptedInput = "/*td:scriptedInput*/(function () {\n" + preamble + #"""
    var args = /*__DECK_ARGS__*/null || {};
    var el = args.selector ? qs(String(args.selector)) : null;
    if (!el && args.action === 'key' && !args.selector) { try { el = document.activeElement || document.body } catch (e) { el = document.body } }
    if (!el) return { ok: false, reason: 'no element matched that selector' };
    if (args.mainDocumentOnly && el.ownerDocument !== document) return { ok: false, reason: 'uploading into another frame requires its own permission' };
    var c = center(el);
    var mods = args.modifiers || {};
    var fire = function (type, init) {
      var base = { bubbles: true, cancelable: true, composed: true, clientX: c.x, clientY: c.y, view: winOf(el),
                   shiftKey: !!mods.shift, ctrlKey: !!mods.control, altKey: !!mods.alt, metaKey: !!mods.meta };
      try { el.dispatchEvent(new (init && init.key ? KeyboardEvent : MouseEvent)(type, Object.assign(base, init || {}))) } catch (e) {}
    };
    if (args.action === 'click') {
      fire('mousedown'); fire('mouseup');
      try { H.click.call(el) } catch (e) { fire('click') }
      return { ok: true };
    }
    if (args.action === 'type') {
      try { H.focus.call(el) } catch (e) {}
      var v = String(args.value == null ? '' : args.value);
      if (editableAttr(el)) { el.textContent = v }
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
      try { if (el !== document.body) H.focus.call(el) } catch (e) {}
      var key = String(args.key || 'Enter');
      fire('keydown', { key: key }); fire('keyup', { key: key });
      if (key === 'Enter' && el.form && typeof el.form.requestSubmit === 'function') { try { el.form.requestSubmit() } catch (e) {} }
      return { ok: true };
    }
    return { ok: false, reason: 'unknown action' };
    })()
    """#

    /// DOM-event actions WebKit's public input cannot do safely (a native right
    /// click opens a menu, a native drag starts a system drag session), plus the
    /// scripted fallback for hover and double-click when the page is off screen.
    public static let domAction = "/*td:domAction*/(function () {\n" + preamble + #"""
    var args = /*__DECK_ARGS__*/null || {};
    var action = String(args.action || '');
    var el = args.selector ? qs(String(args.selector)) : null;
    if (!el && action !== 'scroll') return { ok: false, reason: 'no element matched that selector' };
    var at = function (node) { var c = center(node); return { x: c.x, y: c.y } };
    var mouse = function (node, type, p, extra) {
      var init = Object.assign({ bubbles: true, cancelable: true, composed: true, clientX: p.x, clientY: p.y, view: winOf(node), button: 0, buttons: 0 }, extra || {});
      var ev;
      try { ev = type.indexOf('pointer') === 0 ? new PointerEvent(type, Object.assign({ pointerId: 1, pointerType: 'mouse', isPrimary: true }, init)) : new MouseEvent(type, init) }
      catch (e) { ev = new MouseEvent(type.replace('pointer', 'mouse'), init) }
      node.dispatchEvent(ev);
      return ev;
    };
    if (action === 'hover') {
      var p = at(el);
      ['pointerover', 'pointerenter', 'mouseover', 'mouseenter', 'pointermove', 'mousemove'].forEach(function (t) { mouse(el, t, p, t.indexOf('enter') !== -1 ? { bubbles: false } : null) });
      return { ok: true };
    }
    if (action === 'dblclick') {
      var q = at(el);
      for (var n = 1; n <= 2; n++) { mouse(el, 'pointerdown', q, { detail: n, buttons: 1 }); mouse(el, 'mousedown', q, { detail: n, buttons: 1 }); mouse(el, 'pointerup', q, { detail: n }); mouse(el, 'mouseup', q, { detail: n }); mouse(el, 'click', q, { detail: n }) }
      mouse(el, 'dblclick', q, { detail: 2 });
      return { ok: true };
    }
    if (action === 'contextmenu') {
      var cpt = at(el);
      mouse(el, 'pointerdown', cpt, { button: 2, buttons: 2 }); mouse(el, 'mousedown', cpt, { button: 2, buttons: 2 });
      mouse(el, 'pointerup', cpt, { button: 2 }); mouse(el, 'mouseup', cpt, { button: 2 });
      var menu = mouse(el, 'contextmenu', cpt, { button: 2 });
      return { ok: true, prevented: menu.defaultPrevented };
    }
    if (action === 'focus') { try { H.focus.call(el) } catch (e) {} return { ok: el.ownerDocument.activeElement === el } }
    if (action === 'blur') { try { H.blur.call(el) } catch (e) {} return { ok: true } }
    if (action === 'clear') {
      if (isSecret(el)) return { ok: false, reason: 'that is a secret field' };
      try { H.focus.call(el) } catch (e) {}
      if (editableAttr(el)) el.textContent = '';
      else {
        var proto = tagOf(el) === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        var setter = Object.getOwnPropertyDescriptor(proto, 'value');
        try { setter && setter.set ? setter.set.call(el, '') : (el.value = '') } catch (e) { el.value = '' }
      }
      try { el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' })) } catch (e) {}
      try { el.dispatchEvent(new Event('change', { bubbles: true })) } catch (e) {}
      return { ok: true };
    }
    if (action === 'scroll') {
      var dx = Number(args.x) || 0, dy = Number(args.y) || 0;
      if (el) {
        if (!dx && !dy) { try { H.scrollIntoView.call(el, { block: 'center', inline: 'center', behavior: 'instant' }) } catch (e) {} return { ok: true, rect: box(el) } }
        try { el.scrollBy(dx, dy) } catch (e) { el.scrollTop += dy; el.scrollLeft += dx }
        return { ok: true, scrollTop: el.scrollTop, scrollLeft: el.scrollLeft, scrollHeight: el.scrollHeight };
      }
      window.scrollBy(dx, dy);
      var se = document.scrollingElement || document.documentElement;
      return { ok: true, x: window.scrollX, y: window.scrollY, height: se ? se.scrollHeight : 0, viewport: window.innerHeight };
    }
    if (action === 'drag') {
      var to = args.to ? qs(String(args.to)) : null;
      var from = at(el), dest;
      if (to) dest = at(to);
      else dest = { x: from.x + (Number(args.x) || 0), y: from.y + (Number(args.y) || 0) };
      var targetAt = function (p) { try { return el.ownerDocument.elementFromPoint(p.x, p.y) || to || el } catch (e) { return to || el } };
      var draggable = null; try { draggable = E.closest.call(el, '[draggable="true"]') } catch (e) {}
      if (draggable) {
        var dt; try { dt = new DataTransfer() } catch (e) { dt = null }
        var drag = function (node, type, p) {
          var init = { bubbles: true, cancelable: true, composed: true, clientX: p.x, clientY: p.y, view: winOf(node) };
          var ev; try { ev = new DragEvent(type, Object.assign({ dataTransfer: dt }, init)) } catch (e) { ev = new MouseEvent(type, init); try { Object.defineProperty(ev, 'dataTransfer', { value: dt }) } catch (e2) {} }
          node.dispatchEvent(ev); return ev;
        };
        var target = to || targetAt(dest);
        drag(draggable, 'dragstart', from);
        drag(target, 'dragenter', dest); var over = drag(target, 'dragover', dest);
        var dropped = drag(target, 'drop', dest);
        drag(draggable, 'dragend', dest);
        return { ok: true, mode: 'html-drag', accepted: over.defaultPrevented || dropped.defaultPrevented };
      }
      mouse(el, 'pointerdown', from, { buttons: 1 }); mouse(el, 'mousedown', from, { buttons: 1 });
      var steps = 8;
      for (var s = 1; s <= steps; s++) {
        var mid = { x: from.x + (dest.x - from.x) * s / steps, y: from.y + (dest.y - from.y) * s / steps };
        var under = targetAt(mid);
        mouse(under, 'pointermove', mid, { buttons: 1 }); mouse(under, 'mousemove', mid, { buttons: 1 });
      }
      var end = to || targetAt(dest);
      mouse(end, 'pointerup', dest); mouse(end, 'mouseup', dest);
      return { ok: true, mode: 'pointer-drag' };
    }
    return { ok: false, reason: 'unknown action ' + action };
    })()
    """#

    /// Files for a page, the way Playwright's setInputFiles hands them over: real
    /// File objects put on an <input type=file> (or dropped on a drop zone), with
    /// the input and change events a site listens for. The bytes come from the app.
    public static let files = "/*td:files*/(function () {\n" + preamble + #"""
    var args = /*__DECK_ARGS__*/null || {};
    var el = qs(typeof args.selector === 'string' ? args.selector : '');
    if (!el) return { ok: false, reason: 'no element matched that selector' };
    if (args.mainDocumentOnly && el.ownerDocument !== document) return { ok: false, reason: 'uploading into another frame requires its own permission' };
    var list = [];
    try {
      (args.files || []).forEach(function (f) {
        var bin = atob(String(f.data || '')), bytes = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        list.push(new File([bytes], String(f.name || 'file'), { type: String(f.type || ''), lastModified: Number(f.lastModified) || Date.now() }));
      });
    } catch (e) { return { ok: false, reason: 'the files could not be made in the page: ' + e.message } }
    var dt; try { dt = new DataTransfer(); list.forEach(function (f) { dt.items.add(f) }) } catch (e) { return { ok: false, reason: 'this page cannot take files from a script' } }
    var isInput = tagOf(el) === 'input' && typeOf(el) === 'file';
    if (isInput && args.mode !== 'drop') {
      if (list.length > 1 && !el.multiple) return { ok: false, reason: 'that file field takes one file, not ' + list.length };
      try { el.files = dt.files } catch (e) { return { ok: false, reason: 'the file field refused the files: ' + e.message } }
      try { el.dispatchEvent(new Event('input', { bubbles: true, composed: true })) } catch (e) {}
      try { el.dispatchEvent(new Event('change', { bubbles: true })) } catch (e) {}
      var have = el.files ? el.files.length : 0;
      return { ok: have === list.length, via: 'input', count: have };
    }
    var p = center(el);
    var send = function (type) {
      var init = { bubbles: true, cancelable: true, composed: true, clientX: p.x, clientY: p.y, view: winOf(el) };
      var ev; try { ev = new DragEvent(type, Object.assign({ dataTransfer: dt }, init)) } catch (e) { ev = new MouseEvent(type, init); try { Object.defineProperty(ev, 'dataTransfer', { value: dt }) } catch (e2) {} }
      el.dispatchEvent(ev); return ev;
    };
    send('dragenter'); var over = send('dragover'); var drop = send('drop');
    return { ok: true, via: 'drop', count: list.length, accepted: over.defaultPrevented || drop.defaultPrevented };
    })()
    """#

    /// Read modes: the accessibility tree (roles, names, states, refs), every
    /// link, every table, cleaned HTML, every match of a selector, structured rows,
    /// and the page's frames. Secret field values never leave the page.
    public static let readMode = "/*td:readMode*/(function () {\n" + preamble + #"""
    var args = /*__DECK_ARGS__*/null || {};
    var mode = String(args.mode || '');
    var limit = Math.max(1, Math.min(Number(args.limit) || 200, 5000));
    var scope = document;
    if (args.selector && mode !== 'matches' && mode !== 'extract') {
      var picked = qs(String(args.selector));
      if (!picked) return { found: false };
      scope = picked;
    }
    var base = { found: true, url: String(location.href), title: String(document.title || '') };
    var safeValue = function (el) { if (isSecret(el)) return null; try { return typeof el.value === 'string' ? el.value.slice(0, 200) : null } catch (e) { return null } };
    var safeHTML = function (root, outer) {
      var copy = root.cloneNode(true), originals = [root].concat(Array.from(root.querySelectorAll('*'))), clones = [copy].concat(Array.from(copy.querySelectorAll('*')));
      for (var h = 0; h < originals.length; h++) {
        if (isSecret(originals[h])) { clones[h].removeAttribute('value'); if (tagOf(clones[h]) === 'textarea') clones[h].textContent = '' }
      }
      var drop = copy.querySelectorAll('script,style,noscript'); for (var x = 0; x < drop.length; x++) drop[x].remove();
      return String(outer ? copy.outerHTML || '' : copy.innerHTML || '');
    };
    var abs = function (el, name) {
      try { if ((name === 'href' || name === 'src') && typeof el[name] === 'string' && el[name]) return el[name] } catch (e) {}
      return attr(el, name);
    };
    if (mode === 'accessibility') {
      var lines = [], truncated = false, refs = 0;
      var INTERACTIVE = { button: 1, link: 1, textbox: 1, searchbox: 1, combobox: 1, checkbox: 1, radio: 1, switch: 1, slider: 1, spinbutton: 1,
        tab: 1, menuitem: 1, menuitemcheckbox: 1, menuitemradio: 1, option: 1, listbox: 1, treeitem: 1 };
      var hidden = function (el) {
        if (attr(el, 'aria-hidden') === 'true' || el.hidden === true) return true;
        var s = styleOf(el); return !!s && (s.display === 'none' || s.visibility === 'hidden');
      };
      var quote = function (s) { s = norm(s); if (s.length > 100) s = s.slice(0, 100) + '…'; return '"' + s.replace(/"/g, '\\"') + '"' };
      var emit = function (depth, textLine) { if (lines.length >= limit) { truncated = true; return false } lines.push(new Array(depth + 1).join('  ') + '- ' + textLine); return true };
      var childNodes = function (el) {
        if (el.shadowRoot) return Array.prototype.slice.call(el.shadowRoot.childNodes);
        if (tagOf(el) === 'slot') { try { var assigned = el.assignedNodes({ flatten: true }); if (assigned.length) return Array.prototype.slice.call(assigned) } catch (e) {} }
        if (tagOf(el) === 'iframe' || tagOf(el) === 'frame') { var d = null; try { d = el.contentDocument } catch (e) {} return d && d.body ? [d.body] : [] }
        return Array.prototype.slice.call(el.childNodes);
      };
      var walk = function (node, depth, quietText) {
        if (truncated) return;
        if (node.nodeType === 3) {
          if (quietText) return;
          var t = norm(node.nodeValue); if (t) emit(depth, 'text: ' + quote(t));
          return;
        }
        if (node.nodeType !== 1) return;
        var el = node, tg = tagOf(el);
        if (tg === 'script' || tg === 'style' || tg === 'noscript' || tg === 'template' || tg === 'head') return;
        if (hidden(el)) return;
        var role = roleOf(el);
        if (role && role !== 'presentation' && role !== 'none' && role !== 'generic') {
          var name = nameOf(el, role), st = states(el, role), bits = [];
          for (var k in st) bits.push(st[k] === true ? k : k + '=' + st[k]);
          var head = role + (name ? ' ' + quote(name) : '') + (bits.length ? ' [' + bits.join('] [') + ']' : '');
          if (INTERACTIVE[role] || tg === 'iframe') { head += ' [ref=' + refFor(el) + ']'; refs++ }
          var val = (role === 'textbox' || role === 'searchbox' || role === 'combobox' || role === 'spinbutton' || role === 'slider') ? safeValue(el) : null;
          if (role === 'combobox' && tg === 'select') { try { val = el.options[el.selectedIndex] ? line(el.options[el.selectedIndex]) : '' } catch (e) {} }
          if (val) head += ': ' + quote(val);
          if (isSecret(el) && tg === 'input') head += ' [secret]';
          if (!emit(depth, head)) return;
          if (tg === 'select' || tg === 'textarea' || tg === 'input') return;
          var quiet = !!FROM_CONTENT[role] && !!name;
          var kids = childNodes(el);
          for (var i = 0; i < kids.length; i++) walk(kids[i], depth + 1, quiet);
          return;
        }
        if (tg === 'iframe' || tg === 'frame') { if (!emit(depth, 'iframe [ref=' + refFor(el) + ']' + (attr(el, 'src') ? ' ' + quote(abs(el, 'src')) : ''))) return }
        var list = childNodes(el);
        for (var j = 0; j < list.length; j++) walk(list[j], depth + ((tg === 'iframe' || tg === 'frame') ? 1 : 0), quietText);
      };
      walk(scope.nodeType === 9 ? (scope.body || scope.documentElement) : scope, 0, false);
      return Object.assign(base, { snapshot: lines.join('\n'), lines: lines.length, refs: refs, truncated: truncated });
    }
    if (mode === 'links') {
      var match = args.match ? String(args.match).toLowerCase() : '';
      var links = [], seenLinks = {}, totalLinks = 0;
      var anchors = scope === document ? deepQsa('a[href],area[href]') : Array.prototype.slice.call(scope.querySelectorAll('a[href],area[href]'));
      for (var a = 0; a < anchors.length; a++) {
        var an = anchors[a], href = abs(an, 'href'), label = line(an) || attr(an, 'aria-label') || attr(an, 'title');
        if (!href || /^javascript:/i.test(href)) continue;
        if (match && href.toLowerCase().indexOf(match) === -1 && label.toLowerCase().indexOf(match) === -1) continue;
        var key = href + '\u0000' + label; if (seenLinks[key]) continue; seenLinks[key] = 1;
        totalLinks++;
        if (links.length < limit) links.push({ text: label.slice(0, 200), href: href, rel: attr(an, 'rel'), target: attr(an, 'target'), visible: visible(an) });
      }
      return Object.assign(base, { links: links, count: links.length, total: totalLinks, truncated: totalLinks > links.length });
    }
    if (mode === 'tables') {
      var tables = [], found = scope === document ? deepQsa('table,[role="table"],[role="grid"],[role="treegrid"]') : [scope];
      var rowCap = Math.max(1, Math.min(Number(args.limit) || 500, 5000));
      for (var t = 0; t < found.length && tables.length < 20; t++) {
        var tb = found[t], isHtml = tagOf(tb) === 'table';
        var rows = isHtml ? Array.prototype.slice.call(tb.rows || []) : Array.prototype.slice.call(tb.querySelectorAll('[role="row"]'));
        if (!rows.length) continue;
        var cellsOf = function (row) { return Array.prototype.slice.call(isHtml ? row.cells : row.querySelectorAll('[role="cell"],[role="gridcell"],[role="columnheader"],[role="rowheader"]')) };
        var headers = [], startAt = 0;
        var firstCells = cellsOf(rows[0]);
        var headerRow = firstCells.length && firstCells.every(function (c) { return tagOf(c) === 'th' || attr(c, 'role') === 'columnheader' });
        if (headerRow || (isHtml && tb.tHead && tb.tHead.rows.length && tb.tHead.rows[0] === rows[0])) { headers = firstCells.map(line); startAt = 1 }
        var body = [];
        for (var r = startAt; r < rows.length && body.length < rowCap; r++) {
          var cells = cellsOf(rows[r]).map(function (c) {
            var input = c.querySelector ? c.querySelector('input,select,textarea') : null;
            var value = line(c);
            if (!value && input && !isSecret(input)) value = safeValue(input) || '';
            return value;
          });
          if (cells.some(function (v) { return v !== '' })) body.push(cells);
        }
        var cap = isHtml && tb.caption ? line(tb.caption) : (attr(tb, 'aria-label') || '');
        tables.push({ index: t, caption: cap, selector: refSelector(tb), headers: headers, rows: body, rowCount: rows.length - startAt, truncated: rows.length - startAt > body.length });
      }
      return Object.assign(base, { tables: tables, count: tables.length, total: found.length });
    }
    if (mode === 'html') {
      var maxChars = Math.max(1000, Math.min(Number(args.maxChars) || 100000, 1000000));
      var root = scope.nodeType === 9 ? scope.documentElement : scope;
      var html = safeHTML(root, true);
      return Object.assign(base, { html: html.slice(0, maxChars), chars: html.length, truncated: html.length > maxChars });
    }
    if (mode === 'matches') {
      var nodes;
      try { nodes = resolveAll(String(args.selector || '')) } catch (e) { return { found: false, invalid: true } }
      var wantAttrs = Array.isArray(args.attributes) ? args.attributes.map(String).slice(0, 20) : ['id', 'class', 'href', 'src', 'name', 'role', 'aria-label', 'title', 'alt', 'type'];
      var items = [];
      for (var n2 = 0; n2 < nodes.length && items.length < limit; n2++) {
        var node = nodes[n2], attrs = {};
        wantAttrs.forEach(function (name) { if (!(isSecret(node) && name.toLowerCase() === 'value') && node.hasAttribute && node.hasAttribute(name)) attrs[name] = String(abs(node, name)).slice(0, 500) });
        var item = { index: n2, tag: tagOf(node), text: isSecret(node) ? '' : line(node).slice(0, 300), attributes: attrs, visible: visible(node), ref: refFor(node), rect: box(node) };
        var v = tagOf(node) === 'input' || tagOf(node) === 'textarea' || tagOf(node) === 'select' ? safeValue(node) : null;
        if (v !== null) item.value = v;
        if (isSecret(node)) item.secret = true;
        items.push(item);
      }
      return Object.assign(base, { matches: items, count: items.length, total: nodes.length, truncated: nodes.length > items.length });
    }
    if (mode === 'extract') {
      var fields = args.fields && typeof args.fields === 'object' ? args.fields : null;
      var rowsSel = args.rows ? String(args.rows) : '';
      var records;
      try { records = rowsSel ? resolveAll(rowsSel) : [document.documentElement] } catch (e) { return { found: false, invalid: true } }
      var pull = function (row, spec) {
        spec = String(spec == null ? '' : spec);
        var at = spec.lastIndexOf('@'), sel = spec, attrName = '';
        if (at !== -1 && !/[\]"']/.test(spec.slice(at))) { sel = spec.slice(0, at).trim(); attrName = spec.slice(at + 1).trim() }
        var target = sel ? qs(sel, row) : row;
        if (!target) return null;
        if (isSecret(target)) return null;
        if (attrName === 'value') return safeValue(target);
        if (attrName === 'html') return safeHTML(target, false).slice(0, 5000);
        if (attrName) { var got = abs(target, attrName); return got === '' && !target.hasAttribute(attrName) ? null : got }
        var tv = tagOf(target) === 'input' || tagOf(target) === 'select' || tagOf(target) === 'textarea' ? safeValue(target) : null;
        return tv !== null ? tv : line(target);
      };
      var outRows = [];
      for (var q = 0; q < records.length && outRows.length < limit; q++) {
        var rec = records[q], obj = {};
        if (fields) { for (var key2 in fields) obj[key2] = pull(rec, fields[key2]) }
        else obj.text = line(rec).slice(0, 1000);
        outRows.push(obj);
      }
      return Object.assign(base, { rows: outRows, count: outRows.length, total: records.length, truncated: records.length > outRows.length });
    }
    if (mode === 'frames') {
      var frames = [], list2 = deepQsa('iframe,frame');
      for (var f = 0; f < list2.length && frames.length < limit; f++) {
        var fr = list2[f], doc = null; try { doc = fr.contentDocument } catch (e) {}
        frames.push({ index: f, selector: refSelector(fr), name: attr(fr, 'name'), title: attr(fr, 'title'), src: abs(fr, 'src'),
          sameOrigin: !!doc, url: doc ? String(doc.location.href) : abs(fr, 'src'), visible: visible(fr), rect: box(fr) });
      }
      return Object.assign(base, { frames: frames, count: frames.length });
    }
    return { found: false, reason: 'unknown read mode ' + mode };
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
