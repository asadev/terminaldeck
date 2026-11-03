import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { linkProps, openLink, openLinkExternally, showLinkMenu } from './link'

/**
 * How the renderer asks for a link to be opened.
 *
 * There is no DOM in this project's test setup, so `window` — which is the
 * whole mechanism — is stood up per case. That is not a shortcut: `openLink`
 * deliberately goes through `window.open` rather than an IPC call so that plain
 * `<a target="_blank">` anchors take the same route, and a test that mocked an
 * IPC instead would be testing a design this file does not have.
 */

const open = vi.fn()
const externally = vi.fn(async () => true)
const menu = vi.fn(async () => true)
const host = globalThis as { window?: unknown }

beforeEach(() => {
  open.mockClear()
  externally.mockClear()
  menu.mockClear()
  host.window = { open, deck: { openLinkExternally: externally, showLinkMenu: menu } }
})

afterEach(() => {
  delete host.window
})

describe('openLink', () => {
  it('hands an http(s) URL to the window-open handler, which makes it a tab', () => {
    openLink('https://github.com/cli/cli/pull/1')
    expect(open).toHaveBeenCalledWith(
      'https://github.com/cli/cli/pull/1',
      '_blank',
      'noopener,noreferrer',
    )
    expect(externally, 'the default is in-app, not out').not.toHaveBeenCalled()
  })

  /** These URLs come off the network; a scheme check is cheaper than trust. */
  it('refuses any scheme that is not http or https', () => {
    openLink('javascript:alert(1)')
    openLink('file:///etc/passwd')
    openLink('')
    expect(open).not.toHaveBeenCalled()
  })
})

describe('the way out', () => {
  it('asks the main process to open a link on the machine', () => {
    openLinkExternally('https://github.com/login/device')
    expect(externally).toHaveBeenCalledWith('https://github.com/login/device')
    expect(open, 'the way out must not also open a tab').not.toHaveBeenCalled()
  })

  it('pops the native menu for a right-click', () => {
    showLinkMenu('https://example.com')
    expect(menu).toHaveBeenCalledWith('https://example.com')
  })

  /**
   * The harness mounts the real `App` against a stubbed preload, and older
   * builds of the preload will not have these. A missing bridge method must be
   * a link that does nothing, not a TypeError that takes the panel down.
   */
  it('does nothing when the bridge has no such method', () => {
    host.window = { open }
    expect(() => openLinkExternally('https://example.com')).not.toThrow()
    expect(() => showLinkMenu('https://example.com')).not.toThrow()
    host.window = undefined
    expect(() => openLinkExternally('https://example.com')).not.toThrow()
  })
})

describe('linkProps', () => {
  it('is both handlers at once, so a call site cannot wire only one', () => {
    const props = linkProps('https://example.com/x')
    expect(Object.keys(props).sort()).toEqual(['onClick', 'onContextMenu'])

    props.onClick()
    expect(open).toHaveBeenCalledWith('https://example.com/x', '_blank', 'noopener,noreferrer')

    const preventDefault = vi.fn()
    props.onContextMenu({ preventDefault } as never)
    expect(preventDefault).toHaveBeenCalled()
    expect(menu).toHaveBeenCalledWith('https://example.com/x')
  })

  it('survives a URL that is not there yet', () => {
    // Called during render for a panel whose sign-in has not resolved, so the
    // URL can legitimately be an empty string for a frame.
    const props = linkProps('')
    props.onClick()
    props.onContextMenu({ preventDefault: () => undefined } as never)
    expect(open).not.toHaveBeenCalled()
    expect(menu).toHaveBeenCalledWith('')
  })
})
