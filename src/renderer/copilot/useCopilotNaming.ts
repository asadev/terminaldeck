import { useEffect, useState } from 'react'
import { readCopilotState } from './copilot-model'
import { useCopilotSetup } from './useCopilotSetup'

/**
 * What the copilot is called, and which folder identifies its session — for
 * screens outside the copilot that have to name it the same way the rail does.
 *
 * ## The defect this exists for
 *
 * Asad, 2026-08-20, on the browser's send-to-session picker:
 *
 *   > *"Let's say copilot session one — and it should call commander also,
 *   > because I name it as commander, but it is showing copilot."*
 *
 * The copilot's name is the one session name in this app that is **not** a
 * session property. Every other session is titled from its folder and then
 * renamed in place; the copilot is titled from its folder too — its folder
 * happens to be called `copilot` — and its real name lives in its instruction
 * file, read by `useCopilotSetup`, and is stitched on at the one place that
 * draws its tab (`App.tsx`, where `label` is overwritten with
 * `copilotSetup.name`).
 *
 * Every other surface therefore gets the folder. That was invisible while the
 * copilot only ever appeared in the rail and the strip, and stopped being
 * invisible the moment a second list started including it.
 *
 * ## Why the session id, and why the folder was the wrong handle
 *
 * This answered `root` — the copilot's working directory — for one day, on the
 * argument that a folder is fixed for the life of the install while a session id
 * is minted afresh by every start and restart. The argument was true about the
 * *handle* and wrong about the *question*, because a folder does not name one
 * session. It names everything anybody starts in it. Asad, 2026-08-21, having
 * started a session of his own in the folder his copilot runs in and renamed it
 * in the rail:
 *
 *   > *"Why all of them calls commander now? I mean, why do we have two
 *   > commander sessions and none of this is calling template? **This Mac
 *   > session, the one I just called.** See, this is also a problem."*
 *
 * There were not two copilots. There was one, plus his own session wearing its
 * name, because the caller matched on `cwd` and the copilot's folder was the
 * folder he had picked in the New session dialog — and the folder match ran
 * *after* the line that stores the title he typed, so it overwrote his own name
 * with the copilot's.
 *
 * A name belongs to a session, so it is keyed on the session. The staleness the
 * old note worried about is real and is answered rather than avoided: this
 * re-reads on `session:created` and `session:exit`, and a copilot restart is
 * exactly those two events. Between the exit and the next answer the copilot row
 * is briefly called what its folder calls it, which is a worse label for a
 * moment and never somebody else's.
 *
 * ## What a caller does with this
 *
 * Finds the row whose **id** is {@link sessionId} and calls it {@link name}.
 * Null means the question could not be answered — no copilot channels in this
 * build, the copilot is not running, or the read failed — and the honest thing
 * then is to leave every row named however it was, rather than guessing which
 * one is the copilot.
 */
export interface CopilotNaming {
  /** The copilot's own session, or null when there is no answer to that. */
  sessionId: string | null
  /** What it is called. Falls back to this app's word for an unnamed copilot. */
  name: string
}

interface StateBridge {
  copilotState(): Promise<unknown>
  onSessionCreated?(callback: (meta: unknown) => void): () => void
  onSessionExit?(callback: (id: string, exitCode: number) => void): () => void
}

function bridge(): StateBridge | null {
  const deck = (globalThis as { deck?: Partial<StateBridge> }).deck
  return deck && typeof deck.copilotState === 'function' ? (deck as StateBridge) : null
}

export function useCopilotNaming(): CopilotNaming {
  const setup = useCopilotSetup()
  const [sessionId, setSessionId] = useState<string | null>(null)

  useEffect(() => {
    const deck = bridge()
    if (!deck) return
    let live = true
    const read = (): void => {
      void deck
        .copilotState()
        .then((value) => {
          if (live) setSessionId(readCopilotState(value)?.sessionId ?? null)
        })
        .catch(() => {
          // No copilot channels, or the read threw. The caller names nothing
          // specially, which leaves its rows exactly as they were — a worse
          // label than the right one, and a far better outcome than pinning the
          // copilot's name onto whichever session happened to answer.
        })
    }
    read()
    /*
     * The two events a restart is made of.
     *
     * There is no `copilot:changed` broadcast and this does not invent one —
     * `useCopilot.ts` gives the reason at length — but the copilot is a pty like
     * any other, so its process ending and the replacement starting both arrive
     * on the ordinary session channels. Re-reading on them is what keeps a
     * *session id* usable as the handle: without it, one press of Restart would
     * leave this pointing at a session that no longer exists and the copilot's
     * row would fall back to its folder's name.
     *
     * Both optional, because a preload older than either must still name the
     * copilot correctly at mount rather than render nothing at all.
     */
    const offCreated = deck.onSessionCreated?.(() => read())
    const offExit = deck.onSessionExit?.(() => read())
    return () => {
      live = false
      offCreated?.()
      offExit?.()
    }
  }, [])

  return { sessionId, name: setup.name }
}
