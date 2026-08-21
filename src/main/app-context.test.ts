import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  bootMapFor,
  contextDir,
  currentAppContext,
  INDEX_FILE,
  mapText,
  resetForTests,
  writeAppContext,
} from './app-context'

/**
 * The map, and the three promises it has to keep at once.
 *
 * Asad asked for the same thing twice in one recording and the three halves of
 * it pull against each other, which is why they are pinned together here:
 *
 *  1. *"when any session starts … even from the office PC … or even if it is
 *     starting from the server"* — every session, wherever it runs.
 *  2. *"no file will be visible to edit it … it will just back in the backend"*
 *     — nothing editable, nothing printed, nothing in Settings.
 *  3. *"it knows already the map of context and it can come go to the path
 *     inside the application and it can read from there"* — what arrives is an
 *     index, and the substance is behind it.
 *
 * The first is a wiring fact and is pinned over a real socket in
 * `session-boot-context.test.ts`. This file holds the other two: that the map is
 * small and names a real readable path, that the documents behind it exist and
 * say what is actually true of this install, and that the map is not repaid on
 * every turn.
 */

const dirs: string[] = []

function scratch(): string {
  const dir = mkdtempSync(join(tmpdir(), 'td-app-context-'))
  dirs.push(dir)
  return dir
}

function write(over: Partial<Parameters<typeof writeAppContext>[0]> = {}): string {
  const dir = over.dir ?? scratch()
  writeAppContext({
    dir,
    version: '9.9.9',
    machineName: 'OFFICE-PC',
    opensInApp: true,
    platform: 'darwin',
    ...over,
  })
  return dir
}

beforeEach(() => {
  resetForTests()
})

afterEach(() => {
  resetForTests()
  while (dirs.length > 0) rmSync(dirs.pop() as string, { recursive: true, force: true })
})

describe('the injection is a map and not the context itself', () => {
  it('names a file that is really there, so following it cannot dead-end', () => {
    const dir = write()
    const context = currentAppContext()

    expect(context).not.toBeNull()
    expect(context?.map).toContain(join(contextDir(dir), INDEX_FILE))
    // The whole design rests on this: an agent handed the map goes and opens
    // the one file it was given. A map naming a path that is not on disk would
    // be worse than no map, because the agent would conclude the app lied.
    expect(readFileSync(join(contextDir(dir), INDEX_FILE), 'utf8')).toContain('# Terminal Deck')
  })

  it('stays short — it is an index, not the documents', () => {
    write()
    const map = currentAppContext()?.map ?? ''
    expect(map).toContain('9.9.9')
    expect(map).toContain('OFFICE-PC')

    // Measured against a fixed directory rather than against the map above,
    // because a temporary directory on macOS is sixty bytes of noise and this
    // is a budget on the *prose*. Three sentences: it rides once per context
    // rather than once per prompt, which is what buys it three rather than one.
    const prose = mapText({ version: '9.9.9', machineName: 'OFFICE-PC', dir: '/d' })
    expect(prose.length).toBeLessThan(300)
    // And exactly one path in it. The directory and the index inside it are the
    // same fact twice, and the second one has a filename on the end.
    // Counted as the joined path rather than as the literal `/d`: `mapText`
    // builds it with `join`, which is `\\d\\INDEX.md` on Windows, and a test
    // that splits on a forward slash there counts zero and calls it a bug.
    expect(prose.split(join('/d', INDEX_FILE)).length - 1).toBe(1)
  })

  it('does not name the app again, because the line above it already did', () => {
    // `hookContext` puts "You are running inside Terminal Deck, a terminal app
    // with browser windows of its own." immediately above this. Two consecutive
    // lines opening with the same proper noun is the shape of a hook answer
    // that reads like boilerplate, which is the thing he has objected to.
    expect(mapText({ version: '1.0.0', machineName: 'M', dir: '/d' })).not.toContain('Terminal Deck')
    expect(mapText({ version: '1.0.0', machineName: 'M', dir: '/d' })).toMatch(/^It is version/)
  })
})

describe('the documents behind it', () => {
  it('writes exactly the files the index promises, and no others', () => {
    const dir = write()
    const names = readdirSync(contextDir(dir)).sort()

    expect(names).toEqual(['INDEX.md', 'browser-windows.md', 'sessions-and-machines.md'])
    const index = readFileSync(join(contextDir(dir), INDEX_FILE), 'utf8')
    for (const name of names) {
      if (name !== INDEX_FILE) expect(index).toContain(name)
    }
  })

  it('says on every page that editing it does nothing', () => {
    const dir = write()
    // This is the *"no file will be visible to edit it"* half, kept honest at
    // the one point where it could go wrong: somebody finds the directory
    // anyway. An edit here survives until the next launch, which is the worst
    // of both, so every page says so in its first line.
    for (const name of readdirSync(contextDir(dir))) {
      const body = readFileSync(join(contextDir(dir), name), 'utf8')
      expect(body.split('\n')[0]).toContain('at every start')
      expect(body).toContain('Do not edit')
    }
  })

  it('answers the question the boot map cannot — what B1 means and how it got there', () => {
    const dir = write()
    const browser = readFileSync(join(contextDir(dir), 'browser-windows.md'), 'utf8')

    // His acceptance test for the map, verbatim: *"how do I connect a browser
    // window to this session, and what tools does that give you?"* If this page
    // does not answer it, the map points at nothing worth following.
    expect(browser).toContain('Connect browser')
    expect(browser).toContain('`B1`, `B2`')
    expect(browser).toContain('cannot attach a window')
  })

  it('never claims a route this build did not install', () => {
    const shimmed = readFileSync(join(contextDir(write()), 'browser-windows.md'), 'utf8')
    const bare = readFileSync(
      join(contextDir(write({ opensInApp: false, platform: 'win32' })), 'browser-windows.md'),
      'utf8',
    )

    expect(shimmed).toContain("is on this session's PATH ahead of the machine's own opener")
    // `open-shim.ts` writes nothing on Windows. A document telling an agent that
    // `open <url>` lands in this app would be a confident falsehood in a file it
    // goes and reads on purpose — which is worse than one in a hook answer,
    // because it looks like documentation.
    expect(bare).not.toContain("ahead of the machine's own opener")
    expect(bare).toContain('does not put an opener on a session')
  })

  it('names the machine it was written on, not the one being looked at', () => {
    const dir = write({ machineName: 'DESKTOP-DDGMNCV' })
    const sessions = readFileSync(join(contextDir(dir), 'sessions-and-machines.md'), 'utf8')

    // The whole reason this page exists. A session on his PC reads its own
    // machine's name here, because the person reading its output is on a Mac
    // and their `localhost` is not this one.
    expect(sessions).toContain('This session is running on DESKTOP-DDGMNCV.')
  })
})

describe('which knocks carry it', () => {
  it('rides every SessionStart, because every one of them is a fresh context', () => {
    write()
    // `resume`, `clear` and `compact` all fire `SessionStart` again, and each is
    // a context being rebuilt without the map in it. Latching this event would
    // mean a session that compacts once is never told again.
    expect(bootMapFor('SessionStart', 's1')).not.toBeNull()
    expect(bootMapFor('SessionStart', 's1')).not.toBeNull()
  })

  it('rides the first Gemini turn and then stops', () => {
    write()
    // Gemini's `SessionStart` is deliberately not answered at all —
    // `hook-server.ts` measured that its `additionalContext` lands as a
    // synthesised *user* turn. `BeforeAgent` is the only door left, and it fires
    // on every prompt, so it is the one event that has to be latched.
    expect(bootMapFor('BeforeAgent', 's1')).not.toBeNull()
    expect(bootMapFor('BeforeAgent', 's1')).toBeNull()
    expect(bootMapFor('BeforeAgent', 's1')).toBeNull()
    // And the latch is per session, not per process.
    expect(bootMapFor('BeforeAgent', 's2')).not.toBeNull()
  })

  it('never rides a prompt or a tool call that is not one of those two', () => {
    write()
    // `UserPromptSubmit` is the one that matters here. `SessionStart` has
    // already put the map in that same context, and repeating it above every
    // prompt he types is the wall of statements he has banned three times.
    expect(bootMapFor('UserPromptSubmit', 's1')).toBeNull()
    expect(bootMapFor('PostToolUse', 's1')).toBeNull()
    expect(bootMapFor('AfterTool', 's1')).toBeNull()
    expect(bootMapFor('Stop', 's1')).toBeNull()
  })

  it('says nothing at all before the documents exist, or to a session with no id', () => {
    // A hook from a shell this app did not start arrives with no session header.
    expect(bootMapFor('SessionStart', null)).toBeNull()
    // And a knock that beat `writeAppContext` must not name a directory that is
    // not there yet. Both callers write it before anything can start a session;
    // this is what holds if one of them ever stops.
    expect(bootMapFor('SessionStart', 's1')).toBeNull()
  })
})
