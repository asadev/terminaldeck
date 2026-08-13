# Vendored code and its licence

Terminal Deck ships under MIT. Two directories in here are not ours.

| Directory | Origin | Licence |
| --- | --- | --- |
| `terminal-view/` | [`termux/termux-app`](https://github.com/termux/termux-app), `terminal-view` module | Apache 2.0 |
| `terminal-emulator/` | [`termux/termux-app`](https://github.com/termux/termux-app), `terminal-emulator` module | Apache 2.0 |

Vendored from commit `3df69d1da197dd9bd71a3bafd902dffd720576b4` (2026-07-15).

## Why this is allowed, checked rather than assumed

`termux/termux-app` is **GPLv3-only** as a repository, and GPLv3 code cannot go into an
MIT-distributed product. The two modules above are the exception, and the exception is stated by
upstream in [`LICENSE.md`](https://github.com/termux/termux-app/blob/master/LICENSE.md), quoted in
full:

> The `termux/termux-app` repository is released under [GPLv3 only](https://www.gnu.org/licenses/gpl-3.0.html) license.
>
> ### Exceptions
>
> - [Terminal Emulator for Android](https://github.com/jackpal/Android-Terminal-Emulator) code is used which is released under [Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0) license. Check [`terminal-view`](terminal-view) and [`terminal-emulator`](terminal-emulator) libraries.
> - Check [`termux-shared/LICENSE.md`](https://github.com/termux/termux-app/blob/master/termux-shared/LICENSE.md) for `termux-shared` library related exceptions.

Apache 2.0 is compatible with MIT distribution. The obligations it does carry — attribution,
retaining notices, and stating changes — are met by this file and by `MODIFICATIONS.md`.

**Nothing else from that repository is vendored.** In particular `app/` and `termux-shared/` are
not, and must not be: `app/` is GPLv3 and `termux-shared/` carries its own separate exception list
that has not been reviewed for this project. A dependency on either would relicense Terminal Deck.

Verified independently by reading the two modules' sources: every import outside
`java.*`/`android.*`/their own packages is `androidx.annotation`. Neither module reaches into
`termux-shared`, so the GPLv3 boundary is not crossed by a transitive edge either.

## What is deliberately not vendored

- `terminal-emulator/src/main/jni/` and `JNI.java` — the pty. Terminal Deck's phone client never
  runs a local shell; the process it displays is on a Mac. Leaving the native half out means the
  app has no way to grow one by accident, and it drops the NDK from the build entirely.
- `terminal-emulator/src/test/` — upstream's emulator tests. They exercise `TerminalSession`'s
  pty behaviour, which is the half that was replaced.
- Both modules' `build.gradle`, replaced with `build.gradle.kts` that drop upstream's Maven
  publishing and NDK configuration.

## Re-vendoring

Take the two module directories verbatim from a fresh checkout, delete `JNI.java`, `src/main/jni`
and `src/test`, then reapply the `TerminalSession` change described in `MODIFICATIONS.md`. That is
the whole procedure — it is one file, deliberately.
