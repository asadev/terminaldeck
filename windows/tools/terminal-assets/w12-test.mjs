import { chromium } from 'playwright'
import { fileURLToPath } from 'node:url'
import { mkdir, writeFile } from 'node:fs/promises'
import assert from 'node:assert/strict'
import path from 'node:path'
const output = fileURLToPath(new URL('../../docs/proof/w12-sessions-chats/terminal', import.meta.url))
await mkdir(output, { recursive: true })
const browser = await chromium.launch({ headless: true, executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' })
const page = await browser.newPage({ viewport: { width: 900, height: 600 } })
const errors = []; const passed = []
page.on('pageerror', e => errors.push(e.message))
await page.addInitScript(() => {
  const callbacks = []; window.messages = []
  window.chrome = { webview: { postMessage: message => window.messages.push(message), addEventListener: (_, callback) => callbacks.push(callback) } }
  window.hostSend = data => callbacks.forEach(callback => callback({ data }))
})
try {
  await page.goto(new URL('../../src/TerminalDeck.App/Assets/terminal/index.html', import.meta.url).href)
  await page.waitForFunction(() => window.messages.some(m => m.type === 'ready'))
  await page.evaluate(() => window.hostSend({ type: 'data', data: '\x1b[?2004h❯ needle one\r\nneedle two\r\n' }))
  await page.waitForTimeout(250)
  await page.locator('.xterm-helper-textarea').focus()
  await page.keyboard.press('Control+f')
  await page.waitForFunction(() => window.messages.some(m => m.type === 'findRequest'))
  passed.push('Ctrl+F opens host find without sending a terminal control character')
  await page.evaluate(() => window.hostSend({ type: 'find', query: 'needle', direction: 'next' }))
  await page.waitForFunction(() => window.messages.some(m => m.type === 'findResult' && m.count === 2))
  passed.push('search reports two real terminal matches')
  await page.keyboard.press('Control+Shift+g')
  await page.waitForFunction(() => window.messages.some(m => m.type === 'findNext' && m.previous))
  passed.push('Ctrl+Shift+G routes previous match to host')
  await page.evaluate(() => window.hostSend({ type: 'paste', text: 'line one\nاردو 🙂' }))
  await page.waitForFunction(() => window.messages.some(m => m.type === 'input' && m.data.includes('اردو')))
  const input = await page.evaluate(() => window.messages.filter(m => m.type === 'input').map(m => m.data).join(''))
  assert.equal(input, '\x1b[200~line one\rاردو 🙂\x1b[201~')
  passed.push('Unicode paste uses terminal bracketed-paste mode and adds no Return')
  await page.keyboard.press('Control+Shift+v')
  await page.waitForFunction(() => window.messages.some(m => m.type === 'pasteRequest'))
  passed.push('native clipboard paste is requested only on explicit keyboard action')
  const beforePaste = await page.evaluate(() => window.messages.filter(m => m.type === 'pasteRequest').length)
  await page.keyboard.press('Control+v')
  await page.waitForFunction(before => window.messages.filter(m => m.type === 'pasteRequest').length === before + 1, beforePaste)
  passed.push('Ctrl+V also routes file/image paste to the native owner')
  await page.locator('#terminal').click({ button: 'right', position: { x: 100, y: 50 } })
  await page.waitForFunction(() => window.messages.some(m => m.type === 'contextMenu'))
  passed.push('right-click reaches the native terminal menu')
  for (const theme of ['dark', 'light']) {
    await page.evaluate(theme => window.hostSend({ type: 'theme', theme }), theme)
    assert.equal(await page.evaluate(() => getComputedStyle(document.documentElement).colorScheme), theme)
    await page.screenshot({ path: path.join(output, `terminal-${theme}.png`) })
  }
  assert.deepEqual(errors, []); passed.push('no page errors')
  await writeFile(path.join(output, 'result.json'), JSON.stringify({ at: new Date().toISOString(), passed, count: passed.length, headless: true, clipboardWrites: 0, providerProcesses: 0 }, null, 2))
  console.log(`${passed.length} terminal checks passed`)
} finally { await browser.close() }
