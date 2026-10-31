import { useCallback, useEffect, useState } from 'react'
import { Notice, SectionHead } from '../controls'
import { errorText, type SectionProps } from '../settings-bridge'
import { toSetupSnapshot, type SetupSnapshot } from '../setup-status'
import './SetupSection.css'

/**
 * Setup — the one screen that answers "is my machine ready?".
 *
 * Everything on it is discovered, never declared: the tool rows come from
 * `prerequisites.ts` and `copilot.ts`, the hook blocks from `hooks.ts`, and the
 * endpoint line from `hook-server.ts`. This file adds no facts of its own, and
 * that is the point — a settings page that hardcodes "Claude Code ✓" is a page
 * that lies the first time somebody uninstalls something.
 *
 * Two decisions worth keeping:
 *
 *  - A missing tool shows the literal probe (`copilot not found`) as well as the
 *    verdict. "Not found" invites an argument; the command we ran and what the
 *    shell answered ends it, and the user can paste the same line themselves.
 *  - The event names are the provider's own. Claude fires PreToolUse and
 *    PostToolUse, Gemini fires BeforeTool and AfterTool, and Codex has five
 *    events where Claude has ten. One invented list on this screen would be a
 *    list that matches nobody's CLI.
 */

/*
 * `TOOL_MARK`, `ToolRow`, `AGENT_TOOL_IDS`, `MOVED_TOOL_IDS` and
 * `showsOtherTools` were here, and the **Other tools** disclosure they drew is
 * gone rather than guarded better.
 *
 * The disclosure was meant to hold "what is left after the agents and after
 * Copilot: git, and the GitHub CLI". But the probe behind this pane answers for
 * `SETUP_TOOL_IDS` (`src/main/setup.ts`) — the three agents plus Copilot — and
 * this pane subtracted exactly those four, so the list was empty on every
 * machine that has ever existed. What survived was only the probe-pending
 * branch: a button with ghost rows that appeared on every visit and vanished
 * the moment the probe answered. Asad asked for a button with nothing in it to
 * be removed — *"if there is no tool, why we have this button?"* — and what he
 * got instead was one that appears and disappears. So the whole control is
 * gone, pending branch included: a disclosure that cannot ever hold a row has
 * no honest moment to be drawn in.
 *
 * If the probe one day reports a tool that is not an agent and not Copilot,
 * that is the day a list belongs here again — drawn from that real answer, not
 * ahead of it.
 */

/**
 * Setup is a pair of groups inside Agents now, not a rail entry.
 *
 *   > "This also needs to be reorganized properly at some better place instead
 *   > of here as setup a separate page. Maybe here we can bring a section of
 *   > setting up CLI's, accounts, agents, everything and choosing ones."
 *
 * `head` is what makes that possible without moving a line of the code below:
 * off, the pane draws its groups straight into whatever is already on screen.
 * Kept as a flag rather than deleted so this can still be rendered on its own
 * in a test.
 */
export function SetupSection({ bridge, head = true }: SectionProps & { head?: boolean }) {
  /*
   * `sectionMeta('setup')` resolves to Agents now, so the heading is written
   * here: what this half of the pane is called is "Setup", whatever the rail
   * calls the pane that contains it.
   */
  const meta = { label: 'Setup', blurb: 'What this app needs on your machine, and what it found.' }
  /*
   * `useFeatures` was read here to gate the hook group behind the `hooks`
   * feature. The group is gone — see the note at the bottom of this file — and
   * with it the only thing on this pane that a feature owned, so the hook is
   * gone too rather than left as an unread subscription.
   */
  const [snapshot, setSnapshot] = useState<SetupSnapshot | null>(null)
  // `checking` was a third piece of state here. Its only reader was the
  // probe-pending branch of the Other tools disclosure, which is gone — see the
  // note above — and a flag nothing reads is a flag that drifts.
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(() => {
    if (!bridge.setupStatus) return
    setError(null)
    void bridge.setupStatus().then(
      (raw) => {
        const next = toSetupSnapshot(raw)
        setSnapshot(next)
        if (!next) setError('The setup check answered with something this build cannot read.')
      },
      (cause: unknown) => {
        setError(errorText(cause, 'Could not check what is installed on this machine.'))
      },
    )
  }, [bridge])

  useEffect(load, [load])

  /*
   * `run` was here: the one write this pane could make, which was installing,
   * repairing or removing an agent's hooks. It moved with the group that drew
   * the buttons — this pane probes and reports now, and writes nothing.
   */

  if (!bridge.setupStatus) {
    return (
      <>
        {head && <SectionHead title={meta.label} blurb={meta.blurb} />}
        <Notice tone="warn">
          This window was opened without the setup check, so there is nothing for this pane to
          read.
        </Notice>
      </>
    )
  }

  return (
    <>
      {head && <SectionHead title={meta.label} blurb={meta.blurb} />}

      {error && <Notice tone="error">{error}</Notice>}

      {snapshot && !snapshot.canRunSessions && (
        <Notice tone="warn">
          {snapshot.needsLogin
            ? 'An agent CLI is installed but none of them is signed in, so a new session would open at a login prompt.'
            : 'No agent CLI was found, so a new session can only run a plain shell.'}
        </Notice>
      )}

      {/*
        Two blocks used to follow. One said "the agent CLIs are in Agents" and
        offered a button to go there — gone when the two panes merged. The other
        was the **Other tools** disclosure, gone 2026-08-22: the probe answers
        only for the agents and Copilot, all of which belong to other panes, so
        the list under it was empty on every machine and the control only ever
        appeared while the probe was out and vanished when it answered. See the
        note where `showsOtherTools` used to be, above.
      */}

      {/*
        The "Session hooks" group was here, and it is gone because it was the
        second copy of a page.

        It drew one block per agent — the agent's name, its settings-file path,
        its event list, and Install / Repair / Remove — from `hooks.ts`. The
        sidebar's own page draws the same three agents from the same call, with
        the same three buttons. Two copies of one control in one app, and they
        met on this screen, directly under a list of the same three agent names:

          > *"Do you think hooks and CLIs are the same thing? Because this is a
          > hooks folder and we see CLI here."*

        A fair question, and the honest answer was that one of them should not
        have existed. The page survives rather than this block, for two reasons:
        it is a place a person can be sent to and linked to, and Settings is a
        dialog over whatever you were doing — a control you press once per
        machine does not belong in the same pane as the switches you flip while
        working. The page now leads by saying what it is *for*, which is the
        other half of answering him. See `components/HooksPanel.tsx`.

        `HookBlock`, `hookActions`, `eventState`, `hookSummary` and
        `toHookWriteOutcome` are still exercised by `SetupSection.test.tsx` and
        are the shared vocabulary `setup-status.ts` exists to hold; nothing here
        is orphaned by this deletion except the block itself.
      */}
    </>
  )
}
