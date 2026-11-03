import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The window's bar, over another machine's copilot.
 *
 * ## The defect this is written against
 *
 * The copilot page has had a machine switch at the top of it since 2026-08-20,
 * and `App.tsx` — which draws the bar above that page — knew nothing about it.
 * There was no `onMachine` prop on `CopilotView` and nothing threading the
 * choice up. So with a paired PC chosen, the bar over that PC's conversation
 * went on describing the copilot on **this** Mac: its account chip, its model
 * and effort, and a Restart wired to `useCopilot`.
 *
 * Restart is the sharp one. It is `stop` followed by `ensure`, it ends a
 * conversation, and drawn there it ended the conversation on the computer that
 * was *not* on screen. That is the class of defect this bar has spent the week
 * removing — *"a control that looks right and acts on the wrong computer"* — and
 * it is a lost conversation rather than a cosmetic slip.
 *
 * ## Why this is a source read rather than a render
 *
 * There is no DOM in this project's test setup, deliberately — `wiring.test.ts`
 * states the argument at length and guards the same class of seam the same way.
 * Every fact below is a prop or a condition in one file, and the failure mode is
 * a condition quietly going missing, which is exactly what a source read catches
 * and a passing unit test on either side does not.
 */

const APP = readFileSync(join(__dirname, '..', 'App.tsx'), 'utf8')

/**
 * The opening tag of `<Name ... >`, brace-aware so a prop whose value is an
 * inline arrow does not end the scan early. The same reader `wiring.test.ts`
 * uses, and the same warning applies: a `>` inside a comment between props
 * truncates the tag.
 */
function openingTag(source: string, name: string): string | null {
  const start = source.search(new RegExp(`<${name}[\\s/>]`))
  if (start < 0) return null
  let depth = 0
  for (let i = start; i < source.length; i++) {
    const c = source[i]
    if (c === '{') depth++
    else if (c === '}') depth--
    else if (c === '>' && depth === 0) return source.slice(start, i + 1)
  }
  return null
}

describe('the bar over the copilot page', () => {
  it('is told which machine that page is about', () => {
    // The seam itself. Without this prop nothing below can be true, and nothing
    // in the type checker notices: every prop involved is optional, which is
    // what lets a component render its wrong-but-plausible state instead of
    // failing.
    expect(openingTag(APP, 'CopilotView')).toContain('onMachine={onCopilotMachine}')
  })

  it('keeps that report from re-rendering the window on every pass', () => {
    // `CopilotView` reports on mount and on every change. An inline arrow here
    // would be a new function each render and a fresh object stored for an
    // unchanged machine.
    expect(APP).toContain('const onCopilotMachine = useCallback(')
  })

  it('withdraws Restart while the page is another machine’s', () => {
    // Not relabelled and not re-pointed: there is no restart verb on the wire
    // for a copilot anywhere else, so the honest bar has no button. Silently
    // absent, exactly as the account chip is over a remote session.
    const restart = /\{headingTab\?\.isCopilot &&[^?]*\?\s*\(\s*<CopilotRestart/.exec(APP)?.[0] ?? ''
    expect(restart, 'the Restart gate has changed shape').not.toBe('')
    expect(restart).toContain('copilotMachine === null')
  })

  it('names the machine, and drops the facts that belong to the local copilot', () => {
    // Which computer is on screen is the fact that must never go missing, so the
    // machine's name takes the subtitle slot a remote session's machine already
    // uses. The folder would open this Mac's copilot directory and the account
    // is not a fact any frame carries, so both are absent.
    const branch =
      /: headingTab\?\.isCopilot && copilotMachine !== null[\s\S]*?\n {8}\}/.exec(APP)?.[0] ?? ''
    expect(branch, 'the copilot-elsewhere heading branch is gone').not.toBe('')
    expect(branch).toContain('subtitle: `on ${copilotMachine.name}`')
    expect(branch).toContain('folder: null')
    expect(branch).toContain('account: null')
  })

  it('does not hand the control cluster the local copilot’s session', () => {
    /*
     * `barControls` is what the model, effort and fast-mode chips read *and
     * write*. Left resolving the copilot's tab, those chips would have been
     * setting the model of a session on this Mac from a bar drawn over a PC.
     *
     * The guard used to live on `const headingSession`, which was the bar's own
     * lookup. That lookup became `controlsFor` on 2026-08-21 — one function that
     * answers for a local session, a session on a paired machine and a terminal
     * on a server, so that a *pane* can have the same answer — and this guard
     * came with it, to the one line that was still reading it.
     */
    const controls = /const barControls =[\s\S]*?controlsFor\(barTabId\)/.exec(APP)?.[0] ?? ''
    expect(controls, 'barControls has changed shape').not.toBe('')
    expect(controls).toContain('headingTab?.isCopilot === true && copilotMachine !== null')
  })
})
