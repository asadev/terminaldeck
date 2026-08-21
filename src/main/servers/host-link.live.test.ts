/**
 * The whole link, against a real server, with only the SSH client replaced.
 *
 * Opt-in, because a test that needs a machine on the public internet and a live
 * relay has no business failing a build on a train:
 *
 *     TERMINALDECK_LIVE_SERVER=terminaldeck-server \
 *       npx vitest run src/main/servers/host-link.live.test.ts
 *
 * ## Why this exists
 *
 * Because the thing that failed was not in any of the units. On 2026-08-22 his
 * office PC was running the headless host, connected to the relay, up two hours
 * — and `channels 0`. Nothing was linked to it. Every test in `host.test.ts`
 * passed, because every one of them answers its own `linkThisComputer` and a
 * fake that always answers cannot miss a rendezvous by a beat. The only way to
 * find out whether a press of **Set it up** ends with a channel open is to open
 * one.
 *
 * So this drives {@link ServerHosts.install} — the app's own code, unmodified —
 * over a real SSH connection to a real Ubuntu box, redeems the code it reads
 * with the real {@link pairWithCode} against the real relay, dials the machine
 * with the real {@link createMachineLink}, and then asks **that host, in its own
 * words**, how many channels it has open. One is the assertion. A row in this
 * desktop's store would not have been.
 *
 * ## What is substituted, stated rather than hidden
 *
 * `ssh2` is replaced by the system `ssh` and `scp` — the same substitution
 * `actions.live.test.ts` makes and for the same reason. **This proves the
 * commands, the ordering, the installer, the relay and the pairing; it does not
 * prove the SSH client.**
 *
 * ## What it does to the machine, and what it puts back
 *
 * Everything happens in a `td-scratch` account, created by {@link SETUP} and
 * removed with its home by {@link TEARDOWN} — `SERVERS-DESIGN.md` §8.5, *"clean
 * up after yourself."* The uninstall the app itself performs runs first, so what
 * `userdel` removes afterwards is meant to be an empty home; the test asserts
 * that it was.
 */

import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { HOST_PROBE, ServerHosts, channelsOf, hostIdOf, readHostProbe, type HostShell } from './host'
import { findHostPackage } from './host-package'
import { createMachineLink, type MachineLink } from '../remote/machines/guest'
import { pairWithCode } from '../remote/machines/pair'
import { fingerprint } from '../../shared/sealed'
import { DEFAULT_RELAY_URL } from '../../shared/relay-wire'
import { version } from '../../../package.json'

const named = process.env.TERMINALDECK_LIVE_SERVER ?? ''
const live = named !== ''
const exec = promisify(execFile)

/** The account this test owns. Nothing outside it is touched. */
const WHO = 'td-scratch'
const dest = `${WHO}@${named}`

/**
 * Made with root's own key rather than a password, so this file holds no
 * secret — and lingering, because a user unit dies with the last login and this
 * test logs out between steps.
 */
const SETUP = [
  `id -u ${WHO} >/dev/null 2>&1 || useradd -m -s /bin/bash ${WHO}`,
  `install -d -m 700 -o ${WHO} -g ${WHO} /home/${WHO}/.ssh`,
  `cp /root/.ssh/authorized_keys /home/${WHO}/.ssh/authorized_keys`,
  `chown ${WHO}:${WHO} /home/${WHO}/.ssh/authorized_keys`,
  `chmod 600 /home/${WHO}/.ssh/authorized_keys`,
  `loginctl enable-linger ${WHO}`,
].join('\n')

const TEARDOWN = [
  `loginctl disable-linger ${WHO} >/dev/null 2>&1 || true`,
  `pkill -KILL -u ${WHO} >/dev/null 2>&1 || true`,
  'sleep 1',
  `userdel -r ${WHO} >/dev/null 2>&1 || true`,
].join('\n')

async function asRoot(script: string): Promise<string> {
  const { stdout } = await exec('ssh', ['-o', 'BatchMode=yes', named, script], {
    maxBuffer: 32 * 1024 * 1024,
  })
  return stdout
}

/** `ServerConnections.runScript`, over the system client. */
async function runScript(_serverId: string, script: string): Promise<{ code: number; stdout: string; stderr: string }> {
  try {
    const { stdout, stderr } = await exec('ssh', ['-o', 'BatchMode=yes', dest, script], {
      maxBuffer: 32 * 1024 * 1024,
    })
    return { code: 0, stdout, stderr }
  } catch (error) {
    const failure = error as { code?: number; stdout?: string; stderr?: string }
    return { code: failure.code ?? 1, stdout: failure.stdout ?? '', stderr: failure.stderr ?? '' }
  }
}

/** `ServerConnections.putFile`, over the system client. */
async function putFile(_serverId: string, local: string, name: string): Promise<string> {
  const there = `/home/${WHO}/${name}`
  await exec('scp', ['-o', 'BatchMode=yes', local, `${dest}:${there}`], { maxBuffer: 1024 * 1024 })
  return there
}

/**
 * A real login shell on a real pty, which is not a detail.
 *
 * `terminaldeck pair` refuses to finish without a tty *by design* — it prints
 * the code, says "Not a terminal, so nothing can be confirmed here", and stops,
 * because pretending to wait and approving nothing would leave a device paired
 * and permanently locked out. `-tt` is what makes `ssh` allocate one.
 */
function openShell(): { shell: HostShell; close: () => void } {
  const child = spawn('ssh', ['-tt', '-o', 'BatchMode=yes', dest], { stdio: ['pipe', 'pipe', 'pipe'] })
  const listeners: Array<(chunk: string) => void> = []
  const feed = (chunk: Buffer): void => {
    const text = chunk.toString('utf8')
    for (const listener of [...listeners]) listener(text)
  }
  child.stdout.on('data', feed)
  child.stderr.on('data', feed)
  return {
    shell: {
      onData: (listener) => {
        listeners.push(listener)
        return () => {
          const at = listeners.indexOf(listener)
          if (at >= 0) listeners.splice(at, 1)
        }
      },
      write: (data) => void child.stdin.write(data),
    },
    close: () => child.kill('SIGKILL'),
  }
}

const dialled: MachineLink[] = []

/**
 * `MachinesIpc.linkWithCode`, minus the store — the same `pairWithCode` and the
 * same `createMachineLink` the app calls, so what this proves is the app's path
 * and not a shortcut through it.
 *
 * The dial is the point. A redemption that answered `ok` and never opened a
 * channel is exactly the state his office PC was left in, and it is what a
 * machine row alone can hide.
 */
async function linkThisComputer(
  code: string,
): Promise<
  { ok: true; machineId: string; machineName: string; deviceFingerprint: string } | { ok: false; message: string }
> {
  const result = await pairWithCode({ code, relayUrl: DEFAULT_RELAY_URL, codeFrom: 'supplied' })
  if (!result.ok) return { ok: false, message: result.message }
  const link = createMachineLink({
    id: result.offer.hostId,
    secrets: {
      hostId: result.offer.hostId,
      hostPublicKey: Buffer.from(result.offer.publicKey, 'base64'),
      relayUrl: result.offer.relayUrl,
      credential: result.credential,
      guestKeys: result.guestKeys,
    },
    onState: () => undefined,
    onOutput: () => undefined,
    onWelcome: () => undefined,
  })
  dialled.push(link)
  link.connect()
  return {
    ok: true,
    machineId: result.offer.hostId,
    machineName: result.offer.name === '' ? result.deviceName : result.offer.name,
    deviceFingerprint: fingerprint(result.guestKeys.publicKey),
  }
}

/**
 * `MachinesIpc.whenReaching`, over the one link this file makes.
 *
 * Written out rather than imported because that registration wants an Electron
 * `ipcMain` and a store; what it does is this, and this is what the flow is
 * being asked to wait on.
 */
async function whenReaching(machineId: string, ceilingMs: number): Promise<boolean> {
  const link = dialled.find((one) => one.state().id === machineId)
  if (link === undefined) return false
  const end = Date.now() + ceilingMs
  for (;;) {
    if (link.state().state === 'online') return true
    if (Date.now() >= end) return false
    await new Promise<void>((wake) => setTimeout(wake, 200))
  }
}

/** Ask that host, in its own words, until it says what we are waiting for. */
async function until(want: (status: string) => boolean, ceilingMs: number): Promise<string> {
  const end = Date.now() + ceilingMs
  let last = ''
  for (;;) {
    last = readHostProbe((await runScript('s1', HOST_PROBE)).stdout).host.status
    if (want(last) || Date.now() >= end) return last
    await new Promise<void>((wake) => setTimeout(wake, 1000))
  }
}


describe.runIf(live)('putting the host on a real server and linking to it', () => {
  beforeAll(async () => {
    await asRoot(SETUP)
  }, 120_000)

  afterAll(async () => {
    for (const link of dialled.splice(0)) link.disconnect()
    await asRoot(TEARDOWN)
  }, 120_000)

  it(
    'installs, links, and that host counts this computer among its channels',
    async () => {
      const pack = findHostPackage(version, { resources: null, tree: process.cwd() })
      expect(pack, 'run `npm run dist:headless` first — this test installs what the app carries').not.toBeNull()

      const opened = openShell()
      const hosts = new ServerHosts({
        runScript,
        putFile,
        linkThisComputer,
        // The real one, for the real reason: the channel comes up a beat after
        // the far end approves this computer, and an install that returned at
        // the approval would report a link that was still nothing.
        whenReaching: (machineId, ceilingMs) => whenReaching(machineId, ceilingMs),
        hostPackage: () => pack,
        broadcast: () => undefined,
      })
      try {
        const before = readHostProbe((await runScript('s1', HOST_PROBE)).stdout)
        const final = await hosts.install('s1', opened.shell, before, 'terminaldeck-server')

        expect(final.detail).toBe('')
        expect(final.step).toBe('done')
        // The strong form: not "linked", but linked **and reached**. This is the
        // sentence the install only earns once a channel exists.
        expect(final.line).toBe('It is running, and linked to this computer.')

        /*
         * The assertion this file exists for.
         *
         * Not "the install said done", and not "there is a row in the store" —
         * both of those were true on his office PC while nothing could reach it.
         * This is that host, counting its own open channels, out of the same
         * `status` text the panel prints verbatim.
         */
        const said = await until((status) => (channelsOf(status) ?? 0) >= 1, 30_000)
        expect(hostIdOf(said)).not.toBe('')
        expect(channelsOf(said)).toBeGreaterThanOrEqual(1)
      } finally {
        opened.close()
      }

      // And the way back, which is the other half of §8.5. The data goes too:
      // the device this test paired has no business outliving it.
      const after = readHostProbe((await runScript('s1', HOST_PROBE)).stdout)
      const gone = await hosts.uninstall('s1', after.host, true)
      expect(gone.step).toBe('idle')

      const empty = readHostProbe((await runScript('s1', HOST_PROBE)).stdout)
      expect(empty.host.command).toBe('')
      expect(empty.host.data).toBe(false)
    },
    20 * 60 * 1000,
  )
})
