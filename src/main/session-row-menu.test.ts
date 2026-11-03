import type { MenuItemConstructorOptions } from 'electron'
import { describe, expect, it, vi } from 'vitest'

/*
 * The native ⋯ menu, with Electron's `Menu` replaced by one that records the
 * template and presses an item on request — so what a row offers, and what a
 * press answers, can be read without a window.
 */
const built: MenuItemConstructorOptions[][] = []
let press: string | null = null

vi.mock('electron', () => ({
  Menu: {
    buildFromTemplate: (items: MenuItemConstructorOptions[]) => {
      built.push(items)
      return {
        popup: (options: { callback?: () => void }) => {
          const item = items.find((entry) => entry.label === press)
          ;(item?.click as (() => void) | undefined)?.()
          options.callback?.()
        },
      }
    },
  },
}))

const { showSessionRowMenu } = await import('./session-row-menu')

const deps = { window: () => ({ isDestroyed: () => false }) } as never

function labels(): string[] {
  return (built.at(-1) ?? []).map((item) => item.label ?? `(${item.type})`)
}

describe('the row menu’s window moves', () => {
  it('offers Move to New Window for a session in the main window, and answers it', async () => {
    press = 'Move to New Window'
    const choice = await showSessionRowMenu(deps, { sessionId: 's1', name: 'Session 1', promoted: true, window: 'main' })
    expect(labels()).toContain('Move to New Window')
    expect(labels()).not.toContain('Move Back to Main Window')
    expect(choice).toBe('popout')
  })

  it('offers its window and the way back for a session that is out', async () => {
    press = 'Move Back to Main Window'
    const choice = await showSessionRowMenu(deps, { sessionId: 's1', name: 'Session 1', promoted: true, window: 'own' })
    expect(labels()).toEqual(expect.arrayContaining(['Show Its Window', 'Move Back to Main Window']))
    expect(labels()).not.toContain('Move to New Window')
    expect(choice).toBe('dock')
  })

  it('offers neither for a row that cannot have a window of its own', async () => {
    press = null
    await showSessionRowMenu(deps, { sessionId: 'copilot', name: 'Copilot', promoted: false })
    expect(labels().some((label) => /Window/.test(label))).toBe(false)
  })
})
