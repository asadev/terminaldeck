/**
 * The one test that drives this app's real action layer against a real server.
 *
 * Opt-in, because a test that needs a machine on the public internet has no
 * business failing a build on a train:
 *
 *     TERMINALDECK_LIVE_SERVER=terminaldeck-server \
 *       npx vitest run src/main/servers/actions.live.test.ts
 *
 * ## Why this exists, said plainly
 *
 * The brief for this work put it in one sentence: *"the harness in this repo
 * has lied three times this week — `browserNavigate` returned a fixed URL
 * whatever it was asked for, and the remote stub sent a status that was not a
 * real status — so a stand-in passing is not evidence."* Everything else in
 * this folder runs against a fake `run`, and a fake `run` will happily agree
 * that `systemctl restart` restarts something.
 *
 * So this file substitutes **only the transport**. `PROBE_SCRIPT` and
 * `parseProbe` are agent A's own, `waybackScript`, `parseSurvey` and `classify`
 * are this agent's own, `availableActions`, `previewOf` and `perform` are the
 * code the app ships, and the commands that reach the far end are byte for byte
 * the ones the app would send — quoted by `connection.ts`'s own {@link quote}.
 * What is replaced is `ssh2` with the system `ssh`, and that substitution is
 * stated rather than hidden: **this proves the commands and the ordering, and
 * it does not prove the SSH client.**
 *
 * ## What it does to the machine, and what it puts back
 *
 * It needs three things that do not exist on a fresh box: a service it may
 * stop, a checkout it may move, and a container it may replace. All three are
 * created under a `td-scratch` prefix by {@link SETUP}, and {@link TEARDOWN}
 * removes every one of them plus the images and the temporary compose plugin.
 * `SERVERS-DESIGN.md` §8.5 asks for exactly that: *"clean up after yourself…
 * the box was returned to exactly its prior state after these measurements."*
 *
 * **It never touches anything that was already running.** The demo broker and
 * the web server on that box are somebody's live service; the test asserts that
 * the cards for them exist and does not press a single button on them.
 */

import { execFile } from 'node:child_process'
import { mkdtempSync, readFileSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { quote, type RunResult } from './connection'
import { PROBE_SCRIPT, parseProbe } from './probe.sh'
import { classify, emptySurvey, parseSurvey, waybackScript, type ServerCard } from './classify'
import {
  MemoryJournal,
  SERVER_ACTIONS,
  availableActions,
  perform,
  previewOf,
  type ActionDeps,
  type ActionFacts,
  type ActionTarget,
  type DownloadFromServer,
} from './actions'
import type { ServerFacts } from './facts'

const host = process.env.TERMINALDECK_LIVE_SERVER ?? ''
const live = host !== ''
const exec = promisify(execFile)

/** The transport, and the only thing in this file that is not the app's own code. */
async function sshRun(_serverId: string, argv: readonly string[]): Promise<RunResult> {
  return sshScript(argv.map(quote).join(' '))
}

async function sshScript(script: string): Promise<RunResult> {
  try {
    const { stdout, stderr } = await exec('ssh', ['-o', 'BatchMode=yes', host, script], {
      maxBuffer: 32 * 1024 * 1024,
    })
    return { code: 0, signal: null, stdout, stderr, truncated: false }
  } catch (error) {
    const failure = error as { code?: number; stdout?: string; stderr?: string }
    return {
      code: typeof failure.code === 'number' ? failure.code : 1,
      signal: null,
      stdout: failure.stdout ?? '',
      stderr: failure.stderr ?? String(error),
      truncated: false,
    }
  }
}

/**
 * A real file transfer, substituted the same way `run` is.
 *
 * `connection.ts` exposes no file transfer today, so `ActionDeps.download` is
 * absent in the app and every Backup button is correctly absent with it. That
 * is a true statement about the current build and a useless one for proving the
 * action: what this supplies is `scp`, which moves a file off the server
 * exactly as an `sftp` channel would. So the dump, the emptiness check, the
 * transfer and the cleanup are all genuinely exercised, and the only stand-in
 * is the same one the rest of this file already declares.
 */
const scpDownload: DownloadFromServer = async (_serverId, remotePath, localPath) => {
  await exec('scp', ['-o', 'BatchMode=yes', `${host}:${remotePath}`, localPath])
  return { bytes: statSync(localPath).size }
}

/**
 * The scratch estate.
 *
 * Everything is prefixed `td-scratch` so that a teardown that half-ran is
 * still cleanable by hand, and the compose plugin goes into a throwaway
 * `DOCKER_CONFIG` rather than the machine's own — measured on the test box,
 * Ubuntu's `docker.io` package ships no `docker compose` at all, and installing
 * one into the system configuration would be a change to somebody's server that
 * outlives this test.
 */
const SETUP = `set -e
rm -f /tmp/td-backup-*.sql
mkdir -p /opt/td-scratch
printf '#!/bin/sh\\necho "td-scratch app version 1 starting"\\nwhile :; do echo tick; sleep 5; done\\n' > /opt/td-scratch/app.sh
chmod +x /opt/td-scratch/app.sh
cd /opt/td-scratch
git init -q 2>/dev/null || true
git config user.email scratch@example.com
git config user.name scratch
git add -A && git commit -q -m v1 2>/dev/null || true
git branch -M main
rm -rf /opt/td-scratch-origin && git init -q --bare /opt/td-scratch-origin
git remote remove origin 2>/dev/null || true
git remote add origin /opt/td-scratch-origin
git push -q -f origin main
git -C /opt/td-scratch-origin symbolic-ref HEAD refs/heads/main
git branch --set-upstream-to=origin/main main >/dev/null
rm -rf /tmp/td-pub && git clone -q /opt/td-scratch-origin /tmp/td-pub
cd /tmp/td-pub && git config user.email s@e.com && git config user.name s
sed -i 's/version 1/version 2/' app.sh && git commit -qam v2 && git push -q origin main
printf '[Unit]\\nDescription=Terminal Deck scratch service\\n[Service]\\nWorkingDirectory=/opt/td-scratch\\nExecStart=/opt/td-scratch/app.sh\\nRestart=always\\n[Install]\\nWantedBy=multi-user.target\\n' > /etc/systemd/system/td-scratch.service
systemctl daemon-reload
systemctl start td-scratch.service

# The tool that recreates a container. Measured on this very box: Ubuntu's own
# docker.io package ships no compose plugin at all, which is exactly why the action
# layer treats its presence as a fact and not an assumption. Installed to the
# standard plugin path and removed again by the teardown, so the machine ends
# where it started.
mkdir -p /usr/local/lib/docker/cli-plugins
if ! docker compose version >/dev/null 2>&1; then
  curl -sSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
    https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-$(uname -m)
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi

mkdir -p /opt/td-scratch-compose
printf 'services:\n  web:\n    image: alpine:3\n    command: sh -c "cat /etc/alpine-release; sleep infinity"\n  db:\n    image: postgres:16-alpine\n    environment:\n      POSTGRES_PASSWORD: scratchpw\n      POSTGRES_USER: scratchuser\n' > /opt/td-scratch-compose/docker-compose.yml

# Pin the tag at an old image so that a pull is a genuine version change rather
# than a no-op. This is the only way to prove a rollback restores a *different*
# image without waiting for somebody upstream to publish one.
docker pull -q alpine:3.20
docker tag alpine:3.20 alpine:3
docker compose --project-directory /opt/td-scratch-compose -p tdscratch up -d
sleep 10
docker exec tdscratch-db-1 psql -U scratchuser -q -c "create table things(id int, note text)" || true
docker exec tdscratch-db-1 psql -U scratchuser -q -c "insert into things values (1, 'hello from a real server')" || true`

const TEARDOWN = `systemctl stop td-scratch.service 2>/dev/null
rm -f /etc/systemd/system/td-scratch.service
systemctl daemon-reload
docker compose --project-directory /opt/td-scratch-compose -p tdscratch down -v 2>/dev/null
docker rmi -f alpine:3 alpine:3.20 postgres:16-alpine 2>/dev/null
docker image prune -f 2>/dev/null
rm -f /usr/local/lib/docker/cli-plugins/docker-compose
rmdir /usr/local/lib/docker/cli-plugins /usr/local/lib/docker 2>/dev/null
rm -rf /opt/td-scratch /opt/td-scratch-origin /opt/td-scratch-compose /tmp/td-pub /tmp/td-backup-*.sql
exit 0`

describe.skipIf(!live)('the action layer, against a real server', () => {
  let facts: ServerFacts
  let cards: ServerCard[]
  let composeAvailable = false

  const deps = (): ActionDeps => ({ run: sshRun, journal: journal })
  const journal = new MemoryJournal()

  const cardNamed = (id: string): ServerCard => {
    const card = cards.find((row) => row.id === id)
    if (card === undefined) throw new Error(`no card ${id} in ${cards.map((row) => row.id).join(', ')}`)
    return card
  }
  const target = (id: string): ActionTarget => ({ serverId: 'live', card: cardNamed(id), facts })

  beforeAll(async () => {
    const setup = await sshScript(SETUP)
    expect(setup.code, setup.stderr).toBe(0)

    const probe = await sshScript(PROBE_SCRIPT)
    expect(probe.code, probe.stderr).toBe(0)
    facts = parseProbe(probe.stdout, 'live', Date.now())

    const survey = await sshScript(waybackScript(facts))
    const parsed = survey.code === 0 ? parseSurvey(survey.stdout) : emptySurvey()
    composeAvailable = parsed.compose_available
    cards = classify(facts, parsed)
  }, 180_000)

  afterAll(async () => {
    await sshScript(TEARDOWN)
  }, 60_000)

  it('finds the scratch service and reads the facts it needs', () => {
    // The probe is A's; this asserts only that the three fields the action
    // layer reads arrived, because every button below hangs off them.
    expect(facts.privilege.known).toBe('yes')
    expect(facts.init.known === 'yes' && facts.init.value).toBe('systemd')
    const card = cardNamed('service:td-scratch.service')
    expect(card.kind).toBe('app')
    expect(card.running).toBe(true)
    // `WorkingDirectory=` → git → a repository. Three facts the server told us.
    expect(card.repoDir).toBe('/opt/td-scratch')
  })

  it('offers only what the facts support, and says why the rest is absent', () => {
    const availability = availableActions(cardNamed('service:td-scratch.service'), facts as ActionFacts, {
      canDownload: false,
      composeAvailable,
    })
    expect(availability.offered).toContain('restart')
    expect(availability.offered).toContain('stop')
    expect(availability.offered).toContain('logs')
    expect(availability.offered).toContain('update')
  })

  it('stops and starts the service, and the server agrees each time', async () => {
    const stop = await perform(deps(), 'stop', target('service:td-scratch.service'))
    expect(stop.done).toMatch(/Stopped/)
    expect((await sshRun('live', ['systemctl', 'is-active', 'td-scratch.service'])).stdout.trim()).toBe('inactive')

    const start = await perform(deps(), 'start', target('service:td-scratch.service'))
    expect(start.done).toMatch(/Started/)
    expect((await sshRun('live', ['systemctl', 'is-active', 'td-scratch.service'])).stdout.trim()).toBe('active')
  }, 60_000)

  it('restarts it, and the way back is named in the sentence a person reads', async () => {
    const preview = previewOf('restart', target('service:td-scratch.service'), composeAvailable)
    expect(preview.sentence).toMatch(/offline for about five seconds/)
    const outcome = await perform(deps(), 'restart', target('service:td-scratch.service'))
    expect(outcome.done).toMatch(/Restarted/)
    expect(outcome.wayBack?.label).toBe('Start')
  }, 60_000)

  it('reads a bounded window of its output, newest last', async () => {
    const outcome = await perform({ ...deps(), logLines: 20 }, 'logs', target('service:td-scratch.service'))
    const value = outcome.value as { lines: string[] }
    expect(value.lines.length).toBeGreaterThan(0)
    expect(value.lines.length).toBeLessThanOrEqual(20)
    expect(value.lines.join('\n')).toMatch(/td-scratch/)
  }, 60_000)

  it('updates the checkout, and puts it back on the exact commit it recorded', async () => {
    const before = (await sshRun('live', ['git', '-C', '/opt/td-scratch', 'rev-parse', 'HEAD'])).stdout.trim()

    const update = await perform(deps(), 'update', target('service:td-scratch.service'))
    expect(update.wayBack?.actionId).toBe('go-back')
    const after = (await sshRun('live', ['git', '-C', '/opt/td-scratch', 'rev-parse', 'HEAD'])).stdout.trim()
    expect(after).not.toBe(before)
    // The running program is the new one, which is the point of the restart.
    expect((await sshRun('live', ['cat', '/opt/td-scratch/app.sh'])).stdout).toMatch(/version 2/)

    const back = await perform(deps(), 'go-back', target('service:td-scratch.service'))
    expect(back.done).toMatch(/Put/)
    expect((await sshRun('live', ['git', '-C', '/opt/td-scratch', 'rev-parse', 'HEAD'])).stdout.trim()).toBe(before)
    expect((await sshRun('live', ['cat', '/opt/td-scratch/app.sh'])).stdout).toMatch(/version 1/)
  }, 180_000)

  it('refuses to update a checkout somebody has hand-edited, and changes nothing', async () => {
    await sshRun('live', ['sh', '-c', 'echo "# hand edit" >> /opt/td-scratch/app.sh'])
    const before = (await sshRun('live', ['git', '-C', '/opt/td-scratch', 'rev-parse', 'HEAD'])).stdout.trim()
    await expect(perform(deps(), 'update', target('service:td-scratch.service'))).rejects.toThrow(
      /changed this on the server itself/i,
    )
    expect((await sshRun('live', ['git', '-C', '/opt/td-scratch', 'rev-parse', 'HEAD'])).stdout.trim()).toBe(before)
    await sshRun('live', ['git', '-C', '/opt/td-scratch', 'checkout', '--', 'app.sh'])
  }, 60_000)

  it('classifies the container by what the runtime told us, not by its made-up name', () => {
    const card = cardNamed('container:tdscratch-web-1')
    // The compose service's own name is what a person wrote in their file;
    // `tdscratch-web-1` is what the runtime made up from it.
    expect(card.name).toBe('web')
    expect(card.managedBy).toEqual({
      kind: 'container',
      runtime: 'docker',
      name: 'tdscratch-web-1',
      compose: { project: 'tdscratch', service: 'web', workingDir: '/opt/td-scratch-compose' },
    })
    expect(card.running).toBe(true)
    expect(composeAvailable).toBe(true)
  })

  it('updates the container and puts back the exact image it recorded', async () => {
    const before = (
      await sshRun('live', ['docker', 'inspect', '--format', '{{.Image}}', 'tdscratch-web-1'])
    ).stdout.trim()
    const version = async (): Promise<string> =>
      (await sshRun('live', ['docker', 'logs', '--tail', '1', 'tdscratch-web-1'])).stdout.trim()
    const wasRunning = await version()

    const update = await perform(deps(), 'update', target('container:tdscratch-web-1'))
    expect(update.wayBack?.label).toBe('Go back to the previous version')
    const after = (
      await sshRun('live', ['docker', 'inspect', '--format', '{{.Image}}', 'tdscratch-web-1'])
    ).stdout.trim()
    expect(after).not.toBe(before)
    expect(await version()).not.toBe(wasRunning)

    /*
     * The assertion the whole `kept` class exists for. Going back is not "pull
     * again and hope" — it re-points the tag at the **recorded digest** and
     * recreates from it, so the image running afterwards is byte-identical to
     * the one that was running before, and the program inside it says so.
     */
    const back = await perform(deps(), 'go-back', target('container:tdscratch-web-1'))
    expect(back.done).toMatch(/previous version/)
    expect(
      (await sshRun('live', ['docker', 'inspect', '--format', '{{.Image}}', 'tdscratch-web-1'])).stdout.trim(),
    ).toBe(before)
    expect(await version()).toBe(wasRunning)
  }, 300_000)

  it('refuses to go back when the previous version is no longer on the server', async () => {
    /*
     * A machine that prunes on a timer has no way back, and finding that out
     * *after* the update is finding it out too late. So the rollback checks the
     * recorded image is still present and says something true when it is not,
     * rather than pulling the new one again and reporting success.
     */
    const card = cardNamed('container:tdscratch-web-1')
    await journal.put('live', card.id, {
      kind: 'container-image',
      at: Date.now(),
      container: 'tdscratch-web-1',
      imageId: 'sha256:0000000000000000000000000000000000000000000000000000000000000000',
      imageRef: 'alpine:3',
      compose: { project: 'tdscratch', service: 'web', workingDir: '/opt/td-scratch-compose' },
      backupPath: null,
    })
    await expect(perform(deps(), 'go-back', target('container:tdscratch-web-1'))).rejects.toThrow(
      /isn’t on this server any more/i,
    )
  }, 60_000)

  it('copies a real database to this computer, and the copy contains the data', async () => {
    const card = cardNamed('container:tdscratch-db-1')
    expect(card.kind).toBe('database')
    expect(card.engine).toBe('postgres')

    const backupDir = mkdtempSync(join(tmpdir(), 'td-backup-'))
    const outcome = await perform(
      { run: sshRun, journal, download: scpDownload, backupDir },
      'backup',
      target('container:tdscratch-db-1'),
    )
    const value = outcome.value as { path: string; bytes: number }
    expect(value.bytes).toBeGreaterThan(1000)
    const dump = readFileSync(value.path, 'utf8')
    expect(dump).toMatch(/PostgreSQL database cluster dump/)
    expect(dump).toMatch(/CREATE TABLE public.things/)
    expect(dump).toMatch(/hello from a real server/)

    // The temporary file on the server is gone, whatever happened.
    const left = await sshRun('live', ['sh', '-c', 'ls /tmp/td-backup-*.sql 2>/dev/null | wc -l'])
    expect(left.stdout.trim()).toBe('0')
  }, 180_000)

  it('takes the copy before it updates a database, without being asked', async () => {
    /*
     * The instruction this implements, in his terms: **a backup before anything
     * destructive, taken without being asked.** Rolling a container's image back
     * restores the program; it does nothing about a migration the new version
     * ran over the data on its way up. So the copy is part of the way back, it
     * is taken by `keep` rather than offered as a separate button, and the
     * sentence the person reads says so before they press anything.
     */
    const backupDir = mkdtempSync(join(tmpdir(), 'td-preupdate-'))
    const dbTarget = target('container:tdscratch-db-1')
    const preview = previewOf('update', dbTarget, composeAvailable)
    expect(preview.klass).toBe('kept')
    expect(preview.sentence).toMatch(/copy everything in it to your computer first/i)

    const kept = await SERVER_ACTIONS.update.keep?.(
      { run: sshRun, journal, download: scpDownload, backupDir },
      dbTarget,
    )
    expect(kept?.kind).toBe('container-image')
    expect(kept?.backupPath).not.toBeNull()
    const dump = readFileSync(kept?.backupPath ?? '', 'utf8')
    expect(dump).toMatch(/hello from a real server/)
  }, 180_000)

  it('leaves everything that was already running alone', async () => {
    /*
     * The demo broker and the web server on that box are a live service. The
     * assertion is not that this app *could* restart them — it is that this
     * test has not, which is the discipline §8.5 asks for and the reason the
     * scratch estate exists at all.
     */
    const broker = await sshRun('live', ['systemctl', 'is-active', 'terminaldeck-demo-broker.service'])
    expect(broker.stdout.trim()).toBe('active')
  }, 30_000)
})
