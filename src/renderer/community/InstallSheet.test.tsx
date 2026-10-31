import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { confirmLabel, InstallSheetBody, type InstallSheetBodyProps } from './InstallSheet'
import type { CommunityAgent, CommunityItem } from './bridge'

/**
 * The four lines somebody reads before anything is written to their disk.
 *
 * The body rather than the dialog: `Modal` goes through a portal into
 * `document.body` and there is no DOM here, so this renders the part a person
 * reads. What is asserted is the honesty of it — that every value is one the
 * installer supplied, that all three agents are named whatever is on the
 * machine, and that nothing on this surface is a paragraph.
 */

function item(over: Partial<CommunityItem> = {}): CommunityItem {
  return {
    id: 'acme/pr-review',
    publisher: 'acme',
    handle: 'acme',
    profileUrl: '',
    kind: 'skill',
    name: 'Pull request review',
    summary: 'Reads a diff and writes the review.',
    version: '1.2.0',
    licence: 'MIT',
    tags: [],
    agents: ['claude', 'gemini'],
    tier: 2,
    needs: ['runs-scripts'],
    missing: [],
    cost: 'free',
    costNote: '',
    delivery: 'repo',
    offsiteUrl: '',
    repo: 'https://github.com/acme/pr-review',
    commit: 'a'.repeat(40),
    artifactUrl: 'https://codeload.github.com/acme/pr-review/zip/aaa',
    sha256: 'b'.repeat(64),
    bytes: 4096,
    network: [],
    updatedAt: '2026-08-26T00:00:00.000Z',
    stars: -1,
    openIssues: -1,
    ratingScore: 0,
    ratingCount: 0,
    state: 'available',
    installedVersion: '',
    message: '',
    reason: '',
    lands: ['/Users/x/.claude/skills/acme.pr-review', '/Users/x/.gemini/skills/acme.pr-review'],
    command: '',
    variables: [],
    trigger: '',
    reach: [],
    logo: '',
    ...over,
  }
}

const AGENTS: CommunityAgent[] = [
  { id: 'claude', name: 'Claude Code', found: true, note: '' },
  { id: 'codex', name: 'Codex CLI', found: false, note: '' },
  { id: 'gemini', name: 'Gemini CLI', found: true, note: '' },
]

function render(over: Partial<InstallSheetBodyProps> = {}): string {
  return renderToStaticMarkup(
    <InstallSheetBody
      item={item()}
      agents={AGENTS}
      chosen={['claude']}
      onChoose={() => {}}
      {...over}
    />,
  )
}

describe('the four lines', () => {
  it('names the real folders, spelled out, from the installer’s own list', () => {
    // A sheet that composed its own paths would be a promise made by a component
    // that installs nothing — and the failure of it is silent.
    const markup = render()
    expect(markup).toContain('/Users/x/.claude/skills/acme.pr-review')
    expect(markup).toContain('/Users/x/.gemini/skills/acme.pr-review')
  })

  it('says it could not name them rather than inventing one', () => {
    const markup = render({ item: item({ lands: [] }) })
    expect(markup).toContain('This build could not name the folders.')
  })

  it('names what it needs and what is missing here', () => {
    const markup = render({ item: item({ needs: ['node'], missing: ['node'] }) })
    expect(markup).toContain('Needs Node.js')
    expect(markup).toContain('not found here')
  })

  it('ends on the sentence this app owes anybody pressing Install', () => {
    expect(render()).toContain('Terminal Deck did not write this and has not run it.')
  })

  it('leads with the tier, in the shared words', () => {
    expect(render()).toContain('Ships scripts the agent may run')
    expect(render({ item: item({ tier: 3 }) })).toContain('Runs a program on this machine')
    expect(render({ item: item({ tier: 1 }) })).toContain('Text only — nothing runs')
  })
})

describe('all three agents, whatever is on the machine', () => {
  it('names every one of them', () => {
    /*
     * *"Where we can have an option between Claude, Codex, Gemini, in those
     * places don't name only Claude."* A missing row would report an absent
     * agent by absence, which is the one shape that rule forbids.
     */
    const markup = render()
    expect(markup).toContain('Claude Code')
    expect(markup).toContain('Codex CLI')
    expect(markup).toContain('Gemini CLI')
  })

  it('names all three even when the app answered with none of them', () => {
    // Drawn from the shared list rather than from what arrived, so an older
    // main half cannot quietly turn this into a one-agent screen.
    const markup = render({ agents: [] })
    expect(markup).toContain('Claude Code')
    expect(markup).toContain('Codex CLI')
    expect(markup).toContain('Gemini CLI')
  })

  it('draws no checkbox for an agent that is not on this machine', () => {
    // Absent, never a ticked box that cannot be pressed.
    const markup = render()
    expect(markup).toContain('not on this machine')
    expect(markup.match(/type="checkbox"/g)).toHaveLength(2)
  })

  it('says when the publisher never tested the agent you have', () => {
    const markup = render({ item: item({ agents: ['claude'] }) })
    expect(markup).toContain('the publisher did not test this one')
  })

  it('prints the one short line the app supplied, and composes none of its own', () => {
    const markup = render({
      agents: [
        { id: 'claude', name: 'Claude Code', found: true, note: '' },
        { id: 'codex', name: 'Codex CLI', found: true, note: 'you approve this once, in the CLI' },
        { id: 'gemini', name: 'Gemini CLI', found: true, note: '' },
      ],
    })
    expect(markup).toContain('you approve this once, in the CLI')
  })
})

describe('what a kind adds, and nothing more', () => {
  it('shows the exact command the app composes for a server', () => {
    /*
     * A community item can never supply a command string — the app's own
     * compiled code composes it from a runtime and a package name — and printing
     * the result is what makes that checkable by the person it protects rather
     * than only by a reviewer.
     */
    const markup = render({
      item: item({ kind: 'mcp', tier: 3, command: 'npx -y @lumen/postgres', variables: ['PGURL'] }),
    })
    expect(markup).toContain('npx -y @lumen/postgres')
    expect(markup).toContain('PGURL')
  })

  it('says a routine arrives switched off', () => {
    const markup = render({ item: item({ kind: 'routine', trigger: 'every morning at 9' }) })
    expect(markup).toContain('every morning at 9')
    expect(markup).toContain('arrives switched off')
  })

  it('says what an extension may reach', () => {
    const markup = render({ item: item({ kind: 'extension', reach: ['*://*.example.com/*'] }) })
    expect(markup).toContain('*://*.example.com/*')
  })

  it('adds none of them to a skill', () => {
    const markup = render()
    expect(markup).not.toContain('Trigger')
    expect(markup).not.toContain('Reaches')
    expect(markup).not.toContain('<dt>Runs</dt>')
  })
})

describe('the confirm', () => {
  it('names the publisher when a program is about to run on this machine', () => {
    // At tier 3 that is the decision being made: a program on this machine, on a
    // stranger's word.
    expect(confirmLabel(item({ tier: 3 }), false)).toBe('Install from @acme')
  })

  it('says Install and nothing more below that', () => {
    // Dressing every button in the same warning is how a warning stops being
    // read.
    expect(confirmLabel(item({ tier: 1 }), false)).toBe('Install')
    expect(confirmLabel(item({ tier: 2 }), false)).toBe('Install')
  })

  it('says what it is doing while it does it', () => {
    expect(confirmLabel(item({ tier: 3 }), true)).toBe('Installing…')
  })
})

describe('house rule 1', () => {
  it('has exactly one line of prose, and it is the tier', () => {
    /*
     * Four labelled rows and one line above them. Counting the `<p>`s is the
     * mechanical version of *"no explanatory paragraph on a shared screen"*: a
     * second one means somebody started explaining, and the place for that is
     * the ⓘ.
     */
    const markup = render()
    expect(markup.match(/<p[\s>]/g)).toHaveLength(1)
    expect(markup).toContain('Ships scripts the agent may run')
  })

  it('keeps the long half of the tier behind the dot rather than on the sheet', () => {
    /*
     * The paragraph is in the markup — `HoverNote` keeps it in a described-by
     * span so a screen reader gets it without a hover — but it is *inside the
     * dot*, not a second block of prose in the flow. That distinction is the
     * whole of the rule: what starts it, as whom, and for how long is four more
     * sentences that would push the four rows below the fold.
     */
    const markup = render({ item: item({ tier: 3 }) })
    expect(markup).toContain('More about Runs a program on this machine')
    const note = markup.slice(markup.indexOf('hovernote-text'))
    expect(note).toContain('keeps running until the session ends')
    expect(markup.slice(0, markup.indexOf('hovernote-text'))).not.toContain(
      'keeps running until the session ends',
    )
  })
})
