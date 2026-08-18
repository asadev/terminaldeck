/**
 * Drive the browser client, at a phone width and at a desktop width, and look.
 *
 * The standing rule in this repo: compiling is not working, and a change that is
 * visible has to be looked at. Neither vitest nor the typechecker can see this
 * client at all — `main.ts` builds its DOM against a real browser — so the only
 * thing that can answer "does the new localhost screen actually group anything"
 * is a real browser with a real machine on the other end of a real relay.
 *
 * What is real in a run of this: the relay is `wss://relay.terminaldeck.dev`, the
 * host is the desktop's own remote endpoint under `scripts/remote-host.sh`, the
 * six digits come off a real `startBeacon`, and the pairing is approved by a
 * `curl` standing in for the person at the machine. Nothing about the client is
 * stubbed.
 *
 *   node .harness/web-drive.mjs <code> [--url http://localhost:5301] [--out /tmp/shots]
 */

import { spawn } from 'node:child_process'
import { mkdirSync } from 'node:fs'
/*
 * Resolved by path rather than by name, and that is not laziness.
 *
 * Playwright is not a dependency of this repo and must not become one: it would
 * be a browser download in every `npm ci`, on CI runners that have no use for
 * it, for a harness that runs on one machine. It is installed once, globally, and
 * this file finds it — `PLAYWRIGHT_HOME` overrides for anyone whose copy is
 * elsewhere.
 */
const playwrightHome = process.env.PLAYWRIGHT_HOME ?? '/Users/apple/scrape-tools/node_modules/playwright'
const { chromium } = await import(`${playwrightHome}/index.mjs`)

const args = process.argv.slice(2)
const flag = (name, fallback) => {
  const at = args.indexOf(`--${name}`)
  return at === -1 || at + 1 >= args.length ? fallback : args[at + 1]
}
const base = flag('url', 'http://localhost:5301')
const out = flag('out', '/tmp/webshots')
const control = flag('control', '8878')
/**
 * A second machine, when one is running. Multi-host is the largest thing this
 * pass added and it is the one that cannot be seen with a single pairing: the
 * header's switcher, "Pair another machine", and the rule that a port name
 * belongs to one machine all need two.
 */
const control2 = flag('control2', '')
/**
 * Stop after pairing.
 *
 * For pointing this at `https://app.terminaldeck.dev` — the client that is
 * actually deployed, which is a different build from the one in this working
 * tree. Everything after the pairing exercises screens that build does not have,
 * so a full run there would fail on a control that is not a defect. What is worth
 * knowing about the live deployment is exactly this: does it still find a machine
 * through the relay and open a session list.
 */
const pairOnly = args.includes('--pair-only')

const PHONE = { width: 390, height: 844 }
const DESKTOP = { width: 1440, height: 900 }

mkdirSync(out, { recursive: true })

const say = (line) => process.stdout.write(`${line}\n`)

async function shoot(page, name) {
  await page.screenshot({ path: `${out}/${name}.png` })
  say(`shot ${name}`)
}

/** What the page says it is, so a run is readable without opening the images. */
async function describe(page) {
  return page.evaluate(() => {
    const text = (selector) => document.querySelector(selector)?.textContent?.trim() ?? null
    return {
      title: text('.header__title'),
      subtitle: text('.header__subtitle'),
      banner: document.querySelector('.banner')?.className.includes('online')
        ? 'online'
        : text('.banner__text'),
      tabs: [...document.querySelectorAll('.tab')].map((tab) => tab.textContent),
      groups: [...document.querySelectorAll('.portgroup__head')].map((head) => head.textContent),
      rows: [...document.querySelectorAll('.port__label, .dev__name')].map((row) => row.textContent),
      settings: [...document.querySelectorAll('.setting__title')].map((row) => row.textContent),
      machines: [...document.querySelectorAll('.machine__name')].map((row) => row.textContent),
      sessions: [...document.querySelectorAll('.session__title')].map((row) => row.textContent),
    }
  })
}

/*
 * The full Chromium rather than the headless shell.
 *
 * The shell is a separate download and this machine has only the browser. It is
 * also the better choice for what this is for: the headless shell has no window
 * chrome and a slightly different compositor, and the point of a run is to look
 * at what a person would see.
 */
/*
 * The Chrome that is installed, rather than Playwright's own download.
 *
 * `channel: 'chrome'` launches the system browser with its own temporary
 * profile, so nothing here touches a window somebody has open. Playwright's
 * bundled Chromium is the usual choice and is not usable on this machine — the
 * cached copy is missing its framework — and this is the better answer anyway:
 * the client ships to whatever browser a person already has.
 */
const browser = await chromium.launch({ channel: 'chrome' })
const context = await browser.newContext({ viewport: PHONE, deviceScaleFactor: 2 })
const page = await context.newPage()
page.on('console', (message) => {
  if (message.type() === 'error') say(`console-error ${message.text()}`)
})
page.on('pageerror', (error) => say(`page-error ${error.message}`))

await page.goto(base, { waitUntil: 'networkidle' })
await shoot(page, '01-pair-phone')

/*
 * The code is minted *here*, immediately before it is typed, and that is not
 * tidiness.
 *
 * A pairing token is worth sixty seconds and one redemption, and the beacon that
 * makes it findable is keyed on the digits — so a code minted when the harness
 * started and typed three minutes later fails twice over, and the failure reads
 * as a broken client. `.harness/web-beacon.ts` mints and claims in one step and
 * prints the digits when the slot is live; this waits for that line.
 */
const beacons = []
async function mint(on) {
  const beacon = spawn('npx', ['tsx', '.harness/web-beacon.ts', '--control', on], {
    cwd: new URL('..', import.meta.url).pathname,
  })
  beacons.push(beacon)
  return new Promise((resolve, reject) => {
    const failed = setTimeout(() => reject(new Error('the beacon never claimed its slot')), 30_000)
    beacon.stdout.on('data', (chunk) => {
      const found = /^ready (\d{6})$/m.exec(String(chunk))
      if (found === null) return
      clearTimeout(failed)
      resolve(found[1])
    })
    beacon.stderr.on('data', (chunk) => say(`beacon ${String(chunk).trim()}`))
  })
}

/** Type six digits and watch the banner until the socket is live. */
async function pair(code, on) {
  await page.fill('.code-field', code)
  let banner = ''
  for (let tick = 0; tick < 40; tick += 1) {
    const now = await page.evaluate(() => ({
      banner: document.querySelector('.banner')?.textContent?.trim() ?? '',
      online: document.querySelector('.banner')?.className.includes('--online') ?? false,
    }))
    if (now.banner !== banner) {
      banner = now.banner
      say(`banner ${banner === '' ? '(none)' : banner}`)
    }
    if (now.online) break
    if (tick === 6) {
      // The human at the machine. Approving a device is deliberately something
      // software does not do for itself, so the harness stands in for the person.
      const approved = await fetch(`http://127.0.0.1:${on}/approve`).then((answer) => answer.json())
      say(`approved ${JSON.stringify(approved)}`)
    }
    await page.waitForTimeout(500)
  }
  await page.waitForTimeout(1500)
}

const code = await mint(control)
say(`code ${code}`)

// The field submits itself on the sixth digit. What follows is a memory-hard
// derivation, a round trip to the relay and a Noise handshake, so the wait is
// real — and it is watched rather than slept through, because the banner is the
// one thing in this client that is supposed to always be telling the truth.
await pair(code, control)
await shoot(page, '02-paired')

await shoot(page, '03-sessions-phone')
say(`sessions ${JSON.stringify(await describe(page), null, 2)}`)

if (pairOnly) {
  await browser.close()
  for (const beacon of beacons) beacon.kill('SIGINT')
  say('done')
  process.exit(0)
}

/** Click a tab by its label, when it is there. */
async function tab(name) {
  const found = page.locator('.tab', { hasText: name })
  if ((await found.count()) === 0) return false
  await found.first().click()
  await page.waitForTimeout(1200)
  return true
}

if (await tab('Localhost')) {
  await page.waitForTimeout(2500)
  await shoot(page, '04-localhost-phone')
  say(`localhost ${JSON.stringify(await describe(page), null, 2)}`)
}

/*
 * The interactions, exercised rather than assumed.
 *
 * A screenshot of a list proves the list draws. It does not prove that the fold
 * remembers, that a name promotes a row into another group, or that the menu
 * opens on the row it was pressed on — and those three are the whole of what was
 * added. Each step prints what it found, so a run reads as a transcript.
 */
if (await tab('Localhost')) {
  // Open one of the groups that starts folded. The three that do are the noise —
  // the app's own ports, other services, and what could not be named.
  const folded = page.locator('.portgroup__head', { hasText: 'Other services' })
  if ((await folded.count()) > 0) {
    const before = await page.locator('.port').count()
    await folded.first().click()
    await page.waitForTimeout(400)
    say(`fold-open rows ${before} -> ${await page.locator('.port').count()}`)
    await shoot(page, '10-group-open')
  }

  // Name a port, and watch it leave the group it was derived into.
  const first = page.locator('.port').first()
  await first.locator('.port__more').click()
  await page.waitForTimeout(300)
  await shoot(page, '11-row-menu')
  say(`menu ${JSON.stringify(await page.locator('.port__menu-item').allTextContents())}`)
  await page.locator('.port__menu-item', { hasText: 'Name this port' }).first().click()
  await page.waitForTimeout(300)
  await page.fill('.rename__field', 'Client billing')
  await shoot(page, '12-renaming')
  await page.locator('.rename__save').click()
  await page.waitForTimeout(600)
  say(`after-rename ${JSON.stringify(await describe(page))}`)
  await shoot(page, '13-named-port')

  // And the copy, which is the one action a browser can genuinely be refused.
  await page.locator('.port').first().locator('.port__more').click()
  await page.waitForTimeout(200)
  await page.locator('.port__menu-item', { hasText: 'Copy address' }).first().click()
  await page.waitForTimeout(400)
  say(`toast ${await page.locator('.toast').textContent()}`)
  await shoot(page, '14-copied')

  // The fold and the name are per machine and are meant to survive a reload.
  await page.reload({ waitUntil: 'networkidle' })
  await page.waitForTimeout(3500)
  await tab('Localhost')
  await page.waitForTimeout(2000)
  say(`after-reload ${JSON.stringify(await describe(page))}`)
  await shoot(page, '15-after-reload')
}

if (await tab('Settings')) {
  await shoot(page, '05-settings-phone')
  say(`settings ${JSON.stringify(await describe(page), null, 2)}`)
  // The text size, which is the one setting here that changes the terminal.
  await page.locator('.setting__step', { hasText: '+' }).click()
  await page.locator('.setting__step', { hasText: '+' }).click()
  await page.waitForTimeout(300)
  /*
   * Scoped to the Text size row rather than "the last value on the screen".
   *
   * It was `.setting__value` `.last()`, which was the text size only for as long
   * as Settings ended with it. An About row was added underneath and this line
   * started reporting `text-size 0.3.0` — a build number, printed under the name
   * of a font size, in a transcript whose whole job is to be read instead of the
   * images. A harness that quietly reports the wrong field is worse than one
   * that fails.
   */
  say(
    `text-size ${await page
      .locator('.setting', { hasText: 'Text size' })
      .locator('.setting__value')
      .first()
      .textContent()}`,
  )
  await shoot(page, '16-text-size')

  await page.locator('.setting', { hasText: 'Machines' }).first().click()
  await page.waitForTimeout(600)
  await shoot(page, '06-machines-phone')
  say(`machines ${JSON.stringify(await describe(page), null, 2)}`)

  // Rename the machine, which is the complaint this screen exists for: "I am not
  // able to edit the name of this account and I don't know where it belongs to."
  await page.locator('.machine .port__more').first().click()
  await page.waitForTimeout(300)
  say(`machine-menu ${JSON.stringify(await page.locator('.port__menu-item').allTextContents())}`)
  await page.locator('.port__menu-item', { hasText: 'Name this machine' }).first().click()
  await page.waitForTimeout(300)
  await page.fill('.rename__field', 'Harness Mac')
  await page.locator('.rename__save').click()
  await page.waitForTimeout(600)
  say(`renamed ${JSON.stringify(await page.locator('.machine__name').allTextContents())}`)
  await shoot(page, '17-machine-renamed')
}

/*
 * A second machine, from the screen that offers one.
 *
 * This is the part the browser client could not do at all before tonight: it held
 * one credential under one key, so a person with a Mac and a PC unpaired one to
 * look at the other. Everything below is the whole feature — pair, switch, and
 * the property that makes the switch safe, which is that nothing from the first
 * machine is still on screen under the second machine's name.
 */
if (control2 !== '') {
  await tab('Settings')
  await page.locator('.setting', { hasText: 'Machines' }).first().click()
  await page.waitForTimeout(500)
  await page.locator('.machines__add').click()
  await page.waitForTimeout(500)
  await shoot(page, '18-pair-another')
  const second = await mint(control2)
  say(`code2 ${second}`)
  await pair(second, control2)
  say(`two-machines ${JSON.stringify(await describe(page))}`)
  await shoot(page, '19-second-machine')

  await tab('Settings')
  await page.locator('.setting', { hasText: 'Machines' }).first().click()
  await page.waitForTimeout(500)
  say(`machines ${JSON.stringify(await page.locator('.machine__name').allTextContents())}`)
  await shoot(page, '20-two-machines')

  // The names are per machine: the port named on the first machine must not
  // appear on the second's list.
  await tab('Localhost')
  await page.waitForTimeout(2500)
  say(`second-localhost ${JSON.stringify(await describe(page))}`)
  await shoot(page, '21-second-localhost')

  // And back, by the switcher in the header — the control that only exists once
  // there is more than one machine.
  await page.locator('.header__machine').click()
  await page.waitForTimeout(500)
  await page.locator('.machine__choose').first().click()
  await page.waitForTimeout(3000)
  await tab('Localhost')
  await page.waitForTimeout(2500)
  say(`back-on-first ${JSON.stringify(await describe(page))}`)
  await shoot(page, '22-back-on-first')
}

/*
 * A real session, opened and looked at.
 *
 * The terminal is the one screen in this client that was not touched by this
 * pass, which is exactly why it is worth a look: the text size is new, it is read
 * when the emulator is built, and a font size the protocol refuses closes the
 * socket rather than failing quietly. So this starts a session on the machine,
 * opens it, and reads back what the emulator actually holds.
 */
await tab('Sessions')
// Started from the client's own button rather than over the control port. A
// session created out of band is a session this client has not been told about —
// the protocol pushes a list when something changes and the harness's `/start`
// does not — and pressing the button is also the path a person takes.
await page.locator('.start > .button').click()
await page.waitForTimeout(3500)
await shoot(page, '23-sessions-with-one')
say(`sessions ${JSON.stringify(await describe(page))}`)

const row = page.locator('.session').first()
if ((await row.count()) > 0) {
  await row.click()
  await page.waitForTimeout(2500)
  await shoot(page, '24-terminal')
  say(
    `terminal ${JSON.stringify(
      await page.evaluate(() => ({
        rows: document.querySelectorAll('.xterm-rows > div').length,
        font: getComputedStyle(document.querySelector('.xterm-rows') ?? document.body).fontSize,
        keybar: document.querySelectorAll('.keybar__key').length,
        title: document.querySelector('.header__title')?.textContent,
      })),
    )}`,
  )
  // Back out the way a person would, and check the client did not lose its place.
  await page.locator('.header__back').click()
  await page.waitForTimeout(1200)
  say(`after-back ${JSON.stringify(await describe(page))}`)
}

/*
 * And the other appearance. Both themes are first-class here — the stylesheet
 * says so and `theme-tokens.test.ts` holds the two palettes together — but a
 * palette that agrees with itself can still leave a new surface unreadable, and
 * every surface on the Settings, Machines and grouped Localhost screens is new.
 */
/*
 * One icon now, not three pills — *"you can just give one small icon for
 * switching"* — so dark is reached by pressing it until the document says so
 * rather than by clicking a pill labelled Dark. Bounded, because a control that
 * had stopped cycling would otherwise spin here forever.
 */
for (let press = 0; press < 4; press += 1) {
  const said = await page.evaluate(() => document.querySelector('.appearance')?.getAttribute('aria-label') ?? '')
  if (said.includes('dark')) break
  await page.locator('.appearance').click()
  await page.waitForTimeout(250)
}
await page.waitForTimeout(400)
await tab('Localhost')
await page.waitForTimeout(2000)
await shoot(page, '25-localhost-dark')
await tab('Settings')
await shoot(page, '26-settings-dark')
await page.locator('.setting', { hasText: 'Machines' }).first().click()
await page.waitForTimeout(500)
await shoot(page, '27-machines-dark')

// The same client, given a window. Nothing about the layout changes shape — only
// the width at which a screen stops growing.
await page.setViewportSize(DESKTOP)
await page.waitForTimeout(600)
await shoot(page, '07-machines-desktop')
await tab('Localhost')
await page.waitForTimeout(1500)
await shoot(page, '08-localhost-desktop')
await tab('Sessions')
await shoot(page, '09-sessions-desktop')

await browser.close()
for (const beacon of beacons) beacon.kill('SIGINT')
say('done')
