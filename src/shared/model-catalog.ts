/**
 * Which models a session can be switched to — asked of the CLI instead of kept
 * in a table here.
 *
 * ## Why this file exists
 *
 * The model picker used to be five hand-written rows: `Default`, `Opus`,
 * `Fable`, `Sonnet`, `Haiku`. Watching the app, Asad said what is wrong with
 * that, and it is not that somebody chose badly:
 *
 *   > *"They are just very few, not all of them. And Opus 4 should be Opus 5.
 *   > Opus 4-point-something is available. They should be listed here also, not
 *   > just few of your choice. There are more models — see Sonnet 4.6, to Fable
 *   > 5 — so we should have all of them."*
 *
 * A hand-kept list has one failure mode and it is guaranteed: it is right on the
 * day it is written and wrong from the next model release onwards. Worse, it
 * carried no version at all — a row saying `Opus` says nothing about whether
 * this account is on Opus 5 or Opus 4.8, which is exactly the reading he
 * objected to.
 *
 * So the list is **read out of the CLI's own picker**. `/model`, submitted at
 * the session, draws this:
 *
 *     Select model
 *     Switch between Claude models. Your pick becomes the default for new
 *     sessions. For other/previous model names, specify with --model.
 *       1. Default (recommended)  Opus 5 with 1M context · Best for everyday, complex tasks
 *       2. Opus (1M context)      Opus 5 with 1M context · Best for everyday, complex tasks
 *       3. Fable                  Fable 5 · Most capable for your hardest and longest-running tasks
 *       4. Sonnet                 Sonnet 5 · Efficient for routine tasks
 *       5. Haiku                  Haiku 4.5 · Fastest for quick answers
 *     ❯ 6. Opus ✔                 Opus 5 · Best for everyday, complex tasks
 *       ✦ Ultracode effort ←/→ to adjust
 *       Use /fast to turn on Fast mode (Opus 5).
 *       Enter to set as default · s to use this session only · Esc to cancel
 *
 * Captured verbatim from `claude 2.1.234` on this machine. Every fact the app
 * needs is in it and none of it is a guess: the rows, the resolved model behind
 * each row, which one is in force (the ✔), and which one the account treats as
 * its default (the `(recommended)` marker). It is also the *account's* list —
 * an organisation that restricts models restricts this picker, so a list read
 * here can never offer something the account cannot use, which a table in this
 * repo absolutely can.
 *
 * ## What is still written down here, and why that is not the same mistake
 *
 * Two things.
 *
 * {@link FALLBACK_MODELS} is that same capture, frozen, for the moment before
 * discovery has happened or when the session is too busy to be asked. It is a
 * fallback and it is labelled as one; the live read replaces it whole.
 *
 * {@link PREVIOUS_MODELS} is the part the picker deliberately does not show.
 * The picker's own subtitle says *"For other/previous model names, specify with
 * --model"*, and driving the real CLI showed that `/model` accepts them too —
 * `/model claude-sonnet-4-6` answered `Set model to Sonnet 4.6 and saved as
 * your default for new sessions`, and so did `claude-opus-4-8`, `claude-opus-4-5`
 * and `claude-haiku-4-5`. Those are the "Sonnet 4.6" and "Opus 4.x" he asked
 * for by name. Each id in that list was typed at the binary and accepted; none
 * was copied out of documentation. An account that is not entitled to one gets
 * the CLI's own refusal — `Mythos 5 isn't available for your account yet` is the
 * wording, also captured live — which is surfaced verbatim rather than guessed
 * at in advance.
 */

/** One row of the CLI's model picker. */
export interface ModelRow {
  /**
   * What to type after `/model` to choose this row.
   *
   * Derived from the row's own name rather than looked up, so a model released
   * after this build still gets a working alias. See {@link aliasForRow}.
   */
  alias: string
  /** The row's name as the picker prints it — `Sonnet`, `Opus (1M context)`. */
  name: string
  /** The model the row resolves to, alone — `Sonnet 5`, `Opus 4.8`. */
  model: string
  /** What the picker says it is for, or empty when the row carries no note. */
  note: string
  /** True on the row the picker ticks: the model in force right now. */
  current: boolean
  /** True on the row the CLI marks `(recommended)` — the account's own default. */
  recommended: boolean
}

/**
 * The picker as it stood on `claude 2.1.234`, for use before a live read.
 *
 * The `Default (recommended)` row of the real capture is **not** here, and its
 * absence is a decision rather than an oversight:
 *
 *   > *"Unknown should not be there, it should be already selected. Default, I
 *   > think, is nothing, because in Claude you don't see anything default — it
 *   > just says automatically unselected ones, but not as a separate choice."*
 *
 * He is describing a list where every row is a model and one of them is ticked.
 * `Default` is not a model; it is a pointer at whichever row the account already
 * prefers, and offering it alongside the thing it points at gives two rows that
 * do the same thing and disagree about which is selected. So the pointer is
 * dropped and what it points at is marked instead — {@link ModelRow.recommended}
 * carries it, and the UI prints it as a note on the row rather than as a choice.
 *
 * `Opus Plan` is here and is not in the mac capture above, because it is in the
 * *Windows* capture in `agent-controls.conpty.json` and `/model opusplan` was
 * accepted when driven here: `Set model to Opus in plan mode, else Sonnet`. It
 * is a row the picker shows on some accounts and not others, which is precisely
 * why the live read exists.
 */
export const FALLBACK_MODELS: readonly ModelRow[] = [
  { alias: 'opus[1m]', name: 'Opus (1M context)', model: 'Opus 5 with 1M context', note: 'Best for everyday, complex tasks', current: false, recommended: true },
  { alias: 'opus', name: 'Opus', model: 'Opus 5', note: 'Best for everyday, complex tasks', current: false, recommended: false },
  { alias: 'fable', name: 'Fable', model: 'Fable 5', note: 'Most capable for your hardest and longest-running tasks', current: false, recommended: false },
  { alias: 'sonnet', name: 'Sonnet', model: 'Sonnet 5', note: 'Efficient for routine tasks', current: false, recommended: false },
  { alias: 'haiku', name: 'Haiku', model: 'Haiku 4.5', note: 'Fastest for quick answers', current: false, recommended: false },
  { alias: 'opusplan', name: 'Opus Plan', model: 'Opus in plan mode, else Sonnet', note: '', current: false, recommended: false },
]

/**
 * Older models the picker hides but `/model` still accepts.
 *
 * Every line below is a command that was typed at `claude 2.1.234` on this
 * machine and the reply it gave, in that order. Nothing here is from a
 * changelog.
 *
 *   `/model claude-opus-4-8`   → `Set model to Opus 4.8 and saved as your default…`
 *   `/model claude-opus-4-5`   → `Set model to Opus 4.5 and saved as your default…`
 *   `/model claude-sonnet-4-6` → `Set model to Sonnet 4.6 and saved as your default…`
 *
 * `claude-sonnet-5` and `claude-haiku-4-5` were accepted too and are left out,
 * because the picker's `Sonnet` and `Haiku` rows already resolve to exactly
 * those two — a second row landing on the same model is the duplication the
 * `Default` row was dropped for. `model-catalog.test.ts` pins that no model
 * appears in both lists, so this stays true when somebody adds to either.
 *
 * These are shown under their own heading rather than mixed into the picker's
 * rows, because they are a different kind of claim. A picker row is what this
 * account is offered *today*; these are names the CLI will still parse, and an
 * account with no entitlement gets a refusal at the moment it is chosen. Mixing
 * them would make one list where half the entries are guaranteed and half are
 * not, with nothing on screen saying which is which.
 */
export const PREVIOUS_MODELS: readonly ModelRow[] = [
  { alias: 'claude-opus-4-8', name: 'Opus 4.8', model: 'Opus 4.8', note: '', current: false, recommended: false },
  { alias: 'claude-opus-4-5', name: 'Opus 4.5', model: 'Opus 4.5', note: '', current: false, recommended: false },
  { alias: 'claude-sonnet-4-6', name: 'Sonnet 4.6', model: 'Sonnet 4.6', note: '', current: false, recommended: false },
]

/**
 * The heading the picker prints, and the only thing that identifies it.
 *
 * Anchored to the whole line. `Select model` also appears inside the paragraph
 * of an answer often enough to matter, and a loose match would have this app
 * reading a numbered list out of somebody's chat reply and offering it as the
 * model catalogue.
 */
const PICKER_HEADING = /^Select model$/i

/**
 * A row of the picker: an optional cursor, a number, a name, two or more
 * spaces, and the description.
 *
 * The two-space gap is the separator the CLI actually uses — it pads the name
 * column out so the descriptions line up — and it is what makes the split
 * unambiguous even for a name that contains a space of its own, which
 * `Opus (1M context)` and `Opus Plan` both do.
 */
const PICKER_ROW = /^\s*[❯>]?\s*(\d+)\.\s+(\S.*?)\s{2,}(\S.*?)\s*$/

/**
 * The tick, in the three shapes a terminal draws it.
 *
 * `✔` is what macOS shows. The Windows capture in `agent-controls.conpty.json`
 * shows `√` instead, because ConPTY renders the heavy check mark through the
 * OEM code page. `✓` is here because it is the same character one weight
 * lighter and costs nothing to accept.
 */
const TICK = /[✔✓√]/

/**
 * What to type after `/model` for a row, worked out from the row's own name.
 *
 * Derivation rather than a lookup table, because a lookup table is the thing
 * this file exists to stop being. The rules are three, and each was checked
 * against the real binary:
 *
 *  - `Opus (1M context)` → `opus[1m]`. The CLI's long-context suffix is the
 *    bracketed `[1m]` tag it also uses in transcripts, and `/model opus[1m]`
 *    answered `Set model to Opus 5 (1M context) and saved as your default for
 *    new sessions`.
 *  - `(recommended)` is a marker, not part of the name, so it comes off before
 *    anything else. What is left of `Default (recommended)` is `default`.
 *  - Everything else is the name lowercased with its spaces removed:
 *    `Sonnet` → `sonnet`, `Opus Plan` → `opusplan`. Both were accepted;
 *    `opusplan` answered `Set model to Opus in plan mode, else Sonnet`.
 *
 * A name this produces a nonsense alias for is not a disaster and is not
 * silently swallowed either: `/model <nonsense>` answers `Model 'x' not found`,
 * which `readCommandError` already recognises and shows verbatim. That is a
 * better failure than refusing to offer a model that has just been released.
 */
export function aliasForRow(name: string): string {
  const bare = name
    .replace(TICK, '')
    .replace(/\((?:recommended|default)\)/gi, '')
    .trim()
  const long = /\(1m context\)$/i.test(bare)
  const base = bare
    .replace(/\(1m context\)$/i, '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, '')
  return long ? `${base}[1m]` : base
}

/** Non-empty lines, oldest first. Mirrors the helper in `agent-controls.ts`. */
function lines(screen: string): string[] {
  return screen
    .split('\n')
    .map((line) => line.replace(/\s+$/, ''))
    .filter((line) => line.trim() !== '')
}

/**
 * The picker's rows, or null when the picker is not on screen.
 *
 * Null and empty are different answers and the caller depends on it: null means
 * "this is not the picker, keep waiting", and that is what makes it safe to
 * poll a screen until the dialog appears rather than guessing at a delay.
 *
 * The heading has to be present *and* at least two rows have to parse. The
 * heading alone matches the moment the dialog is half-drawn, when the first row
 * has painted and the rest have not, and a catalogue built from that would be a
 * one-item menu that looked deliberate.
 */
export function readModelPicker(screen: string): ModelRow[] | null {
  const all = lines(screen)
  if (!all.some((line) => PICKER_HEADING.test(line.trim()))) return null

  const rows: ModelRow[] = []
  for (const line of all) {
    const match = PICKER_ROW.exec(line)
    if (!match) continue
    const rawName = match[2]
    const detail = match[3]
    const name = rawName.replace(TICK, '').replace(/\s+/g, ' ').trim()
    if (name === '') continue
    // The description is `<model> · <what it is for>` where a note exists, and
    // just `<model>` where it does not. Splitting on the first middle dot keeps
    // the model name available on its own, which is the half that answers "am I
    // on Opus 5 or Opus 4.8" — the question that started all of this.
    const dot = detail.indexOf('·')
    const model = (dot === -1 ? detail : detail.slice(0, dot)).trim()
    const note = dot === -1 ? '' : detail.slice(dot + 1).trim()
    rows.push({
      alias: aliasForRow(rawName),
      name,
      model,
      note,
      current: TICK.test(rawName),
      recommended: /\(recommended\)/i.test(rawName),
    })
  }
  return rows.length >= 2 ? rows : null
}

/**
 * The catalogue as the app should show it: the pointer row folded into the row
 * it points at.
 *
 * `Default (recommended)` and the row it resolves to are the same model twice —
 * in the capture above, both say `Opus 5 with 1M context`. Showing both is what
 * produced two rows disagreeing about which is selected. So the `Default` row is
 * removed and its `recommended` flag is moved onto whichever row resolves to the
 * same model, which is the fact it was carrying that nothing else does.
 *
 * If nothing resolves to the same model — an account whose default is a model
 * the picker does not otherwise list — the row stays, under its resolved name
 * rather than the word "Default", because dropping it would hide a model that is
 * genuinely on offer.
 */
export function foldDefaultRow(rows: readonly ModelRow[]): ModelRow[] {
  const pointer = rows.find((row) => aliasForRow(row.name) === 'default')
  if (!pointer) return [...rows]

  const twin = rows.find((row) => row !== pointer && row.model === pointer.model)
  if (!twin) {
    // Keep it, but stop calling it "Default": the name has to say which model it
    // is, or the list has a row whose label answers nothing.
    return rows.map((row) => (row === pointer ? { ...row, name: row.model } : row))
  }

  return rows
    .filter((row) => row !== pointer)
    .map((row) =>
      row === twin
        ? { ...row, recommended: true, current: row.current || pointer.current }
        : row,
    )
}

/**
 * Whether a value is safe to type after `/model `.
 *
 * Not an allow-list of names. The old check was one — five aliases, rejecting
 * anything else — and it is the same staleness as the menu it guarded: a model
 * released tomorrow is refused by this app before the CLI ever sees it, with a
 * message blaming the model rather than the list.
 *
 * What actually needs guarding is the *shape*, because this string is written
 * into somebody's terminal. A value with a space in it becomes a second
 * argument; one with a newline in it submits a line nobody wrote. Neither can
 * get through this, and everything else is left to the CLI, which answers
 * `Model 'x' not found` and is shown saying so.
 */
export function isTypeableModelValue(value: string): boolean {
  return /^[a-z0-9][a-z0-9.-]*(\[1m\])?$/i.test(value)
}
