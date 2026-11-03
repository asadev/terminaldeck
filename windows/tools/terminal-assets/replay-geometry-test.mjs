// Own terminal renderer only. No keeper connection, shell or user session.
import { chromium } from 'playwright'
import assert from 'node:assert/strict'
const browser = await chromium.launch({ headless: true, ...(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : {}) })
const page = await browser.newPage({ viewport: { width: 720, height: 480 } })
await page.addInitScript(() => {
  window.messages = []; const listeners = []
  window.chrome = { webview: { postMessage: m => window.messages.push(m), addEventListener: (_, f) => listeners.push(f) } }
  window.hostSend = m => listeners.forEach(f => f({ data: m }))
})
try {
  await page.goto(new URL('../../src/TerminalDeck.App/Assets/terminal/index.html', import.meta.url).href)
  await page.waitForFunction(() => window.messages.some(m => m.type === 'resize'))
  const before = await page.evaluate(() => window.messages.filter(m => m.type === 'resize').at(-1))
  // ConPTY-style absolute cursor positions plus a long wrapped line at a source
  // width unlike the current viewport. Replay must first use 100 x 30.
  await page.evaluate(() => {
    window.messages.length = 0
    window.hostSend({ type: 'replay', cols: 100, rows: 30, data: '\x1b[2J\x1b[H' + 'x'.repeat(99) + '\r\n\x1b[2;1H❯ half typed' })
    window.hostSend({ type: 'data', data: ' suffix' })
  })
  await page.waitForFunction(() => window.messages.some(m => m.type === 'replayed'))
  const messages = await page.evaluate(() => window.messages)
  assert.ok(messages.some(m => m.type === 'resize' && m.cols === 100 && m.rows === 30), 'recorded source geometry was used')
  assert.ok(!messages.some(m => m.type === 'repaint'), 'no artificial shrink/restore requested')
  const final = messages.find(m => m.type === 'replayed')
  assert.equal(final.cols, before.cols); assert.equal(final.rows, before.rows)
  await page.evaluate(() => window.hostSend({ type: 'data', data: '\x1b[6n' }))
  await page.waitForFunction(() => window.messages.some(m => m.type === 'input' && /^\x1b\[\d+;\d+R$/.test(m.data)))
  const cursor = await page.evaluate(() => window.messages.find(m => m.type === 'input' && /^\x1b\[\d+;\d+R$/.test(m.data)).data)
  const position = /^\x1b\[(\d+);(\d+)R$/.exec(cursor)
  assert.equal(Number(position[2]), 20, 'next typed character lands immediately after the replayed prompt and queued suffix')
  await page.locator('.xterm-helper-textarea').focus(); await page.keyboard.type('z')
  await page.waitForFunction(() => window.messages.some(m => m.type === 'input' && m.data === 'z'))
  console.log('PASS replay preserves source geometry, serializes queued output, and returns to the real viewport')
} finally { await browser.close() }
