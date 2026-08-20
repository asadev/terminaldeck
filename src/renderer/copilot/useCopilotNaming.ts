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
 * ## Why the folder rather than the session id
 *
 * `paths.root` is fixed for the life of the install — it is a directory this app
 * made and keeps — whereas the copilot's session id is minted afresh by every
 * start, every restart and every crash-and-respawn. A hook that cached the id
 * would be wrong within one press of Restart, and would have to re-read on every
 * session event to stay right. The folder is read once and stays true, and the
 * caller matches it against whatever session list it is already holding.
 *
 * ## What a caller does with this
 *
 * Finds the row whose `cwd` is {@link root} and calls it {@link name}. Null root
 * means the question could not be answered — no copilot channels in this build,
 * or the read failed — and the honest thing then is to leave the row named
 * however it was, rather than guessing which one is the copilot.
 */
export interface CopilotNaming {
  /** The copilot's working directory, or null when it could not be read. */
  root: string | null
  /** What it is called. Falls back to this app's word for an unnamed copilot. */
  name: string
}

interface StateBridge {
  copilotState(): Promise<unknown>
}

function bridge(): StateBridge | null {
  const deck = (globalThis as { deck?: Partial<StateBridge> }).deck
  return deck && typeof deck.copilotState === 'function' ? (deck as StateBridge) : null
}

export function useCopilotNaming(): CopilotNaming {
  const setup = useCopilotSetup()
  const [root, setRoot] = useState<string | null>(null)

  useEffect(() => {
    const deck = bridge()
    if (!deck) return
    let live = true
    void deck
      .copilotState()
      .then((value) => {
        if (live) setRoot(readCopilotState(value)?.paths?.root ?? null)
      })
      .catch(() => {
        // No copilot channels, or the read threw. The caller names nothing
        // specially, which leaves its rows exactly as they were — a worse label
        // than the right one, and a far better outcome than pinning the
        // copilot's name onto whichever session happened to answer.
      })
    return () => {
      live = false
    }
  }, [])

  return { root, name: setup.name }
}
