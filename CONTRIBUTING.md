# Contributing to Terminal Deck

Thanks for looking. This is a small, opinionated codebase, and the rules below
exist because breaking them has already cost real time here.

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
Contributions are accepted under the [MIT licence](LICENSE); there is no CLA.

---

## Running it

```bash
npm install     # compiles node-pty and better-sqlite3 against Electron — slow first time
npm run dev     # Electron + Vite; the renderer hot reloads
```

Main-process changes need a dev restart. Renderer changes do not.

Before you claim anything works:

```bash
npm run typecheck   # both tsconfigs
npm test            # vitest
```

> **Never run `npm run build` while `npm run dev` is serving.** They share
> `out/`, and the build clobbers what dev is running. Use `npm run typecheck`
> to check a change compiles while dev is live.

### Checking the UI without launching Electron

`.harness/` mounts the real `App` in a plain browser against a stubbed preload:

```bash
npx vite --config .harness/vite.config.ts   # serves on :5199
```

This is the only thing that has reliably caught real defects here. Typecheck and
tests have both passed while a panel rendered nothing on screen, because the
failures were contract mismatches and runtime throws, not type errors.

**If you touch the preload, keep `.harness/stub.ts` honest.** It must mirror the
preload's actual shapes — `on*` methods return an unsubscribe function,
everything else returns a promise. A stub that disagrees with the preload
invents bugs that do not exist and hides ones that do. That happened three times
in a single session.

---

## House rules

These are not style preferences. Each one is here because of a specific bug.

### Write every line

**Never paste code in from another project**, however permissive its licence.
Reading another tool to learn *what* a feature does, or what values it uses —
sizes, timings, thresholds — is fine, and those are not copyrightable. Copying
its code, components, CSS blocks or icon artwork is not, because it pulls that
project's licence and copyright notice permanently into this repository and
quietly makes this file a lie.

If a pull request contains code you did not write, say so in the description and
name the source. It is much easier to deal with before merge than after.

### The name lives in one place

`src/shared/brand.ts`. Never hardcode the product name anywhere else.

### Verify against real data

This codebase has repeatedly been wrong in ways only real data exposed: the
prompt glyph is `❯` and not `>`, one API request emits many JSONL lines with the
usage repeated, and a GUI app on macOS genuinely cannot see `claude` on PATH.
If you can check an assumption against something real on this machine, do that
before writing code that depends on it.

### Compiling is not working

Two bugs here shipped a clean typecheck and a clean console while being visibly
wrong on screen. **If your change is visible, look at it** — in the app or in
the harness — before you open the pull request.

### Where code goes

| Path | Owns |
|---|---|
| `src/main/` | terminal processes, all IPC modules, persistence |
| `src/preload/` | the only renderer↔main bridge; no raw `ipcRenderer` escapes |
| `src/renderer/` | React UI |
| `src/shared/` | types and branding used by both sides |

Each main-process feature exports one `registerXIpc(ipcMain)`, wired in
`src/main/index.ts`. Keep a feature's types in its own module and let them cross
the bridge as `unknown` — duplicating them into `shared/types.ts` is what lets
the two sides drift apart.

### Style

- 2-space indent, no semicolons, single quotes
- Strict TypeScript. No `any`
- Comments explain **why**, not what. The interesting comment is the one that
  records the thing that was surprising
- Tests co-located as `*.test.ts`
- Use the CSS variables in `src/renderer/styles/tokens.css` — never a raw hex
  value

### Keyboard shortcuts

Every binding lives in `src/renderer/keymap.ts` and nowhere else. The matcher
reads that table, the shortcuts sheet renders it, and README quotes it. Adding a
shortcut anywhere else creates a second copy of one fact, and the printed copy
is the one that drifts silently, because nothing breaks when it lies.

---

## Proposing a change

**Something is broken?** Open a bug report. The template asks for your OS, the
app version, which agent CLI and version, and the support bundle — with those
four things a bug is usually reproducible on the first try, and without them it
usually is not. Getting the bundle is in the
[README](README.md#when-something-breaks).

**Want a feature?** Check [ROADMAP.md](ROADMAP.md) first — a lot is already
planned and sequenced. If it is not there, open a feature request describing
the problem you hit rather than the solution you have in mind.

**Sending code?**

1. For anything beyond a small fix, open an issue first. It is a short
   conversation that can save you an afternoon of work in the wrong direction.
2. Branch, and keep the pull request to one concern.
3. `npm run typecheck` and `npm test` both pass.
4. If the change is visible, look at it running and say in the description that
   you did.
5. New behaviour comes with a test. The features that survive refactors here are
   the ones that have one.

### Commit messages

Imperative mood, sentence case, no type prefixes or scopes. Say what the change
does, not what you touched:

```
Fix the panels and views that rendered nothing
Add session resume (Cmd+Shift+T) and a continue button per project
Fix status detection: read the rendered screen, not the byte stream
```

If *why* is not obvious from the subject, put it in the body. The body is worth
more than the subject six months later.

### What is likely to be declined

- A dependency added for something the standard library or a few lines can do.
  Every dependency here has to be shipped, licensed and audited
- Code copied from another project
- A visible change with no evidence anyone looked at it
- A reformat of code unrelated to your change, mixed into the same commit
- New raw hex colours, or a shortcut declared outside the keymap
