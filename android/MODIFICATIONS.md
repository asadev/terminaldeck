# Changes to the vendored Apache 2.0 code

Apache License 2.0 §4(b): *"You must cause any modified files to carry prominent notices stating
that You changed the files."* This is that notice, and each modified file repeats it in its header.

## `terminal-view/`

**Unmodified.** Every `.java` and every resource is byte-identical to upstream. Only
`build.gradle` was replaced (see `VENDORED.md`), and a build file is not part of the licensed work
in any sense that matters here.

## `terminal-emulator/`

Two changes.

### 1. `JNI.java` and `src/main/jni/` are not present

Deletion, not modification. See `VENDORED.md` for why.

### 2. `TerminalSession.java` — rewritten around a transport instead of a pty

Upstream, a `TerminalSession` *is* a child process: the constructor takes a shell path, cwd, argv
and environment, and `initializeEmulator` forks through `JNI.createSubprocess`, wraps the master
file descriptor, and starts three threads (reader, writer, waiter).

Terminal Deck's phone never runs a shell. Every session it displays already exists on a desktop on
the tailnet, and the phone's job is to render bytes and send keystrokes. So:

| Upstream | Here |
| --- | --- |
| `TerminalSession(shellPath, cwd, args, env, transcriptRows, client)` | `TerminalSession(remoteId, transcriptRows, client)` |
| `initializeEmulator` forks a pty and starts 3 threads | creates the emulator, then notifies `Transport.onSizeChanged(initial = true)` |
| `write()` queues into `mTerminalToProcessIOQueue` for a writer thread | `write()` calls `Transport.onInput` synchronously |
| reader thread fills `mProcessToTerminalIOQueue` | `feedOutput()` fills it, callable from any thread |
| waiter thread posts `MSG_PROCESS_EXITED` | `remoteExited(code)` posts it |
| `updateSize` calls `JNI.setPtyWindowSize` | `updateSize` calls `Transport.onSizeChanged(initial = false)` |
| `finishIfRunning()` sends `SIGKILL` | `finishIfRunning()` closes the queue and calls `Transport.onDetach` |
| `getCwd()` reads `/proc/<pid>/cwd` | returns the cwd the desktop reported in its session list |
| `mShellPid` / `getPid()` | gone; there is no local process to have a pid |
| `getExitStatus()` | kept, fed by `remoteExited` |

Added: the nested `TerminalSession.Transport` interface, `setTransport`, `feedOutput`,
`remoteExited`, `mRemoteId`, `mRemoteCwd`.

Kept byte-identical: `writeCodePoint`, the `ByteQueue` → main-thread-handler → `TerminalEmulator`
output path, and every `TerminalOutput` callback. Those are the parts that make the emulator
correct, and none of them had anything to do with the pty.

One fix while passing through: `MainThreadHandler` now calls `super(Looper.getMainLooper())`
explicitly. Upstream relies on the session being constructed on the main thread, which held for
Termux and does not hold here — bindings are created from a view model.

`TerminalSessionClient` is unmodified, including `setTerminalShellPid`, which Terminal Deck
implements as a no-op. Leaving a dead method on the interface is cheaper than a diff that makes the
next re-vendor a merge.
