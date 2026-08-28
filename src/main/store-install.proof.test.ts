import { createHash, createPrivateKey, sign } from 'node:crypto'
import { createServer, type Server } from 'node:http'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { AddressInfo } from 'node:net'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { DEV_KEY_PHRASE, liveStoreKeys } from '../shared/store-key'
import { STORE_INDEX_PATH } from '../shared/store-api'
import { tarGz } from './store-archive.fixture'
import { createStoreInstaller, itemsDir, readLedger } from './store-install'

/**
 * The whole chain, over a real socket, with nothing stubbed but the two command
 * line tools this test must not run.
 *
 * Every other test in this folder hands the store an index and an archive
 * directly, which is the right way to test what it does with them and no way at
 * all to test the parts *between* — a signature over transmitted bytes, an HTTP
 * fetch with its own ceiling and redirect rule, a digest over what actually
 * arrived. Those are exactly the joints where a build passes every unit test and
 * installs nothing, so here they are all real:
 *
 *  - a genuine Ed25519 signature, made with the development key whose private
 *    half is derived from `DEV_KEY_PHRASE` and checked against the public half
 *    compiled into this build;
 *  - a real HTTP server on a loopback port the operating system picks, serving
 *    the signed catalogue and two real `.tar.gz` artifacts;
 *  - the real fetcher, the real digest check, the real unpacker, the real
 *    manifest grammar, and real files written to a scratch home.
 *
 * The agents' own command line tools are the one seam left injected, and that is
 * not a gap in the proof: running the real ones would write into the machine's
 * actual configuration, which is the thing this repository refuses to do in a
 * test. What they were *asked* to run is asserted as argv instead.
 */

/** The development key's private half, from the sentence anyone can recompute. */
function devSigningKey(): ReturnType<typeof createPrivateKey> {
  const seed = createHash('sha256').update(DEV_KEY_PHRASE).digest()
  const pkcs8 = Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed])
  return createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' })
}

function manifest(over: Record<string, unknown>): string {
  return JSON.stringify({
    terminaldeck: 1,
    publisher: 'commons',
    summary: 'One honest line about it.',
    licence: 'MIT',
    category: 'utility',
    tags: [],
    agents: ['claude', 'codex', 'gemini'],
    platforms: ['darwin', 'win32', 'linux'],
    delivery: 'repo',
    pricing: { model: 'free', note: null, url: null },
    licenceEnv: null,
    links: { repo: 'https://github.com/commons/items', home: null, docs: null },
    needs: [],
    version: '1.0.0',
    ...over,
  })
}

const SKILL_BODY = `---
name: plain-english
description: Rewrite what you were about to say in plain English.
---

Say it the way you would to somebody who does not write code.
`

const skillArchive = tarGz([
  {
    name: 'items-abc/terminaldeck.json',
    body: manifest({
      id: 'plain-english',
      kind: 'skill',
      name: 'Plain English',
      install: { dir: 'skill' },
    }),
  },
  { name: 'items-abc/skill/SKILL.md', body: SKILL_BODY },
])

const mcpArchive = tarGz([
  {
    name: 'items-abc/terminaldeck.json',
    body: manifest({
      id: 'notes-server',
      kind: 'mcp',
      name: 'Notes Server',
      needs: ['node'],
      install: {
        runtime: 'node',
        package: '@commons/notes-mcp',
        args: ['--notes', '${input:NOTES}'],
        inputs: [
          { key: 'NOTES', label: 'Notes folder', hint: 'Where your notes live', kind: 'path', into: 'arg', required: true },
        ],
        token: '@commons/notes-mcp',
      },
    }),
  },
  { name: 'items-abc/README.md', body: '# Notes Server\n' },
])

const digest = (bytes: Buffer): string => createHash('sha256').update(bytes).digest('hex')

let server: Server
let base = ''
let userData = ''
let home = ''

beforeAll(async () => {
  userData = mkdtempSync(join(tmpdir(), 'td-proof-data-'))
  home = mkdtempSync(join(tmpdir(), 'td-proof-home-'))

  server = createServer((request, response) => {
    const path = request.url ?? ''
    if (path === '/items/plain-english.tar.gz') {
      response.writeHead(200, { 'content-type': 'application/gzip' })
      response.end(skillArchive)
      return
    }
    if (path === '/items/notes-server.tar.gz') {
      response.writeHead(200, { 'content-type': 'application/gzip' })
      response.end(mcpArchive)
      return
    }
    if (path === STORE_INDEX_PATH) {
      response.writeHead(200, { 'content-type': 'application/json' })
      response.end(envelope())
      return
    }
    response.writeHead(404)
    response.end('no')
  })
  await new Promise<void>((done) => server.listen(0, '127.0.0.1', done))
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
})

afterAll(async () => {
  await new Promise<void>((done) => server.close(() => done()))
  rmSync(userData, { recursive: true, force: true })
  rmSync(home, { recursive: true, force: true })
})

/** The catalogue, signed the way the site's own signing script will sign it. */
function envelope(): string {
  const index = {
    v: 1,
    serial: 1,
    issuedAt: new Date().toISOString(),
    expiresAt: null,
    generator: 'store-install.proof.test',
    truncated: false,
    revoked: [],
    items: [
      {
        id: 'commons/plain-english',
        publisher: 'commons',
        listedBy: 'commons',
        kind: 'skill',
        name: 'Plain English',
        summary: 'One honest line about it.',
        version: '1.0.0',
        licence: 'MIT',
        category: 'utility',
        tags: [],
        agents: ['claude', 'codex', 'gemini'],
        platforms: ['darwin', 'win32', 'linux'],
        tier: 1,
        needs: [],
        cost: 'free',
        costNote: null,
        delivery: 'repo',
        source: {
          repo: 'https://github.com/commons/items',
          commit: 'b'.repeat(40),
          path: '.',
          host: 'github.com',
        },
        artifact: {
          url: `${base}/items/plain-english.tar.gz`,
          sha256: digest(skillArchive),
          bytes: skillArchive.byteLength,
          files: 2,
          unpacked: SKILL_BODY.length + 400,
        },
        install: { dir: 'skill' },
        network: [],
        publishedAt: '2026-08-01T00:00:00.000Z',
        updatedAt: '2026-08-01T00:00:00.000Z',
      },
      {
        id: 'commons/notes-server',
        publisher: 'commons',
        listedBy: 'commons',
        kind: 'mcp',
        name: 'Notes Server',
        summary: 'One honest line about it.',
        version: '1.0.0',
        licence: 'MIT',
        category: 'utility',
        tags: [],
        agents: ['claude', 'codex', 'gemini'],
        platforms: ['darwin', 'win32', 'linux'],
        tier: 3,
        needs: ['node'],
        cost: 'free',
        costNote: null,
        delivery: 'repo',
        source: {
          repo: 'https://github.com/commons/items',
          commit: 'c'.repeat(40),
          path: '.',
          host: 'github.com',
        },
        artifact: {
          url: `${base}/items/notes-server.tar.gz`,
          sha256: digest(mcpArchive),
          bytes: mcpArchive.byteLength,
          files: 2,
          unpacked: 400,
        },
        install: {
          runtime: 'node',
          package: '@commons/notes-mcp',
          args: ['--notes', '${input:NOTES}'],
          inputs: [
            {
              key: 'NOTES',
              label: 'Notes folder',
              hint: 'Where your notes live',
              kind: 'path',
              into: 'arg',
              required: true,
            },
          ],
          token: '@commons/notes-mcp',
        },
        network: [],
        publishedAt: '2026-08-01T00:00:00.000Z',
        updatedAt: '2026-08-01T00:00:00.000Z',
      },
    ],
  }
  const signed = Buffer.from(JSON.stringify(index), 'utf8')
  return JSON.stringify({
    v: 1,
    keyId: liveStoreKeys()[0].id,
    alg: 'ed25519',
    sig: sign(null, signed, devSigningKey()).toString('base64'),
    signed: signed.toString('base64'),
  })
}

const ran: Array<{ agent: string; argv: string[] }> = []
const claudeCalls: Array<{ verb: string; request: Record<string, unknown> }> = []

function realStore(): ReturnType<typeof createStoreInstaller> {
  return createStoreInstaller({
    userData: () => userData,
    base: () => base,
    env: {},
    home: () => home,
    runAgent: async (agent, argv) => {
      ran.push({ agent, argv: [...argv] })
      return { ok: true, message: '' }
    },
    claudeMcp: {
      add: async (raw) => {
        claudeCalls.push({ verb: 'add', request: raw as Record<string, unknown> })
        return { ok: true, message: '' }
      },
      remove: async (raw) => {
        claudeCalls.push({ verb: 'remove', request: raw as Record<string, unknown> })
        return { ok: true, message: '' }
      },
    },
  })
}

describe('the whole chain, over a socket', () => {
  it('fetches a signed catalogue and lists what is in it', async () => {
    const view = await realStore().view()
    expect(view.ok, view.why ?? '').toBe(true)
    expect(view.from).toBe('store')
    expect(view.items.map((item) => item.row.id).sort()).toEqual(['commons/notes-server', 'commons/plain-english'])
    expect(view.items.every((item) => item.state === 'available')).toBe(true)
  })

  it('downloads a real tar.gz, checks its fingerprint and installs the skill', async () => {
    const result = await realStore().install('commons/plain-english', { agents: ['claude', 'gemini'] })
    expect(result.ok, result.message).toBe(true)

    expect(readFileSync(join(home, '.claude', 'skills', 'commons.plain-english', 'SKILL.md'), 'utf8')).toBe(SKILL_BODY)
    expect(readFileSync(join(home, '.gemini', 'skills', 'commons.plain-english', 'SKILL.md'), 'utf8')).toBe(SKILL_BODY)

    const record = readLedger(userData).find((entry) => entry.id === 'commons/plain-english')
    expect(record?.sha256).toBe(digest(skillArchive))
    expect(record?.commit).toBe('b'.repeat(40))
  })

  it('installs the MCP server with a command this app built, not one the list supplied', async () => {
    const result = await realStore().install('commons/notes-server', {
      agents: ['claude', 'codex'],
      values: { NOTES: join(home, 'notes') },
    })
    expect(result.ok, result.message).toBe(true)

    expect(claudeCalls[0].request.command).toBe(`npx -y @commons/notes-mcp --notes "${join(home, 'notes')}"`)
    expect(ran[0]).toEqual({
      agent: 'codex',
      argv: ['mcp', 'add', 'commons-notes-server', '--', 'npx', '-y', '@commons/notes-mcp', '--notes', join(home, 'notes')],
    })
  })

  it('draws both of them as installed afterwards', async () => {
    const view = await realStore().view()
    expect(view.items.map((item) => item.state).sort()).toEqual(['installed', 'installed'])
  })

  it('serves the same list from the kept copy when the store cannot be reached', async () => {
    const offline = createStoreInstaller({
      userData: () => userData,
      base: () => 'http://127.0.0.1:1',
      env: {},
      home: () => home,
    })
    const view = await offline.view()
    expect(view.ok, view.why ?? '').toBe(true)
    expect(view.from).toBe('kept')
    expect(view.because).not.toBeNull()
    expect(view.items).toHaveLength(2)
  })

  it('puts everything back', async () => {
    const store = realStore()
    expect((await store.remove('commons/plain-english')).ok).toBe(true)
    expect((await store.remove('commons/notes-server')).ok).toBe(true)

    expect(existsSync(join(home, '.claude', 'skills', 'commons.plain-english'))).toBe(false)
    expect(existsSync(join(home, '.gemini', 'skills', 'commons.plain-english'))).toBe(false)
    expect(existsSync(join(itemsDir(userData), 'commons.plain-english'))).toBe(false)
    expect(readLedger(userData)).toEqual([])
    expect(claudeCalls.at(-1)?.verb).toBe('remove')
  })
})
