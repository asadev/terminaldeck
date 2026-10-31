/**
 * "Run it as my work account" — an account named by a model, matched to one that exists.
 *
 * Two tools take an account: `sessions.start` (which login a new session runs
 * as) and `sessions.account` (which login a running one switches to). Both have
 * to answer the same question the same way, so it is answered once, here.
 *
 * ## Why a name is accepted, and not only an id
 *
 * A model in another app hears *"use my work account"*. The id is an opaque
 * string it has never been shown, and the only place it could learn one is a
 * listing it would have to know to ask for. So a name is matched too,
 * case-insensitively — and two accounts sharing a name are refused rather than
 * guessed between, because guessing is exactly the silent substitution the
 * start path already does for an unknown id (`resolveProfileId` falls back to
 * the default), which is the reason this check exists at all.
 *
 * Returns a sentence rather than throwing, because the two callers throw their
 * own argument errors and this module has no business importing either.
 */

import type { ProviderId } from '../../shared/types'

export interface AccountOption {
  id: string
  name: string
  provider: ProviderId
}

export type AccountChoice = { ok: true; account: AccountOption } | { ok: false; message: string }

export function chooseAccountFrom(
  accounts: readonly AccountOption[],
  wanted: string,
  provider: string | null,
): AccountChoice {
  const exact = accounts.filter((account) => account.id === wanted)
  const folded = wanted.trim().toLowerCase()
  const byName = accounts.filter((account) => account.name.trim().toLowerCase() === folded)
  const found = exact.length === 1 ? exact : byName
  const names = accounts.map((account) => `${account.name} (${account.provider})`).join(', ')
  if (found.length === 0) {
    return { ok: false, message: `there is no account called "${wanted}". The accounts are: ${names || 'none'}.` }
  }
  if (found.length > 1) {
    return {
      ok: false,
      message: `more than one account is called "${wanted}"; name it by id instead. The accounts are: ${names}.`,
    }
  }
  const account = found[0]
  if (provider !== null && provider !== account.provider) {
    return { ok: false, message: `${account.name} is a ${account.provider} login, so it cannot run a ${provider} session` }
  }
  return { ok: true, account }
}
