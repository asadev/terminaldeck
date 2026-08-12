// Boots a real Electron window, creates a WebContentsView the same way
// browser-tab.ts does, and reports whether a page actually loads.
const { app, BrowserWindow, WebContentsView } = require('electron')

app.whenReady().then(async () => {
  const win = new BrowserWindow({ width: 1200, height: 800, show: false })
  const log = (...a) => console.log('[smoke]', ...a)

  const view = new WebContentsView({
    webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true },
  })
  view.setBackgroundColor('#ffffff')
  win.contentView.addChildView(view)
  view.setBounds({ x: 0, y: 40, width: 1200, height: 760 })
  log('view attached, bounds set')

  const wc = view.webContents
  wc.on('did-fail-load', (_e, code, desc, url) => log('FAIL', code, desc, url))
  wc.on('did-finish-load', () => log('did-finish-load'))

  try {
    await wc.loadURL('https://example.com')
    log('loadURL resolved')
    log('title:', wc.getTitle())
    log('url:', wc.getURL())
    const text = await wc.executeJavaScript('document.body.innerText.slice(0,80)')
    log('page text:', JSON.stringify(text))
    log(text && text.length > 10 ? 'RESULT: PAGE LOADED OK' : 'RESULT: PAGE EMPTY')
  } catch (e) {
    log('RESULT: loadURL THREW', String(e).slice(0, 160))
  }
  app.quit()
})
