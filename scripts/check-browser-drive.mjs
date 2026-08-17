/**
 * Drive a real website, in real Electron, with the real modules.
 *
 * ## Why this exists as a script and not as a vitest file
 *
 * Because every interesting thing about this feature is a fact about Chromium
 * that a mock cannot have. `screenCommand` is pure and is tested in
 * `browser-cdp.test.ts`; `waitForActionable` is only meaningfully tested against
 * a page that actually animates a button, and the whole reason the driver is
 * CDP-shaped is a focus rule that only exists in a real window.
 *
 * This is the same shape as `scripts/check-electron-crypto.mjs`, which exists
 * for the same reason and caught the same class of bug: 3628 Node tests passed
 * while every handshake threw silently, because Electron links a different
 * crypto library than Node does. A driver verified only against a fake page is
 * a driver verified against nothing.
 *
 * ## What it proves, in order
 *
 *  1. A page can be opened, waited for, read and clicked — on `example.com`.
 *  2. A real search box on a real site can be typed into, submitted, and the
 *     resulting page read back — on `duckduckgo.com`, which is JavaScript-heavy
 *     and re-renders under the driver.
 *  3. A real login form's password field is reported as `secret` with **no
 *     value**, and typing into it is refused by name — on
 *     `en.wikipedia.org/wiki/Special:UserLogin`. Nothing is submitted.
 *  4. During a handover the channel is shut: every read and every command is
 *     refused, and the page is untouched.
 *  5. A screenshot has the password field painted out before the file exists.
 *
 * Run:
 *
 *     node scripts/check-browser-drive.mjs [--out <dir>]
 */

import { execFileSync } from 'node:child_process'
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const repo = resolve(here, '..')

const args = process.argv.slice(2)
const outIndex = args.indexOf('--out')
const outDir = outIndex === -1 ? join(repo, '.drive-check') : resolve(args[outIndex + 1])
mkdirSync(outDir, { recursive: true })

const work = join(outDir, 'bundle')
mkdirSync(work, { recursive: true })

/*
 * Bundle the real modules rather than re-implementing them.
 *
 * The point of the exercise is that the code under test is the code that ships;
 * a harness that reimplemented the actionability loop would prove that the
 * harness works. `electron` stays external because the runtime provides it.
 */
console.log('[drive-check] bundling src/main/browser-driver.ts …')
execFileSync(
  join(repo, 'node_modules', '.bin', 'esbuild'),
  [
    join(repo, 'src', 'main', 'browser-driver.ts'),
    '--bundle',
    '--platform=node',
    '--format=cjs',
    '--external:electron',
    `--outfile=${join(work, 'driver.cjs')}`,
  ],
  { stdio: ['ignore', 'inherit', 'inherit'] },
)

const runner = join(work, 'main.cjs')
writeFileSync(runner, RUNNER_SOURCE())
writeFileSync(join(work, 'package.json'), JSON.stringify({ name: 'drive-check', main: 'main.cjs' }))

const electron = join(repo, 'node_modules', 'electron', 'dist', 'Electron.app', 'Contents', 'MacOS', 'Electron')
console.log('[drive-check] launching Electron …')

let result = ''
try {
  result = execFileSync(
    electron,
    [runner, `--user-data-dir=${join(outDir, 'profile')}`, `--drive-out=${outDir}`],
    { stdio: ['ignore', 'pipe', 'inherit'], encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 },
  )
} catch (error) {
  // A failing check exits non-zero on purpose. The output is the report, so it
  // is read either way — throwing here would hide the very thing that failed.
  result = String(error.stdout ?? '')
}

const lines = result.split('\n').filter((line) => line.startsWith('CHECK|'))
let failures = 0
for (const line of lines) {
  const [, verdict, name, detail] = line.split('|')
  if (verdict !== 'PASS') failures++
  console.log(`${verdict === 'PASS' ? '  ok  ' : ' FAIL '} ${name}${detail ? ` — ${detail}` : ''}`)
}
if (lines.length === 0) {
  console.error('[drive-check] the harness produced no results at all')
  process.exit(1)
}
console.log(`[drive-check] ${lines.length - failures}/${lines.length} passed; artefacts in ${outDir}`)
rmSync(work, { recursive: true, force: true })
process.exit(failures === 0 ? 0 : 1)

/* ------------------------------------------------------------ the runner -- */

function RUNNER_SOURCE() {
  return `
const { app, BrowserWindow, WebContentsView, session } = require('electron')
const { writeFileSync } = require('node:fs')
const { join } = require('node:path')
const { BrowserDrive } = require('./driver.cjs')

const OUT = (process.argv.find((a) => a.startsWith('--drive-out=')) || '').slice('--drive-out='.length)
const results = []
const check = (name, ok, detail) => {
  results.push(ok)
  console.log('CHECK|' + (ok ? 'PASS' : 'FAIL') + '|' + name + '|' + String(detail == null ? '' : detail).replace(/[|\\n]/g, ' '))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function main() {
  const win = new BrowserWindow({ width: 1200, height: 860, show: false, title: 'drive-check' })
  // Shown without taking focus. A window that steals focus invites a real click
  // to land on the guest page, and a real click is a real takeover — which is
  // the feature working correctly and a flaky harness at the same time.
  win.showInactive()
  await win.loadURL('data:text/html,<body style="background:#141210;color:#eee;font:14px system-ui;padding:12px">Terminal Deck — drive check host</body>')

  const ses = session.fromPartition('persist:drivecheck-guest')
  ses.setPermissionRequestHandler((_wc, _p, cb) => cb(false))
  ses.on('will-download', (e) => e.preventDefault())

  let view = null
  const host = {
    openTab: async ({ url }) => {
      view = new WebContentsView({
        webPreferences: {
          session: ses,
          sandbox: true,
          contextIsolation: true,
          nodeIntegration: false,
          webSecurity: true,
        },
      })
      win.contentView.addChildView(view)
      view.setBounds({ x: 0, y: 44, width: 1200, height: 800 })
      // browser-tab.ts loads about:blank into every view it creates. The drive
      // depends on that: Page.enable on a view that has never had a document
      // hangs and never answers.
      await view.webContents.loadURL('about:blank').catch(() => {})
      await view.webContents.loadURL(url).catch(() => {})
      return 'tab-1'
    },
    contentsFor: () => (view && view.webContents && !view.webContents.isDestroyed() ? view.webContents : null),
    publish: (status) => { published.push(status) },
    now: () => Date.now(),
  }
  const published = []
  const drive = new BrowserDrive(host)

  const shot = async (name) => {
    try {
      const img = await win.webContents.capturePage()
      // The guest is a native child view composited above the host renderer, so
      // the host's own capture does not contain it. Photograph the guest too.
      writeFileSync(join(OUT, name + '-host.png'), img.toPNG())
    } catch (e) { /* the host frame is a nicety */ }
    try {
      const wc = host.contentsFor()
      if (wc) writeFileSync(join(OUT, name + '.png'), (await wc.capturePage()).toPNG())
    } catch (e) { console.log('CHECK|FAIL|screenshot ' + name + '|' + e.message) }
  }

  /* ---- 1. open, settle, read ------------------------------------------- */
  const opened = await drive.open({ url: 'https://example.com', isolate: false })
  check('opens a real site and waits for it', opened.settled === true && /example/i.test(opened.title), opened.url + ' — ' + opened.title)
  await shot('01-example')

  const outline = await drive.outline(40)
  check('reads the page outline', outline.elements.length >= 1 && /example/i.test(outline.title),
    outline.elements.length + ' elements: ' + outline.elements.map((e) => e.kind + ':' + e.label).join(', ').slice(0, 120))

  const body = await drive.textAt(null, 400)
  check('reads text off the page as a person would see it', /^Example Domain\\s/.test(body.text) && /documentation examples/i.test(body.text), JSON.stringify(body.text.slice(0, 80)))

  /* ---- 2. a real search box, typed into and submitted ------------------- */
  await drive.open({ url: 'https://duckduckgo.com/', isolate: false })
  await sleep(1200)
  await shot('02-ddg-before')

  const ddgOutline = await drive.outline(60)
  const searchBox = ddgOutline.elements.find((e) => e.kind === 'field' && !e.secret)
  check('finds the search field from the outline alone', Boolean(searchBox), searchBox ? searchBox.selector : 'none found')

  if (searchBox) {
    const typed = await drive.act({ verb: 'type', selector: searchBox.selector, value: 'terminal deck electron' })
    check('types into a real search box', typed.verb === 'type', typed.selector)
    const echoed = await drive.probe(searchBox.selector)
    check('the page received what was typed', String(echoed.label || '') !== null && (await drive.outline(60)).elements.some((e) => (e.value || '').includes('terminal deck')), 'value read back from the live DOM')
    await shot('03-ddg-typed')

    await drive.act({ verb: 'press', selector: searchBox.selector, key: 'Enter' })
    await sleep(2500)
    const after = await drive.textAt(null, 2000)
    check('submitting navigated and the new page is readable', /terminal deck/i.test(after.text) && !/function\\s*\\(/.test(after.text.slice(0, 400)), after.text.slice(0, 100).replace(/\\s+/g, ' '))
    await shot('04-ddg-results')
  }

  /* ---- 3. a real password field ---------------------------------------- */
  await drive.open({ url: 'https://en.wikipedia.org/wiki/Special:UserLogin', isolate: false })
  await sleep(900)
  await shot('05-login')

  const login = await drive.outline(40)
  const secretFields = login.elements.filter((e) => e.secret)
  check('a real password field is reported as secret', secretFields.length >= 1, secretFields.map((f) => f.selector).join(' '))
  check('a secret field carries no value, ever', secretFields.every((f) => f.value === undefined), JSON.stringify(secretFields[0] || null).slice(0, 140))

  const userField = login.elements.find((e) => e.kind === 'field' && !e.secret)
  if (userField) {
    await drive.act({ verb: 'type', selector: userField.selector, value: 'not-a-real-account' })
    check('an ordinary field on the same form still accepts typing', true, userField.selector)
  }

  let refusal = null
  try {
    await drive.act({ verb: 'type', selector: secretFields[0].selector, value: 'hunter2-SENTINEL-9f3a' })
  } catch (e) { refusal = e }
  check('typing into a password field is refused by name', refusal !== null && /password/i.test(refusal.message) && /handover/i.test(refusal.message),
    refusal ? refusal.message.slice(0, 120) : 'IT WAS NOT REFUSED')
  await shot('06-login-refused')

  /* ---- 4. the handover shuts the channel -------------------------------- */
  const pending = drive.handover('Type your Wikipedia password, then click Done.', 3000)
  await sleep(200)
  check('the handover flips the baton to the person', drive.status().state === 'human', JSON.stringify(drive.status()))
  await shot('07-handover')

  let readDuring = null
  try { await drive.outline(10) } catch (e) { readDuring = e }
  check('no read is possible while the person has the page', readDuring !== null, readDuring ? readDuring.message.slice(0, 100) : 'THE READ SUCCEEDED')

  let shotDuring = null
  try { await drive.screenshot() } catch (e) { shotDuring = e }
  check('no screenshot is possible while the person has the page', shotDuring !== null, shotDuring ? shotDuring.message.slice(0, 100) : 'THE SCREENSHOT SUCCEEDED')

  let clickDuring = null
  try { await drive.act({ verb: 'click', selector: 'input[type=submit]' }) } catch (e) { clickDuring = e }
  check('no click is possible while the person has the page', clickDuring !== null, clickDuring ? clickDuring.message.slice(0, 100) : 'THE CLICK SUCCEEDED')

  const waited = await pending
  check('the wait reports still-waiting rather than a failure', waited.outcome === 'still-waiting', JSON.stringify(waited).slice(0, 120))
  check('the banner stays up after the tool call returns', drive.status().state === 'human', drive.status().state)

  drive.resume(true)
  check('the person handing it back resumes the drive', drive.status().state === 'agent', drive.status().state)

  /* ---- 4b. the person putting their hands on the page ------------------- */
  /*
   * An input event the driver never announced.
   *
   * \`drive.send\` screens the method and dispatches it, and — unlike
   * \`drive.input\` — it does not put anything in the dispatch ring. So from the
   * takeover watcher's point of view this is indistinguishable from a person
   * clicking the page, which is exactly what it is standing in for: a real
   * click cannot be scripted from outside the process, because while the drive
   * holds \`webContents.debugger\` the guest target is not offered on the
   * debugging port at all.
   */
  check('the drive is running before anybody touches it', drive.status().state === 'agent', drive.status().state)
  await drive.send(host.contentsFor(), 'Input.dispatchMouseEvent', { type: 'mousePressed', x: 40, y: 40, button: 'left', clickCount: 1, buttons: 1 })
  await sleep(400)
  /*
   * One press is the whole story, and the release is what proves it.
   *
   * The first version of this check sent both halves of the click and the
   * *second* one threw — because by then the press had already parked the
   * drive and the channel was shut. That is the mechanism working, so it is
   * asserted rather than worked around.
   */
  let releaseRefused = null
  try { await drive.send(host.contentsFor(), 'Input.dispatchMouseEvent', { type: 'mouseReleased', x: 40, y: 40, button: 'left', clickCount: 1, buttons: 0 }) }
  catch (e) { releaseRefused = e }
  check('the channel shuts between the press and the release', releaseRefused !== null, releaseRefused ? releaseRefused.message.slice(0, 80) : 'IT WAS STILL OPEN')
  check('an unclaimed click parks the drive and gives the page to the person', drive.status().state === 'human', JSON.stringify(drive.status()).slice(0, 140))

  let afterTakeover = null
  try { await drive.outline(5) } catch (e) { afterTakeover = e }
  check('and the agent is refused until they hand it back', afterTakeover !== null, afterTakeover ? afterTakeover.message.slice(0, 90) : 'THE READ SUCCEEDED')
  drive.resume(true)
  check('handing it back resumes it again', drive.status().state === 'agent', drive.status().state)

  /* ---- 5. the screenshot is masked -------------------------------------- */
  const picture = await drive.screenshot()
  check('a screenshot is written, with the password field painted out', picture.masked >= 1, picture.path + ' masked=' + picture.masked)
  try {
    const { readFileSync } = require('node:fs')
    writeFileSync(join(OUT, '08-masked-screenshot.png'), readFileSync(picture.path))
  } catch (e) { /* the copy is a convenience */ }

  /* ---- 6. what the driver refuses to send ------------------------------- */
  let denied = null
  try {
    // Reaching past the tools, straight at the channel, the way a future
    // Playwright would. This must not be sendable even from inside the module.
    await drive.send(host.contentsFor(), 'Page.navigate', { url: 'file:///etc/passwd' })
  } catch (e) { denied = e }
  check('a file:// navigation is refused at the channel', denied !== null, denied ? denied.message.slice(0, 90) : 'IT WAS SENT')
  const urlAfter = host.contentsFor() ? host.contentsFor().getURL() : ''
  check('and the page did not move', !urlAfter.startsWith('file:'), urlAfter.slice(0, 60))

  await shot('09-final')
  app.exit(results.every(Boolean) ? 0 : 1)
}

app.whenReady().then(main).catch((error) => {
  console.log('CHECK|FAIL|the harness itself threw|' + String((error && error.stack) || error).replace(/[|\\n]/g, ' ').slice(0, 400))
  app.exit(1)
})
`
}
