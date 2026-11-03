import { describe, expect, it } from 'vitest'
import { installNativeShell, isMainPage, registerShimCommand, type ShellHost } from './native-shell'

/**
 * What the shim does to the page before the renderer runs: the marker the
 * stylesheets and the renderer read, and the one `window.tdNative` the native
 * side calls — the shim's own commands first, the page's after.
 */

function page(): { host: ShellHost; posted: unknown[] } {
  const posted: unknown[] = []
  const host: ShellHost = {
    document: { documentElement: { dataset: {} } },
    webkit: { messageHandlers: { tdNative: { postMessage: (message: unknown) => posted.push(message) } } },
  }
  return { host, posted }
}

type Commands = { run(name: unknown, arg?: unknown): boolean }

describe('the native shell marker', () => {
  it('sets data-shell="native" on the root element', () => {
    const { host } = page()
    installNativeShell(host)
    expect(host.document.documentElement.dataset.shell).toBe('native')
  })

  it('posts nothing itself — the title comes from the app', () => {
    const { host, posted } = page()
    installNativeShell(host)
    expect(posted).toEqual([])
  })
})

describe('window.tdNative', () => {
  it('says no, to any name, until the page puts its commands there', () => {
    const { host } = page()
    installNativeShell(host)
    const commands = host.tdNative as Commands
    expect(commands.run('new-session')).toBe(false)
    expect(commands.run('select', 'files')).toBe(false)
    expect(commands.run(7)).toBe(false)
  })

  it('hands the page’s names to whatever the page wrote there, with the argument', () => {
    const { host } = page()
    installNativeShell(host)
    const seen: unknown[] = []
    host.tdNative = { run: (name: string, arg?: unknown) => seen.push([name, arg]) > 0 }
    expect((host.tdNative as Commands).run('select', 'files')).toBe(true)
    expect(seen).toEqual([['select', 'files']])
  })

  it('answers the shim’s own commands on every page, whatever the page publishes', () => {
    const { host } = page()
    installNativeShell(host)
    const dropped: unknown[] = []
    registerShimCommand(host, 'drop-paths', (arg) => dropped.push(arg) > 0)
    host.tdNative = { run: () => false }
    expect((host.tdNative as Commands).run('drop-paths', { paths: ['/a'] })).toBe(true)
    expect(dropped).toEqual([{ paths: ['/a'] }])
  })

  it('keeps commands a page set before the shim ran', () => {
    const { host } = page()
    host.tdNative = { run: () => true }
    installNativeShell(host)
    expect((host.tdNative as Commands).run('anything')).toBe(true)
  })
})

describe('the main page', () => {
  it('is the page with no screen of its own named', () => {
    expect(isMainPage('')).toBe(true)
    expect(isMainPage('?t=abc')).toBe(true)
    for (const other of ['?settings=1', '?island=1', '?screen=session&id=s1', '?popout=s1', '?hootpanel=1']) {
      expect(isMainPage(other), other).toBe(false)
    }
  })
})
