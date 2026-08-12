/**
 * Turning a clicked element in the embedded browser into something an agent
 * can act on: a CSS selector, a label, and one line of context.
 *
 * Everything here is pure and DOM-free on purpose. The guest page is untrusted,
 * so the browser preload only *reports facts* about the clicked element (tag,
 * id, whether that id is unique in its document, sibling position). All the
 * judgement — which selector wins, what is safe to escape, what gets pasted
 * into a terminal — happens here, where it can be tested against adversarial
 * input instead of hoped about.
 *
 * The main tsconfig has no DOM lib, which is why the descriptors are plain data
 * rather than `Element`s. That constraint turned out to be the right shape
 * anyway: the untrusted side gathers, the trusted side decides.
 */

/* ------------------------------------------------------------------ types -- */

/**
 * One element on the path from the clicked node up to the document root, as
 * reported by the guest. Every field is optional except `tag` because a hostile
 * or merely unusual page may not supply any of it.
 */
export interface ElementDescriptor {
  /** `localName` — lower-case for HTML, case-preserved for SVG (`clipPath`). */
  tag: string
  id?: string | null
  /** Which test-hook attribute matched, e.g. `data-testid`. */
  testAttr?: string | null
  testValue?: string | null
  /** `#id` matches exactly one element in the guest document. */
  idUnique?: boolean
  /** The attribute selector matches exactly one element in the guest document. */
  testUnique?: boolean
  /** 1-based position among siblings of the same element type. */
  nthOfType?: number
  /** How many siblings of this element type the parent has. */
  ofTypeCount?: number
}

/** A sanitised, ready-to-show capture. Nothing here came straight from the page. */
export interface ElementCapture {
  selector: string
  tag: string
  /** Best human-readable handle for the element, already trimmed and clamped. */
  label: string
  /** Where {@link label} came from, so the context line can say so. */
  labelSource: LabelSource
  /** The page URL as the *main process* knows it — never the page's own claim. */
  url: string
  /** Whitelisted attributes, sanitised. Shown in the panel, not used in selectors. */
  attributes: Record<string, string>
}

export type LabelSource = 'text' | 'value' | 'aria-label' | 'alt' | 'placeholder' | 'title' | 'none'

/**
 * Test-hook attributes in priority order. `data-testid` first because it is
 * what Testing Library and Playwright default to, so it is the one most likely
 * to actually be in the codebase the agent is about to edit.
 */
export const TEST_ID_ATTRS = [
  'data-testid',
  'data-test-id',
  'data-test',
  'data-qa',
  'data-cy',
  'data-automation-id',
] as const

/**
 * Attributes worth carrying across. Deliberately a closed list: the page
 * controls attribute *names* as well as values, and an open-ended copy would
 * let it stuff arbitrary keys into our IPC payload and our UI.
 */
export const CAPTURE_ATTRS = [
  'aria-label',
  'alt',
  'placeholder',
  'title',
  'role',
  'type',
  'name',
  'href',
  'value',
] as const

/** Longest ancestor path we will consider. Deep DOMs exist; unbounded ones are attacks. */
export const MAX_PATH_DEPTH = 64
/** Text is a hint for the agent, not the content of the page. */
export const MAX_LABEL_LENGTH = 150
const MAX_IDENT_LENGTH = 200
const MAX_ATTR_LENGTH = 300
const MAX_URL_LENGTH = 400
/** One line pasted into a prompt. Long enough for a real selector, short enough to read. */
const MAX_CONTEXT_LENGTH = 1200

/* ------------------------------------------------------------ sanitising -- */

/**
 * How much of an oversized string is worth looking at, as a multiple of the
 * limit. The page decides how long its strings are and this code runs on the
 * main process — which is also the app's UI thread — so the scan is bounded
 * before any regex touches it. Measured: three passes over a 20 MB string of
 * alternating spaces costs ~1.2 s of frozen app, per message, and the guest can
 * send as many messages as it likes.
 *
 * The generous multiple keeps the visible behaviour identical for anything
 * short of an attack: only an input carrying kilobytes of whitespace inside the
 * prefix can end up shorter than an unbounded scan would have produced.
 */
const SCAN_HEADROOM = 32

/**
 * Everything the page produces passes through here before it can reach a
 * terminal. The composed context string is written into a PTY, where a stray
 * `\n` submits the prompt early and an ESC can repaint the user's screen — so
 * control characters are removed rather than escaped. Bidi overrides go too:
 * they let text render as something other than what it says.
 */
export function sanitizeLine(value: unknown, max: number): string {
  if (typeof value !== 'string') return ''
  const scanLimit = max * SCAN_HEADROOM + 1024
  const stripped = (value.length > scanLimit ? value.slice(0, scanLimit) : value)
    // C0/C1 controls (includes \n, \r, \t and ESC) and the Unicode line breaks.
    .replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, ' ')
    // Bidi embedding/override/isolate controls — invisible, and they reorder text.
    .replace(/[\u202a-\u202e\u2066-\u2069\u200e\u200f]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
  if (stripped.length <= max) return stripped
  return `${stripped.slice(0, max).trimEnd()}\u2026`
}

/** True when a string is safe to place inside a CSS string or identifier. */
function isPrintable(value: string): boolean {
  return !/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/.test(value)
}

/**
 * CSS.escape, implemented here because the main process has no `CSS` global.
 * Follows the CSSOM serialisation algorithm: leading digits, a lone hyphen and
 * control characters all need hex escapes, and `#3col` is not a valid selector
 * even though `id="3col"` is a perfectly legal id.
 */
export function escapeIdent(value: string): string {
  let out = ''
  const first = value.charCodeAt(0)
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i)
    if (code === 0x0000) {
      out += '\uFFFD'
      continue
    }
    const isDigit = code >= 0x0030 && code <= 0x0039
    if (
      (code >= 0x0001 && code <= 0x001f) ||
      code === 0x007f ||
      (i === 0 && isDigit) ||
      (i === 1 && isDigit && first === 0x002d)
    ) {
      out += `\\${code.toString(16)} `
      continue
    }
    if (i === 0 && code === 0x002d && value.length === 1) {
      out += `\\${value.charAt(i)}`
      continue
    }
    if (
      code >= 0x0080 ||
      code === 0x002d ||
      code === 0x005f ||
      isDigit ||
      (code >= 0x0041 && code <= 0x005a) ||
      (code >= 0x0061 && code <= 0x007a)
    ) {
      out += value.charAt(i)
      continue
    }
    out += `\\${value.charAt(i)}`
  }
  return out
}

/** A CSS string literal, or null when the value cannot safely become one. */
export function cssString(value: string): string | null {
  if (!isPrintable(value)) return null
  return `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
}

/** Tag names we will emit. Allows custom elements and SVG's camelCase names. */
function safeTag(tag: unknown): string {
  return typeof tag === 'string' && /^[a-zA-Z][a-zA-Z0-9-]*$/.test(tag) && tag.length <= 60
    ? tag
    : '*'
}

/* ------------------------------------------------------------- selectors -- */

function usableId(d: ElementDescriptor): string | null {
  const id = typeof d.id === 'string' ? d.id.trim() : ''
  if (!id || id.length > MAX_IDENT_LENGTH || !isPrintable(id)) return null
  return id
}

function usableTest(d: ElementDescriptor): { attr: string; value: string } | null {
  const attr = typeof d.testAttr === 'string' ? d.testAttr : ''
  const value = typeof d.testValue === 'string' ? d.testValue : ''
  // The attribute name must be one *we* named. The page does not get to pick.
  if (!(TEST_ID_ATTRS as readonly string[]).includes(attr)) return null
  if (!value || value.length > MAX_IDENT_LENGTH || !isPrintable(value)) return null
  return { attr, value }
}

function attrSelector(attr: string, value: string): string | null {
  const literal = cssString(value)
  return literal === null ? null : `[${attr}=${literal}]`
}

/** `div` or `div:nth-of-type(3)` — position only when it actually disambiguates. */
function segmentFor(d: ElementDescriptor): string {
  const tag = safeTag(d.tag)
  const count = typeof d.ofTypeCount === 'number' ? d.ofTypeCount : 1
  const nth = typeof d.nthOfType === 'number' ? d.nthOfType : 1
  if (count > 1 && Number.isInteger(nth) && nth >= 1) return `${tag}:nth-of-type(${nth})`
  return tag
}

/**
 * Build the most stable selector the reported path supports.
 *
 * `path[0]` is the clicked element and each entry after it is its parent, which
 * is the order a DOM walk naturally produces. Preference order:
 *
 * 1. the element's own `#id`, **if that id is unique in the document** — ids are
 *    supposed to be unique and routinely are not; React lists duplicate them
 *    constantly, which is exactly the case a naive `#id` gets wrong;
 * 2. its test-hook attribute, when that is unique;
 * 3. a `>`-joined path of `tag:nth-of-type(n)` segments, anchored at the nearest
 *    unique id/test hook above it, or failing that at `body`.
 *
 * The anchor matters: an unanchored path like `div > span` matches at every
 * depth, so it is not a selector, it is a guess.
 */
export function computeSelector(path: ElementDescriptor[]): string {
  if (!Array.isArray(path) || path.length === 0) return ''

  const segments: string[] = []

  for (let i = 0; i < path.length && i < MAX_PATH_DEPTH; i++) {
    const d = path[i]
    if (!d || typeof d !== 'object') break

    const id = usableId(d)
    if (id && d.idUnique === true) {
      segments.unshift(`#${escapeIdent(id)}`)
      return segments.join(' > ')
    }

    const test = usableTest(d)
    if (test && d.testUnique === true) {
      const selector = attrSelector(test.attr, test.value)
      if (selector) {
        segments.unshift(selector)
        return segments.join(' > ')
      }
    }

    // <html> is never worth a segment: `body` already anchors the path.
    if (d.tag === 'html') break

    segments.unshift(segmentFor(d))

    if (d.tag === 'body') break
  }

  return segments.join(' > ')
}

/* --------------------------------------------------------------- capture -- */

function labelFrom(
  text: string,
  attributes: Record<string, string>,
): { label: string; labelSource: LabelSource } {
  if (text) return { label: text, labelSource: 'text' }
  // Order matters: an icon-only button has no text but usually has an
  // aria-label, and an empty input has a placeholder. Whichever a human would
  // read off the screen is the one the agent should be told about.
  const order: LabelSource[] = ['value', 'aria-label', 'alt', 'placeholder', 'title']
  for (const key of order) {
    const value = attributes[key]
    if (value) return { label: value, labelSource: key }
  }
  return { label: '', labelSource: 'none' }
}

function sanitizeAttributes(raw: unknown): Record<string, string> {
  const out: Record<string, string> = {}
  if (typeof raw !== 'object' || raw === null) return out
  const record = raw as Record<string, unknown>
  // A password field's live value must never travel. It would land in the
  // capture panel, in the line handed to the agent, and from there in the
  // agent's own transcript on disk. The guest withholds it too; this is the
  // half that can be tested, and the half a tampered payload cannot skip.
  const isSecret =
    typeof record.type === 'string' && record.type.trim().toLowerCase() === 'password'
  for (const key of CAPTURE_ATTRS) {
    if (isSecret && key === 'value') continue
    const value = sanitizeLine(record[key], MAX_ATTR_LENGTH)
    if (value) out[key] = value
  }
  return out
}

function sanitizeDescriptor(raw: unknown): ElementDescriptor | null {
  if (typeof raw !== 'object' || raw === null) return null
  const r = raw as Record<string, unknown>
  if (typeof r.tag !== 'string') return null
  const d: ElementDescriptor = { tag: r.tag.slice(0, 60) }
  if (typeof r.id === 'string') d.id = r.id.slice(0, MAX_IDENT_LENGTH)
  if (typeof r.testAttr === 'string') d.testAttr = r.testAttr.slice(0, 60)
  if (typeof r.testValue === 'string') d.testValue = r.testValue.slice(0, MAX_IDENT_LENGTH)
  if (r.idUnique === true) d.idUnique = true
  if (r.testUnique === true) d.testUnique = true
  if (typeof r.nthOfType === 'number' && Number.isInteger(r.nthOfType) && r.nthOfType >= 1) {
    d.nthOfType = r.nthOfType
  }
  if (typeof r.ofTypeCount === 'number' && Number.isInteger(r.ofTypeCount) && r.ofTypeCount >= 1) {
    d.ofTypeCount = r.ofTypeCount
  }
  return d
}

/**
 * Validate and sanitise a payload from the guest preload.
 *
 * `url` comes from the main process's own view of the WebContents, not from the
 * payload — a page that could tamper with the message would otherwise be able
 * to tell the agent it is editing a different site than it is.
 *
 * Returns null for anything malformed; the caller drops it silently rather than
 * surfacing a page-authored error string.
 */
export function parseCapture(raw: unknown, url: string): ElementCapture | null {
  if (typeof raw !== 'object' || raw === null) return null
  const payload = raw as Record<string, unknown>
  if (payload.v !== 1) return null
  if (!Array.isArray(payload.path) || payload.path.length === 0) return null

  const path: ElementDescriptor[] = []
  for (const entry of payload.path.slice(0, MAX_PATH_DEPTH)) {
    const d = sanitizeDescriptor(entry)
    // Stop, do not skip. The segments are joined with the child combinator, so
    // dropping one link out of the middle of the chain silently asserts a
    // parent/child relationship that does not exist — `body > span` for a span
    // nested six levels down. Truncating leaves a shorter path that is still
    // true; splicing leaves a selector that is confidently wrong.
    if (!d) break
    path.push(d)
  }
  if (path.length === 0) return null

  const selector = computeSelector(path)
  if (!selector) return null

  const attributes = sanitizeAttributes(payload.attributes)
  const text = sanitizeLine(payload.text, MAX_LABEL_LENGTH)
  const { label, labelSource } = labelFrom(text, attributes)

  return {
    selector,
    tag: safeTag(path[0].tag) === '*' ? '' : path[0].tag,
    label,
    labelSource,
    url: sanitizeLine(url, MAX_URL_LENGTH),
    attributes,
  }
}

/**
 * The one line that goes into the agent's prompt.
 *
 * Single line by construction. Deck types this into a PTY running a coding
 * agent, and in every one of those CLIs a newline submits — a multi-line
 * context string would send the first line as the whole instruction.
 */
export function composeAgentContext(capture: ElementCapture, instruction = ''): string {
  const parts: string[] = []
  if (capture.url) parts.push(`on ${capture.url}`)
  parts.push(`element \`${capture.selector}\``)
  if (capture.tag) parts.push(`<${capture.tag}>`)
  if (capture.label) {
    const word = capture.labelSource === 'text' ? 'text' : capture.labelSource
    parts.push(`${word} "${capture.label}"`)
  }

  const context = `[browser: ${parts.join(', ')}]`
  const lead = sanitizeLine(instruction, 600)
  return sanitizeLine(lead ? `${lead} ${context}` : context, MAX_CONTEXT_LENGTH)
}
