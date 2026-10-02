import { extname, isAbsolute } from 'node:path'
import type { DownloadDestination, DownloadRow, DownloadsView } from '../browser-downloads-store'
import { actionOf, escalateBy, notASession, optStr, str } from './browser-area-kit'
import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from './catalogue'
import { Refused, type Tier } from './surface'

/**
 * `browser.downloads` — the Downloads panel, as one tool.
 *
 * ## The one judgement in this file: opening a file
 *
 * Listing, cancelling, revealing in Finder and choosing where files land are
 * the ordinary work of the panel, and each is the function the panel's own
 * button calls. Opening a downloaded file is the one that can be something else
 * entirely, because `shell.openPath` hands the file to whatever the Mac opens it
 * with — and for an app, an installer, a script or a macro-carrying document
 * that is **running a program somebody else wrote**. A copilot in another
 * application asking to open `report.pdf` is routine; the same copilot asking to
 * open `setup.pkg` is asking this Mac to run code it fetched from the internet.
 *
 * So the tier depends on the file. A file this can confidently place as data —
 * a picture, a PDF, a spreadsheet without macros, an archive the Mac only
 * unpacks — opens at `act`. Anything else is `alter`, which means a person is
 * shown the file's name and says yes first. "Anything else" is deliberately
 * wide: the list below is of what is *known safe*, not of what is known
 * dangerous, and a name with no extension, an extension this list has never
 * seen, or a file with its executable bit set all land on the side that asks.
 * The failure directions are not symmetric — a needless question costs one
 * click, a missing one costs whatever the program did.
 *
 * ## What a clear clears
 *
 * The rows, never a file. `clearDownloads` says so in its own comment and this
 * tool says it again in its answer. It is still `alter`, on the house rule for
 * anything that forgets: the list is the only record of where a file came from.
 */

/* --------------------------------------------------------------- the deps -- */

export interface DownloadToolDeps {
  view(): DownloadsView
  cancel(id: string): DownloadsView
  clear(): DownloadsView
  open(id: string): Promise<{ ok: boolean; message: string }>
  reveal(id: string): { ok: boolean; message: string }
  setDestination(destination: DownloadDestination): DownloadsView
  /** The native folder chooser, for the person at this Mac. `''` when cancelled. */
  chooseFolder(): Promise<string>
  /** Is this file marked executable on disk? False when it cannot be read. */
  executableBit(path: string): boolean
}

/* ------------------------------------------------------- what opens safely -- */

/**
 * Extensions a downloaded file can be opened with and nothing runs.
 *
 * Every entry is a document format the Mac's own apps display: images, audio,
 * video, PDF, plain and rich text, fonts, and the Office and iWork formats
 * *without* macros (`docm`, `xlsm` and `pptm` are absent on purpose — a macro is
 * a program). Archives are here because opening one on a Mac unpacks it and runs
 * nothing; what is inside is a new file, and opening *that* is its own call.
 * Disk images are not here: a `.dmg` mounts a volume whose contents are, almost
 * always, an app.
 */
const OPENS_AS_DATA: ReadonlySet<string> = new Set([
  // pictures
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'heif', 'tif', 'tiff', 'bmp', 'svg', 'ico', 'avif',
  // sound and video
  'mp3', 'm4a', 'aac', 'wav', 'aiff', 'flac', 'ogg', 'opus', 'mp4', 'm4v', 'mov', 'webm', 'mkv', 'avi',
  // documents
  'pdf', 'txt', 'md', 'rtf', 'csv', 'tsv', 'json', 'xml', 'yaml', 'yml', 'log', 'epub',
  'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'ods', 'odp', 'pages', 'numbers', 'key',
  // fonts
  'ttf', 'otf', 'woff', 'woff2',
  // archives the Mac unpacks without running anything
  'zip', 'gz', 'tgz', 'bz2', 'xz', 'tar', '7z', 'rar',
])

/**
 * May this downloaded file be opened without asking a person?
 *
 * Read from the file the row points at — its name and its mode bits — never
 * from the URL it came from, which the far server chose. Pure apart from the
 * mode check, which is handed in.
 */
export function opensAsData(row: Pick<DownloadRow, 'name' | 'path'>, executableBit: (path: string) => boolean): boolean {
  const named = row.path !== '' ? row.path : row.name
  const ext = extname(named).replace(/^\./, '').toLowerCase()
  if (ext === '' || !OPENS_AS_DATA.has(ext)) return false
  if (row.path !== '' && executableBit(row.path)) return false
  return true
}

/* ------------------------------------------------------------- the schema -- */

const ACTIONS = ['list', 'cancel', 'clear', 'open', 'reveal', 'destination'] as const
type Action = (typeof ACTIONS)[number]

const TIERS: Readonly<Record<Action, Tier>> = {
  list: 'read',
  cancel: 'act',
  clear: 'alter',
  open: 'act',
  reveal: 'act',
  destination: 'alter',
}

const SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    action: { type: 'string', enum: [...ACTIONS], description: 'Default list.' },
    download: { type: 'string', description: 'For cancel, open and reveal: the id from the list.' },
    folder: {
      type: 'string',
      description: 'For destination: an absolute folder. Omit to open the folder chooser for the person.',
    },
    machineId: { type: 'string', description: 'For destination: deliver to another machine instead. Omit for this one.' },
    machineName: { type: 'string', description: 'For destination with machineId: what to call it on the rows.' },
  },
  additionalProperties: false,
}

/** One row, as a caller reads it. The digest and the byte counts are kept; nothing is hidden. */
function rowOut(row: DownloadRow, executableBit: (path: string) => boolean): Record<string, unknown> {
  return {
    download: row.id,
    name: row.name,
    url: row.url,
    state: row.state,
    bytes: row.bytes,
    received: row.received,
    path: row.path,
    onMachine: row.onMachine === '' ? 'this computer' : row.onMachineName || row.onMachine,
    message: row.message,
    startedAt: row.startedAt,
    opensWithoutAsking: row.onMachine === '' && opensAsData(row, executableBit),
  }
}

function findRow(deps: DownloadToolDeps, id: string): DownloadRow {
  const row = deps.view().items.find((item) => item.id === id)
  if (!row) {
    throw new Refused('not-permitted', `there is no download ${id} in the list. action "list" names them.`)
  }
  return row
}

export function downloadTools(deps: DownloadToolDeps): ToolSpec[] {
  const tierFor = escalateBy(TIERS, 'list')
  return [
    {
      id: 'browser.downloads',
      wire: 'browser_downloads',
      tier: 'read',
      title: 'The browser’s downloads',
      description:
        'The browser’s Downloads list. "list" (the default) gives every download — name, address, state, ' +
        'size, where the file is and on which machine — and where new ones land. "cancel" stops one in ' +
        'progress. "clear" takes the finished rows off the list and never deletes a file. "open" opens a ' +
        'downloaded file with the Mac’s own app: a picture, document or archive opens straight away, but an ' +
        'app, installer, script or anything this cannot place as plain data runs a program, so the person ' +
        'is asked first. "reveal" shows one in Finder. "destination" sets the folder new downloads go to ' +
        '(folder; or omit it to open the folder chooser for the person), or another machine to deliver ' +
        'them to (machineId).',
      index:
        'Browser downloads: list, cancel, clear the list, open a file, show in Finder, set where they land.',
      inputSchema: SCHEMA,
      escalate: (args) => {
        const tier = tierFor(args)
        if (args.action !== 'open') return tier
        /*
         * Decided from the row before anything runs, and conservatively: a row
         * that cannot be found, or whose file cannot be placed as data, asks.
         * The precheck then refuses a missing row with a sentence, so the
         * question is never put for nothing.
         */
        if (typeof args.download !== 'string') return 'alter'
        const row = deps.view().items.find((item) => item.id === args.download)
        if (!row || row.onMachine !== '') return 'alter'
        return opensAsData(row, deps.executableBit) ? 'act' : 'alter'
      },
      precheck: (args, context: ToolContext) => {
        notASession(context, 'browser.downloads')
        const action = actionOf(args, ACTIONS, 'list')
        if (action === 'cancel' || action === 'open' || action === 'reveal') {
          const row = findRow(deps, str(args, 'download'))
          if ((action === 'open' || action === 'reveal') && row.onMachine !== '') {
            throw new Refused(
              'not-permitted',
              `${row.name} is on ${row.onMachineName || 'another machine'}, so it cannot be opened or shown from here.`,
            )
          }
        }
        const folder = optStr(args, 'folder')
        if (action === 'destination' && folder !== null && optStr(args, 'machineId') === null && !isAbsolute(folder)) {
          throw new Refused('not-permitted', `${folder} is not a full path. Name the folder from the root, like /Users/…/Downloads.`)
        }
        if (action === 'destination' && folder === null && optStr(args, 'machineId') === null) {
          if (context.attended === false) {
            throw new Refused(
              'not-permitted-unattended',
              'the folder chooser needs a person at this Mac. Name the folder instead.',
            )
          }
        }
      },
      summary: (args) => {
        const action = typeof args.action === 'string' ? args.action : 'list'
        const id = typeof args.download === 'string' ? args.download : '?'
        const named = (): string => deps.view().items.find((item) => item.id === id)?.name ?? id
        switch (action) {
          case 'cancel':
            return `Stop downloading ${named()}`
          case 'clear':
            return 'Clear the finished downloads off the list (the files stay)'
          case 'open':
            return `Open the downloaded file ${named()}`
          case 'reveal':
            return `Show ${named()} in Finder`
          case 'destination':
            return typeof args.folder === 'string' && args.folder !== ''
              ? `Save new downloads in ${args.folder}`
              : typeof args.machineId === 'string' && args.machineId !== ''
                ? `Deliver new downloads to ${typeof args.machineName === 'string' ? args.machineName : args.machineId}`
                : 'Ask the person where new downloads should go'
          default:
            return 'List the downloads'
        }
      },
      run: async (args): Promise<ToolOutput> => {
        const action = actionOf(args, ACTIONS, 'list')
        const listing = (view: DownloadsView): Record<string, unknown> => ({
          destination: {
            machine: view.destination.machineId === '' ? 'this computer' : view.destination.machineName || view.destination.machineId,
            folder: view.destination.folder || view.defaultFolder,
          },
          downloads: view.items.map((row) => rowOut(row, deps.executableBit)),
        })

        switch (action) {
          case 'list': {
            const view = deps.view()
            return { value: listing(view), summary: { downloads: view.items.length } }
          }
          case 'cancel': {
            const id = str(args, 'download')
            const view = deps.cancel(id)
            const row = view.items.find((item) => item.id === id)
            return { value: { download: id, state: row?.state ?? 'gone' }, summary: { download: id } }
          }
          case 'clear': {
            const before = deps.view().items.length
            const view = deps.clear()
            return {
              value: {
                cleared: before - view.items.length,
                note: 'Only the rows went. Every file is where it was.',
              },
              summary: { cleared: before - view.items.length },
            }
          }
          case 'open':
          case 'reveal': {
            const id = str(args, 'download')
            const result = action === 'open' ? await deps.open(id) : deps.reveal(id)
            if (!result.ok) throw new Refused('not-permitted', result.message)
            return { value: { download: id, [action === 'open' ? 'opened' : 'shown']: true }, summary: { download: id } }
          }
          case 'destination': {
            const machineId = optStr(args, 'machineId')
            let folder = optStr(args, 'folder')
            if (folder === null && machineId === null) {
              // The person at the Mac picks, in the same sheet the panel opens.
              folder = await deps.chooseFolder()
              if (folder === '') {
                return { value: { changed: false, note: 'The person closed the chooser without picking a folder.' }, summary: { changed: false } }
              }
            }
            const view = deps.setDestination({
              machineId: machineId ?? '',
              machineName: machineId === null ? '' : (optStr(args, 'machineName') ?? machineId),
              folder: folder ?? '',
            })
            return { value: { changed: true, ...listing(view) }, summary: { changed: true } }
          }
        }
        throw new Refused('not-permitted', `action must be one of: ${ACTIONS.join(', ')}`)
      },
    },
  ]
}
