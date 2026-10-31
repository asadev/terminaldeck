import { chromium } from 'playwright'
import { pathToFileURL } from 'node:url'
import { mkdir } from 'node:fs/promises'
import assert from 'node:assert/strict'
import { homedir } from 'node:os'
import path from 'node:path'
const shots = path.join(homedir(), 'Deck Dev/notes/windows/terminal')
await mkdir(shots, { recursive: true })
const browser = await chromium.launch({ headless: true, executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' })
const page = await browser.newPage({ viewport: { width: 900, height: 600 } })
const errors = []
page.on('pageerror', error => errors.push(error.message))
await page.addInitScript(() => {
  window.messages = []
  const listeners = []
  window.chrome = { webview: { postMessage: message => window.messages.push(message), addEventListener: (name, fn) => { if (name === 'message') listeners.push(fn) } } }
  window.hostSend = message => listeners.forEach(fn => fn({ data: message }))
})
let passed = 0
async function check(name, fn) { if (process.env.RETRY && name !== '20,000 lines and responsive input') return; try { await fn(); passed++; console.log(`PASS ${name}`) } catch (error) { console.error(`FAIL ${name}: ${error.message}`); process.exitCode = 1 } }
await page.goto(pathToFileURL(path.resolve('../../src/TerminalDeck.App/Assets/terminal/index.html')).href)
await check('ready and resize', async () => {
  await page.waitForFunction(() => window.messages.some(m => m.type === 'ready') && window.messages.some(m => m.type === 'resize' && m.cols > 0 && m.rows > 0))
})
await check('typed input round trip', async () => {
  await page.locator('.xterm-helper-textarea').focus()
  await page.keyboard.type('hello')
  await page.waitForFunction(() => window.messages.filter(m => m.type === 'input').map(m => m.data).join('').includes('hello'))
})
await check('output and glyphs', async () => {
  await page.evaluate(() => window.hostSend({ type: 'data', data: '❯ ⏵⏵ █▀▄\r\n' }))
  await page.waitForTimeout(500)
  assert.ok(await page.locator('.xterm-screen canvas').count())
  await page.screenshot({ path: path.join(shots, 'dark.png') })
})
await check('light theme and font', async () => {
  await page.evaluate(() => { window.hostSend({ type: 'theme', theme: 'light', background: '#ffffff', foreground: '#202020' }); window.hostSend({ type: 'font', size: 15 }) })
  await page.waitForFunction(() => getComputedStyle(document.getElementById('terminal')).backgroundColor === 'rgb(255, 255, 255)')
  await page.screenshot({ path: path.join(shots, 'light.png') })
})
await check('20,000 lines and responsive input', async () => {
  await page.evaluate(() => window.hostSend({ type: 'data', data: Array.from({ length: 20000 }, (_, i) => `line ${i}\r\n`).join('') + 'FLOOD_END' }))
  await page.waitForTimeout(3000)
  await page.screenshot({ path: path.join(shots, 'flood.png') })
  await page.locator('.xterm-helper-textarea').focus()
  await page.keyboard.type('z')
  await page.waitForFunction(() => window.messages.some(m => m.type === 'input' && m.data === 'z'), null, { timeout: 5000 })
})
await check('no page errors', async () => assert.deepEqual(errors, []))
console.log(`${passed}/${process.env.RETRY ? 1 : 6} passed`)
await browser.close()
