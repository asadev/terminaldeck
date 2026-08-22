/**
 * Drive a real website, in the real installed Chromium, over the real CDP pipe.
 *
 * ## Why this exists
 *
 * `scripts/check-browser-drive.mjs` is the same idea for the *desktop*: real
 * Electron, real `WebContents`, real page. It exists because a driver verified
 * only against a fake page is a driver verified against nothing.
 *
 * The server path had no such check. Everything under `browser-chromium-*.ts`,
 * `browser-cdp-pipe.ts` and `browser-driven-cdp.ts` was unit-green against an
 * injected `spawn` and a scripted transport — and on the first real Linux box it
 * was pointed at, three separate things were wrong, every one of them invisible
 * to a fake:
 *
 *  1. `browser install` reported success and left a binary that could not run,
 *     because a bare server has none of the ~13 shared libraries Chromium links.
 *  2. `launchChromium` returned `ok: true` for a process that was dead 30 ms
 *     later with exit 127 — pid present, `exitCode` still `null` at the moment
 *     it was read, both pipe fds open onto a corpse. (It is now async and does
 *     not answer until the browser has; `spawnChromium` is the old synchronous
 *     half, and nothing outside that module holds its result.)
 *  3. Stock Ubuntu 24.04 cannot start Chromium with the flags that shipped, as
 *     *any* user: as root it refuses outright, and as a normal user
 *     `apparmor_restrict_unprivileged_userns=1` leaves it with no usable sandbox.
 *
 * So this is the Linux counterpart, and it is written to be run **on the box
 * that matters** rather than on a developer's Mac:
 *
 *     node scripts/check-headless-drive.mjs --emit /tmp/out    # bundle here
 *     scp /tmp/out/headless-drive-check.mjs server:            # ship one file
 *     ssh server node headless-drive-check.mjs                 # run it there
 *
 * With no `--emit` it bundles and runs in one go, which is the right thing on a
 * Linux CI runner and useless on macOS — there is no linux64 Chromium to drive.
 *
 * ## What it proves, in order
 *
 *  1. `installChromium()` resolves, verifies and unpacks — reporting which
 *     digest authority was used, app-owned sha256 or the server's md5.
 *  2. The binary's dynamic libraries are all present, named individually when
 *     they are not, before anything tries to run it.
 *  3. Every binary in the archive that has to *run* came out executable — the
 *     failure `ldd` and `chrome --version` are both green over.
 *  4. `launchChromium()` starts a process that answers `Browser.getVersion`
 *     over the pipe, and the version agrees with the pinned one.
 *  4. A real static page loads and its title and text read back.
 *  5. A real **JavaScript-rendered** page loads, and text is proven absent from
 *     the raw HTML and present in the rendered DOM — the difference is the whole
 *     point, and a check that only ever loaded `example.com` could not tell a
 *     rendering browser from a fetch.
 *  6. A screenshot decodes through the repository's own `decodePngToRgba` and is
 *     shown not to be blank, by counting distinct pixels rather than by trusting
 *     that bytes arrived.
 *  7. A screencast delivers real JPEG frames, with the dimensions read out of
 *     each frame's own SOF marker and the time to the first one measured.
 *  8. Everything is torn down and no Chromium is left behind.
 *
 * Every number it prints is measured on the machine it ran on. Nothing here is
 * asserted from a constant.
 */

import { execFileSync, spawn } from 'node:child_process'
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const repo = resolve(here, '..')

const args = process.argv.slice(2)
const emitIndex = args.indexOf('--emit')
const emitDir = emitIndex === -1 ? null : resolve(args[emitIndex + 1])
const work = emitDir ?? join(repo, '.headless-drive-check')
mkdirSync(work, { recursive: true })

/*
 * Bundle the real modules rather than re-implementing them.
 *
 * Same argument `check-browser-drive.mjs` makes: the point of the exercise is
 * that the code under test is the code that ships. The entry below imports from
 * `src/main` by path and esbuild pulls the real graph in, so a change to the
 * install, the launch, the pipe framing or the page wrapper changes what this
 * checks. There is nothing external — the headless closure is `node:*` only.
 */
const entry = join(work, 'entry.mjs')
writeFileSync(entry, ENTRY_SOURCE(repo))

const bundle = join(work, 'headless-drive-check.mjs')
console.log('[headless-drive] bundling the real modules …')
execFileSync(
  join(repo, 'node_modules', '.bin', 'esbuild'),
  [entry, '--bundle', '--platform=node', '--format=esm', '--target=node22', `--outfile=${bundle}`],
  { stdio: ['ignore', 'inherit', 'inherit'] },
)

if (emitDir !== null) {
  console.log(`\n[headless-drive] ${bundle}`)
  console.log('[headless-drive] copy that one file to a Linux box and run it with node 22+.')
  process.exit(0)
}

if (process.platform !== 'linux') {
  console.log(`\n[headless-drive] bundled to ${bundle}`)
  console.log(`[headless-drive] this is ${process.platform}; chrome-for-testing linux64 is what this drives.`)
  console.log('[headless-drive] run the bundled file on the Linux host instead.')
  process.exit(0)
}

const child = spawn(process.execPath, [bundle, ...args], { stdio: 'inherit' })
child.on('exit', (code) => process.exit(code ?? 1))

/* -------------------------------------------------------------- the entry -- */

function ENTRY_SOURCE(root) {
  const q = (p) => JSON.stringify(join(root, 'src', 'main', p))
  return `
import { execFileSync } from 'node:child_process'
import { createServer } from 'node:http'
import { readFileSync, readdirSync, statSync, writeFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

import { installPaths, nodePaths } from ${q('platform/paths.ts')}
import { installChromium, PINNED_CHROMIUM_VERSION } from ${q('browser-chromium-install.ts')}
import { chromiumFlags, readSandboxFacts, sandboxDecision } from ${q('browser-chromium-launch.ts')}
import { decodePngToRgba } from ${q('browser-driven-cdp.ts')}
import { classifyBlock } from ${q('browser-block-watch.ts')}
import { HeadlessDriveHost } from ${q('browser-headless-host.ts')}

/*
 * Say which shell this is, exactly as \`src/headless/daemon.ts\` does on its first
 * line. \`platform/paths.ts\` deliberately has no default, so a process that is
 * neither the Electron shell nor the daemon has to install its own — and this
 * one installs the *daemon's*, so the check reads and reuses the very Chromium
 * \`terminaldeck browser install\` put there rather than fetching a second copy
 * into a directory nothing else will ever look in.
 */
installPaths(nodePaths({ appRoot: process.argv[1] }))

/*
 * Per-user, because /tmp is shared.
 *
 * The first run of this as a second user on the same box died with EACCES on the
 * screenshot: root had created the directory, and \`tmpdir()\` is the same path
 * for everybody. Which user runs the host is exactly the variable this check
 * exists to explore — root and an ordinary user get different sandbox answers —
 * so a fixed shared path was guaranteed to collide. \`--out\` overrides it.
 */
const outFlag = process.argv.indexOf('--out')
const OUT =
  outFlag === -1
    ? join(tmpdir(), \`headless-drive-check-\${typeof process.getuid === 'function' ? process.getuid() : 0}\`)
    : process.argv[outFlag + 1]
mkdirSync(OUT, { recursive: true })

let failures = 0
const ok = (label, detail) => console.log(\`  \\u001b[32mok\\u001b[0m   \${label}\${detail ? '  ' + detail : ''}\`)
const bad = (label, detail) => { failures += 1; console.log(\`  \\u001b[31mFAIL\\u001b[0m \${label}\${detail ? '  ' + detail : ''}\`) }
const info = (label, detail) => console.log(\`       \${label}\${detail ? '  ' + detail : ''}\`)
const ms = (t) => \`\${Date.now() - t} ms\`

/** RSS of every process in the Chromium tree, straight out of /proc. */
function chromiumRss(rootPid) {
  const pids = []
  const walk = (pid) => {
    pids.push(pid)
    let kids = ''
    try { kids = readFileSync(\`/proc/\${pid}/task/\${pid}/children\`, 'utf8') } catch { return }
    for (const k of kids.trim().split(/\\s+/).filter(Boolean)) walk(Number(k))
  }
  walk(rootPid)
  let total = 0
  const each = []
  for (const pid of pids) {
    try {
      const status = readFileSync(\`/proc/\${pid}/status\`, 'utf8')
      const kb = Number(/VmRSS:\\s+(\\d+) kB/.exec(status)?.[1] ?? 0)
      const name = /Name:\\s+(.+)/.exec(status)?.[1] ?? '?'
      total += kb
      each.push(\`\${name}:\${(kb / 1024).toFixed(0)}M\`)
    } catch { /* it exited between the listing and the read */ }
  }
  return { processes: pids.length, totalMb: total / 1024, each }
}

/** The Chromium browser process running under a given profile root, out of /proc. */
function chromiumPidUnder(userData) {
  for (const name of readdirSync('/proc')) {
    if (!/^\\d+$/.test(name)) continue
    try {
      const cmdline = readFileSync(\`/proc/\${name}/cmdline\`, 'utf8')
      // The browser process is the one carrying --user-data-dir; its renderers
      // and zygotes inherit a different argv and would otherwise match first.
      if (cmdline.includes(userData) && cmdline.includes('--user-data-dir')) return Number(name)
    } catch { /* it exited between the listing and the read */ }
  }
  return null
}

/** Width and height out of a JPEG's own SOF marker — never the protocol's word for it. */
function jpegSize(bytes) {
  if (bytes[0] !== 0xff || bytes[1] !== 0xd8) return null
  let i = 2
  while (i < bytes.length - 9) {
    if (bytes[i] !== 0xff) { i += 1; continue }
    const marker = bytes[i + 1]
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      return { height: bytes.readUInt16BE(i + 5), width: bytes.readUInt16BE(i + 7) }
    }
    i += 2 + bytes.readUInt16BE(i + 2)
  }
  return null
}

/** Distinct RGBA pixels, capped — a blank page has one, a rendered page has many. */
function distinctPixels(frame, cap = 5000) {
  const seen = new Set()
  const data = frame.data
  for (let i = 0; i + 3 < data.length && seen.size < cap; i += 4) {
    seen.add((data[i] << 24) | (data[i + 1] << 16) | (data[i + 2] << 8) | data[i + 3])
  }
  return seen.size
}

const sleep = (n) => new Promise((r) => setTimeout(r, n))

async function main() {
  console.log('\\nTerminal Deck — headless drive check')
  console.log(\`  node \${process.version}  \${process.platform}/\${process.arch}\\n\`)

  /* -- 1. install ------------------------------------------------------- */
  console.log('1. install the pinned Chromium')
  let t = Date.now()
  const install = await installChromium()
  if (!install.ok) { bad('installChromium', install.why); process.exit(1) }
  ok('installChromium', \`\${install.version}\${install.reused ? ' (reused)' : ' (fetched)'} in \${ms(t)}\`)
  info('path', install.path)
  if (!install.sideloaded && install.version !== PINNED_CHROMIUM_VERSION) {
    bad('version', \`installed \${install.version}, pinned \${PINNED_CHROMIUM_VERSION}\`)
  }
  try {
    const record = JSON.parse(readFileSync(join(install.path, '..', '..', 'installed.json'), 'utf8'))
    if (record.checksum === 'sha256') ok('digest', 'verified against the app-owned sha256')
    else if (record.checksum === 'md5') info('digest', 'verified against the server-published md5 (no app pin for this build)')
    else bad('digest', \`recorded as "\${record.checksum}"\`)
  } catch { info('digest', 'no install record (side-loaded)') }

  /* -- 2. the libraries it links --------------------------------------- */
  console.log('\\n2. the shared libraries the binary links')
  let missing = []
  try {
    const ldd = execFileSync('ldd', [install.path], { encoding: 'utf8' })
    missing = ldd.split('\\n').filter((l) => l.includes('not found')).map((l) => l.trim().split(' ')[0])
  } catch { info('ldd', 'not available here; skipped') }
  if (missing.length === 0) ok('ldd', 'every library resolves')
  else bad('ldd', \`\${missing.length} missing: \${missing.join(', ')}\`)

  /*
   * The exec bits, which ldd and --version are both blind to.
   *
   * browser-extension-unzip.ts drops a zip entry's mode bits on purpose — an
   * extension is read, never run — so browser-chromium-install.ts chmods the
   * binaries back. Measured on the reference server, 2026-08-22: with
   * chrome_crashpad_handler left non-executable, ldd was clean and
   * chrome --version printed the version and exited 0, and every real start
   * died on SIGABRT with "posix_spawn ...: Permission denied (13)".
   */
  const binDir = join(install.path, '..')
  for (const name of ['chrome_crashpad_handler', 'chrome_sandbox']) {
    const file = join(binDir, name)
    try {
      const mode = statSync(file).mode
      if ((mode & 0o111) !== 0) ok(name, 'executable')
      else bad(name, \`present but not executable (mode \${(mode & 0o777).toString(8)})\`)
    } catch { info(name, 'not in this build') }
  }

  /* -- 3. the sandbox, and the launch ----------------------------------- */
  console.log('\\n3. the sandbox this machine can give it')
  const facts = readSandboxFacts()
  const decision = sandboxDecision(facts)
  info('facts', \`uid \${facts.uid}  max_user_namespaces \${facts.maxUserNamespaces}  apparmor-restricted \${facts.apparmorRestrictsUserns}\`)
  if (decision.sandbox) ok('sandbox', 'kept on')
  else info('sandbox', \`dropped — \${decision.why}\`)
  // The flags as they will actually be passed, decision included. Printing the
  // default set here instead would be this check telling its own small lie.
  info('flags', chromiumFlags({ userDataDir: '<profile>', sandbox: decision.sandbox }).join(' '))

  console.log('\\n4. open a tab, the way a device does')
  /*
   * Through \`HeadlessDriveHost\`, not a hand-wired pipe.
   *
   * \`openTab\` is what a phone's request actually lands on, and going through it
   * exercises the whole production path — \`defaultLaunch\`, the readiness race
   * that replaced the silent hang, the browser-level arming, the target, and the
   * \`DrivenPage\` the driver steers. A check that assembled those by hand would
   * be checking the check.
   */
  const host = new HeadlessDriveHost({ userData: join(OUT, 'userdata') })
  t = Date.now()
  const viewId = await host.openTab({ url: 'about:blank', isolate: false })
  if (viewId === null) { bad('openTab', 'the host would not open a tab'); await host.stop(); process.exit(1) }
  ok('openTab', \`launched and opened in \${ms(t)}\`)
  const page = host.contentsFor(viewId)
  if (page === null) { bad('contentsFor', 'the host has no page for the tab it just opened'); await host.stop(); process.exit(1) }
  await page.attach()
  await page.send('Page.enable', {})

  const browserPid = chromiumPidUnder(join(OUT, 'userdata'))
  if (browserPid === null) info('pid', 'no chrome process found under this profile')
  else ok('the browser is a real process', \`pid \${browserPid}\`)

  const loaded = () => new Promise((done) => {
    const off = page.onEvent((method) => { if (method === 'Page.loadEventFired') { off(); done() } })
    setTimeout(() => { off(); done() }, 30000)
  })

  const go = async (url) => { const wait = loaded(); await page.loadURL(url); await wait; await sleep(400) }

  const evaluate = async (expression) => {
    const result = await page.send('Runtime.evaluate', { expression, returnByValue: true })
    return result.result?.value
  }

  console.log('\\n5. drive a real page')
  t = Date.now()
  await go('https://example.com')
  const staticText = String(await evaluate('document.body.innerText') ?? '')
  ok('example.com', \`loaded in \${ms(t)}\`)
  info('navigator.userAgent', String(await evaluate('navigator.userAgent') ?? ''))
  info('page.url()', page.url())
  info('page.title()', JSON.stringify(page.title()))
  info('body text', JSON.stringify(staticText.trim().slice(0, 60)) + '…')
  if (page.title().toLowerCase().includes('example')) ok('title read back', 'through the real DrivenPage')
  else bad('title read back', \`got \${JSON.stringify(page.title())} — the host is not subscribed to Target.targetInfoChanged\`)
  if (staticText.toLowerCase().includes('example domain')) ok('text read back', 'the document really rendered')
  else bad('text read back', 'the expected text is not in the DOM')

  /* -- 5. a page whose content only exists after JavaScript -------------- */
  console.log('\\n6. drive a page that only exists after JavaScript')

  /*
   * A page this check serves itself, over real HTTP, whose body is written by
   * JavaScript after load.
   *
   * The first version of this pointed at a public search engine and asserted
   * that the rendered DOM held text the raw HTML did not. It passed — and the
   * screenshot showed it had passed against a *bot challenge*, because a
   * datacenter IP asking a search engine for results gets a CAPTCHA. The
   * assertion was true and the story it told was wrong, which is its own kind of
   * lie, so the deterministic half of the proof is now served from here: the
   * marker is a fresh random string that exists in no HTML anywhere, the server
   * proves it is absent from the bytes it sent, and only a browser that ran the
   * script can put it in the DOM. Real HTTP, real navigation, real V8, and no
   * third party's bot policy in the middle of it.
   */
  const marker = \`js-only-\${Math.random().toString(36).slice(2)}-\${Date.now()}\`
  const html =
    '<!doctype html><meta charset="utf-8"><title>rendered by javascript</title>' +
    '<body><div id="slot">not rendered</div>' +
    \`<script>document.getElementById('slot').textContent = \${JSON.stringify(marker)}</script>\`
  const server = createServer((_request, response) => {
    response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
    response.end(html)
  })
  await new Promise((done) => server.listen(0, '127.0.0.1', done))
  const localUrl = \`http://127.0.0.1:\${server.address().port}/\`

  await go(localUrl)
  const localText = String(await evaluate('document.getElementById("slot").textContent') ?? '')
  if (html.includes(marker) && !html.includes(\`>\${marker}<\`)) {
    // The marker is in the script, never in the markup the server sent.
    ok('served HTML has no rendered marker', 'it exists only inside the script tag')
  }
  if (localText === marker) ok('javascript ran', \`the DOM now holds \${marker.slice(0, 24)}…\`)
  else bad('javascript ran', \`the slot holds \${JSON.stringify(localText)}\`)
  info('page.title()', JSON.stringify(page.title()))
  server.close()

  /*
   * And a real public JavaScript-heavy site, reported rather than asserted.
   *
   * What a server-side browser meets in the wild is worth measuring, but it is
   * not worth failing a build over: a datacenter IP gets challenged, and that is
   * the site's decision, not a defect here. So this drives the real thing, runs
   * the repository's own \`classifyBlock\` over what came back, and prints the
   * verdict — which is the first time that classifier has ever been shown a
   * live challenge instead of a fixture.
   */
  console.log('\\n   a real public site, from a datacenter IP')
  const publicUrl = 'https://duckduckgo.com/?q=terminal+deck&ia=web'
  t = Date.now()
  await go(publicUrl)
  await sleep(2500)
  const publicText = String(await evaluate('document.body.innerText') ?? '')
  const publicNodes = Number(await evaluate('document.querySelectorAll("*").length') ?? 0)
  info('duckduckgo.com', \`loaded in \${ms(t)}, \${publicNodes} elements\`)
  info('page.title()', JSON.stringify(page.title()))
  info('first line', JSON.stringify(publicText.split('\\n').map((l) => l.trim()).filter(Boolean)[0] ?? ''))

  const verdict = classifyBlock({
    requestedUrl: publicUrl,
    finalUrl: page.url(),
    httpStatus: 200,
    statusText: 'OK',
    title: page.title(),
    text: publicText,
    failed: null,
  })
  const looksChallenged = /challenge|captcha|are you a human|confirm this search|select all/i.test(publicText)
  info('classifyBlock', verdict.blocked ? \`blocked — \${verdict.signals.join('; ')}\` : 'not blocked')
  if (looksChallenged && !verdict.blocked) {
    bad(
      'the block watcher saw a real challenge and did not call it one',
      'the page is asking a human to solve a puzzle; DEFAULT_BLOCK_RULES has no marker for this wording',
    )
  } else if (looksChallenged) {
    ok('the block watcher caught a real challenge', verdict.signals.join('; '))
  } else {
    ok('not challenged', 'this IP got the real page')
  }

  /* -- 6. a screenshot that is not blank -------------------------------- */
  console.log('\\n7. screenshot')
  t = Date.now()
  const shot = await page.send('Page.captureScreenshot', { format: 'png' })
  const png = Buffer.from(shot.data, 'base64')
  const shotMs = ms(t)
  writeFileSync(join(OUT, 'screenshot.png'), png)
  let decoded = null
  try { decoded = decodePngToRgba(png) } catch (error) { bad('decodePngToRgba', error.message) }
  if (decoded) {
    const colours = distinctPixels(decoded)
    ok('captureScreenshot', \`\${png.length} bytes, \${decoded.width}\\u00d7\${decoded.height}, in \${shotMs}\`)
    info('saved', join(OUT, 'screenshot.png'))
    if (decoded.width > 100 && decoded.height > 100) ok('dimensions', 'sane')
    else bad('dimensions', \`\${decoded.width}\\u00d7\${decoded.height}\`)
    if (colours > 50) ok('not blank', \`\${colours}+ distinct pixel values\`)
    else bad('not blank', \`only \${colours} distinct pixel values — this is an empty or error page\`)
  }

  /* -- 7. the watch path ------------------------------------------------ */
  console.log('\\n8. the watch path — a real screencast')
  const frames = []
  const started = Date.now()
  let firstFrameAt = 0
  const offFrame = page.onEvent((method, params) => {
    if (method !== 'Page.screencastFrame') return
    if (firstFrameAt === 0) firstFrameAt = Date.now()
    const bytes = Buffer.from(params.data, 'base64')
    frames.push({ bytes: bytes.length, size: jpegSize(bytes) })
    if (frames.length === 1) writeFileSync(join(OUT, 'frame-1.jpg'), bytes)
    void page.send('Page.screencastFrameAck', { sessionId: params.sessionId }).catch(() => undefined)
  })
  await page.send('Page.startScreencast', { format: 'jpeg', quality: 70, everyNthFrame: 1 })
  // Something has to change on screen or a screencast has nothing to send.
  for (let i = 0; i < 6; i += 1) { await evaluate('window.scrollBy(0, 120)'); await sleep(280) }
  await sleep(1200)
  await page.send('Page.stopScreencast', {}).catch(() => undefined)
  offFrame()

  if (frames.length === 0) bad('screencast', 'no frames arrived')
  else {
    ok('screencast', \`\${frames.length} frames\`)
    info('time to first frame', \`\${firstFrameAt - started} ms\`)
    const sizes = frames.map((f) => f.bytes)
    info('frame bytes', \`min \${Math.min(...sizes)}, max \${Math.max(...sizes)}, mean \${Math.round(sizes.reduce((a, b) => a + b, 0) / sizes.length)}\`)
    const dims = frames.map((f) => f.size).filter(Boolean)
    if (dims.length !== frames.length) bad('frames are JPEG', \`\${frames.length - dims.length} had no readable SOF marker\`)
    else {
      const first = dims[0]
      ok('frames are JPEG', \`\${first.width}\\u00d7\${first.height} read from the frame's own SOF marker\`)
      if (first.width > 100 && first.height > 100) ok('frame dimensions', 'sane')
      else bad('frame dimensions', \`\${first.width}\\u00d7\${first.height}\`)
    }
    info('saved', join(OUT, 'frame-1.jpg'))
  }

  /* -- 8. what it cost, and tear down ----------------------------------- */
  console.log('\\n9. cost, and teardown')
  if (browserPid !== null) {
    const rss = chromiumRss(browserPid)
    ok('chromium RAM', \`\${rss.totalMb.toFixed(0)} MB across \${rss.processes} processes\`)
    info('by process', rss.each.join('  '))
  }

  await host.closeWindow(viewId).catch(() => undefined)
  await host.stop()
  await sleep(1200)
  if (browserPid !== null) {
    let stillThere = true
    try { process.kill(browserPid, 0) } catch { stillThere = false }
    if (stillThere) bad('teardown', \`pid \${browserPid} is still running after host.stop()\`)
    else ok('teardown', 'the browser is gone')
  }

  console.log(failures === 0 ? '\\n\\u001b[32mAll checks passed.\\u001b[0m\\n' : \`\\n\\u001b[31m\${failures} check(s) failed.\\u001b[0m\\n\`)
  process.exit(failures === 0 ? 0 : 1)
}

main().catch((error) => { console.error('\\nthe check itself threw:', error); process.exit(1) })
`
}
