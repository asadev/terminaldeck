import { mkdtempSync, readFileSync } from 'node:fs'
import { request as httpRequest } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import {
  ancestryFrom,
  classifyOperation,
  createCredentialProxy,
  CREDENTIAL_HEADER,
  deviceKey,
  formatHelperAnswer,
  gitSubcommand,
  parseHelperRequest,
  parsePsTable,
  PID_HEADER,
  type CredentialProxy,
  type DevicePost,
} from './credentials'
import { CREDENTIAL_KEY_VAR, CREDENTIAL_URL_VAR } from './git-guest'
import type { ServerMessage } from './protocol'
import { CAPABILITY } from './protocol'

/**
 * The refusals are tested as hard as the approvals, which is the whole point of
 * this file.
 *
 * A credential proxy that answers when it should is half a feature; the half
 * that decides whether anybody trusts it is what happens when the device is
 * asleep, when somebody taps Deny, when the phone drops off mid-push, and when
 * an approval exists for a *different* repository than the one being pushed.
 * Each of those has a case below and each asserts on the sentence a person
 * actually reads, because "it failed" and "your device isn't reachable — open
 * the app to approve this push" are the same outcome and completely different
 * products.
 *
 * Everything goes through the real loopback endpoint rather than through a
 * function on the desk. That is not thoroughness for its own sake: the helper on
 * disk talks HTTP, and a test that called an internal method would pass with the
 * endpoint's authentication removed.
 */

const DEVICE = 'device-1'
const OTHER_DEVICE = 'device-2'

/** What git posts for a push to a repository, as its own helper protocol. */
const REQUEST = 'protocol=https\nhost=github.com\npath=asadev/terminaldeck.git\n\n'
const OTHER_REPO = 'protocol=https\nhost=github.com\npath=asadev/mookhayo.git\n\n'

interface Harness {
  proxy: CredentialProxy
  asked: Array<Extract<ServerMessage, { t: 'credential.request' }>>
  /** Devices the fake sockets say are there. Mutated to make one disappear. */
  present: Set<string>
  /** What the process tree says next, so one test can fetch and then push. */
  running(...lines: string[]): void
  key(deviceId?: string): Promise<string>
  post(key: string, body?: string): Promise<string>
}

const made: CredentialProxy[] = []

afterEach(async () => {
  await Promise.all(made.splice(0).map((proxy) => proxy.stop()))
})

/**
 * A desk with fake sockets in front of it and a fake process tree behind it.
 *
 * `ancestry` is injected rather than read from `ps`, so a test can say "this was
 * a push" on any machine, including one where nothing is pushing. The deadlines
 * are milliseconds for the same reason a test never sleeps for a minute.
 */
function harness(options: { ancestry?: string[]; reach?: number; decide?: number; silent?: number } = {}): Harness {
  const asked: Array<Extract<ServerMessage, { t: 'credential.request' }>> = []
  const present = new Set([DEVICE, OTHER_DEVICE])
  let tree = options.ancestry ?? ['/usr/bin/git push origin main']

  const proxy = createCredentialProxy({
    dir: mkdtempSync(join(tmpdir(), 'td-credentials-')),
    ancestry: async () => tree,
    reachTimeoutMs: options.reach ?? 60,
    decideTimeoutMs: options.decide ?? 250,
    silentTimeoutMs: options.silent ?? 120,
  })
  made.push(proxy)

  const post: DevicePost = {
    ask(deviceId, message) {
      if (!present.has(deviceId)) return 0
      if (message.t === 'credential.request') asked.push(message)
      return 1
    },
    reachable: (deviceId) => present.has(deviceId),
  }
  proxy.serve(post)

  return {
    proxy,
    asked,
    present,
    running(...lines: string[]): void {
      tree = lines
    },
    async key(deviceId = DEVICE): Promise<string> {
      const guest = await proxy.openGuestSession(deviceId)
      const value = guest.env.set[CREDENTIAL_KEY_VAR]
      // The address travels in the environment beside the key, so a test reads
      // both the way the helper does.
      urls.set(value, guest.env.set[CREDENTIAL_URL_VAR])
      guest.started(`session-for-${deviceId}-${value.slice(0, 6)}`)
      return value
    },
    post: (key, body = REQUEST) => postTo(urls.get(key) ?? '', key, body),
  }
}

const urls = new Map<string, string>()

/** POST exactly what the helper posts, and answer with exactly what it reads. */
function postTo(url: string, key: string, body: string, pid = 4242): Promise<string> {
  return new Promise((resolve, reject) => {
    const req = httpRequest(
      url,
      { method: 'POST', headers: { [CREDENTIAL_HEADER]: key, [PID_HEADER]: String(pid) } },
      (res) => {
        let text = ''
        res.setEncoding('utf8')
        res.on('data', (chunk: string) => {
          text += chunk
        })
        res.on('end', () => resolve(`${res.statusCode} ${text}`))
      },
    )
    req.on('error', reject)
    req.end(body)
  })
}

/** Wait for the desk to have put the question, without racing on a fixed sleep. */
async function until(check: () => boolean, label: string): Promise<void> {
  for (let i = 0; i < 200; i += 1) {
    if (check()) return
    await new Promise((done) => setTimeout(done, 5))
  }
  throw new Error(`timed out waiting for ${label}`)
}

/* ------------------------------------------------------------- git's format -- */

describe('reading what git asked for', () => {
  it('pulls the repository out of the path, which is why useHttpPath is set', () => {
    expect(parseHelperRequest(REQUEST)).toEqual({
      protocol: 'https',
      host: 'github.com',
      repo: 'asadev/terminaldeck',
    })
  })

  it('answers null for the repository when git gave no path', () => {
    // Not a failure. It is what a request looks like without `useHttpPath`, or
    // against a remote whose path is not `owner/name`, and the prompt has to be
    // able to say "somewhere" rather than invent a name.
    expect(parseHelperRequest('protocol=https\nhost=github.com\n\n')?.repo).toBeNull()
  })

  it('refuses a path that is not a repository', () => {
    // A gist, a wiki, a traversal. `parseRemoteUrl` already refuses each of
    // these and this is what reusing it buys.
    for (const path of ['../etc/passwd.git', 'one/two/three.git', 'only-one']) {
      expect(parseHelperRequest(`protocol=https\nhost=github.com\npath=${path}\n\n`)?.repo, path).toBeNull()
    }
  })

  it('ignores keys it has not been taught, so a git upgrade cannot break it', () => {
    const parsed = parseHelperRequest(
      'protocol=https\nhost=github.com\npath=asadev/terminaldeck.git\nwwwauth[]=Basic realm="GitHub"\ncapability[]=authtype\n\n',
    )
    expect(parsed?.repo).toBe('asadev/terminaldeck')
  })

  it('stops at the blank line that ends the request', () => {
    const parsed = parseHelperRequest('protocol=https\nhost=github.com\n\nhost=evil.example\n')
    expect(parsed?.host).toBe('github.com')
  })

  it('refuses a request with no host at all', () => {
    expect(parseHelperRequest('protocol=https\n\n')).toBeNull()
  })

  it('refuses a host too long to have come from a real remote', () => {
    expect(parseHelperRequest(`protocol=https\nhost=${'a'.repeat(300)}\n\n`)).toBeNull()
  })
})

describe('writing the answer git reads', () => {
  it('produces the two lines and nothing else', () => {
    expect(formatHelperAnswer('octocat', 'ghp_x')).toBe('username=octocat\npassword=ghp_x\n')
  })

  it('refuses a value carrying a newline, which would be a second directive', () => {
    // The failure this closes: a device answering with `x\nquit=1` changes what
    // git does rather than merely logging in.
    expect(formatHelperAnswer('octocat', 'x\nquit=1')).toBeNull()
    expect(formatHelperAnswer('octo\rcat', 'x')).toBeNull()
  })
})

/* ----------------------------------------------------------- read or write -- */

describe('working out whether git is reading or writing', () => {
  it('reads the subcommand out of the tokens, not out of the line', () => {
    // A checkout at `~/push-service` must not make every fetch look like a push.
    expect(gitSubcommand('/usr/bin/git -C /Users/x/push-service fetch origin')).toBe('fetch')
    expect(gitSubcommand('git -c credential.helper=x push origin main')).toBe('push')
    expect(gitSubcommand('git --no-pager push')).toBe('push')
    expect(gitSubcommand('/usr/libexec/git-core/git-remote-https origin https://github.com/o/r')).toBeNull()
    expect(gitSubcommand('node /Users/x/push.js')).toBeNull()
  })

  it('calls a fetch a read and a push a write', () => {
    expect(classifyOperation(['git-remote-https origin https://x', '/usr/bin/git fetch origin'])).toBe('read')
    expect(classifyOperation(['git-remote-https origin https://x', '/usr/bin/git push origin main'])).toBe('write')
    expect(classifyOperation(['git clone https://github.com/o/r'])).toBe('read')
  })

  it('prompts when it cannot tell, which is the safe direction', () => {
    // No git in the ancestry at all is what Windows produces today, and what a
    // `ps` that would not run produces anywhere. Prompting for a fetch is a
    // tapped button; not prompting for a push is the feature not working.
    expect(classifyOperation([])).toBe('write')
    expect(classifyOperation(['/bin/zsh -l', '/Applications/Some.app/Contents/MacOS/Some'])).toBe('write')
  })

  it('lets the nearest git win', () => {
    expect(classifyOperation(['git push origin main', 'git fetch origin'])).toBe('write')
  })
})

describe('reading the process table', () => {
  const TABLE = ['    1     0 /sbin/launchd', '  900     1 /bin/zsh', '  901   900 /usr/bin/git push', '  902   901 /bin/sh helper'].join('\n')

  it('walks up from the helper to the git that started it', () => {
    expect(ancestryFrom(parsePsTable(TABLE), 902)).toEqual([
      '/bin/sh helper',
      '/usr/bin/git push',
      '/bin/zsh',
    ])
  })

  it('skips the continuation lines of a command with a newline in it', () => {
    // `git commit -m` with a multi-line message is the everyday case, and `ps`
    // prints the newline raw.
    const table = parsePsTable('  1 0 /sbin/launchd\n  5 1 git commit -m first\nsecond line\n  6 5 /bin/sh helper')
    // The walk stops at the init process rather than reporting it: every
    // ancestry on the machine ends the same way and it says nothing about git.
    expect(ancestryFrom(table, 6)).toEqual(['/bin/sh helper', 'git commit -m first'])
  })

  it('does not spin on a pid that points at itself', () => {
    expect(ancestryFrom(parsePsTable('  7 7 /bin/loop'), 7)).toEqual(['/bin/loop'])
  })

  it('answers nothing for a pid that is not there', () => {
    expect(ancestryFrom(parsePsTable(TABLE), 99999)).toEqual([])
  })
})

/* --------------------------------------------------------------- the desk -- */

describe('a read', () => {
  it('is answered without asking anybody', async () => {
    const h = harness({ ancestry: ['/usr/bin/git fetch origin'] })
    const key = await h.key()
    const answer = h.post(key)
    await until(() => h.asked.length === 1, 'the question')

    expect(h.asked[0].operation).toBe('read')
    // The field that decides whether a person is disturbed. A fetch never is.
    expect(h.asked[0].prompt).toBe(false)

    h.proxy.handle(DEVICE, { t: 'credential.ack', id: h.asked[0].id })
    h.proxy.handle(DEVICE, {
      t: 'credential.answer',
      id: h.asked[0].id,
      username: 'octocat',
      password: 'ghp_theirs',
    })
    expect(await answer).toBe('200 username=octocat\npassword=ghp_theirs\n')
  })
})

describe('a push', () => {
  it('asks once, names the repository, and is answered', async () => {
    const h = harness()
    const key = await h.key()
    const answer = h.post(key)
    await until(() => h.asked.length === 1, 'the question')

    expect(h.asked[0]).toMatchObject({
      host: 'github.com',
      repo: 'asadev/terminaldeck',
      operation: 'write',
      prompt: true,
    })

    h.proxy.handle(DEVICE, { t: 'credential.ack', id: h.asked[0].id })
    h.proxy.handle(DEVICE, { t: 'credential.answer', id: h.asked[0].id, username: 'octocat', password: 'ghp_theirs' })
    expect(await answer).toContain('password=ghp_theirs')
  })

  it('asks again next time when the approval was only for once', async () => {
    const h = harness()
    const key = await h.key()

    const first = h.post(key)
    await until(() => h.asked.length === 1, 'the first question')
    h.proxy.handle(DEVICE, { t: 'credential.ack', id: h.asked[0].id })
    h.proxy.handle(DEVICE, { t: 'credential.answer', id: h.asked[0].id, username: 'octocat', password: 'a' })
    await first

    const second = h.post(key)
    await until(() => h.asked.length === 2, 'the second question')
    // Approve-once is once. Anything else and the two buttons on the prompt mean
    // the same thing.
    expect(h.asked[1].prompt).toBe(true)
    h.proxy.handle(DEVICE, { t: 'credential.ack', id: h.asked[1].id })
    h.proxy.handle(DEVICE, { t: 'credential.answer', id: h.asked[1].id, username: 'octocat', password: 'b' })
    await second
  })

  it('stops asking for a repository the device approved always', async () => {
    const h = harness()
    const key = await h.key()

    const first = h.post(key)
    await until(() => h.asked.length === 1, 'the first question')
    h.proxy.handle(DEVICE, { t: 'credential.ack', id: h.asked[0].id })
    h.proxy.handle(DEVICE, {
      t: 'credential.answer',
      id: h.asked[0].id,
      username: 'octocat',
      password: 'a',
      remember: true,
    })
    await first

    const second = h.post(key)
    await until(() => h.asked.length === 2, 'the second question')
    // Still asked — the token is on the device and this end never kept it. What
    // changed is that nobody is disturbed.
    expect(h.asked[1].prompt).toBe(false)
    expect(h.asked[1].operation).toBe('write')
    h.proxy.handle(DEVICE, { t: 'credential.ack', id: h.asked[1].id })
    h.proxy.handle(DEVICE, { t: 'credential.answer', id: h.asked[1].id, username: 'octocat', password: 'b' })
    expect(await second).toContain('password=b')
  })

  it('does not let an approval for one repository answer for another', async () => {
    const h = harness()
    const key = await h.key()

    const first = h.post(key)
    await until(() => h.asked.length === 1, 'the first question')
    h.proxy.handle(DEVICE, { t: 'credential.ack', id: h.asked[0].id })
    h.proxy.handle(DEVICE, {
      t: 'credential.answer',
      id: h.asked[0].id,
      username: 'octocat',
      password: 'a',
      remember: true,
    })
    await first

    const other = h.post(key, OTHER_REPO)
    await until(() => h.asked.length === 2, 'the second question')
    // A grant to work in one folder is not consent to push to everything the
    // account can reach. This is that sentence, as a test.
    expect(h.asked[1].repo).toBe('asadev/mookhayo')
    expect(h.asked[1].prompt).toBe(true)
    h.proxy.handle(DEVICE, { t: 'credential.deny', id: h.asked[1].id })
    expect(await other).toContain('refused on your device')
  })

  it('does not let one device’s approval answer for another device', async () => {
    const h = harness()
    const mine = await h.key(DEVICE)
    const theirs = await h.key(OTHER_DEVICE)

    const first = h.post(mine)
    await until(() => h.asked.length === 1, 'the first question')
    h.proxy.handle(DEVICE, { t: 'credential.ack', id: h.asked[0].id })
    h.proxy.handle(DEVICE, {
      t: 'credential.answer',
      id: h.asked[0].id,
      username: 'octocat',
      password: 'a',
      remember: true,
    })
    await first

    const second = h.post(theirs)
    await until(() => h.asked.length === 2, 'the second question')
    expect(h.asked[1].prompt).toBe(true)
    h.proxy.handle(OTHER_DEVICE, { t: 'credential.deny', id: h.asked[1].id })
    await second
  })

  it('ignores “remember” on a request nobody was asked about', async () => {
    const h = harness({ ancestry: ['/usr/bin/git fetch origin'] })
    const key = await h.key()

    const first = h.post(key)
    await until(() => h.asked.length === 1, 'the fetch')
    h.proxy.handle(DEVICE, { t: 'credential.ack', id: h.asked[0].id })
    // Consent nobody was asked for is not consent. Recording this would turn a
    // silent fetch into a standing permission to push.
    h.proxy.handle(DEVICE, {
      t: 'credential.answer',
      id: h.asked[0].id,
      username: 'octocat',
      password: 'a',
      remember: true,
    })
    await first

    h.running('/usr/bin/git push origin main')
    const push = postTo(urls.get(key) ?? '', key, REQUEST)
    await until(() => h.asked.length === 2, 'the push')
    expect(h.asked[1].prompt).toBe(true)
    h.proxy.handle(DEVICE, { t: 'credential.deny', id: h.asked[1].id })
    await push
  })
})

describe('the refusals', () => {
  it('says the device is not reachable, in milliseconds, when it is not connected', async () => {
    const h = harness()
    const key = await h.key()
    h.present.delete(DEVICE)

    const started = Date.now()
    const answer = await h.post(key)

    expect(answer).toContain("Your device isn't reachable — open the app to approve this push.")
    // The number this feature is judged on. A device that is simply not there is
    // answered without waiting for any deadline at all.
    expect(Date.now() - started).toBeLessThan(200)
    expect(h.asked).toHaveLength(0)
  })

  it('gives up in seconds when the app is open but nothing acknowledges', async () => {
    const h = harness({ reach: 60, decide: 5_000 })
    const key = await h.key()

    const started = Date.now()
    const answer = await h.post(key)

    // A socket that is open to an app that is not running any more looks exactly
    // like a person thinking. Without its own deadline this would have waited out
    // the human one — the thirty-second stall.
    expect(answer).toContain("isn't reachable")
    expect(Date.now() - started).toBeLessThan(2_000)
  })

  it('waits for a person once their device has said it is there', async () => {
    const h = harness({ reach: 60, decide: 150 })
    const key = await h.key()
    const answer = h.post(key)
    await until(() => h.asked.length === 1, 'the question')

    h.proxy.handle(DEVICE, { t: 'credential.ack', id: h.asked[0].id })
    // Past the reachability deadline, which the acknowledgement replaced.
    await new Promise((done) => setTimeout(done, 100))

    h.proxy.handle(DEVICE, { t: 'credential.answer', id: h.asked[0].id, username: 'octocat', password: 'late' })
    expect(await answer).toContain('password=late')
  })

  it('says nobody answered when the prompt is left on screen', async () => {
    const h = harness({ reach: 60, decide: 80 })
    const key = await h.key()
    const answer = h.post(key)
    await until(() => h.asked.length === 1, 'the question')
    h.proxy.handle(DEVICE, { t: 'credential.ack', id: h.asked[0].id })

    // A different sentence from "not reachable", because it is a different fact
    // and has a different fix.
    expect(await answer).toContain('Nobody answered on your device')
  })

  it('says so when the device denies', async () => {
    const h = harness()
    const key = await h.key()
    const answer = h.post(key)
    await until(() => h.asked.length === 1, 'the question')
    h.proxy.handle(DEVICE, { t: 'credential.ack', id: h.asked[0].id })
    h.proxy.handle(DEVICE, { t: 'credential.deny', id: h.asked[0].id })

    expect(await answer).toContain('That push was refused on your device.')
  })

  it('tells the truth when the device has no GitHub connected', async () => {
    const h = harness()
    const key = await h.key()
    const answer = h.post(key)
    await until(() => h.asked.length === 1, 'the question')
    h.proxy.handle(DEVICE, { t: 'credential.deny', id: h.asked[0].id, reason: 'no-account' })

    // Not a refusal, and telling somebody "denied" when the truth is "you have
    // not signed in yet" sends them looking for a decision they never made.
    await expect(answer).resolves.toContain('No GitHub account is connected')
  })

  it('answers immediately when the device disappears mid-operation', async () => {
    const h = harness({ reach: 5_000, decide: 5_000 })
    const key = await h.key()
    const answer = h.post(key)
    await until(() => h.asked.length === 1, 'the question')
    h.proxy.handle(DEVICE, { t: 'credential.ack', id: h.asked[0].id })

    const started = Date.now()
    h.present.delete(DEVICE)
    h.proxy.connectionClosed(DEVICE)

    expect(await answer).toContain("isn't reachable")
    expect(Date.now() - started).toBeLessThan(500)
  })

  it('keeps waiting when one of a device’s two sockets closes', async () => {
    const h = harness({ reach: 5_000, decide: 5_000 })
    const key = await h.key()
    const answer = h.post(key)
    await until(() => h.asked.length === 1, 'the question')
    h.proxy.handle(DEVICE, { t: 'credential.ack', id: h.asked[0].id })

    // A phone and a tablet, and the tablet went to sleep. The person is still
    // holding the thing that is showing the prompt.
    h.proxy.connectionClosed(DEVICE)
    h.proxy.handle(DEVICE, { t: 'credential.answer', id: h.asked[0].id, username: 'octocat', password: 'still-here' })
    expect(await answer).toContain('still-here')
  })

  it('ends everything in flight when the device is revoked', async () => {
    const h = harness({ reach: 5_000, decide: 5_000 })
    const key = await h.key()
    const answer = h.post(key)
    await until(() => h.asked.length === 1, 'the question')
    h.proxy.handle(DEVICE, { t: 'credential.ack', id: h.asked[0].id })

    h.proxy.forget(DEVICE)
    expect(await answer).toContain('no longer allowed')
  })

  it('forgets a revoked device’s approvals, and its key', async () => {
    const h = harness()
    const key = await h.key()

    const first = h.post(key)
    await until(() => h.asked.length === 1, 'the question')
    h.proxy.handle(DEVICE, { t: 'credential.ack', id: h.asked[0].id })
    h.proxy.handle(DEVICE, {
      t: 'credential.answer',
      id: h.asked[0].id,
      username: 'octocat',
      password: 'a',
      remember: true,
    })
    await first

    h.proxy.forget(DEVICE)
    // Revocation is disconnection, and there is nothing to clean up afterwards
    // because nothing was ever written down. The key stops working with it.
    expect(await h.post(key)).toContain('403')
  })

  it('ignores an answer from a device that was not asked', async () => {
    const h = harness({ reach: 200, decide: 5_000 })
    const key = await h.key()
    const answer = h.post(key)
    await until(() => h.asked.length === 1, 'the question')

    // Dropped in silence rather than refused: a device that guessed an id must
    // not learn that it guessed one that exists.
    h.proxy.handle(OTHER_DEVICE, { t: 'credential.ack', id: h.asked[0].id })
    h.proxy.handle(OTHER_DEVICE, {
      t: 'credential.answer',
      id: h.asked[0].id,
      username: 'someone-else',
      password: 'not-theirs',
    })

    const result = await answer
    expect(result).not.toContain('not-theirs')
    expect(result).toContain("isn't reachable")
  })

  it('stops answering for a session that has exited', async () => {
    const h = harness()
    const guest = await h.proxy.openGuestSession(DEVICE)
    const key = guest.env.set[CREDENTIAL_KEY_VAR]
    const url = guest.env.set[CREDENTIAL_URL_VAR]
    guest.started('session-9')

    h.proxy.sessionEnded('session-9')
    // Every process on this machine runs as the same account, so a key that
    // outlived its session is not a theoretical caller.
    expect(await postTo(url, key, REQUEST)).toContain('403')
  })
})

describe('the loopback endpoint', () => {
  it('refuses a key it never issued', async () => {
    const h = harness()
    const key = await h.key()
    expect(await postTo(urls.get(key) ?? '', 'f'.repeat(64), REQUEST)).toContain('403')
  })

  it('refuses a request with no key at all', async () => {
    const h = harness()
    const key = await h.key()
    expect(await postTo(urls.get(key) ?? '', '', REQUEST)).toContain('403')
  })

  it('refuses a browser that was pointed at it by a hostile page', async () => {
    const h = harness()
    const key = await h.key()
    const url = new URL(urls.get(key) ?? '')
    const answer = await new Promise<string>((resolve, reject) => {
      const req = httpRequest(
        {
          host: '127.0.0.1',
          port: url.port,
          path: url.pathname,
          method: 'POST',
          // A rebound name resolving to loopback. It cannot guess a key either,
          // and refusing costs nothing.
          headers: { host: 'attacker.example', [CREDENTIAL_HEADER]: key },
        },
        (res) => resolve(String(res.statusCode)),
      )
      req.on('error', reject)
      req.end(REQUEST)
    })
    expect(answer).toBe('403')
  })

  it('survives the git on the other end being killed mid-question', async () => {
    const h = harness({ reach: 5_000, decide: 5_000 })
    const key = await h.key()
    const url = new URL(urls.get(key) ?? '')

    // A push can wait a minute on a person, and in that minute somebody can
    // press Ctrl-C. Writing to that response throws, and a throw out of the
    // settled half of a promise is an unhandled rejection in the process running
    // every one of the user's terminals.
    const req = httpRequest({
      host: '127.0.0.1',
      port: url.port,
      path: url.pathname,
      method: 'POST',
      headers: { [CREDENTIAL_HEADER]: key, [PID_HEADER]: '4242' },
    })
    req.on('error', () => {})
    req.end(REQUEST)

    await until(() => h.asked.length === 1, 'the question')
    req.destroy()
    await new Promise((done) => setTimeout(done, 20))

    const rejections: unknown[] = []
    process.on('unhandledRejection', (reason) => rejections.push(reason))
    h.proxy.handle(DEVICE, { t: 'credential.ack', id: h.asked[0].id })
    h.proxy.handle(DEVICE, { t: 'credential.answer', id: h.asked[0].id, username: 'octocat', password: 'a' })
    await new Promise((done) => setTimeout(done, 50))
    process.removeAllListeners('unhandledRejection')

    expect(rejections).toEqual([])

    // And the desk is still usable afterwards, which is the half a crash would
    // have taken with it.
    const next = h.post(key)
    await until(() => h.asked.length === 2, 'the next question')
    h.proxy.handle(DEVICE, { t: 'credential.ack', id: h.asked[1].id })
    h.proxy.handle(DEVICE, { t: 'credential.answer', id: h.asked[1].id, username: 'octocat', password: 'after' })
    expect(await next).toContain('password=after')
  })

  it('refuses anything that is not a POST to its one path', async () => {
    const h = harness()
    const key = await h.key()
    const url = new URL(urls.get(key) ?? '')
    const status = await new Promise<string>((resolve, reject) => {
      const req = httpRequest({ host: '127.0.0.1', port: url.port, path: url.pathname, method: 'GET' }, (res) =>
        resolve(String(res.statusCode)),
      )
      req.on('error', reject)
      req.end()
    })
    expect(status).toBe('405')
  })
})

describe('what is left on this machine', () => {
  it('writes no secret into the helper on disk', async () => {
    const h = harness()
    const guest = await h.proxy.openGuestSession(DEVICE)
    const helper = guest.env.set.GIT_ASKPASS
    const script = readFileSync(helper, 'utf8')

    // The address and the key both travel in the environment. A script with a
    // token baked into it would be a live secret in a file, for a feature whose
    // whole promise is that no secret is written here.
    expect(script).not.toContain(guest.env.set[CREDENTIAL_KEY_VAR])
    expect(script).not.toContain(guest.env.set[CREDENTIAL_URL_VAR])
    expect(script).toContain(CREDENTIAL_URL_VAR)
    expect(script).toContain(CREDENTIAL_KEY_VAR)
  })

  it('gives two devices two directories', async () => {
    const h = harness()
    const mine = await h.proxy.openGuestSession(DEVICE)
    const theirs = await h.proxy.openGuestSession(OTHER_DEVICE)
    expect(mine.env.set.GIT_CONFIG_GLOBAL).not.toBe(theirs.env.set.GIT_CONFIG_GLOBAL)
    // Named by a hash rather than by the id itself: the next device-id format is
    // not this module's decision, and a path built from somebody else's
    // identifier is a path that eventually contains a separator.
    expect(mine.env.set.GIT_CONFIG_GLOBAL).toContain(deviceKey(DEVICE))
  })

  it('gives two sessions on one device two keys', async () => {
    const h = harness()
    const first = await h.proxy.openGuestSession(DEVICE)
    const second = await h.proxy.openGuestSession(DEVICE)
    expect(first.env.set[CREDENTIAL_KEY_VAR]).not.toBe(second.env.set[CREDENTIAL_KEY_VAR])
  })

  it('closes a grant whose session never started', async () => {
    const h = harness()
    const guest = await h.proxy.openGuestSession(DEVICE)
    const key = guest.env.set[CREDENTIAL_KEY_VAR]
    const url = guest.env.set[CREDENTIAL_URL_VAR]
    // The key exists before the session does, because it has to be in the
    // environment the spawn is handed. A spawn that then failed would otherwise
    // leave a live key belonging to nothing.
    guest.close()
    expect(await postTo(url, key, REQUEST)).toContain('403')
  })
})

describe('the capability it is negotiated with', () => {
  it('is the name the frames are prefixed with', () => {
    // `upload` serves `upload.*`; this serves `credential.*`. A capability whose
    // name does not match its verbs is one more thing for two ends to disagree
    // about.
    expect(CAPABILITY.credential).toBe('credential')
  })
})
