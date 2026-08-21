import { useCallback, useEffect, useState } from 'react'
import { Modal } from '../components/Modal'
import {
  GRANT_WORDS,
  originWords,
  readStoreResult,
  readStoreView,
  type StoreApi,
  type StoreTool,
  type StoreView,
} from './store-bridge'

interface Props {
  open: boolean
  api: StoreApi
  onClose(): void
}

/**
 * The browser's tools store.
 *
 *   > *"i think we can have a tools store for extensions to this browser with
 *   > all open source best tools in the market so people can use the tool of
 *   > their choice in the browser, which tools will not be here only when they
 *   > download."*
 *
 * ## What a row promises, and why it says so much
 *
 * Four facts on every row before you press anything: what it does, **what it
 * reads**, **where it runs**, and where it came from. That is not decoration —
 * it is the disclosure the install is checked against. `browser-store.ts`
 * refuses a tool whose recipe asks for a grant or an origin this row did not
 * say, so what is on screen and what runs are the same thing or neither
 * happens.
 *
 * ## Why browser extensions are not in this panel
 *
 * They were nowhere at all when this was written, and the foot of this panel
 * said so. They have a store of their own now — `ExtensionsPanel.tsx` — and the
 * sentence at the foot points at it rather than denying it exists.
 *
 * They stayed out of *this* panel deliberately. A tool here is selectors this
 * app's own code runs, bounded by `browser.read`; an extension is a program
 * somebody else wrote, running on every page of a profile, and none of this
 * panel's safety argument transfers to it. One panel holding both would have to
 * keep saying which half it was talking about — and the row that matters most,
 * *what this reaches*, means something different in each.
 *
 * ## Why every failure lands on the row
 *
 * An install that refuses says which check refused it — the digest, the schema,
 * a grant, the network — on the row, in a sentence. A store that answered
 * "couldn't install" would be asking somebody to guess between a broken download
 * and a tool that wanted more than it was allowed, and those are opposite
 * problems.
 */
export function ToolsPanel({ open, api, onClose }: Props) {
  const [view, setView] = useState<StoreView>({ tools: [], folder: '', orphans: [] })
  const [loaded, setLoaded] = useState(false)
  /** id → the sentence the last action on that row produced. */
  const [said, setSaid] = useState<Record<string, string>>({})
  /** The row with something in flight, so its button can say so. */
  const [busy, setBusy] = useState('')

  /** Why the list could not be read, or `''`. */
  const [problem, setProblem] = useState('')

  const load = useCallback(async () => {
    if (!api.browserStore) return
    try {
      setView(readStoreView(await api.browserStore()))
      setProblem('')
    } catch (error) {
      /*
       * A dialog that opens and stays blank is the dead end this whole round is
       * about: it reads as a store with nothing in it, which is a different and
       * much more misleading thing than a store that could not be read. So the
       * panel finishes loading either way and says which one happened.
       */
      setView({ tools: [], folder: '', orphans: [] })
      setProblem(error instanceof Error ? error.message : 'The list could not be read.')
    }
    setLoaded(true)
  }, [api])

  useEffect(() => {
    if (!open) return
    void load()
  }, [open, load])

  const act = useCallback(
    async (tool: StoreTool | { id: string; name: string }, verb: 'install' | 'remove') => {
      const call = verb === 'install' ? api.browserStoreInstall : api.browserStoreRemove
      if (!call) return
      setBusy(tool.id)
      try {
        const result = readStoreResult(await call(tool.id))
        setSaid((was) => ({ ...was, [tool.id]: result.message }))
      } catch (error) {
        setSaid((was) => ({
          ...was,
          [tool.id]: error instanceof Error ? error.message : 'That did not work.',
        }))
      } finally {
        setBusy('')
        // Re-read whatever happened, so the row's state comes off the disk
        // rather than off an assumption about what the call did.
        await load()
      }
    },
    [api, load],
  )

  const installed = view.tools.filter((tool) => tool.state !== 'available')
  const available = view.tools.filter((tool) => tool.state === 'available')

  const row = (tool: StoreTool) => (
    <ToolRow
      key={tool.id}
      tool={tool}
      busy={busy === tool.id}
      said={said[tool.id] ?? ''}
      onAct={(verb) => void act(tool, verb)}
    />
  )

  return (
    <Modal open={open} title="Browser tools" onClose={onClose} size="lg">
      {!loaded ? null : problem !== '' ? (
        <p className="bw-error">{problem}</p>
      ) : (
        <>
          {installed.length > 0 && (
            <section className="bw-store-section">
              <h3 className="bw-store-heading">Installed</h3>
              <ul className="bw-store-list">{installed.map(row)}</ul>
            </section>
          )}

          <section className="bw-store-section">
            <h3 className="bw-store-heading">{installed.length > 0 ? 'More tools' : 'Tools'}</h3>
            {available.length === 0 ? (
              <p className="bw-muted">Everything in this store is installed.</p>
            ) : (
              <ul className="bw-store-list">{available.map(row)}</ul>
            )}
          </section>

          {/*
            Folders this build has no row for — a tool withdrawn between
            releases. Offered rather than hidden: a file this app wrote and can
            no longer name is a file nobody has any way to delete.
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
                        onClick={() => void act({ id, name: id }, 'remove')}
                      >
                        {busy === id ? 'Working…' : 'Remove'}
                      </button>
                    </div>
                    <p className="bw-store-summary">
                      This version of the app no longer offers this tool, so it cannot be run. Its
                      file is still on disk.
                    </p>
                    {(said[id] ?? '') !== '' && <p className="bw-store-said">{said[id]}</p>}
                  </li>
                ))}
              </ul>
            </section>
          )}

          <p className="bw-store-note">
            A tool is a set of selectors this browser runs on a page you point it at. It is never a
            program: nothing downloaded here is executed, and every file is checked against a
            fingerprint built into this app before it is saved and again every time it is read.
          </p>
          <p className="bw-store-note">
            Browser extensions are a separate thing, in their own store: the ⋯ menu, under
            Extensions.
          </p>
          {/* Where the files are, because Remove says a file is deleted and a
              person is entitled to go and look. */}
          {view.folder !== '' && (
            <p className="bw-store-note">
              Installed tools are kept in <code>{view.folder}</code>.
            </p>
          )}
        </>
      )}
    </Modal>
  )
}

/**
 * What one press will do, in the one word the button wears.
 *
 * Pure and exported because a button whose label disagrees with its handler is
 * the defect this app names outright — a control that looks like it works and
 * does something else — and a label assembled inline out of three ternaries is
 * exactly where that happens. `damaged` says Remove and not Reinstall: the file
 * on disk is not the one that was installed, and the honest first move is to
 * delete it.
 */
export function actionLabel(tool: StoreTool, busy: boolean): string {
  if (busy) return 'Working…'
  if (tool.state === 'installed' || tool.state === 'damaged') return 'Remove'
  return tool.fetched ? 'Download' : 'Install'
}

/** Which verb that press sends. The other half of {@link actionLabel}. */
export function actionVerb(tool: StoreTool): 'install' | 'remove' {
  return tool.state === 'installed' || tool.state === 'damaged' ? 'remove' : 'install'
}

interface RowProps {
  tool: StoreTool
  busy: boolean
  /** The sentence the last press on this row produced. */
  said: string
  onAct(verb: 'install' | 'remove'): void
}

/**
 * One row: four facts, one button, and whatever the last press said.
 *
 * Exported so it can be rendered on its own — this project has no DOM in its
 * test setup, so a dialog's first paint under SSR is an empty shell and the row
 * is where everything worth asserting lives.
 */
export function ToolRow({ tool, busy, said, onAct }: RowProps) {
  const verb = actionVerb(tool)
  return (
    <li className="bw-store-row">
      <div className="bw-store-head">
        <span className="bw-store-name">{tool.name}</span>
        <span className="bw-store-version">{tool.version}</span>
        <span className="bw-grow" />
        <button
          type="button"
          className={verb === 'remove' ? 'bw-text-button' : 'bw-store-install'}
          disabled={busy}
          onClick={() => onAct(verb)}
        >
          {actionLabel(tool, busy)}
        </button>
      </div>

      <p className="bw-store-summary">{tool.summary}</p>

      <dl className="bw-store-facts">
        <div>
          <dt>Reads</dt>
          <dd>{tool.grants.map((grant) => GRANT_WORDS[grant] ?? grant).join('. ') || 'nothing'}</dd>
        </div>
        <div>
          <dt>Runs on</dt>
          <dd>{originWords(tool.origins)}</dd>
        </div>
        <div>
          <dt>Licence</dt>
          <dd>{tool.licence}</dd>
        </div>
        {/* Only once it is installed, because until then there is no file to
            read the field names out of, and inventing them from the catalogue
            would be this panel's word rather than the recipe's. */}
        {tool.reads.length > 0 && (
          <div>
            <dt>Collects</dt>
            <dd>{tool.reads.join(', ')}</dd>
          </div>
        )}
      </dl>

      {tool.state === 'damaged' && <p className="bw-error">{tool.message}</p>}
      {said !== '' && <p className="bw-store-said">{said}</p>}
    </li>
  )
}
