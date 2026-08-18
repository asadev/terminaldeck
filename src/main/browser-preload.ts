import { chmodSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

/**
 * The preload that runs inside the *guest* page of an embedded browser tab.
 *
 * ## Why the script lives here as a string
 *
 * electron-vite builds exactly one preload entry (`src/preload/index.ts`), and
 * this repo's parallel-agent rule forbids touching the build config. A preload,
 * unlike everything else in `src/main`, has to exist as its own file on disk at
 * runtime because Electron loads it by path. So this module owns the source and
 * writes it out on first use. That also keeps the guest script honest: it is
 * plain ES5-ish JavaScript with no imports, which is all a sandboxed preload
 * can be anyway.
 *
 * ## Why it is so small
 *
 * The guest page is untrusted. This script only *reports facts* — tag names,
 * ids, whether an id is unique in its document, sibling positions. Every
 * decision (which selector wins, what is safe to show, what may reach a
 * terminal) happens in `selector.ts` in the main process, where it is tested.
 *
 * It runs in an isolated world with `contextIsolation` on and `sandbox` on, so
 * the page cannot see or poison it: the DOM is shared, but the JavaScript
 * globals and prototypes are not. Nothing is exposed via `contextBridge`, so
 * page code has no route to the IPC channels either.
 */

/** Guest → main: an element was clicked while inspecting. */
export const GUEST_ELEMENT_CHANNEL = 'terminaldeck-browser:element'
/** Main → guest: turn inspection on or off. */
export const GUEST_INSPECT_CHANNEL = 'terminaldeck-browser:set-inspect'
/** Guest → main: the user pressed Escape inside the page. */
export const GUEST_CANCEL_CHANNEL = 'terminaldeck-browser:inspect-cancelled'

/**
 * The three channels saved logins need, and why they are here rather than in a
 * second preload.
 *
 * A session-registered preload — the mechanism `browser-record-preload.ts` uses
 * — runs in *every* frame of the session, including cross-origin iframes. That
 * is right for a flow recorder, which wants to see everything that happens, and
 * wrong for a credential filler, which must never type a password into a frame
 * a third party controls. This preload is attached per view by
 * `browser-tab.ts`, and `browser-guest-dom.ts`'s own rule already applies here:
 * only the top document speaks. So the login work lives in the file with the
 * narrower reach.
 */
/** Guest → main: this document has a sign-in form; is there a login for it? */
export const GUEST_LOGIN_READY_CHANNEL = 'terminaldeck-browser:login-ready'
/** Main → guest: fill these into the form. Sent only in answer to the above. */
export const GUEST_LOGIN_FILL_CHANNEL = 'terminaldeck-browser:login-fill'
/** Guest → main: a sign-in was just submitted with these credentials. */
export const GUEST_LOGIN_SUBMIT_CHANNEL = 'terminaldeck-browser:login-submit'

export const GUEST_PRELOAD_FILENAME = 'browser-guest-preload.js'

/**
 * Test-hook attributes the guest looks for, most standard first.
 * Mirrors `TEST_ID_ATTRS` in selector.ts; the main process re-checks the name
 * against its own list, so a tampered payload cannot widen this.
 */
const TEST_ATTRS = ['data-testid', 'data-test-id', 'data-test', 'data-qa', 'data-cy', 'data-automation-id']

/** Attributes carried across for the capture panel. Closed list, by design. */
const ATTR_KEYS = ['aria-label', 'alt', 'placeholder', 'title', 'role', 'type', 'name', 'href']

/*
 * The highlight colours are the app's accent written out literally, because the
 * guest is a different document and cannot read `tokens.css`. If the accent in
 * tokens.css changes, change it here too — there is no way to share it.
 *
 * That instruction had already been ignored once: these stayed the purple-blue
 * #8588f2 through two accent changes, so the picker outlined elements in a
 * colour that appeared nowhere else in the product and read as a rendering bug
 * rather than a selection. This is the dark theme's --accent (#3b8fee, itself
 * the app icon's blue).
 *
 * ## A one-pixel outline, and no fill at all
 *
 * There used to be a 2px border over a 16% wash, and a 38% wash once an element
 * had been captured. On camera on 2026-08-16 that reads as the element being
 * *replaced* by a pale blue rectangle: the text under it washes out, and on a
 * card-shaped element the whole card turns blue. You cannot see what you are
 * pointing at, which is the one thing an element picker exists for. Vibeyard
 * draws a single-pixel outline and the content stays legible; that is the right
 * answer and this now does the same.
 *
 * The captured state is a *ring outside* the element rather than a fill inside
 * it. `box-shadow` paints beyond the box, so the element gains a halo and loses
 * none of its own contrast.
 */
const HIGHLIGHT_BORDER = '#3b8fee'
const CAPTURED_RING = '0 0 0 3px rgba(59, 143, 238, 0.35)'

/**
 * The guest script.
 *
 * Written with doubled backslashes because it is a template literal: `\\s` here
 * becomes `\s` in the generated file. It uses no template literals of its own
 * for the same reason.
 */
export const GUEST_PRELOAD_SOURCE = `'use strict'
/* Generated by Deck from src/main/browser-preload.ts. Do not edit — it is overwritten on launch. */
;(function () {
  var ipc = require('electron').ipcRenderer

  var CH_ELEMENT = ${JSON.stringify(GUEST_ELEMENT_CHANNEL)}
  var CH_INSPECT = ${JSON.stringify(GUEST_INSPECT_CHANNEL)}
  var CH_CANCEL = ${JSON.stringify(GUEST_CANCEL_CHANNEL)}
  var CH_LOGIN_READY = ${JSON.stringify(GUEST_LOGIN_READY_CHANNEL)}
  var CH_LOGIN_FILL = ${JSON.stringify(GUEST_LOGIN_FILL_CHANNEL)}
  var CH_LOGIN_SUBMIT = ${JSON.stringify(GUEST_LOGIN_SUBMIT_CHANNEL)}
  var TEST_ATTRS = ${JSON.stringify(TEST_ATTRS)}
  var ATTR_KEYS = ${JSON.stringify(ATTR_KEYS)}

  var MAX_DEPTH = 64
  var MAX_TEXT = 300
  var MAX_ATTR = 300
  var MAX_IDENT = 200

  var BASE_STYLE =
    'position:fixed;top:0;left:0;width:0;height:0;margin:0;padding:0;' +
    'box-sizing:border-box;pointer-events:none;display:none;' +
    'z-index:2147483647;border:1px solid ${HIGHLIGHT_BORDER};border-radius:2px;' +
    'background:transparent;'
  var RING_CAPTURED = ${JSON.stringify(CAPTURED_RING)}

  var active = false
  var overlay = null
  var hovered = null
  var savedCursor = null

  function flatten(value, max) {
    if (typeof value !== 'string') return ''
    // Cut first, collapse second. textContent on a big page is megabytes — and
    // clicking <body> while inspecting asks for exactly that — so an unbounded
    // collapse would hang the page on the click it is meant to capture.
    var raw = value.length > max * 8 ? value.slice(0, max * 8) : value
    var flat = raw.replace(/\\s+/g, ' ').trim()
    return flat.length > max ? flat.slice(0, max) : flat
  }

  function printable(value) {
    return !/[\\u0000-\\u001f\\u007f]/.test(value)
  }

  /**
   * The text a person can actually read on this element.
   *
   * Kept in step with \`terminaldeckVisibleText\` in browser-guest-dom.ts, which
   * documents it at length. The short version, because it is the fault he saw:
   * \`textContent\` runs every descendant together with no separator and includes
   * the ones the page has hidden, so a wrapper around a collapsed country picker
   * reported its whole list as one unbroken word. \`innerText\` is what is
   * rendered.
   *
   * Form controls report no text. A \`<select>\`'s is its options; a
   * \`<textarea>\`'s is its seed content. Neither names the field, and both are
   * already covered by the naming attributes.
   */
  function visibleText(el) {
    var tag = typeof el.localName === 'string' ? el.localName : ''
    if (tag === 'select' || tag === 'textarea' || tag === 'input' || tag === 'option') return ''
    var raw = typeof el.textContent === 'string' ? el.textContent : ''
    // innerText forces a layout and builds the whole rendered string before
    // anything can be sliced. Clicking <body> asks for exactly that.
    if (raw.length <= 20000) {
      try {
        if (typeof el.innerText === 'string' && el.innerText !== '') raw = el.innerText
      } catch (err) {
        // Already have textContent, which is a true if uglier answer.
      }
    }
    return flatten(raw, MAX_TEXT)
  }

  function ensureOverlay() {
    // isConnected, not a null check: a single-page app can wipe the DOM out
    // from under us, and a detached box would silently stop appearing.
    if (overlay && overlay.isConnected) return overlay
    var box = document.createElement('div')
    box.setAttribute('data-terminaldeck-inspector', '')
    box.style.cssText = BASE_STYLE
    document.documentElement.appendChild(box)
    overlay = box
    return box
  }

  function place(el, captured) {
    var box = ensureOverlay()
    var rect = el.getBoundingClientRect()
    box.style.transform = 'translate(' + Math.round(rect.left) + 'px,' + Math.round(rect.top) + 'px)'
    box.style.width = Math.max(0, Math.round(rect.width)) + 'px'
    box.style.height = Math.max(0, Math.round(rect.height)) + 'px'
    // Outside the element, never over it: the point of the highlight is that
    // you can still read what it is around.
    box.style.boxShadow = captured ? RING_CAPTURED : 'none'
    box.style.display = 'block'
  }

  function hideOverlay() {
    if (overlay) overlay.style.display = 'none'
  }

  function removeOverlay() {
    if (overlay && overlay.parentNode) overlay.parentNode.removeChild(overlay)
    overlay = null
  }

  function isUnique(selector) {
    try {
      return document.querySelectorAll(selector).length === 1
    } catch (err) {
      return false
    }
  }

  function cssStringOf(value) {
    return '"' + value.replace(/\\\\/g, '\\\\\\\\').replace(/"/g, '\\\\"') + '"'
  }

  function describe(el) {
    var d = { tag: typeof el.localName === 'string' ? el.localName : '' }

    var id = el.getAttribute('id')
    if (typeof id === 'string' && id !== '' && id.length <= MAX_IDENT && printable(id)) {
      d.id = id
      d.idUnique = isUnique('#' + CSS.escape(id))
    }

    for (var i = 0; i < TEST_ATTRS.length; i++) {
      var name = TEST_ATTRS[i]
      var value = el.getAttribute(name)
      if (typeof value === 'string' && value !== '' && value.length <= MAX_IDENT && printable(value)) {
        d.testAttr = name
        d.testValue = value
        d.testUnique = isUnique('[' + name + '=' + cssStringOf(value) + ']')
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
        // namespace — an <a> in SVG is not the same type as an <a> in HTML.
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

  function pathFrom(el) {
    var path = []
    var node = el
    var depth = 0
    while (node && node.nodeType === 1 && depth < MAX_DEPTH) {
      path.push(describe(node))
      node = node.parentElement
      depth++
    }
    return path
  }

  function isSecretField(el) {
    // The property wins where it exists — a page can set input.type without
    // touching the attribute — and the attribute covers the fake-DOM case.
    var type = typeof el.type === 'string' && el.type !== '' ? el.type : el.getAttribute('type')
    return typeof type === 'string' && type.toLowerCase() === 'password'
  }

  function attributesOf(el) {
    var out = {}
    for (var i = 0; i < ATTR_KEYS.length; i++) {
      var name = ATTR_KEYS[i]
      var value = el.getAttribute(name)
      if (typeof value === 'string' && value !== '') out[name] = flatten(value, MAX_ATTR)
    }
    // What a form control currently holds, which its attribute does not track.
    // Never for a password field: that value would be shown in the capture
    // panel and pasted into the agent's prompt, which is written to disk.
    if (typeof el.value === 'string' && el.value !== '' && !isSecretField(el)) {
      out.value = flatten(el.value, MAX_ATTR)
    }
    return out
  }

  function elementFrom(event) {
    var target = event.target
    if (!target || target.nodeType !== 1) return null
    if (overlay !== null && target === overlay) return null
    return target
  }

  function onOver(event) {
    var el = elementFrom(event)
    if (!el) return
    hovered = el
    place(el, false)
  }

  function onOut() {
    hovered = null
    hideOverlay()
  }

  function reposition() {
    if (hovered && hovered.isConnected) place(hovered, false)
    else hideOverlay()
  }

  function swallow(event) {
    // Inspecting must not also drive the page: a click on a nav link would
    // navigate away from the thing being inspected.
    event.preventDefault()
    event.stopPropagation()
    if (typeof event.stopImmediatePropagation === 'function') event.stopImmediatePropagation()
  }

  function onClick(event) {
    var el = elementFrom(event)
    swallow(event)
    if (!el) return
    place(el, true)
    var rect = el.getBoundingClientRect()
    ipc.send(CH_ELEMENT, {
      v: 1,
      path: pathFrom(el),
      text: visibleText(el),
      attributes: attributesOf(el),
      // Where the element is inside the view, in CSS pixels. The renderer
      // anchors the capture popup here — one that opened in a corner would make
      // you look away from the thing you had just pointed at.
      rect: {
        x: Math.round(rect.left),
        y: Math.round(rect.top),
        width: Math.round(rect.width),
        height: Math.round(rect.height)
      }
    })
  }

  function onKeyDown(event) {
    if (event.key !== 'Escape') return
    event.preventDefault()
    event.stopPropagation()
    disable()
    ipc.send(CH_CANCEL)
  }

  // Capture phase everywhere, so page handlers never see these first.
  var DOC_EVENTS = [
    ['mouseover', onOver],
    ['mouseout', onOut],
    ['click', onClick],
    ['mousedown', swallow],
    ['mouseup', swallow],
    ['dblclick', swallow],
    ['contextmenu', swallow],
    ['keydown', onKeyDown]
  ]
  var WIN_EVENTS = [
    ['scroll', reposition],
    ['resize', reposition]
  ]

  function enable() {
    if (active) return
    active = true
    for (var i = 0; i < DOC_EVENTS.length; i++) {
      document.addEventListener(DOC_EVENTS[i][0], DOC_EVENTS[i][1], true)
    }
    for (var j = 0; j < WIN_EVENTS.length; j++) {
      window.addEventListener(WIN_EVENTS[j][0], WIN_EVENTS[j][1], true)
    }
    var root = document.documentElement
    // Remember what the page had rather than blanking it, so turning
    // inspection off cannot destroy a cursor the page set itself.
    savedCursor = root.style.cursor
    root.style.cursor = 'crosshair'
    ensureOverlay()
  }

  function disable() {
    if (!active) return
    active = false
    hovered = null
    for (var i = 0; i < DOC_EVENTS.length; i++) {
      document.removeEventListener(DOC_EVENTS[i][0], DOC_EVENTS[i][1], true)
    }
    for (var j = 0; j < WIN_EVENTS.length; j++) {
      window.removeEventListener(WIN_EVENTS[j][0], WIN_EVENTS[j][1], true)
    }
    if (savedCursor !== null) {
      document.documentElement.style.cursor = savedCursor
      savedCursor = null
    }
    removeOverlay()
  }

  ipc.on(CH_INSPECT, function (event, enabled) {
    if (enabled === true) enable()
    else disable()
  })

  /* ------------------------------------------------------------ logins -- */

  /*
   * Saved logins: filling one in, and noticing a new one.
   *
   * The store, the encryption and every decision about *whether* to fill live
   * in browser-passwords.ts. This end does two mechanical things — find the
   * fields, and say what was typed into them — and it is deliberately incapable
   * of anything else: it holds no credentials between page loads, it never
   * reads a field it was not asked about, and it cannot ask for a password by
   * origin because the main process decides which origin it is answering for.
   *
   * ## Why the visibility test is a security control, not tidiness
   *
   * A page that wants somebody's saved password does not have to ask for it. It
   * can put a password field one pixel wide behind an image and wait for the
   * browser to fill it, which is why every real password manager refuses
   * invisible fields. So does this: a field with no client rects, no size, or
   * hidden by style is never filled and never read. Combined with the top-frame
   * rule this preload already lives under, and with exact-origin matching in
   * the store, that closes the three ways a fill turns into a leak.
   *
   * ## Why the credentials are remembered on input rather than read on submit
   *
   * Half the sign-in forms on the web are not forms. A single-page app clears
   * its fields, unmounts the component and navigates in JavaScript, so by the
   * time anything observable happens the values are gone — which is exactly the
   * case that matters here, because the audience for this app is building
   * single-page apps. Chrome solves it the same way: watch what is typed, and
   * offer at the last moment something is known to be happening.
   */

  var typed = null
  var offered = ''

  function shown(el) {
    if (!el || el.disabled || el.readOnly) return false
    var rects = el.getClientRects()
    if (!rects || rects.length === 0) return false
    var box = rects[0]
    if (box.width < 8 || box.height < 8) return false
    var style = window.getComputedStyle(el)
    if (style.visibility === 'hidden' || style.display === 'none') return false
    return parseFloat(style.opacity || '1') > 0.05
  }

  function passwordField() {
    var all = document.querySelectorAll('input[type="password"]')
    for (var i = 0; i < all.length; i++) {
      if (shown(all[i])) return all[i]
    }
    return null
  }

  /*
   * The field that names the account, chosen by what the page says about it.
   *
   * In document order and *before* the password field, because a "confirm
   * password" form has a second text input after it and filling that one is
   * how a password manager corrupts somebody's profile page. The autocomplete
   * attribute wins when the page bothered to set it; an email input is the next
   * best evidence; a plain text input is the fallback.
   */
  function usernameFieldFor(pw) {
    var inputs = document.querySelectorAll('input')
    var best = null
    var bestRank = 0
    for (var i = 0; i < inputs.length; i++) {
      var el = inputs[i]
      if (el === pw) break
      if (!shown(el)) continue
      var type = (el.getAttribute('type') || 'text').toLowerCase()
      if (type !== 'text' && type !== 'email' && type !== 'tel') continue
      var auto = (el.getAttribute('autocomplete') || '').toLowerCase()
      var rank = auto.indexOf('username') >= 0 || auto === 'email' ? 3 : type === 'email' ? 2 : 1
      if (rank >= bestRank) {
        best = el
        bestRank = rank
      }
    }
    return best
  }

  /*
   * Set a value the way a person would, so a framework notices.
   *
   * This preload runs in an isolated world, where the DOM node carries a
   * different wrapper prototype from the one the page's own React or Vue
   * patched. Assigning through it changes the real value without going through
   * the page's value tracker, so the input and change events below are what
   * tell the framework anything happened — without them the field shows the
   * password and the component's state stays empty, and the form submits blank.
   */
  function fillField(el, value) {
    if (!el) return
    el.focus()
    el.value = value
    el.dispatchEvent(new Event('input', { bubbles: true }))
    el.dispatchEvent(new Event('change', { bubbles: true }))
    el.blur()
  }

  function announce() {
    if (window.top !== window) return
    if (!passwordField()) return
    ipc.send(CH_LOGIN_READY, location.href)
  }

  ipc.on(CH_LOGIN_FILL, function (event, username, password) {
    if (typeof password !== 'string' || password === '') return
    var pw = passwordField()
    // Never over the top of something already there. A page that restored a
    // draft, or a person half way through typing, owns those characters.
    if (!pw || pw.value !== '') return
    var user = usernameFieldFor(pw)
    if (user && user.value === '' && typeof username === 'string' && username !== '') {
      fillField(user, username)
    }
    fillField(pw, password)
  })

  function remember() {
    var pw = passwordField()
    if (!pw || pw.value === '') return
    var user = usernameFieldFor(pw)
    typed = { username: user ? user.value : '', password: pw.value }
  }

  function offer() {
    if (window.top !== window || typed === null) return
    // One offer per credential per document. A form that submits, fails
    // validation and submits again is one sign-in attempt, not three prompts.
    var key = typed.username + '\\u0000' + typed.password
    if (key === offered) return
    offered = key
    ipc.send(CH_LOGIN_SUBMIT, location.href, typed.username, typed.password)
  }

  document.addEventListener('input', function (event) {
    var el = event.target
    if (el && el.tagName === 'INPUT' && (el.type === 'password' || el.type === 'text' || el.type === 'email')) {
      remember()
    }
  }, true)

  document.addEventListener('submit', offer, true)

  document.addEventListener('keydown', function (event) {
    if (event.key === 'Enter') offer()
  }, true)

  document.addEventListener('click', function (event) {
    var el = event.target
    // Walk up: the click nearly always lands on a span inside the button.
    for (var i = 0; el && i < 4; i++) {
      var tag = el.tagName
      var type = el.getAttribute ? (el.getAttribute('type') || '').toLowerCase() : ''
      if (tag === 'BUTTON' || (tag === 'INPUT' && (type === 'submit' || type === 'button'))) {
        offer()
        return
      }
      el = el.parentElement
    }
  }, true)

  // The last moment anything is known to be happening. A single-page app that
  // signs in and then hard-navigates never fires submit, and this is the only
  // event left before the document is gone.
  window.addEventListener('pagehide', offer)

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', announce)
  } else {
    announce()
  }
  // Sign-in forms are routinely rendered after the first paint, so one look at
  // DOMContentLoaded misses most single-page apps. Two more, cheaply: a
  // querySelector for one attribute is not something worth debouncing.
  setTimeout(announce, 700)
  setTimeout(announce, 2200)
})()
`

/**
 * Write the guest preload next to the app's other user data and return its
 * absolute path.
 *
 * Rewritten every launch rather than cached: a file left behind by an older
 * version would otherwise keep running against a newer main process.
 *
 * The unlink-then-create dance is not ceremony. `writeFileSync` has two
 * behaviours that matter for a file the app *executes*:
 *
 * - `mode` is ignored when the file already exists, so writing 0o600 over a
 *   file someone else created 0o666 leaves it world-writable — and then we load
 *   it into a preload;
 * - it follows symlinks, so a link planted at this path would send the write
 *   somewhere else entirely and keep the link in place for next time.
 *
 * Removing the path first drops a symlink rather than following it, and `wx`
 * refuses to write anything that reappeared in between rather than writing
 * through it.
 */
export function writeGuestPreload(userDataDir: string): string {
  mkdirSync(userDataDir, { recursive: true })
  const target = join(userDataDir, GUEST_PRELOAD_FILENAME)
  rmSync(target, { force: true })
  // Owner-only: this file is executed by the app, so nothing else should be
  // able to rewrite what it executes.
  writeFileSync(target, GUEST_PRELOAD_SOURCE, { encoding: 'utf8', mode: 0o600, flag: 'wx' })
  // Belt and braces, and honestly so: after the unlink above the create always
  // applies `mode`, so this only matters under a umask strict enough to strip
  // the owner's own bits — which would leave the app unable to read the file it
  // is about to load. Not covered by a test, because setting the umask inside a
  // vitest worker is not something a test should be doing.
  chmodSync(target, 0o600)
  return target
}
