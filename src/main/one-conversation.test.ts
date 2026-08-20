import { describe, expect, it } from 'vitest'
import { argsForSpawn, conversationIsHeld, type SessionInFolder } from './one-conversation'

/**
 * The guard that stops two sessions writing one conversation.
 *
 * The defect being prevented is silent, which is what makes it worth a test
 * file of its own: two sessions resolving the same `--continue` both append to
 * one transcript, from the same parent message, and the file stays valid JSON
 * throughout. Nothing errors. One branch is simply never seen again — measured
 * and written up in `ACCOUNT-MODEL.md`, which found it with two accounts but
 * where nothing in the mechanism needs two accounts.
 *
 * So the cases below are arranged around the two directions the guard can be
 * wrong in, because they are not equally bad:
 *
 *  - **Refusing a resume that would have been fine** costs one `--continue`
 *    typed by hand. Recoverable, visible, nobody loses work.
 *  - **Permitting a resume that forks** loses turns with no message. The tests
 *    that matter are the ones pinning that this cannot happen.
 */

let counter = 0

function live(cwd: string, provider = 'claude'): SessionInFolder {
  return { id: `s${++counter}`, cwd, provider, exitCode: null }
}

function dead(cwd: string, provider = 'claude'): SessionInFolder {
  return { id: `s${++counter}`, cwd, provider, exitCode: 0 }
}

describe('whether a folder is already held', () => {
  it('is not held when nothing is running', () => {
    expect(conversationIsHeld([], '/w/app', 'claude')).toBe(false)
  })

  it('is held by a live session in the same folder', () => {
    expect(conversationIsHeld([live('/w/app')], '/w/app', 'claude')).toBe(true)
  })

  it('is not held by a session in a different folder', () => {
    // `--continue` resolves within one folder, so a session next door cannot be
    // reading the same transcript and must not block a resume.
    expect(conversationIsHeld([live('/w/other')], '/w/app', 'claude')).toBe(false)
  })

  it('is not held by a session that has exited', () => {
    /*
     * The case this guard must not break. Closing a tab and opening a new one
     * in the same folder has always continued where it left off, and that is
     * the whole point of `--continue`. A dead process holds nothing: the CLI
     * has written its last line and released the file.
     */
    expect(conversationIsHeld([dead('/w/app')], '/w/app', 'claude')).toBe(false)
  })

  it('is not held by a different agent in the same folder', () => {
    // Two providers keep transcripts in different places and different formats,
    // and neither one's `--continue` can see the other's, so they cannot fork
    // each other. Blocking here would refuse a resume for no reason at all.
    expect(conversationIsHeld([live('/w/app', 'codex')], '/w/app', 'claude')).toBe(false)
  })

  it('ignores a trailing separator on either side', () => {
    // The same folder reaches this comparison as two different strings
    // depending on whether it came from a picker, a stored project or a pty —
    // and a fork is not prevented by a slash.
    expect(conversationIsHeld([live('/w/app/')], '/w/app', 'claude')).toBe(true)
    expect(conversationIsHeld([live('/w/app')], '/w/app/', 'claude')).toBe(true)
    expect(conversationIsHeld([live('C:\\w\\app\\')], 'C:\\w\\app', 'claude')).toBe(true)
  })

  it('finds the holder among many sessions', () => {
    const running = [live('/w/one'), dead('/w/app'), live('/w/two'), live('/w/app')]
    expect(conversationIsHeld(running, '/w/app', 'claude')).toBe(true)
  })
})

describe('the arguments a spawn actually gets', () => {
  const base = {
    resumeArgs: ['--continue'] as readonly string[],
    args: [] as readonly string[],
    cwd: '/w/app',
    provider: 'claude',
  }

  it('continues when the folder is free', () => {
    expect(argsForSpawn({ ...base, resume: true, live: [] })).toEqual(['--continue'])
  })

  it('starts fresh when a live session already holds the folder', () => {
    // The rule Asad asked for: a second session in a busy folder gets a new
    // conversation rather than joining the one already open.
    expect(argsForSpawn({ ...base, resume: true, live: [live('/w/app')] })).toEqual([])
  })

  it('does not resume when nobody asked to', () => {
    expect(argsForSpawn({ ...base, resume: false, live: [] })).toEqual([])
  })

  it('returns the plain arguments for a provider with no resume flag', () => {
    /*
     * `resumeArgs` is empty for providers that cannot resume — a plain shell,
     * or an agent added by hand with the field left blank. Asking to resume one
     * is not an error and must not become one; it simply starts normally. This
     * is the pre-existing behaviour of the expression this function replaced
     * and it is pinned here so the guard cannot be blamed for changing it.
     */
    const plain = { ...base, resumeArgs: [], args: ['--interactive'], resume: true, live: [] }
    expect(argsForSpawn(plain)).toEqual(['--interactive'])
  })

  it('still starts fresh when the held folder is a different string for the same path', () => {
    expect(argsForSpawn({ ...base, resume: true, live: [live('/w/app/')] })).toEqual([])
  })
})

/*
 * The switch, which is the one spawn that is not a second session.
 *
 * `performSwitch` starts the replacement before it stops the session it
 * replaces, so that a spawn which cannot start leaves a working agent alone.
 * That order put a live session of the same provider in the same folder in
 * front of this guard on **every** account switch, and the guard did the thing
 * it is built to do: dropped `--continue`. Which is the whole of the defect
 * Asad reported twice — *"it is not going to keep it… It's not keeping the
 * conversation history."*
 */
describe('the session being replaced', () => {
  it('does not hold the conversation against its own replacement', () => {
    const outgoing = live('/w/app')
    expect(conversationIsHeld([outgoing], '/w/app', 'claude', outgoing.id)).toBe(false)
  })

  it('still lets any other live session hold it', () => {
    // The exemption is one id, not a switch that turns the guard off: a third
    // tab open in the folder must still force a fresh conversation.
    const outgoing = live('/w/app')
    const other = live('/w/app')
    expect(conversationIsHeld([outgoing, other], '/w/app', 'claude', outgoing.id)).toBe(true)
  })

  it('hands the replacement the continue flag', () => {
    const outgoing = live('/w/app')
    expect(
      argsForSpawn({
        resume: true,
        resumeArgs: ['--continue'],
        args: [],
        live: [outgoing],
        cwd: '/w/app',
        provider: 'claude',
        replaces: outgoing.id,
      }),
    ).toEqual(['--continue'])
  })

  it('does not hand it over when a different tab is also in the folder', () => {
    const outgoing = live('/w/app')
    expect(
      argsForSpawn({
        resume: true,
        resumeArgs: ['--continue'],
        args: [],
        live: [outgoing, live('/w/app')],
        cwd: '/w/app',
        provider: 'claude',
        replaces: outgoing.id,
      }),
    ).toEqual([])
  })

  it('is unchanged for every spawn that replaces nothing', () => {
    // No id passed is the ordinary case, and it must behave exactly as it did.
    expect(conversationIsHeld([live('/w/app')], '/w/app', 'claude')).toBe(true)
    expect(conversationIsHeld([live('/w/app')], '/w/app', 'claude', null)).toBe(true)
  })
})
