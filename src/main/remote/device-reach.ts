/**
 * One answer to "what may this device touch", for every door that has to ask.
 *
 * ## Why this is one function and not three checks
 *
 * There were three doors and only one of them was locked.
 *
 *  - **`create`** — enforced. `session-create.ts` refuses a folder that is not on
 *    the device's list, and has done since folder grants landed.
 *  - **`list`** — not enforced. `SessionAccess.list()` takes no device id, so
 *    every paired device was sent every running session on the machine.
 *  - **`attach`** — not enforced either, and this is the one that mattered. A
 *    device could take the id off that list and attach to a session running in a
 *    folder nobody had granted it, then type into it. Starting a *new* shell in
 *    a folder was refused while typing into an *existing* one in the same folder
 *    was not, which is the wrong way round: the existing one is somebody's live
 *    work with an agent already holding it.
 *
 * `session-create.ts` says the quiet part in its own header — *"the device could
 * already attach to a session in that folder and type into it, which is strictly
 * more access than starting a fresh shell there"* — and used that as the
 * argument for why naming a folder grants nothing new. It was true, and it was
 * describing the hole rather than a property: the reason attaching was more
 * access is that nothing checked it.
 *
 * So the rule moves here, one function, and the three doors call it. A rule
 * spread across three files is a rule with three subtly different versions, and
 * the folder allowlist has already been through that once — `folder-grants.ts`
 * exists because the advertised list and the enforced list were computed
 * separately and disagreed.
 *
 * ## The rule
 *
 * **`mine`** reaches everything. No folder list is consulted, `create` accepts
 * any absolute folder, and every session is listed and attachable. That is the
 * whole content of *"it's you at another keyboard"*: a second laptop of your own
 * that could only see two of your six projects would be a worse tool than the
 * ssh it is replacing, and the person approving it made exactly one decision —
 * that this machine is theirs — which is the decision being honoured.
 *
 * **`guest`** reaches the folders that were chosen for it, and nothing else. Not
 * the desktop's open projects, not the folders other sessions happen to be
 * running in, and — when nothing was chosen — nothing at all. A session is
 * visible when its working directory is inside one of those folders, so a guest
 * granted `~/work/site` can see and attach to the two agents already running
 * there and cannot see that there is anything else on the machine.
 *
 * ## Containment, not equality
 *
 * A granted folder covers what is under it. `~/work/site` grants a session whose
 * cwd is `~/work/site/packages/api`, because that session is inside the project
 * the person shared and refusing it would be a distinction nobody asked for —
 * they shared a project, and an agent that `cd`s into a subdirectory has not
 * left it.
 *
 * The **start** rule stays equality, deliberately, and the asymmetry is not an
 * oversight. `create` is answered from a picker: the list it offers is the list
 * it enforces, and a picker that offered `~/work/site` while silently accepting
 * anything beneath it would be a text field pretending to be a menu. Visibility
 * has no picker — it is a question asked about a session that already exists, in
 * a folder nobody is choosing — so the right question there is "is this inside
 * what I shared", which is containment.
 */

import type { FolderGrants } from './folder-grants'
import type { DeviceKind, DeviceKinds } from './device-kind'
import { currentPlatform, type Platform } from '../platform/host'
import { sameFolder, withinFolder } from './session-create'

/**
 * What one device may touch, as one value.
 *
 * `unrestricted` is not "the folder list happens to contain everything" — there
 * is no such list, since the machine's folders are not enumerable — so it is a
 * separate fact rather than a sentinel value in `folders`. The alternative shape,
 * an empty list meaning "everything", is the exact collision `folder-grants.ts`
 * spent a paragraph avoiding: an empty list already means *nothing*, and that is
 * a person's answer rather than a gap.
 */
export interface DeviceReach {
  kind: DeviceKind
  /** True only for `mine`. Every folder check is skipped. */
  unrestricted: boolean
  /**
   * The folders to offer this device, most relevant first.
   *
   * For a guest this is the enforced list. For one of your own it is a list of
   * *suggestions* — the machine's open projects and running sessions — which is
   * what a picker should show first and is not a ceiling on what may be named.
   */
  folders: string[]
}

/**
 * The two stores this reads. Structural rather than the classes themselves, so a
 * test supplies two object literals and the headless host supplies the real
 * pair without either of them having to construct the other's file.
 */
export interface ReachStores {
  kinds: Pick<DeviceKinds, 'kindOf'>
  grants: Pick<FolderGrants, 'granted'>
}

/**
 * What this machine has open, for the suggestions an owner's device is shown.
 *
 * Called lazily, and only on the `mine` path: a guest's answer is its granted
 * list and must never cost a walk of the desktop's projects — and, more to the
 * point, must never be *influenced* by one. The old rule read this list for
 * every device, which is how a phone came to see whatever happened to be open.
 */
export interface HostFolders {
  offered(): readonly string[]
  home(): string
}

export function reachFor(
  stores: ReachStores,
  deviceId: string,
  host: HostFolders,
  platform: Platform = currentPlatform(),
): DeviceReach {
  const kind = stores.kinds.kindOf(deviceId)

  if (kind === 'mine') {
    /*
     * Deduplicated, because `offered` concatenates two sources that overlap.
     *
     * `host-core.ts` builds it as the open projects *plus* the cwd of every
     * running session — and a session almost always runs in a project that is
     * open, so two projects with a session in each offer four entries, two of
     * them repeats. Asad's recording caught exactly that: the browser client's
     * "Start in" list showed `/home/asad/ClaudeImza` and
     * `/home/asad/ClaudeImzacrm`, and then both again.
     *
     * `sameFolder` rather than a Set, so `/a/b` and `/a/b/` are one folder and
     * Windows' case-insensitivity is honoured — the same comparison the
     * enforcement uses, rather than a second idea of what makes two paths the
     * same.
     */
    const list: string[] = []
    for (const path of host.offered()) {
      if (list.some((seen) => sameFolder(seen, path, platform))) continue
      list.push(path)
    }
    // A first launch: nothing open, nothing running, and a device starting a
    // session is at its most useful and least able to name a folder. Only a
    // suggestion — `unrestricted` means any folder is startable anyway.
    return { kind, unrestricted: true, folders: list.length > 0 ? list : [host.home()] }
  }

  /*
   * A guest gets what was chosen, and `null` — nobody chose — is `[]`.
   *
   * This is the line that closes the hole, and it is worth stating what it
   * replaces rather than only what it does. `foldersForDevice` used to read a
   * missing record as "fall back to what this desktop is offering", which meant
   * six digits typed into a phone bought every open project and every folder a
   * session was running in, immediately, with no further act by anybody. The
   * argument for that fallback was compatibility with phones paired before
   * grants existed, and it was a good argument about a preference. It is not an
   * argument about a boundary.
   */
  const chosen = stores.grants.granted(deviceId) ?? []
  return { kind, unrestricted: false, folders: chosen }
}

/**
 * May this device see, attach to, and type into a session in this folder?
 *
 * The one predicate behind `list` and `attach`. `cwd` is the session's working
 * directory as the pty layer reports it, never something off the network.
 */
export function reachesFolder(
  // `Pick` rather than the whole shape: `SessionFanout` is handed the two facts
  // that decide the answer and has no use for the kind, and a parameter that
  // demanded one would make that caller invent a value it does not have.
  reach: Pick<DeviceReach, 'unrestricted' | 'folders'>,
  cwd: string,
  platform: Platform = currentPlatform(),
): boolean {
  if (reach.unrestricted) return true
  return reach.folders.some((folder) => withinFolder(folder, cwd, platform))
}
