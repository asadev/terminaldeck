/**
 * What each plugin was allowed, and whether it is switched on.
 *
 * One small file, `<userData>/plugin-grants.json`, written only by
 * {@link PluginHost} after a person answered yes (or narrowed what they had
 * allowed, which needs no question). No channel a plugin or a model can reach
 * writes it. A plugin cannot reach it on disk either: its sandbox can write
 * only its own data folder. And the assistant — the one agent a plugin's tools
 * are offered to — is refused writing it by the records fence
 * (`confine/records.ts`), so it cannot grant its own plugin tools by editing
 * the file; `host.test.ts` pins the fence's spelling of the path to this one.
 *
 * ## The shape, and why a grant carries a hash
 *
 *     { "format": 1,
 *       "plugins": { "word-count": { "enabled": true,
 *         "grant": { "hash": "…", "capabilities": ["tasks.read"], "projects": [], "grantedAt": 1759… } } } }
 *
 * `hash` is the hash of the plugin's folder when the person said yes. A grant
 * whose hash is not the folder's hash *now* is not a grant: the code changed,
 * and nobody has looked at the new code. The record stays — so the pane can say
 * "this changed since you allowed it" rather than "never allowed" — and is
 * replaced the next time they allow it.
 *
 * ## Default deny, including on a bad file
 *
 * A file that cannot be read, or reads as something else, is treated as empty:
 * nothing enabled, nothing granted. Every plugin then asks again, which is
 * annoying and safe; the other reading of a corrupt permission file is not.
 */

import { mkdirSync, readFileSync, rmSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { writeFileAtomic } from '../atomic-write'
import { isPluginCapability, PLUGIN_GRANTS_FILE, type PluginCapability } from '../../shared/plugins'

export interface PluginGrant {
  /** The folder hash the person was shown. See the header. */
  hash: string
  capabilities: PluginCapability[]
  /** Real paths of the projects a project-scoped capability covers. */
  projects: string[]
  grantedAt: number
}

export interface PluginRecord {
  enabled: boolean
  grant: PluginGrant | null
}

interface GrantsFile {
  format: 1
  plugins: Record<string, PluginRecord>
}

const EMPTY: PluginRecord = Object.freeze({ enabled: false, grant: null })

function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === 'string') : []
}

function readGrant(value: unknown): PluginGrant | null {
  if (typeof value !== 'object' || value === null) return null
  const raw = value as Record<string, unknown>
  if (typeof raw.hash !== 'string' || !/^[0-9a-f]{64}$/.test(raw.hash)) return null
  return {
    hash: raw.hash,
    capabilities: strings(raw.capabilities).filter(isPluginCapability),
    projects: strings(raw.projects),
    grantedAt: typeof raw.grantedAt === 'number' && Number.isFinite(raw.grantedAt) ? raw.grantedAt : 0,
  }
}

export class PluginGrants {
  private readonly file: string
  private records = new Map<string, PluginRecord>()

  constructor(userData: string) {
    this.file = join(userData, PLUGIN_GRANTS_FILE)
    this.load()
  }

  private load(): void {
    this.records.clear()
    let raw: unknown
    try {
      raw = JSON.parse(readFileSync(this.file, 'utf8'))
    } catch {
      return
    }
    if (typeof raw !== 'object' || raw === null || (raw as { format?: unknown }).format !== 1) return
    const plugins = (raw as { plugins?: unknown }).plugins
    if (typeof plugins !== 'object' || plugins === null) return
    for (const [id, value] of Object.entries(plugins as Record<string, unknown>)) {
      if (typeof value !== 'object' || value === null) continue
      const record = value as Record<string, unknown>
      this.records.set(id, { enabled: record.enabled === true, grant: readGrant(record.grant) })
    }
  }

  private save(): void {
    const body: GrantsFile = { format: 1, plugins: Object.fromEntries(this.records) }
    mkdirSync(dirname(this.file), { recursive: true })
    writeFileAtomic(this.file, `${JSON.stringify(body, null, 2)}\n`)
  }

  get(id: string): PluginRecord {
    return this.records.get(id) ?? EMPTY
  }

  /** The grant, only when it was given for this exact code. */
  validGrant(id: string, hash: string | null): PluginGrant | null {
    const grant = this.get(id).grant
    return grant !== null && hash !== null && grant.hash === hash ? grant : null
  }

  setEnabled(id: string, enabled: boolean): void {
    this.records.set(id, { ...this.get(id), enabled })
    this.save()
  }

  setGrant(id: string, grant: PluginGrant, enabled: boolean): void {
    this.records.set(id, { enabled, grant: { ...grant, capabilities: [...grant.capabilities], projects: [...grant.projects] } })
    this.save()
  }

  forget(id: string): void {
    if (!this.records.delete(id)) return
    if (this.records.size === 0) {
      rmSync(this.file, { force: true })
      return
    }
    this.save()
  }
}
