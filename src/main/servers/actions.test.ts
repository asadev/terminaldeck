/**
 * The buttons a card carries, the commands behind them, and the sentences when
 * they fail.
 *
 * Every command asserted here was run against a real Ubuntu 24.04 server before
 * it was written down — see `actions.live.test.ts`, which drives this same code
 * end to end over a real connection. What this file adds is the cases that are
 * *inconvenient* to stand up on a real machine: an account with no `sudo`, a
 * server with no container runtime, an init system this app has never driven,
 * and a database whose engine we cannot copy.
 *
 * The rule those cases are all about is rule 4, in Asad's words: *"make sure we
 * don't design it as per our design, it's gonna be used for all so they might
 * have different settings, we need something common."*
 */

import { describe, expect, it } from 'vitest'
import {
  ActionRefused,
  DEFAULT_LOG_LINES,
  MAX_LOG_LINES,
  MemoryJournal,
  NOT_YOURS_TO_STOP,
  SERVER_ACTIONS,
  availableActions,
  canBackUp,
  dumpCommand,
  elevate,
  failureSentence,
  logCommand,
  perform,
  previewOf,
  serviceCommand,
  shellJoin,
  updateKind,
} from './actions'
import { quote } from './connection'
import { factNo, factYes, type Privilege } from './facts'
import { cmd, containerCard, facts, looseContainerCard, repoCard, siteCard } from './test-fixtures'

const AT = 1_700_000_000_000
const AVAILABLE = { canDownload: true, composeAvailable: true }

describe('one command, chosen from a measured fact', () => {
  it('runs it plainly when the sign-in is already the administrator', () => {
    expect(serviceCommand({ kind: 'systemd', unit: 'x.service' }, 'restart', facts())).toEqual([
      'systemctl',
      'restart',
      'x.service',
    ])
  })

  it('asks non-interactively when it is not, and never waits on a password prompt', () => {
    /*
     * §3.4's trap: `sudo-password` and "not in the sudoers file at all" are
     * indistinguishable without trying. `-n` is what makes trying safe — it
     * fails immediately instead of hanging on a prompt nobody can see, and the
     * failure maps to a sentence that is true in both cases.
     */
    const asUser = facts({ privilege: factYes<Privilege>('sudo-password', AT, 'asked') })
    expect(serviceCommand({ kind: 'systemd', unit: 'x.service' }, 'stop', asUser)).toEqual([
      'sudo',
      '-n',
      'systemctl',
      'stop',
      'x.service',
    ])
    expect(elevate(asUser, ['whoami'])).toEqual(['sudo', '-n', 'whoami'])
  })

  it('speaks each init system’s own dialect, and never tries a second one', () => {
    expect(serviceCommand({ kind: 'openrc', service: 'nginx' }, 'restart', facts())).toEqual([
      'rc-service',
      'nginx',
      'restart',
    ])
  })

  it('does not elevate a container runtime the probe already reached as this user', () => {
    // The facts probe proved this account can talk to the runtime by running
    // `docker info` successfully as itself. Adding `sudo` would be asking for a
    // privilege we know is not needed, and failing on a machine that has none.
    const asUser = facts({ privilege: factYes<Privilege>('sudo-password', AT, 'asked') })
    expect(
      serviceCommand({ kind: 'container', runtime: 'docker', name: 'c1', compose: null }, 'restart', asUser),
    ).toEqual(['docker', 'restart', 'c1'])
  })

  it('refuses a name it would not be willing to send', () => {
    expect(serviceCommand({ kind: 'systemd', unit: 'x; reboot' }, 'stop', facts())).toBeNull()
  })

  it('reads a bounded window of log, and has none to read for an init system with no journal', () => {
    expect(logCommand({ kind: 'systemd', unit: 'x.service' }, DEFAULT_LOG_LINES, facts())).toEqual([
      'journalctl',
      '-u',
      'x.service',
      '-n',
      '200',
      '--no-pager',
      '-o',
      'short-iso',
    ])
    expect(logCommand({ kind: 'container', runtime: 'docker', name: 'c1', compose: null }, 5, facts())).toContain(
      '--tail',
    )
    // OpenRC has no journal and no file whose location we could know without
    // assuming one. A Logs button showing the wrong file is worse than none.
    expect(logCommand({ kind: 'openrc', service: 'nginx' }, 200, facts())).toBeNull()
  })

  it('clamps a log window a caller has got wrong', () => {
    expect(logCommand({ kind: 'systemd', unit: 'x.service' }, 10_000_000, facts())).toContain(String(MAX_LOG_LINES))
    expect(logCommand({ kind: 'systemd', unit: 'x.service' }, -4, facts())).toContain('1')
  })
})

describe('a control that cannot act is absent, with its reason', () => {
  it('offers Open only where the server gave a real address', () => {
    expect(availableActions(siteCard(), facts(), AVAILABLE).offered).toContain('open')
    expect(availableActions(repoCard(), facts(), AVAILABLE).offered).not.toContain('open')
  })

  it('offers Start for something stopped, and Stop for something running — never both', () => {
    const running = availableActions(repoCard(), facts(), AVAILABLE).offered
    expect(running).toContain('stop')
    expect(running).not.toContain('start')
    const stopped = availableActions(repoCard({ running: false }), facts(), AVAILABLE).offered
    expect(stopped).toContain('start')
    expect(stopped).not.toContain('stop')
  })

  it('says so when it cannot tell how the server starts and stops things', () => {
    const availability = availableActions(repoCard({ managedBy: null }), facts(), AVAILABLE)
    expect(availability.offered).not.toContain('restart')
    expect(availability.absent).toContainEqual({
      actionId: 'restart',
      because: 'We can’t tell how this server starts and stops things, so we’re not going to guess.',
    })
  })

  it('offers nothing that changes a thing nobody here set up, and says why once', () => {
    /*
     * The remainder heading on a real Ubuntu box was fifty-odd rows of the
     * operating system talking to itself — `apparmor`, `ufw`, `systemd-udevd`,
     * `user@0` — and every one of them carried Restart and Stop. Sixty-four
     * buttons on one page, a good half of which take the machine or this app's
     * own connection down with them.
     *
     * Reading survives, because "what is this and is it unhappy" is the
     * question somebody opening that group actually has.
     */
    const os = repoCard({ id: 'service:systemd-udevd.service', kind: 'other', name: 'systemd-udevd' })
    const availability = availableActions(os, facts(), AVAILABLE)
    expect(availability.offered).toEqual(['logs'])
    expect(availability.absent).toEqual([{ actionId: 'restart', because: NOT_YOURS_TO_STOP }])
    // And the same card in a group we *can* attribute to somebody keeps every
    // one of them — the discriminator is `addedHere`, not the name.
    expect(availableActions(repoCard({ name: 'systemd-udevd' }), facts(), AVAILABLE).offered).toContain('stop')
  })

  it('says so when the sign-in could never administer this server', () => {
    const availability = availableActions(repoCard(), facts({ privilege: factNo(AT, 'asked') }), AVAILABLE)
    expect(availability.offered).not.toContain('restart')
    expect(availability.absent).toContainEqual({
      actionId: 'restart',
      because: 'This sign-in can’t start or stop things on this server.',
    })
  })

  it('offers no Backup for an engine it cannot copy safely, and says which fact was missing', () => {
    // Recognising the engine is what makes the card a Database. Knowing how to
    // dump it is what puts a Backup button on it. The two are different facts
    // and the card says which one is absent.
    const redis = containerCard({ engine: 'redis', kind: 'database' })
    const availability = availableActions(redis, facts(), AVAILABLE)
    expect(availability.offered).not.toContain('backup')
    expect(availability.absent).toContainEqual({
      actionId: 'backup',
      because: 'We can’t tell what kind of database this is, so we don’t know how to copy it safely.',
    })
  })

  it('offers no Backup at all on a build that cannot move a file', () => {
    const database = containerCard({ engine: 'postgres', kind: 'database' })
    const availability = availableActions(database, facts(), { canDownload: false, composeAvailable: true })
    expect(availability.absent).toContainEqual({
      actionId: 'backup',
      because: 'This app can’t copy files off a server yet.',
    })
  })

  it('offers no Update for a container somebody started by hand', () => {
    /*
     * Recreating a container from a reconstructed `docker run` line is a guess
     * about what somebody meant, and a wrong guess is a container that comes
     * back missing a volume. A compose project's own labels are a fact the
     * server told us; nothing else is.
     */
    expect(updateKind(looseContainerCard(), true)).toBeNull()
    const availability = availableActions(looseContainerCard(), facts(), AVAILABLE)
    expect(availability.offered).not.toContain('update')
    expect(availability.absent.find((row) => row.actionId === 'update')?.because).toMatch(/how this was set up/)
  })

  it('offers no Update when the server has no tool to put a container back', () => {
    // Measured on the real box: Ubuntu's own docker package ships no compose
    // plugin. An Update that shelled out to it would fail *after* the pull.
    const availability = availableActions(containerCard(), facts(), { canDownload: true, composeAvailable: false })
    expect(availability.offered).not.toContain('update')
    expect(availability.absent.find((row) => row.actionId === 'update')?.because).toMatch(
      /doesn’t have the tool we’d use to put a container back/,
    )
  })

  it('offers no Update for a database it cannot copy first', () => {
    const database = containerCard({ engine: 'postgres', kind: 'database' })
    const availability = availableActions(database, facts(), { canDownload: false, composeAvailable: true })
    expect(availability.offered).not.toContain('update')
    expect(availability.absent.find((row) => row.actionId === 'update')?.because).toMatch(
      /updating a database without one isn’t something we can undo/,
    )
  })
})

describe('the dump command, and the engines that have none', () => {
  it('reads the credentials out of the container’s own environment, never from this app', () => {
    const managedBy = { kind: 'container', runtime: 'docker', name: 'db', compose: null } as const
    const postgres = dumpCommand('postgres', managedBy)
    expect(postgres?.dump.join(' ')).toContain('POSTGRES_USER')
    expect(postgres?.probe.join(' ')).toContain('command -v pg_dumpall')

    const mysql = dumpCommand('mysql', managedBy)
    // MYSQL_PWD rather than `-p` on the command line, so the password does not
    // appear in the container's own process list.
    expect(mysql?.dump.join(' ')).toContain('MYSQL_PWD')
    expect(mysql?.dump.join(' ')).not.toMatch(/-p['"]?\$/)
  })

  it('has none for an engine on the host, or for one it does not know', () => {
    // A database installed on the host is deliberately not covered: Postgres
    // would work through peer authentication and MySQL would not, and a Backup
    // button that succeeds on one engine and fails on another for a reason
    // nothing on the card can explain is a half-answer.
    expect(dumpCommand('postgres', { kind: 'systemd', unit: 'postgresql.service' })).toBeNull()
    expect(dumpCommand('mongo', { kind: 'container', runtime: 'docker', name: 'm', compose: null })).toBeNull()
    expect(canBackUp('redis', { kind: 'container', runtime: 'docker', name: 'r', compose: null })).toBe(false)
    expect(canBackUp(null, null)).toBe(false)
  })
})

describe('a failure is a sentence too', () => {
  it('says "not allowed" only when the server said permission', () => {
    const refused = failureSentence(cmd({ code: 1, stderr: 'Failed to restart x.service: Access denied' }), 'your site')
    expect(refused.sentence).toBe('This sign-in isn’t allowed to do that on this server.')

    const sudo = failureSentence(cmd({ code: 1, stderr: 'sudo: a password is required' }), 'your site')
    expect(sudo.sentence).toBe('This sign-in isn’t allowed to do that on this server.')
  })

  it('does not say "not allowed" for a thing that simply is not there', () => {
    /*
     * The distinction matters because the two have different fixes. Answering
     * "you are not allowed" to a unit that does not exist sends somebody to
     * change a permission that was never the problem.
     */
    const missing = failureSentence(cmd({ code: 5, stderr: 'Unit x.service could not be found.' }), 'your site')
    expect(missing.sentence).toBe('The server couldn’t find your site any more.')
  })

  it('relays what the server said rather than inventing a diagnosis', () => {
    const other = failureSentence(cmd({ code: 1, stderr: 'Job for x.service failed' }), 'your site')
    expect(other.sentence).toBe('The server refused to do that to your site.')
    // The server's own words survive, behind the disclosure.
    expect(other.detail).toContain('Job for x.service failed')
  })

  it('treats a command the kernel stopped as a failure, not a success', () => {
    const killed = failureSentence(cmd({ code: null, signal: 'SIGKILL' }), 'your site')
    expect(killed.detail).toContain('SIGKILL')
  })
})

describe('the small guarantees', () => {
  it('quotes an argument exactly the way the transport does', () => {
    /*
     * Two implementations of POSIX quoting in one repository is two answers to
     * one question, and the day they disagree is the day a redirect goes
     * somewhere nobody intended. `shellJoin` exists because a bare argv cannot
     * express a redirection into a file on the far end; this pins it to
     * `connection.ts`'s own `quote`, character for character, on everything
     * that has ever broken a quoting routine.
     */
    const nasty = ["it's", '$(reboot)', '`reboot`', 'a b', 'x"y', '\\', '\n', '', 'a;b|c&d']
    for (const argument of nasty) {
      expect(shellJoin([argument]), argument).toBe(quote(argument))
    }
    expect(shellJoin(['echo', 'hello world'])).toBe("'echo' 'hello world'")
  })

  it('refuses to open something the server gave no address for', async () => {
    await expect(
      perform({ run: async () => cmd(), journal: new MemoryJournal() }, 'open', {
        serverId: 's1',
        card: repoCard(),
        facts: facts(),
      }),
    ).rejects.toBeInstanceOf(ActionRefused)
  })

  it('does the two local actions here rather than on the server', () => {
    expect(SERVER_ACTIONS.open.where).toBe('here')
    expect(SERVER_ACTIONS['copy-address'].where).toBe('here')
    expect(SERVER_ACTIONS.restart.where).toBe('server')
  })

  it('describes what a person is about to do, in full, before they press', () => {
    const preview = previewOf('stop', { serverId: 's1', card: repoCard(), facts: facts() })
    expect(preview).toMatchObject({
      actionId: 'stop',
      klass: 'reversible',
      label: 'Stop',
      target: 'td-scratch',
      wayBack: 'Start',
      keeps: null,
    })
    expect(preview.sentence).toContain('td-scratch')
  })
})
