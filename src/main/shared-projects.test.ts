import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  readlinkSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { Profile } from './profiles'

/**
 * One history across several accounts, tested against a real filesystem.
 *
 * Mocking `fs` here would test nothing worth knowing. Every claim this module
 * makes is a claim about what a symlink *is* — whether the CLI's `readdir` of
 * `projects/` reaches through it, whether a recursive delete of an account
 * follows it into the user's real history — and those are facts about the
 * operating system rather than about this code. So everything below runs in a
 * temporary directory and looks at what is actually on disk afterwards.
 */

let root: string
let profilesRoot: string
let home: string

vi.mock('./profiles', async () => {
  const actual = await vi.importActual<typeof import('./profiles')>('./profiles')
  return {
    ...actual,
    // Only the two things this module asks `profiles.ts`. The rest of that
    // module reads `userDataDir()`, which would drag Electron in.
    isManagedConfigDir: (dir: string) => dir.startsWith(profilesRoot),
    getState: () => ({ version: 1, profiles: [], defaultProfileId: null, projectDefaults: {}, systemNames: {} }),
    findProfile: () => null,
  }
})

vi.mock('./transcript', async () => {
  const actual = await vi.importActual<typeof import('./transcript')>('./transcript')
  return { ...actual, claudeConfigDir: () => join(home, '.claude') }
})

const account = (id: string): Profile => ({
  id,
  name: id,
  provider: 'claude',
  configDir: join(profilesRoot, id),
  system: false,
  color: '--accent',
  createdAt: 0,
  lastUsedAt: null,
})

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'td-shared-'))
  home = join(root, 'home')
  profilesRoot = join(root, 'userdata', 'profiles')
  mkdirSync(join(home, '.claude', 'projects'), { recursive: true })
  mkdirSync(profilesRoot, { recursive: true })
})

afterEach(() => {
  rmSync(root, { recursive: true, force: true })
  vi.resetModules()
})

async function subject() {
  return await import('./shared-projects')
}

describe('sharing', () => {
  it('links the account into the user’s own history rather than the other way round', async () => {
    const { shareProjects, shareState, sharedProjectsRoot } = await subject()
    const work = account('work')
    mkdirSync(work.configDir, { recursive: true })

    shareProjects(work)

    // The account's folder is the link. The user's own directory is untouched,
    // which is the whole of the first of `ACCOUNT-MODEL.md`'s three rules — his
    // real history must never be restructured to make this work.
    expect(lstatSync(join(work.configDir, 'projects')).isSymbolicLink()).toBe(true)
    expect(lstatSync(sharedProjectsRoot()).isSymbolicLink()).toBe(false)
    expect(shareState(work).link).toBe('shared')
  })

  it('is what the CLI would see: a conversation written by one account is read by the other', async () => {
    const { shareProjects } = await subject()
    const one = account('one')
    const two = account('two')
    mkdirSync(one.configDir, { recursive: true })
    mkdirSync(two.configDir, { recursive: true })
    shareProjects(one)
    shareProjects(two)

    // Written through one account's projects/ …
    const folder = join(one.configDir, 'projects', '-tmp-work')
    mkdirSync(folder, { recursive: true })
    writeFileSync(join(folder, 'abc.jsonl'), '{}\n')

    // … and listed through the other's, which is the only thing that makes a
    // conversation survive a change of account.
    expect(readdirSync(join(two.configDir, 'projects', '-tmp-work'))).toEqual(['abc.jsonl'])
  })

  it('moves the account’s own history in, and refuses to merge a folder both already have', async () => {
    const { shareProjects, sharedProjectsRoot } = await subject()
    const work = account('work')
    const mine = join(work.configDir, 'projects')
    mkdirSync(join(mine, '-tmp-only-mine'), { recursive: true })
    mkdirSync(join(mine, '-tmp-both'), { recursive: true })
    mkdirSync(join(sharedProjectsRoot(), '-tmp-both'), { recursive: true })

    const result = shareProjects(work)

    expect(result.moved).toBe(1)
    expect(result.kept).toBe(1)
    expect(existsSync(join(sharedProjectsRoot(), '-tmp-only-mine'))).toBe(true)
    // Nothing was deleted and nothing was interleaved. A transcript line records
    // nothing about which account wrote it, so merging two histories for one
    // folder is a decision this module has no basis to make — it says where the
    // unmerged half went instead.
    expect(result.keptAt).not.toBeNull()
    expect(existsSync(join(result.keptAt as string, '-tmp-both'))).toBe(true)
  })

  it('refuses an account whose directory the person set up themselves', async () => {
    const { shareProjects } = await subject()
    const adopted: Profile = { ...account('adopted'), configDir: join(root, 'my-own-claude') }
    mkdirSync(adopted.configDir, { recursive: true })
    expect(() => shareProjects(adopted)).toThrow(/only an account this app created its own folder for/i)
  })
})

describe('what a person is told before anything is deleted', () => {
  it('promises no loss for a sharing account, and a recursive delete keeps that promise', async () => {
    const { describeDelete, shareProjects, shareState, sharedProjectsRoot } = await subject()
    const work = account('work')
    mkdirSync(work.configDir, { recursive: true })
    shareProjects(work)
    mkdirSync(join(sharedProjectsRoot(), '-tmp-real'), { recursive: true })
    writeFileSync(join(sharedProjectsRoot(), '-tmp-real', 'abc.jsonl'), '{}\n')

    expect(describeDelete(shareState(work))).toMatch(/no conversations are lost/i)

    // The sentence is only true if a delete really does stop at the link. This
    // is the same call `deleteProfile` makes, run against the real thing rather
    // than reasoned about — the failure it guards is a person losing every
    // conversation on the machine to a button that said they would lose none.
    rmSync(work.configDir, { recursive: true, force: true })
    expect(existsSync(join(sharedProjectsRoot(), '-tmp-real', 'abc.jsonl'))).toBe(true)
  })

  it('counts what an unshared account would actually lose', async () => {
    const { describeDelete, shareState } = await subject()
    const solo = account('solo')
    mkdirSync(join(solo.configDir, 'projects', '-tmp-a'), { recursive: true })
    mkdirSync(join(solo.configDir, 'projects', '-tmp-b'), { recursive: true })
    const said = describeDelete(shareState(solo))
    expect(said).toContain('2 folders')
    expect(said).toMatch(/will be deleted/i)
  })
})

describe('stopping', () => {
  it('gives the account its own empty history back and leaves the shared one alone', async () => {
    const { shareProjects, shareState, sharedProjectsRoot, unshareProjects } = await subject()
    const work = account('work')
    mkdirSync(work.configDir, { recursive: true })
    shareProjects(work)
    mkdirSync(join(sharedProjectsRoot(), '-tmp-keep'), { recursive: true })

    const after = unshareProjects(work)

    expect(after.link).toBe('separate')
    expect(lstatSync(join(work.configDir, 'projects')).isDirectory()).toBe(true)
    expect(readdirSync(join(work.configDir, 'projects'))).toEqual([])
    expect(existsSync(join(sharedProjectsRoot(), '-tmp-keep'))).toBe(true)
    expect(shareState(work).link).toBe('separate')
  })
})

/**
 * The migration, and the reason there has to be one.
 *
 * Option C was built, measured — `ACCOUNT-MODEL.md` has account TWO continuing
 * account ONE's conversation and resuming it by id — and then left switched off
 * behind a control in Settings. So every account that existed before the
 * feature kept its own store, and the switch went on doing exactly what the
 * complaint said:
 *
 *   > *"It's not keeping the conversation history. If I go back, again that
 *   > message."*
 *
 * The shape below is the one taken off his own machine on 2026-08-20:
 * `profiles/imzapremium-gmail-com/projects` was an ordinary directory with
 * seven project folders in it, five of which the user's own `~/.claude` also
 * had. That is the case these tests are about.
 */
describe('bringing existing accounts onto the shared history', () => {
  it('links an account whose projects folder is an ordinary directory', async () => {
    const { adoptSharedHistory, readsSharedHistory, shareState } = await subject()
    const old = account('imzapremium-gmail-com')
    mkdirSync(join(old.configDir, 'projects', '-Users-apple-bin'), { recursive: true })
    expect(shareState(old).link).toBe('separate')
    expect(readsSharedHistory(old)).toBe(false)

    const result = adoptSharedHistory([old])

    expect(result.joined).toEqual([old.id])
    expect(readsSharedHistory(old)).toBe(true)
  })

  /*
   * The measured result from `ACCOUNT-MODEL.md`, reproduced through the
   * migration rather than through the Settings button — because the button is
   * what nobody pressed. A conversation written by the account he was on has to
   * be visible to the account he switches to, or the switch is the bug again.
   */
  it('makes the conversation on screen visible to the account he switches to', async () => {
    const { adoptSharedHistory, sharedProjectsRoot } = await subject()
    const mine = account('imzapremium-gmail-com')
    mkdirSync(mine.configDir, { recursive: true })

    // His own install writes the conversation he is looking at.
    const folder = join(sharedProjectsRoot(), '-Users-apple-Projects-terminaldeck')
    mkdirSync(folder, { recursive: true })
    writeFileSync(join(folder, 'dbebd1aa.jsonl'), '{"type":"user"}\n')

    adoptSharedHistory([mine])

    // And the other account can now read it, which is the whole of what
    // `--continue` needs: it scans `projects/` rather than reading a remembered
    // session id.
    const seen = join(mine.configDir, 'projects', '-Users-apple-Projects-terminaldeck')
    expect(readdirSync(seen)).toEqual(['dbebd1aa.jsonl'])
  })

  it('never rewrites the history the user already had', async () => {
    const { adoptSharedHistory, sharedProjectsRoot } = await subject()
    const old = account('work')
    // The overlap his own machine has: a folder both stores know about. The
    // shared copy is the one that must survive untouched.
    mkdirSync(join(sharedProjectsRoot(), '-tmp-both'), { recursive: true })
    writeFileSync(join(sharedProjectsRoot(), '-tmp-both', 'ours.jsonl'), 'mine\n')
    mkdirSync(join(old.configDir, 'projects', '-tmp-both'), { recursive: true })
    writeFileSync(join(old.configDir, 'projects', '-tmp-both', 'theirs.jsonl'), 'theirs\n')
    mkdirSync(join(old.configDir, 'projects', '-tmp-only-theirs'), { recursive: true })

    adoptSharedHistory([old])

    expect(readFileSync(join(sharedProjectsRoot(), '-tmp-both', 'ours.jsonl'), 'utf8')).toBe('mine\n')
    expect(existsSync(join(sharedProjectsRoot(), '-tmp-both', 'theirs.jsonl'))).toBe(false)
    // The half that could not be merged is set aside, never deleted.
    expect(existsSync(join(sharedProjectsRoot(), '-tmp-only-theirs'))).toBe(true)
    const aside = readdirSync(old.configDir).find((entry) => entry.startsWith('projects.not-merged-'))
    expect(aside).toBeDefined()
    expect(readdirSync(join(old.configDir, aside as string))).toEqual(['-tmp-both'])
  })

  it('leaves alone every account it has no business restructuring', async () => {
    const { adoptSharedHistory, canJoinSharedHistory } = await subject()
    // A directory the person pointed the account at themselves.
    const adopted: Profile = { ...account('adopted'), configDir: join(root, 'my-own-claude') }
    mkdirSync(join(adopted.configDir, 'projects'), { recursive: true })
    // Another agent, whose conversations are not in this shape at all.
    const codex: Profile = { ...account('codex'), provider: 'codex' }
    mkdirSync(codex.configDir, { recursive: true })
    // And a link somebody made for themselves, pointing somewhere else.
    const elsewhere = account('elsewhere')
    mkdirSync(elsewhere.configDir, { recursive: true })
    mkdirSync(join(root, 'somewhere-else'), { recursive: true })
    symlinkSync(join(root, 'somewhere-else'), join(elsewhere.configDir, 'projects'), 'dir')

    for (const profile of [adopted, codex, elsewhere]) {
      expect(canJoinSharedHistory(profile), profile.id).toBe(false)
    }
    const result = adoptSharedHistory([adopted, codex, elsewhere])
    expect(result.joined).toEqual([])
    expect(result.left.sort()).toEqual(['adopted', 'codex', 'elsewhere'])
    expect(result.failed).toEqual([])
    // The link somebody made is still theirs.
    expect(readlinkSync(join(elsewhere.configDir, 'projects'))).toBe(join(root, 'somewhere-else'))
  })

  /*
   * The user's own install *is* the shared history, so it reads it by being it
   * — and `shareState` answers `unmanaged` about it, which is correct about the
   * link and the wrong answer to this question. Getting that wrong would leave
   * a switch between his own login and a managed account reporting two separate
   * stores forever, which is the original bug wearing the fix's clothes.
   */
  it('counts an agent’s own install as already reading the shared history', async () => {
    const { adoptSharedHistory, canJoinSharedHistory, readsSharedHistory } = await subject()
    const own: Profile = {
      ...account('system-claude'),
      configDir: join(home, '.claude'),
      system: true,
    }
    expect(readsSharedHistory(own)).toBe(true)
    expect(canJoinSharedHistory(own)).toBe(true)
    expect(adoptSharedHistory([own]).already).toEqual(['system-claude'])
  })

  it('is idempotent, because it runs on every launch', async () => {
    const { adoptSharedHistory, readsSharedHistory } = await subject()
    const work = account('work')
    mkdirSync(join(work.configDir, 'projects'), { recursive: true })

    expect(adoptSharedHistory([work]).joined).toEqual(['work'])
    expect(adoptSharedHistory([work]).joined).toEqual([])
    expect(adoptSharedHistory([work]).already).toEqual(['work'])
    expect(readsSharedHistory(work)).toBe(true)
  })

  it('never throws, because it runs before there is anywhere to report to', async () => {
    const { adoptSharedHistory } = await subject()
    const broken = account('broken')
    // A file where the config directory should be: every fs call under it
    // fails, which is as close to a hostile disk as a test can honestly get.
    writeFileSync(broken.configDir, 'not a directory\n')

    const result = adoptSharedHistory([broken])
    expect(result.joined).toEqual([])
    expect(result.left.concat(result.failed.map((entry) => entry.id))).toEqual(['broken'])
  })
})

/** Seed the user's own history with the folders his machine really has. */
function seedOwnHistory(folders: readonly string[]): void {
  for (const folder of folders) {
    const dir = join(home, '.claude', 'projects', folder)
    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, 'own.jsonl'), '{"type":"user"}\n')
  }
}

/**
 * His machine's actual account layout, as measured on 2026-08-20, walked
 * through the migration.
 *
 * The directory names below are the real ones, read off
 * `~/Library/Application Support/terminaldeck/profiles/` and `~/.claude/projects`.
 * Five of the seven folders his second account holds are folders his own
 * install also has, which is the case the merge has to refuse — and it is why
 * this is a test rather than a paragraph: the interesting half of the answer is
 * what happens to those five.
 */

/** What his `profiles/imzapremium-gmail-com/projects` actually holds. */
const HIS_ACCOUNT_FOLDERS = [
  '-private-tmp-deck-switch-demo',
  '-private-tmp-td-acct-model-work',
  '-private-tmp-td-switch-evidence',
  '-private-var-folders-7j-copilot-probe-copilot',
  '-Users-apple--claude-jobs-5ccc1804-tmp-deck-demo',
  '-Users-apple--claude-jobs-5ccc1804-tmp-deck-solo',
  '-Users-apple-bin',
]

/** The five of those his own `~/.claude/projects` also has, plus one it alone has. */
const HIS_OWN_FOLDERS = [
  '-private-tmp-deck-switch-demo',
  '-private-tmp-td-acct-model-work',
  '-private-tmp-td-switch-evidence',
  '-Users-apple--claude-jobs-5ccc1804-tmp-deck-demo',
  '-Users-apple--claude-jobs-5ccc1804-tmp-deck-solo',
  '-Users-apple-Projects-terminaldeck',
]

describe('his three accounts, as they are on disk', () => {
  it('joins the Claude one, leaves the Codex one, and loses nothing', async () => {
    const { adoptSharedHistory, readsSharedHistory, sharedProjectsRoot } = await subject()
    seedOwnHistory(HIS_OWN_FOLDERS)

    // `imzapremium@gmail.com` — provider claude, a real projects directory.
    const imza = account('imzapremium-gmail-com')
    for (const folder of HIS_ACCOUNT_FOLDERS) {
      const dir = join(imza.configDir, 'projects', folder)
      mkdirSync(dir, { recursive: true })
      writeFileSync(join(dir, 'theirs.jsonl'), '{"type":"user"}\n')
    }
    // `asadiqbalonline@gmail.com` — provider codex, whose history is not in
    // this shape at all.
    const codex: Profile = { ...account('asadiqbalonline-gmail-com-2'), provider: 'codex' }
    mkdirSync(codex.configDir, { recursive: true })
    // And his own install, which is the shared history rather than a link to it.
    const own: Profile = { ...account('system-claude'), configDir: join(home, '.claude'), system: true }

    const result = adoptSharedHistory([imza, codex, own])

    expect(result.joined).toEqual(['imzapremium-gmail-com'])
    expect(result.left).toEqual(['asadiqbalonline-gmail-com-2'])
    expect(result.already).toEqual(['system-claude'])
    expect(result.failed).toEqual([])

    // The switch he actually makes now sees one store on both sides.
    expect(readsSharedHistory(imza)).toBe(true)
    expect(readsSharedHistory(own)).toBe(true)

    // His own history is intact, to the file.
    for (const folder of HIS_OWN_FOLDERS) {
      expect(existsSync(join(sharedProjectsRoot(), folder, 'own.jsonl')), folder).toBe(true)
    }
    // The two folders only that account had came across.
    expect(existsSync(join(sharedProjectsRoot(), '-Users-apple-bin', 'theirs.jsonl'))).toBe(true)
    expect(
      existsSync(join(sharedProjectsRoot(), '-private-var-folders-7j-copilot-probe-copilot', 'theirs.jsonl')),
    ).toBe(true)
    // The five that collided were not merged and were not deleted: they are
    // set aside under a name that says what they are. Nothing in a transcript
    // line records which account wrote it, so interleaving two histories for
    // one folder is a decision nothing here has a basis to make.
    const aside = readdirSync(imza.configDir).find((entry) => entry.startsWith('projects.not-merged-'))
    expect(aside).toBeDefined()
    expect(readdirSync(join(imza.configDir, aside as string)).sort()).toEqual(
      HIS_ACCOUNT_FOLDERS.filter((folder) => HIS_OWN_FOLDERS.includes(folder)).sort(),
    )

    // And the account's projects/ is a link, so deleting the account later
    // takes the link and not his history.
    expect(lstatSync(join(imza.configDir, 'projects')).isSymbolicLink()).toBe(true)
  })

  it('the folder he was working in becomes readable from the other account', async () => {
    const { adoptSharedHistory } = await subject()
    seedOwnHistory(HIS_OWN_FOLDERS)
    const imza = account('imzapremium-gmail-com')
    mkdirSync(imza.configDir, { recursive: true })

    adoptSharedHistory([imza])

    // `--continue` scans `projects/` for the encoded cwd; this is that lookup,
    // done from the account he is switching *to*, against a conversation his
    // own login wrote.
    const seen = join(imza.configDir, 'projects', '-Users-apple-Projects-terminaldeck')
    expect(readdirSync(seen)).toEqual(['own.jsonl'])
  })
})
