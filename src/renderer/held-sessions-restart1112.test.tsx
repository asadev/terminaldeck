import { isValidElement, type ReactNode } from 'react'
import { expect, it, vi } from 'vitest'
import { useHeldSessions, type HeldSessionsBridge } from './held-sessions'
import { Sidebar } from './shell/Sidebar'

// This project uses no DOM. Retain hook state between renders and drive the real Sidebar button handler.
const hooks = vi.hoisted(() => ({ slots: [] as unknown[], cursor: 0, active: false, effect: undefined as (() => void) | undefined }))
vi.mock('react', async (original) => {
  const react = await original<typeof import('react')>()
  return {
    ...react,
    useState: (initial: unknown) => {
      const value = () => typeof initial === 'function' ? (initial as () => unknown)() : initial
      if (!hooks.active) return [value(), () => {}]
      const index = hooks.cursor++
      if (!(index in hooks.slots)) hooks.slots[index] = value()
      return [hooks.slots[index], (next: unknown) => { hooks.slots[index] = typeof next === 'function' ? (next as (old: unknown) => unknown)(hooks.slots[index]) : next }]
    },
    useCallback: (fn: unknown) => fn,
    useMemo: (fn: () => unknown) => fn(),
    useContext: () => null,
    useSyncExternalStore: (_subscribe: unknown, _get: unknown, server: () => unknown) => server(),
    useEffect: (effect: () => void) => { if (hooks.active && !hooks.effect) hooks.effect = effect },
    useRef: (current: unknown) => ({ current }),
  }
})

type Button = { title?: string; className?: string; disabled?: boolean; onClick?: () => void; children?: ReactNode }
function findHeldButton(node: ReactNode): Button | undefined {
  if (Array.isArray(node)) return node.map(findHeldButton).find(Boolean)
  if (!isValidElement<Button>(node)) return undefined
  if (node.props.className?.includes('sb-held-open')) return node.props
  return findHeldButton(node.props.children)
}
const noop = () => {}

it.each(['login', 'history'])('renderer held-row Retry keeps a removed %s account until it is re-added', async (removed) => {
  hooks.slots = []; hooks.cursor = 0; hooks.effect = undefined
  const reason = "this tab's account or conversation history account was removed. Add it again with its original name in Settings › Coding AIs, then press Retry."
  const saved = { key: 'held-1', tabKey: 'same-tab', cwd: '/fixture', provider: 'claude', profileId: removed === 'login' ? 'original' : 'working',
    ...(removed === 'history' ? { homeProfileId: 'original' } : {}), reason, at: 1, pick: false, recoveryAction: 'retry' }
  let accountExists = false
  const retryHeldSession = vi.fn(async (key: string) => {
    expect(key).toBe(saved.key)
    return accountExists ? [] : [saved]
  })
  const bridge: HeldSessionsBridge = { listHeldSessions: async () => [saved], retryHeldSession,
    forgetHeldSession: vi.fn(async () => []), onHeldSessions: () => noop }
  const renderHook = () => {
    hooks.active = true; hooks.cursor = 0
    try { return useHeldSessions(bridge) } finally { hooks.active = false }
  }
  renderHook(); hooks.effect?.()
  await Promise.resolve()
  let held = renderHook()
  const button = () => findHeldButton(Sidebar({ width: 264, projects: [{ path: '/fixture', name: 'Fixture' }], tabs: [], activeTabId: null,
    activePanel: null, held: held.rows, heldRetrying: held.retrying, onRetryHeld: held.retry, onForgetHeld: held.forget,
    onSelectTab: noop, onCloseTab: noop, onSelectPanel: noop, onNewSession: noop, onNewBrowserTab: noop, onOpenProject: noop,
    onCloseProject: noop, onOpenSettings: noop, onOpenAlerts: noop, onToggleCollapsed: noop, onPeekStart: noop, onPeekEnd: noop, onStartResize: noop }))
  expect(button()?.title).toContain(reason)
  expect(button()?.disabled).toBe(false)
  button()?.onClick?.()
  await Promise.resolve()
  held = renderHook()
  expect(held.rows).toHaveLength(1)
  expect(held.rows[0]).toMatchObject(saved)
  expect(button()?.title).toContain('then press Retry')
  expect(bridge.forgetHeldSession).not.toHaveBeenCalled()
  accountExists = true // The backend now reports the original account re-added, not a replacement selection.
  button()?.onClick?.()
  await Promise.resolve()
  held = renderHook()
  expect(held.rows).toEqual([])
  expect(retryHeldSession.mock.calls).toEqual([[saved.key], [saved.key]])
  expect(bridge.forgetHeldSession).not.toHaveBeenCalled()
})
