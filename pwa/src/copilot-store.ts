/**
 * Where a copilot credential lives in a browser, and why it is a second one.
 *
 * A device that has been paired for terminals holds one credential. A device
 * that has *also* been connected to the copilot holds two, and the second is not
 * derivable from the first — `src/main/remote/copilot-link.ts` mints it in its
 * own ceremony, stores its own scrypt hash of it, and will never show it again.
 * Two secrets, two records, and revoking one does not revoke the other.
 *
 * ## Why its own key rather than a field on the machine
 *
 * The same argument `folder-grants.ts` makes on the desktop for not living in
 * `remote-auth.json`. `machines.ts` has a strict parser that keeps the fields it
 * knows and drops the rest, so a second module writing into the book would have
 * its data erased by the next rename or re-pair — silently, and only for people
 * who had done both. And the split is right anyway: losing the book costs a list
 * of machines, losing this costs a credential and a permission, and one file
 * holding both has the worse of the two as its worst case.
 *
 * ## Why it is keyed by machine
 *
 * Because a copilot connection is to *one* machine, and this client can be
 * paired with several. A single stored string would be sent to whichever machine
 * happened to be current, which is a credential for machine A presented to
 * machine B — refused, and counted against machine B's failed-attempt limiter.
 *
 * ## The same two stores, and the same question
 *
 * `remember.ts` owns the answer to *is this browser yours*, and this follows it
 * exactly: written into whichever store the pairing went into, cleared out of the
 * other. A copilot credential in `localStorage` beside a pairing in
 * `sessionStorage` would be the durable half of something the person said should
 * not outlive the tab — and it is the more powerful half.
 */

import { MAX_COPILOT_CREDENTIAL_CHARS } from './protocol-client'
import { clearAcross, readAcross, writeAcross, type Remember, type StorageLike, type Stores } from './remember'

/** Versioned, like every other stored shape here: a format change is not current. */
export const COPILOT_KEY = 'terminaldeck.copilot.v1'

/**
 * How many machines' copilot credentials one browser keeps.
 *
 * The machine book itself is unbounded and this is not, deliberately: a stale
 * entry there is a row somebody can see and delete, and a stale entry here is a
 * secret nobody can see at all. Eight is far more machines than anyone pairs one
 * browser with, and the oldest entry falling off is the right failure — it costs
 * a connect code, which is one act at a machine.
 */
export const MAX_STORED_COPILOTS = 8

export type CopilotCredentials = Readonly<Record<string, string>>

const NONE: CopilotCredentials = {}

/**
 * Every copilot credential this browser holds, or an empty map.
 *
 * Anything unreadable reads as empty rather than as an error. The consequence is
 * exact and survivable: the Copilot screen offers a Connect field, somebody mints
 * a code at the machine, and it works again. The alternative — refusing to draw
 * the screen — would leave somebody with a client that cannot reach the thing
 * that would fix it.
 */
export function readCopilots(storage: StorageLike): CopilotCredentials | null {
  let stored: string | null = null
  try {
    stored = storage.getItem(COPILOT_KEY)
  } catch {
    // Safari in private mode throws rather than returning null.
    return null
  }
  if (stored === null) return null
  let parsed: unknown
  try {
    parsed = JSON.parse(stored)
  } catch {
    return null
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return null
  const out: Record<string, string> = {}
  for (const [id, value] of Object.entries(parsed as Record<string, unknown>)) {
    // Bounded on the way *in* as well as on the way out. A hand-edited store is
    // the only way an oversized value gets here, and the cost of not checking is
    // a megabyte handed to the desktop's scrypt.
    if (id !== '' && typeof value === 'string' && value !== '' && value.length <= MAX_COPILOT_CREDENTIAL_CHARS) {
      out[id] = value
    }
  }
  return Object.keys(out).length === 0 ? null : out
}

/** The credentials from whichever store holds any. */
export function loadCopilots(stores: Stores): CopilotCredentials {
  return readAcross(stores, readCopilots)?.value ?? NONE
}

/**
 * Add or replace one machine's credential, keeping the rest.
 *
 * Pure, so the trimming rule is checkable: the newest entry is the one just
 * written, so when the map is over {@link MAX_STORED_COPILOTS} the entries that
 * fall off are the ones inserted longest ago. Object key order in JavaScript is
 * insertion order for string keys, which is what makes that true without a
 * timestamp per entry — and a timestamp per entry would be one more thing to
 * get wrong for a map that holds eight strings.
 */
export function withCopilot(held: CopilotCredentials, machineId: string, credential: string): CopilotCredentials {
  const next: Record<string, string> = {}
  for (const [id, value] of Object.entries(held)) if (id !== machineId) next[id] = value
  next[machineId] = credential
  const ids = Object.keys(next)
  if (ids.length <= MAX_STORED_COPILOTS) return next
  const trimmed: Record<string, string> = {}
  for (const id of ids.slice(ids.length - MAX_STORED_COPILOTS)) trimmed[id] = next[id]
  return trimmed
}

/** Drop one machine's credential. Used when a machine is forgotten. */
export function withoutCopilot(held: CopilotCredentials, machineId: string): CopilotCredentials {
  const next: Record<string, string> = {}
  for (const [id, value] of Object.entries(held)) if (id !== machineId) next[id] = value
  return next
}

/** Write where the answer says, and clear the other store. */
export function saveCopilots(stores: Stores, remember: Remember, held: CopilotCredentials): void {
  writeAcross(
    stores,
    remember,
    (storage) => {
      try {
        if (Object.keys(held).length === 0) storage.removeItem(COPILOT_KEY)
        else storage.setItem(COPILOT_KEY, JSON.stringify(held))
      } catch {
        // Out of quota, or private mode. This visit still works — the credential
        // is in memory — and the next launch asks for a connect code.
      }
    },
    clearOne,
  )
}

/** Forget every copilot connection, in both stores. */
export function clearCopilots(stores: Stores): void {
  clearAcross(stores, clearOne)
}

function clearOne(storage: StorageLike): void {
  try {
    storage.removeItem(COPILOT_KEY)
  } catch {
    // Nothing useful to do; the caller is already on its way to the pair screen.
  }
}
