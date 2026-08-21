import { useCallback, useEffect, useState } from 'react'
import { Modal } from '../components/Modal'
import {
  canAct,
  extensionActionLabel,
  extensionActionVerb,
  reachWords,
  readExtensionResult,
  readExtensionsView,
  type ExtensionsApi,
  type ExtensionsView,
  type StoreExtension,
} from './extensions-bridge'

/**
 * The browser's extension store.
 *
 *   > *"extensions store needs to be a proper store from where we can see most
 *   > famous open source tools to attach to the browser and use there with
 *   > session ai."*
 *
 * ## Why the limits are at the top and not in a footnote
 *
 * The tools store puts its one caveat at the foot, under everything, which is
 * right for a caveat. These are not caveats. *There is no Web Store, nothing
 * updates itself, and most of the famous extensions do not work here* is the
 * first thing somebody needs in order to read the list correctly — a person who
 * reads it after scrolling past uBlock Origin has already formed the wrong idea
 * and this panel put it there. So it is said once, plainly, before the first
 * row, and it is never repeated per row.
 *
 * ## Why a row can say "cannot work here" and still be a row
 *
 * Because the first question anybody opens an extension store with is *where is
 * uBlock Origin*, and there are two different true answers: "this app never
 * heard of it" and "it loads and blocks nothing". Omitting it gives the first
 * answer to a person for whom the second is true, and they will go and install
 * it by hand and get the same nothing with no explanation attached.
 *
 * Those rows have **no button**. Not a disabled one either: a disabled Install
 * with a tooltip is still a store offering something, and this app's rule is that
 * a control which looks like it works and does not is the defect. What they have
 * instead is the sentence describing what was measured.
 *
 * ## Why every row names a profile
 *
 * An extension is loaded into one profile's session and reads every page in it.
 * `browser-extensions.ts` has the whole argument; what it means here is that
 * "installed" is never a global fact, so the panel says which profile it is
 * talking about in a control at the top rather than in prose, and switching it
 * re-reads.
 *
 * ## Why the switch and the Remove are separate controls
 *
 * Off and gone are different things and a person means one of them. Off calls
 * `removeExtension` — the program stops immediately and does not come back at
 * the next launch — and the files stay, with whatever the extension had stored.
 * Remove deletes them. A store with only Remove makes "stop this for an hour"
 * cost everything the extension knows.
 */

interface Props {
  open: boolean
  api: ExtensionsApi
  /** The profile the browser is on, so the panel opens on the right one. */
  profileId: string
  onClose(): void
}

const EMPTY: ExtensionsView = {
  profileId: '',
  profileName: '',
  extensions: [],
  folder: '',
  orphans: [],
  profiles: [],
  limits: [],
}

export function ExtensionsPanel({ open, api, profileId, onClose }: Props) {
  const [view, setView] = useState<ExtensionsView>(EMPTY)
  const [loaded, setLoaded] = useState(false)
  /** Which profile the panel is showing. Starts at the browser's own. */
  const [showing, setShowing] = useState(profileId)
  /** id → the sentence the last action on that row produced. */
  const [said, setSaid] = useState<Record<string, string>>({})
  /** The row with something in flight, so its button can say so. */
  const [busy, setBusy] = useState('')
  /** Why the list could not be read, or `''`. */
  const [problem, setProblem] = useState('')

  useEffect(() => {
    if (open) setShowing(profileId)
  }, [open, profileId])

  const load = useCallback(async () => {
    if (!api.browserExtensions) return
    try {
      setView(readExtensionsView(await api.browserExtensions(showing)))
      setProblem('')
    } catch (error) {
      /*
       * A panel that opens and stays blank reads as a store with nothing in it,
       * which is a different and much more misleading thing than a store that
       * could not be read. The same judgement `ToolsPanel` makes.
       */
      setView(EMPTY)
      setProblem(error instanceof Error ? error.message : 'The list could not be read.')
    }
    setLoaded(true)
  }, [api, showing])

  useEffect(() => {
    if (!open) return
    void load()
  }, [open, load])

  const act = useCallback(
    async (id: string, verb: 'install' | 'remove') => {
      const call = verb === 'install' ? api.browserExtensionInstall : api.browserExtensionRemove
      if (!call) return
      setBusy(id)
      try {
        const result = readExtensionResult(await call(showing, id))
        setSaid((was) => ({ ...was, [id]: result.message }))
      } catch (error) {
        setSaid((was) => ({
          ...was,
          [id]: error instanceof Error ? error.message : 'That did not work.',
        }))
      } finally {
        setBusy('')
        // Re-read whatever happened, so the row's state comes off the disk and
        // the live session rather than off an assumption about what the call did.
        await load()
      }
    },
    [api, showing, load],
  )

  const setEnabled = useCallback(
    async (id: string, on: boolean) => {
      if (!api.browserExtensionEnable) return
      setBusy(id)
      try {
        const result = readExtensionResult(await api.browserExtensionEnable(showing, id, on))
        setSaid((was) => ({ ...was, [id]: result.message }))
      } catch (error) {
        setSaid((was) => ({
          ...was,
          [id]: error instanceof Error ? error.message : 'That did not work.',
        }))
      } finally {
        setBusy('')
        await load()
      }
    },
    [api, showing, load],
  )

  const openPopup = useCallback(
    async (id: string) => {
      if (!api.browserExtensionPopup) return
      try {
        const result = readExtensionResult(await api.browserExtensionPopup(showing, id))
        if (!result.ok) setSaid((was) => ({ ...was, [id]: result.message }))
      } catch (error) {
        setSaid((was) => ({
          ...was,
          [id]: error instanceof Error ? error.message : 'Its panel did not open.',
        }))
      }
    },
    [api, showing],
  )

  const installed = view.extensions.filter((one) => one.state === 'installed' || one.state === 'damaged')
  const available = view.extensions.filter((one) => one.state === 'available')
  const unavailable = view.extensions.filter((one) => one.state === 'unavailable')

  const row = (extension: StoreExtension) => (
    <ExtensionRow
      key={extension.id}
      extension={extension}
      busy={busy === extension.id}
      said={said[extension.id] ?? ''}
      canOpenPopup={typeof api.browserExtensionPopup === 'function'}
      onAct={(verb) => void act(extension.id, verb)}
      onEnable={(on) => void setEnabled(extension.id, on)}
      onOpenPopup={() => void openPopup(extension.id)}
    />
  )

  return (
    <Modal open={open} title="Browser extensions" onClose={onClose} size="lg">
      {!loaded ? null : problem !== '' ? (
        <p className="bw-error">{problem}</p>
      ) : (
        <>
          {/*
            Said once, before the first row, because these change how the whole
            list should be read rather than qualifying any part of it.
          */}
          <section className="bw-store-section">
            {view.limits.map((line) => (
              <p key={line} className="bw-store-note">
                {line}
              </p>
            ))}
          </section>

          {view.profiles.length > 1 && (
            <label className="bw-store-note bw-ext-profile" htmlFor="bw-ext-profile">
              Extensions are installed into one profile and read every page in it. Showing{' '}
              <select
                id="bw-ext-profile"
                value={showing}
                onChange={(event) => setShowing(event.target.value)}
              >
                {view.profiles.map((profile) => (
                  <option key={profile.id} value={profile.id}>
                    {profile.name}
                  </option>
                ))}
              </select>
            </label>
          )}

          {installed.length > 0 && (
            <section className="bw-store-section">
              <h3 className="bw-store-heading">Installed in {view.profileName || 'this profile'}</h3>
              <ul className="bw-store-list">{installed.map(row)}</ul>
            </section>
          )}

          <section className="bw-store-section">
            <h3 className="bw-store-heading">
              {installed.length > 0 ? 'More extensions' : 'Extensions'}
            </h3>
            {available.length === 0 ? (
              <p className="bw-muted">
                Everything this app can install is already installed in this profile.
              </p>
            ) : (
              <ul className="bw-store-list">{available.map(row)}</ul>
            )}
          </section>

          {unavailable.length > 0 && (
            <section className="bw-store-section">
              <h3 className="bw-store-heading">Cannot work in this browser</h3>
              <p className="bw-store-note">
                These load and then do not do their job. Each line is what this app saw when it ran
                them here, not a guess from their manifests. There is no Install for them, because
                installing one would only put a program on your disk that does nothing.
              </p>
              <ul className="bw-store-list">{unavailable.map(row)}</ul>
            </section>
          )}

          {/*
            Folders this build has no row for — an extension withdrawn between
            releases. Offered rather than hidden: these are megabytes of files
            this app wrote and can no longer name.
          */}
          {view.orphans.length > 0 && (
            <section className="bw-store-section">
              <h3 className="bw-store-heading">No longer offered</h3>
              <ul className="bw-store-list">
                {view.orphans.map((id) => (
                  <li key={id} className="bw-store-row">
                    <div className="bw-store-head">
                      <span className="bw-store-name">{id}</span>
                      <span className="bw-grow" />
                      <button
                        type="button"
                        className="bw-text-button"
                        disabled={busy === id}
                        onClick={() => void act(id, 'remove')}
                      >
                        {busy === id ? 'Working…' : 'Remove'}
                      </button>
                    </div>
                    <p className="bw-store-summary">
                      This version of the app no longer offers this extension, so it is not loaded.
                      Its files are still on disk.
                    </p>
                    {(said[id] ?? '') !== '' && <p className="bw-store-said">{said[id]}</p>}
                  </li>
                ))}
              </ul>
            </section>
          )}

          {/* Where the files are, because Remove says files are deleted and a
              person is entitled to go and look. */}
          {view.folder !== '' && (
            <p className="bw-store-note">
              This profile’s extensions are kept in <code>{view.folder}</code>.
            </p>
          )}
        </>
      )}
    </Modal>
  )
}

interface RowProps {
  extension: StoreExtension
  busy: boolean
  said: string
  canOpenPopup: boolean
  onAct(verb: 'install' | 'remove'): void
  onEnable(on: boolean): void
  onOpenPopup(): void
}

/**
 * One row: what it is, what it reaches, what was measured, and the controls it
 * has actually earned.
 *
 * Exported so it can be rendered on its own — this project has no DOM in its
 * test setup, so a dialog's first paint under SSR is an empty shell and the row
 * is where everything worth asserting lives. The same reason `ToolRow` is.
 */
export function ExtensionRow({
  extension,
  busy,
  said,
  canOpenPopup,
  onAct,
  onEnable,
  onOpenPopup,
}: RowProps) {
  const actionable = canAct(extension)
  const isInstalled = extension.state === 'installed'
  return (
    <li className="bw-store-row">
      <div className="bw-store-head">
        <span className="bw-store-name">{extension.name}</span>
        <span className="bw-store-version">{extension.version}</span>
        <span className="bw-grow" />
        {/* An extension that draws a panel of its own gets a way in. Only when
            it has one and only when it is running — a button opening the popup
            of a program that is not loaded has nothing to show. */}
        {isInstalled && extension.enabled && extension.popup !== '' && canOpenPopup && (
          <button type="button" className="bw-text-button" onClick={onOpenPopup}>
            Open panel
          </button>
        )}
        {isInstalled && (
          <label className="bw-ext-switch">
            <input
              type="checkbox"
              checked={extension.enabled}
              disabled={busy}
              onChange={(event) => onEnable(event.target.checked)}
            />
            On
          </label>
        )}
        {actionable && (
          <button
            type="button"
            className={
              extensionActionVerb(extension) === 'remove' ? 'bw-text-button' : 'bw-store-install'
            }
            disabled={busy}
            onClick={() => onAct(extensionActionVerb(extension))}
          >
            {extensionActionLabel(extension, busy)}
          </button>
        )}
      </div>

      <p className="bw-store-summary">{extension.summary}</p>

      <dl className="bw-store-facts">
        <div>
          <dt>Reaches</dt>
          {/*
            Before the button, always, installed or not. This is the whole of
            what somebody is agreeing to: an extension is a program, and the one
            thing that decides how much of your browsing it sees is the host
            patterns in its manifest.

            The catalogue states it before the install and the manifest on disk
            replaces that answer afterwards — and `browser-extensions.ts` refuses
            an install whose manifest reaches wider than this line said, so the
            two can never be different things.
          */}
          <dd>{reachWords(extension.reach, extension.everywhere)}</dd>
        </div>
        <div>
          <dt>Licence</dt>
          <dd>{extension.licence}</dd>
        </div>
        <div>
          <dt>Source</dt>
          <dd>{extension.homepage}</dd>
        </div>
        {extension.missing.length > 0 && (
          <div>
            <dt>Not available here</dt>
            <dd>{extension.missing.map((api) => `chrome.${api}`).join(', ')}</dd>
          </div>
        )}
      </dl>

      {/*
        What this app saw, in its own words. On every row, including the ones
        that work: a verdict with no observation behind it is an opinion, and a
        store full of opinions is what this one was written to avoid.
      */}
      <p className="bw-store-said">{extension.measured}</p>

      {extension.staticRulesets && extension.state === 'installed' && (
        <p className="bw-error">
          Its rules ship as manifest declarativeNetRequest rulesets, and this browser does not switch
          those on, so they are not in force.
        </p>
      )}
      {extension.state === 'damaged' && <p className="bw-error">{extension.message}</p>}
      {extension.state === 'installed' && extension.message !== '' && (
        <p className="bw-error">{extension.message}</p>
      )}
      {said !== '' && <p className="bw-store-said">{said}</p>}
    </li>
  )
}
