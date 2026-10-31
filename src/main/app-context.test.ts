import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  bootMapFor,
  composeRemoteContext,
  contextDir,
  currentAppContext,
  INDEX_FILE,
  mapText,
  resetForTests,
  writeAppContext,
} from './app-context'
import { noVerbsReasons } from './session-verbs'

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
    // A posix `dir` keeps its slashes on every host — the separator follows the
    // dir, not this machine — so the joined path is spelled with `/` here too.
    expect(prose.split(`/d/${INDEX_FILE}`).length - 1).toBe(1)
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

  /**
   * The page argued *against* the tools the same day's other lane handed out.
   *
   * `browser-windows.md` closed with *"It cannot click, type, scroll or read the
   * page — a session has no tool for any of that. Driving a page belongs to the
   * copilot"*, which was true when it was written and false by that evening:
   * `deck-control/session-tools.ts` puts six browser verbs on an ordinary
   * session's own tool list. Both landed 2026-08-21, one lane each.
   *
   * So this app was writing a file, at every launch, telling every agent it
   * started not to reach for tools that were sitting in that agent's tool list —
   * an argument against the correct behaviour, in a channel nobody can turn off.
   * These two assertions are the ones that would have caught it: the false
   * sentence is gone, and the page names what is actually there.
   */
  it('does not tell a session it has no tool for the tools it has', () => {
    const browser = readFileSync(join(contextDir(write()), 'browser-windows.md'), 'utf8')

    expect(browser).not.toContain('a session has no tool for any of that')
    expect(browser).not.toContain('Driving a page belongs to the copilot')
    for (const verb of ['browser_open', 'browser_read', 'browser_step', 'browser_close']) {
      expect(browser).toContain(verb)
    }
    // And the naming half, which is the whole reason the verbs are worth telling
    // a session about here rather than leaving to the tool list: the window a
    // hook answer calls `B1` is the one a verb calls `B1`.
    expect(browser).toContain('`window: "B2"`')
  })

  /**
   * And the reasons are rendered from the set the sentence is composed from.
   *
   * The failure above was a second copy of a fact going stale. A page that spelt
   * the five reasons out again would be the same mistake one round later, so it
   * renders `noVerbsReasons()` — and this pins that, by asserting the page
   * against the list rather than against a string typed here.
   */
  it('lists every reason a session can be without them, from the one list', () => {
    const browser = readFileSync(join(contextDir(write()), 'browser-windows.md'), 'utf8')

    const reasons = noVerbsReasons()
    expect(reasons.length).toBeGreaterThan(0)
    for (const clause of reasons) {
      expect(browser).toContain(`${clause[0].toUpperCase()}${clause.slice(1)}.`)
    }
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

/* ------------------------------------------------- and the same, elsewhere -- */

describe('what a session on a server is given instead', () => {
  const remote = (opensInApp = true) =>
    composeRemoteContext({
      version: '9.9.9',
      serverName: 'Office PC',
      appMachineName: 'Asad’s MacBook',
      opensInApp,
    })

  it('names documents on that machine, never a path that only exists here', () => {
    const here = write()
    const there = remote()
    const map = there.mapFor('/tmp/td-drive-abc123/context')

    expect(map).toContain('/tmp/td-drive-abc123/context/INDEX.md')
    // The one that would have been handed over before this existed: a path under
    // `<userData>` on this Mac, which on somebody's Ubuntu box is a file that is
    // not there. An agent told to read it reads nothing.
    expect(map).not.toContain(contextDir(here))
    expect(currentAppContext()?.map).not.toBe(map)
  })

  it('is the caller’s text when the caller has one, and this run’s otherwise', () => {
    write()
    const theirs = remote().mapFor('/tmp/td-drive-abc123/context')
    expect(bootMapFor('SessionStart', 'server-1 shell-9', 'server-1', theirs)).toBe(theirs)
    // Handing in nothing keeps the answer a local session has always had.
    expect(bootMapFor('SessionStart', 's1')).toBe(currentAppContext()?.map)
  })

  it('describes the transport that is actually carrying it', () => {
    const pages = remote().pages
    const sessions = pages['sessions-and-machines.md']

    // The hook that carried this did not come from that account's settings file
    // and nothing was written into it, so the page does not say either.
    expect(sessions).toContain("Nothing was written into this account's home directory.")
    expect(sessions).toContain('# terminaldeck-hook')
    expect(sessions).not.toContain('~/.codex/hooks.json')
    // And there is no session variable in an SSH shell to look one up in — the
    // first thing `window-drive.ts` rejected, and a thing an agent would go
    // hunting for if it were promised.
    expect(sessions).not.toContain('TERMINALDECK_SESSION')
    expect(sessions).toContain("There is no session id in this shell's environment")
  })

  it('says which machine is which, in every page that mentions one', () => {
    const pages = remote().pages
    expect(pages['INDEX.md']).toContain('Office PC')
    expect(pages['INDEX.md']).toContain('Asad’s MacBook')
    // The person reading the output is not sitting at the machine this session
    // is running on, which is the fact most worth stating and least obvious.
    expect(pages['sessions-and-machines.md']).toContain(
      'This session is running on Office PC, and the app',
    )
    expect(pages['browser-windows.md']).toContain('on Asad’s MacBook')
  })

  it('never claims an opener it did not manage to install', () => {
    expect(remote(true).pages['browser-windows.md']).toContain(
      "ahead of this server's own opener",
    )
    const without = remote(false).pages
    expect(without['browser-windows.md']).toContain('opens **on this server** rather than in the')
    expect(without['INDEX.md']).toContain("this server's own opener")
  })

  /**
   * A server session always has the verbs, so the page there does not hedge.
   *
   * `servers/window-drive.ts`'s `arm()` settles the driving half first and
   * returns on any refusal; the hooks and these documents are only written
   * afterwards, and `belongFiles` writes the pages only inside `if
   * (input.hooks)`. So a session on a server that can read this page is holding
   * the verbs, and printing the five local reasons there would be five sentences
   * about launches that cannot happen on the machine reading them — the same
   * class of defect as naming a file that is not there.
   */
  it('does not offer a server session reasons that belong to another machine', () => {
    const browser = remote().pages['browser-windows.md']

    expect(browser).toContain("browser verbs, and that is not a hope")
    expect(browser).toContain('browser_read')
    // Every clause the local page lists, and not one of them here.
    for (const clause of noVerbsReasons()) {
      expect(browser).not.toContain(`${clause[0].toUpperCase()}${clause.slice(1)}.`)
    }
  })

  it('does not name a directory it cannot know yet', () => {
    // The folder is made by `mktemp -d` on the far end, so at the moment these
    // are composed there is no path to print. `mapText` already argues that one
    // path is enough and that an agent holding the index can list its folder.
    expect(remote().pages['INDEX.md']).not.toContain('This directory:')
  })
})
