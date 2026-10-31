import type { AccountsApi } from './accounts-bridge'

interface Props {
  origin: string
  username: string
  api: AccountsApi
  onAnswered(message: string): void
}

/**
 * "Save this login?" — the moment a password manager is actually a password
 * manager.
 *
 * ## What is on screen, and what is not
 *
 * The site and the username, and nothing else. **The password is not here** and
 * cannot be: it is held in the main process in a single pending slot, and this
 * component's only power over it is to say yes or no. That is not caution for
 * its own sake — a password rendered here would be in a React tree, in devtools
 * and in any future crash report, which is the rule `browser-session.ts` already
 * applies to cookie values and which a password deserves at least as much.
 *
 * ## Why there is no "never for this site"
 *
 * Because it would have to be honoured, and honouring it means a second store,
 * on disk, of sites somebody once declined — which is a list of where they have
 * accounts, kept forever, to save one dismissal. The prompt only appears when
 * the credentials are genuinely new (see `isNewLogin`), so declining and
 * carrying on does not produce it again for the same password. That covers the
 * case the option exists for, without keeping the list.
 */
export function PasswordOffer({ origin, username, api, onAnswered }: Props) {
  const site = origin.replace(/^https:\/\//, '')

  const answer = async (keep: boolean): Promise<void> => {
    const outcome = await api.browserPasswordAnswer?.(keep)
    const message =
      typeof outcome === 'object' && outcome !== null
        ? String((outcome as Record<string, unknown>).message ?? '')
        : ''
    // The main process's own sentence, because the interesting failure is the
    // one it alone knows about: a machine with no secure store refuses to save
    // rather than writing a password to a plain file, and saying "Saved" there
    // would be the worst lie in this feature.
    onAnswered(keep ? message : '')
  }

  return (
    <div className="bw-offer" role="status">
      <div className="bw-signin-text">
        <strong>Save this login?</strong>
        <span>
          {username === '' ? site : `${username} at ${site}`}. It is encrypted on this machine and
          filled in for you next time.
        </span>
      </div>
      <span className="bw-spacer" />
      <button type="button" className="bw-primary" onClick={() => void answer(true)}>
        Save
      </button>
      <button type="button" className="bw-text-button" onClick={() => void answer(false)}>
        Not now
      </button>
    </div>
  )
}
