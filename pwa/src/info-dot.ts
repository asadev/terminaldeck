/**
 * The ⓘ, and the only place an explanation is allowed to live.
 *
 * His instruction, twice in one recording, and the rule most often broken while
 * fixing something else:
 *
 *   > *"here you have a very long description… Remove this full shit. I don't
 *   > want any kind of long descriptions anywhere. Just if somewhere it's very
 *   > required, give the i icon like other ones, information icon in the
 *   > settings, same way."*
 *
 *   > *"don't put any single statement in anywhere… We want simplicity. Let the
 *   > smart people use it. Smart people knows how it works."*
 *
 * So a screen carries controls and figures, and anything that would have been a
 * paragraph under one of them goes behind this. Nothing is lost: it is reachable
 * by pointer, by keyboard and by a screen reader, and it costs a reader who
 * already knows how the thing works exactly nothing.
 *
 * ## A popup, not a disclosure
 *
 * The desktop's Settings window made this decision first and it is worth
 * following rather than re-litigating: a disclosure pushes everything below it
 * down the page, so reading the second explanation moves the third somewhere
 * else. Asad's own words about the same dot — *"the ⓘ dot shows its detail on
 * hover, as a popup — not by expanding the pane downward."*
 *
 * This is a `<details>` with an absolutely-positioned `<summary>` sibling, which
 * is the smallest thing in a browser that opens, closes, takes focus, answers
 * Escape and is announced — with no script holding it open and nothing to leak
 * when the screen it is on is thrown away and rebuilt, which is how every screen
 * in this client is drawn.
 */

const SVG_NS = 'http://www.w3.org/2000/svg'

/** The ⓘ glyph — a circle with a bar and a dot, drawn rather than a font. */
function glyph(): SVGSVGElement {
  const svg = document.createElementNS(SVG_NS, 'svg')
  svg.setAttribute('viewBox', '0 0 24 24')
  svg.setAttribute('width', '16')
  svg.setAttribute('height', '16')
  svg.setAttribute('fill', 'none')
  svg.setAttribute('stroke', 'currentColor')
  svg.setAttribute('stroke-width', '1.8')
  svg.setAttribute('stroke-linecap', 'round')
  svg.setAttribute('aria-hidden', 'true')
  const ring = document.createElementNS(SVG_NS, 'circle')
  ring.setAttribute('cx', '12')
  ring.setAttribute('cy', '12')
  ring.setAttribute('r', '9')
  const bar = document.createElementNS(SVG_NS, 'path')
  bar.setAttribute('d', 'M12 11v5')
  const dot = document.createElementNS(SVG_NS, 'path')
  dot.setAttribute('d', 'M12 8h.01')
  svg.append(ring, bar, dot)
  return svg
}

/**
 * An ⓘ carrying one explanation.
 *
 * `about` is what the dot is beside, and it is only ever read aloud — a dot with
 * no name is a dot a screen reader announces as "disclosure triangle".
 */
export function infoDot(about: string, text: string): HTMLElement {
  const details = document.createElement('details')
  details.className = 'info'

  const summary = document.createElement('summary')
  summary.className = 'info__dot'
  summary.setAttribute('aria-label', `About ${about}`)
  summary.title = `About ${about}`
  summary.append(glyph())

  const body = document.createElement('div')
  body.className = 'info__body'
  body.setAttribute('role', 'note')
  body.textContent = text

  /*
   * Pulled back inside the frame when it opens.
   *
   * The popup is anchored to the dot, and a dot two-thirds of the way across a
   * 375px phone puts a 320px popup a hundred and seventy pixels off the right
   * edge. Rendered at a phone viewport before this existed: `left: 229, right:
   * 549, width: 375`. That is the defect he filmed on the desktop, in the same
   * words it deserves — *"this window is going out of the frame"* — and a
   * `max-width` does not fix it, because the width was never the problem.
   *
   * Measured rather than guessed, because where the dot sits depends on the
   * length of the heading beside it, which is a translated string. `transform`
   * rather than `left`, so nothing reflows and the correction survives the
   * popup being closed and opened again at a different width.
   */
  details.addEventListener('toggle', () => {
    body.style.transform = ''
    if (!details.open) return
    // One at a time. `details` elements do not close each other, so opening the
    // second ⓘ on a screen left the first one's popup underneath it — two
    // paragraphs overlapping, the lower one clipping the upper. Rendered at a
    // phone viewport, which is how it was found.
    for (const other of document.querySelectorAll('details.info[open]')) {
      if (other !== details) (other as HTMLDetailsElement).open = false
    }
    const box = body.getBoundingClientRect()
    const overflowRight = box.right - (window.innerWidth - MARGIN)
    if (overflowRight > 0) body.style.transform = `translateX(${-Math.min(overflowRight, box.left - MARGIN)}px)`
  })

  details.append(summary, body)
  return details
}

/** How close to the edge of the frame the popup may come. */
const MARGIN = 12
