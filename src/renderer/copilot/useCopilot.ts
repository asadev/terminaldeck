/**
 * The window's one connection to the copilot.
 *
 * Mounted once, in `App.tsx`, and read by three places that must never disagree
 * about it: the pinned entry in the rail, the view it opens, and the filter that
 * keeps the copilot's *own* session out of the ordinary session list.
 *
 * ## Why the state is asked for rather than pushed
 *
 * There is no `copilot:changed` broadcast, and this deliberately does not invent
 * one. `copilotState` in the main process is computed from the filesystem and a
 * liveness check on every call, so it is never stale by construction — and the
 * things that change it are things a person does in this window (open it, stop
 * it) or one event the window can already hear (the session exiting). So the
 * read is on those moments plus a slow backstop, rather than on a timer fast
 * enough to feel live. A copilot whose process was killed from a terminal is the
 * one case nothing tells the window about, and the backstop is what catches it.
 *
 * ## Why opening the view is what starts it
 *
 * `ensureCopilot` spawns a real agent CLI, and an agent CLI bills for what it
 * does. Starting it at launch would put a standing charge on opening the app,
 * for an assistant nobody had asked anything. So nothing here starts it: the
 * copilot view calls `ensure()` when it opens, which is the moment somebody has
 * said they want to talk to it. It is idempotent by contract — see
 * `ensureCopilot`'s own header — so opening the view twice is one copilot.
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import {
  copilotStage,
  readCopilotSignIn,
  readCopilotState,
  type CopilotSignInView,
  type CopilotStage,
  type CopilotStateView,
} from './copilot-model'

/**
 * The bridge methods this hook uses.
 *
 * Declared as an interface a component takes rather than reaching for
 * `window.deck` inline, for the reason `preload/contract.test.ts` guards: a
 * `*Bridge` interface is checked against what the preload actually exposes, so a
 * method renamed on one side fails a test instead of rendering an empty state
 * that looks like an unbuilt feature.
 */
export interface CopilotBridge {
  copilotState(): Promise<unknown>
  ensureCopilot(): Promise<unknown>
  stopCopilot(): Promise<unknown>
  copilotSignIn(): Promise<unknown>
}

export interface Copilot {
  state: CopilotStateView | null
  signIn: CopilotSignInView | null
  stage: CopilotStage
  /** True until the first answer has landed, so nothing draws "stopped" too early. */
  loading: boolean
  /** Start it if it is not running, and refresh. Safe to call repeatedly. */
  ensure(): void
  /** Stop it, and refresh. */
  stop(): void
  /** Ask again — after a login, after an exit, on a Check again button. */
  refresh(): void
}

/**
 * How often the state is re-read while a window is open.
 *
 * Thirty seconds, and it is a backstop rather than the mechanism. Everything a
 * person does goes through `ensure`/`stop`/`refresh`, which read immediately;
 * this exists for the one thing nothing reports — a copilot killed from outside
 * the app — so the interval only has to be shorter than somebody's patience,
 * not shorter than their reaction time. Each tick is a handful of `stat` calls
 * on a directory of small files.
 */
const REFRESH_MS = 30_000

function bridge(): CopilotBridge | null {
  const deck = (globalThis as { deck?: Partial<CopilotBridge> }).deck
  if (!deck || typeof deck.copilotState !== 'function') return null
  return deck as CopilotBridge
}

export function useCopilot(injected?: CopilotBridge | null): Copilot {
  // `useState` rather than `useMemo`: a bridge resolved during render would be
  // re-resolved on every render, and the harness swaps `window.deck` in before
  // the first paint, so resolving once at mount is both cheaper and correct.
  const [deck] = useState<CopilotBridge | null>(() => injected ?? bridge())
  const [state, setState] = useState<CopilotStateView | null>(null)
  const [signIn, setSignIn] = useState<CopilotSignInView | null>(null)
  const [loading, setLoading] = useState(true)

  /** So a read that lands after unmount does not write into a dead tree. */
  const mounted = useRef(true)
  useEffect(() => {
    mounted.current = true
    return () => {
      mounted.current = false
    }
  }, [])

  const apply = useCallback((value: unknown) => {
    if (!mounted.current) return
    const next = readCopilotState(value)
    setLoading(false)
    // Only on a readable answer. Writing `null` for an unreadable one would
    // blank a pane that is showing the truth, and the truth has not changed —
    // one call failed.
    if (next) setState(next)
  }, [])

  /**
   * Ask whether it is signed in.
   *
   * Only while it is running, and that is not an optimisation. The probe spawns
   * the agent's CLI inside the copilot's own sandbox to ask about the copilot's
   * own credential store; asking it about a copilot that is not running would
   * spend a `sandbox-exec` proof and a process on a question with no subject.
   * The main process memoises the answer for a minute of its own.
   */
  const askSignIn = useCallback(
    (running: boolean) => {
      if (!deck || !running) {
        if (!running) setSignIn(null)
        return
      }
      void deck
        .copilotSignIn()
        .then((value) => {
          if (mounted.current) setSignIn(readCopilotSignIn(value))
        })
        .catch(() => {
          // The channel is missing or threw. That is not evidence of being
          // signed out, so nothing is written: the stage stays `checking`,
          // which says exactly what happened.
        })
    },
    [deck],
  )

  const refresh = useCallback(() => {
    if (!deck) {
      setLoading(false)
      return
    }
    void deck
      .copilotState()
      .then((value) => {
        apply(value)
        askSignIn(readCopilotState(value)?.status === 'running')
      })
      .catch(() => {
        if (mounted.current) setLoading(false)
      })
  }, [deck, apply, askSignIn])

  const ensure = useCallback(() => {
    if (!deck) return
    // Optimistic only in the honest direction: nothing is claimed to be running.
    // `ensureCopilot` can take a few seconds to prove a sandbox and spawn a CLI,
    // and a pane with no sign of life in that window reads as a dead button.
    setLoading(true)
    void deck
      .ensureCopilot()
      .then((value) => {
        apply(value)
        askSignIn(readCopilotState(value)?.status === 'running')
      })
      .catch(() => {
        if (mounted.current) setLoading(false)
      })
  }, [deck, apply, askSignIn])

  const stop = useCallback(() => {
    if (!deck) return
    void deck
      .stopCopilot()
      .then((value) => {
        apply(value)
        // Not asked again: nothing is running to ask. Cleared, so a restart
        // shows `checking` rather than the answer from before it was stopped.
        if (mounted.current) setSignIn(null)
      })
      .catch(() => {})
  }, [deck, apply])

  useEffect(() => {
    refresh()
    const timer = setInterval(refresh, REFRESH_MS)
    return () => clearInterval(timer)
  }, [refresh])

  return { state, signIn, stage: copilotStage(state, signIn), loading, ensure, stop, refresh }
}
