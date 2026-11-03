import { describe, expect, it } from 'vitest'
import { agentLabel } from './server-signin'

/**
 * Which agent a terminal on a server is running as, in words.
 *
 * This file used to be about the chat bridge that let one chat view read a
 * conversation off a server — the shell-keyed reader, the wiring check the mode
 * switch asked before drawing a Chat segment, and the narrowing of what crossed
 * the preload boundary. Chat mode was removed on 2026-08-26 and all three went
 * with it. What is left is the naming, which was never about chat: the far
 * end's probe can be newer than this build, so an id this app has never heard
 * of has to come out as *something* rather than as a blank.
 *
 * The sentences the chip draws from it are exercised in `sign-in-words.test.ts`.
 */
describe('the agent named on the sign-in line', () => {
  it('uses the catalogue’s own name', () => {
    expect(agentLabel('claude')).toBe('Claude Code')
  })

  it('prints an id it has never heard of rather than nothing', () => {
    expect(agentLabel('something-new')).toBe('something-new')
  })
})
