import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { KeyFileOffers, describeKey, listKeyFiles, type KeyFolderReader } from './keyfiles'

/**
 * Which files in a folder are keys, which of those need a password, and which
 * paths this process is willing to read.
 *
 * **Every key text below was produced by `ssh-keygen` itself** — an unlocked
 * and a locked one in the modern format, an unlocked and a locked one in the
 * old PEM format, and the `.pub` twin that sits beside each. The bodies are
 * truncated to keep the file readable; the header, the format's own magic and
 * the encryption fields are byte-for-byte what the tool wrote, because those
 * are the parts being read.
 *
 * The case that must never regress is the last one: a public key is never
 * offered as a private one. Somebody who sends the wrong file of that pair to a
 * server has published the thing that must never leave their computer.
 */

/*
 * `openssh-key-v1\0` then a length-prefixed cipher name. `none` and
 * `aes256-ctr` are the two real answers; both blobs below start with exactly
 * the bytes `ssh-keygen` emitted.
 */
const OPENSSH_OPEN = `-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACAPYzDZdh+7iDEAImrLBicB1gZqLTxtLZUMNktMKME7Pw==
-----END OPENSSH PRIVATE KEY-----
`

const OPENSSH_LOCKED = `-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABDCFqvVYs
5CTaB1EJ0gYs0WAAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIPrazOD6pinZ
-----END OPENSSH PRIVATE KEY-----
`

const PEM_OPEN = `-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAwyl1mdifqbHatPQkvglBe/isn5BdIxUNz5Cmmxh9mSjBtYIc
-----END RSA PRIVATE KEY-----
`

const PEM_LOCKED = `-----BEGIN RSA PRIVATE KEY-----
Proc-Type: 4,ENCRYPTED
DEK-Info: AES-128-CBC,3F1A0B0C2D3E4F5061728394A5B6C7D8

kQz9mF3rT5vX7yA1bC2dE4fG6hJ8kL0mN2pQ4rS6tU8vW0xY2zA4bC6dE8fG0hJ2
-----END RSA PRIVATE KEY-----
`

const PUBLIC = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA9jMNl2H7uIMQAiassGJwHWBmotPG0tlQw2S0wowTs/ test\n'

/**
 * The last segment of a path, in either spelling.
 *
 * Split on `/` alone and this fixture works on this Mac and fails on the
 * Windows runner, because `listKeyFiles` builds its paths with `join()` — which
 * answers `C:\\Users\\x\\.ssh\\id_ed25519` there. The lookup then misses,
 * every file reads as absent, and the suite reports a defect in the key reader
 * that does not exist.
 *
 * That is the same "measures the machine it runs on" shape this repository has
 * been caught by six times, arriving in a *fixture* rather than in an
 * assertion — which is the harder place to see it, because nothing in the test
 * body looks platform-specific.
 */
function lastSegment(path: string): string {
  const at = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'))
  return at === -1 ? path : path.slice(at + 1)
}

function folder(files: Record<string, string>): KeyFolderReader {
  const find = (path: string): string => {
    const text = files[lastSegment(path)]
    if (text === undefined) throw new Error('ENOENT')
    return text
  }
  return {
    entries: () => Object.keys(files),
    read: find,
    size: (path) => find(path).length,
  }
}

/** A real `~/.ssh`, from the machine this was written on. */
const REAL_SHAPE = folder({
  agent: '', // a directory, read as empty
  authorized_keys: PUBLIC,
  'authorized_keys.bak-2026-06-23-removed-commander-key': PUBLIC,
  config: 'Host imza-vps\n  HostName 1.2.3.4\n  User root\n',
  'config.bak-20260815-2242': 'Host old\n',
  hetzner_personal: OPENSSH_OPEN,
  'hetzner_personal.pub': PUBLIC,
  id_ed25519: OPENSSH_LOCKED,
  'id_ed25519.pub': PUBLIC,
  known_hosts: 'github.com ssh-ed25519 AAAAC3Nza…\n',
})

describe('the keys already on this computer', () => {
  it('offers the private keys out of a real folder and nothing else', () => {
    const found = listKeyFiles('/home/x/.ssh', REAL_SHAPE)
    expect(found.map((offer) => offer.name)).toEqual(['hetzner_personal', 'id_ed25519'])
  })

  it('never offers the public twin sitting beside a key', () => {
    /*
     * The one that matters. These files differ by three characters in their
     * names and by everything in their meaning, and sending the wrong one to a
     * server publishes the thing that must never leave this computer. The
     * filter is the first line of the file, so it does not matter what either
     * is called.
     */
    expect(describeKey(PUBLIC, 'id_ed25519.pub')).toBeNull()
    expect(describeKey(PUBLIC, 'id_ed25519')).toBeNull()
    expect(describeKey(OPENSSH_OPEN, 'something-else-entirely')).not.toBeNull()
  })

  it('reads whether a key needs a password out of the file, both formats', () => {
    // The cipher name inside the blob for the modern format…
    expect(describeKey(OPENSSH_OPEN, 'k')?.locked).toBe(false)
    expect(describeKey(OPENSSH_LOCKED, 'k')?.locked).toBe(true)
    // …and the header line for the old one.
    expect(describeKey(PEM_OPEN, 'k')?.locked).toBe(false)
    expect(describeKey(PEM_LOCKED, 'k')?.locked).toBe(true)
  })

  it('says it could not tell rather than guessing at a blob it cannot parse', () => {
    const nonsense = '-----BEGIN OPENSSH PRIVATE KEY-----\nnot base64 at all!!\n-----END OPENSSH PRIVATE KEY-----\n'
    expect(describeKey(nonsense, 'k')?.locked).toBeNull()
  })

  it('treats a computer that has never used SSH as an empty list, not a failure', () => {
    const missing: KeyFolderReader = {
      entries: () => {
        throw new Error('ENOENT')
      },
      read: () => '',
      size: () => 0,
    }
    expect(listKeyFiles('/home/x/.ssh', missing)).toEqual([])
  })
})

describe('the paths this process will read a key out of', () => {
  it('refuses one the window made up, however plausible', () => {
    /*
     * Without this the channel is "read any file on this computer" with the
     * renderer's word for which one — and the renderer is the surface that runs
     * other people's web pages in this app.
     */
    const offers = new KeyFileOffers()
    offers.list('/home/x/.ssh', REAL_SHAPE)
    const refused = offers.read(join('/home/x/.ssh', 'config'), REAL_SHAPE)
    expect(refused.ok).toBe(false)
    expect(refused.ok === false && refused.sentence).toContain('not one this app offered')
  })

  it('reads one it offered, and hands back the file unchanged', () => {
    const offers = new KeyFileOffers()
    offers.list('/home/x/.ssh', REAL_SHAPE)
    /*
     * Built with `join`, not written out, because the allowlist holds the exact
     * string `listKeyFiles` put in it — and that is `join`'s answer, which is
     * back-slashed on Windows. A literal forward-slash path here passes on this
     * Mac and is refused on the Windows runner, reporting the guard as broken
     * when it is doing precisely its job.
     */
    const got = offers.read(join('/home/x/.ssh', 'hetzner_personal'), REAL_SHAPE)
    expect(got.ok).toBe(true)
    expect(got.ok === true && got.key).toBe(OPENSSH_OPEN)
  })

  it('allows a file the person chose in a panel, and still refuses one that is not a key', () => {
    const downloads = folder({ 'server.pem': PEM_OPEN, 'notes.txt': 'hello' })
    const offers = new KeyFileOffers()
    expect(offers.chose('/Users/x/Downloads/notes.txt', downloads)).toBeNull()
    const chosen = offers.chose('/Users/x/Downloads/server.pem', downloads)
    expect(chosen?.what).toBe('An RSA key')
    expect(offers.read('/Users/x/Downloads/server.pem', downloads).ok).toBe(true)
    // Refusing to describe it also refused to allow it.
    expect(offers.read('/Users/x/Downloads/notes.txt', downloads).ok).toBe(false)
  })
})
