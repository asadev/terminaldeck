/**
 * This window, registered as the one that answers the copilot's alter-tier
 * questions.
 *
 * ## Why the attach exists at all
 *
 * `deck-control` refuses every alter-tier call with `no-approver` until some
 * window has said *I will answer*. That is the intended resting state and not a
 * gap — `consent.ts` argues it at length — and it means this hook is not a
 * decoration on a working gate: **it is the half that makes the gate answerable
 * at all.** Without it the copilot can never write a setting, never stop one of
 * your sessions, never do anything in the tier that exists to be confirmed.
 *
 * ## Why it retries
 *
 * The channel is registered once a loopback server has bound a port, which
 * happens a few milliseconds into launch and after `registerIpc` has returned.
 * A window that mounts inside that gap gets "no handler registered" from an
 * invoke that would have worked one tick later, and would then sit for the rest
 * of the session as a window that cannot approve anything — silently, because
 * the symptom is a dialog that never appears. So it retries a few times and
 * then stops, rather than either giving up instantly or hammering a channel
 * that genuinely is not there in this build.
 *
 * The push subscriptions are set up first and unconditionally, because
 * `ipcRenderer.on` needs no handler on the far side: a request that arrives
 * during the retry window is caught by the listener, and anything older comes
 * back in the attach's own return value.
 */

import { useCallback, useEffect, useRef, useState } from 'react'
import {
  nextQuestion,
  readConsentRequest,
  readConsentSettled,
  settledSentence,
  type ConsentRequestView,
} from './consent-model'

export interface ConsentBridge {
  attachConsent(): Promise<unknown>
  answerConsent(id: string, approved: boolean): Promise<unknown>
  deckControlStatus(): Promise<unknown>
  onCopilotConsentRequest(cb: (request: unknown) => void): () => void
  onCopilotConsentSettled(cb: (settled: unknown) => void): () => void
}

export interface Consent {
  /** The question in front of the person — the oldest outstanding one. */
  question: ConsentRequestView | null
  /** How many are waiting behind it. Zero on the ordinary single question. */
  waiting: number
  /** Why the last question closed without this window answering it, or null. */
  notice: string | null
  /**
   * Tool id → the title the catalogue gives it, for the dialog's heading.
   *
   * Read once, at attach, rather than per question: the catalogue is fixed for
   * the life of the process, and a dialog that had to make a round trip before
   * it could name what it was asking about would spend the first frames of a
   * two-minute deadline looking blank.
   */
  titles: Readonly<Record<string, string>>
  answer(id: string, approved: boolean): void
  dismissNotice(): void
}

/** How many times, and how far apart, the attach is retried. See the header. */
const ATTACH_TRIES = 6
const ATTACH_DELAY_MS = 250

function bridge(): ConsentBridge | null {
  const deck = (globalThis as { deck?: Partial<ConsentBridge> }).deck
  if (!deck || typeof deck.attachConsent !== 'function') return null
  return deck as ConsentBridge
}

export function useConsent(injected?: ConsentBridge | null): Consent {
  const [deck] = useState<ConsentBridge | null>(() => injected ?? bridge())
  const [pending, setPending] = useState<readonly ConsentRequestView[]>([])
  const [notice, setNotice] = useState<string | null>(null)
  const [titles, setTitles] = useState<Readonly<Record<string, string>>>({})

  const mounted = useRef(true)
  useEffect(() => {
    mounted.current = true
    return () => {
      mounted.current = false
    }
  }, [])

  const add = useCallback((value: unknown) => {
    const request = readConsentRequest(value)
    // Dropped rather than drawn. A dialog that cannot name the tool it is
    // approving is worse than no dialog: the call is refused by timeout either
    // way, and only one of the two options asks somebody to say yes to
    // something unnamed.
    if (!request || !mounted.current) return
    setPending((current) =>
      current.some((entry) => entry.id === request.id) ? current : [...current, request],
    )
  }, [])

  const drop = useCallback((id: string) => {
    setPending((current) => current.filter((entry) => entry.id !== id))
  }, [])

  useEffect(() => {
    if (!deck) return
    const offRequest = deck.onCopilotConsentRequest(add)
    const offSettled = deck.onCopilotConsentSettled((value) => {
      const settled = readConsentSettled(value)
      if (!settled || !mounted.current) return
      drop(settled.id)
      // Only for the outcomes a person did not produce here. `settledSentence`
      // returns null for "you just pressed Refuse", because narrating the button
      // somebody has this instant pressed is noise.
      const sentence = settledSentence(settled)
      if (sentence) setNotice(sentence)
    })
    return () => {
      offRequest()
      offSettled()
    }
  }, [deck, add, drop])

  useEffect(() => {
    if (!deck) return
    let live = true
    let attempt = 0
    let timer: ReturnType<typeof setTimeout> | null = null

    const attach = (): void => {
      void deck
        .attachConsent()
        .then((value) => {
          if (!live) return
          // Whatever was already outstanding when this window arrived. Without
          // folding these in, a question raised before the page finished loading
          // would sit in the main process until it timed out with nothing on
          // screen — the copilot blocked, and the person never asked.
          if (Array.isArray(value)) for (const entry of value) add(entry)
        })
        .catch(() => {
          if (!live) return
          attempt += 1
          if (attempt >= ATTACH_TRIES) return
          timer = setTimeout(attach, ATTACH_DELAY_MS)
        })
    }

    attach()
    return () => {
      live = false
      if (timer) clearTimeout(timer)
    }
  }, [deck, add])

  /*
   * The tool titles, so a dialog can head itself "Change a setting" rather than
   * `settings.write`.
   *
   * A failure here is silent and harmless by design: `toolHeading` falls back to
   * the dotted tool id, which is a poor heading and never a wrong one. The one
   * thing a confirmation dialog may not do is name the wrong tool.
   */
  useEffect(() => {
    if (!deck) return
    let live = true
    void deck
      .deckControlStatus()
      .then((value) => {
        if (!live || typeof value !== 'object' || value === null) return
        const tools = (value as { tools?: unknown }).tools
        if (!Array.isArray(tools)) return
        const map: Record<string, string> = {}
        for (const entry of tools) {
          if (typeof entry !== 'object' || entry === null) continue
          const tool = entry as { id?: unknown; title?: unknown }
          if (typeof tool.id === 'string' && typeof tool.title === 'string') {
            map[tool.id] = tool.title
          }
        }
        setTitles(map)
      })
      .catch(() => {})
    return () => {
      live = false
    }
  }, [deck])

  const answer = useCallback(
    (id: string, approved: boolean) => {
      // Removed here rather than on the settled push, so the dialog closes on
      // the press instead of on the round trip. The push still arrives and is a
      // no-op by then, which is the right order: the person's answer is the
      // event, and the confirmation of it is not something they should wait for.
      drop(id)
      if (!deck) return
      void deck.answerConsent(id, approved).catch(() => {
        // The answer did not land — a window that lost its approver status, a
        // question that had already expired. The far side defaults to refusal
        // in both cases, which is the outcome this dialog promises, so there is
        // nothing to undo and nothing to claim.
      })
    },
    [deck, drop],
  )

  return {
    question: nextQuestion(pending),
    waiting: Math.max(0, pending.length - 1),
    notice,
    titles,
    answer,
    dismissNotice: useCallback(() => setNotice(null), []),
  }
}
