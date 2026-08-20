import { useCallback, useEffect, useState } from 'react'
import { AnchoredPopup } from './AnchoredPopup'
import {
  loginLabel,
  passwordsAvailable,
  readLoginList,
  readProfileState,
  type AccountsApi,
  type ProfileState,
  type SavedLoginSummary,
} from './accounts-bridge'
import type { Box } from './popup-anchor'

interface Props {
  api: AccountsApi
  anchor: Box
  /**
   * How many sites have data in the **active** profile's partition.
   *
   * Passed in rather than reached for, because the cookie jar belongs to the
   * browser bridge and not to the accounts one, and only the active profile's
   * session can be read at all — `browser-session.ts` resolves `guestSession()`
   * to whichever partition is on. So this is one number about one profile, and
   * the menu is careful to print it only against that profile's row.
   */
  countSites?: () => Promise<number>
  /** Open the cookies-and-site-data dialog. */
  onSiteData(): void
  /** Reopen this page in the profile that was just switched to. */
  onReopen(): void
  onClose(): void
}

/**
 * Who you are while you browse — the menu behind the toolbar's profile icon.
 *
 * ## Why this exists rather than the profile rows being deleted
 *
 * He put the choice plainly:
 *
 *   > *"if I click on profile, there is nothing inside the profile, just the
 *   > name, not like Chrome. So if we don't have those features, then even
 *   > profile doesn't make any sense if there is nothing that we can see in each
 *   > profile."*
 *
 * The fork is real and it resolves on one question: is a profile here a real
 * thing, or a label? It is a real thing. `browser-profiles.ts` gives each one a
 * `persist:` **session partition** — Chromium's own mechanism, reached through
 * Electron — which is a separate cookie jar, `localStorage`, IndexedDB, cache,
 * service workers and per-origin zoom, on disk, surviving restart. Two profiles
 * can be signed into the same site as two different people at the same time.
 * That is not an approximation of the Chrome feature; it is the same mechanism.
 *
 * What was missing was not the feature. It was any way to *see* it: the menu
 * printed a name and a tick, so a profile looked like a label, and a label with
 * nothing behind it is exactly the half-feature this whole review is about.
 *
 * So the rows carry what a profile actually holds, and both numbers are read
 * from the real stores rather than composed:
 *
 *  - **logins**, per profile — `browser-password:list` filters the store by
 *    `profileId`, so this is answerable for *every* profile, not only the active
 *    one.
 *  - **sites**, for the active profile — the cookie jar can only be enumerated
 *    for the session that is on, so this number appears on one row and would be
 *    a guess on any other. A guess is what would have made this menu a lie.
 *
 * ## Why switching offers to reopen instead of just doing it
 *
 * A `WebContents`' session is fixed when it is constructed and cannot be swapped
 * afterwards — the physics the Isolated toggle already lives under. So switching
 * decides what the *next* page opens into. The old menu said that in a sentence;
 * *"I don't want any kind of long descriptions anywhere"*, so it is a button
 * now. A button that appears exactly when the situation arises is the sentence,
 * and it is also the fix.
 */
export function ProfileMenu({ api, anchor, countSites, onSiteData, onReopen, onClose }: Props) {
  const [view, setView] = useState<'profiles' | 'logins'>('profiles')
  const [profiles, setProfiles] = useState<ProfileState | null>(null)
  /** Saved logins per profile id, so every row can carry its own count. */
  const [counts, setCounts] = useState<Record<string, number>>({})
  const [sites, setSites] = useState<number | null>(null)
  const [logins, setLogins] = useState<SavedLoginSummary[]>([])
  const [canStore, setCanStore] = useState(true)
  const [naming, setNaming] = useState(false)
  const [draft, setDraft] = useState('')
  const [note, setNote] = useState('')
  const [switched, setSwitched] = useState(false)

  const hasPasswords = passwordsAvailable(api)

  const loadProfiles = useCallback(async () => {
    if (!api.browserProfiles) return null
    const next = readProfileState(await api.browserProfiles())
    setProfiles(next)
    return next
  }, [api])

  /*
   * One count per profile, gathered together.
   *
   * `Promise.all` over what is at most a handful of profiles, rather than a
   * request per row inside the list: a row that fetches on mount is a menu that
   * grows its numbers one at a time while somebody is reading it, and the shift
   * is more distracting than the wait.
   */
  const loadCounts = useCallback(
    async (state: ProfileState | null) => {
      if (!api.browserPasswords || !state) return
      const read = api.browserPasswords
      const pairs = await Promise.all(
        state.profiles.map(async (profile) => {
          const list = readLoginList(await read(profile.id))
          return [profile.id, list.length] as const
        }),
      )
      setCounts(Object.fromEntries(pairs))
    },
    [api],
  )

  useEffect(() => {
    void (async () => {
      const state = await loadProfiles()
      await loadCounts(state)
    })()
    if (api.browserPasswordsAvailable) {
      void api.browserPasswordsAvailable().then((value) => setCanStore(value === true))
    }
    if (countSites) void countSites().then(setSites)
  }, [api, loadProfiles, loadCounts, countSites])

  const activeId = profiles?.activeId ?? ''

  const activate = async (id: string): Promise<void> => {
    if (!api.browserProfileActivate || id === activeId) return
    setProfiles(readProfileState(await api.browserProfileActivate(id)))
    // The site count belonged to the profile that was on a moment ago, and the
    // new one's jar cannot be read until a page in it exists. Clearing it is the
    // honest state; leaving the old number under a new name is not.
    setSites(null)
    setSwitched(true)
  }

  const create = async (): Promise<void> => {
    if (!api.browserProfileCreate) return
    const next = readProfileState(await api.browserProfileCreate(draft))
    setProfiles(next)
    await loadCounts(next)
    setDraft('')
    setNaming(false)
  }

  const remove = async (id: string): Promise<void> => {
    if (!api.browserProfileDelete) return
    const next = readProfileState(await api.browserProfileDelete(id))
    setProfiles(next)
    await loadCounts(next)
  }

  const openLogins = async (): Promise<void> => {
    if (!api.browserPasswords || activeId === '') return
    setLogins(readLoginList(await api.browserPasswords(activeId)))
    setView('logins')
  }

  const forget = async (entry: SavedLoginSummary): Promise<void> => {
    if (!api.browserPasswordForget || !api.browserPasswords) return
    await api.browserPasswordForget(entry.profileId, entry.origin, entry.username)
    const list = readLoginList(await api.browserPasswords(activeId))
    setLogins(list)
    setCounts((prev) => ({ ...prev, [activeId]: list.length }))
  }

  const copy = async (entry: SavedLoginSummary): Promise<void> => {
    if (!api.browserPasswordCopy) return
    const done = await api.browserPasswordCopy(entry.profileId, entry.origin, entry.username)
    setNote(done === true ? 'Copied' : 'No longer stored')
  }

  if (view === 'logins') {
    return (
      <AnchoredPopup anchor={anchor} label="Saved logins" onClose={onClose}>
        <div className="bw-menu">
          <div className="bw-menu-head">
            <button type="button" className="bw-text-button" onClick={() => setView('profiles')}>
              ‹ Back
            </button>
            <span className="bw-menu-title">Saved logins</span>
          </div>

          {!canStore && <p className="bw-menu-note">No secure store on this machine.</p>}

          {logins.length === 0 ? (
            <p className="bw-menu-note">Nothing saved.</p>
          ) : (
            <ul className="bw-menu-list">
              {logins.map((entry) => (
                <li key={`${entry.origin}|${entry.username}`} className="bw-menu-row">
                  <span className="bw-menu-label">{loginLabel(entry)}</span>
                  <span className="bw-spacer" />
                  {/* Copy and not Reveal. The password is put on the clipboard
                      by the main process and never crosses into this tree — see
                      `browser-passwords.ts`. Showing it would mean sending it
                      here, which is the one line that undoes the whole design. */}
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
        </div>
      </AnchoredPopup>
    )
  }

  return (
    <AnchoredPopup anchor={anchor} label="Profiles" onClose={onClose}>
      <div className="bw-menu">
        <p className="bw-menu-title">Profile</p>

        <ul className="bw-menu-list">
          {(profiles?.profiles ?? []).map((profile) => {
            const on = profile.id === profiles?.activeId
            /*
             * The two facts a profile row can honestly carry.
             *
             * Joined with a middot rather than stacked, because the row is a
             * click target first: a two-line row in a menu of one-line rows is
             * a target that moves under the pointer as the numbers arrive.
             */
            const facts: string[] = []
            if (on && sites !== null) facts.push(`${sites} ${sites === 1 ? 'site' : 'sites'}`)
            const saved = counts[profile.id]
            if (saved !== undefined && saved > 0) facts.push(`${saved} saved`)

            return (
              <li key={profile.id} className="bw-menu-row">
                <button
                  type="button"
                  className="bw-menu-choice"
                  aria-pressed={on}
                  data-on={on || undefined}
                  onClick={() => void activate(profile.id)}
                >
                  <span className="bw-menu-tick" aria-hidden="true">
                    {on ? '✓' : ''}
                  </span>
                  {profile.name}
                  {/* `bw-menu-count` is the sheet's existing grammar for "a
                      small word at the end of a row, saying a different thing" —
                      the machine picker prints its port count with it. */}
                  {facts.length > 0 && <span className="bw-menu-count">{facts.join(' · ')}</span>}
                </button>
                {!profile.isDefault && (
                  <button
                    type="button"
                    className="bw-text-button"
                    title="Delete this profile and everything signed in inside it"
                    onClick={() => void remove(profile.id)}
                  >
                    Delete
                  </button>
                )}
              </li>
            )
          })}
        </ul>

        {naming ? (
          <div className="bw-menu-row">
            <input
              className="bw-menu-input"
              autoFocus
              value={draft}
              placeholder="Name it"
              aria-label="Name for the new profile"
              onChange={(event) => setDraft(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === 'Enter') void create()
                if (event.key === 'Escape') {
                  event.stopPropagation()
                  setNaming(false)
                }
              }}
            />
            <button type="button" className="bw-primary" onClick={() => void create()}>
              Add
            </button>
          </div>
        ) : (
          <button type="button" className="bw-menu-item" onClick={() => setNaming(true)}>
            New profile…
          </button>
        )}

        {/* The consequence of a switch, as the one action that resolves it. A
            page already open belongs to the session it was constructed with and
            cannot be moved; this reopens it in the profile now chosen. */}
        {switched && (
          <button
            type="button"
            className="bw-menu-item"
            onClick={() => {
              onReopen()
              onClose()
            }}
          >
            Reopen this page
          </button>
        )}

        <p className="bw-menu-title">In this profile</p>

        <button
          type="button"
          className="bw-menu-item"
          onClick={() => {
            onSiteData()
            onClose()
          }}
        >
          Cookies and site data
        </button>

        {/* No count on this row: the active profile's row above already carries
            it, and one fact printed twice in one menu is the thing he objected
            to by name — *"It doesn't make any sense to keep in both side the
            same thing."* */}
        {hasPasswords && (
          <button type="button" className="bw-menu-item" onClick={() => void openLogins()}>
            Saved logins
          </button>
        )}
      </div>
    </AnchoredPopup>
  )
}
