import { useCallback, useEffect, useState } from 'react'
import { AnchoredPopup } from './AnchoredPopup'
import {
  loginLabel,
  readLoginList,
  readProfileState,
  type AccountsApi,
  type ProfileState,
  type SavedLoginSummary,
} from './accounts-bridge'
import type { Box } from './popup-anchor'
import { profileInitial } from './profile-badge'

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
 * And the login count is a door, not a caption. Pressing `2 saved` on a row
 * opens *that* profile's logins — a profile you are not in, without switching
 * into it — which is the plainest answer this menu can give to *"there is
 * nothing that we can see in each profile"*. It is also why the standing
 * `Saved logins` row at the foot of the menu is gone: it opened the active
 * profile's list, which is the list its own row now opens, and one thing
 * reachable two ways from one menu is *"the same thing in both side"*.
 *
 * A row with no count has nothing saved in it, and an empty list is not a screen
 * worth a control. **No count is ever printed as a zero.** `0 sites` was on the
 * one row somebody opens this menu to look at, and it is the exact shape of the
 * thing he keeps striking out: a number that exists to stop a row looking empty.
 *
 * ## Why there are no headings over any of it
 *
 *   > *"I said to you, don't put any single statement in anywhere. Everywhere
 *   > you are putting a lot of statements. We don't need to give the
 *   > statements."*
 *
 * There were two — `Profile` over the list, and `In this profile` over a single
 * item. The first named the button that had just been pressed to open the menu.
 * The second was three words above one row. Both went; the popup keeps its
 * accessible name, which is the only reader that ever needed one.
 *
 * ## Why Delete asks first, in red
 *
 * Deleting a profile throws away a whole cookie jar — every login in it, on
 * disk, with no undo — and it was a grey word at the end of a row, one click
 * from gone. He specified this control's behaviour and its colours out loud
 * once, about ending a session, and it is the same control:
 *
 *   > *"It should give the warning also. Warning should be also word using the
 *   > word delete. That warning, when I hover on the delete, it will have the
 *   > white text and red color instead of this blue. And when it's not hover, it
 *   > will have red text only."*
 *
 * So the first press arms rather than destroys, and the armed row is the
 * warning: the profile's own name is already on it, `Delete` turns red, and
 * `Cancel` is beside it. No sentence was needed to say which profile, because
 * the question is asked on the row being asked about.
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
  /** Whose logins the second view is showing — not necessarily the active one. */
  const [loginsFor, setLoginsFor] = useState('')
  const [canStore, setCanStore] = useState(true)
  const [naming, setNaming] = useState(false)
  const [draft, setDraft] = useState('')
  const [note, setNote] = useState('')
  const [switched, setSwitched] = useState(false)
  /** The profile whose Delete has been armed, if any. One at a time. */
  const [arming, setArming] = useState('')

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
    setArming('')
    const next = readProfileState(await api.browserProfileDelete(id))
    setProfiles(next)
    await loadCounts(next)
  }

  /*
   * Any profile's logins, not only the one that is on.
   *
   * `browser-password:list` filters the store by `profileId`, so this was always
   * answerable for every row — the menu simply never asked. Reading another
   * profile's list does not switch into it, which is the point: what is signed
   * in over there is exactly the thing you want to know *before* deciding to go.
   */
  const openLogins = async (profileId: string): Promise<void> => {
    if (!api.browserPasswords || profileId === '') return
    setLoginsFor(profileId)
    setLogins(readLoginList(await api.browserPasswords(profileId)))
    setNote('')
    setView('logins')
  }

  const forget = async (entry: SavedLoginSummary): Promise<void> => {
    if (!api.browserPasswordForget || !api.browserPasswords) return
    await api.browserPasswordForget(entry.profileId, entry.origin, entry.username)
    const list = readLoginList(await api.browserPasswords(loginsFor))
    setLogins(list)
    setCounts((prev) => ({ ...prev, [loginsFor]: list.length }))
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
            {/* Whose list this is, as the badge and not as a sentence. The same
                circle the toolbar and the rows behind this view draw, so "these
                are Work's logins" is one glyph rather than a line of prose. */}
            <span className="bw-avatar" aria-hidden="true">
              {profileInitial(
                (profiles?.profiles ?? []).find((profile) => profile.id === loginsFor)?.name ?? '',
              )}
            </span>
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
        {/* No heading. This menu opens from a button whose hover already says
            the profile's name, and a title repeating the control you just
            pressed is a statement. `AnchoredPopup`'s `label` is the accessible
            name, which is the only place one was ever needed. */}
        <ul className="bw-menu-list bw-menu-gutter">
          {(profiles?.profiles ?? []).map((profile) => {
            const on = profile.id === profiles?.activeId
            const saved = counts[profile.id] ?? 0
            const armed = arming === profile.id

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
                  {/* The same badge the toolbar wears, so the button up there and
                      the row down here are recognisably one profile. */}
                  <span className="bw-avatar" aria-hidden="true">
                    {profileInitial(profile.name)}
                  </span>
                  {profile.name}
                  {/* `bw-menu-count` is the sheet's existing grammar for "a
                      small word at the end of a row, saying a different thing" —
                      the machine picker prints its port count with it. Only the
                      active row: the cookie jar of a profile that is not on
                      cannot be enumerated, and a blank would read as zero.

                      And never `0 sites`. A count that is zero is not a fact
                      about the profile, it is a filler making the row look
                      occupied — which is the thing he keeps deleting. An empty
                      profile is a name, because an empty profile *is* a name. */}
                  {on && sites !== null && sites > 0 && !armed && (
                    <span className="bw-menu-count">
                      {sites} {sites === 1 ? 'site' : 'sites'}
                    </span>
                  )}
                </button>
                {/* The count is the door. Pressing it reads that profile's
                    logins without switching into it — see `openLogins`. Hidden
                    while the row is asking to be deleted: a row cannot offer to
                    open something and ask a question at the same time. */}
                {saved > 0 && !armed && (
                  <button
                    type="button"
                    className="bw-text-button"
                    title="Saved logins"
                    onClick={() => void openLogins(profile.id)}
                  >
                    {saved} saved
                  </button>
                )}
                {!profile.isDefault &&
                  (armed ? (
                    <>
                      {/* Red at rest, red *fill* under the pointer, and the same
                          two tokens the session dialog uses — see
                          `CloseSessionConfirm.css` for why the fill carries its
                          own ink rather than borrowing `--text-onaccent`. */}
                      <button
                        type="button"
                        className="bw-menu-danger"
                        aria-label={`Delete ${profile.name}`}
                        onClick={() => void remove(profile.id)}
                      >
                        Delete
                      </button>
                      {/* Focus lands here and not on Delete. The button that
                          armed this row has just been replaced, so focus would
                          otherwise fall to the body and a keyboard user would
                          lose the row entirely; parking it on the safe answer is
                          what every OS confirmation does, and it means Enter
                          cancels. */}
                      <button
                        type="button"
                        className="bw-text-button"
                        autoFocus
                        onClick={() => setArming('')}
                      >
                        Cancel
                      </button>
                    </>
                  ) : (
                    <button
                      type="button"
                      className="bw-text-button"
                      aria-label={`Delete ${profile.name}`}
                      onClick={() => setArming(profile.id)}
                    >
                      Delete
                    </button>
                  ))}
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

        {/* The one thing left that really is about the profile that is *on*: the
            cookie jar can only be enumerated for the active session. Saved
            logins are not here, because every profile's own row opens its own —
            *"It doesn't make any sense to keep in both side the same thing."*

            It had `In this profile` written over it — three words of heading
            above one row, in a menu whose every other row is also about a
            profile. The heading went and the row stayed: it is the action, and
            the `n sites` on the active row above is what it opens. */}
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
      </div>
    </AnchoredPopup>
  )
}
