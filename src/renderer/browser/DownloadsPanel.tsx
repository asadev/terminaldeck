import { useCallback, useEffect, useState } from 'react'
import { AnchoredPopup } from './AnchoredPopup'
import {
  destinationLine,
  downloadLine,
  downloadProgress,
  readAction,
  REMOTE_DEFAULT_FOLDER,
  SERVER_DEFAULT_FOLDER,
  type DownloadDestination,
  type DownloadRow,
  type DownloadsApi,
  type DownloadsView,
} from './downloads-bridge'
import type { MachineChoice } from './machines-bridge'
import type { Box } from './popup-anchor'

interface Props {
  api: DownloadsApi
  anchor: Box
  /** The view the panel's host is already holding, so opening it costs no round trip. */
  view: DownloadsView
  /** Every machine a file could be delivered to. Refusals included, as rows. */
  machines: readonly MachineChoice[]
  /** What to call the computer this window is on. See `hereName`. */
  here: string
  onClose(): void
}

/**
 * What has been downloaded, where it went, and where the next one will go.
 *
 * ## The three sentences this answers
 *
 * Asad, 2026-08-21, with our ⋯ menu open beside Chrome's:
 *
 *   > *"Then I need to have downloads option"*
 *   > *"Then I need proper downloads folder and all of this stuff, history, save
 *   > passwords and all of this."*
 *
 * and, a couple of minutes later, with the toolbar's machine picker pointed at
 * his Office PC:
 *
 *   > *"We should actually be able to maybe choose, if possible, it will bring
 *   > the thing in that machine where we want to actually download. So maybe we
 *   > can have an option."*
 *
 * So this is two things in one panel: a list of what happened, and the one
 * control that decides where the next one lands. They are together because they
 * are the same subject — a downloads list whose first question, *where did it
 * go*, could only be answered somewhere else would be the half-feature the whole
 * review is about.
 *
 * ## Why the destination is a machine *and* a folder, chosen separately
 *
 * A folder means nothing without the machine it is on. `/home/asad/Downloads`
 * exists on two of his three computers and is a different place on each, which
 * is the same ambiguity that put "This machine" on one bar three times — see
 * `hereName` in `machines/types.ts`. So the machine is picked first, by name,
 * and the folder is picked in the terms that machine can actually offer.
 *
 * ## Why the folder control differs by machine, and is not a lie either way
 *
 * **This computer** gets the OS's own folder chooser, because this process can
 * open one and it is the control everybody already knows.
 *
 * **A paired machine** gets the folders *that machine published* — they arrive
 * on its `welcome`, which is the same list its New-session picker offers — plus
 * a box for anything else. The far machine decides whether to accept what is
 * typed (`storeForFolder` in `remote/server.ts`), so a refusal is its own
 * sentence on the row rather than a guess made here.
 *
 * **A server** publishes no such list — an ssh connection carries no `welcome` —
 * so the box is the route, and the path is resolved by the server's own
 * `realpath` before anything is written. That asymmetry is stated on the control
 * rather than hidden behind an empty list.
 *
 * ## Nothing here is drawn for a file it cannot act on
 *
 * Open and Show in folder appear only for a finished download that is on **this**
 * machine, because the path in every other row is a path on somebody else's
 * disk. A button that resolved it against this one would open a different file
 * with the same name, which is worse than not offering it.
 */
export function DownloadsPanel({ api, anchor, view, machines, here, onClose }: Props) {
  const [choosing, setChoosing] = useState(false)
  /** The last refusal, from a machine or from this disk. One at a time. */
  const [problem, setProblem] = useState('')

  const destination = view.destination
  const chosen = machines.find((machine) => machine.id === destination.machineId) ?? null
  /*
   * What the chosen machine does with a file nobody named a folder for.
   *
   * A server and a paired desktop do genuinely different things — see the two
   * constants — and the line has to say which, or it is describing one machine
   * with another machine's behaviour.
   */
  const elsewhereDefault = chosen?.kind === 'server' ? SERVER_DEFAULT_FOLDER : REMOTE_DEFAULT_FOLDER
  const where = destinationLine(destination, here, view.defaultFolder, elsewhereDefault)

  const setDestination = useCallback(
    (next: DownloadDestination) => {
      setProblem('')
      void api.browserDownloadDestination?.(next)
    },
    [api],
  )

  return (
    <AnchoredPopup anchor={anchor} label="Downloads" onClose={onClose}>
      <div className="bw-downloads">
        {/*
          The destination, at the top, as a line rather than behind a heading.

          It reads as a fact — "Mac-mini · /Users/apple/Downloads/Terminal Deck"
          — and is a button, because the fact and the way to change it are the
          same thing. A "Save to" label above it would be a word restating the
          control underneath it, which is the habit this project has spent the
          week deleting.
        */}
        <button
          type="button"
          className="bw-dl-dest"
          aria-expanded={choosing}
          disabled={!api.browserDownloadDestination}
          title={api.browserDownloadDestination ? undefined : 'Not wired into this build'}
          onClick={() => setChoosing((open) => !open)}
        >
          <span className="bw-dl-dest-where">{where}</span>
          <span className="bw-dl-dest-verb" aria-hidden="true">
            {choosing ? 'Done' : 'Change'}
          </span>
        </button>

        {choosing && api.browserDownloadDestination && (
          <DestinationChooser
            api={api}
            destination={destination}
            defaultFolder={view.defaultFolder}
            elsewhereDefault={elsewhereDefault}
            machines={machines}
            here={here}
            chosen={chosen}
            onSet={setDestination}
          />
        )}

        {problem !== '' && <p className="bw-dl-problem">{problem}</p>}

        {view.items.length === 0 ? (
          /*
            The empty state names the folder rather than saying "no downloads".

            A person opening this on a fresh install is asking one of two
            questions — *has anything downloaded* and *where would it go* — and
            the second one has an answer even when the first does not.
          */
          <p className="bw-dl-empty">Nothing yet. Files land in {where}.</p>
        ) : (
          <div className="bw-dl-list">
            {view.items.map((row) => (
              <DownloadRowView
                key={row.id}
                api={api}
                row={row}
                here={here}
                onProblem={setProblem}
              />
            ))}
          </div>
        )}

        {view.items.length > 0 && api.browserDownloadClear && (
          <button
            type="button"
            className="bw-dl-clear"
            /* The list, never the files. See `clearDownloads`. */
            title="Empties this list. The files stay where they are."
            onClick={() => void api.browserDownloadClear?.()}
          >
            Clear list
          </button>
        )}
      </div>
    </AnchoredPopup>
  )
}

/* ------------------------------------------------------------------- rows -- */

function DownloadRowView({
  api,
  row,
  here,
  onProblem,
}: {
  api: DownloadsApi
  row: DownloadRow
  here: string
  onProblem(message: string): void
}) {
  const progress = downloadProgress(row)
  const moving = row.state === 'downloading' || row.state === 'delivering'
  const onThisMachine = row.state === 'done' && row.onMachine === '' && row.path !== ''

  const act = async (run: (id: string) => Promise<unknown>): Promise<void> => {
    const answer = readAction(await run(row.id))
    // A refusal is the whole reason these two go through the main process rather
    // than being drawn as links: the file can have been moved or deleted since
    // it landed, and "nothing happened" is the one answer this panel may not
    // give.
    if (!answer.ok) onProblem(answer.message || 'That file could not be opened.')
  }

  return (
    <div className="bw-dl-row" data-state={row.state}>
      <span className="bw-dl-name" title={row.url || row.name}>
        {row.name}
      </span>
      <span className="bw-dl-line">{downloadLine(row, here)}</span>
      {progress !== null && (
        <span
          className="bw-dl-bar"
          role="progressbar"
          aria-label={`${row.name} downloading`}
          aria-valuenow={Math.round(progress * 100)}
        >
          <span style={{ width: `${Math.round(progress * 100)}%` }} />
        </span>
      )}
      <span className="bw-dl-acts">
        {moving && api.browserDownloadCancel && (
          <button
            type="button"
            className="bw-dl-act"
            data-tone="critical"
            onClick={() => void api.browserDownloadCancel?.(row.id)}
          >
            Stop
          </button>
        )}
        {onThisMachine && api.browserDownloadOpen && (
          <button
            type="button"
            className="bw-dl-act"
            onClick={() => void act((id) => api.browserDownloadOpen?.(id) ?? Promise.resolve(null))}
          >
            Open
          </button>
        )}
        {onThisMachine && api.browserDownloadReveal && (
          <button
            type="button"
            className="bw-dl-act"
            onClick={() =>
              void act((id) => api.browserDownloadReveal?.(id) ?? Promise.resolve(null))
            }
          >
            Show
          </button>
        )}
      </span>
    </div>
  )
}

/* ------------------------------------------------------------ destination -- */

function DestinationChooser({
  api,
  destination,
  defaultFolder,
  elsewhereDefault,
  machines,
  here,
  chosen,
  onSet,
}: {
  api: DownloadsApi
  destination: DownloadDestination
  defaultFolder: string
  /** What the chosen machine does with a file when no folder is named. */
  elsewhereDefault: string
  machines: readonly MachineChoice[]
  here: string
  chosen: MachineChoice | null
  onSet(next: DownloadDestination): void
}) {
  const [typed, setTyped] = useState(destination.folder)

  // The box follows the destination rather than holding whatever was last typed
  // into it: switching machines and leaving a path from the previous one in the
  // field is a control that lies about where the next file is going.
  useEffect(() => {
    setTyped(destination.folder)
  }, [destination.machineId, destination.folder])

  const pickMachine = (machine: MachineChoice | null): void => {
    onSet(
      machine === null
        ? { machineId: '', machineName: '', folder: '' }
        : // Folder cleared with the machine, deliberately: a path is a path on
          // one computer, and carrying it across would point at a folder that
          // very likely does not exist over there.
          { machineId: machine.id, machineName: machine.name, folder: '' },
    )
  }

  return (
    <div className="bw-dl-chooser">
      <div className="bw-dl-machines" role="group" aria-label="Where downloads land">
        <button
          type="button"
          className="bw-dl-machine"
          data-on={destination.machineId === '' || undefined}
          onClick={() => pickMachine(null)}
        >
          {here || 'This machine'}
        </button>
        {machines.map((machine) => (
          <button
            key={machine.id}
            type="button"
            className="bw-dl-machine"
            data-on={destination.machineId === machine.id || undefined}
            /*
              A machine that cannot be reached still gets a row, disabled, with
              its state at the end of it — the rule `MachinePicker.tsx` sets out
              and the reason it gives: a machine that was there this morning and
              is simply missing from a menu sends somebody looking for a computer.
            */
            disabled={machine.unreachable !== null}
            title={machine.detail ?? undefined}
            onClick={() => pickMachine(machine)}
          >
            {machine.name}
            {machine.unreachable !== null && (
              <span className="bw-dl-machine-state"> — {machine.unreachable}</span>
            )}
          </button>
        ))}
      </div>

      {destination.machineId === '' ? (
        <div className="bw-dl-folder">
          <button
            type="button"
            className="bw-dl-act"
            disabled={!api.browserDownloadFolder}
            title={api.browserDownloadFolder ? undefined : 'Not wired into this build'}
            onClick={() => {
              void api.browserDownloadFolder?.().then((raw) => {
                // Empty means the sheet was cancelled, which is not a choice and
                // must not become one — setting an empty folder here would
                // silently move downloads back to the default.
                if (typeof raw === 'string' && raw !== '') {
                  onSet({ machineId: '', machineName: '', folder: raw })
                }
              })
            }}
          >
            Choose a folder…
          </button>
          {destination.folder !== '' && (
            <button
              type="button"
              className="bw-dl-act"
              onClick={() => onSet({ machineId: '', machineName: '', folder: '' })}
            >
              Use {defaultFolder || 'the downloads folder'}
            </button>
          )}
        </div>
      ) : (
        <div className="bw-dl-folder">
          {/*
            The folders that machine published, offered as they arrived.

            Only for a paired machine: `folders` is `null` for a server, which
            has no `welcome` to carry a list, and null is drawn as *nothing
            offered* rather than as an empty list — the same distinction the
            field itself makes.
          */}
          {(chosen?.folders ?? []).map((folder) => (
            <button
              key={folder}
              type="button"
              className="bw-dl-act"
              data-on={destination.folder === folder || undefined}
              onClick={() =>
                onSet({
                  machineId: destination.machineId,
                  machineName: destination.machineName,
                  folder,
                })
              }
            >
              {folder}
            </button>
          ))}
          <form
            className="bw-dl-typed"
            onSubmit={(event) => {
              event.preventDefault()
              onSet({
                machineId: destination.machineId,
                machineName: destination.machineName,
                folder: typed.trim(),
              })
            }}
          >
            <input
              type="text"
              value={typed}
              spellCheck={false}
              aria-label={`A folder on ${destination.machineName || 'that machine'}`}
              placeholder={elsewhereDefault}
              onChange={(event) => setTyped(event.target.value)}
            />
            <button type="submit" className="bw-dl-act" disabled={typed.trim() === destination.folder}>
              Set
            </button>
          </form>
        </div>
      )}
    </div>
  )
}
