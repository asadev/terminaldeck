import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { WINDOWS_SETUP_NEEDED } from './appcontainer'

/**
 * The Windows one-time grant, and the sentence the app says about it.
 *
 * ## The failure this exists to stop
 *
 * `tools.ts` builds the whole of the Windows grant. `plannedToolGrant` says what
 * it would cover without doing it, `elevatedGrantCommand` raises Windows' own
 * consent dialog naming the launcher, `establishToolGrant` runs it and writes
 * the record `confinementKind` then reads. All of it is tested. **None of it is
 * called by the app**, which is why `confinementKind('win32')` answers `'none'`
 * on every Windows machine, every device session runs unconfined, and the
 * copilot — which refuses outright without a boundary — cannot be started on
 * Windows at all.
 *
 * That is a gap in the feature and it is tracked as one. What it must not also
 * be is a gap in what the app *says*: the sentence a Windows user reads used to
 * promise "a one-time permission, granted once with an administrator prompt",
 * which reads as a prompt that is coming. Somebody waiting for that dialog is
 * waiting for a thing this build never raises, and they have no way to find that
 * out — the grant screen, the copilot page and `remote/session-create.ts` all
 * quote this one constant.
 *
 * ## Why it is checked this way round
 *
 * This is not a test of the wording for its own sake. It is a test that the
 * wording and the wiring agree, in whichever direction they happen to be:
 *
 *   - nothing calls the grant  → the sentence must not promise a prompt;
 *   - something calls the grant → the sentence must say where the prompt is,
 *     because at that point "this build does not offer that step yet" is the
 *     lie instead.
 *
 * So the day somebody wires it, this fails and sends them to the constant.
 * A test that only pinned today's wording would pass through that change and
 * leave the app telling a Windows user a feature is missing while it sits one
 * click away — which is the exact failure `WINDOWS_UNCONFINED_REASON`'s own
 * comment says the split between these two sentences exists to avoid.
 */

const SRC = resolve(__dirname, '..', '..')

/** Where the grant lives. Its own definitions and its own tests are not callers. */
const DEFINITION = resolve(__dirname, 'tools.ts')

const isTest = (path: string): boolean => /\.(test|spec)\.tsx?$/.test(path)

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name)
    if (statSync(full).isDirectory()) walk(full, out)
    else if (/\.tsx?$/.test(full) && !isTest(full)) out.push(full)
  }
  return out
}

/**
 * Comments removed, so that writing *about* the grant is not mistaken for
 * calling it.
 *
 * This is not fussiness: the constant's own doc comment names
 * `establishToolGrant` in a `{@link}`, which is exactly the explanation a reader
 * arriving at a confusing sentence needs, and a naive text search read that as
 * the feature having been wired. A check that punishes the explanation for
 * mentioning the thing it explains would be quietly deleted within a week.
 *
 * Block comments before line comments, because `//` inside a block comment is
 * ordinary prose and stripping it first would end the block early. Neither
 * pattern understands a `//` inside a string literal, which is fine here — the
 * only thing being asked afterwards is whether one identifier survives.
 */
const withoutComments = (source: string): string =>
  source.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ')

/**
 * Every file that reaches `establishToolGrant` and is not where it is written.
 *
 * A re-export counts as a caller for this purpose and that is deliberate: the
 * only reason to re-export it from `confine/index.ts` is for something outside
 * the folder to call, so the re-export appearing is the same signal one step
 * early. Better to fail then, while the wording is still easy to change, than
 * after the button ships.
 */
function callers(): string[] {
  return walk(SRC)
    .filter((file) => file !== DEFINITION)
    .filter((file) => withoutComments(readFileSync(file, 'utf8')).includes('establishToolGrant'))
    .map((file) => relative(SRC, file))
}

describe('the Windows one-time grant says what is actually true of this build', () => {
  it('is not reachable from anywhere in the app', () => {
    /*
     * Stated as its own assertion rather than folded into the wording check
     * below, because the two failures need different messages. This one is the
     * good news — somebody has wired it — and the fix is to update the sentence,
     * not to unwire anything.
     */
    expect(
      callers(),
      'Something now reaches establishToolGrant. That is the feature arriving, not a ' +
        'regression — go and rewrite WINDOWS_SETUP_NEEDED in appcontainer.ts so it names the ' +
        'prompt again, then update this test to expect a caller.',
    ).toEqual([])
  })

  it('does not promise an administrator prompt while nothing can raise one', () => {
    // The words that make a person wait for a dialog. Checked as a phrase rather
    // than as the whole sentence so that ordinary rewording does not fail here
    // and only the promise does.
    expect(WINDOWS_SETUP_NEEDED).not.toMatch(/administrator prompt/i)
    expect(WINDOWS_SETUP_NEEDED).not.toMatch(/granted once with/i)
  })

  it('says instead that this build does not offer the step', () => {
    // The replacement has to carry three things: that the mechanism is real,
    // that the app does not offer it yet, and what that means for a session
    // right now. A blank or truncated constant would pass a `not.toMatch`.
    expect(WINDOWS_SETUP_NEEDED).toMatch(/AppContainer/)
    expect(WINDOWS_SETUP_NEEDED).toMatch(/does not offer that step yet/i)
    expect(WINDOWS_SETUP_NEEDED).toMatch(/runs unconfined/i)
  })

  it('still keeps the WSL caveat in its own sentence', () => {
    // A session inside a WSL folder is a Linux process, held by the Linux
    // mechanism. Losing this line while editing the rest would tell a WSL user
    // their session is unconfined when it is not.
    expect(WINDOWS_SETUP_NEEDED).toMatch(/WSL folder is a Linux process/)
  })
})
