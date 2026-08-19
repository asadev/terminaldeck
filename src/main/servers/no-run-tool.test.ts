/**
 * The copilot gets the named actions and nothing else.
 *
 * `SERVERS-DESIGN.md` §6.1, which is worth quoting because the reasoning is the
 * whole test:
 *
 * > An arbitrary-command tool is the whole machine, and it makes every rule
 * > above decorative: an agent that can run a command does not need
 * > `servers.restart` and is not bound by its consequence sentence, its class,
 * > or its way back.
 *
 * A `servers.run` would not merely add a capability. It would *remove* every
 * guarantee the rest of this feature is built on, silently, while every other
 * test in the folder stayed green — because each of them checks that the named
 * actions behave, and none of them would notice a door opening beside the
 * named actions.
 *
 * So this is deliberately structural. It reads the tool specs and it reads the
 * *source*, because the hole it guards is a second code path somebody adds
 * later rather than a bug in the one that exists.
 */

import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { ServerGrants } from './grants'
import { serverTools, CONTROL_ACTIONS } from './tools'
import { fakeRoom } from './test-fixtures'

const tools = serverTools({ room: fakeRoom(), grants: new ServerGrants() })

describe('no tool runs an arbitrary command', () => {
  it('exposes three tools and no more', () => {
    /*
     * The count is pinned because `catalogue.ts` holds the whole assembled
     * listing to twenty tools and eight thousand tokens, and the app already
     * contributes fourteen built-ins plus five browser tools plus the tour. A
     * fourth server tool here is not free: it is a standing tax on every
     * question Asad asks, including the ones that will never call it. That
     * file's instruction to whoever runs out is explicit — disclose
     * progressively, do not raise the number.
     */
    expect(tools.map((tool) => tool.id).sort()).toEqual(['servers.control', 'servers.logs', 'servers.look'])
  })

  it('has no tool whose name suggests running something of the agent’s own', () => {
    for (const tool of tools) {
      expect(tool.id, `${tool.id} reads like an arbitrary-command tool`).not.toMatch(
        /\.(run|exec|shell|command|script|sh|eval|sudo)$/,
      )
    }
  })

  it('takes no free-text argument that could carry a command', () => {
    const banned = /^(command|cmd|argv|args|script|shell|exec|run|sudo|code|eval|sql|query)$/i
    for (const tool of tools) {
      const properties = (tool.inputSchema as { properties?: Record<string, unknown> }).properties ?? {}
      for (const name of Object.keys(properties)) {
        expect(banned.test(name), `${tool.id} takes an argument called ${name}`).toBe(false)
      }
    }
  })

  it('constrains the control tool to a closed list of named actions', () => {
    /*
     * The enum is what makes one tool safe where six specs would have been. A
     * free string here would be `servers.run` wearing a different name — the
     * dispatcher would happily pass `rm -rf /` through as an "action" and the
     * only thing standing between it and the server would be a lookup that
     * happened to miss.
     */
    const control = tools.find((tool) => tool.id === 'servers.control')
    const properties = (control?.inputSchema as { properties?: Record<string, { enum?: unknown }> }).properties ?? {}
    expect(Array.isArray(properties.action?.enum)).toBe(true)
    expect(properties.action?.enum).toEqual([...CONTROL_ACTIONS])
    expect(CONTROL_ACTIONS).not.toContain('open')
  })

  it('refuses every argument that is not in the enum, before any dialog', () => {
    const control = tools.find((tool) => tool.id === 'servers.control')
    expect(() =>
      control?.precheck?.(
        { serverId: 's1', cardId: 'service:one.service', action: 'rm -rf /' },
        // eslint-disable-next-line @typescript-eslint/no-explicit-any -- only `caller` is read here
        { caller: { kind: 'local', tiers: { read: true, act: true, alter: true } } } as any,
      ),
    ).toThrow(/action must be one of/)
  })

  it('never reaches the transport itself', () => {
    /*
     * `tools.ts` goes through `ServerRoom`, which goes through `actions.ts`,
     * which is where the class discipline lives. A tool calling `run` directly
     * would be a tool outside all of it — and it would look completely ordinary
     * in review, which is exactly why this is checked mechanically.
     */
    const source = readFileSync(join(__dirname, 'tools.ts'), 'utf8')
    const code = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')
    expect(code).not.toMatch(/\brun\s*\(/)
    expect(code).not.toMatch(/from '\.\/connection'/)
  })
})
