/**
 * Which paired devices may reach the copilot, and how far.
 *
 * ## Why this is not a boolean
 *
 * `COPILOT-DESIGN.md` settles that copilot access over the relay is *"a separate
 * capability grant, off by default, granted per device"*, and phases it last:
 * *"remote access to an agent that can rewrite settings and spawn sessions is
 * the highest-stakes surface in the product."* Correct, and the trap is in the
 * word "grant" being singular.
 *
 * The copilot's tools have the same names locally and remotely, on purpose, so
 * there is one model to understand. A single boolean therefore makes "my phone
 * can ask the copilot which session is stuck" and "my phone can rewrite my
 * settings and kill the session I am working in" the same click. That is not a
 * theoretical objection: OpenClaw shipped exactly it — advisory
 * GHSA-943q-mwmv-hhvh (OC-02), where the HTTP gateway did not deny
 * session-orchestration tools by default, so anyone holding gateway auth could
 * call `sessions_spawn` and `sessions_send`.
 *
 * So a grant is three answers: {@link TierGrant}. Read is a phone that can see
 * the fleet; act is one that can start and steer work; alter is the one that
 * cannot be granted at all (below). Deciding this now costs nothing; a boolean
 * shipped once is a migration, and a migration of a permission is the kind
 * where somebody has to choose what an old `true` meant.
 *
 * ## `alter` is never grantable from here, and the type still has it
 *
 * `set()` clamps it to false and `load()` scrubs it out of a hand-edited file.
 * Keeping the field rather than dropping it from the type is deliberate:
 *
 *  - The tier set is `deck-control`'s, not this file's. A grant that could only
 *    express two of the three tiers would need translating at the boundary, and
 *    a translation is where a third tier added later arrives as `undefined` and
 *    reads as false in one place and true in another.
 *  - It makes the refusal *checkable*. `alter: false` in a stored file that a
 *    person has edited to `true` is a case with a test against it. A missing
 *    field is a case with nothing to assert about.
 *
 * The rule it encodes: a confirmation dialog appears on the desktop, and the
 * person holding the phone is by definition not the person who would answer it.
 * Granting a phone the tier whose entire safety property is "a human at the
 * machine says yes" is granting away the property.
 *
 * ## Absence means nothing granted — the opposite of `folder-grants.ts`
 *
 * That file falls back to the desktop's own folder list for a device with no
 * record, and says at length why: two phones were already paired when it was
 * written, and shipping a feature that silently stopped them starting sessions
 * would have been a worse bug than the one being fixed.
 *
 * The reasoning does not carry over, and the difference is worth stating so the
 * two files do not get "made consistent" later. Nobody has ever had remote
 * copilot access, so nobody can lose it. There is no behaviour to preserve, only
 * a default to choose, and off is the default Asad chose. Unknown device,
 * unreadable file, malformed record: all of them are {@link NO_TIERS}.
 *
 * ## Why its own file, and not a field on the folder grants
 *
 * Same argument `folder-grants.ts` makes for not living in `remote-auth.json`:
 * that file's parser drops every field it does not recognise, so a second module
 * writing into it would have its data erased by the next approve or revoke. And
 * the split is right anyway — losing a folder list costs a preference, losing
 * this costs a permission, and a file holding both is a file whose worst case is
 * the worse of the two.
 */

import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { NO_TIERS, TIERS, type Tier, type TierGrant } from '../deck-control/surface'
import { writeSecretFile } from './secret-file'

/** One device's copilot access, as the settings panel lists it. */
export interface DeviceCopilotGrant {
  deviceId: string
  tiers: TierGrant
}

export const REMOTE_COPILOT_FILE = 'remote-copilot.json'

/** Written into the file so a later format can tell itself apart from this one. */
const FORMAT_VERSION = 1

/**
 * Tiers a device may be granted **from anywhere**.
 *
 * Not a preference and not a default — a ceiling. `alter` is absent and the
 * absence is the mechanism: every path into this store filters against this
 * list, so there is no argument, no file edit and no future settings toggle that
 * puts `alter: true` in memory.
 */
export const REMOTE_GRANTABLE_TIERS: readonly Tier[] = ['read', 'act']

/**
 * Matches `MAX_DEVICES` in the trust store: a device that cannot be paired
 * cannot be granted anything, so a larger ceiling here would only bound a file
 * nothing can reach.
 */
const MAX_DEVICES = 64
const MAX_FILE_BYTES = 64 * 1024

interface StoredState {
  version: number
  devices: Record<string, Record<string, boolean>>
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * Read anything into a grant, keeping only what is both a tier and grantable.
 *
 * Exported because it is the whole of the rule and it is worth being able to
 * test it without a filesystem. Three properties, all of them load-bearing:
 *
 *  - **A non-object is nothing.** Including `true`. If a boolean-shaped grant
 *    ever appears in this file — hand-written, or from some future build that
 *    got it wrong — it is read as no access rather than as "they meant all of
 *    it". Guessing generously at a permission is how a permission gets widened
 *    by a bug in a parser.
 *  - **Only literal `true` grants.** `"yes"`, `1` and `"true"` are all false
 *    here. A JSON file a person may edit will eventually contain one of them,
 *    and the difference between reading it as an intention and reading it as a
 *    mistake is a difference in who gets access.
 *  - **`alter` cannot survive.** It is not in {@link REMOTE_GRANTABLE_TIERS}, so
 *    it is dropped whatever it says.
 */
export function copilotGrantFrom(raw: unknown): TierGrant {
  if (!isRecord(raw)) return NO_TIERS
  const grant: Record<Tier, boolean> = { read: false, act: false, alter: false }
  for (const tier of REMOTE_GRANTABLE_TIERS) {
    grant[tier] = raw[tier] === true
  }
  return Object.freeze(grant)
}

/** True when this grant permits nothing at all. */
export function grantsNothing(grant: TierGrant): boolean {
  return TIERS.every((tier) => !grant[tier])
}

/**
 * Per-device copilot access, on disk, with the app's copy in memory.
 *
 * No Electron import, for the same reason `device-auth.ts` and
 * `folder-grants.ts` have none: the storage directory is a constructor argument,
 * so the whole thing runs against a temp directory under vitest with no `app`
 * object anywhere near it.
 */
export class CopilotGrants {
  /** Absolute path of the file. Exposed for diagnostics and tests. */
  readonly file: string

  private readonly dir: string
  private grants = new Map<string, TierGrant>()

  constructor(storageDir: string) {
    this.dir = storageDir
    this.file = join(storageDir, REMOTE_COPILOT_FILE)
    this.load()
  }

  /**
   * What this device may do, which for almost every device is nothing.
   *
   * Returns a grant rather than `null`, and that is the difference from
   * `FolderGrants.granted`. There is no "nobody has chosen yet" state to
   * distinguish here, because the answer to not having chosen is the same as the
   * answer to having chosen nothing: no access. One return type means no caller
   * can forget to handle the absent case, which is the case that matters.
   */
  granted(deviceId: string): TierGrant {
    if (typeof deviceId !== 'string' || deviceId === '') return NO_TIERS
    return this.grants.get(deviceId) ?? NO_TIERS
  }

  /** Every device that has been given something, for the settings panel. */
  list(): DeviceCopilotGrant[] {
    return [...this.grants].map(([deviceId, tiers]) => ({ deviceId, tiers }))
  }

  /**
   * Record what one device may do, replacing whatever was there.
   *
   * Returns what was actually stored, which is not always what was asked for —
   * `alter` is dropped. The caller is a settings panel and it should render the
   * answer rather than its own request, so that a UI cannot show a switch as on
   * when the store says off.
   *
   * Throws if the file cannot be written. A grant the panel believes and the
   * disk does not is a permission that reverts at the next launch, and the only
   * thing worse than that is a permission that reverts *up*.
   */
  set(deviceId: string, tiers: unknown): TierGrant {
    if (typeof deviceId !== 'string' || deviceId === '') return NO_TIERS
    const cleaned = copilotGrantFrom(tiers)

    const next = new Map(this.grants)
    // The ceiling binds only new device ids: a device that already has a row
    // must always be editable, including revocable, however large the file grew.
    if (!next.has(deviceId) && next.size >= MAX_DEVICES) return NO_TIERS

    // Nothing granted is stored as no row at all, so the file holds only real
    // grants and `list()` in the settings panel shows only devices that have
    // something. Absence and all-false are the same state; keeping both would
    // be two spellings of one fact.
    if (grantsNothing(cleaned)) next.delete(deviceId)
    else next.set(deviceId, cleaned)

    this.commit(next)
    return cleaned
  }

  /**
   * Drop a device's access entirely. Called when a device is revoked.
   *
   * Revocation is permanent — the trust store never un-revokes, and a returning
   * phone pairs again and gets a *new* device id — so a row left behind here
   * could never be reached again by anything, and keeping it would mean the file
   * only ever grows. Worse than untidy: a stale row is a grant sitting in a file
   * with nobody's name against it.
   */
  forget(deviceId: string): boolean {
    if (!this.grants.has(deviceId)) return false
    const next = new Map(this.grants)
    next.delete(deviceId)
    this.commit(next)
    return true
  }

  /* ------------------------------------------------------------- internals */

  private commit(next: Map<string, TierGrant>): void {
    const devices: Record<string, Record<string, boolean>> = {}
    for (const [deviceId, tiers] of next) {
      // Only the grantable tiers are serialised. A stored `"alter": false` would
      // read, to somebody opening the file, like a switch that could be turned
      // on. It cannot be, and a file should not imply otherwise.
      const stored: Record<string, boolean> = {}
      for (const tier of REMOTE_GRANTABLE_TIERS) stored[tier] = tiers[tier]
      devices[deviceId] = stored
    }
    const state: StoredState = { version: FORMAT_VERSION, devices }
    writeSecretFile(this.dir, this.file, `${JSON.stringify(state, null, 2)}\n`)
    // Only after the disk agrees. The in-memory map is what every call consults,
    // so swapping it first would leave a grant live for the rest of the run that
    // no longer exists after a restart.
    this.grants = next
  }

  /**
   * Read the file, and treat anything unreadable as no access for anybody.
   *
   * Fails **closed**, which is the opposite of `folder-grants.ts` and is the
   * right way round for the same reason that file gives for its own choice. That
   * one decides which folder a session starts in for a machine its owner has
   * already approved, and failing closed would strand a paired phone over a JSON
   * typo. This one decides whether a phone can drive an agent that spends money
   * and edits files, and the worst case of failing closed is that somebody has
   * to re-tick a box on the desktop — where they already are, because that is
   * the only place the box exists.
   */
  private load(): void {
    let text: string
    try {
      text = readFileSync(this.file, 'utf8')
    } catch {
      // Missing is the normal case, and will stay the normal case: this is a
      // capability nobody has until they go looking for it.
      return
    }

    if (text.length > MAX_FILE_BYTES) {
      console.error('[remote] the copilot grant file is implausibly large; ignoring it')
      return
    }

    let parsed: unknown
    try {
      parsed = JSON.parse(text)
    } catch (error) {
      console.error('[remote] could not read the copilot grants:', error)
      return
    }

    if (!isRecord(parsed) || !isRecord(parsed.devices)) return
    const grants = new Map<string, TierGrant>()
    for (const [deviceId, value] of Object.entries(parsed.devices)) {
      if (deviceId === '' || grants.size >= MAX_DEVICES) continue
      // Re-read through the same rule the writer used rather than trusted. This
      // file can be edited by hand, and `alter: true` typed into it must not
      // become an `alter` grant just because it survived a round trip.
      const grant = copilotGrantFrom(value)
      if (grantsNothing(grant)) continue
      grants.set(deviceId, grant)
    }
    this.grants = grants
  }
}

/**
 * The {@link Caller} a relayed copilot request must be dispatched with.
 *
 * One function, so that the day a transport is written there is a single
 * obvious thing to call and no temptation to assemble a `Caller` by hand with
 * `ALL_TIERS` in it while getting something working. The device id rides along
 * into the action log, which is the only place "which of my phones did that" can
 * be answered from.
 */
export function remoteCopilotCaller(
  grants: Pick<CopilotGrants, 'granted'>,
  deviceId: string,
): { kind: 'remote'; deviceId: string; tiers: TierGrant } {
  return { kind: 'remote', deviceId, tiers: grants.granted(deviceId) }
}
