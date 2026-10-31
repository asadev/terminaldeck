// Umer's first-use findings: bottom row visibility, replay resync, text weight.
import { chromium } from 'playwright'
import { mkdir } from 'node:fs/promises'
import assert from 'node:assert/strict'
import path from 'node:path'
const shots = process.env.SHOTS || path.resolve('.artifacts/umer-terminal')
await mkdir(shots, { recursive: true })
const browser = await chromium.launch({ headless: true, executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' })
let passed = 0; let failed = 0
async function check(name, fn) { try { await fn(); passed++; console.log(`PASS ${name}`) } catch (error) { failed++; console.error(`FAIL ${name}: ${error.message}`) } }
async function open(width, height, scale) {
  const context = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: scale })
  const page = await context.newPage(); page.errors = []
  page.on('pageerror', error => page.errors.push(error.message))
  await page.addInitScript(() => {
    window.messages = []; const listeners = []
    window.chrome = { webview: { postMessage: message => window.messages.push(message), addEventListener: (name, fn) => { if (name === 'message') listeners.push(fn) } } }
    window.hostSend = message => listeners.forEach(fn => fn({ data: message }))
  })
  await page.goto(new URL('../../src/TerminalDeck.App/Assets/terminal/index.html', import.meta.url).href)
  await page.waitForFunction(() => window.messages.some(m => m.type === 'ready'))
  await page.waitForTimeout(400)
  return page
}
// Every fitted row, including the last, must sit inside the card's content box.
async function lastRowVisible(page) {
  return page.evaluate(() => {
    const card = document.getElementById('terminal'); const style = getComputedStyle(card)
    const contentBottom = card.getBoundingClientRect().bottom - parseFloat(style.paddingBottom)
    const contentRight = card.getBoundingClientRect().right - parseFloat(style.paddingRight)
    const screen = document.querySelector('.xterm-screen').getBoundingClientRect()
    const fits = [...window.messages].reverse().find(m => m.type === 'resize')
    return { bottom: screen.bottom, contentBottom, right: screen.right, contentRight, rows: fits?.rows }
  })
}
for (const [width, height] of [[1920, 1080], [1536, 864], [1280, 720], [1366, 705]]) {
  for (const scale of [1, 1.25, 1.5]) {
    await check(`last row fully visible ${width}x${height} @${scale * 100}%`, async () => {
      const page = await open(width, height, scale)
      const r = await lastRowVisible(page)
      assert.ok(r.rows > 0, 'fitted')
      assert.ok(r.bottom <= r.contentBottom + 0.5, `screen bottom ${r.bottom} past content ${r.contentBottom}`)
      assert.ok(r.right <= r.contentRight + 0.5, `screen right ${r.right} past content ${r.contentRight}`)
      await page.setViewportSize({ width: Math.round(width * 0.8), height: Math.round(height * 0.75) }); await page.waitForTimeout(300)
      const s = await lastRowVisible(page)
      assert.ok(s.bottom <= s.contentBottom + 0.5 && s.rows < r.rows, 'refits on resize')
      if (width === 1920 && scale === 1.25) await page.screenshot({ path: path.join(shots, 'fit-1920-125.png') })
      assert.deepEqual(page.errors, []); await page.context().close()
    })
  }
}
await check('replay asks for a repaint after it is written', async () => {
  const page = await open(900, 600, 1.25)
  await page.evaluate(() => window.hostSend({ type: 'replay', data: 'old\r\n❯ half typ' }))
  await page.waitForFunction(() => window.messages.some(m => m.type === 'repaint' && m.cols > 0 && m.rows > 0))
  const text = await page.evaluate(() => document.querySelector('.xterm-accessibility-tree, .xterm-rows')?.textContent ?? '')
  assert.ok(!text.includes('stale'))
  await page.evaluate(() => window.hostSend({ type: 'data', data: 'stale' }))
  await page.evaluate(() => window.hostSend({ type: 'replay', data: 'fresh' }))
  await page.waitForFunction(() => window.messages.filter(m => m.type === 'repaint').length === 2)
  assert.deepEqual(page.errors, []); await page.context().close()
})
await check('bundled Cascadia Mono at Medium weight is used', async () => {
  const page = await open(900, 600, 1)
  await page.evaluate(() => window.hostSend({ type: 'data', data: 'The quick brown fox ❯ ⏵⏵ │ ╭─╮ █▀▄\r\n' }))
  await page.waitForTimeout(600)
  assert.ok(await page.evaluate(() => document.fonts.check("500 13px 'Deck Cascadia Mono'")))
  assert.ok(await page.evaluate(() => [...document.fonts].some(f => f.family.includes('Deck Cascadia Mono') && f.status === 'loaded')))
  await page.screenshot({ path: path.join(shots, 'weight-dark.png'), clip: { x: 0, y: 0, width: 420, height: 60 } })
  assert.deepEqual(page.errors, []); await page.context().close()
})
await check('renderer comes back after a lost GPU context', async () => {
  const page = await open(900, 600, 1.25)
  const lost = await page.evaluate(() => {
    const canvas = [...document.querySelectorAll('.xterm-screen canvas')].find(c => c.getContext('webgl2'))
    const ext = canvas?.getContext('webgl2')?.getExtension('WEBGL_lose_context'); if (!ext) return false
    ext.loseContext(); return true
  })
  if (!lost) { console.log('  (WebGL unavailable in this browser; skipped)'); await page.context().close(); return }
  await page.waitForTimeout(4500) // xterm waits 3 s for the browser to restore the context first
  const live = await page.evaluate(() => [...document.querySelectorAll('.xterm-screen canvas')].some(c => { const gl = c.getContext('webgl2'); return gl && !gl.isContextLost() }))
  assert.ok(live, 'a live WebGL canvas is back')
  await page.locator('.xterm-helper-textarea').focus(); await page.keyboard.type('x')
  await page.waitForFunction(() => window.messages.some(m => m.type === 'input' && m.data === 'x'))
  assert.deepEqual(page.errors, []); await page.context().close()
})
console.log(`${passed} passed, ${failed} failed`)
await browser.close()
process.exitCode = failed ? 1 : 0
