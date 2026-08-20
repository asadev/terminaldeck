/**
 * Cards, from facts, on machines that are not this one.
 *
 * Every fixture in this file is output a real machine actually produced —
 * `terminaldeck-server` (Ubuntu 24.04.4, systemd, Docker, Caddy) and the
 * containers run on it. `CLAUDE.md`'s standing instruction is the reason:
 * *"this codebase has repeatedly been wrong in ways only real data exposed."*
 * That happened again while this file was being written, and the case is
 * covered below — `{{index .Labels "k"}}` is a Docker template that fails
 * outright, and against a hand-written fixture it would have looked perfect.
 */

import { describe, expect, it } from 'vitest'
import {
  cannotOf,
  classify,
  emptySurvey,
  engineOf,
  howOf,
  isSafeName,
  isSafePath,
  parseSurvey,
  siteUrl,
  waybackScript,
} from './classify'
import { factCannot, factNo, factYes, type ServerFacts } from './facts'

const AT = 1_700_000_000_000

/** A whole record, with everything absent unless a test says otherwise. */
function facts(overrides: Partial<ServerFacts> = {}): ServerFacts {
  const nothing = factNo<never>(AT, 'asked')
  return {
    serverId: 's1',
    measuredAt: AT,
    os: factYes('Ubuntu 24.04.4 LTS', AT, 'read the operating system'),
    kernel: factYes('Linux 6.8.0-51-generic', AT, 'asked'),
    arch: factYes('x86_64', AT, 'asked'),
    hostname: factYes('terminaldeck-server', AT, 'asked'),
    user: factYes('root', AT, 'asked'),
    privilege: factYes('yes', AT, 'asked'),
    init: factYes('systemd', AT, 'asked'),
    containerRuntime: factYes('docker', AT, 'asked'),
    packageManager: factYes('apt-get', AT, 'asked'),
    webServer: factYes('caddy', AT, 'asked'),
    cpus: factYes(2, AT, 'asked'),
    disk: nothing,
    memory: nothing,
    load1: nothing,
    uptimeSeconds: nothing,
    services: factYes([], AT, 'asked what it is set up to keep running'),
    containers: factYes([], AT, 'asked what is running in containers'),
    listeners: factYes([], AT, 'asked what is accepting connections'),
    siteNames: factYes([], AT, 'read the web settings'),
    agents: factYes([], AT, 'looked for a coding assistant'),
    agentInstall: nothing,
    ...overrides,
  }
}

describe('the three nouns', () => {
  it('names a site from the web settings and gives it a scheme it measured', () => {
    const cards = classify(
      facts({
        siteNames: factYes(['178-105-239-176.sslip.io'], AT, 'read the web settings'),
        listeners: factYes(
          [{ address: '*', port: 443, program: 'caddy', pid: 761, unit: 'caddy.service' }],
          AT,
          'asked',
        ),
      }),
    )
    expect(cards).toHaveLength(1)
    expect(cards[0].kind).toBe('site')
    expect(cards[0].url).toBe('https://178-105-239-176.sslip.io')
    expect(cards[0].detail).toBe('Served by caddy')
    // A site is not a process: we did not ask whether it answers, so we say so
    // rather than drawing a green dot we did not earn.
    expect(cards[0].running).toBeNull()
  })

  it('gives a site no address at all when nothing is listening on a web port', () => {
    /*
     * §3.1: never draw a blank, a zero or a dash where a `cannot` lives. An
     * Open button pointing at a scheme we guessed reaches a connection refused,
     * and the person's reasonable conclusion is that their site is down.
     */
    const cards = classify(facts({ siteNames: factYes(['example.test'], AT, 'read the web settings') }))
    expect(cards[0].url).toBeNull()
  })

  it('files a service an administrator added as an app, and the rest under the heading', () => {
    const cards = classify(
      facts({
        services: factYes(
          [
            // Real rows from the test box.
            { name: 'terminaldeck-demo-broker.service', state: 'running', description: 'Terminal Deck demo broker', addedHere: true },
            { name: 'caddy.service', state: 'running', description: 'Caddy', addedHere: false },
            { name: 'systemd-journald.service', state: 'running', description: 'Journal Service', addedHere: false },
          ],
          AT,
          'asked',
        ),
      }),
    )
    const byId = new Map(cards.map((card) => [card.id, card]))
    expect(byId.get('service:terminaldeck-demo-broker.service')?.kind).toBe('app')
    expect(byId.get('service:caddy.service')?.kind).toBe('other')
    expect(byId.get('service:systemd-journald.service')?.kind).toBe('other')
    // Nothing that is *running* is dropped — only ordered. §3.5. What a unit
    // nobody added and that is not running gets is covered by the test below.
    expect(cards).toHaveLength(3)
  })

  it('leaves out the operating system\u2019s dormant units, and keeps the one that failed', () => {
    /*
     * Measured on the test box, and it is the reason this test exists rather
     * than a preference about tidiness. `systemctl` reports 151 loaded service
     * units there: 7 an administrator added, 22 running, 37 finished one-shots
     * \u2014 and 91 dead, plus exactly one genuinely failed.
     *
     * Drawing a card for each dead one made the calm sentence at the top of the
     * page read "92 things aren\u2019t running" about a healthy server, buried the
     * person\u2019s own website under a hundred and fifty rows of the operating
     * system talking to itself, and \u2014 worst \u2014 put a **Start** button on
     * `rescue`, `emergency` and `initrd-switch-root`.
     *
     * The heading is "Other things running". A unit that is not running is not
     * one of them. A unit that *failed* is, because it is the one row on that
     * box worth somebody\u2019s attention and it was the needle the ninety-one hid.
     */
    const cards = classify(
      facts({
        services: factYes(
          [
            // Every row here is real output from the test box.
            { name: 'terminaldeck-demo-broker.service', state: 'running', description: 'Terminal Deck demo broker', addedHere: true },
            { name: 'caddy.service', state: 'running', description: 'Caddy', addedHere: false },
            { name: 'rescue.service', state: 'stopped', description: 'Rescue Shell', addedHere: false },
            { name: 'emergency.service', state: 'stopped', description: 'Emergency Shell', addedHere: false },
            { name: 'modprobe@drm.service', state: 'stopped', description: 'Load Kernel Module drm', addedHere: false },
            { name: 'cloud-init-hotplugd.service', state: 'failed', description: 'Cloud-init: Hotplug Hook', addedHere: false },
          ],
          AT,
          'asked',
        ),
      }),
    )
    expect(cards.map((card) => card.id).sort()).toEqual([
      'service:caddy.service',
      'service:cloud-init-hotplugd.service',
      'service:terminaldeck-demo-broker.service',
    ])
    /*
     * And the consequence that made this worth fixing rather than tidying: the
     * sentence at the top of the page now names the one thing that is wrong,
     * instead of counting the operating system\u2019s dormant units at somebody.
     */
    const stopped = cards.filter((card) => card.running === false)
    expect(stopped.map((card) => card.name)).toEqual(['cloud-init-hotplugd'])
  })

  it('never offers a way to start a unit it decided not to draw', () => {
    /*
     * The structural half of the test above. The point was never the count on
     * screen \u2014 it was that every one of those rows carried a Start button, and
     * `emergency` and `rescue` are units whose whole purpose is to take the
     * machine away from everybody using it.
     */
    const cards = classify(
      facts({
        services: factYes(
          [
            { name: 'rescue.service', state: 'stopped', description: 'Rescue Shell', addedHere: false },
            { name: 'emergency.service', state: 'stopped', description: 'Emergency Shell', addedHere: false },
            { name: 'initrd-switch-root.service', state: 'stopped', description: 'Switch Root', addedHere: false },
          ],
          AT,
          'asked',
        ),
      }),
    )
    expect(cards).toEqual([])
  })

  it('promotes a database whatever directory its unit file is in', () => {
    /*
     * The one exception to the "an administrator put it there" filter, and
     * without it the filter would hide the thing that matters most: a database
     * installed from a package sits in the operating system's own directory.
     */
    const cards = classify(
      facts({
        services: factYes(
          [{ name: 'postgresql.service', state: 'running', description: 'PostgreSQL RDBMS', addedHere: false }],
          AT,
          'asked',
        ),
        listeners: factYes(
          [{ address: '127.0.0.1', port: 5432, program: 'postgres', pid: 900, unit: 'postgresql.service' }],
          AT,
          'asked',
        ),
      }),
    )
    expect(cards[0].kind).toBe('database')
    expect(cards[0].engine).toBe('postgres')
  })

  it('draws a card with no way to start or stop it, rather than guessing one', () => {
    /*
     * §4.2: *"there is no fallback chain."* A machine whose init system this
     * app has never driven still shows what is on it — the person can see it
     * and reach it from the terminal — and carries no buttons, because a guess
     * here runs a command that does something else.
     */
    const cards = classify(
      facts({
        init: factYes('sysvinit', AT, 'asked'),
        services: factYes([{ name: 'apache2', state: 'running', description: '', addedHere: true }], AT, 'asked'),
      }),
    )
    expect(cards[0].managedBy).toBeNull()
  })

  it('draws no cards at all on a machine with nothing it can be asked about', () => {
    // §3.5's supported outcome, not a failure: a bare container, a BSD box, or
    // an init system this app has never heard of all land here.
    const cards = classify(
      facts({
        init: factCannot(AT, 'we could not tell how this server starts and stops things'),
        containerRuntime: factNo(AT, 'asked'),
        services: factCannot(AT, 'we could not tell how this server starts and stops things'),
        containers: factNo(AT, 'asked'),
      }),
    )
    expect(cards).toEqual([])
  })

  it('names a container by the name a person wrote, not the one the runtime made up', () => {
    const survey = emptySurvey()
    survey.compose.set('tdscratch-web-1', { project: 'tdscratch', service: 'web', workingDir: '/opt/td-scratch-compose' })
    const cards = classify(
      facts({
        containers: factYes(
          [{ name: 'tdscratch-web-1', image: 'alpine:3', state: 'running', status: 'Up 2 minutes', ports: '' }],
          AT,
          'asked',
        ),
      }),
      survey,
    )
    expect(cards[0].name).toBe('web')
    expect(cards[0].detail).toBe('Running in a container from alpine:3')
    expect(cards[0].managedBy).toEqual({
      kind: 'container',
      runtime: 'docker',
      name: 'tdscratch-web-1',
      compose: { project: 'tdscratch', service: 'web', workingDir: '/opt/td-scratch-compose' },
    })
  })

  it('orders sites, then apps, then databases, then the remainder', () => {
    const cards = classify(
      facts({
        siteNames: factYes(['a.test'], AT, 'read'),
        listeners: factYes([{ address: '*', port: 80, program: '', pid: null, unit: '' }], AT, 'asked'),
        services: factYes(
          [
            { name: 'zzz-mine.service', state: 'running', description: '', addedHere: true },
            { name: 'aaa-theirs.service', state: 'running', description: '', addedHere: false },
          ],
          AT,
          'asked',
        ),
        containers: factYes(
          [{ name: 'pg', image: 'postgres:16', state: 'running', status: '', ports: '' }],
          AT,
          'asked',
        ),
      }),
    )
    expect(cards.map((card) => card.kind)).toEqual(['site', 'app', 'database', 'other'])
  })
})

describe('the way-back survey', () => {
  it('asks the container runtime for labels in the form that actually works', () => {
    /*
     * The bug this pins was found by running the script on a real machine and
     * would have been invisible against a fixture. In `docker ps` templates
     * `.Labels` is the comma-joined **string** from the table, so
     * `{{index .Labels "k"}}` fails with *"cannot index slice/array with type
     * string"* — the command exits non-zero, the survey comes back empty, and
     * the result looks exactly like a machine that runs no compose projects.
     * Every Update button would have been missing on every server, silently.
     */
    const script = waybackScript(facts())
    expect(script).toContain('{{.Label "com.docker.compose.project"}}')
    expect(script).not.toContain('index .Labels')
  })

  it('asks nothing of a runtime the probe could not reach', () => {
    const script = waybackScript(facts({ containerRuntime: factCannot(AT, 'not allowed to ask') }))
    expect(script).not.toContain('docker')
    expect(script).toContain('##compose')
  })

  it('asks only about services an administrator added, and never about all four hundred', () => {
    const script = waybackScript(
      facts({
        services: factYes(
          [
            { name: 'mine.service', state: 'running', description: '', addedHere: true },
            { name: 'systemd-udevd.service', state: 'running', description: '', addedHere: false },
          ],
          AT,
          'asked',
        ),
      }),
    )
    expect(script).toContain("'mine.service'")
    expect(script).not.toContain('systemd-udevd')
  })

  it('reads the real shape the runtime prints, and drops rows with no project', () => {
    const survey = parseSurvey(
      [
        '##compose-available',
        'yes',
        '##compose',
        'tdscratch-web-1\ttdscratch\tweb\t/opt/td-scratch-compose',
        'hand-started\t\t\t',
        '##repos',
        'td-scratch.service\t/opt/td-scratch',
      ].join('\n'),
    )
    expect(survey.compose_available).toBe(true)
    expect(survey.compose.get('tdscratch-web-1')).toEqual({
      project: 'tdscratch',
      service: 'web',
      workingDir: '/opt/td-scratch-compose',
    })
    // A container started by hand has no project, so it has no way back and no
    // entry — which is what removes its Update button.
    expect(survey.compose.has('hand-started')).toBe(false)
    expect(survey.repos.get('td-scratch.service')).toBe('/opt/td-scratch')
  })

  it('answers "no compose here" rather than throwing when the tool is missing', () => {
    // Measured on the real box: Ubuntu's own docker package ships no compose
    // plugin, and the probe of it prints `no`.
    expect(parseSurvey('##compose-available\nno\n##compose\n##repos\n').compose_available).toBe(false)
    expect(parseSurvey('').compose_available).toBe(false)
  })

  it('refuses a path or a name it would not be willing to send back', () => {
    const survey = parseSurvey(
      ['##compose', 'evil\tproj$(rm -rf /)\tsvc\t/tmp', 'ok\tproj\tsvc\t/tmp/x; reboot'].join('\n'),
    )
    expect(survey.compose.size).toBe(0)
  })
})

describe('the small decisions', () => {
  it('recognises engines by whole words, and does not see one inside another name', () => {
    expect(engineOf('postgres:16-alpine')).toBe('postgres')
    expect(engineOf('mariadb:11')).toBe('mariadb')
    expect(engineOf('ghcr.io/acme/redis-cache:1')).toBe('redis')
    expect(engineOf('my-app:latest')).toBeNull()
    // The trap: a name that merely contains the letters.
    expect(engineOf('nomongolia:1')).toBeNull()
  })

  it('refuses names and paths with anything a shell could find in them', () => {
    expect(isSafeName('td-scratch.service')).toBe(true)
    expect(isSafeName('a b')).toBe(false)
    expect(isSafeName('$(reboot)')).toBe(false)
    expect(isSafePath('/opt/td-scratch')).toBe(true)
    expect(isSafePath('opt/relative')).toBe(false)
    expect(isSafePath('/opt/`reboot`')).toBe(false)
  })

  it('reports what it asked, and only for the questions that answered', () => {
    const how = howOf(facts())
    expect(how).toContain('asked what it is set up to keep running')
    // Deduplicated: four facts sharing a `how` produce one line, not four.
    expect(new Set(how).size).toBe(how.length)
  })

  it('carries the server’s own reason for every question it could not ask', () => {
    const cannot = cannotOf(
      facts({
        containers: factCannot(AT, 'this sign-in is not allowed to ask this server about its containers'),
      }),
    )
    expect(cannot).toEqual([
      {
        what: 'anything running in a container',
        why: 'this sign-in is not allowed to ask this server about its containers',
      },
    ])
  })

  it('never turns a hostname pattern into an address', () => {
    const listeners = [{ address: '*', port: 443, program: '', pid: null, unit: '' }]
    expect(siteUrl('*.example.com', listeners)).toBeNull()
    expect(siteUrl('', listeners)).toBeNull()
    expect(siteUrl('example.com', listeners)).toBe('https://example.com')
  })
})
