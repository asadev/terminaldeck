/**
 * Asking the page how big it expects an image to be.
 *
 * ## Why the page has to be asked at all
 *
 * A `Fetch.requestPaused` event carries the URL, the method and the resource
 * type. It does not carry the element that asked for it — there is no such
 * field in the protocol, because at that layer there is no element, only a
 * network request with a referrer. So the size a lazy-loader is about to check
 * `naturalWidth` against is knowable only from the DOM, and the DOM is a round
 * trip away.
 *
 * That round trip is affordable for exactly one reason: the request is
 * **paused**. Nothing is racing. The page's own JavaScript carries on — a
 * pending image load never blocked it — and the answer comes back in a
 * millisecond or two on an idle renderer. `browser-network.ts` bounds the wait
 * anyway and falls back to 1×1 when it expires, because a request that is never
 * answered is a page that never finishes loading, and that failure would be far
 * worse than a placeholder of the wrong size.
 *
 * ## Where a size can come from, in order of how much the page means it
 *
 *  1. **The `width`/`height` attributes.** An author wrote them down. They are
 *     the intrinsic size the page is asserting, and they are what a
 *     `naturalWidth` check is usually comparing against.
 *  2. **A `srcset` width descriptor.** `photo-1200.jpg 1200w` states the
 *     intrinsic width of that exact candidate. It is the *only* place a
 *     responsive image states its real width, and it is why blocking images
 *     breaks `<picture>` so completely.
 *  3. **The laid-out CSS box.** Not the intrinsic size — it is the size the
 *     element occupies — but it is a real number the page produced, and a card
 *     grid measuring the first image to lay out its columns is measuring
 *     exactly this.
 *
 * A height that no source states is derived from whatever ratio the page does
 * state — `aspect-ratio`, or the box — and the derivation is reported rather
 * than hidden, because a derived height is a guess and the caller is entitled
 * to know how many of its placeholders were guesses.
 *
 * ## What this deliberately does not do
 *
 * It does not walk computed styles looking for `background-image`. That is a
 * `getComputedStyle` per element over the whole document, on a page that is
 * mid-load, once per paused request. The cost is not worth it: a CSS background
 * has no `naturalWidth` for anything to gate on, so the lazy-loading failure
 * this feature exists to prevent cannot happen through one.
 */

import { withArgs } from './browser-drive-script'

/** Where a size came from. `none` means the page states no size anywhere. */
export type SizeSource = 'attributes' | 'srcset' | 'box' | 'none'

export interface SizeHint {
  width: number
  height: number
  from: SizeSource
  /** True when only a width was stated and the height came off a ratio. */
  derivedHeight: boolean
}

/**
 * Find the element that asked for this URL, and say how big it expects it.
 *
 * Runs in the drive's isolated world, through the one
 * `executeJavaScriptInIsolatedWorld` call in `browser-driver.ts`. Every DOM
 * access goes through a prototype rather than an instance, for the reason
 * `browser-drive-script.ts` gives at length: the page owns its own objects and
 * may have replaced any of them, and a driver that can be lied to by the site
 * it is driving is a driver whose reports are the site's opinion.
 */
export const IMAGE_SIZE_SCRIPT = `(function () {
  var want = /*__DECK_ARGS__*/null;
  if (typeof want !== 'string' || want === '') return null;

  var D = Document.prototype, E = Element.prototype;
  var attr = function (el, name) {
    try { var v = E.getAttribute.call(el, name); return typeof v === 'string' ? v : '' } catch (e) { return '' }
  };
  var num = function (raw) {
    var n = parseInt(String(raw).trim(), 10);
    return isFinite(n) && n > 0 ? n : 0;
  };
  var all = function (sel) {
    try { return Array.prototype.slice.call(D.querySelectorAll.call(document, sel), 0, 4000) } catch (e) { return [] }
  };

  /*
   * A candidate list, parsed. \`photo-1200.jpg 1200w, photo-600.jpg 600w\`.
   * Descriptors may also be \`2x\` densities, which state no width at all — those
   * candidates match the URL but contribute no size, which is a real and
   * ordinary answer rather than a parse failure.
   */
  var candidates = function (raw) {
    var out = [];
    var parts = String(raw).split(',');
    for (var i = 0; i < parts.length; i++) {
      var bits = parts[i].trim().split(/\\s+/);
      if (bits.length === 0 || bits[0] === '') continue;
      var w = 0;
      for (var j = 1; j < bits.length; j++) {
        var d = bits[j];
        if (/^[0-9]+w$/.test(d)) w = num(d.slice(0, -1));
      }
      out.push({ url: bits[0], width: w });
    }
    return out;
  };

  /*
   * Same image?
   *
   * An exact string match first, then a match on the absolute form, because an
   * attribute is usually relative and the protocol always hands over an
   * absolute URL. \`new URL\` resolves against the document's base, which is what
   * the browser itself did to produce the request.
   */
  var absolute = function (raw) {
    if (typeof raw !== 'string' || raw === '') return '';
    if (raw === want) return raw;
    try { return new URL(raw, document.baseURI).href } catch (e) { return raw }
  };
  var same = function (raw) { return raw === want || absolute(raw) === want };

  var boxOf = function (el) {
    try {
      var r = E.getBoundingClientRect.call(el);
      return { width: Math.round(r.width), height: Math.round(r.height) };
    } catch (e) { return { width: 0, height: 0 } }
  };

  /* A ratio the page states, for a height nothing states. */
  var ratioOf = function (el) {
    try {
      var s = window.getComputedStyle(el);
      var m = /^([0-9.]+)\\s*\\/\\s*([0-9.]+)$/.exec(String(s.aspectRatio || '').trim());
      if (m) {
        var w = parseFloat(m[1]), h = parseFloat(m[2]);
        if (w > 0 && h > 0) return h / w;
      }
    } catch (e) { /* a node with no computed style is a node with no stated ratio. */ }
    var b = boxOf(el);
    return b.width > 0 && b.height > 0 ? b.height / b.width : 0;
  };

  var judge = function (el) {
    var aw = num(attr(el, 'width')), ah = num(attr(el, 'height'));
    if (aw > 0 && ah > 0) return { width: aw, height: ah, from: 'attributes', derivedHeight: false };

    var sw = 0;
    var sets = [attr(el, 'srcset'), attr(el, 'data-srcset')];
    for (var i = 0; i < sets.length && sw === 0; i++) {
      if (sets[i] === '') continue;
      var list = candidates(sets[i]);
      for (var j = 0; j < list.length; j++) {
        if (same(list[j].url) && list[j].width > 0) { sw = list[j].width; break }
      }
    }
    /* An attribute width with no height still beats a box, so it is tried before one. */
    var width = aw > 0 ? aw : sw;
    var from = aw > 0 ? 'attributes' : (sw > 0 ? 'srcset' : '');
    if (width > 0) {
      if (ah > 0) return { width: width, height: ah, from: from, derivedHeight: false };
      var r = ratioOf(el);
      /*
       * No ratio anywhere. A square is used, and \`derivedHeight\` says so — a
       * placeholder with a made-up aspect is still a placeholder that passes
       * every \`naturalWidth > 1\` gate, which is what it is for, and the caller
       * is told how many of its placeholders were guesses.
       */
      var height = r > 0 ? Math.max(1, Math.round(width * r)) : width;
      return { width: width, height: height, from: from, derivedHeight: true };
    }

    var box = boxOf(el);
    if (box.width > 0 && box.height > 0) {
      return { width: box.width, height: box.height, from: 'box', derivedHeight: false };
    }
    return null;
  };

  /*
   * \`<source>\` before \`<img>\`.
   *
   * Inside a \`<picture>\` the chosen candidate is the source's, and the \`<img>\`
   * underneath carries the fallback \`src\` — so an image requested because of a
   * \`<source srcset>\` is described by that source's descriptor and by the
   * \`<img>\`'s box. Both are consulted; the first that yields a size wins, and
   * the source's own \`<img>\` is checked next by the loop below anyway.
   */
  var pool = all('source[srcset],source[data-srcset]').concat(
    all('img'), all('[data-src],[data-srcset]')
  );
  var fallback = null;
  for (var i = 0; i < pool.length; i++) {
    var el = pool[i];
    var mine =
      same(attr(el, 'src')) || same(attr(el, 'data-src')) ||
      (typeof el.currentSrc === 'string' && el.currentSrc === want);
    if (!mine) {
      var sets = [attr(el, 'srcset'), attr(el, 'data-srcset')];
      for (var s = 0; s < sets.length && !mine; s++) {
        if (sets[s] === '') continue;
        var list = candidates(sets[s]);
        for (var c = 0; c < list.length; c++) { if (same(list[c].url)) { mine = true; break } }
      }
    }
    if (!mine) continue;
    var verdict = judge(el);
    if (verdict) return verdict;
    /*
     * The element is the right one and states nothing — an \`<img>\` with no
     * attributes that has not been laid out yet, which is the ordinary state of
     * a lazy image below the fold. Remembered rather than returned, so a later
     * element describing the same URL can still answer.
     */
    if (fallback === null) fallback = { width: 1, height: 1, from: 'none', derivedHeight: false };
  }
  return fallback;
})()`

/** The script, with the URL in it. */
export function imageSizeScript(url: string): string {
  return withArgs(IMAGE_SIZE_SCRIPT, url)
}

/**
 * Narrow whatever the page handed back.
 *
 * A script running in a page's world returns whatever it returns, and this is
 * main-process code that is about to allocate a raster from the numbers in it.
 * `browser-placeholder.ts` clamps as well; two checks, because the consequence
 * of one of them being wrong is a `Buffer.alloc` sized by a website.
 */
export function readSizeHint(raw: unknown): SizeHint | null {
  if (typeof raw !== 'object' || raw === null) return null
  const value = raw as Record<string, unknown>
  const width = whole(value.width)
  const height = whole(value.height)
  if (width === 0 || height === 0) return null
  const from = value.from
  return {
    width,
    height,
    from:
      from === 'attributes' || from === 'srcset' || from === 'box' || from === 'none'
        ? from
        : 'none',
    derivedHeight: value.derivedHeight === true,
  }
}

function whole(raw: unknown): number {
  if (typeof raw !== 'number' || !Number.isFinite(raw)) return 0
  const n = Math.trunc(raw)
  return n > 0 ? n : 0
}
