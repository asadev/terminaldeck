import type { MenuItemConstructorOptions } from 'electron'
import { describe, expect, it, vi } from 'vitest'
import type { SessionMeta } from '../shared/types'

/*
 * The background tray against a fake `Tray`, for the one rule that matters now
 * that Hoot's owl can be in the menu bar: one icon for the app — never zero
 * while it is in the background, never two.
 */
const trays: Array<{ destroyed: boolean; menu: unknown }> = []
vi.mock('electron', () => ({
  Tray: class {
    destroyed = false
    menu: unknown = null
    constructor() {
      trays.push(this)
    }
    setToolTip(): void {}
    on(): void {}
    setContextMenu(menu: unknown): void {
      this.menu = menu
    }
    destroy(): void {
      this.destroyed = true
    }
  },
  Menu: { buildFromTemplate: (items: unknown) => items },
  nativeImage: {
    createFromBuffer: () => ({ addRepresentation: () => undefined, setTemplateImage: () => undefined }),
  },
}))

const { ResidentPresence, residentMenuItems } = await import('./resident')

function meta(id: string, cwd = `/work/${id}`): SessionMeta {
  return { id, cwd, title: id, provider: 'claude', exitCode: null, createdAt: 0 }
}

function rig(owl: { on: boolean }) {
  trays.length = 0
  const presence = new ResidentPresence({
    sessions: () => [meta('a'), meta('b')],
    open: () => undefined,
    stop: () => undefined,
    quitAll: () => undefined,
    represented: () => owl.on,
  })
  const live = () => trays.filter((t) => !t.destroyed).length
  return { presence, live }
}

describe('one menu bar icon for the app', () => {
  it('draws none of its own while Hoot’s owl is in the menu bar, and still counts as visible', () => {
    const owl = { on: true }
    const r = rig(owl)
    r.presence.show()
    expect(r.live()).toBe(0)
    expect(r.presence.visible).toBe(true)
  })

  it('draws its own the moment the owl is turned off in the background, and drops it when the owl is back', () => {
    const owl = { on: true }
    const r = rig(owl)
    r.presence.show()
    owl.on = false
    r.presence.refresh()
    expect(r.live()).toBe(1)
    expect(r.presence.visible).toBe(true)
    owl.on = true
    r.presence.refresh()
    expect(r.live()).toBe(0)
  })

  it('draws nothing while the app has a window, whatever the owl is doing', () => {
    const owl = { on: false }
    const r = rig(owl)
    r.presence.refresh()
    expect(r.live()).toBe(0)
    expect(r.presence.visible).toBe(false)
    r.presence.show()
    r.presence.hide()
    expect(r.live()).toBe(0)
  })
})

describe('the background menu, wherever it is shown', () => {
  it('lists the sessions, open and quit, with another icon’s entries in their places', () => {
    const items = residentMenuItems(
      { sessions: () => [meta('a', '/work/api')], open: () => undefined, stop: () => undefined, quitAll: () => undefined },
      { afterOpen: [{ label: 'Hoot Settings…' }], beforeQuit: [{ label: 'Hide Hoot from the Menu Bar' }] },
    )
    const labels = items.map((item: MenuItemConstructorOptions) => item.label ?? `(${item.type})`)
    expect(labels).toEqual([
      'Terminal Deck — 1 session running',
      '(separator)',
      'Open Terminal Deck',
      'Hoot Settings…',
      '(separator)',
      'Claude Code — api',
      '(separator)',
      'Hide Hoot from the Menu Bar',
      '(separator)',
      'Quit and Stop All Sessions',
    ])
  })
})
