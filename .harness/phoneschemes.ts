/**
 * The browser client's colour picker, at a phone width, on its own.
 *
 * The Settings screen it lives on is four taps behind a real pairing with a
 * real machine, which `web-drive.mjs` can do and which is far too much
 * machinery to look at a grid of swatches. What this page mounts is the block
 * itself, against the client's own stylesheet, with the same host interface
 * `main.ts` passes it — so what is on screen is what is on the phone.
 *
 * `?wide` for the two-column layout a browser tab on a monitor gets.
 */
import '../pwa/src/styles.css'
import { schemeBlock, type SchemePickerHost } from '../pwa/src/scheme-picker'
import { FOLLOW_APP_SCHEME_ID, type TerminalScheme } from '../src/shared/terminal-theme'

const root = document.getElementById('root')!
root.className = 'screen'

const host: SchemePickerHost = {
  chosen: new URLSearchParams(location.search).get('scheme') ?? FOLLOW_APP_SCHEME_ID,
  customs: [] as TerminalScheme[],
  editing: new URLSearchParams(location.search).has('edit'),
  importing: new URLSearchParams(location.search).has('paste'),
  draft: '',
  problem: null,
  said: null,
  choose(id) {
    host.chosen = id
    host.refresh()
  },
  keep(customs, chooseId) {
    host.customs = customs
    if (chooseId !== undefined) host.chosen = chooseId
    host.refresh()
  },
  preview() {},
  refresh() {
    draw()
  },
}

function draw(): void {
  const caption = document.createElement('p')
  caption.className = 'caption'
  caption.textContent = 'Terminal'
  root.replaceChildren(caption, schemeBlock(host))
}

document.body.style.padding = '16px'
draw()
