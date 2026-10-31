import { describe, expect, it } from 'vitest'
import { NATIVE_MESSAGE_HANDLER, type NativeHost } from '../shared/native-shell'
import { hideNativeDialog, publishDialogCommands, showNativeDialog, type DialogHandler } from './native-dialogs'

function host(native: boolean) {
  const posted: Array<Record<string, unknown>> = []
  const target: NativeHost & { tdDialog?: { run(name: unknown, action: unknown, arg?: unknown): boolean } } = {
    document: { documentElement: { dataset: native ? { shell: 'native' } : {} } },
    webkit: { messageHandlers: { [NATIVE_MESSAGE_HANDLER]: { postMessage: (m) => posted.push(m as Record<string, unknown>) } } },
  }
  return { target, posted }
}

describe('the page hands its dialogs to the native window', () => {
  it('opens and closes a dialog, each newer than the last', () => {
    const page = host(true)
    showNativeDialog('close-confirm', { title: 'zsh', status: 'idle' }, page.target)
    hideNativeDialog('close-confirm', page.target)
    expect(page.posted.map((m) => [m.type, m.name, m.open])).toEqual([
      ['dialog', 'close-confirm', true],
      ['dialog', 'close-confirm', false],
    ])
    expect(page.posted[0].data).toEqual({ title: 'zsh', status: 'idle' })
    expect(Number(page.posted[1].seq)).toBeGreaterThan(Number(page.posted[0].seq))
  })

  it('keeps one opening while a dialog is updated, and a new one when it opens again', () => {
    const page = host(true)
    showNativeDialog('switch-account', { busy: true }, page.target)
    showNativeDialog('switch-account', { busy: false }, page.target)
    hideNativeDialog('switch-account', page.target)
    hideNativeDialog('switch-account', page.target) // already closed: nothing more is said
    showNativeDialog('switch-account', {}, page.target)
    const openings = page.posted.map((m) => m.opening)
    expect(page.posted).toHaveLength(4)
    expect(openings[0]).toBe(openings[1])
    expect(openings[2]).toBe(openings[0])
    expect(openings[3]).not.toBe(openings[0])
  })

  it('says nothing outside the native window', () => {
    const page = host(false)
    showNativeDialog('close-confirm', {}, page.target)
    hideNativeDialog('close-confirm', page.target)
    expect(page.posted).toEqual([])
  })

  it('routes the native answer to the dialog it is for', () => {
    const page = host(true)
    const seen: Array<[string, unknown]> = []
    const handlers: Record<string, DialogHandler> = {
      'close-confirm': (action, arg) => {
        seen.push([action, arg])
      },
    }
    const stop = publishDialogCommands(() => handlers, page.target)
    expect(page.target.tdDialog?.run('close-confirm', 'confirm', { suppress: true })).toBe(true)
    expect(page.target.tdDialog?.run('nope', 'confirm')).toBe(false)
    expect(page.target.tdDialog?.run(42, 'confirm')).toBe(false)
    expect(seen).toEqual([['confirm', { suppress: true }]])
    stop()
    expect(page.target.tdDialog).toBeUndefined()
  })

  it('installs nothing outside the native window', () => {
    const page = host(false)
    publishDialogCommands(() => ({}), page.target)
    expect(page.target.tdDialog).toBeUndefined()
  })
})
