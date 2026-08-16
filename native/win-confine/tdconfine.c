/*
 * tdconfine.exe — the one thing on Windows that Node cannot do for itself.
 *
 * ## Why an .exe exists in a repository that is otherwise TypeScript
 *
 * On macOS a confined session is `sandbox-exec -p <profile> <command>`: a
 * program that already exists, taking the boundary as an argument. Linux is
 * `unshare` and `setpriv`, same shape. Windows has no such program. The only
 * mechanism on Windows that actually holds — measured, not read; see
 * `CONFINEMENT.md` — is an **AppContainer**, and an AppContainer is not
 * something a process enters. It is something a process is *created inside*:
 * the container SID travels in an attribute on the `CreateProcess` call itself,
 * through `UpdateProcThreadAttribute(PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES)`.
 *
 * Node cannot make that call. Neither can `node-pty`: its Windows backend is
 * ConPTY, and it builds its own attribute list with the pseudoconsole in it and
 * offers no seam to add a second attribute. There is no PowerShell cmdlet
 * either — `Get-Command *AppContainer*` returns nothing on Windows 11 26200. So
 * the choice was a native addon or a launcher, and this is the launcher: a
 * program whose whole job is to be the thing that calls `CreateProcess`,
 * because the caller is the only one who can apply the boundary.
 *
 * It is deliberately the smallest program that can do that. It is
 * security-critical code in a language with no seatbelt, it runs before the
 * session the user is about to type into, and every line in it is a line that
 * can be wrong in a way nobody sees. There is no logging framework, no
 * configuration file, no library, and no allocation that is not bounded.
 *
 * ## What it does, in order
 *
 *   1. Turns a container **name** into a container **SID**. Deterministic:
 *      `DeriveAppContainerSidFromAppContainerName` answers the same SID before
 *      the profile exists and after it has been deleted, which is what lets the
 *      grant and the revoke be separate acts.
 *   2. Creates the profile if it is not there. Idempotent; an existing profile
 *      answers `HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS)` and that is success.
 *   3. Adds one ACE per granted path for that SID, and **only** adds — the
 *      existing ACEs on the folder are read, the new one is merged in, and the
 *      result is written back with `DACL_SECURITY_INFORMATION` alone, so the
 *      "inheritance is blocked here" bit on the folder is not touched. That is
 *      not a stylistic preference over `icacls`: an `icacls` sweep during the
 *      measurement re-enabled inheritance on `C:\Program Files\nodejs` and had
 *      to be repaired by hand against a recorded copy of the original.
 *   4. Creates a window station and a desktop **of its own** for the container
 *      and grants those, rather than granting the interactive ones. See the
 *      comment on {@link makeStation} — this is the part where the obvious
 *      implementation quietly hands a confined process the user's desktop.
 *   5. Creates the process with the container attribute, inheriting whatever
 *      console or pipes this launcher was given, so ConPTY keeps working.
 *   6. Puts the child in a job that ends with this process. It is created
 *      suspended and resumed once it is in — see the comment at that call for
 *      why a job is here at all, and why it is not part of the boundary.
 *   7. Waits, and exits with the child's exit code.
 *   8. Removes every ACE it added, on every path, on every exit route it
 *      controls.
 *
 * ## What it does not do, so that nobody reads a claim into it
 *
 * It does not confine WSL. `wsl.exe` is refused outright inside an AppContainer
 * — measured, with the window station already granted — so a session whose
 * folder is a Linux path cannot be covered by this program at all and must be
 * confined on the Linux side by the namespace mechanism. A caller that hands
 * this launcher a `wsl.exe` command line is making a mistake this program
 * cannot detect.
 *
 * It does not decide policy. Which directories are writable, which are readable
 * and which ancestors get an ancestor ACE is the plan's business, computed in
 * TypeScript and passed in. This program has no defaults and no fallbacks: a
 * flag it does not understand is a refusal, not a warning.
 *
 * It never falls back. Every failure below refuses to start the child. A
 * launcher that ran the shell unconfined because a grant failed would be the
 * exact shape of bug this project has been bitten by before — the side that
 * reports success not being the side that had to do the work.
 */

#define WIN32_LEAN_AND_MEAN
#define _CRT_SECURE_NO_WARNINGS

#include <windows.h>
#include <aclapi.h>
#include <sddl.h>
#include <strsafe.h>
#include <stdio.h>

/*
 * `PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES`, spelled out rather than
 * included.
 *
 * The constant is `ProcThreadAttributeValue(ProcThreadAttributeSecurityCapabilities = 9,
 * Thread = FALSE, Input = TRUE, Additive = FALSE)`, which the SDK expands to
 * `9 | PROC_THREAD_ATTRIBUTE_INPUT (0x00020000)` = `0x00020009`. It is written
 * as the literal because the enum member and the macro live in different
 * headers on different toolchains, and this file is compiled by two of them:
 * MSVC in CI, and mingw-w64 on the Linux side of the machine it was measured
 * on. A missing macro would be a build break, which is loud; a wrong literal
 * would be a process that starts unconfined, which is not. The `#ifndef` means
 * that wherever the SDK does define it, the SDK wins.
 */
#ifndef PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES
#define PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES 0x00020009
#endif

/*
 * The two `userenv.dll` entry points, resolved at run time.
 *
 * Not because they might be missing — they have been in `userenv.dll` since
 * Windows 8 and this app requires Windows 10 — but because their *declarations*
 * are not reliably present. mingw-w64 11 does not declare
 * `CreateAppContainerProfile` at all, and linking `userenv.lib` for two symbols
 * is one more thing that has to be true in two toolchains. Resolving them here
 * makes the import table of this binary `kernel32`, `advapi32` and `user32` and
 * nothing else, which is the same list on both compilers.
 */
typedef HRESULT(WINAPI *fnCreateAppContainerProfile)(PCWSTR, PCWSTR, PCWSTR,
                                                     PSID_AND_ATTRIBUTES, DWORD, PSID *);
typedef HRESULT(WINAPI *fnDeriveAppContainerSid)(PCWSTR, PSID *);

/* ------------------------------------------------------------------ exits -- */

/*
 * Exit codes this program produces itself.
 *
 * They start at 120 because a child's own exit code is passed through
 * untouched and the low numbers belong to it. They are not what a caller should
 * key on — every one of them is accompanied by a line on stderr beginning
 * `tdconfine:`, and that line is what the TypeScript side reads, because a
 * shell can also exit 121. They exist so that a human staring at a dead tab has
 * something to grep for.
 */
#define EXIT_USAGE 120
#define EXIT_CONTAINER 121
#define EXIT_ACL 122
#define EXIT_STATION 123
#define EXIT_SPAWN 124

/*
 * How many paths one plan may carry.
 *
 * A fixed array rather than a growing one. The plans this program is given come
 * from `confine/plan.ts`, which collapses them; the largest measured had eleven
 * entries. Sixty-four is far past any real plan and turns every allocation
 * question in this file into a bounds check, which is the trade this program
 * wants — a plan that overflows is refused loudly, and refusing to start is
 * this program's answer to everything anyway.
 */
#define MAX_PATHS 64

/*
 * How many capability SIDs one token may carry.
 *
 * Two are named (`internet-client`, `private-network`) and the rest are the
 * tool capability the one-time grant writes onto the tool directories. Four is
 * far past what any caller sends and keeps the array a fixed size, for the same
 * reason `MAX_PATHS` is one.
 */
#define MAX_CAPABILITIES 4

typedef enum {
  GRANT_WRITE,   /* the granted folder, the device's home: read, write, delete  */
  GRANT_READ,    /* a directory of tools: read and execute, inherited downwards */
  GRANT_FILE,    /* one file, read and execute, and nothing around it           */
  GRANT_ANCESTOR /* on the path to the folder: pass through and list, not read  */
} GrantKind;

typedef struct {
  LPWSTR path;
  GrantKind kind;
} Grant;

/* --------------------------------------------------------------- printing -- */

static void fail(const wchar_t *what, unsigned long code) {
  fwprintf(stderr, L"tdconfine: %ls (0x%08lX)\n", what, code);
  fflush(stderr);
}

/* ----------------------------------------------------------- capabilities -- */

/*
 * Is this SID a capability, and nothing else?
 *
 * This is a security check rather than input validation, and the difference
 * matters enough to spell out. Every SID in `SECURITY_CAPABILITIES.Capabilities`
 * lands in the child's token as an enabled group, and an access check against an
 * AppContainer token grants on any of them. So a caller who could pass
 * `--capability-sid S-1-5-32-544` would hand the confined session every ACE on
 * the machine that names the Administrators group — the boundary would still be
 * an AppContainer, and it would be an AppContainer that can read the disk.
 *
 * A capability SID is `S-1-15-3-…`: identifier authority 15
 * (`SECURITY_APP_PACKAGE_AUTHORITY`) and first sub-authority 3
 * (`SECURITY_CAPABILITY_BASE_RID`). Anything else is refused, and refused rather
 * than dropped, because a caller that believed it had asked for something and
 * got a session without it is the failure shape this program exists to avoid.
 */
static BOOL isCapabilitySid(PSID sid) {
  SID_IDENTIFIER_AUTHORITY app = {{0, 0, 0, 0, 0, 15}};
  PSID_IDENTIFIER_AUTHORITY authority;
  PUCHAR count;

  if (sid == NULL || !IsValidSid(sid)) return FALSE;
  authority = GetSidIdentifierAuthority(sid);
  if (memcmp(authority, &app, sizeof(app)) != 0) return FALSE;
  count = GetSidSubAuthorityCount(sid);
  if (count == NULL || *count < 1) return FALSE;
  return *GetSidSubAuthority(sid, 0) == 3;
}

/* ------------------------------------------------------------------- ACLs -- */

/*
 * The rights each kind of grant carries, and why each one is the size it is.
 *
 * `GRANT_WRITE` is `icacls`'s "M" (Modify) and deliberately not "F": Full
 * Control includes `WRITE_DAC` and `WRITE_OWNER`, which would let the confined
 * process rewrite the very ACL that is holding it — a boundary that can edit
 * itself is not a boundary. `DELETE` is in the set because a session that
 * cannot delete a file in its own folder cannot run `git checkout`.
 *
 * `GRANT_READ` and `GRANT_FILE` are "RX". Execute matters: without it a granted
 * tool directory is a directory of files the session can read and cannot run.
 *
 * `GRANT_ANCESTOR` is the one that costs something, and the cost was measured
 * rather than assumed, so it is written down here in full.
 *
 * An ancestor of the granted folder is `C:\`, `C:\Users`, `C:\Users\<user>`
 * and each directory below that down to the folder itself. The container needs
 * *something* on them, and the first version of this mask was the narrow thing
 * anyone would reach for — `FILE_TRAVERSE | FILE_READ_ATTRIBUTES`, pass through
 * but do not list. With that, a shell works, `node` works, the agent CLI works,
 * `cd ..` shows nothing and the owner's files are refused. **`git` does not.**
 * Every git command dies at `fatal: unable to get current working directory:
 * Permission denied`, and a boundary that breaks git is a boundary nobody keeps
 * switched on.
 *
 * The reason is exact. git-for-windows resolves its own working directory with
 * `GetLongPathNameW`, which walks the path component by component with
 * `FindFirstFileW` — enumeration, not traversal, so `FILE_LIST_DIRECTORY` on
 * every ancestor is what it wants. Its fallback for exactly this case,
 * `CreateFileW(cwd) + GetFinalPathNameByHandleW`, opens the folder fine and
 * then fails too: `VOLUME_NAME_DOS` has to map `\Device\HarddiskVolume3` back
 * to `C:`, and an AppContainer cannot enumerate the DOS device namespace to do
 * it. That is not a file permission and no ACL fixes it — measured with a probe
 * run inside the container, where `VOLUME_NAME_NT` answered and
 * `VOLUME_NAME_DOS` returned `ERROR_ACCESS_DENIED`.
 *
 * So the choice was: git works and the ancestors are listable, or the ancestors
 * are not listable and git does not work. `FILE_LIST_DIRECTORY` is in the mask,
 * and **this is the one place a Windows session is weaker than a macOS one**: a
 * confined Windows session can see the *names* of the entries in each ancestor
 * — the way `dir` shows them, so also their sizes and dates — including the
 * owner's home directory. It cannot open any of them. `CONFINEMENT.md` says so,
 * and the grant screen says it in the user's words, because it is a real
 * difference and not a footnote.
 *
 * `READ_CONTROL` lets a tool read the ACL it is being refused by, which is how
 * an `access()`-shaped check answers without an exception. What stays absent is
 * every write bit and `FILE_GENERIC_READ`: an ancestor is listable and is not
 * readable, and the ACE does not inherit, so nothing *inside* an ancestor is
 * reachable through it.
 */
static DWORD rightsFor(GrantKind kind) {
  switch (kind) {
    case GRANT_WRITE:
      return FILE_GENERIC_READ | FILE_GENERIC_WRITE | FILE_GENERIC_EXECUTE | DELETE;
    case GRANT_READ:
    case GRANT_FILE:
      return FILE_GENERIC_READ | FILE_GENERIC_EXECUTE;
    case GRANT_ANCESTOR:
    default:
      return FILE_TRAVERSE | FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY | READ_CONTROL |
             SYNCHRONIZE;
  }
}

/*
 * Whether the ACE propagates into what is inside the object.
 *
 * A directory the session works in wants `(OI)(CI)` — every file and folder
 * created under it inherits the grant, or the first file the session writes is
 * a file it cannot read back. An ancestor wants `NO_INHERITANCE`, and that is
 * the whole point of the traverse kind: an inheriting ACE on `C:\Users\Imza`
 * would grant the container everything under it, which is precisely what the
 * boundary exists to prevent — it is the difference between "you may walk
 * through my home directory" and "you may read my home directory". A single
 * file has nothing to inherit.
 */
static DWORD inheritanceFor(GrantKind kind) {
  if (kind == GRANT_WRITE || kind == GRANT_READ) {
    return OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE;
  }
  return NO_INHERITANCE;
}

/*
 * Add or remove one ACE on one path's DACL, leaving every other bit of its
 * security descriptor alone.
 *
 * `GetNamedSecurityInfoW` → `SetEntriesInAclW` → `SetNamedSecurityInfoW` is the
 * additive path. `SetEntriesInAclW` copies the existing ACL and merges the new
 * entry, so the ACEs that were there stay there in their original order, and
 * `SetNamedSecurityInfoW` is called with `DACL_SECURITY_INFORMATION` **only** —
 * not `PROTECTED_DACL_SECURITY_INFORMATION` or its opposite — so whether the
 * folder blocks inherited permissions is left exactly as it was found.
 *
 * `mode == REVOKE_ACCESS` runs the same three calls to take the ACE away again.
 * Revoke removes every ACE for the trustee rather than subtracting rights,
 * which is correct here and only here: the trustee is a container SID derived
 * from a name this program was given, so the only ACEs for it on this path are
 * the ones this program put there.
 */
/*
 * The ACE this run wants on this path, merged into whatever is already there.
 *
 * Split out so that the two write APIs below share one definition of what is
 * being written. `BuildTrusteeWithSidW` rather than assigning the SID into
 * `ptstrName`: the documented way to name a trustee by SID is to store a `PSID`
 * in a field declared `LPWSTR`, and writing that assignment would put a pointer
 * cast in the middle of security-critical code where a reader has to squint at
 * it. This helper does the same thing with the types the API should have had.
 */
static DWORD mergeAce(PACL current, PSID sid, GrantKind kind, ACCESS_MODE mode,
                      PACL *updated) {
  EXPLICIT_ACCESS_W entry;
  ZeroMemory(&entry, sizeof(entry));
  entry.grfAccessPermissions = rightsFor(kind);
  entry.grfAccessMode = mode;
  entry.grfInheritance = inheritanceFor(kind);
  BuildTrusteeWithSidW(&entry.Trustee, sid);
  return SetEntriesInAclW(1, &entry, current, updated);
}

/*
 * The inheritable case: `SetNamedSecurityInfoW`, and it walks the tree.
 *
 * Used for the granted folder, the device's home and any tool directory —
 * everything whose ACE carries `(OI)(CI)`. The walk is not a side effect to be
 * avoided; it is the point. NTFS materialises inherited ACEs on each child, so
 * an inheritable ACE placed on a folder reaches the files that already exist
 * only because this call goes and writes it on them. Without it the session
 * could create new files in its folder and could not open the ones that were
 * there when it started.
 *
 * The cost is real and worth stating: it is O(files under the folder), and it
 * happens at session start. A project with a large `node_modules` pays for it
 * once per session.
 */
static DWORD editPathInheritable(LPWSTR path, PSID sid, GrantKind kind, ACCESS_MODE mode) {
  PACL current = NULL;
  PACL updated = NULL;
  PSECURITY_DESCRIPTOR descriptor = NULL;
  DWORD rc;

  rc = GetNamedSecurityInfoW(path, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, NULL, NULL,
                             &current, NULL, &descriptor);
  if (rc != ERROR_SUCCESS) return rc;

  rc = mergeAce(current, sid, kind, mode, &updated);
  if (rc == ERROR_SUCCESS) {
    rc = SetNamedSecurityInfoW(path, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, NULL, NULL,
                               updated, NULL);
  }

  if (updated != NULL) LocalFree(updated);
  if (descriptor != NULL) LocalFree(descriptor);
  return rc;
}

/*
 * The ancestor case: `SetFileSecurityW`, and it walks nothing.
 *
 * This exists because of a measurement that would otherwise have shipped as a
 * hang. `C:\Users\Imza\tdwin\granted` cannot be resolved to a real path by
 * `git` or by `fs.realpathSync` without the container being able to stat its
 * ancestors — including the volume root — so the plan carries a
 * `GRANT_ANCESTOR` entry for each of them. Writing those with
 * `SetNamedSecurityInfoW` re-runs the auto-inheritance algorithm over
 * everything underneath, and on `C:\` that is the whole disk: the first
 * version of this program spent **fifteen minutes at a hundred percent of one
 * core** granting and revoking three ancestors, and had to be killed, which
 * left its ACEs on the user's home directory. Nothing about the boundary was
 * wrong. The API was.
 *
 * `SetFileSecurityW` is the older, blunter call that writes the DACL and stops.
 * It is exactly right here and would be exactly wrong above, and the difference
 * is the same fact from both sides: an ancestor ACE is `NO_INHERITANCE`, so
 * there is nothing under the folder that needs to hear about it.
 *
 * The two control bits are carried across by hand because `SetFileSecurityW`
 * takes the descriptor literally. `SE_DACL_AUTO_INHERITED` is what tells
 * Windows this folder's DACL is maintained by inheritance, and
 * `SE_DACL_PROTECTED` is the "block inherited permissions" checkbox. A
 * descriptor built from scratch has neither, and writing one to `C:\Users`
 * would silently change how that directory inherits from then on — a change to
 * the user's machine that has nothing to do with confining a session, and one
 * nobody would connect to this program a month later.
 */
static DWORD editPathDirect(LPWSTR path, PSID sid, GrantKind kind, ACCESS_MODE mode) {
  const SECURITY_DESCRIPTOR_CONTROL carried = SE_DACL_AUTO_INHERITED | SE_DACL_PROTECTED;
  PSECURITY_DESCRIPTOR existing = NULL;
  SECURITY_DESCRIPTOR fresh;
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  PACL current = NULL;
  PACL updated = NULL;
  BOOL present = FALSE;
  BOOL defaulted = FALSE;
  DWORD needed = 0;
  DWORD rc;

  GetFileSecurityW(path, DACL_SECURITY_INFORMATION, NULL, 0, &needed);
  if (needed == 0) return GetLastError();

  existing = LocalAlloc(LPTR, needed);
  if (existing == NULL) return ERROR_NOT_ENOUGH_MEMORY;

  if (!GetFileSecurityW(path, DACL_SECURITY_INFORMATION, existing, needed, &needed) ||
      !GetSecurityDescriptorControl(existing, &control, &revision) ||
      !GetSecurityDescriptorDacl(existing, &present, &current, &defaulted)) {
    rc = GetLastError();
    LocalFree(existing);
    return rc;
  }

  rc = mergeAce(present ? current : NULL, sid, kind, mode, &updated);
  if (rc != ERROR_SUCCESS) {
    LocalFree(existing);
    return rc;
  }

  if (!InitializeSecurityDescriptor(&fresh, SECURITY_DESCRIPTOR_REVISION) ||
      !SetSecurityDescriptorDacl(&fresh, TRUE, updated, defaulted) ||
      !SetSecurityDescriptorControl(&fresh, carried, control & carried) ||
      !SetFileSecurityW(path, DACL_SECURITY_INFORMATION, &fresh)) {
    rc = GetLastError();
  }

  LocalFree(updated);
  LocalFree(existing);
  return rc;
}

/*
 * Which of the two, decided by the ACE rather than by the caller.
 *
 * The rule is one line and it is the whole of the policy: an ACE that children
 * inherit has to be propagated to the children that already exist; an ACE that
 * children do not inherit must not be, because propagating it means rewriting
 * security descriptors on files that this session has nothing to do with.
 */
static DWORD editPath(LPWSTR path, PSID sid, GrantKind kind, ACCESS_MODE mode) {
  if (inheritanceFor(kind) == NO_INHERITANCE) return editPathDirect(path, sid, kind, mode);
  return editPathInheritable(path, sid, kind, mode);
}

/*
 * Take back every ACE this run added.
 *
 * Best effort by design, and it runs on every exit route this program controls
 * — a failed grant halfway down the list is unwound before the refusal is
 * printed, so a session that could not start does not leave the user's folders
 * carrying a permission for a container that is not running.
 *
 * What it cannot cover is being killed outright. `TerminateProcess` on this
 * launcher leaves the ACEs behind: an unresolvable SID on a folder, granting
 * access to nothing that is running, but litter on somebody's own directory all
 * the same. That is why the container name is per device rather than per
 * session, and why `--release` exists — so the next session for that device
 * reuses the same SID rather than adding a second one, and so the app can sweep
 * without having to remember what a dead process was doing.
 */
static void revokeAll(const Grant *grants, int count, PSID sid) {
  int i;
  for (i = 0; i < count; i++) {
    DWORD rc = editPath(grants[i].path, sid, grants[i].kind, REVOKE_ACCESS);
    if (rc != ERROR_SUCCESS) fail(L"could not remove a permission it had added", rc);
  }
}

/* ------------------------------------------------- window station, desktop -- */

/*
 * A window station and a desktop that belong to nobody else.
 *
 * This is the part of the Windows boundary that is easiest to get wrong
 * quietly, so it is worth stating what the wrong version looks like. Every
 * Win32 process connects to a window station and a desktop as `user32.dll`
 * initialises, and an AppContainer has access to neither of the interactive
 * ones. Without a grant almost nothing starts: `mode.com`, `where.exe`,
 * `timeout.exe`, `whoami.exe` and `tasklist.exe` all died with `0xC0000142` —
 * `STATUS_DLL_INIT_FAILED` — until the window station and desktop were
 * reachable. The obvious fix is to add the container SID to `WinSta0` and
 * `Default`. It works, and it hands the confined session the interactive
 * desktop: the surface every UI-automation escape on Windows has ever started
 * from.
 *
 * So the obvious fix is not what this does. It creates a **new** window station
 * and a **new** desktop, grants those to the container, and starts the child on
 * them by name. The interactive station is never modified — the ACL on
 * `WinSta0` after a confined session is what it was before, because this
 * program never touched it. The confined process has a desktop; it is a desktop
 * with nothing on it, on a station with no clipboard the user is using and no
 * windows the user owns.
 *
 * The handles are held for the lifetime of this process on purpose. A window
 * station and a desktop are destroyed when the last handle to them closes, so
 * holding them is what keeps the child's desktop alive, and closing them at
 * exit is what stops the machine accumulating one per session.
 *
 * `SetProcessWindowStation` is called twice: a desktop is created *in the
 * calling process's current station*, so the only way to create one in the new
 * station is to stand in it briefly. The original is restored immediately —
 * leaving this process on the new station would detach it from the console it
 * is about to hand the child.
 */
typedef struct {
  HWINSTA station;
  HDESK desktop;
  WCHAR name[128]; /* "<station>\\Default", for STARTUPINFO.lpDesktop */
} Station;

static DWORD editUserObject(HANDLE object, PSID sid, DWORD rights, DWORD inheritance,
                            const wchar_t *what) {
  SECURITY_INFORMATION info = DACL_SECURITY_INFORMATION;
  SECURITY_DESCRIPTOR fresh;
  PSECURITY_DESCRIPTOR existing = NULL;
  PACL current = NULL;
  PACL updated = NULL;
  EXPLICIT_ACCESS_W entry;
  DWORD needed = 0;
  BOOL present = FALSE;
  BOOL defaulted = FALSE;
  DWORD rc = ERROR_SUCCESS;

  /* Two calls: the first only to learn the size. The API has no other shape. */
  GetUserObjectSecurity(object, &info, NULL, 0, &needed);
  if (needed == 0) {
    rc = GetLastError();
    fail(what, rc);
    fail(L"  ^ sizing GetUserObjectSecurity", rc);
    return rc;
  }

  existing = LocalAlloc(LPTR, needed);
  if (existing == NULL) return ERROR_NOT_ENOUGH_MEMORY;

  if (!GetUserObjectSecurity(object, &info, existing, needed, &needed)) {
    rc = GetLastError();
    fail(what, rc);
    fail(L"  ^ reading GetUserObjectSecurity", rc);
    LocalFree(existing);
    return rc;
  }

  if (!GetSecurityDescriptorDacl(existing, &present, &current, &defaulted)) {
    rc = GetLastError();
    fail(what, rc);
    fail(L"  ^ GetSecurityDescriptorDacl", rc);
    LocalFree(existing);
    return rc;
  }

  ZeroMemory(&entry, sizeof(entry));
  entry.grfAccessPermissions = rights;
  entry.grfAccessMode = GRANT_ACCESS;
  entry.grfInheritance = inheritance;
  BuildTrusteeWithSidW(&entry.Trustee, sid);

  rc = SetEntriesInAclW(1, &entry, present ? current : NULL, &updated);
  if (rc != ERROR_SUCCESS) {
    fail(what, rc);
    fail(L"  ^ SetEntriesInAcl", rc);
    LocalFree(existing);
    return rc;
  }

  /*
   * A fresh absolute descriptor rather than editing the one that was read.
   * `GetUserObjectSecurity` hands back a self-relative descriptor, whose DACL
   * pointer is an offset into its own buffer, and `SetSecurityDescriptorDacl`
   * refuses those. `SetUserObjectSecurity` reads only the parts named by the
   * information flags, so a descriptor carrying nothing but the new DACL is
   * complete for this call.
   */
  if (!InitializeSecurityDescriptor(&fresh, SECURITY_DESCRIPTOR_REVISION)) {
    rc = GetLastError();
    fail(L"  ^ InitializeSecurityDescriptor", rc);
  } else if (!SetSecurityDescriptorDacl(&fresh, TRUE, updated, FALSE)) {
    rc = GetLastError();
    fail(L"  ^ SetSecurityDescriptorDacl", rc);
  } else if (!SetUserObjectSecurity(object, &info, &fresh)) {
    rc = GetLastError();
    fail(what, rc);
    fail(L"  ^ SetUserObjectSecurity", rc);
  }

  LocalFree(updated);
  LocalFree(existing);
  return rc;
}

/*
 * A private desktop on the window station this process is already on.
 *
 * This exists because {@link makeStation} cannot be used by the program that
 * actually ships. Creating a *window station* needs an administrator:
 * `CreateWindowStationW` answered `ERROR_ACCESS_DENIED` for a genuinely
 * non-elevated token — medium integrity, Administrators deny-only — running in
 * the interactive session on `DESKTOP-DDGMNCV`, while the same call from an
 * elevated shell on the same machine succeeded. Terminal Deck is a desktop app
 * that nobody elevates, so the station half of the previous design was never
 * reachable in production; it was measured from an elevated shell and the
 * difference did not show.
 *
 * A *desktop* is different: the caller creates it on a station it already has,
 * and a normal user can. So the child gets a desktop of its own — no window of
 * the user's is on it, and `SendMessage` cannot cross a desktop boundary — on
 * the station the user is already using.
 *
 * **What that costs, stated because it is a real difference and not a
 * footnote.** A window station owns the clipboard and the global atom table, so
 * a confined session sharing `WinSta0` can read whatever the user last copied.
 * It cannot see or touch their windows; it can see their clipboard. That is the
 * price of not needing an administrator at every session start, it is written
 * down in `CONFINEMENT.md`, and it is why the choice is a flag the caller has
 * to make rather than a fallback this program takes on its own — a program that
 * quietly picked the weaker option when the stronger one failed would be
 * deciding a security question in a place nobody reads.
 */
static DWORD makeDesktopOnCurrentStation(Station *out, PSID sid, DWORD pid) {
  WCHAR desktopName[64];
  WCHAR stationName[64];
  DWORD needed = 0;
  HWINSTA current;
  DWORD rc;

  ZeroMemory(out, sizeof(*out));
  StringCchPrintfW(desktopName, 64, L"tdconfine-%lu", pid);

  current = GetProcessWindowStation();
  if (current == NULL) {
    fail(L"this process has no window station to start from", GetLastError());
    return GetLastError();
  }
  /*
   * The station's own name, asked of the object rather than assumed to be
   * `WinSta0`. A service, a scheduled task and a remote-desktop session are all
   * on stations with other names, and `STARTUPINFO.lpDesktop` takes
   * `<station>\<desktop>` — a hardcoded `WinSta0` would start the child on a
   * desktop belonging to a station this process is not on, which fails as
   * `STATUS_DLL_INIT_FAILED` long after the useful error is gone.
   */
  if (!GetUserObjectInformationW(current, UOI_NAME, stationName, sizeof(stationName), &needed)) {
    rc = GetLastError();
    fail(L"could not read the name of this window station", rc);
    return rc;
  }

  out->desktop =
      CreateDesktopW(desktopName, NULL, NULL, 0, GENERIC_ALL | READ_CONTROL | WRITE_DAC, NULL);
  if (out->desktop == NULL) {
    rc = GetLastError();
    fail(L"could not create a desktop of its own", rc);
    return rc;
  }

  /*
   * Only the desktop is granted. The station is not touched at all — no ACE is
   * added to `WinSta0` and none is taken away, because an AppContainer already
   * reaches the interactive station through the `ALL APPLICATION PACKAGES` ACE
   * Windows itself puts there for store apps. Measured: with this desktop
   * granted and the station untouched, a confined `cmd.exe` starts and runs.
   */
  rc = editUserObject(out->desktop, sid, GENERIC_ALL, NO_INHERITANCE, L"desktop");
  if (rc != ERROR_SUCCESS) {
    fail(L"could not grant the container its desktop", rc);
    return rc;
  }

  StringCchPrintfW(out->name, 128, L"%ls\\%ls", stationName, desktopName);
  return ERROR_SUCCESS;
}

static DWORD makeStation(Station *out, PSID sid, DWORD pid) {
  HWINSTA original;
  WCHAR stationName[64];
  DWORD rc;

  ZeroMemory(out, sizeof(*out));

  /*
   * Named after this process rather than randomly. A window station name has to
   * be unique within the logon session, and two sessions starting in the same
   * millisecond is an ordinary event; a pid is unique by definition for as long
   * as the process holding the handle is alive, which is exactly the lifetime
   * of the station.
   */
  StringCchPrintfW(stationName, 64, L"tdconfine-%lu", pid);

  original = GetProcessWindowStation();
  if (original == NULL) {
    fail(L"this process has no window station to start from", GetLastError());
    return GetLastError();
  }

  /*
   * `READ_CONTROL | WRITE_DAC` on top of `WINSTA_ALL_ACCESS`, and the reason is
   * a trap worth naming: `WINSTA_ALL_ACCESS` is **not** all access. Unlike
   * `FILE_ALL_ACCESS` it is a bare `OR` of the window-station-specific rights
   * with no `STANDARD_RIGHTS_REQUIRED` in it, so a handle opened with it cannot
   * read or write the object's own security descriptor. Creating the station
   * succeeded and then granting the container access to it failed with
   * `ERROR_ACCESS_DENIED` on the station this very process had just created —
   * measured, and the sort of thing that reads as "AppContainer is not allowed
   * to do this" when it is really "ask for the right on the handle".
   */
  out->station =
      CreateWindowStationW(stationName, 0, WINSTA_ALL_ACCESS | READ_CONTROL | WRITE_DAC, NULL);
  if (out->station == NULL) {
    rc = GetLastError();
    fail(L"could not create a window station", rc);
    return rc;
  }

  if (!SetProcessWindowStation(out->station)) {
    rc = GetLastError();
    fail(L"could not stand on the new window station", rc);
    CloseWindowStation(out->station);
    out->station = NULL;
    return rc;
  }

  out->desktop = CreateDesktopW(L"Default", NULL, NULL, 0,
                                GENERIC_ALL | READ_CONTROL | WRITE_DAC, NULL);
  rc = (out->desktop == NULL) ? GetLastError() : ERROR_SUCCESS;
  if (rc != ERROR_SUCCESS) fail(L"could not create a desktop on it", rc);

  /* Back to the console's station before anything else happens. */
  if (!SetProcessWindowStation(original) && rc == ERROR_SUCCESS) {
    rc = GetLastError();
    fail(L"could not return to the original window station", rc);
  }
  if (rc != ERROR_SUCCESS) return rc;

  /*
   * The station's ACE has to reach the desktop as well, or a desktop opened by
   * name would be unreachable. `NO_PROPAGATE_INHERIT_ACE` stops it going any
   * further than one level down, which for a window station means the desktops
   * directly on it and nothing beyond.
   */
  rc = editUserObject(out->station, sid, WINSTA_ALL_ACCESS | READ_CONTROL,
                      OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE | NO_PROPAGATE_INHERIT_ACE,
                      L"window station");
  if (rc != ERROR_SUCCESS) {
    fail(L"could not grant the container its window station", rc);
    return rc;
  }

  rc = editUserObject(out->desktop, sid, GENERIC_ALL, NO_INHERITANCE, L"desktop");
  if (rc != ERROR_SUCCESS) {
    fail(L"could not grant the container its desktop", rc);
    return rc;
  }

  StringCchPrintfW(out->name, 128, L"%ls\\Default", stationName);
  return ERROR_SUCCESS;
}

static void closeStation(Station *station) {
  if (station->desktop != NULL) CloseDesktop(station->desktop);
  if (station->station != NULL) CloseWindowStation(station->station);
  station->desktop = NULL;
  station->station = NULL;
}

/* ------------------------------------------------------------ command line -- */

/*
 * One argument, quoted the way `CommandLineToArgvW` will unquote it.
 *
 * `CreateProcessW` takes a string and the child takes an argument vector, and
 * the function in the middle is this one. Getting it wrong is not cosmetic
 * here: a folder called `C:\Users\Imza\My Projects` would arrive as two
 * arguments and the session would start somewhere else entirely, or not at all.
 * The rule being implemented is the documented one — backslashes are literal
 * except immediately before a quote, where they double.
 *
 * `*written` is advanced rather than assigned, so the caller can build the
 * whole line by calling this once per argument.
 */
static BOOL quoteArg(LPCWSTR arg, LPWSTR out, size_t room, size_t *written) {
  size_t used = 0;
  size_t i;
  size_t slashes;
  BOOL simple = (arg[0] != L'\0');

  for (i = 0; arg[i] != L'\0'; i++) {
    if (arg[i] == L' ' || arg[i] == L'\t' || arg[i] == L'"') simple = FALSE;
  }

#define PUT(ch)                       \
  do {                                \
    if (used + 1 >= room) return FALSE; \
    out[used++] = (ch);               \
  } while (0)

  if (simple) {
    for (i = 0; arg[i] != L'\0'; i++) PUT(arg[i]);
    out[used] = L'\0';
    *written += used;
    return TRUE;
  }

  PUT(L'"');
  for (i = 0;; i++) {
    slashes = 0;
    while (arg[i] == L'\\') {
      i++;
      slashes++;
    }
    if (arg[i] == L'\0') {
      /* Trailing backslashes double, so the closing quote stays a quote. */
      for (; slashes > 0; slashes--) {
        PUT(L'\\');
        PUT(L'\\');
      }
      break;
    }
    if (arg[i] == L'"') {
      for (; slashes > 0; slashes--) {
        PUT(L'\\');
        PUT(L'\\');
      }
      PUT(L'\\');
      PUT(L'"');
    } else {
      for (; slashes > 0; slashes--) PUT(L'\\');
      PUT(arg[i]);
    }
  }
  PUT(L'"');
  out[used] = L'\0';
  *written += used;
  return TRUE;

#undef PUT
}

/* ------------------------------------------------------------------- main -- */

/*
 * Ctrl-C belongs to the child, not to this process.
 *
 * A console control event goes to every process attached to the console, and
 * this launcher is one of them. Letting the default handler run would kill the
 * launcher while the shell it is waiting on carried on running — a session that
 * looks closed with a process still inside the boundary, and an exit code the
 * pty reads before the child has produced one. Returning TRUE says "handled",
 * and the shell, which is the program the user is actually typing at, gets to
 * decide what Ctrl-C means.
 */
static BOOL WINAPI ignoreConsoleEvent(DWORD type) {
  (void)type;
  return TRUE;
}

static void usage(void) {
  fwprintf(stderr,
           L"tdconfine: usage:\n"
           L"  tdconfine --container <name> --station own|shared\n"
           L"            [--capability internet-client|private-network]...\n"
           L"            [--capability-sid <S-1-15-3-...>]...\n"
           L"            [--write <dir>] [--read <dir>] [--file <path>] [--ancestor <dir>]\n"
           L"            --cwd <dir> -- <program> [args...]\n"
           L"  tdconfine --container <name> --release [--write <dir>|--read <dir>|"
           L"--file <path>|--ancestor <dir>]...\n"
           L"  tdconfine --establish --capability-sid <S-1-15-3-...> "
           L"[--read <dir>|--file <path>|--ancestor <dir>]...\n"
           L"  tdconfine --withdraw  --capability-sid <S-1-15-3-...> "
           L"[--read <dir>|--file <path>|--ancestor <dir>]...\n");
  fflush(stderr);
}

int wmain(int argc, wchar_t **argv) {
  Grant grants[MAX_PATHS];
  int grantCount = 0;
  int granted = 0;
  LPWSTR container = NULL;
  LPWSTR cwd = NULL;
  int childAt = -1;
  BOOL release = FALSE;
  /*
   * The one-time grant, and its undo.
   *
   * Separate flags rather than a mode enum because they are separate answers to
   * separate questions, and because the argument parser below is a flat loop
   * that a mode variable would have to be threaded through. What makes them a
   * mode is the block after the parse, which refuses every combination that is
   * not one of the four this program does.
   */
  BOOL establish = FALSE;
  BOOL withdraw = FALSE;
  /*
   * Which desktop the child gets, and it has no default on purpose.
   *
   * `own` creates a whole window station and needs an administrator; `shared`
   * creates a private desktop on the station this process is already on and
   * needs nothing. They differ in what the confined session can reach — see
   * {@link makeDesktopOnCurrentStation} — so the caller states which one it is
   * asking for and this program refuses to guess.
   */
  LPWSTR stationMode = NULL;
  BOOL wantsInternet = FALSE;
  BOOL wantsPrivateNetwork = FALSE;

  HMODULE userenv = NULL;
  fnCreateAppContainerProfile createProfile = NULL;
  fnDeriveAppContainerSid deriveSid = NULL;

  PSID containerSid = NULL;
  SID_IDENTIFIER_AUTHORITY appAuthority = {{0, 0, 0, 0, 0, 15}};
  SID_AND_ATTRIBUTES capabilities[MAX_CAPABILITIES];
  /*
   * Which allocator each capability SID came from, because they do not all come
   * from the same one and the two are not interchangeable. The well-known pair
   * are built with `AllocateAndInitializeSid` and freed with `FreeSid`; a SID
   * parsed from a string comes out of `ConvertStringSidToSidW`, which documents
   * `LocalFree`. Passing one to the other's free is the kind of thing that works
   * on every machine it is tried on and is still wrong.
   */
  BOOL capabilityLocal[MAX_CAPABILITIES];
  DWORD capabilityCount = 0;
  DWORD capability;
  LPWSTR capabilitySids[MAX_CAPABILITIES];
  int capabilitySidCount = 0;

  Station station;
  HANDLE job = NULL;
  SECURITY_CAPABILITIES security;
  STARTUPINFOEXW startup;
  PROCESS_INFORMATION child;
  SIZE_T attributeBytes = 0;
  LPWSTR commandLine = NULL;
  size_t commandRoom = 0;
  size_t commandUsed = 0;

  HRESULT hr;
  DWORD rc;
  DWORD exitCode = EXIT_SPAWN;
  int i;

  ZeroMemory(&station, sizeof(station));
  ZeroMemory(&child, sizeof(child));
  ZeroMemory(&startup, sizeof(startup));
  ZeroMemory(capabilities, sizeof(capabilities));
  ZeroMemory(capabilityLocal, sizeof(capabilityLocal));
  ZeroMemory(capabilitySids, sizeof(capabilitySids));

  for (i = 1; i < argc; i++) {
    if (wcscmp(argv[i], L"--") == 0) {
      childAt = i + 1;
      break;
    }
    if (wcscmp(argv[i], L"--release") == 0) {
      release = TRUE;
      continue;
    }
    if (wcscmp(argv[i], L"--establish") == 0) {
      establish = TRUE;
      continue;
    }
    if (wcscmp(argv[i], L"--withdraw") == 0) {
      withdraw = TRUE;
      continue;
    }
    if (i + 1 >= argc) {
      usage();
      return EXIT_USAGE;
    }
    if (wcscmp(argv[i], L"--container") == 0) {
      container = argv[++i];
    } else if (wcscmp(argv[i], L"--station") == 0) {
      stationMode = argv[++i];
      if (wcscmp(stationMode, L"own") != 0 && wcscmp(stationMode, L"shared") != 0) {
        fwprintf(stderr, L"tdconfine: --station takes own or shared, not %ls\n", stationMode);
        return EXIT_USAGE;
      }
    } else if (wcscmp(argv[i], L"--cwd") == 0) {
      cwd = argv[++i];
    } else if (wcscmp(argv[i], L"--capability-sid") == 0) {
      /*
       * The tool capability, as a SID rather than a name.
       *
       * A SID string rather than a name this program derives, because the same
       * value has to be written into an ACL by an elevated run of this program
       * at install time and put into a token by an unprivileged run of it at
       * every session, and the two must be the same value. Deriving it twice
       * from a name would be two sources of truth; `confine/tools.ts` computes
       * it once and both runs are handed the answer.
       */
      if (capabilitySidCount >= MAX_CAPABILITIES) {
        fwprintf(stderr, L"tdconfine: more than %d capabilities\n", MAX_CAPABILITIES);
        return EXIT_USAGE;
      }
      capabilitySids[capabilitySidCount++] = argv[++i];
    } else if (wcscmp(argv[i], L"--capability") == 0) {
      i++;
      if (wcscmp(argv[i], L"internet-client") == 0) {
        wantsInternet = TRUE;
      } else if (wcscmp(argv[i], L"private-network") == 0) {
        wantsPrivateNetwork = TRUE;
      } else {
        /*
         * An unknown capability is a refusal rather than a shrug. The set this
         * program understands is the set that has been measured; ignoring a
         * name would mean a caller believing it had asked for something and a
         * session running without it.
         */
        fwprintf(stderr, L"tdconfine: unknown capability %ls\n", argv[i]);
        return EXIT_USAGE;
      }
    } else if (wcscmp(argv[i], L"--write") == 0 || wcscmp(argv[i], L"--read") == 0 ||
               wcscmp(argv[i], L"--file") == 0 || wcscmp(argv[i], L"--ancestor") == 0) {
      if (grantCount >= MAX_PATHS) {
        fwprintf(stderr, L"tdconfine: more than %d paths in one plan\n", MAX_PATHS);
        return EXIT_USAGE;
      }
      grants[grantCount].kind = (argv[i][2] == L'w')   ? GRANT_WRITE
                                : (argv[i][2] == L'r') ? GRANT_READ
                                : (argv[i][2] == L'f') ? GRANT_FILE
                                                       : GRANT_ANCESTOR;
      grants[grantCount].path = argv[++i];
      grantCount++;
    } else {
      fwprintf(stderr, L"tdconfine: unknown option %ls\n", argv[i]);
      usage();
      return EXIT_USAGE;
    }
  }

  /*
   * The one-time grant: the half of Windows confinement that needs an
   * administrator, done once instead of once per session.
   *
   * Two things a confined session needs are on directories the person running
   * Terminal Deck cannot rewrite the permissions of, and measured on
   * `DESKTOP-DDGMNCV` with a real non-elevated token (`AccessCheck` for
   * `WRITE_DAC`, Administrators deny-only, medium integrity):
   *
   *     C:\                     NO        C:\Users\<user>        YES
   *     C:\Users                NO        C:\Program Files       NO
   *
   * `C:\` and `C:\Users` are on the path to every granted folder under a user
   * profile, and a confined session that cannot list them cannot resolve an
   * absolute path at all — `cmd` answers `Access is denied` for a command given
   * by full path, and git dies at `unable to get current working directory`.
   * `C:\Program Files` is where `node` and `git` are. So a session that ACL'd
   * its own way in would need an administrator **every time it started**, which
   * is not something anybody would keep switched on.
   *
   * The trustee here is therefore not the per-device container SID that the
   * session grants use — those come and go with the session — but a **capability
   * SID**, which is stable across devices and across reinstalls because it is
   * derived from a fixed name. The session's token carries that capability
   * (`--capability-sid`), so an ACE written once by this mode is what makes
   * every later session work with no privilege at all.
   *
   * `--write` is refused in this mode, and the refusal is the point: a permanent
   * ACE that lets a container *write* somewhere is not a thing this program will
   * create. The one-time grant is read, execute and list, and nothing else.
   */
  if (establish || withdraw) {
    PSID toolSid = NULL;
    int failures = 0;
    if (establish && withdraw) {
      fwprintf(stderr, L"tdconfine: --establish and --withdraw are opposites\n");
      usage();
      return EXIT_USAGE;
    }
    if (capabilitySidCount != 1 || childAt >= 0 || grantCount == 0) {
      usage();
      return EXIT_USAGE;
    }
    for (i = 0; i < grantCount; i++) {
      if (grants[i].kind != GRANT_WRITE) continue;
      fwprintf(stderr, L"tdconfine: a one-time grant is never writable (%ls)\n", grants[i].path);
      return EXIT_USAGE;
    }
    if (!ConvertStringSidToSidW(capabilitySids[0], &toolSid)) {
      fwprintf(stderr, L"tdconfine: %ls is not a SID\n", capabilitySids[0]);
      return EXIT_USAGE;
    }
    if (!isCapabilitySid(toolSid)) {
      fwprintf(stderr, L"tdconfine: %ls is not a capability SID (S-1-15-3-...)\n",
               capabilitySids[0]);
      LocalFree(toolSid);
      return EXIT_USAGE;
    }
    for (i = 0; i < grantCount; i++) {
      rc = editPath(grants[i].path, toolSid, grants[i].kind,
                    establish ? GRANT_ACCESS : REVOKE_ACCESS);
      if (rc != ERROR_SUCCESS) {
        fwprintf(stderr, L"tdconfine: could not %ls %ls (0x%08lX)\n",
                 establish ? L"grant" : L"withdraw", grants[i].path, rc);
        fflush(stderr);
        failures++;
      }
    }
    LocalFree(toolSid);
    /*
     * A partial establish is left in place rather than unwound, which is the
     * opposite of what the session path does, and deliberately so: the ACEs
     * this mode writes are *meant* to outlive the process, so unwinding the
     * ones that worked would turn "one directory could not be reached" into
     * "nothing was granted", and the caller would have no way to tell those
     * apart from the exit code. The record on the TypeScript side is written
     * only when this exits zero, so a partial run is repeated rather than
     * trusted, and repeating it is harmless — `SetEntriesInAclW` merges.
     */
    return failures == 0 ? 0 : EXIT_ACL;
  }

  if (container == NULL ||
      (!release && (childAt < 0 || childAt >= argc || cwd == NULL || stationMode == NULL))) {
    usage();
    return EXIT_USAGE;
  }

  userenv = LoadLibraryW(L"userenv.dll");
  if (userenv == NULL) {
    fail(L"could not load userenv.dll", GetLastError());
    return EXIT_CONTAINER;
  }
  /*
   * The two casts in this file that are not a printf width. `GetProcAddress`
   * returns a function pointer with no signature and there is no way to name
   * one of these without saying which; the `void *` step is what C requires to
   * get from `FARPROC` to a differently-shaped function pointer without a
   * warning on either compiler.
   */
  createProfile =
      (fnCreateAppContainerProfile)(void *)GetProcAddress(userenv, "CreateAppContainerProfile");
  deriveSid = (fnDeriveAppContainerSid)(void *)GetProcAddress(
      userenv, "DeriveAppContainerSidFromAppContainerName");
  if (createProfile == NULL || deriveSid == NULL) {
    fail(L"this Windows has no AppContainer API", ERROR_NOT_SUPPORTED);
    return EXIT_CONTAINER;
  }

  /*
   * Create first, derive second, and treat "already exists" as success.
   *
   * The SID is a pure function of the name — the same value before the profile
   * is created and after it has been deleted — so deriving it separately is not
   * a second source of truth, it is the only way to get the SID on a run where
   * the profile was already there.
   */
  if (!release) {
    PSID created = NULL;
    hr = createProfile(container, container, L"Terminal Deck confined session", NULL, 0,
                       &created);
    if (created != NULL) FreeSid(created);
    if (FAILED(hr) && hr != HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS)) {
      fail(L"could not create the container profile", (unsigned long)hr);
      return EXIT_CONTAINER;
    }
  }

  hr = deriveSid(container, &containerSid);
  if (FAILED(hr) || containerSid == NULL) {
    fail(L"could not derive the container SID", (unsigned long)hr);
    return EXIT_CONTAINER;
  }

  if (release) {
    revokeAll(grants, grantCount, containerSid);
    FreeSid(containerSid);
    return 0;
  }

  for (granted = 0; granted < grantCount; granted++) {
    rc = editPath(grants[granted].path, containerSid, grants[granted].kind, GRANT_ACCESS);
    if (rc != ERROR_SUCCESS) {
      fwprintf(stderr, L"tdconfine: could not grant %ls (0x%08lX)\n", grants[granted].path, rc);
      fflush(stderr);
      revokeAll(grants, granted, containerSid);
      FreeSid(containerSid);
      return EXIT_ACL;
    }
  }

  rc = (wcscmp(stationMode, L"own") == 0)
           ? makeStation(&station, containerSid, GetCurrentProcessId())
           : makeDesktopOnCurrentStation(&station, containerSid, GetCurrentProcessId());
  if (rc != ERROR_SUCCESS) {
    fail(L"could not give the container a desktop", rc);
    exitCode = EXIT_STATION;
    goto teardown;
  }

  /*
   * The capabilities, built rather than looked up.
   *
   * `S-1-15-3-1` is `internetClient` and `S-1-15-3-3` is
   * `privateNetworkClientServer`; both are well known, and constructing them
   * from the app-package authority is exact where `DeriveCapabilitySidsFromName`
   * would be another dynamic import for a value that cannot change.
   *
   * An AppContainer with no capability at all has no network, and an agent CLI
   * with no network is not a session anybody wants. What it still does not have
   * — and this is worth knowing before somebody reports it as a bug — is
   * loopback: an AppContainer cannot reach `127.0.0.1` without a per-container
   * loopback exemption, which is a machine-wide setting this program will not
   * make. A confined session can talk to the internet and cannot talk to a dev
   * server on the same machine.
   */
  if (wantsInternet) {
    if (!AllocateAndInitializeSid(&appAuthority, 2, 3, 1, 0, 0, 0, 0, 0, 0,
                                  &capabilities[capabilityCount].Sid)) {
      fail(L"could not build the internet capability", GetLastError());
      goto teardown;
    }
    capabilities[capabilityCount].Attributes = SE_GROUP_ENABLED;
    capabilityCount++;
  }
  if (wantsPrivateNetwork) {
    if (!AllocateAndInitializeSid(&appAuthority, 2, 3, 3, 0, 0, 0, 0, 0, 0,
                                  &capabilities[capabilityCount].Sid)) {
      fail(L"could not build the private-network capability", GetLastError());
      goto teardown;
    }
    capabilities[capabilityCount].Attributes = SE_GROUP_ENABLED;
    capabilityCount++;
  }

  /*
   * The named capabilities the caller passed as SIDs — in practice exactly one,
   * the tool capability.
   *
   * This is the half of the one-time grant that lives in the token. The other
   * half is an ACE for the same SID on `C:\Program Files\nodejs` and the rest of
   * the tool trees, written once by an elevated run of this program, and the two
   * halves are what let a confined *shell* start `node` without any per-session
   * permission change and without administrator rights. Measured: with the ACE
   * present and this SID absent from the token, `node -v` inside the container
   * is `Access is denied`; with both, it prints the version.
   *
   * `isCapabilitySid` is not a formality. See its comment: a SID that is not a
   * capability would arrive in the child's token as an enabled group and grant
   * every ACE on the machine that names it.
   */
  for (i = 0; i < capabilitySidCount; i++) {
    PSID parsed = NULL;
    if (capabilityCount >= MAX_CAPABILITIES) {
      fail(L"more capabilities than this program will carry", ERROR_INSUFFICIENT_BUFFER);
      goto teardown;
    }
    if (!ConvertStringSidToSidW(capabilitySids[i], &parsed)) {
      fwprintf(stderr, L"tdconfine: %ls is not a SID\n", capabilitySids[i]);
      fflush(stderr);
      goto teardown;
    }
    if (!isCapabilitySid(parsed)) {
      fwprintf(stderr, L"tdconfine: %ls is not a capability SID (S-1-15-3-...)\n",
               capabilitySids[i]);
      fflush(stderr);
      LocalFree(parsed);
      goto teardown;
    }
    capabilities[capabilityCount].Sid = parsed;
    capabilities[capabilityCount].Attributes = SE_GROUP_ENABLED;
    capabilityLocal[capabilityCount] = TRUE;
    capabilityCount++;
  }

  /*
   * The command line, sized from the arguments themselves rather than from a
   * constant. Every character can at worst double (a backslash before a quote)
   * and every argument can gain two quotes and a separator.
   */
  commandRoom = 1;
  for (i = childAt; i < argc; i++) commandRoom += (wcslen(argv[i]) * 2) + 4;
  commandLine = LocalAlloc(LPTR, commandRoom * sizeof(WCHAR));
  if (commandLine == NULL) {
    fail(L"out of memory building the command line", ERROR_NOT_ENOUGH_MEMORY);
    goto teardown;
  }
  for (i = childAt; i < argc; i++) {
    if (i > childAt) commandLine[commandUsed++] = L' ';
    if (!quoteArg(argv[i], commandLine + commandUsed, commandRoom - commandUsed,
                  &commandUsed)) {
      fail(L"could not build the command line", ERROR_INSUFFICIENT_BUFFER);
      goto teardown;
    }
  }

  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
  startup.StartupInfo.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
  startup.StartupInfo.hStdError = GetStdHandle(STD_ERROR_HANDLE);
  startup.StartupInfo.lpDesktop = station.name;

  InitializeProcThreadAttributeList(NULL, 1, 0, &attributeBytes);
  startup.lpAttributeList = LocalAlloc(LPTR, attributeBytes);
  if (startup.lpAttributeList == NULL) {
    fail(L"out of memory building the attribute list", ERROR_NOT_ENOUGH_MEMORY);
    goto teardown;
  }
  if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &attributeBytes)) {
    fail(L"could not initialise the attribute list", GetLastError());
    goto teardown;
  }

  ZeroMemory(&security, sizeof(security));
  security.AppContainerSid = containerSid;
  security.Capabilities = capabilityCount > 0 ? capabilities : NULL;
  security.CapabilityCount = capabilityCount;

  if (!UpdateProcThreadAttribute(startup.lpAttributeList, 0,
                                 PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, &security,
                                 sizeof(security), NULL, NULL)) {
    fail(L"could not attach the container to the process creation", GetLastError());
    goto teardown;
  }

  SetConsoleCtrlHandler(ignoreConsoleEvent, TRUE);

  /*
   * A job object, and it is **not** part of the boundary.
   *
   * Saying that first because a job object is the thing everyone reaches for on
   * Windows and it does not confine anything here: a job that this process
   * cannot break out of was measured surviving in the one way that matters —
   * `wsl.exe -e /usr/bin/setsid /bin/sleep 511` outlived `TerminateJobObject`
   * with its pid and session id intact while the shell died. A job must never
   * be described as containing a WSL session.
   *
   * What it does is fix a real defect that was measured on this launcher.
   * Killing the launcher outright leaves the confined child **running** — a
   * node process still alive inside the container, still holding the ACEs on
   * the user's folders, with nothing left that knows to take them off. That is
   * exactly what `node-pty` does when a tab is closed hard. With
   * `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, the last handle to the job closing is
   * what ends the whole tree, and the launcher's handle is the last one.
   *
   * The child is created suspended so there is no window between it starting
   * and it being in the job. A process that ran for a millisecond outside the
   * job and spawned something in that millisecond would leave that grandchild
   * outside it.
   *
   * Failure here is printed and continued past rather than fatal. It is not a
   * security property, and refusing a session that is properly confined because
   * a cleanup mechanism was unavailable would trade a real feature for a tidy
   * one. The child is resumed either way — a suspended child that nobody
   * resumes is a session that hangs with no message at all.
   */
  job = CreateJobObjectW(NULL, NULL);
  if (job != NULL) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
    ZeroMemory(&limits, sizeof(limits));
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits,
                                 sizeof(limits))) {
      fail(L"could not set the job to end with this process", GetLastError());
      CloseHandle(job);
      job = NULL;
    }
  } else {
    fail(L"could not create a job object", GetLastError());
  }

  /*
   * `bInheritHandles = TRUE` is what keeps ConPTY working.
   *
   * This launcher is started by `node-pty`, which has already attached it to a
   * pseudoconsole. The child inherits this process's standard handles and, with
   * them, the same pseudoconsole — no second pty, no byte pumping, no resize
   * message to forward. That is the whole reason the design is a launcher that
   * `CreateProcess`es rather than a program that builds its own console: the
   * part of the terminal that works is the part nobody had to reimplement.
   */
  if (!CreateProcessW(NULL, commandLine, NULL, NULL, TRUE,
                      EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT |
                          CREATE_SUSPENDED,
                      NULL, cwd, &startup.StartupInfo, &child)) {
    fail(L"could not start the confined process", GetLastError());
    goto teardown;
  }

  if (job != NULL && !AssignProcessToJobObject(job, child.hProcess)) {
    fail(L"could not put the confined process in a job; it will outlive a hard kill",
         GetLastError());
  }
  if (ResumeThread(child.hThread) == (DWORD)-1) {
    fail(L"could not start the confined process running", GetLastError());
    TerminateProcess(child.hProcess, EXIT_SPAWN);
  }

  WaitForSingleObject(child.hProcess, INFINITE);
  if (!GetExitCodeProcess(child.hProcess, &exitCode)) exitCode = EXIT_SPAWN;
  CloseHandle(child.hThread);
  CloseHandle(child.hProcess);

teardown:
  if (startup.lpAttributeList != NULL) {
    DeleteProcThreadAttributeList(startup.lpAttributeList);
    LocalFree(startup.lpAttributeList);
  }
  if (commandLine != NULL) LocalFree(commandLine);
  for (capability = 0; capability < capabilityCount; capability++) {
    if (capabilityLocal[capability]) {
      LocalFree(capabilities[capability].Sid);
    } else {
      FreeSid(capabilities[capability].Sid);
    }
  }
  /*
   * Closing the job before the ACEs come off, not after. If anything in the
   * container is somehow still running at this point, this is what ends it, and
   * revoking a permission from a process that is still using it is the wrong
   * order to do those two things in.
   */
  if (job != NULL) CloseHandle(job);
  closeStation(&station);
  revokeAll(grants, grantCount, containerSid);
  FreeSid(containerSid);
  FreeLibrary(userenv);
  /* An exit code is a DWORD on Windows and an int here; nothing this program
   * or a shell produces is anywhere near the width where that matters. */
  return (int)exitCode;
}
