import { useCallback, useEffect, useState } from 'react'
import { Modal } from '../components/Modal'
import {
  historyAvailable,
  loginLabel,
  readLoginList,
  readProfileState,
  type AccountsApi,
  type BrowserProfile,
  type SavedLoginSummary,
} from './accounts-bridge'
import { profileInitial } from './profile-badge'

interface Props {
  open: boolean
  api: AccountsApi
  /**
   * Which profile this section is about — an id, and not the record itself.
   *
   * The record is read here, from the store, every time this opens. Taking one
   * from above would make this section as fresh as whatever the panel last
   * happened to read: press Settings on a profile made a moment ago in the menu
   * and there would be nothing to draw, which is a press that does nothing —
   * the exact defect this whole review is made of.
   */
  profileId: string
  /** Anything that changed the stored list, so the menu behind this can reload. */
  onChanged(): void
  /** Open the cookies-and-site-data dialog for this profile. */
  onSiteData(profileId: string): void
  /** Open this profile's browsing history. Absent when history is not wired. */
  onHistory?: (profileId: string) => void
  onClose(): void
}

/**
 * The characters a profile can be badged with.
 *
 * A short, fixed set rather than a free field or an emoji keyboard: the badge is
 * an 18px circle on the toolbar and 32 at the head of this section, so what goes
 * in it has to be one code point that reads at the smaller of those, and a
 * picker of twelve is a decision somebody makes in a second. The
 * letter — the name's initial, which is what this app has always drawn — is the
 * thirteenth option and the way back out, and it is not in this list because it
 * is not a character, it is the absence of one.
 *
 * Deliberately neutral. Nothing here means anything, which is the point: these
 * are ways to tell two rows apart at a glance, not a taxonomy of profiles.
 */
export const PROFILE_AVATARS = ['🦊', '🐧', '🐳', '🌿', '⚡', '🎧', '🧭', '📚', '🔭', '🌙', '🎯', '🧪']

/**
 * What is *inside* a profile — the section behind its row.
 *
 *   > *"And now profiles doesn't have any kind of settings, I think, so they
 *   > should have proper settings, proper section, just like Google Chrome."*
 *
 * ## Why this is a section rather than more rows in the menu
 *
 * The menu row already carries the two counts and two doors that answered
 * *"there is nothing that we can see in each profile"* — see `ProfileMenu.tsx`.
 * What it cannot carry is anything you have to *do*: renaming needs a field,
 * choosing a badge needs a grid, and a list of saved logins needs room. Chrome
 * puts exactly this behind "Customize Profile", one level down from the flyout,
 * and for the same reason.
 *
 * Everything on it is scoped to the profile named at the top, including the two
 * things it does not draw itself: Sites opens that profile's cookie jar, and
 * History opens that profile's list. Neither is a second copy — they are the
 * same dialogs the menu rows open, called with this profile's id, because *"it
 * doesn't make any sense to keep in both side the same thing"* is about two
 * implementations of one thing far more than it is about two buttons.
 *
 * ## What is not here, and is not pretended to be
 *
 * Chrome's flyout also offers a Google account, sync, and autofill of addresses
 * and cards. This app has none of those and does not draw a row for any of them:
 * a row that opens nothing is the defect the whole review is about. Saved logins
 * are here because they exist — `browser-passwords.ts` is this app's own
 * encrypted store — and they are listed with the same Copy and Forget the menu
 * has always offered, never a Reveal, because the password never crosses into
 * this side of the app at all.
 */
export function ProfileSettings({
  open,
  api,
  profileId,
  onChanged,
  onSiteData,
  onHistory,
  onClose,
}: Props) {
  const [profile, setProfile] = useState<BrowserProfile | null>(null)
  const [draft, setDraft] = useState('')
  const [logins, setLogins] = useState<SavedLoginSummary[]>([])
  const [note, setNote] = useState('')
  const [arming, setArming] = useState(false)

  /** This profile as the store has it, and the field reset to match. */
  const reload = useCallback(async () => {
    if (!api.browserProfiles || profileId === '') return
    const state = readProfileState(await api.browserProfiles())
    const found = state?.profiles.find((entry) => entry.id === profileId) ?? null
    setProfile(found)
    // The name in the field is the stored name each time this loads, so a name
    // typed and abandoned last time is not sitting there waiting to be saved.
    setDraft(found?.name ?? '')
  }, [api, profileId])

  const loadLogins = useCallback(async () => {
    if (!api.browserPasswords || profileId === '') return
    setLogins(readLoginList(await api.browserPasswords(profileId)))
  }, [api, profileId])

  useEffect(() => {
    if (!open) return
    setNote('')
    setArming(false)
    void reload()
    void loadLogins()
  }, [open, reload, loadLogins])

  // Nothing to draw until the store has answered, and nothing at all for an id
  // that is no longer in it — a profile deleted from the menu behind this.
  if (!profile) return null

  const rename = async (): Promise<void> => {
    if (!api.browserProfileRename) return
    const wanted = draft.trim()
    if (wanted === '' || wanted === profile.name) return
    await api.browserProfileRename(profile.id, wanted)
    await reload()
    setNote('Renamed')
    onChanged()
  }

  const setAvatar = async (glyph: string): Promise<void> => {
    if (!api.browserProfileAvatar) return
    await api.browserProfileAvatar(profile.id, glyph)
    await reload()
    onChanged()
  }

  const forget = async (entry: SavedLoginSummary): Promise<void> => {
    if (!api.browserPasswordForget) return
    await api.browserPasswordForget(entry.profileId, entry.origin, entry.username)
    await loadLogins()
  }

  const copy = async (entry: SavedLoginSummary): Promise<void> => {
    if (!api.browserPasswordCopy) return
    const done = await api.browserPasswordCopy(entry.profileId, entry.origin, entry.username)
    setNote(done === true ? 'Copied' : 'No longer stored')
  }

  const remove = async (): Promise<void> => {
    if (!api.browserProfileDelete) return
    setArming(false)
    await api.browserProfileDelete(profile.id)
    onChanged()
    onClose()
  }

  return (
    <Modal open={open} title={profile.name} onClose={onClose} size="lg">
      <div className="bw-profile-head">
        <span className="bw-avatar bw-avatar-lg" aria-hidden="true">
          {profileInitial(profile.name, profile.avatar)}
        </span>
        <input
          className="bw-menu-input"
          value={draft}
          aria-label="Profile name"
          spellCheck={false}
          onChange={(event) => setDraft(event.target.value)}
          onBlur={() => void rename()}
          onKeyDown={(event) => {
            if (event.key === 'Enter') void rename()
          }}
        />
        {/* Present even while the name is unchanged, and disabled then. A button
            that appears when you start typing is a button you have to discover
            twice. */}
        <button
          type="button"
          className="bw-primary"
          disabled={draft.trim() === '' || draft.trim() === profile.name}
          onClick={() => void rename()}
        >
          Rename
        </button>
      </div>

      {/* The avatar picker is drawn only where the preload can store one. A grid
          of characters that does not stick is worse than a badge that is a
          letter. */}
      {api.browserProfileAvatar && (
        <div className="bw-avatar-picker" role="group" aria-label="Badge">
          {PROFILE_AVATARS.map((glyph) => (
            <button
              key={glyph}
              type="button"
              className="bw-avatar-choice"
              aria-label={`Badge ${glyph}`}
              aria-pressed={profile.avatar === glyph}
              data-on={profile.avatar === glyph || undefined}
              onClick={() => void setAvatar(glyph)}
            >
              {glyph}
            </button>
          ))}
          {/* The way back to the badge this app has always drawn. */}
          <button
            type="button"
            className="bw-avatar-choice"
            aria-label="Badge the name’s letter"
            aria-pressed={profile.avatar === ''}
            data-on={profile.avatar === '' || undefined}
            onClick={() => void setAvatar('')}
          >
            {profileInitial(profile.name)}
          </button>
        </div>
      )}

      <div className="bw-profile-doors">
        <button type="button" className="bw-menu-item" onClick={() => onSiteData(profile.id)}>
          Cookies and site data
        </button>
        {/* Absent, not disabled, where history is not wired — a preload that
            cannot answer has nothing to open, and a greyed row here would be a
            promise about a build that does not have the feature. */}
        {onHistory && historyAvailable(api) && (
          <button type="button" className="bw-menu-item" onClick={() => onHistory(profile.id)}>
            History
          </button>
        )}
      </div>

      <h3 className="bw-history-heading">Saved logins</h3>
      {logins.length === 0 ? (
        <p className="bw-muted">Nothing saved.</p>
      ) : (
        <ul className="bw-menu-list">
          {logins.map((entry) => (
            <li key={`${entry.origin}|${entry.username}`} className="bw-menu-row">
              <span className="bw-menu-label">{loginLabel(entry)}</span>
              <span className="bw-spacer" />
              {/* Copy and not Reveal — see `browser-passwords.ts`. The password
                  is put on the clipboard by the main process and never enters
                  this tree. */}
              <button type="button" className="bw-text-button" onClick={() => void copy(entry)}>
                Copy
              </button>
              <button type="button" className="bw-text-button" onClick={() => void forget(entry)}>
                Forget
              </button>
            </li>
          ))}
        </ul>
      )}
      {note !== '' && <p className="bw-menu-note">{note}</p>}

      {/* Deleting throws away a whole cookie jar, every login in it, and now its
          history — on disk, with no undo. Armed first, red, exactly as the row
          in the menu arms: *"It should give the warning also … when I hover on
          the delete, it will have the white text and red color."* */}
      {!profile.isDefault && (
        <div className="bw-profile-danger">
          {arming ? (
            <>
              <button type="button" className="bw-danger" onClick={() => void remove()}>
                Delete {profile.name}
              </button>
              <button
                type="button"
                className="bw-text-button"
                autoFocus
                onClick={() => setArming(false)}
              >
                Cancel
              </button>
            </>
          ) : (
            <button type="button" className="bw-text-button" onClick={() => setArming(true)}>
              Delete this profile
            </button>
          )}
        </div>
      )}
    </Modal>
  )
}
