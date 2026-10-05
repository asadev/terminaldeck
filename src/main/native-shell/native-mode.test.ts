import { EventEmitter } from 'node:events'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { uiDoCall, UI_LIST_CALL } from '../deck-control/ui-tools'
import { WHERE_CALL } from '../deck-control/where-tool'
import { frontDialogs } from './dialogs'
import { scrubInheritedEnv } from './inherited-env'
import { nativeMachineName, NATIVE_SHELL_FLAG } from './mode'
import { createPageCalls, pageCallFor, PAGE_CALL_CHANNEL } from './page-call'
import { createNativeNotifier, NOTIFICATION_CLICK_CHANNEL } from './notifications'
import { hydrateOnce } from './hydration'

function withFlag(): void {
  beforeEach(() => {
    process.argv.push(NATIVE_SHELL_FLAG)
  })
  afterEach(() => {
    const at = process.argv.lastIndexOf(NATIVE_SHELL_FLAG)
    if (at !== -1) process.argv.splice(at, 1)
  })
}

/* ------------------------------------------------- the inherited session -- */

describe('what the engine does not inherit', () => {
  /** The environment measured on the running proof on 2026-10-05, values shortened. */
  const PROFILE = '/Users/me/Library/Application Support/terminaldeck/profiles/me-example-com'
  const measured = {
    HOME: '/Users/me',
    SHELL: '/bin/zsh',
    TERM: 'xterm-256color',
    CLAUDECODE: '1',
    CLAUDE_CODE_SESSION_ID: 'parent-run',
    CLAUDE_CODE_CHILD_SESSION: '1',
    CLAUDE_EFFORT: 'xhigh',
    CLAUDE_PID: '3227',
    CLAUDE_CONFIG_DIR: PROFILE,
    TERMINALDECK_SESSION_ID: 'their-session',
    TERMINALDECK_ACCOUNT_TICKET: 'secret-ticket',
    TERMINALDECK_ACCOUNT_VAULT: '/Users/me/Library/Application Support/terminaldeck/account-vault/vault.sock',
    ANTHROPIC_BASE_URL: 'https://example.invalid',
    PATH: [
      '/Users/me/Library/Application Support/terminaldeck/account-vault-shim',
      '/Users/me/Library/Application Support/terminaldeck/shim',
      '/Users/me/.local/bin',
      '/Users/me/tools/shim',
      '/Users/me/Library/Application Support/Native Proof/engine/shim',
      '/usr/bin',
    ].join(':'),
  }
  const appDirs = new Set(['/Users/me/Library/Application Support/terminaldeck', '/Users/me/Library/Application Support/Native Proof/engine'])
  const scrub = (env: Record<string, string>) =>
    scrubInheritedEnv(env, {
      ownUserData: '/Users/me/Library/Application Support/Native Proof/engine',
      isAppDataDir: (dir) => appDirs.has(dir),
    })

  it('drops the parent run, the other app’s session and its account folder', () => {
    const { env, removed } = scrub(measured)
    for (const key of [
      'CLAUDECODE',
      'CLAUDE_CODE_SESSION_ID',
      'CLAUDE_CODE_CHILD_SESSION',
      'CLAUDE_EFFORT',
      'CLAUDE_PID',
      'CLAUDE_CONFIG_DIR',
      'TERMINALDECK_SESSION_ID',
      'TERMINALDECK_ACCOUNT_TICKET',
      'TERMINALDECK_ACCOUNT_VAULT',
    ]) {
      expect(env[key], key).toBeUndefined()
      expect(removed).toContain(key)
    }
    // A person's own settings stay.
    expect(env.ANTHROPIC_BASE_URL).toBe('https://example.invalid')
    expect(env.HOME).toBe('/Users/me')
    // Values are never reported.
    expect(removed.join(' ')).not.toContain('secret-ticket')
  })

  it('takes the other copy’s shims off PATH and keeps its own and everybody else’s', () => {
    const { env } = scrub(measured)
    expect(env.PATH.split(':')).toEqual([
      '/Users/me/.local/bin',
      '/Users/me/tools/shim',
      '/Users/me/Library/Application Support/Native Proof/engine/shim',
      '/usr/bin',
    ])
  })

  it('keeps a config folder the person set themselves, with no parent run around it', () => {
    const { env, removed } = scrub({ HOME: '/Users/me', CLAUDE_CONFIG_DIR: '/Users/me/.claude-work', PATH: '/usr/bin' })
    expect(env.CLAUDE_CONFIG_DIR).toBe('/Users/me/.claude-work')
    expect(removed).toEqual([])
  })
})

/* ---------------------------------------------------------------- dialogs -- */

describe('dialogs with no window', () => {
  it('come to the front first and drop a null window', async () => {
    const calls: unknown[][] = []
    const fake = {
      showOpenDialog: async (...args: unknown[]) => {
        calls.push(['open', ...args])
        return { canceled: true, filePaths: [] }
      },
      showMessageBox: async (...args: unknown[]) => {
        calls.push(['box', ...args])
        return { response: 1 }
      },
      showSaveDialog: async (...args: unknown[]) => {
        calls.push(['save', ...args])
        return { canceled: true }
      },
    }
    let fronted = 0
    expect(frontDialogs(fake, () => fronted++).sort()).toEqual(['showMessageBox', 'showOpenDialog', 'showSaveDialog'])
    await fake.showOpenDialog(null, { title: 'Add files' })
    await fake.showMessageBox({ message: 'Allow?' })
    const parent = { window: true }
    await fake.showSaveDialog(parent, { title: 'Save' })
    expect(fronted).toBe(3)
    expect(calls).toEqual([
      ['open', { title: 'Add files' }],
      ['box', { message: 'Allow?' }],
      ['save', parent, { title: 'Save' }],
    ])
  })

  it('still opens the dialog when coming forward fails', async () => {
    const fake = { showMessageBox: async (options: unknown) => options }
    frontDialogs(fake, () => {
      throw new Error('no focus today')
    })
    await expect(fake.showMessageBox({ message: 'x' })).resolves.toEqual({ message: 'x' })
  })
})

/* ------------------------------------------------------------- page calls -- */

describe('Hoot’s window readers in the native page', () => {
  it('recognises exactly the three calls the tools make', () => {
    expect(pageCallFor(WHERE_CALL)).toEqual({ fn: 'where' })
    expect(pageCallFor(UI_LIST_CALL)).toEqual({ fn: 'ui.list' })
    expect(pageCallFor(uiDoCall({ kind: 'panel', target: 'tasks x' }))).toEqual({
      fn: 'ui.do',
      arg: { kind: 'panel', target: 'tasks x' },
    })
    expect(pageCallFor('fetch("https://example.invalid")')).toBeNull()
    expect(pageCallFor(`${uiDoCall({ kind: 'a', target: 'b' })}; alert(1)`)).toBeNull()
  })

  it('asks the page by name and returns its answer', async () => {
    const pushed: unknown[][] = []
    const calls = createPageCalls({
      push: (channel, args) => {
        pushed.push([channel, ...args])
        return true
      },
    })
    const answer = calls.evaluate(uiDoCall({ kind: 'panel', target: 'tasks' }))
    const [channel, call] = pushed[0] as [string, { id: string; fn: string; arg: unknown }]
    expect(channel).toBe(PAGE_CALL_CHANNEL)
    expect(call.fn).toBe('ui.do')
    expect(call.arg).toEqual({ kind: 'panel', target: 'tasks' })
    calls.settle(call.id, { ok: true })
    await expect(answer).resolves.toEqual({ ok: true })
  })

  it('answers null with no page, null on silence, and refuses any other script', async () => {
    const none = createPageCalls({ push: () => false })
    await expect(none.evaluate(WHERE_CALL)).resolves.toBeNull()
    const silent = createPageCalls({ push: () => true, timeoutMs: 10 })
    await expect(silent.evaluate(UI_LIST_CALL)).resolves.toBeNull()
    await expect(silent.evaluate('document.cookie')).rejects.toThrow(/named page calls/)
  })
})

/* ----------------------------------------------------------- the machine -- */

describe('its name on the relay', () => {
  it('is the plain name outside the native shell', () => {
    expect(nativeMachineName('mac-mini')).toBe('mac-mini')
  })

  describe('inside it', () => {
    withFlag()
    it('says which copy it is', () => {
      expect(nativeMachineName('mac-mini')).toBe('mac-mini (native)')
    })
  })
})

/* -------------------------------------------------------- plugin consent -- */

const electron = vi.hoisted(() => ({
  fromWebContents: vi.fn((): unknown => null),
  showMessageBox: vi.fn(async (..._args: unknown[]) => ({ response: 1 })),
}))
vi.mock('electron', () => ({
  BrowserWindow: { fromWebContents: electron.fromWebContents },
  dialog: { showMessageBox: electron.showMessageBox },
}))

describe('a plugin asking for consent', () => {
  const approver = { isDestroyed: () => false } as unknown as Electron.WebContents
  const request = { message: 'Let the plugin read files?', detail: 'It asked to.' }

  beforeEach(() => {
    electron.fromWebContents.mockClear()
    electron.showMessageBox.mockClear()
  })

  it('is refused outside the native shell when there is no window to ask over', async () => {
    const { nativePluginConsent } = await import('../plugins/consent')
    const outcome = await nativePluginConsent(() => approver)(request as never)
    expect(outcome).toMatchObject({ granted: false, reason: 'no-approver' })
    expect(electron.showMessageBox).not.toHaveBeenCalled()
  })

  describe('in the native shell', () => {
    withFlag()
    it('is asked in a free-standing box, and the answer counts', async () => {
      const { nativePluginConsent } = await import('../plugins/consent')
      const outcome = await nativePluginConsent(() => approver)(request as never)
      expect(outcome).toMatchObject({ granted: true })
      expect(electron.fromWebContents).not.toHaveBeenCalled()
      expect(electron.showMessageBox).toHaveBeenCalledTimes(1)
      const args = electron.showMessageBox.mock.calls[0]
      expect(args).toHaveLength(1)
      expect(args[0]).toMatchObject({ message: request.message })
    })
  })
})

/* ---------------------------------------------------------- notifications -- */

describe('the page’s banners', () => {
  class FakeBanner extends EventEmitter {
    shown = 0
    closed = 0
    show(): void {
      this.shown++
    }
    close(): void {
      this.closed++
      this.emit('close')
    }
    override on(event: string, listener: () => void): this {
      return super.on(event, listener)
    }
  }

  it('shows one, and sends the click back to the page by its id', () => {
    const made: FakeBanner[] = []
    const pushed: unknown[][] = []
    const notifier = createNativeNotifier({
      supported: () => true,
      make: () => {
        const banner = new FakeBanner()
        made.push(banner)
        return banner
      },
      push: (channel, args) => pushed.push([channel, ...args]),
    })
    expect(notifier.notify({ id: 'n1', title: 'Session finished', body: 'deck' })).toEqual({ shown: true })
    expect(made[0].shown).toBe(1)
    made[0].emit('click')
    expect(pushed).toEqual([[NOTIFICATION_CLICK_CHANNEL, 'n1']])
    notifier.notify({ id: 'n2', title: 'Needs you' })
    notifier.close('n2')
    expect(made[1].closed).toBe(1)
  })

  it('shows nothing without a title, an id, or system support', () => {
    const notifier = createNativeNotifier({ supported: () => false, make: () => new FakeBanner(), push: () => undefined })
    expect(notifier.notify({ id: 'n1', title: 'x' })).toEqual({ shown: false })
    const supported = createNativeNotifier({ supported: () => true, make: () => new FakeBanner(), push: () => undefined })
    expect(supported.notify({ title: 'x' })).toEqual({ shown: false })
    expect(supported.notify('junk')).toEqual({ shown: false })
  })
})

/* -------------------------------------------------------------- hydration -- */

describe('telling the pages about the sessions', () => {
  it('restores for the first page only; a second or third stream changes nothing', () => {
    let runs = 0
    const onClient = hydrateOnce(() => runs++)
    onClient()
    onClient()
    onClient()
    expect(runs).toBe(1)
  })
})
