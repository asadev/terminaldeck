/**
 * The copilot's files, as one of his own phones reads and edits them.
 *
 * ## What this is for, in his words
 *
 * > *"the copilot has things in the macbook side and the windows side, it has a
 * > lot of other things also to do so it differentiates itself … its memory
 * > folder which is actually here, the folder's own instruction, what it was
 * > handed, its tool list, its instructions, its folder, its account status, its
 * > name … it reads and writes two kinds of prompts and only one is ours."*
 *
 * The settings pane on the desktop has answered that since the *"Its files"*
 * card was written — *"this is the answer to why did it say that"* — and the iOS
 * Copilot screen had a thin version of it with nothing behind the rows. This
 * module is the thing behind them.
 *
 * ## Why it is here and not in `remote/`
 *
 * Every other seam the endpoint takes lives beside it, and this one cannot:
 * `copilot-inspect.ts` imports `shell` from `electron` as a **value**, so the
 * module throws at load under plain Node. A `remote/` implementation would take
 * the headless daemon down at import time rather than at call time — the same
 * edge `staleAgents` records in `headless/host.ts`. So the interface is over
 * there, in `remote/copilot-files.ts`, where `server.ts` can `import type` it
 * with nothing following the import; the assembly is here, where Electron is a
 * given.
 *
 * ## Nothing in this file is a second implementation
 *
 * Every read and every write below is one of the functions the settings pane
 * already presses — `readCopilotInstructions`, `writeCopilotInstructions`,
 * `resetCopilotInstructions`, `readFolderInstructions`, `writeFolderInstructions`,
 * `readLayerFile`, `readComposedLayer`, `readMemory`, `readMemoryFact`,
 * `writeMemoryFact`, `deleteMemoryFact`. What this module adds is exactly three
 * things, and they are the three the wire needs and the pane does not:
 *
 *  - **an id space with no paths in it.** `protocol.ts` decides what an id may
 *    be; this file is where the four words become the four paths, out of
 *    `copilotPaths()`, in this process. Nothing a phone sent is ever joined,
 *    resolved or opened.
 *  - **a size gate**, because the desktop's editors allow 256 KB and this wire
 *    cannot carry a quarter of that. See `MAX_COPILOT_FILE_BYTES`.
 *  - **an honest actor in the action log.** The pane's rows say *from Settings*.
 *    A save that came off a phone says *from a paired device*, because a row
 *    that could be read as somebody at the keyboard is a row that lies about the
 *    one edit hardest to explain afterwards.
 */

import { statSync } from 'node:fs'
import {
  appendCopilotAction,
  copilotLayerFiles,
  copilotStartupFiles,
  folderInstructions,
  readCopilotInstructions,
  readFolderInstructions,
  resetCopilotInstructions,
  writeCopilotInstructions,
  writeFolderInstructions,
  type CopilotPaths,
  type StartupFile,
} from './copilot-home'
import { readComposedLayer, readLayerFile } from './copilot-layer'
import { deleteMemoryFact, readMemory, readMemoryFact, writeMemoryFact } from './copilot-inspect'
import {
  COPILOT_MEMORY_PREFIX,
  MAX_COPILOT_FILE_BYTES,
  MAX_COPILOT_FILE_PURPOSE,
  MAX_COPILOT_FILE_ROWS,
  type CopilotFileId,
  type CopilotFileRow,
  type CopilotFileTarget,
} from './remote/protocol'
import type { CopilotFiles, CopilotFileText, CopilotFileWrite } from './remote/copilot-files'

/**
 * How the action log names an edit that arrived over the wire.
 *
 * Deliberately not the device's name. The log is read weeks later by somebody
 * working out why the copilot changed its mind, and *"you edited its
 * instructions from iPhone (Asad)"* invites the reading that the phone did it —
 * whereas the true statement is that a person did, at a keyboard that was not
 * this one. Which device it was is already in the roster and in the tool rows
 * beside it; this line is about the actor, and the actor is the person.
 */
const FROM_A_PHONE = 'a paired device'

/**
 * What is stripped out of a row's `name` and `purpose` before it goes onto the
 * wire.
 *
 * C0, DEL and C1, the narrower half of what `protocol.ts` strips off a device
 * name — and here for a related reason rather than the same one. A memory row's
 * purpose is the `description:` line **out of a file the copilot wrote**, so it
 * is the one string on this surface whose content an agent chose. It lands in a
 * list on a phone and, when something goes wrong, in a log line; a control byte
 * in either is an escape sequence somebody else composed.
 *
 * The bidi overrides `DISPLAY_STRIP` also removes are not here, and that is a
 * deliberate difference: those matter on the approval screen, where a human
 * grants access by reading attacker-chosen text. Nobody grants anything by
 * reading this list, and a description written in Arabic must lay out correctly.
 */
const ROW_STRIP = /[\u0000-\u001f\u007f-\u009f]/g

/**
 * Assemble the copilot's files for the wire, given a way to find them.
 *
 * `paths` is a function rather than a value for the reason every late-bound
 * dependency in `index.ts` is one: the copilot's folder is a setting, a person
 * can point it somewhere else while a phone is connected, and a `CopilotPaths`
 * captured at assembly would be answering about a folder that has since changed.
 * `copilot-session.ts` resolves it the same way on every start.
 */
export function copilotFilesHere(paths: () => CopilotPaths): CopilotFiles {
  return {
    list: () => rows(paths()),
    read: (target) => readOne(paths(), target),
    write: (target, body) => writeOne(paths(), target, body),
    reset: () => resetOwn(paths()),
    forget: (name) => forgetMemory(paths(), name),
  }
}

/* ------------------------------------------------------------------ listing -- */

/**
 * Every file, in the order the copilot meets them.
 *
 * The two app-side halves first — the persona and the generated contract —
 * then the composed file that is actually handed over, then the folder's own
 * instructions, then memory newest-first. That is `copilotLayerFiles`'s order
 * followed by `copilotStartupFiles`'s, and it is not alphabetical for the reason
 * that function gives about itself: the order *is* part of the answer.
 *
 * The folder's `CLAUDE.md` is listed **even when it is not there**, which is the
 * one row worth defending against a tidy-up. Its absence is the visible proof
 * that nothing in that folder claims to be a copilot, so an ordinary terminal
 * opened there reads nothing of ours. A row saying "not there" states it;
 * leaving the row out would leave a person to infer it.
 */
function rows(paths: CopilotPaths): CopilotFileRow[] {
  /*
   * Both listings, keyed by path, so each of the four fixed files is found by
   * name rather than by its position in an array. Two functions produce these
   * and both are free to grow a row; matching on the path means a row added to
   * either one changes nothing here, where matching on an index would silently
   * relabel a file.
   *
   * `copilotStartupFiles` is asked for an empty memory listing. It takes that
   * seam already, and without it every call here would stat the whole memory
   * directory twice — once for a list this function throws away, and once inside
   * `readMemory` below, which is the listing that actually answers.
   */
  const stats = new Map<string, StartupFile>()
  for (const file of copilotLayerFiles(paths)) stats.set(file.path, file)
  for (const file of copilotStartupFiles(paths, () => [])) stats.set(file.path, file)

  const fixed: CopilotFileRow[] = [
    fixedRow('yours', paths.layer.yours, stats, true),
    // The two generated ones. Not writable, and this is the same refusal the
    // desk makes by having no `copilot:write-contract` channel: a hand-edited
    // copy of a generated description drifts from the thing it describes, and
    // this project has shipped exactly that defect twice — an instruction file
    // claiming a jail that had been removed, and one denying powers the copilot
    // had.
    fixedRow('contract', paths.layer.contract, stats, false),
    fixedRow('composed', paths.layer.composed, stats, false),
    fixedRow('folder', folderInstructions(paths), stats, true),
  ]

  /*
   * And memory, out of the same reader the settings pane uses.
   *
   * `readMemory` rather than the memory half of `copilotStartupFiles`, because
   * it answers two things that listing cannot: the file's **name** on its own —
   * so nothing here has to slice a basename off a path — and the `description:`
   * out of its front matter, which is a far better `purpose` than the word
   * "Memory" repeated forty times. It is newest-first, which is the order a
   * person opening this is asking about; the alphabetical order is already in
   * `MEMORY.md`, which the copilot maintains as the index.
   */
  const room = MAX_COPILOT_FILE_ROWS - fixed.length
  const facts = readMemory(paths).facts.slice(0, room < 0 ? 0 : room)
  return [
    ...fixed,
    ...facts.map((fact) => ({
      id: `${COPILOT_MEMORY_PREFIX}${fact.name}`,
      name: display(fact.name),
      purpose: display(fact.description ?? (fact.index ? 'Memory index' : 'Memory')),
      // `folder` rather than `yours`, matching what `copilotStartupFiles` badges
      // these as: `memory/` lives in the working directory, which may be a
      // workspace of the person's own, and the copilot is the thing that writes
      // it. The badge answers *who wrote this*, and the answer is neither the
      // app nor the person.
      owner: 'folder' as const,
      exists: true,
      size: fact.bytes,
      modifiedAt: fact.modifiedAt,
      writable: fact.bytes <= MAX_COPILOT_FILE_BYTES,
    })),
  ]
}

/**
 * One of the four fixed rows, out of whichever listing described it.
 *
 * A miss cannot happen while the two listings above describe these four paths,
 * and it is answered rather than thrown for the reason `describe` itself
 * swallows a failed `stat`: this function is called to draw a list, and a
 * refactor in `copilot-home.ts` must cost a row that says "not there" rather
 * than a Files card that fails to open.
 */
function fixedRow(
  id: CopilotFileId,
  path: string,
  stats: Map<string, StartupFile>,
  editable: boolean,
): CopilotFileRow {
  const file = stats.get(path)
  const size = file?.size ?? null
  return {
    id,
    name: baseName(path),
    purpose: display(file?.purpose ?? ''),
    owner: file?.owner ?? 'app',
    exists: file?.exists ?? false,
    size,
    modifiedAt: file?.modifiedAt ?? null,
    // A file bigger than this wire could have shown whole is not writable from
    // it. See `MAX_COPILOT_FILE_BYTES`: saving a box that was never filled is a
    // delete, and refusing the Save is cheaper than explaining the deletion.
    writable: editable && (size === null || size <= MAX_COPILOT_FILE_BYTES),
  }
}

/** The last path component, without importing a path module for one slice. */
function baseName(path: string): string {
  const at = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'))
  return at < 0 ? path : path.slice(at + 1)
}

/** A display string, stripped and capped. See {@link ROW_STRIP}. */
function display(value: string): string {
  return value.replace(ROW_STRIP, '').slice(0, MAX_COPILOT_FILE_PURPOSE)
}

/* -------------------------------------------------------------------- read -- */

/**
 * One file, whole, or the sentence saying why not.
 *
 * Four readers rather than one, because the four files fail in genuinely
 * different ways and each reader already knows its own. The layer's own reader
 * says *"There are no instructions yet. Create its files first."*; the folder's
 * treats a missing file as an empty box rather than an error, because a folder
 * with no instruction file is the ordinary and reassuring case; the generated
 * pair say *"Nothing has been written yet — these files are composed when the
 * copilot starts."* Folding them into one message would lose the difference
 * between *your copilot has never run* and *this folder is clean*.
 */
function readOne(paths: CopilotPaths, target: CopilotFileTarget): CopilotFileText {
  const read = rawRead(paths, target)
  if (read.error !== null) return { text: '', error: read.error }
  /*
   * The size gate, applied to what came back rather than to a `stat`.
   *
   * After the read on purpose. A `stat` first would be a second answer to how
   * big the file is, taken at a different moment from the read — and the value
   * that has to fit on the wire is the string in hand, not the file that was on
   * disk a moment before it.
   *
   * Nothing is truncated: see `MAX_COPILOT_FILE_BYTES`, and the sentence sends
   * the person to the machine, which has the file and an editor with no cap.
   */
  const bytes = Buffer.byteLength(read.text, 'utf8')
  if (bytes > MAX_COPILOT_FILE_BYTES) {
    return {
      text: '',
      error:
        `That file is ${Math.round(bytes / 1024)} KB, and the most that can be sent to a device is ` +
        `${Math.round(MAX_COPILOT_FILE_BYTES / 1024)} KB. Open it on the computer running the copilot.`,
    }
  }
  return { text: read.text, error: null }
}

/** The four readers, each answering in its own words. */
function rawRead(paths: CopilotPaths, target: CopilotFileTarget): CopilotFileText {
  if (target.kind === 'memory') {
    const fact = readMemoryFact(paths, target.name)
    if (!fact.ok) return { text: '', error: fact.error }
    /*
     * `truncated` is treated as a failure rather than passed on.
     *
     * That reader may hand back the first 256 KB of a longer file, because at
     * the desk it feeds a viewer. Here every box has a Save under it, and the
     * size gate above would refuse anything this large anyway — but saying so
     * here as well means a change to either number cannot quietly turn this into
     * an editor holding half a file.
     */
    if (fact.truncated) {
      return { text: '', error: 'That memory is too large to open on a device. Open it on the computer.' }
    }
    return { text: fact.text, error: null }
  }
  switch (target.id) {
    case 'yours': {
      const read = readCopilotInstructions(paths)
      return read.ok ? { text: read.text, error: null } : { text: '', error: read.error }
    }
    case 'contract': {
      const read = readLayerFile(paths.layer.contract)
      return { text: read.text ?? '', error: read.text === null ? read.error : null }
    }
    case 'composed': {
      const read = readComposedLayer(paths.layer)
      return { text: read.text ?? '', error: read.text === null ? read.error : null }
    }
    case 'folder': {
      // A missing file is an **empty box**, not an error. That is the whole
      // difference between this reader and the layer's, and it is the state a
      // person is most often looking at: nothing in that folder claims to be a
      // copilot, and the box is where they would write one if they wanted to.
      const read = readFolderInstructions(paths)
      return { text: read.text, error: read.error }
    }
  }
}

/* ------------------------------------------------------------------- write -- */

/**
 * Save one file, and record who did it.
 *
 * The two generated files are refused here rather than by an absent method,
 * because a refusal a person can read is worth more than a frame that quietly
 * did nothing — and the row already said `writable: false`, so anything landing
 * in this branch is a client that ignored its own listing.
 */
function writeOne(paths: CopilotPaths, target: CopilotFileTarget, body: string): CopilotFileWrite {
  if (target.kind === 'layer' && (target.id === 'contract' || target.id === 'composed')) {
    return {
      ok: false,
      error:
        'That file is written by the app every time the copilot starts, so there is nothing to save. ' +
        'Edit its instructions instead — this one is composed from them.',
    }
  }
  /*
   * And the size of what is **already on disk**, before anything is replaced.
   *
   * The check is against the existing file rather than against the text that
   * arrived, and that is the point of it: a file too big to have been sent whole
   * is a file the box on the phone can only be holding part of, and saving part
   * of a file over the whole of it is a deletion wearing a Save button. The
   * desktop's pane refuses a save on a truncated read for the same reason; this
   * is that rule where the truncation would have happened on the wire.
   */
  const existing = onDisk(paths, target)
  if (existing !== null && existing > MAX_COPILOT_FILE_BYTES) {
    return {
      ok: false,
      error:
        `That file is ${Math.round(existing / 1024)} KB — larger than a device can be sent — so it cannot be ` +
        'saved from here. Edit it on the computer running the copilot.',
    }
  }

  if (target.kind === 'memory') {
    // The one writer that logs its own row, which is why the actor is passed in
    // rather than appended after. See `writeMemoryFact`'s `where`.
    const written = writeMemoryFact(paths, target.name, body, FROM_A_PHONE)
    return { ok: written.ok, error: written.error }
  }
  if (target.id === 'folder') {
    const written = writeFolderInstructions(paths, body)
    if (!written.saved) return { ok: false, error: written.error ?? 'It could not be saved just now.' }
    /*
     * Logged, and logged as a person's doing at another keyboard.
     *
     * The desk's IPC handler writes the same three sentences and the reason is
     * stronger here than there: this file is in a folder of theirs that other
     * tools read, so *when did this change and who changed it* is a question
     * with consequences outside this app — and the answer now includes a machine
     * nobody was sitting at.
     */
    appendCopilotAction(paths, {
      action: 'folder-instructions.edited',
      detail: written.created
        ? `you created the folder’s own instructions from ${FROM_A_PHONE} at ${paths.root}`
        : written.backup === null
          ? `you saved the folder’s own instructions from ${FROM_A_PHONE}; nothing changed`
          : `you edited the folder’s own instructions from ${FROM_A_PHONE}; the previous file is at ${written.backup}`,
    })
    return { ok: true, error: null }
  }

  const written = writeCopilotInstructions(paths, body)
  if (!written.saved) return { ok: false, error: written.error ?? 'It could not be saved just now.' }
  // Only when something was replaced, matching the desk exactly: a first save
  // into a file that did not exist has no previous version to point at, and a
  // null backup also covers a save whose text matched what was already there.
  // Neither is a change worth a row.
  if (written.backup !== null) {
    appendCopilotAction(paths, {
      action: 'instructions.edited',
      detail: `you edited its instructions from ${FROM_A_PHONE}; the previous file is at ${written.backup}`,
    })
  }
  return { ok: true, error: null }
}

/**
 * How big the file behind a target is right now, or null when there is none.
 *
 * **No path is composed for a memory file.** The size comes out of the listing
 * `readMemory` already produces, which is the module that owns where memory
 * lives; a `join(paths.memory, name)` here would be a second place in this app
 * that turns a name off the wire into a path, which is exactly the thing
 * `copilotFileTarget` exists to keep to one. The four fixed paths are this
 * process's own and are stat'd directly.
 */
function onDisk(paths: CopilotPaths, target: CopilotFileTarget): number | null {
  if (target.kind === 'memory') {
    return readMemory(paths).facts.find((fact) => fact.name === target.name)?.bytes ?? null
  }
  try {
    const stat = statSync(fixedPath(paths, target.id))
    return stat.isFile() ? stat.size : null
  } catch {
    return null
  }
}

/**
 * The four fixed paths, composed here and nowhere a client can reach.
 *
 * **This function is the entire translation from a wire id to a file**, and it
 * is a `switch` over a closed union rather than a lookup in an object so that a
 * fifth id added to `COPILOT_FILE_IDS` stops the build here instead of falling
 * through to a default. There is no branch that takes a string.
 */
function fixedPath(paths: CopilotPaths, id: CopilotFileId): string {
  switch (id) {
    case 'yours':
      return paths.layer.yours
    case 'contract':
      return paths.layer.contract
    case 'composed':
      return paths.layer.composed
    case 'folder':
      return folderInstructions(paths)
  }
}

/* -------------------------------------------------------- reset and forget -- */

/**
 * Put this build's instructions back, keeping what was there.
 *
 * The previous contents go to a `.bak` beside the file before anything is
 * written, unconditionally, and that is what makes this safe to put behind a
 * single tap on a phone with no dialog in front of it — the argument
 * `resetCopilotInstructions` makes about its own backup, and it carries further
 * here, because the person tapping cannot see the file they are replacing.
 */
function resetOwn(paths: CopilotPaths): CopilotFileWrite {
  const result = resetCopilotInstructions(paths)
  if (result.error !== null) return { ok: false, error: result.error }
  appendCopilotAction(paths, {
    action: 'instructions.reset',
    detail:
      result.backup === null
        ? `the instructions this build ships were restored from ${FROM_A_PHONE}`
        : `the instructions this build ships were restored from ${FROM_A_PHONE}; the previous file is at ${result.backup}`,
  })
  return { ok: true, error: null }
}

/** Forget one memory. `deleteMemoryFact` writes its own row; see its `where`. */
function forgetMemory(paths: CopilotPaths, name: string): CopilotFileWrite {
  const result = deleteMemoryFact(paths, name, FROM_A_PHONE)
  return { ok: result.ok, error: result.error }
}
