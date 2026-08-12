/**
 * The DOM-reading half of a guest script, as source text.
 *
 * ## Why this is a string and not a module
 *
 * Guest scripts run inside an untrusted page as sandboxed preloads. A sandboxed
 * preload's `require` only resolves `electron` — it cannot load a file from this
 * repo — so anything two guest scripts share has to be *pasted into both* at
 * build time. Keeping the shared part here makes that duplication a named,
 * reviewable thing instead of two 200-line template literals that drifted.
 *
 * ## What it is allowed to do
 *
 * Report facts, nothing else. It produces the exact payload shape
 * `parseCapture()` in `selector.ts` validates — `{v:1, path, text, attributes}` —
 * because every decision about that data (which selector wins, what may reach a
 * terminal, what a password field is allowed to say) belongs on the main-process
 * side where it is tested against hostile input.
 *
 * `browser-preload.ts` carries its own copy of these helpers, written before
 * this module existed. They are the same functions and should be folded together
 * when that file is next touched; until then, a change here needs the same
 * change there. Nothing breaks if they drift — the two scripts are independent —
 * but the selectors they produce would stop agreeing with each other, which is
 * worse than an outright break because it looks fine.
 *
 * Written with doubled backslashes throughout: this is a template literal, so
 * `\\s` here lands as `\s` in the generated file.
 */

/** Test-hook attributes, most standard first. Mirrors `TEST_ID_ATTRS` in selector.ts. */
const TEST_ATTRS = [
  'data-testid',
  'data-test-id',
  'data-test',
  'data-qa',
  'data-cy',
  'data-automation-id',
]

/** Attributes carried across. Closed list — the page names attributes too. */
const ATTR_KEYS = ['aria-label', 'alt', 'placeholder', 'title', 'role', 'type', 'name', 'href']

/**
 * Defines `terminaldeckDescribeElement(el)` returning a `parseCapture`-shaped payload,
 * plus `terminaldeckFlatten(value, max)` for one-off strings. Both are `var`-scoped
 * functions, so this snippet must be embedded inside the consuming script's own
 * IIFE rather than at top level, where it would leak into the isolated world's
 * globals and be visible to any other script sharing that world.
 */
export const GUEST_DOM_HELPERS_SOURCE = `
  var TERMINALDECK_TEST_ATTRS = ${JSON.stringify(TEST_ATTRS)}
  var TERMINALDECK_ATTR_KEYS = ${JSON.stringify(ATTR_KEYS)}
  var TERMINALDECK_MAX_DEPTH = 64
  var TERMINALDECK_MAX_TEXT = 300
  var TERMINALDECK_MAX_ATTR = 300
  var TERMINALDECK_MAX_IDENT = 200

  function terminaldeckFlatten(value, max) {
    if (typeof value !== 'string') return ''
    // Cut first, collapse second. textContent on a real page is megabytes, and
    // an unbounded collapse would hang the page on the very interaction being
    // recorded.
    var raw = value.length > max * 8 ? value.slice(0, max * 8) : value
    var flat = raw.replace(/\\s+/g, ' ').trim()
    return flat.length > max ? flat.slice(0, max) : flat
  }

  function terminaldeckPrintable(value) {
    return !/[\\u0000-\\u001f\\u007f]/.test(value)
  }

  function terminaldeckUnique(selector) {
    try {
      return document.querySelectorAll(selector).length === 1
    } catch (err) {
      return false
    }
  }

  function terminaldeckCssString(value) {
    return '"' + value.replace(/\\\\/g, '\\\\\\\\').replace(/"/g, '\\\\"') + '"'
  }

  function terminaldeckDescribe(el) {
    var d = { tag: typeof el.localName === 'string' ? el.localName : '' }

    var id = el.getAttribute('id')
    if (typeof id === 'string' && id !== '' && id.length <= TERMINALDECK_MAX_IDENT && terminaldeckPrintable(id)) {
      d.id = id
      d.idUnique = terminaldeckUnique('#' + CSS.escape(id))
    }

    for (var i = 0; i < TERMINALDECK_TEST_ATTRS.length; i++) {
      var name = TERMINALDECK_TEST_ATTRS[i]
      var value = el.getAttribute(name)
      if (typeof value === 'string' && value !== '' && value.length <= TERMINALDECK_MAX_IDENT && terminaldeckPrintable(value)) {
        d.testAttr = name
        d.testValue = value
        d.testUnique = terminaldeckUnique('[' + name + '=' + terminaldeckCssString(value) + ']')
        break
      }
    }

    var count = 1
    var index = 1
    var parent = el.parentElement
    if (parent) {
      var kids = parent.children
      count = 0
      for (var j = 0; j < kids.length; j++) {
        var kid = kids[j]
        // :nth-of-type counts by element type, which is local name plus
        // namespace — an <a> in SVG is not an <a> in HTML.
        if (kid.localName === el.localName && kid.namespaceURI === el.namespaceURI) {
          count++
          if (kid === el) index = count
        }
      }
      if (count < 1) count = 1
    }
    d.ofTypeCount = count
    d.nthOfType = index
    return d
  }

  function terminaldeckSecretField(el) {
    // The property wins where it exists — a page can set input.type without
    // touching the attribute — and the attribute covers the fake-DOM case.
    var type = typeof el.type === 'string' && el.type !== '' ? el.type : el.getAttribute('type')
    if (typeof type !== 'string') return false
    var kind = type.toLowerCase()
    // \`file\` belongs here with \`password\`, and was missing. Its value is a path
    // on the user's own disk — /Users/<name>/… names them before it names
    // anything else — and it is the one attribute value \`labelFrom\` reaches for
    // first, so an unnamed file input was captured *as* its path and carried
    // that into the line handed to an agent. Neither field's value is the
    // page's to report, and neither can be replayed from one anyway.
    return kind === 'password' || kind === 'file'
  }

  function terminaldeckAttributes(el) {
    var out = {}
    for (var i = 0; i < TERMINALDECK_ATTR_KEYS.length; i++) {
      var name = TERMINALDECK_ATTR_KEYS[i]
      var value = el.getAttribute(name)
      if (typeof value === 'string' && value !== '') out[name] = terminaldeckFlatten(value, TERMINALDECK_MAX_ATTR)
    }
    // What a control currently holds, which its attribute does not track. Never
    // for a password or file field: that value would be shown in the step list
    // and pasted into a prompt that is written to disk.
    if (typeof el.value === 'string' && el.value !== '' && !terminaldeckSecretField(el)) {
      out.value = terminaldeckFlatten(el.value, TERMINALDECK_MAX_ATTR)
    }
    return out
  }

  function terminaldeckDescribeElement(el) {
    var path = []
    var node = el
    var depth = 0
    while (node && node.nodeType === 1 && depth < TERMINALDECK_MAX_DEPTH) {
      path.push(terminaldeckDescribe(node))
      node = node.parentElement
      depth++
    }
    return {
      v: 1,
      path: path,
      text: terminaldeckFlatten(el.textContent, TERMINALDECK_MAX_TEXT),
      attributes: terminaldeckAttributes(el)
    }
  }
`
