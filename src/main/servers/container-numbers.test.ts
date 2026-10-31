import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { parseProbe } from './probe.sh'
import { CONTAINER_INHERITED_FACTS, CONTAINER_NUMBERS_WHY, numbersBelongToTheHost } from './facts'
import type { ServerFacts } from './facts'

/**
 * A container's numbers are somebody else's numbers, and this is why that is a
 * test rather than a note.
 *
 * Measured, on a Debian container running on the test box, and kept in
 * `probe-fixtures/container-nothing-installed.txt` exactly as it came back:
 *
 *     disk_total_kb=39020108     ← the Hetzner machine's 39 GB
 *     uptime_s=233949            ← the Hetzner machine's two and a half days
 *     memory_total_kb=3911564    ← the Hetzner machine's memory
 *     load1=0.08                 ← the Hetzner machine's load
 *
 * The container had been alive for seconds and has none of that disk. `df`,
 * `/proc/meminfo`, `/proc/loadavg` and `/proc/uptime` are all inherited from the
 * host in the ordinary container configuration, and every one of those four
 * numbers is real, plausible, and about a computer the person is not looking at.
 *
 * A card reading "Disk 16% full" there is not imprecise. It is a true statement
 * about the wrong machine, which is worse than no card at all — and it is
 * exactly the class of thing that ships green, because nothing about it looks
 * wrong from here.
 *
 * Reading the cgroup limits to get the container's own figures is a reasonable
 * second version. Inventing them in the first is the failure this whole model
 * exists to prevent, so the four are refused, with the reason on screen where
 * the number would have been.
 */

const CONTAINER = readFileSync(
  resolve(__dirname, 'probe-fixtures', 'container-nothing-installed.txt'),
  'utf8',
)

describe("a container's inherited numbers", () => {
  const facts = parseProbe(CONTAINER, 'server-1', 1_000)

  it('are recognised as a container in the first place', () => {
    expect(facts.init).toMatchObject({ known: 'yes', value: 'container-none' })
    expect(numbersBelongToTheHost(facts)).toBe(true)
  })

  it('are never reported as measured, even though the server answered with them', () => {
    // The fixture *does* contain values for all four. This is the point: the
    // refusal is a decision made here, not an absence of data.
    expect(CONTAINER).toMatch(/disk_total_kb=\d+/)
    expect(CONTAINER).toMatch(/uptime_s=\d+/)
    for (const name of CONTAINER_INHERITED_FACTS) {
      expect(facts[name].known, `${name} was reported`).toBe('cannot')
    }
  })

  it('say whose numbers they would have been', () => {
    for (const name of CONTAINER_INHERITED_FACTS) {
      const fact = facts[name]
      expect(fact.known === 'cannot' && fact.why).toBe(CONTAINER_NUMBERS_WHY)
    }
  })

  it('leave alone the facts a container does know about itself', () => {
    // The refusal is surgical. A container genuinely knows what it is running,
    // how many processors it can see, and what it can install — blanking those
    // as well would be over-correcting into a different kind of dishonesty.
    expect(facts.os.known).toBe('yes')
    expect(facts.packageManager.known).toBe('yes')
    expect(facts.cpus.known).toBe('yes')
  })
})

describe('the same numbers on a machine that owns them', () => {
  const facts = parseProbe(
    readFileSync(resolve(__dirname, 'probe-fixtures', 'ubuntu-administrator.txt'), 'utf8'),
    'server-1',
    1_000,
  )

  it('are reported, because there they are true', () => {
    expect(numbersBelongToTheHost(facts)).toBe(false)
    for (const name of CONTAINER_INHERITED_FACTS) {
      expect(facts[name].known, `${name} was refused`).toBe('yes')
    }
  })

  it('never shows a used figure without the total it is out of', () => {
    // "5.5 GB used" with no denominator is a number nobody can act on, so the
    // pair travels together or not at all.
    const partial = parseProbe('init=systemd\ndisk_used_kb=100\n#end ok\n', 's', 1)
    expect(partial.disk.known).toBe('cannot')
  })
})

describe('the rule cannot be worked around by reading the raw output', () => {
  it('is applied by the only thing that produces facts', () => {
    // There is no exported reader of the scalar lines, so nothing above this
    // layer can reach `disk_total_kb` and draw it. If that ever changes, this
    // is the test that should stop compiling.
    const exported = Object.keys(
      parseProbe('', 's', 1) as unknown as Record<string, unknown>,
    ) as (keyof ServerFacts)[]
    expect(exported).not.toContain('scalars' as keyof ServerFacts)
    expect(exported).toContain('disk')
  })
})
