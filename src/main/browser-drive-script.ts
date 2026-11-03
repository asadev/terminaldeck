/**
 * The scripts the drive runs inside a page, written here and nowhere else.
 *
 * ## Why these are strings in the main process
 *
 * Because the alternative is a tool that takes an expression, and that one
 * addition is what would make every other guarantee in this feature decorative.
 * `DRIVABLE-BROWSER.md` §3.4 puts it first in the list for that reason: there
 * is no arbitrary-evaluation tool, there never will be one, and the day
 * somebody adds a sixth tool that takes a free-form string, the promise that a
 * password cannot reach an agent's transcript stops being true.
 *
 * So the only thing an agent contributes to any of this is a **CSS selector**,
 * and it arrives as a JSON string literal inside {@link ARGS_TOKEN}. A selector
 * is not code: the worst a hostile one can do is match the wrong element or
 * throw a `SyntaxError`, both of which are handled. It is never concatenated
 * into an expression.
 *
 * ## Why an isolated world
 *
 * These run through `webContents.executeJavaScriptInIsolatedWorld`, which was
 * verified on Electron 41.10.5 to do three things this needs:
 *
 *  - see the page's real DOM (`document.getElementsByTagName('input').length`
 *    answered `1` for a document with one input);
 *  - **not** see the page's globals (`typeof window.__pageOnly` answered
 *    `"undefined"` in the world while the main world answered `"number"`);
 *  - survive a navigation — the same world id ran correctly against a fresh
 *    document with no re-registration.
 *
 * The isolation is what makes the third bullet of that list matter. A page that
 * redefines `document.querySelector` to throw was tried, and the script below
 * still resolved the element, because it goes through `Document.prototype`
 * rather than through whatever the page has left on the instance. A driver that
 * can be lied to by the site it is driving is a driver whose reports are the
 * site's opinion.
 *
 * ## The one thing these scripts must never return
 *
 * The value of a secret field. Not redacted downstream — never produced. See
 * {@link SECRET_TEST}; every path that could carry a value checks it first, and
 * `browser-driver.ts` checks it again on the way out, because the day one of
 * these strings is edited by somebody in a hurry is the day the second check
 * earns its keep.
 */

/* ------------------------------------------------------------ the wiring -- */

/**
 * Where the arguments are substituted. One interpolation point, one JSON literal.
 *
 * Exported alongside {@link PREAMBLE}, so that `browser-store-script.ts` writes
 * the same token rather than a second spelling of it. A hard-coded copy in the
 * other file would look identical and stop being identical the day this one is
 * renamed — and the failure would be a script that silently received `null` for
 * its arguments and returned an empty page.
 */
export const ARGS_TOKEN = '/*__DECK_ARGS__*/null'

/**
 * Put the arguments into a script.
 *
 * `JSON.stringify` twice over: once for the value, and the result is a JSON
 * literal, which is a subset of JavaScript expression syntax. The one character
 * that is not — `U+2028` and `U+2029` are legal in JSON strings and are line
 * terminators in JavaScript — is escaped explicitly, because a selector
 * containing one would otherwise end the statement early and turn a string into
 * a syntax error at best.
 */
export function withArgs(script: string, args: unknown): string {
  const json = JSON.stringify(args ?? null)
    .replace(/\u2028/g, '\\u2028')
    .replace(/\u2029/g, '\\u2029')
  // A function replacement, not a string one. `String.replace` reads the dollar
  // patterns out of a *string* replacement, and a selector is agent-supplied text
  // that may contain any of them — which would splice the matched token back into
  // the JSON and produce a syntax error at best.
  return script.replace(ARGS_TOKEN, () => json)
}

/* ---------------------------------------------------------- the preamble -- */

/**
 * Helpers every script below shares.
 *
 * Written once as a string and concatenated, rather than repeated, because the
 * secret predicate in particular must be *one* definition. Two copies of a rule
 * about passwords is one copy that gets updated.
 *
 * Note the pervasive use of `Element.prototype` / `Document.prototype` rather
 * than the instance methods. The page owns its own objects and may have
 * replaced any of them; a driver that called `el.getBoundingClientRect()`
 * directly would be reading a number the site chose.
 *
 * Exported since 2026-08-21, for `browser-store-script.ts`, and for the reason
 * the paragraph above already gives: `isSecret` must be **one** definition. A
 * store tool's engine reads text out of a page, so it needs the same predicate,
 * and a second copy of a rule about passwords is one copy that gets updated. The
 * store's script is one of the scripts this comment is about in every way except
 * which file it is typed in.
 */
export const PREAMBLE = `
var D = Document.prototype, E = Element.prototype, H = HTMLElement.prototype;
var qs = function (sel) { try { return D.querySelector.call(document, sel) } catch (e) { return null } };
var qsa = function (sel) { try { return Array.prototype.slice.call(D.querySelectorAll.call(document, sel)) } catch (e) { return [] } };
var attr = function (el, name) { try { var v = E.getAttribute.call(el, name); return typeof v === 'string' ? v : '' } catch (e) { return '' } };
var box = function (el) { try { var r = E.getBoundingClientRect.call(el); return { x: r.x, y: r.y, width: r.width, height: r.height } } catch (e) { return null } };
/*
 * The text a person would actually read.
 *
 * \`innerText\` and not \`textContent\`, and the difference is not cosmetic. It
 * was measured on example.com: \`textContent\` answered "Example DomainThis
 * domain is for use in documentation examples…", running the heading straight
 * into the paragraph, and on a search-results page it returned the contents of
 * every inline \`<script>\` — a model reading that is reading minified
 * JavaScript and calling it the page. \`innerText\` is layout-aware: it skips
 * script, style and anything not rendered, and it puts a break where the layout
 * puts one.
 *
 * The cost is that it forces layout, which is why it is not used for anything
 * that runs inside the actionability loop. \`textContent\` remains the fallback,
 * because SVG and XML elements do not have \`innerText\` at all.
 */
var text = function (el) {
  try {
    var t = typeof el.innerText === 'string' && el.innerText !== '' ? el.innerText : el.textContent;
    return typeof t === 'string' ? t.replace(/[ \\t\\u00a0]+/g, ' ').replace(/\\n{3,}/g, '\\n\\n').trim() : '';
  } catch (e) { return '' }
};
var line = function (el) { return text(el).replace(/\\s+/g, ' ').trim() };
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
 *    with his name. \`browser-steps.ts\` already treats it as secret for
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
  try { return window.CSS && typeof window.CSS.escape === 'function' ? window.CSS.escape(v) : v.replace(/[^a-zA-Z0-9_-]/g, '\\\\$&') }
  catch (e) { return v }
};
var selectorFor = function (el) {
  var hooks = ['data-testid', 'data-test-id', 'data-test', 'data-cy'];
  for (var i = 0; i < hooks.length; i++) {
    var v = attr(el, hooks[i]);
    if (v) { var s = '[' + hooks[i] + '="' + v.replace(/["\\\\]/g, '\\\\$&') + '"]'; if (uniq(s)) return s }
  }
  var id = attr(el, 'id');
  if (id) { var s2 = '#' + cssEscape(id); if (uniq(s2)) return s2 }
  var name = attr(el, 'name');
  if (name) { var s3 = tagOf(el) + '[name="' + name.replace(/["\\\\]/g, '\\\\$&') + '"]'; if (uniq(s3)) return s3 }
  var aria = attr(el, 'aria-label');
  if (aria) { var s4 = tagOf(el) + '[aria-label="' + aria.replace(/["\\\\]/g, '\\\\$&') + '"]'; if (uniq(s4)) return s4 }
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
 * The vocabulary is \`selector.ts\`'s \`LabelSource\` plus two the desktop's own
 * capture cannot produce because it starts from a click rather than from a
 * field: \`name\`, and \`label\` for a \`<label for="…">\` somewhere else in the
 * document. \`value\` is in that list and deliberately never returned here —
 * see the note below on why a field never wears its own contents.
 */
var labelWithSource = function (el) {
  var t = tagOf(el);
  if (t === 'input' || t === 'textarea' || t === 'select') {
    // Never the element's own text or value for a field. A <select>'s
    // textContent is all of its options concatenated, and an input's value is
    // whatever he last typed — \`browser-steps.ts\` records both mistakes.
    var order = ['aria-label', 'placeholder', 'title', 'name'];
    for (var i = 0; i < order.length; i++) {
      var named = attr(el, order[i]);
      if (named) return { label: named, source: order[i] };
    }
    var id = attr(el, 'id');
    if (id) {
      var lab = qs('label[for="' + id.replace(/["\\\\]/g, '\\\\$&') + '"]');
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
`

/* ----------------------------------------------------------- the scripts -- */

/**
 * What is on this page — what it says, and what can be acted on.
 *
 * The compact outline is what lets a model act without spending a screenshot,
 * which matters more than it sounds: an image is thousands of tokens and it
 * does not carry a selector, so a model given only pictures has to guess at
 * names. Role, label and selector is the whole of what an action needs.
 *
 * ## Why the page's own words are in here as well
 *
 * They were not, and the tool that returns this is described as *"what is on
 * the page"*, which it was not delivering: an outline of the controls says what
 * you can press and nothing at all about what the page is *saying*. Watched on
 * 2026-08-18, asked in words to read a form's result line, the copilot spent
 * four calls guessing selectors — `#result`, `p`, `body`, `p:last-of-type` —
 * because the only route to any text was to name an element it had not been
 * shown. On a page that is mostly prose, which is most pages, the honest
 * summary of the old outline was "there is a link called Learn more".
 *
 * It is also the concrete half of what Asad asked for after finding the copilot
 * could not use the browser — *"it should know what I am looking at"*. A page
 * you can only click is not a page you can talk about.
 *
 * So the script returns `text` as well: `innerText` of the body, which is the
 * *rendered* text — it honours `display:none`, collapses runs of whitespace the
 * way the layout does, and puts line breaks where the page puts them.
 * `textContent` was the alternative and is wrong for this: it returns the
 * contents of every `<script>` and `<style>` and every hidden template on the
 * page, which is both enormous and misleading.
 *
 * Bounded by `textLimit`, cut at the *end* and flagged, because the top of a
 * document is its heading and its lede while the bottom is the footer.
 *
 * `secret: true` fields are listed **with no value**, deliberately. The agent
 * has to know the password box is there — that is how it knows to call
 * `browser.handover` — and it must never learn what is in it. The text above is
 * not a hole in that: a password field's *value* is never rendered text on any
 * page, and a page that printed one into its own body has already disclosed it
 * to anyone looking at the screen.
 */
export const OUTLINE_SCRIPT = `(function () {
${PREAMBLE}
var args = ${ARGS_TOKEN} || {};
var limit = typeof args.limit === 'number' ? args.limit : 60;
var textLimit = typeof args.textLimit === 'number' ? args.textLimit : 4000;
var sel = 'a[href],button,input,select,textarea,summary,[role="button"],[role="link"],[role="checkbox"],[role="tab"],[contenteditable="true"]';
var out = [];
var seen = 0;
var all = qsa(sel);
for (var i = 0; i < all.length && out.length < limit; i++) {
  var el = all[i];
  if (typeOf(el) === 'hidden') continue;
  if (!visible(el)) continue;
  seen++;
  var t = tagOf(el);
  var kind = t === 'a' ? 'link' : (t === 'input' || t === 'textarea' || t === 'select') ? 'field' : 'button';
  var entry = {
    kind: kind,
    tag: t,
    type: typeOf(el),
    label: labelFor(el),
    selector: selectorFor(el),
    secret: isSecret(el),
    enabled: enabled(el),
  };
  if (kind === 'field' && !entry.secret) {
    // A field's current contents, so a model can tell an empty form from a
    // filled one. Never for a secret field — see \`isSecret\`.
    try { entry.value = typeof el.value === 'string' ? el.value.slice(0, 120) : '' } catch (e) { entry.value = '' }
  }
  out.push(entry);
}
var body = document.body;
var full = '';
try { full = body && typeof body.innerText === 'string' ? body.innerText : '' } catch (e) { full = '' }
full = full.replace(/[ \\t]+/g, ' ').replace(/\\n{3,}/g, '\\n\\n').trim();
return {
  url: String(location.href),
  title: String(document.title || ''),
  text: full.length > textLimit ? full.slice(0, textLimit) : full,
  textTruncated: full.length > textLimit,
  elements: out,
  matched: seen,
  truncated: seen > out.length,
};
})()`

/**
 * Everything the driver needs to know about one selector before it acts.
 *
 * This is the observation half of the actionability loop in
 * `browser-driver.ts`. It returns *facts*, never a verdict — whether those
 * facts add up to "safe to click" is decided in the main process, where it can
 * be tested, and not in a page the site controls.
 *
 * `hit` is the one that stops the classic failure. A button can be attached,
 * visible, enabled and the wrong thing to click, because a spinner overlay or a
 * cookie banner is painted over it — so the script asks the document what is
 * actually at the point the click would land, and reports whether that node is
 * the target or inside it. That single check is the difference between "clicked
 * Sign in" and "clicked the modal backdrop and reported success".
 */
export const PROBE_SCRIPT = `(function () {
${PREAMBLE}
var args = ${ARGS_TOKEN} || {};
var sel = typeof args.selector === 'string' ? args.selector : '';
/*
 * A selector that does not parse is a different answer from one that matches
 * nothing, and the driver needs both. "No such element" is worth waiting for —
 * the page may still be rendering it — and "that is not a selector" never
 * becomes true however long anybody waits, so retrying it is a whole tool
 * timeout spent on a typo.
 */
var invalid = false;
try { D.querySelectorAll.call(document, sel) } catch (e) { invalid = true }
var nodes = invalid ? [] : qsa(sel);
if (nodes.length === 0) return { found: false, count: 0, invalid: invalid };
var el = nodes[0];
var r = box(el);
var hitId = null, hit = false;
if (r && r.width > 0 && r.height > 0) {
  var cx = r.x + r.width / 2, cy = r.y + r.height / 2;
  try {
    var at = D.elementFromPoint.call(document, cx, cy);
    hit = at === el || (at !== null && typeof E.contains === 'function' && (E.contains.call(el, at) || E.contains.call(at, el)));
    hitId = at ? tagOf(at) + (attr(at, 'id') ? '#' + attr(at, 'id') : '') : null;
  } catch (e) { hit = false }
}
return {
  found: true,
  count: nodes.length,
  tag: tagOf(el),
  type: typeOf(el),
  label: labelFor(el),
  secret: isSecret(el),
  visible: visible(el),
  enabled: enabled(el),
  editable: (function () { var t = tagOf(el); return t === 'input' || t === 'textarea' || attr(el, 'contenteditable') === 'true' })(),
  checked: el.checked === true,
  rect: r,
  hit: hit,
  hitNode: hitId,
  scrollX: window.scrollX || 0,
  scrollY: window.scrollY || 0,
  viewport: { width: window.innerWidth || 0, height: window.innerHeight || 0 },
  readyState: String(document.readyState || ''),
};
})()`

/**
 * Put the element where a click can reach it, and say where that is.
 *
 * Separate from the probe because it *changes* the page — scrolling is a
 * mutation of scroll position, and a function called `probe` that scrolled
 * would be a function whose name lies. The driver scrolls once and then
 * re-probes, so the coordinates it clicks at are read after the movement has
 * settled rather than before it started.
 */
export const SCROLL_SCRIPT = `(function () {
${PREAMBLE}
var args = ${ARGS_TOKEN} || {};
var el = qs(typeof args.selector === 'string' ? args.selector : '');
if (!el) return { found: false };
try { H.scrollIntoView.call(el, { block: 'center', inline: 'center', behavior: 'instant' }) }
catch (e) { try { H.scrollIntoView.call(el, true) } catch (e2) { /* a node with no scroll parent is already where it is going to be. */ } }
return { found: true, rect: box(el) };
})()`

/**
 * Text, either of one element or of the page.
 *
 * Clamped inside the page rather than only in the main process, because the
 * string crosses a process boundary before anything can trim it and a document
 * with a megabyte of text would be a megabyte on the wire either way.
 */
export const TEXT_SCRIPT = `(function () {
${PREAMBLE}
var args = ${ARGS_TOKEN} || {};
var sel = typeof args.selector === 'string' && args.selector !== '' ? args.selector : null;
var limit = typeof args.limit === 'number' ? args.limit : 4000;
var el = sel === null ? document.body : qs(sel);
if (!el) return { found: false, text: '' };
if (isSecret(el)) return { found: true, secret: true, text: '' };
var t = text(el);
return {
  found: true,
  secret: false,
  text: t.slice(0, limit),
  truncated: t.length > limit,
  url: String(location.href),
  title: String(document.title || ''),
};
})()`

/**
 * Choose an option in a `<select>`.
 *
 * The one step that sets a value rather than dispatching input, and it is worth
 * saying why that is not a shortcut taken everywhere else. A native select
 * opens an **OS-level popup** that is not part of the page at all, so there are
 * no coordinates to click and no DOM node to hit-test — a driver that tried to
 * click through one would be clicking at a menu the renderer cannot see. Every
 * other verb goes through real input events, because for every other verb the
 * thing being clicked is in the page.
 *
 * Matching is by value first and visible text second, because a model reading
 * an outline sees the text and a model reading the HTML sees the value, and
 * both are reasonable things for it to pass. The `change` and `input` events
 * are dispatched explicitly: assigning `selectedIndex` fires neither, and a
 * framework-bound form that never hears `change` will submit the old value
 * while the box on screen shows the new one.
 */
export const SELECT_SCRIPT = `(function () {
${PREAMBLE}
var args = ${ARGS_TOKEN} || {};
var el = qs(typeof args.selector === 'string' ? args.selector : '');
if (!el) return { ok: false, reason: 'no element matched that selector' };
if (tagOf(el) !== 'select') return { ok: false, reason: 'that element is not a dropdown' };
var wanted = String(args.value == null ? '' : args.value);
var options = Array.prototype.slice.call(el.options || []);
var found = -1;
for (var i = 0; i < options.length; i++) { if (String(options[i].value) === wanted) { found = i; break } }
if (found === -1) {
  for (var j = 0; j < options.length; j++) { if (line(options[j]) === wanted) { found = j; break } }
}
if (found === -1) {
  var names = [];
  for (var k = 0; k < options.length && k < 20; k++) names.push(line(options[k]) || String(options[k].value));
  return { ok: false, reason: 'no such option. The ones there are: ' + names.join(', ') };
}
el.selectedIndex = found;
try { el.dispatchEvent(new Event('input', { bubbles: true })) } catch (e) { /* an ancient page with no Event constructor still gets the change below. */ }
try { el.dispatchEvent(new Event('change', { bubbles: true })) } catch (e) { /* nothing else to try; the value is set either way. */ }
return { ok: true, value: String(el.value) };
})()`

/**
 * Where every secret field is, in CSS pixels, so a screenshot can be painted
 * over before it exists anywhere an agent could read it.
 *
 * This runs even though the agent is shut out of the page entirely during a
 * handover, because the leak it closes is not the handover — it is the ordinary
 * screenshot afterwards. A password manager leaves the dots in place, a
 * one-time-code field shows its digits in clear, and a "show password" toggle
 * shows the password. All three survive the person handing the page back.
 */
export const SECRET_RECTS_SCRIPT = `(function () {
${PREAMBLE}
var out = [];
var all = qsa('input,textarea');
for (var i = 0; i < all.length; i++) {
  var el = all[i];
  if (!isSecret(el)) continue;
  if (!visible(el)) continue;
  var r = box(el);
  if (r) out.push(r);
}
return {
  rects: out,
  /*
   * The CSS viewport, which is what the rectangles above are measured in.
   *
   * Reported because a captured image is in DEVICE pixels and these are not,
   * and the ratio between them is the whole of whether a mask lands on the
   * password field or a hundred pixels above it. Read here rather than
   * inferred from the image, and read as \`innerWidth\` rather than as
   * \`devicePixelRatio\` — a page can define its own \`devicePixelRatio\`, and
   * this script runs in an isolated world whose \`window\` the page does not
   * own, so the browser is what answers.
   */
  viewport: { width: window.innerWidth || 0, height: window.innerHeight || 0 },
};
})()`

/**
 * How many ancestors a pick may walk up before it stops.
 *
 * The same sixty-four `selector.ts` bounds its path at and the same number the
 * phone's own inspector uses (`MAX_DEPTH` in `InspectScript.swift`). Deep DOMs
 * exist; unbounded ones are an attack, and a walk with no ceiling is a loop a
 * page can lengthen at will.
 *
 * Spelled here **and** as `MAX_PICK_UP` in `remote/protocol.ts`, on purpose and
 * not by oversight: this one is a ceiling on a walk inside a page, that one is a
 * refusal at the door for a number a client sent, and the wire file imports
 * nothing from `src/main` so that it stays readable as the whole language on its
 * own. `browser-driver.test.ts` asserts the two are the same number, which is
 * the guard that makes the duplication safe rather than the comment.
 */
export const MAX_PICK_ANCESTORS = 64

/**
 * What is at one point on the page, and what encloses it.
 *
 * ## What this is for
 *
 * Tapping one thing on a page and telling an agent *change this* already
 * existed twice — once on the desktop, where a click in the embedded browser
 * goes through `browser-preload.ts` into `selector.ts`, and once on the phone,
 * where a tap in the tunnelled page goes through `InspectScript.swift` into the
 * same rules rewritten in Swift. Both start from a **click on a real DOM the
 * client owns**. Neither could work on a window the phone is only *watching*:
 * over a screencast the phone has pixels, and pixels have no elements in them.
 * Asad, on that gap:
 *
 * > *"in the page, if I click on something, I don't have something to, some
 * > option to specifically inspect one piece. Here I also don't have. And then
 * > in the own, in the own this phone page, we have it, but we don't have the
 * > rest of the options here… So everything should, all of them should be
 * > identical, and all of them should have all the options."*
 *
 * So the hit test moves to where the DOM actually is. The phone sends a point
 * and this answers with the element under it, exactly as the other two do, using
 * the *same* selector rule, the same label rule and the same secret rule that
 * are already in {@link PREAMBLE} — because the three inspectors feed one sheet
 * and a fourth opinion about what a stable selector is would show up as the same
 * element described two different ways on two screens.
 *
 * ## Why the point is in document coordinates
 *
 * `browser.frame` carries `scrollX`/`scrollY` beside every screencast frame, so
 * the viewer can turn a tap into a point on the *document* rather than on the
 * picture. Document coordinates are the one space that survives the round trip:
 * the page can scroll between the frame being drawn and the tap arriving, and a
 * viewport point measured against an old frame would then hit whatever has
 * scrolled into that spot. This converts with the page's **own live scroll**,
 * read here rather than trusted from the caller.
 *
 * When the point is no longer on screen at all the answer is \`moved\`, not a
 * guess and not a scroll. Scrolling would move the page under somebody who is
 * watching it — `SCROLL_SCRIPT` is a separate script for exactly that reason —
 * and guessing would report an element nobody pointed at.
 *
 * ## Walking up, which is the whole of Wider/Narrower
 *
 * A fingertip is not a mouse pointer: a tap lands on whichever wrapper happens
 * to be on top, and there is no second, more precise gesture to offer. So the
 * correction is a control — `up` ancestors from the element actually hit — and
 * the answer says how far up it went (\`depth\`) and how much further it could
 * go (\`maxUp\`), which is what lets the sheet grey out Wider at the top of the
 * document instead of stepping onto nothing.
 *
 * ## What it never returns
 *
 * A field's value, secret or not. There is no value in this answer at all: the
 * label of a password box is its label, and its contents are not something a
 * point on a screen has any business fetching.
 */
export const PICK_SCRIPT = `(function () {
${PREAMBLE}
var args = ${ARGS_TOKEN} || {};
var MAX_UP = ${MAX_PICK_ANCESTORS};
var num = function (v) { return typeof v === 'number' && isFinite(v) ? v : 0 };
var x = num(args.x), y = num(args.y);
var want = Math.floor(num(args.up));
if (!(want > 0)) want = 0;
if (want > MAX_UP) want = MAX_UP;

/*
 * Document point to viewport point, with the scroll the page has right now.
 * Read from the isolated world's own \`window\`, which the page cannot redefine.
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
 * Collected before anything is measured, because \`maxUp\` is a fact about the
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
})()`

/**
 * The predicate, restated in TypeScript for the main process's own check.
 *
 * Deliberately a second implementation of the same rule rather than a shared
 * one, which is the opposite of what this codebase normally does. The reason is
 * that the two run on opposite sides of a trust boundary: the one above runs
 * inside a page and could in principle be defeated by something nobody has
 * thought of, and this one runs on a value that has already crossed back.
 * `browser-driver.ts` refuses to type into a field either of them calls secret,
 * so defeating one is not enough.
 */
export const SECRET_TEST = {
  types: ['password', 'file'],
  autocomplete: /(current-password|new-password|one-time-code|cc-number|cc-csc)/i,
}

export function looksSecret(field: { type?: unknown; autocomplete?: unknown }): boolean {
  const type = typeof field.type === 'string' ? field.type.trim().toLowerCase() : ''
  if (SECRET_TEST.types.includes(type)) return true
  const auto = typeof field.autocomplete === 'string' ? field.autocomplete : ''
  return SECRET_TEST.autocomplete.test(auto)
}
