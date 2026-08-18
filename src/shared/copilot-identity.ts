/**
 * What the copilot is called, and what it calls the person — as it is written
 * in the one file that already holds everything else about who it is.
 *
 * ## There is no store here, and that is the whole design
 *
 * Asad, 2026-08-17: *"Maybe we can give a few steps flow before someone sets up
 * the copilot. It can ask, what would you call your copilot, give it a name —
 * related to identity setup. And keep it in-app, actually, yes in app. So it
 * will ask those questions in the flow, and the copilot will always know about
 * this and act that way always."*
 *
 * The last clause is the requirement, and it is met by writing the answers where
 * the copilot already reads: `<userData>/copilot-layer/instructions.md`, the
 * person's half of the layer, handed to the CLI at spawn through
 * `--append-system-prompt-file`. Not a `copilot.name` setting, not a JSON file
 * beside it, and — the one that matters — **never a file in the copilot's
 * working directory.** `copilot-layer.ts` argues that at length: a folder can be
 * one the person already had, and identity kept on their disk is identity
 * inherited by every ordinary terminal they open there.
 *
 * So this module is a *format*, not a store. It composes a block of prose, and
 * it reads that same block back. Three consequences fall out of it, and each one
 * is the reason the format is prose rather than front matter or JSON:
 *
 *  - The copilot is told its name in the same sentence a person would use, in
 *    the file it already reads at every start. Nothing has to be taught to
 *    interpolate it.
 *  - Settings → Copilot already puts this file in an editable box with a Save
 *    button. Renaming the copilot by editing that sentence works, because the
 *    sentence *is* the record — the setup flow is a friendlier front door to the
 *    same bytes, which is exactly what was asked for.
 *  - Nothing can drift, because there is only one copy. A `copilot.name` setting
 *    and a paragraph saying "you are called Nova" would be two copies of one
 *    fact, and the one that drifts is always the one nobody reread.
 *
 * ## The product's name and the copilot's name are opposites
 *
 * `CLAUDE.md` in this repo: *"The name lives in one place. `src/shared/brand.ts`.
 * Never hardcode 'Terminal Deck' anywhere else."* That rule is about the
 * **product**, and it exists because the product's name is a constant that must
 * be spelled once.
 *
 * A copilot's name is the opposite of a constant in every respect. It is user
 * data: typed by a person, stored in their app-data directory, different on
 * every machine, and absent until they say otherwise. It must never be derived
 * from `BRAND`, and `BRAND` must never be derived from it.
 * {@link DEFAULT_COPILOT_NAME} is the only name this module knows, it is a
 * *description* rather than a name, and `copilot-identity.test.ts` pins the
 * separation.
 *
 * ## What "skipped" is written as, and why it is written at all
 *
 * Every question in the flow can be skipped, and skipping the first one is a
 * real answer rather than an absence: it means *they have not named it yet.*
 * That is written into the block in so many words, because the alternative — an
 * agent inventing a name for itself when nobody asked — is the failure Asad's
 * own instructions to an assistant already guard against:
 *
 * > *"He hasn't named you yet. Until he does, don't pick one for yourself —
 * > he'll tell you."*
 *
 * The block is therefore written **even when every question was skipped**, and
 * its presence is what {@link readCopilotIdentity} reports as `ran`. That is the
 * only record that the flow has happened, which is what stops it asking again on
 * the next launch — and it is a record a person can see, edit and delete, which
 * a hidden `setupDone: true` boolean would not be.
 */

/**
 * What this app calls a copilot nobody has named.
 *
 * A description rather than a name, deliberately — see the header. It is what
 * the sidebar row, the tab pill and Settings print until somebody says
 * otherwise, and it is the fallback for every reader of {@link copilotName}.
 */
export const DEFAULT_COPILOT_NAME = 'Copilot'

/**
 * The heading the block lives under.
 *
 * Load-bearing in both directions: {@link withCopilotIdentity} writes it, and
 * {@link readCopilotIdentity} finds the block by looking for it. Spelled once so
 * the writer and the reader cannot disagree about a word.
 *
 * A heading rather than an HTML comment or a fenced marker, because this file is
 * read by three audiences — the model at every start, a person in Settings, and
 * this module — and only a heading is unremarkable to all three. A pair of
 * `<!-- identity -->` markers would be machinery showing through in a document
 * whose whole point is that it is somebody's own writing.
 */
export const IDENTITY_HEADING = '## Who you are'

/**
 * The rule that closes the block.
 *
 * A closing fence rather than "everything up to the next heading", and the
 * difference is a paragraph of somebody's writing. The block is inserted under
 * the file's title, and the seeded file's next line is *prose* — the paragraph
 * about what a developer's copilot is for, with the next heading several
 * sentences below it. With no terminator, re-running the flow to change one name
 * replaced the block **and that paragraph**, because both sat between the
 * heading it starts on and the heading it stopped at. It was written that way,
 * and the round-trip test above caught it before anything ran.
 *
 * A thematic break is ordinary Markdown and reads as what it is: the line
 * between what this app wrote and what the person wrote. `copilot-layer.ts` uses
 * the same divider between the app's half of the layer and theirs, so the file a
 * person opens has one vocabulary for one idea.
 */
export const IDENTITY_END = '---'

/**
 * The three sentence stems the block is parsed by.
 *
 * Each is matched at the start of a line **inside the block only**, which is
 * what keeps the parse honest: somebody's own paragraph elsewhere in the file
 * that happens to begin "Call them" is prose about something else, and reading
 * it as an answer would rename the person from a sentence they wrote about a
 * pull request.
 */
const NAME_STEM = 'Your name is '
const CALL_STEM = 'Call them '
const ADDRESS_STEM = 'Address them like this: '

/** The answers, as the flow collects them and as the file gives them back. */
export interface CopilotIdentity {
  /** What the copilot is called, or null when nobody has named it. */
  name: string | null
  /** What it calls the person, or null when they did not say. */
  callThem: string | null
  /** One line about how they want to be spoken to, or null. */
  addressNote: string | null
}

/** Nothing answered — the shape a flow starts from, and a skipped one ends on. */
export const NO_IDENTITY: CopilotIdentity = { name: null, callThem: null, addressNote: null }

export interface IdentityReading {
  /**
   * True when the block is in the file at all.
   *
   * The record that the setup flow has run, and the only one. False means it has
   * never been offered — a fresh install, or somebody who deleted the block —
   * and that is what puts the flow in front of the first start.
   */
  ran: boolean
  identity: CopilotIdentity
}

/* ------------------------------------------------------------- sanitising -- */

/**
 * The most a copilot's name may be.
 *
 * Thirty-two characters, and the number comes from where the name is drawn
 * rather than from taste: the sidebar row is a 240px rail whose label column
 * shares space with a status dot, and the tab pill has a ~144px floor. A name
 * longer than this is one nobody can read in either place, so it is refused at
 * the point of typing — where a person can shorten it themselves — rather than
 * ellipsised in three different widths afterwards.
 */
export const MAX_COPILOT_NAME = 32

/** The same, for what it calls the person. One name, not a title. */
export const MAX_CALL_THEM = 32

/**
 * The most the "how to address me" line may be.
 *
 * A line, not a paragraph. Anything longer is a standing instruction, and
 * standing instructions have a whole file of their own directly below this block
 * — one a person can write as much of as they like. Keeping this short is what
 * stops the setup flow quietly becoming a second, worse instruction editor.
 */
export const MAX_ADDRESS_NOTE = 160

/**
 * One answer, made safe to write into a line of Markdown and read back out.
 *
 * Three things happen here and each one is a way the round trip could otherwise
 * break rather than a matter of taste:
 *
 *  - **Newlines and control characters become spaces.** Every value is written
 *    on one line and parsed to the end of that line. A pasted two-line value
 *    would put half of somebody's answer into the file as free-standing prose,
 *    where the reader would never find it again.
 *  - **Markdown emphasis characters are dropped.** The name and the address are
 *    written between `**`, so an asterisk in the value ends the bold early: the
 *    file would render wrongly *and* {@link readCopilotIdentity} would read back
 *    a truncated name. Backticks and underscores go for the same reason.
 *  - **It is capped and trimmed**, and an empty result is `null` rather than an
 *    empty string, because "typed nothing" and "skipped" are the same answer and
 *    the rest of this module should not have to know which one happened.
 */
export function cleanIdentityValue(raw: unknown, max: number): string | null {
  if (typeof raw !== 'string') return null
  const flattened = raw
    // eslint-disable-next-line no-control-regex -- the point is to remove them
    /*
     * Control characters are written as escapes here, never as the bytes
     * themselves. `encoding.test.ts` fails a source file that contains one,
     * and it is right to: a single raw control byte makes `file`(1) call this
     * a data file and makes `grep`(1) go silent about every match in it —
     * `workspace-tabs.ts` records the hours that cost. It happened again
     * while this line was being written.
     */
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/[*_`]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
  if (flattened === '') return null
  return flattened.slice(0, max).trim() || null
}

/** Every answer cleaned at once, which is what the flow hands to the composer. */
export function cleanIdentity(raw: Partial<CopilotIdentity>): CopilotIdentity {
  return {
    name: cleanIdentityValue(raw.name, MAX_COPILOT_NAME),
    callThem: cleanIdentityValue(raw.callThem, MAX_CALL_THEM),
    addressNote: cleanIdentityValue(raw.addressNote, MAX_ADDRESS_NOTE),
  }
}

/**
 * What to print, given whatever was read.
 *
 * Every surface that names the copilot goes through this rather than reaching
 * for `identity.name`, so an unnamed copilot cannot come out as an empty label
 * in one place and "Copilot" in another.
 */
export function copilotName(identity: CopilotIdentity | null | undefined): string {
  return identity?.name ?? DEFAULT_COPILOT_NAME
}

/* -------------------------------------------------------------- composing -- */

/**
 * The block, as it is written into the person's half of the layer.
 *
 * Written for the model first and the person second, which is the same order
 * `copilotInstructions()` is written in and for the same reason: the agent has
 * to be able to act on it, and the person has to be able to own it.
 *
 * Every branch says something true rather than falling silent. A skipped name is
 * not the absence of a sentence about names — it is the sentence *"they have not
 * named you; do not pick one for yourself"*, because an agent with no
 * instruction on the subject is an agent that will happily introduce itself as
 * whatever sounds good. That is the one behaviour this whole block exists to
 * prevent, and it is worth more here than the name is.
 */
export function copilotIdentityBlock(raw: CopilotIdentity): string {
  /*
   * Cleaned here rather than trusted from the caller, and it is not belt and
   * braces — it is the only place that can promise the round trip.
   *
   * The name is written between `**`, so an asterisk in it closes the emphasis
   * early and {@link readCopilotIdentity} reads back a truncated name; a pasted
   * newline puts half of somebody's answer into the file as free-standing prose
   * where nothing will ever find it again. Both were real, and both were caught
   * by `copilot-identity.test.ts` rather than by a reviewer, which is exactly
   * the argument for cleaning at the composer instead of at every call site.
   */
  const identity = cleanIdentity(raw)
  const lines: string[] = [IDENTITY_HEADING, '']

  if (identity.name === null) {
    lines.push(
      `They have not named you yet, and until they do you should not pick a name`,
      `for yourself. If they ask what you are called, say exactly that. In the`,
      `meantime this app calls you the ${DEFAULT_COPILOT_NAME}, which is a description`,
      `rather than a name.`,
    )
  } else {
    lines.push(
      `${NAME_STEM}**${identity.name}**. This app reads it from this line — change the`,
      `name here and it changes in the sidebar, on the tab and in Settings.`,
    )
  }

  lines.push('')

  if (identity.callThem === null) {
    lines.push(
      `They have not told you what to call them. If the folder you work in says,`,
      `follow that; otherwise ask, rather than guessing a name out of what you`,
      `find in their files.`,
    )
  } else {
    lines.push(`${CALL_STEM}**${identity.callThem}**.`)
  }

  if (identity.addressNote !== null) {
    lines.push('', `${ADDRESS_STEM}${identity.addressNote}`)
  }

  lines.push('', IDENTITY_END)
  return `${lines.join('\n')}\n`
}

/**
 * The instruction file with this block in it — replacing the old one, or put
 * where a first block belongs.
 *
 * Replace-in-place rather than append, because the flow is **re-runnable**: it
 * is offered again from Settings whenever somebody wants to rename their
 * copilot, and a second run that left the first block behind would hand the
 * model two paragraphs disagreeing about its own name. The block is found by its
 * heading, so a person who moved it down the file keeps it where they put it.
 *
 * A first block goes directly under the document's own `#` title when it has
 * one, and at the very top when it does not. Under the title because that is
 * where a reader looks for "who is this about", and because the seeded file
 * opens with a title followed by a paragraph about the job — putting the name
 * *above* the title would read as a second title.
 *
 * Everything the person has written is preserved byte for byte on either side of
 * the block. This function is the only thing in the app that edits their file
 * without them typing in it, so it edits as little as it possibly can.
 */
export function withCopilotIdentity(instructions: string, identity: CopilotIdentity): string {
  const block = copilotIdentityBlock(identity)
  const lines = instructions.split('\n')
  const start = headingAt(lines)

  /*
   * What is above the block, and what is below it. Everything else in this
   * function is deciding those two, and nothing in it ever looks *inside* them.
   */
  let head: readonly string[]
  let tail: readonly string[]
  if (start !== -1) {
    head = lines.slice(0, start)
    tail = lines.slice(blockEnd(lines, start))
  } else {
    // Under the title, when the file opens with one. Only a title on the *first*
    // line counts: a `#` heading further down is a section of somebody's own
    // prose, and inserting into the middle of it would split a paragraph from
    // the thing it is about.
    const at = /^#\s+\S/.test(lines[0] ?? '') ? 1 : 0
    head = lines.slice(0, at)
    tail = lines.slice(at)
  }

  /*
   * One blank line on each side, and no more, whatever was there before.
   *
   * Rebuilding the seams rather than splicing around them is what makes this
   * idempotent: two runs with the same answers have to produce the same bytes,
   * or every re-run would push the rest of the file down by a line and the
   * Settings editor would show a diff nobody made.
   */
  const above = trimEnd(head)
  const below = trimStart(tail)
  return (
    (above.length === 0 ? '' : `${above.join('\n')}\n\n`) +
    block +
    (below.length === 0 ? '' : `\n${below.join('\n')}`)
  )
}

/** The block's heading, wherever the person has since moved it. */
function headingAt(lines: readonly string[]): number {
  return lines.findIndex((line) => line.trim() === IDENTITY_HEADING)
}

/**
 * The line after the block: past its closing rule, or — for a block whose rule
 * somebody deleted — at the next heading, or the end of the file.
 *
 * The fence is the answer that matters and the heading is the fallback, in that
 * order. A hand-edited file that has lost its `---` still has to be
 * *replaceable* rather than appended to, and stopping at the next heading is
 * wrong-but-bounded there, where stopping nowhere would delete the rest of
 * somebody's instructions on the next run.
 */
function blockEnd(lines: readonly string[], start: number): number {
  for (let at = start + 1; at < lines.length; at += 1) {
    if (lines[at].trim() === IDENTITY_END) return at + 1
    if (/^#{1,6}\s/.test(lines[at])) return at
  }
  return lines.length
}

function trimEnd(lines: readonly string[]): readonly string[] {
  let end = lines.length
  while (end > 0 && lines[end - 1].trim() === '') end -= 1
  return lines.slice(0, end)
}

function trimStart(lines: readonly string[]): readonly string[] {
  let at = 0
  while (at < lines.length && lines[at].trim() === '') at += 1
  return lines.slice(at)
}

/* ----------------------------------------------------------------- reading -- */

/**
 * The block as it stands, read back out of the file.
 *
 * The exact inverse of {@link withCopilotIdentity} for anything this app wrote —
 * `copilot-identity.test.ts` pins the round trip, including for the values most
 * likely to break it — and a best effort for anything a person has since edited
 * by hand. That asymmetry is deliberate: a hand-edit that no longer matches a
 * stem is not an error to report, it is a person who has written their own
 * sentence, and the honest answer is that this app does not know the name.
 * Nothing is lost by that — their sentence still tells the model, which is the
 * only reader that has to understand it — and the app falls back to
 * {@link DEFAULT_COPILOT_NAME} in its own chrome.
 *
 * `ran` is what the flow asks. It is true the moment the heading is present,
 * whatever the block says underneath, because an all-skipped run is a finished
 * run and asking again on the next launch would be nagging somebody who already
 * answered "no thanks" four times.
 */
export function readCopilotIdentity(instructions: unknown): IdentityReading {
  if (typeof instructions !== 'string') return { ran: false, identity: NO_IDENTITY }
  const lines = instructions.split('\n')
  const start = headingAt(lines)
  if (start === -1) return { ran: false, identity: NO_IDENTITY }

  const block = lines.slice(start + 1, blockEnd(lines, start))
  return {
    ran: true,
    identity: {
      name: bolded(block, NAME_STEM, MAX_COPILOT_NAME),
      callThem: bolded(block, CALL_STEM, MAX_CALL_THEM),
      addressNote: trailing(block, ADDRESS_STEM, MAX_ADDRESS_NOTE),
    },
  }
}

/** `Stem **value**.` on a line of its own, or null. */
function bolded(block: readonly string[], stem: string, max: number): string | null {
  for (const line of block) {
    if (!line.startsWith(stem)) continue
    const match = /^\*\*([^*]+)\*\*/.exec(line.slice(stem.length))
    if (match) return cleanIdentityValue(match[1], max)
  }
  return null
}

/** `Stem the rest of the line`, or null. */
function trailing(block: readonly string[], stem: string, max: number): string | null {
  for (const line of block) {
    if (line.startsWith(stem)) return cleanIdentityValue(line.slice(stem.length), max)
  }
  return null
}
