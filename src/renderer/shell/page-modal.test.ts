import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { createPageModal } from './page-modal'

/**
 * "A dialog is open in the page", for the native window that may be drawing a
 * screen over it: said when the first one opens and when the last one closes —
 * once each, however many are stacked — from the app's dialog primitives.
 */

const RENDERER = join(__dirname, '..')
const read = (path: string): string => readFileSync(join(RENDERER, path), 'utf8')

describe('the count', () => {
  it('says open on the first dialog and closed on the last, once each', () => {
    const told: boolean[] = []
    const modal = createPageModal((open) => told.push(open))
    const sheet = modal.hold()
    const confirm = modal.hold()
    expect(told).toEqual([true])
    confirm()
    expect(told).toEqual([true])
    sheet()
    expect(told).toEqual([true, false])
    expect(modal.held()).toBe(0)
  })

  it('ignores a release called twice', () => {
    const told: boolean[] = []
    const modal = createPageModal((open) => told.push(open))
    const one = modal.hold()
    const two = modal.hold()
    one()
    one()
    expect(modal.held()).toBe(1)
    two()
    expect(told).toEqual([true, false])
  })

  it('posts only in the native shell, as the contract’s message', () => {
    const source = read('shell/page-modal.ts')
    expect(source).toContain("if (isNativeShell()) postToNative({ type: 'page-modal', open })")
  })
})

describe('the dialogs that hold it', () => {
  it('every sheet, through Modal — while it is open and not parked', () => {
    expect(read('components/Modal.tsx')).toContain('usePageModal(open && !hidden)')
  })

  it('the command palette', () => {
    expect(read('components/CommandPalette.tsx')).toContain('usePageModal(open)')
  })

  it('every task overlay, through the one scroll lock they all take', () => {
    expect(read('crm-task/lib/use-scroll-lock.ts')).toContain('usePageModal(active)')
    for (const overlay of ['crm-task/ui/dialog.tsx', 'crm-task/photo-lightbox.tsx']) {
      expect(read(overlay), overlay).toContain('useScrollLock(open)')
    }
  })

  it('Accounts’ add-account popup', () => {
    expect(read('settings/sections/AddAccountDialog.tsx')).toContain('usePageModal(props.open)')
  })

  it('is every primitive that draws an aria-modal dialog over the page', () => {
    const modals = [
      'components/Modal.tsx',
      'components/CommandPalette.tsx',
      'crm-task/ui/dialog.tsx',
      'crm-task/photo-lightbox.tsx',
    ]
    for (const file of modals) expect(read(file), file).toContain('aria-modal')
  })
})
