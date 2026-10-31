import { mkdirSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { writeFileAtomic } from '../atomic-write'

/**
 * One switch per project: "Give agents Stays Fixed".
 *
 * ## Why the default is "on, once it is set up" rather than a stored `true`
 *
 * The owner's ask is that agents get it *automatically*. A project nobody has
 * set up has nothing for an agent to check against — the engine would refuse
 * every call with "nothing is set up here" — so handing it over before then
 * would be a server that answers every question with a refusal. Once the
 * settings file exists, the default flips to on without anything being written,
 * and only a person turning it **off** is stored. So the record holds decisions,
 * not defaults: a project nobody touched has no line here at all.
 *
 * It lives in this app's own userData, not in the project. Whether this
 * computer's agents get a tool is a fact about this computer — a teammate who
 * pulls the repository has their own app and their own answer.
 */

const FILE = 'staysfixed.json'

interface Stored {
  version: 1
  projects: Record<string, { agents?: boolean }>
}

export interface StaysFixedPrefs {
  /** The person's own answer for this folder, or null when they never gave one. */
  agentsChoice(projectPath: string): boolean | null
  setAgents(projectPath: string, on: boolean): void
}

function key(projectPath: string): string {
  return resolve(projectPath)
}

export function openPrefs(userData: string): StaysFixedPrefs {
  const file = resolve(userData, FILE)
  let cache: Stored | null = null

  const load = (): Stored => {
    if (cache) return cache
    try {
      const raw = JSON.parse(readFileSync(file, 'utf8')) as Partial<Stored>
      const projects = typeof raw.projects === 'object' && raw.projects !== null ? raw.projects : {}
      cache = { version: 1, projects }
    } catch {
      // Missing is the ordinary first-run state; unreadable is treated the same,
      // because the only thing lost is a switch that falls back to its default.
      cache = { version: 1, projects: {} }
    }
    return cache
  }

  return {
    agentsChoice(projectPath) {
      const value = load().projects[key(projectPath)]?.agents
      return typeof value === 'boolean' ? value : null
    },
    setAgents(projectPath, on) {
      const next = load()
      next.projects[key(projectPath)] = { ...next.projects[key(projectPath)], agents: on }
      mkdirSync(dirname(file), { recursive: true })
      writeFileAtomic(file, `${JSON.stringify(next, null, 2)}\n`)
      cache = next
    },
  }
}

/** On unless the person said off, and never before the project is set up. */
export function agentsOn(prefs: StaysFixedPrefs, projectPath: string, setUp: boolean): boolean {
  if (!setUp) return false
  return prefs.agentsChoice(projectPath) ?? true
}
