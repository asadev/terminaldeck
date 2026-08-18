/**
 * What the copilot is called, and whether anybody has ever been asked.
 *
 * One read of one file, at the top of the window, feeding three things that must
 * never disagree: the name on the pinned row in the rail, the name on the tab
 * pill, and the decision about whether to put the setup flow in front of the
 * copilot's first start.
 *
 * ## Why this reads the instruction file rather than a setting
 *
 * Because that is where the answers are. `shared/copilot-identity.ts` sets out
 * the reasoning in full: the copilot's name is written into the person's half of
 * the copilot layer — the file it is handed at every spawn — so that the agent
 * knows it, the person can edit it in Settings, and there is exactly one copy of
 * the fact. A `copilot.name` preference would be a second copy, and the second
 * copy is the one that goes stale.
 *
 * The cost of that decision lands here: knowing the name means reading a file,
 * which means one round trip through the bridge. It is a single `readFileSync`
 * of a few kilobytes on the other side, done once per window, and refreshed only
 * when something has changed it.
 *
 * ## `hasRun`, and the race it exists to lose safely
 *
 * The flow must appear **before** the copilot starts — *"show what it is about to
 * become before it starts, rather than starting and letting him discover it"* —
 * so the decision has to be made inside the click that opens it. But the click
 * can arrive before the read has landed, and answering "no setup has run" from a
 * state that simply has not loaded would put the flow in front of somebody who
 * finished it last week.
 *
 * So the question is asked as a promise. {@link CopilotSetup.hasRun} resolves
 * from the answer already in hand when there is one, and otherwise waits for the
 * read that is already in flight — never starting a second one. The cost of
 * getting it right is one microtask on the path that opens the copilot.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  copilotName,
  NO_IDENTITY,
  readCopilotIdentity,
  type CopilotIdentity,
} from '../../shared/copilot-identity'
import {
  resolveCopilotBridge,
  toInstructionsRead,
  type CopilotBridge,
} from '../settings/sections/copilot-bridge'

export type SetupStatus =
  /** The file has not been read yet. Nothing may be concluded from this. */
  | 'loading'
  /** Read, and there is no identity block — nobody has ever been asked. */
  | 'unset'
  /** Read, and the flow has run. The identity is whatever it left behind. */
  | 'set'
  /** This build has no copilot channels, so the question cannot be asked. */
  | 'unavailable'

export interface CopilotSetup {
  status: SetupStatus
  identity: CopilotIdentity
  /** What to print. Falls back to this app's own word for an unnamed copilot. */
  name: string
  /**
   * Has the setup flow ever finished? Resolves once the file has been read.
   *
   * `true` for a build with no channels, deliberately: a window that cannot ask
   * must not answer by putting a setup flow in front of a feature it also cannot
   * configure.
   */
  hasRun(): Promise<boolean>
  /** Read it again — after the flow saves, after an edit in Settings. */
  reload(): void
}

export function useCopilotSetup(injected?: Partial<CopilotBridge>): CopilotSetup {
  const bridge = useMemo(() => injected ?? resolveCopilotBridge(), [injected])
  const [status, setStatus] = useState<SetupStatus>(() =>
    bridge.copilotReadInstructions ? 'loading' : 'unavailable',
  )
  const [identity, setIdentity] = useState<CopilotIdentity>(NO_IDENTITY)

  /**
   * The read that is in flight, so `hasRun` can wait on it instead of starting
   * another.
   *
   * A ref rather than state: it is read inside a callback that must not change
   * identity every time a load completes, and nothing draws from it.
   */
  const inFlight = useRef<Promise<boolean> | null>(null)
  /** So an answer that lands after the window closed is not written into a dead tree. */
  const mounted = useRef(true)
  useEffect(() => {
    mounted.current = true
    return () => {
      mounted.current = false
    }
  }, [])

  const read = useCallback((): Promise<boolean> => {
    const ask = bridge.copilotReadInstructions
    if (!ask) return Promise.resolve(true)

    const job = ask()
      .then((raw) => {
        const result = toInstructionsRead(raw)
        /*
         * An unreadable file is `unset`, and that is the correct reading rather
         * than a swallowed error. The one way it fails on a healthy machine is
         * `ENOENT` — no instructions have been written, which is exactly a
         * machine where nobody has been asked anything yet. A window that
         * treated it as "set" would silently never offer the flow on the one
         * install that most needs it.
         */
        const reading = result.ok
          ? readCopilotIdentity(result.text)
          : { ran: false, identity: NO_IDENTITY }
        if (mounted.current) {
          setIdentity(reading.identity)
          setStatus(reading.ran ? 'set' : 'unset')
        }
        return reading.ran
      })
      .catch(() => {
        // The channel threw. That is not evidence about the file either way, so
        // the flow is not offered — the same call `useCopilot` makes when its
        // own probe fails.
        if (mounted.current) setStatus('set')
        return true
      })
      .finally(() => {
        if (inFlight.current === job) inFlight.current = null
      })

    inFlight.current = job
    return job
  }, [bridge])

  useEffect(() => {
    void read()
  }, [read])

  const hasRun = useCallback((): Promise<boolean> => {
    if (inFlight.current) return inFlight.current
    if (status === 'loading') return read()
    return Promise.resolve(status !== 'unset')
  }, [status, read])

  return {
    status,
    identity,
    name: copilotName(identity),
    hasRun,
    reload: useCallback(() => void read(), [read]),
  }
}
