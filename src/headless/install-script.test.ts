/**
 * The installer has to be right about a machine that is not this machine.
 *
 * ## Why a test reads a shell script
 *
 * `scripts/install-headless.sh` is what `curl -fsSL https://terminaldeck.dev/install.sh | sh`
 * runs, and every interesting decision in it is made from facts about the box it
 * is running on — the OS, the architecture *as Node spells it*, the C library —
 * on boxes nobody here is sitting at. It was measured wrong once already: on
 * 2026-08-18 the owner's own server (aarch64, Ubuntu 24.04.4, glibc 2.39) had no
 * node and no npm, and the installer refused it, so the one machine the headless
 * host was built for was the one machine it could not be installed on.
 *
 * The fix — fetch an official Node into a private prefix and use that — is
 * mostly a URL and a checksum, which is exactly the kind of thing that is
 * correct for the architecture you tested on and silently wrong for the one you
 * did not. So the script has a dry run: it resolves everything, prints the plan
 * and writes nothing. These tests drive that with a forced platform and a local
 * mirror, and read back the URL it *would* have used.
 *
 * ## Why the checksums below are real
 *
 * They are copied out of the file the Node project publishes at
 * `https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt`, verbatim, two spaces
 * and all. `node-v22.23.2-linux-arm64.tar.gz` was downloaded and hashed on
 * 2026-08-19 and came back `013b59cf…`, matching the line below. A fixture with
 * invented hashes would still exercise the parsing and would stop proving the
 * one thing worth proving: that this asks nodejs.org for a file that exists.
 */

import { execFileSync } from 'node:child_process'
import { currentPlatform, withPath } from '../main/platform/host'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { beforeAll, describe, expect, it } from 'vitest'

const SCRIPT = fileURLToPath(new URL('../../scripts/install-headless.sh', import.meta.url))
const script = readFileSync(SCRIPT, 'utf8')

/** Real lines from the published SHASUMS256.txt for v22.23.2. */
const SHASUMS = [
  '77c63032fd4ab8e98e0ae7db9d79e396659e04af95a5edf8e1ca869e426c04a5  node-v22.23.2-aix-ppc64.tar.gz',
  '61130f394c1630d211dd50aecc4353d379480f36d3ac913cd85dbba1aed585c6  node-v22.23.2-darwin-arm64.tar.gz',
  '58e99022c2ff89395576cc7fd4d98cea24bb68081475d5f88b801ee8729fb026  node-v22.23.2-darwin-x64.tar.gz',
  '013b59cfd2819703a6f4a14ab891fc46fc2a4e3f5bcd92de3fb4929b43e35b30  node-v22.23.2-linux-arm64.tar.gz',
  'fff4078c5def658577f92c88db7db3bc0072924bfb93fe52c1e744a54e94abb8  node-v22.23.2-linux-arm64.tar.xz',
  '2a2f59eb8fd9dec27b3bee17c729131d1fd3e6d9943d479f1156ce38af8cd599  node-v22.23.2-linux-armv7l.tar.gz',
  'b294a556e639d64338823920e5866c21c02741742d2e1529ee1a225c1ec9252a  node-v22.23.2-linux-x64.tar.gz',
  '9a06b4bd1eb0b1e1a1b57e2b47b6b0bd4b3fb4a02f6b83bbf2d24d2cd0a1cb03  node-v22.23.2.tar.gz',
  '',
].join('\n')

const ARM64_SHA = '013b59cfd2819703a6f4a14ab891fc46fc2a4e3f5bcd92de3fb4929b43e35b30'

const posix = process.platform !== 'win32'

let mirror = ''
let home = ''

beforeAll(() => {
  if (!posix) return
  const root = mkdtempSync(join(tmpdir(), 'td-install-'))
  home = join(root, 'home')
  mkdirSync(home, { recursive: true })
  // A file:// mirror laid out the way nodejs.org/dist is. `curl` speaks file://,
  // so the script's own fetch path is the thing under test rather than a mock of
  // it — the parsing, the awk field match and the URL assembly all run for real.
  mirror = join(root, 'dist')
  for (const dir of ['v22.23.2', 'latest-v22.x']) {
    mkdirSync(join(mirror, dir), { recursive: true })
    writeFileSync(join(mirror, dir, 'SHASUMS256.txt'), SHASUMS, 'utf8')
  }
})

/*
 * The environment for one run, PATH written through `withPath`.
 *
 * Not `{ PATH: ..., ...extra }`, and the reason is a guard rather than taste:
 * `platform/env-path.test.ts` refuses any object literal that both spreads an
 * environment and writes `PATH`, because Windows treats the name
 * case-insensitively and a spread of one env into a literal that writes `PATH`
 * can leave `Path` and `PATH` side by side — after which the child gets
 * whichever the OS happens to pick. It caught this file the first time it ran.
 *
 * A test is not exempt from that, deliberately: the guard is structural so that
 * nobody has to decide case by case which spread is the dangerous one.
 */
function envFor(extra: Record<string, string>, path = process.env.PATH ?? '/usr/bin:/bin'): Record<string, string> {
  return withPath(
    {
      HOME: home,
      TERMINALDECK_DRYRUN: '1',
      // This machine has a Node, and the interesting branch is the one for a
      // machine that does not.
      TERMINALDECK_FORCE_RUNTIME: '1',
      TERMINALDECK_SKIP_TOOLCHAIN_CHECK: '1',
      TERMINALDECK_NODE_MIRROR: `file://${mirror}`,
      ...extra,
    },
    path,
    currentPlatform(),
  )
}

/** Run the installer's dry run for a machine that is not this one. */
function plan(extra: Record<string, string>): string {
  return execFileSync('/bin/sh', [SCRIPT], { encoding: 'utf8', env: envFor(extra) })
}

/** The same, for the runs that are supposed to refuse. */
function refusal(extra: Record<string, string>, path = process.env.PATH ?? '/usr/bin:/bin'): string {
  try {
    // `envFor` minus the toolchain skip, so the refusals that are *about* the
    // toolchain can still fire.
    const env = envFor(extra, path)
    delete env.TERMINALDECK_SKIP_TOOLCHAIN_CHECK
    execFileSync('/bin/sh', [SCRIPT], { encoding: 'utf8', env })
  } catch (error) {
    const failure = error as { status?: number; stderr?: string }
    expect(failure.status).toBe(1)
    return failure.stderr ?? ''
  }
  throw new Error('expected the installer to refuse, and it did not')
}

describe('the installer, planning for a machine it is not running on', () => {
  it.skipIf(!posix)('asks for linux-arm64 on aarch64 — the owner’s own server', () => {
    // The measured box: aarch64 Ubuntu 24.04.4. `uname -m` says aarch64 and Node
    // spells it arm64; getting that translation wrong produces a 404 rather than
    // a wrong binary, which is at least loud, but it produces it on his server
    // rather than here.
    const out = plan({ TERMINALDECK_OS: 'Linux', TERMINALDECK_ARCH: 'aarch64', TERMINALDECK_LIBC: 'gnu' })

    expect(out).toContain('/v22.23.2/node-v22.23.2-linux-arm64.tar.gz')
    expect(out).toContain(ARM64_SHA)
    expect(out).toContain('linux arm64 (gnu)')
  })

  it.skipIf(!posix)('resolves the version out of the checksum file rather than hardcoding one', () => {
    // The script never assigns a version. It reads `latest-v22.x/SHASUMS256.txt`
    // and takes the version out of the filenames inside it, so it keeps up with
    // Node's releases without anybody editing a literal — and a literal is what
    // would rot here, quietly, until somebody's install pulled a Node from two
    // years ago. (`22.23.2` does appear in the file, in the sentence suggesting
    // how to pin one by hand, which is why this looks for the assignment.)
    expect(script).not.toMatch(/^NODE_VERSION=/m)
    expect(script).toContain('latest-v22.x')
    expect(plan({ TERMINALDECK_OS: 'Linux', TERMINALDECK_ARCH: 'aarch64' })).toContain('22.23.2')
  })

  it.skipIf(!posix)('translates every architecture into the spelling Node publishes', () => {
    const cases: [string, string, string][] = [
      ['Linux', 'x86_64', 'linux-x64'],
      ['Linux', 'aarch64', 'linux-arm64'],
      ['Linux', 'armv7l', 'linux-armv7l'],
      ['Darwin', 'arm64', 'darwin-arm64'],
      ['Darwin', 'x86_64', 'darwin-x64'],
    ]
    for (const [os, arch, expected] of cases) {
      expect(plan({ TERMINALDECK_OS: os, TERMINALDECK_ARCH: arch, TERMINALDECK_LIBC: 'gnu' })).toContain(
        `node-v22.23.2-${expected}.tar.gz`,
      )
    }
  })

  it.skipIf(!posix)('writes nothing at all while planning', () => {
    // The dry run is only worth having if it is safe to run on a production
    // server out of curiosity.
    const runtime = join(home, 'planning-only')
    plan({ TERMINALDECK_OS: 'Linux', TERMINALDECK_ARCH: 'aarch64', TERMINALDECK_RUNTIME: runtime })
    expect(existsSync(runtime)).toBe(false)
  })
})

describe('the installer, refusing a machine it cannot serve', () => {
  it.skipIf(!posix)('never builds a URL for musl, because Node publishes none', () => {
    // Alpine is the case the original comment at the top of the script was most
    // afraid of, and it is right to be: every tarball under nodejs.org/dist is
    // linked against glibc. One would unpack perfectly here and then exit with
    // "not found", which is the loader missing and reads like nothing at all.
    const out = refusal({ TERMINALDECK_OS: 'Linux', TERMINALDECK_ARCH: 'aarch64', TERMINALDECK_LIBC: 'musl' })

    expect(out).toMatch(/musl/i)
    expect(out).toMatch(/nodejs|node/i)
    expect(out).toContain('Nothing has been written to this machine.')
    // The refusal has to be a refusal, not a fallback that guesses.
    expect(out).not.toContain('.tar.gz')
  })

  it.skipIf(!posix)('names the file when Node publishes no build for the combination', () => {
    // darwin-armv7l is not a thing anyone builds. The message has to say that it
    // is Node's answer and not this installer's opinion, or the next step is a
    // bug report here.
    const out = refusal({ TERMINALDECK_OS: 'Darwin', TERMINALDECK_ARCH: 'armv7l', TERMINALDECK_NODE_VERSION: '22.23.2' })

    expect(out).toContain('node-v22.23.2-darwin-armv7l.tar.gz')
    expect(out).toContain("That is Node's answer, not this installer's")
  })

  it.skipIf(!posix)('refuses an architecture it has no spelling for, rather than guessing one', () => {
    expect(refusal({ TERMINALDECK_ARCH: 'sparc64' })).toContain("Unrecognised architecture 'sparc64'")
  })

  it.skipIf(!posix)('checks for node-pty’s build tools before it downloads anything', () => {
    // node-pty 1.1.0's published tarball carries prebuilds for darwin-arm64,
    // darwin-x64, win32-arm64 and win32-x64 — and none for Linux, where its
    // install script falls through to `node-gyp rebuild`. On a minimal server
    // image that fails a minute in with "gyp ERR! find Python", which looks like
    // a bug in this project. An empty PATH is a server with no compiler.
    const out = refusal(
      { TERMINALDECK_OS: 'Linux', TERMINALDECK_ARCH: 'aarch64', TERMINALDECK_LIBC: 'gnu' },
      join(home, 'no-tools-here'),
    )

    expect(out).toContain('node-pty')
    expect(out).toMatch(/apt-get install .*python3 make g\+\+/)
    // Before, not after: the promise the app makes on this screen is that a
    // refusal leaves the server untouched.
    expect(out).toContain('Nothing has been written to this machine.')
  })

  it.skipIf(!posix)('still refuses outright when told not to fetch a runtime', () => {
    // The app's install screen tells people "nothing was written to this
    // server" when it refuses. That promise needs a mode where it is true by
    // construction, because a private runtime does write something.
    const out = refusal(
      { TERMINALDECK_NO_RUNTIME: '1', TERMINALDECK_OS: 'Linux', TERMINALDECK_ARCH: 'aarch64' },
      join(home, 'no-tools-here'),
    )

    expect(out).toContain('Nothing has been written to this machine.')
  })
})

describe('the shape of the script itself', () => {
  it('is POSIX sh, because dash is what a minimal server image has', () => {
    expect(script.startsWith('#!/bin/sh\n')).toBe(true)
    // Comments dropped first: the preamble talks *about* these constructs, and a
    // check that cannot tell an example from a use is a check that gets deleted
    // the first time it cries wolf.
    const code = script
      .split('\n')
      .filter((line) => !/^\s*#/.test(line))
      .join('\n')
    // Each of these runs fine under bash and changes behaviour or dies under
    // dash, which is the /bin/sh on Debian, Ubuntu and Alpine.
    expect(code).not.toMatch(/\[\[/)
    expect(code).not.toMatch(/^\s*local\s/m)
    expect(code).not.toMatch(/^\s*function\s+\w+/m)
    expect(code).not.toMatch(/\bpipefail\b/)
    expect(code).not.toMatch(/\becho\s+-[en]/)
  })

  it('verifies the download before it unpacks it', () => {
    // An installer that pipes an unverified tarball into tar on somebody's
    // server has made the machine less safe than the refusal it replaced. Order
    // is the whole property: comparing hashes after extracting is theatre.
    const compare = script.indexOf('[ "$got" = "$NODE_SHA" ]')
    const extract = script.indexOf('tar -xzf')
    expect(compare).toBeGreaterThan(0)
    expect(extract).toBeGreaterThan(compare)
  })

  it('downloads the gzip tarball, not the xz one', () => {
    // The xz is about half the size and GNU tar shells out to an `xz` binary
    // that a minimal image need not have — turning a saving into
    // "tar: Cannot exec xz" on exactly the bare servers this exists for.
    expect(script).toContain('.tar.gz')
    expect(script).not.toMatch(/NODE_TARBALL=.*\.tar\.xz/)
  })

  it('puts the runtime under the home directory and never in /usr', () => {
    // The point of a private prefix is that it shadows nothing, needs no sudo,
    // and is undone by deleting one folder.
    expect(script).toContain('$HOME/.terminaldeck/runtime')
    expect(script).not.toMatch(/(?<!not )install(ed|ing)? (into|to) \/usr/)
    expect(script).not.toMatch(/^\s*sudo /m)
  })

  it('leaves the host’s state and the agent’s login untouched by an update', () => {
    /*
     * The data-loss symptom this whole lane exists for, guarded on the headless
     * side. Asad reported that a Windows *or headless* update logs the account
     * out and loses history, and asked that the two be aligned. The headless
     * host already preserves all of it across `install.sh` — the relay identity,
     * the device roster and the account — for one plain reason: that state lives
     * in the host's own directory (`~/.local/share/terminaldeck`) and the
     * agent's `~/.claude`, and this script installs a package and a private Node
     * runtime and never so much as names either place.
     *
     * So the guard is two-sided, and it is here to make a future edit that
     * *would* reach into those directories fail before it ships. Every
     * destructive command the script runs is scoped to the private runtime it is
     * replacing (`$RUNTIME`) and the staging directory beside it (`$tmp`); the
     * one `rm` that names the runtime directly is printed for a person to run by
     * hand, not executed. And the state directory is a string the script does
     * not contain at all.
     */
    const executed = script
      .split('\n')
      .map((line) => line.replace(/#.*$/, ''))
      .filter((line) => /\brm\s+-rf\b|\bmv\s/.test(line))
      // A line that only *prints* a command (the uninstall hint) removes nothing.
      .filter((line) => !/^\s*(say|die|printf|echo|cat|warn)\b/.test(line))

    expect(executed.length).toBeGreaterThan(0)
    for (const line of executed) {
      expect(line, `an update may only remove the runtime or its staging dir, not: ${line.trim()}`).toMatch(
        /\$tmp\b|\$RUNTIME\b|\$NODE_DIR\b/,
      )
    }

    // Never named, so an update cannot reset, relocate or clear the host's state
    // directory or the agent's login — the two places all of it actually lives.
    expect(script).not.toMatch(/\.local\/share/)
    expect(script).not.toMatch(/XDG_DATA_HOME/)
    expect(script).not.toMatch(/\.claude\b/)
  })

  it('keeps the user-prefix fallback rather than telling anyone to re-run under sudo', () => {
    // Installing a user's own tool as root leaves every future update needing
    // root too. This has been the behaviour since the first version and the
    // runtime work must not have quietly dropped it.
    expect(script).toContain('$HOME/.local')
    expect(script).toMatch(/npm prefix -g/)
  })

  it('still says what to do next, which on a server is the part people get wrong', () => {
    expect(script).toContain('terminaldeck pair')
    expect(script).toContain('terminaldeck status')
    expect(script).toContain('terminaldeck address')
  })

  it('ends by printing the address, not by naming the command that would', () => {
    // The gap this closes: a host id and a fingerprint are one-way hashes, so
    // until `address` existed there was nothing a fresh server could print that
    // a phone could type. An installer that stops at "now run this" stops one
    // step short of the only string that works, in an SSH window somebody is
    // about to close.
    expect(script).toMatch(/address=\$\("\$\{bin_dir\}\/\$\{PACKAGE\}" address/)
    // stdout is the address and stderr is everything else, which is what makes
    // the capture an address rather than an address with a progress line on it.
    expect(script).toContain('address 2>/dev/null')
  })

  it('says the address is not a secret, where it prints it', () => {
    // A long random-looking token gets treated as a credential unless it says
    // otherwise, and somebody who will not paste it cannot use the feature.
    expect(script).toContain('NOT a secret')
    expect(script).toMatch(/grants nothing on its own/)
  })

  it('has a sentence for a host with no relay instead of a broken address', () => {
    expect(script).toContain('No address yet')
  })

  it('does not claim success when npm installed something with no command in it', () => {
    // Measured on 2026-08-19: `terminaldeck` on the registry was still the 0.0.1
    // placeholder, which has no `bin` at all. `npm install -g` exits 0, the old
    // script printed "Installed to …", and nothing was installed that could
    // answer a phone.
    expect(script).toMatch(/\[ -x "\$INSTALL_PREFIX\/bin\/\$PACKAGE" \]/)
  })
})
