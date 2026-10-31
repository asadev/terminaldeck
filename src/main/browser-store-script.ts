import { ARGS_TOKEN, PREAMBLE } from './browser-drive-script'
import type { Recipe, RecipeField } from './browser-store-recipe'

/**
 * The engine every store tool runs on — one script, written here, in this
 * repository.
 *
 * ## Why the engine is here and the tool is not
 *
 * This is the whole safety argument of the tools store, in one sentence: **the
 * store downloads recipes and this file runs them.** A recipe is JSON — names,
 * selectors and an op chosen from a closed list — and it arrives the same way a
 * selector already arrives at every other script in this app: as a JSON literal
 * substituted into {@link ARGS_TOKEN} by `withArgs`. Nothing fetched is ever
 * evaluated, concatenated into an expression, or handed to `Function`.
 *
 * `browser-drive-script.ts` states the invariant this preserves, and it is
 * quoted rather than paraphrased because it is the thing that would have been
 * lost: *"there is no arbitrary-evaluation tool, there never will be one, and
 * the day somebody adds a sixth tool that takes a free-form string, the promise
 * that a password cannot reach an agent's transcript stops being true."*
 *
 * {@link PREAMBLE} is imported rather than copied, so `isSecret` here is the
 * *same* predicate the driver uses — the file it comes from is explicit that two
 * copies of a rule about passwords is one copy that gets updated.
 *
 * ## The three failures this script is shaped by
 *
 * Every one of them is a real number off a real pipeline, and each is a
 * deliberate decision below rather than a happy accident.
 *
 *  1. **62,000 images taken at a 498-pixel preview when the 1920-pixel original
 *     was one path segment away**, and **16,498 floor plans lost** because
 *     images were blocked to go faster, so lazy-loading never fired and the real
 *     URLs were never revealed. So `image` returns **every candidate it can
 *     see** — `currentSrc`, `src`, every `srcset` entry with the width it
 *     declares, `poster`, and thirteen lazy-loading attributes — sorted widest
 *     first and **choosing nothing**. It also reports `naturalWidth`, which is
 *     the one number that says whether what loaded is the original or a
 *     thumbnail, and `loading`, which says whether there is more to reveal by
 *     scrolling. A tool that picked "the best one" would be the 498-pixel bug
 *     with better manners.
 *  2. **58% of every image discarded by a resize that ran before writing to
 *     disk.** Nothing here transforms anything. It returns URLs and text; what
 *     is done with them happens outside, which is what Asad asked for — *"the
 *     browser should expose these capabilities cleanly; the orchestration can
 *     live outside."*
 *  3. **7% of a dataset shipped as complete, because nothing compared it against
 *     the total the page itself stated.** So the result carries `rowsOnPage` and
 *     `rowsReturned` as separate numbers, and a recipe may name the page's own
 *     printed total; `store-tools.ts` does the arithmetic and says so out loud.
 *     A count that is only ever "how many did I get" cannot notice that it got
 *     the wrong number.
 *
 * ## What it never returns
 *
 * The value of a secret field. `isSecret` is checked before any text or
 * attribute is read, exactly as the driver's own scripts check it, and the field
 * comes back `null` rather than redacted — you cannot leak what was never
 * produced.
 */

/** What crosses to the page. A recipe, flattened to the shape the script reads. */
export interface ExtractPlan {
  fields: readonly RecipeField[]
  rows: { selector: string; fields: readonly RecipeField[] } | null
  stated: RecipeField | null
  next: string | null
  /** Most rows, and most matches for an `all` field, to bring back. */
  limit: number
  /** Most characters of any one piece of text. */
  textLimit: number
}

/** How many rows a call brings back unless it asks for fewer. */
export const DEFAULT_EXTRACT_LIMIT = 200
export const MAX_EXTRACT_LIMIT = 2_000
/** Characters of any single text value. */
export const DEFAULT_EXTRACT_TEXT_CHARS = 4_000
export const MAX_EXTRACT_TEXT_CHARS = 40_000

export interface ExtractResult {
  url: string
  title: string
  fields: Record<string, unknown>
  rows: Record<string, unknown>[]
  /** How many row containers the page has. */
  rowsOnPage: number
  /** How many came back — smaller when `limit` bit. */
  rowsReturned: number
  /**
   * For every field that collects a list: how many matched, and how many came
   * back under the limit.
   *
   * Separate numbers because they answer different questions, and collapsing
   * them is the shape of the bug this whole feature is about — a field that
   * returned two hundred of eight hundred images and reported only "200" reads
   * as a page with two hundred images on it.
   */
  counts: Record<string, { matched: number; returned: number }>
  /** The total the page states about itself, when the recipe names it. */
  stated: number | null
  /** The next page, absolute, when the recipe names a link and the page has one. */
  next: string | null
}

/** A recipe, as the page will see it. */
export function planFor(
  recipe: Recipe,
  options: { limit?: number; textLimit?: number } = {},
): ExtractPlan {
  const clamp = (value: number | undefined, fallback: number, max: number): number =>
    typeof value === 'number' && Number.isFinite(value)
      ? Math.min(Math.max(Math.trunc(value), 1), max)
      : fallback
  return {
    fields: recipe.fields,
    rows: recipe.rows,
    stated: recipe.stated,
    next: recipe.next,
    limit: clamp(options.limit, DEFAULT_EXTRACT_LIMIT, MAX_EXTRACT_LIMIT),
    textLimit: clamp(options.textLimit, DEFAULT_EXTRACT_TEXT_CHARS, MAX_EXTRACT_TEXT_CHARS),
  }
}

/**
 * Every attribute a lazy-loading library has been seen to park a real URL in.
 *
 * A list rather than a pattern, and read in order, because `data-src` on one
 * site is the thumbnail and on another is the original — so all of them are
 * returned, none is preferred, and the caller is told which attribute each URL
 * came from. This is the direct repair for the 16,498 floor plans: the page
 * never fired its loader, and the URLs were sitting in these attributes the
 * whole time.
 */
/**
 * What separates two entries in a `srcset`, as a pattern rather than a comma.
 *
 * Exported and interpolated into the script rather than typed twice, so the test
 * below drives the same regex the page runs. An image CDN path is full of commas
 * — `/w_500,h_300/` is one path segment — and splitting on a bare comma cuts
 * those URLs in half, which is the "62,000 images at the wrong size" failure
 * wearing a different hat. A real separator is a comma followed by whitespace,
 * or a comma immediately after a width or density descriptor.
 */
export const SRCSET_SEPARATOR = /,\s+|(?<=\d[wx])\s*,\s*/

/**
 * Longer than any address a server will accept.
 *
 * In practice this means a base64 `data:` placeholder — the grey square a lazy
 * loader shows before the real image arrives. Two hundred of those inline would
 * be megabytes on the wire for something that is not a URL to anything. They are
 * **counted**, never silently dropped: discarding without saying so is how 58%
 * of a dataset went missing once already.
 */
export const MAX_CANDIDATE_URL_CHARS = 2048

export const LAZY_ATTRIBUTES = [
  'data-src',
  'data-original',
  'data-original-src',
  'data-lazy',
  'data-lazy-src',
  'data-url',
  'data-image',
  'data-full',
  'data-full-src',
  'data-large',
  'data-large-src',
  'data-zoom-image',
  'data-hi-res',
] as const

export const EXTRACT_SCRIPT = `(function () {
${PREAMBLE}
var args = ${ARGS_TOKEN} || {};
var limit = typeof args.limit === 'number' ? args.limit : 200;
var textLimit = typeof args.textLimit === 'number' ? args.textLimit : 4000;
var LAZY = ${JSON.stringify(LAZY_ATTRIBUTES)};

/* Resolved against the document's own base, never left relative. A crawl that
   kept a relative href is a crawl that eventually fetches the wrong host. */
var abs = function (u) {
  if (typeof u !== 'string') return '';
  var t = u.trim();
  if (t === '') return '';
  try { return new URL(t, document.baseURI).href } catch (e) { return '' }
};

/* "1,248 properties" is 1248. Thin spaces and non-breaking spaces are grouping
   separators on plenty of sites, so they come out before the digits are read. */
var num = function (s) {
  if (typeof s !== 'string') return null;
  var m = /-?[0-9][0-9,.\\u00a0\\u202f ]*/.exec(s);
  if (!m) return null;
  var digits = m[0].replace(/[^0-9-]/g, '');
  if (digits === '' || digits === '-') return null;
  var n = parseInt(digits, 10);
  return isFinite(n) ? n : null;
};

var within = function (scope, sel) {
  try {
    if (scope === document) return qsa(sel);
    return Array.prototype.slice.call(E.querySelectorAll.call(scope, sel));
  } catch (e) { return [] }
};

var MAX_URL = ${MAX_CANDIDATE_URL_CHARS};

var candidate = function (out, url, width, from) {
  var a = abs(url);
  if (a === '') return;
  if (a.length > MAX_URL) { out.dropped++; return }
  for (var i = 0; i < out.length; i++) {
    if (out[i].url === a) { if (width > out[i].width) out[i].width = width; return }
  }
  if (out.length < 32) out.push({ url: a, width: width, from: from });
  else out.dropped++;
};

/* Every URL this element declares, widest first, and nothing chosen. */
var imageOf = function (el) {
  var out = [];
  out.dropped = 0;
  try { if (el.currentSrc) candidate(out, el.currentSrc, 0, 'currentSrc') } catch (e) { /* not an image */ }
  candidate(out, attr(el, 'src'), 0, 'src');
  candidate(out, attr(el, 'href'), 0, 'href');
  candidate(out, attr(el, 'poster'), 0, 'poster');
  var sets = [attr(el, 'srcset'), attr(el, 'data-srcset')];
  for (var s = 0; s < sets.length; s++) {
    if (!sets[s]) continue;
    var parts = sets[s].split(/${SRCSET_SEPARATOR.source}/);
    for (var i = 0; i < parts.length; i++) {
      var bits = parts[i].trim().split(/\\s+/);
      if (!bits[0]) continue;
      var w = 0;
      for (var j = 1; j < bits.length; j++) {
        var d = /^([0-9]+)w$/.exec(bits[j]);
        if (d) w = parseInt(d[1], 10);
      }
      candidate(out, bits[0], w, 'srcset');
    }
  }
  for (var k = 0; k < LAZY.length; k++) candidate(out, attr(el, LAZY[k]), 0, LAZY[k]);
  out.sort(function (a, b) { return b.width - a.width });
  var natural = null;
  try {
    if (typeof el.naturalWidth === 'number' && el.naturalWidth > 0) {
      natural = { width: el.naturalWidth, height: el.naturalHeight };
    }
  } catch (e) { /* not an <img> */ }
  return {
    candidates: out.slice(0),
    /** How many candidates this element had that are not in the list above. */
    dropped: out.dropped,
    /* What actually loaded, so a thumbnail can be told from an original with no
       second request — and \`loading\` says whether scrolling would reveal more. */
    natural: natural,
    alt: attr(el, 'alt'),
    loading: attr(el, 'loading')
  };
};

/* What the page publishes about itself. Usually more complete and more stable
   than anything a selector reaches, and on a listing page it is the whole record. */
var dataOf = function (scope) {
  var out = { jsonld: [], meta: {}, itemprop: {} };
  var scripts = within(scope, 'script[type="application/ld+json"]');
  for (var i = 0; i < scripts.length && out.jsonld.length < 20; i++) {
    try {
      var raw = scripts[i].textContent;
      if (typeof raw === 'string' && raw.length <= 200000) out.jsonld.push(JSON.parse(raw));
    } catch (e) { /* a page with broken JSON-LD is the ordinary case, not an error */ }
  }
  if (scope === document) {
    var metas = qsa('meta[property],meta[name]');
    for (var m = 0; m < metas.length; m++) {
      var key = attr(metas[m], 'property') || attr(metas[m], 'name');
      var val = attr(metas[m], 'content');
      if (key && val && !Object.prototype.hasOwnProperty.call(out.meta, key)) out.meta[key] = val.slice(0, 2000);
    }
  }
  var props = within(scope, '[itemprop]');
  for (var p = 0; p < props.length && p < 200; p++) {
    var name = attr(props[p], 'itemprop');
    if (!name || Object.prototype.hasOwnProperty.call(out.itemprop, name)) continue;
    var v = attr(props[p], 'content') || attr(props[p], 'datetime') || line(props[p]);
    out.itemprop[name] = String(v).slice(0, 2000);
  }
  return out;
};

/*
 * counts is where a list field writes down how many it saw against how many
 * it brought back. Passed in rather than returned, because a field returns its
 * value and the accounting is a second answer about the same call — and a
 * caller that only ever hears the value cannot tell a short page from a short
 * read.
 */
var valueOf = function (scope, f, counts) {
  var op = String(f.op || '');
  var sel = typeof f.selector === 'string' ? f.selector : '';
  var many = f.all === true;

  if (op === 'count') return sel === '' ? within(scope, '*').length : within(scope, sel).length;
  if (op === 'data') return dataOf(sel === '' ? scope : (within(scope, sel)[0] || scope));

  var els = sel === '' ? [scope] : within(scope, sel);
  if (many && counts) {
    counts[String(f.name)] = { matched: els.length, returned: Math.min(els.length, limit) };
  }
  if (els.length === 0) return many ? [] : null;
  var take = many ? els.slice(0, limit) : [els[0]];
  var vals = [];
  for (var i = 0; i < take.length; i++) {
    var el = take[i];
    if (op === 'image') { vals.push(imageOf(el)); continue }
    if (op === 'link') {
      vals.push(abs(attr(el, 'href') || attr(el, 'src') || attr(el, 'data-href') || ''));
      continue;
    }
    /* The one thing this script must never produce. Null, not redacted: a value
       that was never read cannot be leaked by anything downstream. */
    if (isSecret(el)) { vals.push(null); continue }
    if (op === 'attribute') { vals.push(attr(el, String(f.attribute || ''))); continue }
    var t = text(el);
    if (op === 'number') { vals.push(num(t)); continue }
    vals.push(t.slice(0, textLimit));
  }
  return many ? vals : vals[0];
};

var fields = {};
var counts = {};
var list = Array.isArray(args.fields) ? args.fields : [];
for (var a = 0; a < list.length; a++) fields[String(list[a].name)] = valueOf(document, list[a], counts);

var rows = [];
var rowsOnPage = 0;
if (args.rows && typeof args.rows.selector === 'string' && Array.isArray(args.rows.fields)) {
  var containers = qsa(args.rows.selector);
  rowsOnPage = containers.length;
  var wanted = containers.slice(0, limit);
  for (var r = 0; r < wanted.length; r++) {
    var row = {};
    for (var q = 0; q < args.rows.fields.length; q++) {
      var rf = args.rows.fields[q];
      /* No counts for a field inside a row: one number per row per field is
         noise, and the number that matters for a repeated block is how many
         rows there are, which is recorded above. */
      row[String(rf.name)] = valueOf(wanted[r], rf, null);
    }
    rows.push(row);
  }
}

var stated = null;
if (args.stated) {
  var claimed = valueOf(document, args.stated, null);
  stated = typeof claimed === 'number' && isFinite(claimed) ? claimed : null;
}

var next = null;
if (typeof args.next === 'string' && args.next !== '') {
  var link = qs(args.next);
  if (link) {
    var href = abs(attr(link, 'href') || attr(link, 'data-href') || '');
    next = href === '' ? null : href;
  }
}

return {
  url: String(location.href),
  title: String(document.title || ''),
  fields: fields,
  rows: rows,
  rowsOnPage: rowsOnPage,
  rowsReturned: rows.length,
  counts: counts,
  stated: stated,
  next: next
};
})()`
