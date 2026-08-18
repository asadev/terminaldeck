/**
 * The sessions that were open, did not come back, and are being kept.
 *
 * ## What the window is for here
 *
 * The main process holds them (`main/session-held.ts` has the account, and the
 * bug report behind it). This file is the other half of the promise: that a
 * person can *see* it.
 *
 * That half is the one that was missing. When four of Asad's sessions failed to
 * restart on 2026-08-16, the app wrote a warning to a log nobody had opened,
 * quietly replaced them with something else, and showed a window that looked
 * completely normal. He found out because the agent he had been talking to for a
 * day was a bare terminal that could not remember anything — which is the worst
 * possible way to be told, because the symptom is three steps from the cause.
 *
 * So a held session is a **row**. It sits under its project in the rail, where
 * that session's row was yesterday, and it says what happened and offers to try
 * again. Nothing is retried behind anybody's back and nothing is dismissed on a
 * timer: the app got this wrong by deciding on somebody's behalf, and the fix is
 * not a cleverer decision.
 *
 * ## Why the shape is narrowed here rather than typed across the bridge
 *
 * The house rule for every feature module — the shape lives in the main-process
 * module that owns it and crosses as `unknown`, because a type duplicated on
 * both sides of the bridge is two types that drift. This narrower is total: an
 * answer that is not the expected shape produces no rows rather than a crash, so
 * a channel that goes missing costs the rows and not the window.
 */

import { useCallback, useEffect, useState } from 'react'
// Relative, not '@shared/agent-catalog'. Vitest runs without the electron-vite
// alias, so a *value* import through it resolves in the app and throws in a
// test — `ProviderPicker.tsx`, `McpServers.tsx` and `PowerSection.tsx` all
// carry this note for the same reason.
import { AGENT_CATALOG } from '../shared/agent-catalog'
import { CUSTOM_PROVIDER_PREFIX } from '../shared/custom-agents'
import type { ProviderId } from '@shared/types'

/** One held session, as the rail draws it. */
export interface HeldSessionView {
  key: string
  cwd: string
  provider: string
  /** Why it did not start, in the main process's own words. */
  reason: string
  /** When the last attempt failed. Epoch ms. */
  at: number
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

/**
 * What to call the agent on a held row.
 *
 * The row exists to say *what you asked for*, so the name on it is the whole
 * point: "Claude Code did not start" is a sentence somebody can act on, and
 * "claude did not start" is a sentence about a string. The catalogue for the
 * agents this build ships; for one somebody added, the id minus its prefix,
 * because `customAgentId` derives that id from the label they typed and it is
 * the closest thing to their own word for it that survives into `openSessions`.
 *
 * Deliberately not a lookup through the custom-agent store. That store is
 * loaded asynchronously by the settings pane, and a rail row whose name arrives
 * two frames late — or not at all, for an agent since removed, which is one of
 * the cases that produces a held row in the first place — would be a row that
 * flickers or reads blank. The reason underneath it is written by the main
 * process, which *does* have the store, and that is where the person's own
 * label appears in full.
 */
export function heldAgentName(provider: string): string {
  const known = AGENT_CATALOG[provider as ProviderId]
  if (known !== undefined) return known.label
  return provider.startsWith(CUSTOM_PROVIDER_PREFIX)
    ? provider.slice(CUSTOM_PROVIDER_PREFIX.length)
    : provider
}

/**
 * Read the answer from `sessions:held`.
 *
 * A row needs a key to retry with, a folder to sit under and a reason to show,
 * so an entry missing any of those three is dropped rather than drawn with a
 * blank in it. `provider` and `at` are allowed to be missing and default,
 * because a row with an unknown agent and an unknown time is still a row that
 * tells a person their session did not come back.
 */
export function readHeldSessions(raw: unknown): HeldSessionView[] {
  if (!Array.isArray(raw)) return []
  const rows: HeldSessionView[] = []
  for (const entry of raw) {
    if (!isRecord(entry)) continue
    const { key, cwd, reason } = entry
    if (typeof key !== 'string' || key === '') continue
    if (typeof cwd !== 'string' || cwd === '') continue
    if (typeof reason !== 'string') continue
    rows.push({
      key,
      cwd,
      reason,
      provider: typeof entry.provider === 'string' ? entry.provider : 'shell',
      at: typeof entry.at === 'number' ? entry.at : 0,
    })
  }
  return rows
}

/**
 * The bridge methods this hook uses.
 *
 * An interface the hook takes rather than `window.deck` reached for inline, for
 * the reason `preload/contract.test.ts` guards: a `*Bridge` interface is checked
 * against what the preload actually exposes, so a method renamed on one side
 * fails a test instead of rendering an empty state that looks like a feature
 * nobody built.
 */
export interface HeldSessionsBridge {
  listHeldSessions(): Promise<unknown>
  retryHeldSession(key: string): Promise<unknown>
  forgetHeldSession(key: string): Promise<unknown>
  onHeldSessions(cb: (held: unknown) => void): () => void
}

export interface HeldSessions {
  rows: readonly HeldSessionView[]
  /** Keys with an attempt in flight, so the row can say so and not fire twice. */
  retrying: readonly string[]
  retry(key: string): void
  forget(key: string): void
}

function bridge(): HeldSessionsBridge | null {
  const deck = (globalThis as { deck?: Partial<HeldSessionsBridge> }).deck
  if (!deck || typeof deck.listHeldSessions !== 'function') return null
  return deck as HeldSessionsBridge
}

/**
 * Subscribe to the held list.
 *
 * Pushed, not polled. The list changes at two moments and the window can hear
 * both: the restore at launch fills it, and any attempt — from here or from
 * anywhere else — refills it. A timer over the top would be this app asking a
 * question whose answer arrives on its own, which rule 7.9 of the build
 * preferences objects to and which would also be wrong: a person watching a row
 * they just pressed wants the answer at the speed of the spawn, not of the next
 * tick.
 *
 * The initial read still happens, because a subscription only carries changes
 * and the launch's restore is over long before this window mounts on a renderer
 * reload.
 */
export function useHeldSessions(injected?: HeldSessionsBridge | null): HeldSessions {
  // `useState` rather than `useMemo`: the harness swaps `window.deck` in before
  // the first paint, so resolving once at mount is both cheaper and correct.
  const [deck] = useState<HeldSessionsBridge | null>(() => injected ?? bridge())
  const [rows, setRows] = useState<readonly HeldSessionView[]>([])
  const [retrying, setRetrying] = useState<readonly string[]>([])

  useEffect(() => {
    if (!deck) return
    let alive = true
    const apply = (value: unknown): void => {
      if (alive) setRows(readHeldSessions(value))
    }
    void deck.listHeldSessions().then(apply, () => undefined)
    const off = deck.onHeldSessions(apply)
    return () => {
      alive = false
      off()
    }
  }, [deck])

  const retry = useCallback(
    (key: string) => {
      if (!deck) return
      /*
       * Guarded against a second press, and the guard is not cosmetic. A retry
       * spawns a session; two of them spawn two, in one folder, on one agent —
       * and `planRestore` then has to decide which of the pair continues the
       * conversation, so the duplicate does not merely waste a process, it
       * demotes the real one to a fresh start. A row that is already trying says
       * so and does nothing.
       */
      if (retrying.includes(key)) return
      setRetrying((keys) => [...keys, key])
      const done = (): void => setRetrying((keys) => keys.filter((k) => k !== key))
      void deck.retryHeldSession(key).then(
        (value) => {
          setRows(readHeldSessions(value))
          done()
        },
        () => done(),
      )
    },
    [deck, retrying],
  )

  const forget = useCallback(
    (key: string) => {
      if (!deck) return
      void deck.forgetHeldSession(key).then(
        (value) => setRows(readHeldSessions(value)),
        () => undefined,
      )
    },
    [deck],
  )

  return { rows, retrying, retry, forget }
}
