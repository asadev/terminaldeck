import { execFile } from 'node:child_process'
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  CONFIG_FILE,
  CREDENTIAL_KEY_VAR,
  CREDENTIAL_URL_VAR,
  HELPER_FILE,
  askpassScript,
  guestGitConfigEntries,
  guestGitEnv,
  prepareGuestGit,
  shellPath,
} from './git-guest'

/**
 * The claim this file has to defend is not "the code sets some variables". It is
 * that a session started for somebody else's device **cannot reach the owner's
 * GitHub login**, and that is a claim about what `git` does, not about what this
 * module returns.
 *
 * So the interesting half of this file runs the real git. A fake credential
 * helper stands in for `osxkeychain`, wired into a temporary global config and a
 * temporary system config and, in one case, into a repository's own config —
 * because those are the three places a helper actually lives and they have three
 * different precedences. Each test asserts on a marker file the fake helper
 * writes: it either ran or it did not, and nothing about that is a matter of
 * interpretation.
 *
 * It matters that this was not obvious. The first version of this feature added
 * a helper and did not clear the existing ones, and `git credential fill`
 * answered from the login keychain with the machine owner's real token — the new
 * helper was never executed at all. That is the shape of the bug the empty
 * `credential.helper` entry exists to close, and the test named for it is the one
 * that would have caught it.
 *
 * The git cases are skipped on Windows. The script is POSIX shell run through the
 * shell git itself provides, which is present there — but nothing has watched it,
 * and a test that claims a platform it has never run on is worse than one that
 * says so. The pure cases below cover both.
 */

const run = promisify(execFile)
const POSIX = process.platform !== 'win32'

let root: string

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'td-guest-git-'))
})

afterEach(() => {
  // Left on disk deliberately when a test fails — the config and the marker are
  // what tell you why — and the OS clears the temp directory.
})

/**
 * A stand-in for the machine owner's credential helper.
 *
 * Writes where it was invoked from and answers with a credential nobody should
 * ever see. The marker is the assertion: a test that has to prove a *negative*
 * needs positive evidence that the thing which should not have run did not run,
 * and "the output did not contain the password" would also pass if git had
 * failed for an unrelated reason.
 */
function hostHelper(name: string): { path: string; marker: string } {
  const marker = join(root, `${name}.ran`)
  const path = join(root, `${name}.sh`)
  writeFileSync(
    path,
    `#!/bin/sh\ncat > /dev/null\necho "$1" >> ${JSON.stringify(marker)}\nprintf 'username=theowner\\npassword=owner-secret\\n'\n`,
    { mode: 0o755 },
  )
  chmodSync(path, 0o755)
  return { path, marker }
}

/** The environment a session would have without any of this: the owner's git. */
function ownerEnv(global: string, system: string): NodeJS.ProcessEnv {
  return {
    ...process.env,
    HOME: root,
    GIT_CONFIG_GLOBAL: global,
    GIT_CONFIG_SYSTEM: system,
    // Nothing in these tests may reach a terminal or a keychain of its own.
    GIT_TERMINAL_PROMPT: '0',
  }
}

/** `git credential fill`, which is the credential path with no network in it. */
async function fill(env: NodeJS.ProcessEnv, cwd: string, path = 'asadev/terminaldeck.git'): Promise<string> {
  const child = run('git', ['credential', 'fill'], { env, cwd })
  child.child.stdin?.end(`protocol=https\nhost=github.com\npath=${path}\n\n`)
  try {
    const { stdout } = await child
    return stdout
  } catch (error) {
    // A refusal is a legitimate outcome here and is the *expected* one in most of
    // these tests, so it is returned rather than thrown. What is being asserted
    // is which helper ran, not whether git succeeded.
    return error instanceof Error && 'stdout' in error ? String(error.stdout) : ''
  }
}

describe('the settings that outrank every file on the machine', () => {
  it('clears the existing helpers before adding its own', () => {
    const entries = guestGitConfigEntries({ dir: root, link: link() })
    const helpers = entries.filter(([key]) => key === 'credential.helper')
    expect(helpers[0]).toEqual(['credential.helper', ''])
    expect(helpers).toHaveLength(2)
    expect(helpers[1][1]).toContain(HELPER_FILE)
    // The order is the whole of it. Ours after the clear, never before.
    expect(entries.findIndex(([, value]) => value === '')).toBeLessThan(
      entries.findIndex(([key, value]) => key === 'credential.helper' && value !== ''),
    )
  })

  it('clears them even when there is no proxy to add', () => {
    const entries = guestGitConfigEntries({ dir: root })
    const helpers = entries.filter(([key]) => key === 'credential.helper')
    // Half one on its own: nobody answers, which is the point. A list with the
    // clear missing would fall straight through to the owner's helper.
    expect(helpers).toEqual([['credential.helper', '']])
  })

  it('asks git for the repository path, which is what makes per-repo consent possible', () => {
    expect(guestGitConfigEntries({ dir: root })).toContainEqual(['credential.useHttpPath', 'true'])
  })

  it('sends GitHub ssh remotes the long way round, through the proxy', () => {
    const entries = guestGitConfigEntries({ dir: root })
    const rewrites = entries.filter(([key]) => key.endsWith('.insteadOf')).map(([, value]) => value)
    expect(rewrites).toEqual(['git@github.com:', 'ssh://git@github.com/'])
  })

  it('leaves ssh with no agent and no identity', () => {
    const [, command] = guestGitConfigEntries({ dir: root }).find(([key]) => key === 'core.sshCommand') ?? []
    expect(command).toContain('IdentityAgent=none')
    expect(command).toContain('IdentitiesOnly=yes')
    expect(command).toContain('IdentityFile=')
  })

  it('spells the null device per platform', () => {
    const windows = guestGitConfigEntries({ dir: root, platform: 'win32' }).find(
      ([key]) => key === 'core.sshCommand',
    )
    expect(windows?.[1]).toContain('IdentityFile=NUL')
  })
})

describe('the environment a guest session gets', () => {
  it('redirects the global config and numbers the overrides', () => {
    const { set } = guestGitEnv({ dir: root, configFile: join(root, CONFIG_FILE) })
    expect(set.GIT_CONFIG_GLOBAL).toBe(join(root, CONFIG_FILE))
    const count = Number(set.GIT_CONFIG_COUNT)
    expect(count).toBeGreaterThan(0)
    for (let i = 0; i < count; i += 1) {
      expect(set[`GIT_CONFIG_KEY_${i}`], `key ${i}`).toBeTruthy()
      expect(set[`GIT_CONFIG_VALUE_${i}`], `value ${i}`).toBeDefined()
    }
    // One past the count would be a stale pair from a longer list, which git
    // ignores and a reader does not.
    expect(set[`GIT_CONFIG_KEY_${count}`]).toBeUndefined()
  })

  it('takes the token variables away rather than blanking them', () => {
    const { set, remove } = guestGitEnv({ dir: root, configFile: join(root, CONFIG_FILE) })
    for (const name of ['GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN']) {
      expect(remove, name).toContain(name)
      expect(set[name], name).toBeUndefined()
    }
  })

  it('takes the ssh agent away, which is the door a credential helper never sees', () => {
    expect(guestGitEnv({ dir: root, configFile: join(root, CONFIG_FILE) }).remove).toContain('SSH_AUTH_SOCK')
  })

  it('points gh somewhere that is not the owner’s', () => {
    const { set } = guestGitEnv({ dir: root, configFile: join(root, CONFIG_FILE) })
    expect(set.GH_CONFIG_DIR.startsWith(root)).toBe(true)
  })

  it('refuses to let git fall back to the terminal', () => {
    // The session has a real terminal on the other end of a socket. A prompt
    // there would be answered by somebody about a repository it does not name.
    expect(guestGitEnv({ dir: root, configFile: join(root, CONFIG_FILE) }).set.GIT_TERMINAL_PROMPT).toBe('0')
  })

  it('never removes a variable it also sets', () => {
    const { set, remove } = guestGitEnv({ dir: root, configFile: join(root, CONFIG_FILE), link: link() })
    // `GIT_ASKPASS` is on the removal list until there is a helper to put there.
    expect(set.GIT_ASKPASS).toBe(link().helper)
    for (const name of remove) expect(set[name], name).toBeUndefined()
  })

  it('names which of its variables are paths, for the WSL crossing', () => {
    const { set, paths } = guestGitEnv({ dir: root, configFile: join(root, CONFIG_FILE), link: link() })
    expect(paths).toContain('GIT_CONFIG_GLOBAL')
    expect(paths).toContain('GH_CONFIG_DIR')
    for (const name of paths) expect(set[name], name).toBeTruthy()
  })

  it('carries the endpoint in the environment, so the script on disk holds no secret', () => {
    const { set } = guestGitEnv({ dir: root, configFile: join(root, CONFIG_FILE), link: link() })
    expect(set[CREDENTIAL_URL_VAR]).toBe(link().url)
    expect(set[CREDENTIAL_KEY_VAR]).toBe(link().key)
    expect(askpassScript()).not.toContain(link().key)
  })
})

describe('the files it puts in place', () => {
  it('writes the config once and then leaves it to the guest', () => {
    const dir = join(root, 'device-a')
    prepareGuestGit({ dir, link: link() })
    const config = join(dir, CONFIG_FILE)
    writeFileSync(config, `${readFileSync(config, 'utf8')}\n[user]\n\temail = guest@example.com\n`)
    prepareGuestGit({ dir, link: link() })
    // A guest who set an identity keeps it. Rewriting on every spawn would make
    // `git config --global` a control that silently does nothing.
    expect(readFileSync(config, 'utf8')).toContain('guest@example.com')
  })

  it('rewrites the helper every time, because it belongs to this code', () => {
    const dir = join(root, 'device-b')
    mkdirSync(dir, { recursive: true })
    const helper = join(root, HELPER_FILE)
    writeFileSync(helper, '#!/bin/sh\nexit 0\n', { mode: 0o700 })
    prepareGuestGit({ dir, link: { url: 'http://127.0.0.1:1/credential', key: 'k', helper } })
    expect(readFileSync(helper, 'utf8')).toBe(askpassScript())
  })

  it('writes no helper at all when there is no proxy', () => {
    const dir = join(root, 'device-c')
    prepareGuestGit({ dir })
    expect(existsSync(join(root, HELPER_FILE))).toBe(false)
  })
})

describe('quoting the helper path for the shell git runs it through', () => {
  it('survives a space, which is where this lands on a Mac', () => {
    expect(shellPath('/Users/x/Application Support/Terminal Deck/askpass.sh')).toBe(
      "'/Users/x/Application Support/Terminal Deck/askpass.sh'",
    )
  })

  it('turns a Windows path into one the shell git ships will not eat', () => {
    // Backslashes inside quotes are escapes in that shell, so `C:\Users\x`
    // arrives as `C:Usersx` and the helper is a path that does not exist.
    expect(shellPath('C:\\Users\\x\\askpass.sh')).toBe("'C:/Users/x/askpass.sh'")
  })

  it('escapes a quote rather than ending the argument on it', () => {
    expect(shellPath("/tmp/it's here/askpass.sh")).toBe(`'/tmp/it'\\''s here/askpass.sh'`)
  })
})

describe.skipIf(!POSIX)('what git actually does', () => {
  it('answers from the owner’s helper when nothing has been done about it', async () => {
    const owner = hostHelper('owner')
    const global = join(root, 'owner-gitconfig')
    writeFileSync(global, `[credential]\n\thelper = ${owner.path}\n`)
    const system = join(root, 'owner-systemconfig')
    writeFileSync(system, '')

    const out = await fill(ownerEnv(global, system), root)

    // The baseline, and the reason this feature exists. Without it the rest of
    // this describe block would be asserting that something did not happen in a
    // world where it never happened anyway.
    expect(readFileSync(owner.marker, 'utf8').trim()).toBe('get')
    expect(out).toContain('username=theowner')
  })

  it('cuts the owner’s helper out, even from the system config', async () => {
    const owner = hostHelper('owner')
    const machine = hostHelper('machine')
    const global = join(root, 'owner-gitconfig')
    writeFileSync(global, `[credential]\n\thelper = ${owner.path}\n`)
    const system = join(root, 'owner-systemconfig')
    // Where Git for Windows keeps `manager`. Redirecting the *global* config
    // does nothing about this one, which is why the clearing entry exists.
    writeFileSync(system, `[credential]\n\thelper = ${machine.path}\n`)

    const dir = join(root, 'device-a')
    const guest = prepareGuestGit({ dir })
    const env = { ...ownerEnv(global, system), ...guest.set }
    for (const name of guest.remove) delete env[name]

    const out = await fill(env, root)

    expect(existsSync(owner.marker), 'the global helper ran').toBe(false)
    expect(existsSync(machine.marker), 'the system helper ran').toBe(false)
    expect(out).not.toContain('owner-secret')
  })

  it('beats a helper set in the repository itself', async () => {
    const owner = hostHelper('owner')
    const global = join(root, 'owner-gitconfig')
    writeFileSync(global, '')
    const system = join(root, 'owner-systemconfig')
    writeFileSync(system, '')

    const repo = join(root, 'repo')
    mkdirSync(repo, { recursive: true })
    await run('git', ['init', '-q'], { cwd: repo, env: ownerEnv(global, system) })
    // The granted folders are the owner's own checkouts, so a helper configured
    // locally in one of them is not a hypothetical. A global file we control
    // would lose to this; the environment entries do not.
    await run('git', ['config', 'credential.helper', owner.path], { cwd: repo, env: ownerEnv(global, system) })

    const guest = prepareGuestGit({ dir: join(root, 'device-a') })
    const env = { ...ownerEnv(global, system), ...guest.set }
    for (const name of guest.remove) delete env[name]

    await fill(env, repo)

    expect(existsSync(owner.marker), 'the repository’s own helper ran').toBe(false)
  })

  it('hands its own helper the repository name, which askpass could never carry', async () => {
    const global = join(root, 'owner-gitconfig')
    writeFileSync(global, '')
    const system = join(root, 'owner-systemconfig')
    writeFileSync(system, '')

    const helper = join(root, HELPER_FILE)
    const seen = join(root, 'seen.txt')
    const guest = prepareGuestGit({
      dir: join(root, 'device-a'),
      link: { url: 'http://127.0.0.1:1/credential', key: 'k', helper },
    })
    // A stand-in for the real script, written *after* the preparation that puts
    // the real one there — same contract, but it records the request instead of
    // posting it, so this test is about what git hands a helper rather than
    // about HTTP.
    writeFileSync(
      helper,
      `#!/bin/sh\necho "argv=$1" >> ${JSON.stringify(seen)}\ncat >> ${JSON.stringify(seen)}\nprintf 'username=guest\\npassword=from-their-phone\\n'\n`,
      { mode: 0o755 },
    )
    chmodSync(helper, 0o755)

    const env = { ...ownerEnv(global, system), ...guest.set }
    for (const name of guest.remove) delete env[name]

    const out = await fill(env, root)

    const request = readFileSync(seen, 'utf8')
    expect(request).toContain('argv=get')
    expect(request).toContain('host=github.com')
    // The whole reason this is a credential helper and not GIT_ASKPASS: a prompt
    // string names a host, and an approval scoped to a host is consent to push
    // anywhere the account can reach.
    expect(request).toContain('path=asadev/terminaldeck.git')
    expect(out).toContain('password=from-their-phone')
  })

  it('refuses the askpass hat silently, because git has already said why', async () => {
    const helper = join(root, HELPER_FILE)
    writeFileSync(helper, askpassScript(), { mode: 0o755 })
    chmodSync(helper, 0o755)

    // Exactly how git invokes GIT_ASKPASS: one argument, the prompt.
    const result = await run('sh', [helper, "Password for 'https://github.com'"], {
      env: { ...process.env, [CREDENTIAL_URL_VAR]: 'http://127.0.0.1:1/credential', [CREDENTIAL_KEY_VAR]: 'k' },
    }).then(
      (ok) => ({ code: 0, stdout: ok.stdout, stderr: ok.stderr }),
      (error: { code?: number; stdout?: string; stderr?: string }) => ({
        code: error.code ?? -1,
        stdout: error.stdout ?? '',
        stderr: error.stderr ?? '',
      }),
    )

    // Non-zero and empty, both halves. An exit code alone would not be enough:
    // git ignores the status and reads stdout, so a helper that printed a blank
    // line here would hand git an empty username rather than a refusal.
    expect(result.code).not.toBe(0)
    expect(result.stdout).toBe('')
    // Silent, because git reaches this only after the `get` branch has already
    // printed the sentence a person can act on. A second explanation about a
    // different thing read as a contradiction — see `askpassScript`.
    expect(result.stderr).toBe('')
  })

  it('refuses to store anything on this machine', async () => {
    const helper = join(root, HELPER_FILE)
    writeFileSync(helper, askpassScript(), { mode: 0o755 })
    chmodSync(helper, 0o755)

    // `store` is git offering to save the credential here. The answer is no, and
    // it is silent so that git carries on rather than reporting a broken helper.
    const child = run('sh', [helper, 'store'], {
      env: { ...process.env, [CREDENTIAL_URL_VAR]: 'http://127.0.0.1:1/credential', [CREDENTIAL_KEY_VAR]: 'k' },
    })
    child.child.stdin?.end('protocol=https\nhost=github.com\nusername=guest\npassword=theirs\n\n')
    const { stdout } = await child
    expect(stdout).toBe('')
    // Nothing on disk anywhere near this directory learned the password.
    for (const name of [CONFIG_FILE, HELPER_FILE]) {
      const file = join(root, name)
      if (existsSync(file)) expect(readFileSync(file, 'utf8')).not.toContain('theirs')
    }
  })
})

function link(): { url: string; key: string; helper: string } {
  return { url: 'http://127.0.0.1:49152/credential', key: 'a'.repeat(64), helper: join(root, HELPER_FILE) }
}
