import { useCallback, useEffect, useState } from 'react'
import { LinkOut, Notice, SectionHead, ToolVersion } from '../controls'
import { HoverNote } from '../../components/HoverNote'
import { errorText, type SectionProps } from '../settings-bridge'
import { toSetupSnapshot, TOOL_STATE_LABEL, type SetupSnapshot } from '../setup-status'
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

/**
 * The glyph on a tool row, in the same vocabulary the event rows use.
 *
 * `installed-not-authed` gets `!` rather than `✕` on purpose: that tool *is* on
 * the machine, and giving it the same cross as one that is absent left colour —
 * amber against red — as the only thing separating "you have it, sign in" from
 * "you do not have it". `SetupSection.css` has always coloured those two states
 * differently; this is the half of that distinction that survives a screenshot
 * in greyscale, or a reader who cannot tell the two hues apart.
 */
export const TOOL_MARK: Record<SetupSnapshot['tools'][number]['state'], string> = {
  ready: '✓',
  'installed-not-authed': '!',
  missing: '✕',
  unknown: '?',
}

function ToolRow({ tool }: { tool: SetupSnapshot['tools'][number] }) {
  const ok = tool.state === 'ready'
  return (
    <li className="settings-tool" data-state={tool.state}>
      <span className="setup-mark" data-state={tool.state} aria-hidden="true">
        {TOOL_MARK[tool.state]}
      </span>
      <span className="settings-tool-main">
        <span className="settings-tool-name">
          {tool.label}
          <ToolVersion tool={tool} />
          {/* What this app uses it for, and the caveat when there is one — the
              two lines that used to stand under the name. A caveat about a tool
              that is not even here is noise, so it is only joined on for one
              that is. */}
          <HoverNote label={tool.label}>
            {tool.note && tool.state !== 'missing' ? `${tool.purpose}. ${tool.note}` : tool.purpose}
          </HoverNote>
        </span>
        {/*
          `purpose` was a standing line under every name — "Read branches and
          diffs for the source control panel", "Read issues and pull requests
          without a token of your own". True of both, and a description of what
          a tool is for rather than anything about the state of this machine:

            > *"Why do we have all of this full list? Why not just one drop-down
            > to look at it if we need it? Why do, if I have ten like this, how
            > I will read all of them?"*

          It is behind the ⓘ on the name now, which is where a fact that is
          occasionally wanted and never urgent goes on this pane. What is left on
          the row is what is *wrong* with it and how to fix that, which is not a
          description.
        */}
        {!ok && tool.remedy && <span className="settings-tool-note">{tool.remedy}</span>}
        {tool.probe && (
          <code className="setup-probe" title={tool.probe.command}>
            {tool.probe.line}
          </code>
        )}
      </span>
      <span className="settings-tool-state">{TOOL_STATE_LABEL[tool.state]}</span>
      {/* Only for a tool that is not here. Offering "Install" beside "Sign in
          needed" sends somebody to a download page for something they already
          have — the remedy on the row is the instruction that fits. */}
      {tool.state === 'missing' && tool.url && <LinkOut href={tool.url}>Install</LinkOut>}
    </li>
  )
}

/*
   `HookBlock` was here, and it is gone with the group it drew.

   It rendered one agent's hook state — its name, its settings-file path, its
   event list and the Install / Repair / Remove trio — and the sidebar's
   Session updates page renders the same three agents from the same `hooks.ts`
   call with the same three buttons. See the note where the group used to be,
   at the bottom of this file, for why the page is the copy that survived.
*/

/**
 * The agent CLIs, which Settings → Coding AI already lists in full.
 *
 * The same three rows were drawn twice in one window, under two different
 * headings — "Coding tools" here and "What is installed" there — with the same
 * skeleton, the same versions and the same "Checking… / Check again" button
 * under each. Two copies of one fact in one dialog is worse than either copy
 * alone: a reader who notices has to work out which one is stale, and the
 * answer (neither) is not visible from the screen.
 *
 * Agents keeps them, because that section is *about* them and carries the
 * profile each one runs as. Setup keeps everything else it probes — git and the
 * GitHub CLI — and points at Agents for these.
 */
export const AGENT_TOOL_IDS: readonly string[] = ['claude', 'codex', 'gemini']

/**
 * Also not on this pane: GitHub Copilot, which moved to the GitHub page.
 *
 *   > *"we will move this GitHub Copilot from here to the main page of GitHub,
 *   > because we have already a page specifically for GitHub, so don't need to
 *   > keep it inside the settings."*
 *
 * He is right about where it belongs, and the row was an odd one out here for a
 * reason this list makes plain: everything else Setup probes is something the
 * app *uses* — git, and the GitHub CLI it shells out to. Copilot it merely
 * *finds*; nothing in this build starts a Copilot session or writes a Copilot
 * hook. So the one place that fact is worth reading is the page about GitHub,
 * and it is drawn there now by `components/GitHubPanel.tsx`.
 *
 * Nothing is left behind here: this id is filtered out of `tools` below, so
 * there is no row, no heading and no "moved to…" pointer — a cross-reference is
 * the thing that made Setup and Agents read as two halves of one screen, and
 * one is not being added back on its way out.
 */
export const MOVED_TOOL_IDS: readonly string[] = ['copilot']

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
  const [checking, setChecking] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(() => {
    if (!bridge.setupStatus) return
    setChecking(true)
    setError(null)
    void bridge.setupStatus().then(
      (raw) => {
        const next = toSetupSnapshot(raw)
        setSnapshot(next)
        setChecking(false)
        if (!next) setError('The setup check answered with something this build cannot read.')
      },
      (cause: unknown) => {
        setChecking(false)
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

  // Minus the agents and minus Copilot — see `AGENT_TOOL_IDS` and
  // `MOVED_TOOL_IDS`. What is left is git and the GitHub CLI, which is what
  // "what this app needs on your machine" means once the agents have a section
  // of their own and Copilot lives on the GitHub page.
  const tools = (snapshot?.tools ?? []).filter(
    (tool) => !AGENT_TOOL_IDS.includes(tool.id) && !MOVED_TOOL_IDS.includes(tool.id),
  )

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
        The block that used to be here said "the agent CLIs are in Agents" and
        offered a button to go there. They are on this page now, above this
        group, so the sentence would be pointing at itself. That cross-reference
        is the clearest single piece of evidence that these two panes were one
        subject: it existed only because the merge had not happened yet.
      */}

      {/* What is left after the agents and after Copilot: git, and the GitHub
          CLI this app shells out to. Both are things the app *uses*, which is
          what makes this the pane they belong on — see `MOVED_TOOL_IDS`.

          Behind a disclosure rather than standing open, and it is the sixth and
          last of the blocks that made this pane read as three pages stacked. It
          is a list of things that are working, which is the definition of a
          thing you look at when you go looking:

            > *"Also here again, it is too big thing to give someone to read.
            > Why do we have all of this full list? Why not just one drop-down
            > to look at it if we need it?"*

          The same `<details>` the Add-agent menu is, for the same two reasons —
          it is real markup a `renderToStaticMarkup` test can read, and it costs
          the closed pane nothing. */}
      <details className="settings-addmenu">
        <summary>Other tools</summary>
        <ul className="settings-tools">
          {tools.map((tool) => (
            <ToolRow key={tool.id} tool={tool} />
          ))}
          {/*
            One placeholder, shaped like the answer.

            There used to be two, stacked: a full-width box reading "Looking at
            your machine…" with a separate "Checking…" chip directly under it,
            both saying the same thing about the same read. The button already
            says the work is in flight — that is what a disabled button with a
            present-tense label is for — so the list says it by *looking* like
            the list that is coming, which also stops the panel jumping when
            three rows land at once.
          */}
          {tools.length === 0 &&
            (checking ? (
              // Two rows, because two is what lands: git and the GitHub CLI.
              // The placeholder has to keep being shaped like the answer, or the
              // panel jumps when the probe returns.
              [0, 1].map((n) => (
                <li key={n} className="settings-tool settings-tool-ghost" aria-hidden="true">
                  <span className="settings-tool-main">
                    <span className="settings-ghost-line" />
                  </span>
                  <span className="settings-ghost-line settings-ghost-short" />
                </li>
              ))
            ) : (
              <li className="settings-tool" data-state="unknown">
                <span className="settings-tool-main">
                  <span className="settings-tool-note">Nothing reported yet.</span>
                </span>
              </li>
            ))}
        </ul>
        {/*
          "Check again" was here, and it is gone for the same reason the one on
          the agent list above it is: `load` runs from an effect on every visit
          to this pane, so the button re-ran a probe that had answered a second
          earlier. It was also the third control on a pane the recorded review of
          2026-08-19 called *"too messy and too difficult to understand"* — and
          two of the three did nothing a person had asked for.
        */}
      </details>

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
