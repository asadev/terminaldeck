import { useCallback, useEffect, useState } from 'react'
import { AnchoredPopup } from './AnchoredPopup'
import {
  loginLabel,
  passwordsAvailable,
  profilesAvailable,
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
  /** The page the menu is about. Empty when nothing is open. */
  url: string
  /** Settings → Browser → Start page, so the row can say which state it is in. */
  startUrl: string
  /** Absent when the panel has no way to write the setting — the row goes then. */
  onStartUrl?: (url: string) => void
  onCookies(): void
  /** Reopen the recorded flow. Absent when nothing has been recorded. */
  onFlow?: () => void
  /** Reopen this page in the profile that was just switched to. */
  onReopen(): void
  onClose(): void
}

/**
 * Everything the browser needs that is not a button on the toolbar — in the top
 * right corner, which is where he asked for it.
 *
 * ## Why this component exists at all
 *
 * From the recorded review of 2026-08-17, of the in-app browser, and it is the
 * whole brief for this file:
 *
 *   > *"Remove everything from the bottom. I need a clear view of the websites.
 *   > Whatever is required should be on the top right corner."*
 *
 * The bottom band held four things: a heading, the recorded flow, the draw
 * controls and "Set as start page". The flow is now a popup from the toolbar,
 * the draw controls are a strip under it — draw mode has no website on screen
 * to keep clear — and the two remaining answers to "what is this browser doing"
 * are here, alongside the two features he asked for by name.
 *
 * ## Why profiles and logins are one menu and not two
 *
 * They are the same question asked twice. *"Which of me is this?"* decides both
 * which cookies are in play and which passwords may be offered, and the second
 * list is scoped by the first — the logins shown are the active profile's, and
 * switching profile changes them. Two separate menus would have made a person
 * hold that relationship in their head; one menu with the profile at the top of
 * it shows the relationship instead.
 *
 * ## Why it takes over rather than nesting
 *
 * The saved-logins list can be long and a submenu inside a popup that is itself
 * placed against a moving anchor is a rectangle nobody can predict. So the popup
 * has two states and a way back. The audience for this app is *"mostly
 * non-technical vibe coders"*; a back arrow is a thing everybody has used.
 */
export function BrowserMenu({
  api,
  anchor,
  url,
  startUrl,
  onStartUrl,
  onCookies,
  onFlow,
  onReopen,
  onClose,
}: Props) {
  const [view, setView] = useState<'menu' | 'logins'>('menu')
  const [profiles, setProfiles] = useState<ProfileState | null>(null)
  const [logins, setLogins] = useState<SavedLoginSummary[]>([])
  const [canStore, setCanStore] = useState(true)
  const [naming, setNaming] = useState(false)
  const [draft, setDraft] = useState('')
  const [note, setNote] = useState('')
  const [switched, setSwitched] = useState(false)

  const hasProfiles = profilesAvailable(api)
  const hasPasswords = passwordsAvailable(api)

  const loadProfiles = useCallback(async () => {
    if (!api.browserProfiles) return
    setProfiles(readProfileState(await api.browserProfiles()))
  }, [api])

  const loadLogins = useCallback(
    async (profileId: string) => {
      if (!api.browserPasswords) return
      setLogins(readLoginList(await api.browserPasswords(profileId)))
    },
    [api],
  )

  useEffect(() => {
    void loadProfiles()
    if (api.browserPasswordsAvailable) {
      void api.browserPasswordsAvailable().then((value) => setCanStore(value === true))
    }
  }, [api, loadProfiles])

  const activeId = profiles?.activeId ?? ''

  useEffect(() => {
    if (activeId !== '') void loadLogins(activeId)
  }, [activeId, loadLogins])

  const isStartPage = url !== '' && url === startUrl

  const activate = async (id: string): Promise<void> => {
    if (!api.browserProfileActivate || id === activeId) return
    setProfiles(readProfileState(await api.browserProfileActivate(id)))
    // A `WebContents`' session is fixed when it is constructed, so switching
    // cannot move the page that is already open — the same physics the Isolated
    // toggle lives under. Saying so, and offering the one action that resolves
    // it, is the difference between a control that looks broken and one that is
    // simply honest about what it did.
    setSwitched(true)
  }

  const create = async (): Promise<void> => {
    if (!api.browserProfileCreate) return
    const next = readProfileState(await api.browserProfileCreate(draft))
    setProfiles(next)
    setDraft('')
    setNaming(false)
  }

  const remove = async (id: string): Promise<void> => {
    if (!api.browserProfileDelete) return
    setProfiles(readProfileState(await api.browserProfileDelete(id)))
  }

  const forget = async (entry: SavedLoginSummary): Promise<void> => {
    if (!api.browserPasswordForget) return
    await api.browserPasswordForget(entry.profileId, entry.origin, entry.username)
    await loadLogins(activeId)
  }

  const copy = async (entry: SavedLoginSummary): Promise<void> => {
    if (!api.browserPasswordCopy) return
    const done = await api.browserPasswordCopy(entry.profileId, entry.origin, entry.username)
    setNote(done === true ? 'Copied to the clipboard.' : 'That login is no longer stored.')
  }

  return (
    <AnchoredPopup anchor={anchor} label="Browser settings" onClose={onClose}>
      {view === 'logins' ? (
        <div className="bw-menu">
          <div className="bw-menu-head">
            <button type="button" className="bw-text-button" onClick={() => setView('menu')}>
              ‹ Back
            </button>
            <span className="bw-menu-title">Saved logins</span>
          </div>

          {!canStore && (
            <p className="bw-menu-note">
              This machine has no secure store available, so logins cannot be saved here.
            </p>
          )}

          {logins.length === 0 ? (
            <p className="bw-menu-note">
              Nothing saved yet. Sign in to a site and this will offer to remember it.
            </p>
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
      ) : (
        <div className="bw-menu">
          {hasProfiles && profiles && (
            <>
              <p className="bw-menu-title">Profile</p>
              <ul className="bw-menu-list">
                {profiles.profiles.map((profile) => (
                  <li key={profile.id} className="bw-menu-row">
                    <button
                      type="button"
                      className="bw-menu-choice"
                      aria-pressed={profile.id === profiles.activeId}
                      data-on={profile.id === profiles.activeId || undefined}
                      onClick={() => void activate(profile.id)}
                    >
                      <span className="bw-menu-tick" aria-hidden="true">
                        {profile.id === profiles.activeId ? '✓' : ''}
                      </span>
                      {profile.name}
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
                ))}
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

              {switched && (
                <p className="bw-menu-note">
                  Pages opened from now on use this profile.{' '}
                  <button
                    type="button"
                    className="bw-text-button"
                    onClick={() => {
                      onReopen()
                      onClose()
                    }}
                  >
                    Reopen this page
                  </button>
                </p>
              )}
            </>
          )}

          <p className="bw-menu-title">This page</p>

          {/* Disabled with a reason rather than hidden. There is always a page
              or there is not, and a row that disappears when nothing is open
              reads as the menu changing shape at random. */}
          {onStartUrl && (
            <button
              type="button"
              className="bw-menu-item"
              disabled={url === '' || isStartPage}
              title={
                url === ''
                  ? 'Open a page first.'
                  : isStartPage
                    ? 'This is already the page every new tab opens on.'
                    : 'Every new tab will open on this page.'
              }
              onClick={() => {
                onStartUrl(url)
                onClose()
              }}
            >
              {isStartPage ? 'This is your start page' : 'Set as start page'}
            </button>
          )}

          <button
            type="button"
            className="bw-menu-item"
            disabled={url === '' || !api.browserSignInHandover}
            title="Open this address in the browser you already use."
            onClick={() => {
              void api.browserSignInHandover?.(url)
              onClose()
            }}
          >
            Open in your browser
          </button>

          <button
            type="button"
            className="bw-menu-item"
            onClick={() => {
              onCookies()
              onClose()
            }}
          >
            Cookies and site data
          </button>

          {hasPasswords && (
            <button type="button" className="bw-menu-item" onClick={() => setView('logins')}>
              Saved logins{logins.length > 0 ? ` (${logins.length})` : ''}
            </button>
          )}

          {onFlow && (
            <button
              type="button"
              className="bw-menu-item"
              onClick={() => {
                onFlow()
                onClose()
              }}
            >
              Recorded flow
            </button>
          )}
        </div>
      )}
    </AnchoredPopup>
  )
}
