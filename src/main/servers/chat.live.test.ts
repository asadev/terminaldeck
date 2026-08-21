import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { ServerConnections } from './connection'
import { ServerStore } from './store'
import { ServerChatSession, type ChatFeed } from './chat'
import type { ServerCredential, ServerCredentials } from './credentials'

/**
 * Chat on a server terminal, against a real sshd, with a real transcript.
 *
 * Opt-in, because a test that needs a machine on the public internet has no
 * business failing a build on a train:
 *
 *     TERMINALDECK_LIVE_SSH=178.105.239.176 \
 *     TERMINALDECK_LIVE_SSH_USER=root \
 *     TERMINALDECK_LIVE_SSH_KEY=~/.ssh/hetzner_personal \
 *       npx vitest run src/main/servers/chat.live.test.ts
 *
 * ## Why it had to exist
 *
 * The lane that built this feature said so itself: *"Never run against a real
 * server… no round trip was made to a live sshd: busybox `find -mmin`/`awk`, and
 * OpenSSH's SFTP `open`/`read` (short reads in particular), are handled in code
 * and unproven on real hardware."* Everything in `chat.test.ts` stands on a fake
 * far end, and a fake far end will agree with whatever the script says. What it
 * cannot report on is a real `sh` running the survey, a real `find` deciding
 * whether it has `-mmin`, a real `awk` finding the leftmost timestamp on a
 * 3 KB line, a real SFTP server answering a read short, or a real `tail -f`
 * deciding whether it will follow anything.
 *
 * So this substitutes **nothing**. `ServerConnections` is the app's own, over
 * `ssh2`; `surveyScript`, `parseSurvey`, `attributeServerTranscript`,
 * `ChatReader` and `ServerChatSession` are the code the app ships. The only
 * thing that is not from a real machine is the moment the shell is believed to
 * have opened — see {@link openedAt} — and it is stated rather than hidden.
 *
 * ## The transcript is a real one
 *
 * Written by `claude` on this Mac, two turns, and copied over — not a fixture
 * somebody typed to match the parser. `claude` is not installed on the box, and
 * putting somebody's API key on a rented server to install it would be a worse
 * idea than this compromise. What the far end does with those bytes — the
 * survey, the attribution, the byte ranges, the follow — is all real.
 *
 * ## What it does to the machine, and what it puts back
 *
 * One directory under a `td-scratch` prefix inside `~/.claude/projects`, which
 * did not exist on that box at all. {@link TEARDOWN} removes it and the two
 * empty parents it had to create, and nothing else on the machine is read or
 * written. `SERVERS-DESIGN.md` §8.5 asks for exactly that.
 */

const host = process.env.TERMINALDECK_LIVE_SSH ?? ''
const username = process.env.TERMINALDECK_LIVE_SSH_USER ?? 'root'
const keyPath = (process.env.TERMINALDECK_LIVE_SSH_KEY ?? '').replace(/^~/, process.env.HOME ?? '~')
/** A real transcript, written by `claude`, to put on that server. */
const transcriptPath = process.env.TERMINALDECK_LIVE_TRANSCRIPT ?? ''
const live = host !== '' && keyPath !== '' && transcriptPath !== ''

/**
 * The project folder on the far end.
 *
 * Non-ASCII on purpose, and it is not decoration. The survey answers **file
 * paths** over the same channel `run` decodes, and a `é` whose three bytes land
 * on either side of a TCP boundary used to come back as two replacement
 * characters — a path SFTP then cannot open, reported to somebody as *"no
 * conversation found"* while they are looking at one in the terminal beside it.
 * A real link, a real sshd and a real filename are the only way to find out that
 * the whole path survives.
 */
const PROJECT = 'td-scratch-café-chat'
const REMOTE_DIR = `/root/.claude/projects/${PROJECT}`

const store = new ServerStore(mkdtempSync(join(tmpdir(), 'td-live-chat-')))
let serverId = ''
let pool: ServerConnections | null = null
let remoteFile = ''
/** The two halves of the real transcript: what is there, and what is appended. */
let firstTurn = ''
let secondTurn = ''
/**
 * When the shell is believed to have opened.
 *
 * The one synthetic input in this file, and it is synthetic for a reason that
 * cannot be engineered away here: attribution asks whether a conversation began
 * *after* this terminal did, and the real transcript was written before this
 * test ran, because the machine it was written on is this one.
 *
 * A **minute** before the transcript's first line rather than a second, and the
 * gap is the two clocks. `serverSkew` converts this moment into the server's
 * time and deliberately overestimates by a whole round trip, so that this side
 * can only ever claim *fewer* conversations. Measured against this box while
 * writing this: its clock reads about two seconds ahead of this Mac's, and
 * `OPENED_SLACK_MS` is two — so a one-second margin sat exactly on the edge and
 * this test failed its second run and passed its first. That is not a bug in
 * the rule; it is a rule tuned for a transcript stamped by the **server's**
 * clock being handed one stamped by this one. A minute covers the difference,
 * and it is still a shell that opened before the conversation began, which is
 * the fact the rule is about.
 */
let openedAt = 0

function ssh(script: string): string {
  return execFileSync('ssh', ['-o', 'BatchMode=yes', '-i', keyPath, `${username}@${host}`, script], {
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
  })
}

/** Every `tail -f` this app has running on that machine right now. */
function tails(): string {
  return ssh("pgrep -fa '[t]ail -n 0 -f' || true")
}

const credentials = {
  read: (): ServerCredential => ({
    kind: 'key',
    privateKey: readFileSync(keyPath, 'utf8'),
    passphrase: null,
  }),
} as unknown as ServerCredentials

beforeAll(() => {
  if (!live) return
  const whole = readFileSync(transcriptPath, 'utf8')
  const lines = whole.split('\n').filter((line) => line !== '')
  // Split at the second prompt, so the append below is a genuine second turn of
  // a real conversation rather than bytes cut at an arbitrary offset.
  const secondPrompt = lines.findIndex(
    (line, at) => at > 0 && line.includes('"type":"queue-operation"') && line.includes('enqueue'),
  )
  firstTurn = `${lines.slice(0, secondPrompt).join('\n')}\n`
  secondTurn = `${lines.slice(secondPrompt).join('\n')}\n`
  const first = /"timestamp":"([^"]*)"/.exec(lines[0] ?? '')?.[1] ?? ''
  openedAt = Date.parse(first) - 60_000

  remoteFile = `${REMOTE_DIR}/${/([^/]+)\.jsonl$/.exec(transcriptPath)?.[1] ?? 'live'}.jsonl`
  const local = mkdtempSync(join(tmpdir(), 'td-live-put-'))
  writeFileSync(join(local, 'first.jsonl'), firstTurn, 'utf8')
  /*
   * Emptied, not merely created.
   *
   * A leftover transcript from an interrupted run sits in this folder with the
   * same first-line timestamp as the one about to be uploaded, and the
   * attribution then has two conversations with an equal claim — which is
   * exactly the case it is written to refuse. The failure reads as *"the survey
   * found nothing"* and points nowhere near the real cause; it cost a
   * diagnosis here before this line existed.
   */
  ssh(`rm -rf ${JSON.stringify(REMOTE_DIR)} && mkdir -p ${JSON.stringify(REMOTE_DIR)}`)
  execFileSync('scp', [
    '-o',
    'BatchMode=yes',
    '-i',
    keyPath,
    join(local, 'first.jsonl'),
    `${username}@${host}:${remoteFile}`,
  ])
  rmSync(local, { recursive: true, force: true })

  serverId = store.add({ name: 'live', address: host, username }).id
  pool = new ServerConnections(store, credentials)
}, 120_000)

/**
 * One connection for the whole file, held the way a page holds one.
 *
 * Not tidiness. `reach.live.test.ts` measured this box refusing the fifth
 * handshake inside nine seconds — a real machine on the public internet defends
 * itself against repeated dials — and every `withConnection` here would open its
 * own. Holding one is also what the app does: the server's page acquires while
 * it is on screen and every action rides that socket.
 */
beforeAll(async () => {
  if (!live) return
  await (pool as ServerConnections).acquire(serverId)
}, 120_000)

afterAll(() => {
  if (live) pool?.release(serverId)
  pool?.closeAll()
  if (!live) return
  // Only what this test made, and only while the parents it made are empty. The
  // box is shared and `~/.claude` may have grown a real occupant since.
  ssh(
    `rm -rf ${JSON.stringify(REMOTE_DIR)}; ` +
      'rmdir /root/.claude/projects /root/.claude 2>/dev/null; true',
  )
}, 60_000)

/** The far end, as `ServerChatSession` asks for it — the app's own connection. */
function accessOn(connections: ServerConnections): {
  runScript: (id: string, script: string) => Promise<{ stdout: string; code: number | null }>
  readFileRange: (
    id: string,
    path: string,
    from: number,
    length: number,
  ) => Promise<{ bytes: Buffer; size: number }>
  follow: ServerConnections['follow']
} {
  return {
    runScript: async (id, script) => {
      const result = await connections.runScript(id, script)
      return { stdout: result.stdout, code: result.code }
    },
    readFileRange: (id, path, from, length) => connections.readFileRange(id, path, from, length),
    follow: (id, argv) => connections.follow(id, argv),
  }
}

describe.runIf(live)('a conversation on a real server', () => {
  it('finds the real transcript, over a real sshd, and folds it into bubbles', async () => {
    const session = new ServerChatSession(
      accessOn(pool as ServerConnections),
      serverId,
      openedAt,
      () => [],
    )
    const update = await session.load()

    // The survey ran on that machine's own `sh`, its `find` decided whether it
    // has `-mmin`, and its `awk` found the leftmost timestamp on lines that are
    // several kilobytes wide.
    expect(update.found, 'the survey found nothing on the far end').toBe(true)
    // And the whole path came back — the `é` included. This is the assertion the
    // per-chunk decode in `exec` used to fail intermittently, depending on where
    // TCP happened to cut.
    expect(update.transcriptPath).toBe(remoteFile)
    expect(update.transcriptPath).not.toContain('�')
    // Bubbles out of a transcript `claude` wrote, read over SFTP by byte range.
    expect(update.messages.map((one) => one.role)).toEqual(['you', 'agent'])
    expect(update.messages[1].text).toContain('the transcript is real')
    session.close()
  }, 120_000)

  it('is told by the server when the conversation grows, with no timer anywhere', async () => {
    const connections = pool as ServerConnections
    const session = new ServerChatSession(accessOn(connections), serverId, openedAt, () => [])

    const feeds: ChatFeed[] = []
    let pushes = 0
    const pushed: (() => void)[] = []
    session.watch((feed) => {
      feeds.push(feed)
      pushes += 1
      for (const wake of pushed.splice(0)) wake()
    })

    const before = await session.load()
    expect(before.messages[1].text).toContain('the transcript is real')
    // A `tail -n 0 -f` is running on that box. `-c +N` is not used and must not
    // be: POSIX specifies the leading `+` and busybox reads it as "the last N
    // bytes", which would splice real bytes in at the wrong offset with no
    // error anywhere.
    expect(before.feed, 'GNU tail on that box would not follow').toBe<ChatFeed>('live')

    const seen = pushes
    const arrived = new Promise<void>((resolve, reject) => {
      pushed.push(resolve)
      // Generous, and still nothing like a poll: what is being measured is that
      // the push happens *at all*, over a real link, without this side asking.
      setTimeout(() => reject(new Error('the server never said the file had grown')), 20_000)
    })

    // The real second turn of the same real conversation, appended on the far
    // end by something that is not this app — which is what an agent running in
    // that terminal is.
    ssh(`cat >> ${JSON.stringify(remoteFile)} <<'TDEOF'\n${secondTurn.trimEnd()}\nTDEOF`)

    await arrived
    expect(pushes).toBeGreaterThan(seen)

    const after = await session.tail()
    expect(after.messages.map((one) => one.text).join('\n')).toContain('pushed over a real sshd')
    expect(after.feed).toBe<ChatFeed>('live')
    expect(feeds.every((feed) => feed === 'live')).toBe(true)

    /*
     * And it really is a process on that box, which really stops when nobody is
     * looking.
     *
     * `pgrep` over there rather than a flag over here: the promise is that a
     * hidden pane costs nothing *on somebody else's machine*, and only that
     * machine can say whether something is still running on it.
     *
     * `[t]ail` and not `tail` — the pattern is a regex, and `pgrep -f` reads
     * every command line including the shell running this one, so a literal
     * pattern matches itself and the check passes for the wrong reason. The
     * bracket makes the pattern's own text fail to match the pattern.
     */
    expect(tails()).toContain(remoteFile)
    session.setWatched(false)
    await new Promise((wake) => setTimeout(wake, 1_500))
    expect(tails()).not.toContain(remoteFile)

    session.close()
  }, 180_000)

  it('carries a megabyte of multi-byte characters back without breaking one', async () => {
    /*
     * The boundary, visited on purpose over a real link.
     *
     * A short answer arrives in one TCP segment and a per-chunk decode passes;
     * a megabyte does not, and cannot. Every `é` here is two bytes and there are
     * enough of them that some land across a segment edge — so a single
     * replacement character in the result is the old bug, reproduced on real
     * hardware rather than argued about.
     */
    const connections = pool as ServerConnections
    const result = await connections.runScript(
      serverId,
      "awk 'BEGIN{ s=\"\"; for (i=0;i<64;i++) s = s \"café→\"; " +
        'for (j=0;j<4096;j++) print s }\'\n',
    )
    expect(result.truncated).toBe(false)
    expect(result.stdout.length).toBeGreaterThan(1_000_000)
    expect(result.stdout).not.toContain('�')
    // Every line whole, not merely no replacement characters overall.
    const lines = result.stdout.split('\n').filter((line) => line !== '')
    expect(lines).toHaveLength(4096)
    expect(new Set(lines).size, 'one line came back different from the others').toBe(1)
  }, 120_000)
})
