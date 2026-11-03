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
  /** The ids treated as the owner's own. A guest is any id outside this set. */
  own: Set<string>
  key(deviceId?: string): Promise<string>
  post(key: string, body?: string): Promise<string>
}

const made: CredentialProxy[] = []

afterEach(async () => {
  await Promise.all(made.splice(0).map((proxy) => proxy.stop()))
})

/** The machine's own GitHub login, as the proxy hands it to git. */
const HOST_LOGIN = { username: 'asadev', password: 'ghp_host' }

/**
 * A desk in front of a proxy that answers git from the machine's own login.
 *
 * Since 2026-08-27 there is no phone to fake: git on the machine is answered in
 * this process from `hostCredential`. So the harness is a host login (or none,
 * for the not-connected case) and a set of the owner's own devices — a guest is
 * any id outside it, and is refused rather than handed the owner's account.
 */
function harness(
  options: { hostCredential?: () => { username: string; password: string } | null; own?: string[] } = {},
): Harness {
  const own = new Set(options.own ?? [DEVICE, OTHER_DEVICE])

  const proxy = createCredentialProxy({
    dir: mkdtempSync(join(tmpdir(), 'td-credentials-')),
    hostCredential: options.hostCredential ?? (() => HOST_LOGIN),
  })
  made.push(proxy)

  const post: DevicePost = {
    ask: () => 0,
    reachable: () => false,
    ownDevice: (deviceId) => own.has(deviceId),
  }
  proxy.serve(post)

  return {
    proxy,
    own,
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

describe('answering git from the machine’s own login', () => {
  it('answers from the host account, asking nobody, at once', async () => {
    const h = harness()
    const key = await h.key()

    const started = Date.now()
    // No phone, no round-trip: the machine owns the login now, so git is answered
    // in this process and returns at once — the whole of "it can push/deploy on
    // its own even when the phone is closed."
    expect(await h.post(key)).toBe('200 username=asadev\npassword=ghp_host\n')
    expect(Date.now() - started).toBeLessThan(500)
  })

  it('answers every repository from the one account, with no per-repo gate', async () => {
    // The old proxy asked once per repository because the token belonged to a
    // person who got to see whose name went on the commit. The machine's own
    // login has no such prompt: it is the machine's, for whatever git it runs.
    const h = harness()
    const key = await h.key()
    expect(await h.post(key, REQUEST)).toContain('password=ghp_host')
    expect(await h.post(key, OTHER_REPO)).toContain('password=ghp_host')
  })

  it('refuses a malformed request before the token is read', async () => {
    const h = harness()
    const key = await h.key()
    // A body that is not git's credential protocol names no host, and a live
    // credential must never be handed back to a request this end could not parse.
    const answer = await h.post(key, 'this is not the git credential protocol\n\n')
    expect(answer).toContain('did not say which host')
    expect(answer).not.toContain('ghp_host')
  })
})

describe('the refusals', () => {
  it('tells the truth when the machine has no GitHub connected', async () => {
    // Not a phone problem any more: the fix is to connect GitHub on the host,
    // which is a thing the host itself can now do (`github.connect`, or its panel).
    const h = harness({ hostCredential: () => null })
    const key = await h.key()
    expect(await h.post(key)).toContain('No GitHub account is connected on this machine')
  })

  it('does not hand the owner’s login to a guest', async () => {
    // The one promise of the old proxy that survives the flip: a device granted a
    // folder never pushes as the machine's owner. The owner drives their own
    // machine; a guest gets their own token, not this one.
    const h = harness({ own: [DEVICE] })
    const guestKey = await h.key(OTHER_DEVICE)
    const answer = await h.post(guestKey)
    expect(answer).toContain('not shared with other devices')
    expect(answer).not.toContain('ghp_host')
  })

  it('answers the owner’s own device from the host account', async () => {
    const h = harness({ own: [DEVICE] })
    const key = await h.key(DEVICE)
    expect(await h.post(key)).toContain('password=ghp_host')
  })

  it('treats the caller as the owner when the desk names no device rule', async () => {
    // A `serve()` with no `ownDevice` — an older wiring, or a test — is the
    // single-device world, where there is no guest to refuse. Production always
    // wires it; this is the fail-open direction, and it opens onto the owner.
    const proxy = createCredentialProxy({
      dir: mkdtempSync(join(tmpdir(), 'td-credentials-')),
      hostCredential: () => HOST_LOGIN,
    })
    made.push(proxy)
    proxy.serve({ ask: () => 0, reachable: () => false })
    const guest = await proxy.openGuestSession(DEVICE)
    const key = guest.env.set[CREDENTIAL_KEY_VAR]
    guest.started('s1')
    expect(await postTo(guest.env.set[CREDENTIAL_URL_VAR], key, REQUEST)).toContain('password=ghp_host')
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

  it('stops answering a revoked device’s key', async () => {
    const h = harness()
    const key = await h.key()
    expect(await h.post(key)).toContain('password=ghp_host')

    h.proxy.forget(DEVICE)
    // Revocation is disconnection, and there is nothing to clean up afterwards
    // because nothing was ever written down. The key stops working with it.
    expect(await h.post(key)).toContain('403')
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

  it('survives the git on the other end being killed mid-request', async () => {
    const h = harness()
    const key = await h.key()
    const url = new URL(urls.get(key) ?? '')

    // The answer is in-process and instant now, but a client can still hang up
    // the moment it has posted — and writing to a response whose socket is gone
    // throws, which out of the settled half of a promise is an unhandled
    // rejection in the process running every one of the user's terminals.
    const rejections: unknown[] = []
    const onReject = (reason: unknown): void => {
      rejections.push(reason)
    }
    process.on('unhandledRejection', onReject)
    for (let i = 0; i < 8; i += 1) {
      const req = httpRequest({
        host: '127.0.0.1',
        port: url.port,
        path: url.pathname,
        method: 'POST',
        headers: { [CREDENTIAL_HEADER]: key, [PID_HEADER]: '4242' },
      })
      req.on('error', () => {})
      req.end(REQUEST)
      req.destroy()
    }
    await new Promise((done) => setTimeout(done, 60))
    process.removeListener('unhandledRejection', onReject)

    expect(rejections).toEqual([])

    // And the desk is still usable afterwards, which is the half a crash would
    // have taken with it.
    expect(await h.post(key)).toContain('password=ghp_host')
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

describe('what it is negotiated with', () => {
  it('is nothing on the wire any more — git is answered in-process', () => {
    // `credential` was the capability a phone advertised to say it could answer a
    // git login. Since 2026-08-27 the machine answers its own git, so nothing is
    // negotiated for this over the wire; the name is kept only so a stale client's
    // `credential.*` frame is recognised and ignored rather than closing the
    // channel. The wire capability that replaced the whole idea — a phone
    // *driving* the host's login instead of holding one — is `github`.
    expect(CAPABILITY.credential).toBe('credential')
    expect(CAPABILITY.github).toBe('github')
  })
})
