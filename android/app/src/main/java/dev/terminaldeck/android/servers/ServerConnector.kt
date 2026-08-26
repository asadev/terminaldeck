package dev.terminaldeck.android.servers

import dev.terminaldeck.android.protocol.EnrollMethod
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Something that went wrong with one server, as two sentences a screen prints.
 *
 * [SshProblem]'s own shape, kept as its own type because not everything that can go wrong with a
 * server is an SSH failure — a store that would not write, an installer this build does not carry
 * — and reporting those as *"that sign-in was refused"* would send somebody to check a password
 * that is perfectly correct.
 */
data class ServerTrouble(val headline: String, val advice: String) {
    constructor(problem: SshProblem) : this(problem.headline, problem.advice)
}

/** What a look at one server came back with. Stamped, because nothing here refreshes on its own. */
data class ServerView(val host: HostLook, val measuredAt: Long)

/** Where an install has got to. The desktop's `HostState`, with its own words. */
data class ServerInstallState(
    val step: Step = Step.IDLE,
    /** The one line under the output. Written here, never in a view. */
    val line: String = "",
    /** The server's own words when something failed. Shown behind a disclosure. */
    val detail: String = "",
    /** Every step that has finished, in order, each already a sentence. */
    val done: List<String> = emptyList(),
    /** What the installer printed, as it printed it. */
    val output: String = "",
) {
    enum class Step { IDLE, CHECKING, STAGING, INSTALLING, SERVICE, REMOVING, DONE, FAILED }

    val isBusy: Boolean
        get() = step == Step.CHECKING || step == Step.STAGING ||
            step == Step.INSTALLING || step == Step.SERVICE || step == Step.REMOVING
}

/** Where an attempt to log in to a server has got to. */
sealed interface LoginPhase {
    data object Editing : LoginPhase

    /** Opening the socket and checking the server's identity. */
    data object Reaching : LoginPhase

    /** Signed in; asking the server what is on it. */
    data object Looking : LoginPhase

    data class Added(val server: StoredServer) : LoginPhase

    data class Failed(val headline: String, val advice: String) : LoginPhase
}

/** Everything the login screen and the host-step card draw. */
data class ServersState(
    val servers: List<StoredServer> = emptyList(),
    /** The last look at each server, by server id. Absent means never looked. */
    val views: Map<String, ServerView> = emptyMap(),
    /** Which servers have something in flight, so a screen can disable its buttons. */
    val working: Set<String> = emptySet(),
    /** The last failure per server, shown until something else happens. */
    val problems: Map<String, ServerTrouble> = emptyMap(),
    val installs: Map<String, ServerInstallState> = emptyMap(),
    val login: LoginPhase = LoginPhase.Editing,
    /**
     * This app's own build, carried on the state so a screen can compare it against what a server
     * is running without reaching into the connector for it. What [HostProbe.updateAvailable] and
     * the Update button are decided from. Empty in a unit-tested default, which reads as "say
     * nothing" — the safe answer when there is no build to compare against.
     */
    val appVersion: String = "",
) {
    val isSigningIn: Boolean get() = login is LoginPhase.Reaching || login is LoginPhase.Looking
}

/**
 * The phone's server connector: sign in, look, install, start, stop — the whole of what the
 * desktop's `ServersPanel` does, on a phone, over the phone's own SSH connection.
 *
 * ## The requirement, in his words
 *
 * > *"I want it to work exactly like it works for MacBook. Say no MacBook or Windows exists at
 * > all — a user only has a server and a phone… The steps should be: first they log in to the
 * > server. Then all the server-related stuff comes up… Then it checks whether the headless
 * > Terminal Deck already exists on that server. If it exists, it brings it up and asks you to
 * > connect. If it does not exist, it gives the option to install."*
 *
 * That is the order this object executes and the order [dev.terminaldeck.android.ui.HostStepCard]
 * draws. There is no step in it where somebody is handed a command to go and type somewhere else,
 * and the one that used to exist — `INSTALL_COMMAND`, a `curl … | sh` on the add-a-server screen —
 * is deleted rather than moved. *"I don't want that command."*
 *
 * ## Nothing is held open, and nothing is polled
 *
 * His standing rule: **events, not polling** — *"they make the system heavier."* A connection is
 * opened for a piece of work and closed when it ends, so a server nobody is looking at costs this
 * phone nothing. The consequence, which must not be "fixed" with a timer: **what is on screen can
 * be stale**, and the measurement time is carried rather than hidden.
 *
 * The one thing that is held is the session belonging to a server whose card is open — [open]
 * keeps it and [release] drops it — because check, install and start are three round trips
 * somebody makes in a row, and re-running a handshake between them would be three sign-ins for one
 * visit.
 *
 * ## Not a ViewModel, and not Android
 *
 * A plain class with a [StateFlow], held by `DeckViewModel` so it survives a rotation mid-install.
 * It touches no Android type at all — the SSH client is a seam, the scripts are a seam, the store
 * is an interface — which is what lets the whole of the check/install/start order be exercised by
 * `./gradlew test` rather than only by a person holding a phone.
 */
class ServerConnector(
    private val store: ServerStore,
    private val scripts: ScriptLibrary,
    private val dialer: SshDialer = SshDialer.real,
    /** This app's build. What [ServerScripts.hostPackage] derives the release asset from. */
    private val appVersion: String,
    private val now: () -> Long = System::currentTimeMillis,
) {

    /**
     * The most installer output kept.
     *
     * Enough to see what failed, bounded so a build that decides to print a line a second cannot
     * become this app's heap.
     */
    private val maxOutputChars = 256 * 1024

    /**
     * How long an install gets before this side stops believing it is running.
     *
     * The desktop's ceiling, and it is generous for a reason: a server with no Node fetches a
     * runtime, and node-pty compiles.
     */
    private val installTimeoutMs = 12 * 60 * 1000L

    private val _state = MutableStateFlow(ServersState(servers = store.all(), appVersion = appVersion))
    val state: StateFlow<ServersState> = _state.asStateFlow()

    /** Sessions belonging to open cards. See the header. */
    private val sessions = mutableMapOf<String, SshLink>()

    /* ------------------------------------------------------------ signing in -- */

    fun resetLogin() {
        _state.value = _state.value.copy(login = LoginPhase.Editing)
    }

    /**
     * Sign in to a server for the first time.
     *
     * The port is a real question and not a detail: Asad's own machine has listened on **2222**,
     * and a form that quietly assumed 22 told him his server was off. Empty means 22 and the field
     * says so.
     *
     * The host key is taken on trust the first time — there is nothing to compare it against yet —
     * and written down. Every connection after this one is checked against it, and a server that
     * answers with a different key is refused before a password is offered.
     */
    suspend fun signIn(
        name: String,
        address: String,
        port: Int?,
        username: String,
        secret: String,
        kind: ServerCredentialKind,
    ) {
        if (_state.value.isSigningIn) return
        val cleanAddress = address.trim()
        val cleanUser = username.trim()
        if (cleanAddress.isEmpty()) {
            return fail(
                "That sign-in needs an address.",
                "The name or number you would put after `ssh` — a hostname or an IP address.",
            )
        }
        if (cleanUser.isEmpty()) {
            return fail(
                "That sign-in needs a username.",
                "The account you would use to sign in to that server.",
            )
        }
        // Not trimmed: a password may legitimately begin or end with a space, and a private key
        // ends with a newline that is part of the format.
        if (secret.isEmpty()) {
            return fail(
                if (kind == ServerCredentialKind.PASSWORD) {
                    "That sign-in needs a password."
                } else {
                    "That sign-in needs a key."
                },
                if (kind == ServerCredentialKind.PASSWORD) {
                    "The password for that account on that server."
                } else {
                    "Paste the private key for that account, including its BEGIN and END lines."
                },
            )
        }
        val realPort = port ?: ServerStore.DEFAULT_PORT
        if (realPort < 1 || realPort > 65535) {
            return fail(
                ServerDraftProblem.BadPort.sentence,
                "Whoever set the server up will know which port it listens on.",
            )
        }

        _state.value = _state.value.copy(login = LoginPhase.Reaching)
        val auth = if (kind == ServerCredentialKind.KEY) SshAuth.Key(secret) else SshAuth.Password(secret)
        try {
            val session = dialer.open(cleanAddress, realPort, cleanUser, auth, expect = null)
            _state.value = _state.value.copy(login = LoginPhase.Looking)
            val look = measure(session)
            val server = store.add(
                name = name,
                address = cleanAddress,
                port = realPort,
                username = cleanUser,
                secret = secret,
                kind = kind,
                hostKey = session.hostKey,
            )
            sessions[server.id] = session
            _state.value = _state.value.copy(
                servers = store.all(),
                views = _state.value.views + (server.id to look),
                login = LoginPhase.Added(server),
            )
        } catch (e: SshException) {
            fail(e.problem.headline, e.problem.advice)
        } catch (e: ServerDraftException) {
            fail(e.problem.sentence, "")
        } catch (e: Exception) {
            fail("That sign-in did not finish.", e.toString())
        }
    }

    private fun fail(headline: String, advice: String) {
        _state.value = _state.value.copy(login = LoginPhase.Failed(headline, advice))
    }

    /* --------------------------------------------------------------- looking -- */

    /**
     * Ask a server whether the host is on it.
     *
     * One script and one round trip on the connection this phone already holds — the desktop asks
     * two, because it also draws a panel of machine facts (services, listeners, containers) that
     * this app has no screen for. Shipping the second probe so that nothing reads it would be a
     * script to keep in step for a feature that does not exist.
     */
    suspend fun look(id: String) {
        val server = store.load(id) ?: return
        if (_state.value.working.contains(id)) return
        begin(id)
        try {
            val session = open(server)
            val view = measure(session)
            store.save(server.copy(lastConnectedAt = now()))
            _state.value = _state.value.copy(
                servers = store.all(),
                views = _state.value.views + (id to view),
            )
        } catch (e: SshException) {
            trouble(id, ServerTrouble(e.problem))
            drop(id)
        } catch (e: Exception) {
            trouble(id, ServerTrouble(SshProblem.Lost))
            drop(id)
        } finally {
            end(id)
        }
    }

    private suspend fun measure(session: SshLink): ServerView {
        val host = session.run(scripts.hostProbe())
        return ServerView(host = HostProbe.read(host.stdout), measuredAt = now())
    }

    /* ------------------------------------------------------------ installing -- */

    /**
     * Put the headless host on a server, as five steps somebody watches happen.
     *
     * Check, stage, install, start, look again — the desktop's order, minus its upload of a
     * tarball. The phone cannot carry a Node package it does not build, so it sends the installer
     * and **names the release asset for this app's own version** for the installer to fetch. See
     * [ServerScripts.hostPackage] for why that is not `terminaldeck@latest`.
     */
    suspend fun install(id: String) {
        val server = store.load(id) ?: return
        if (_state.value.working.contains(id)) return
        begin(id)

        var state = ServerInstallState()
        fun step(next: ServerInstallState.Step, line: String) {
            state = state.copy(step = next, line = line)
            putInstall(id, state)
        }
        fun failInstall(line: String, detail: String = "") {
            state = state.copy(step = ServerInstallState.Step.FAILED, line = line, detail = detail)
            putInstall(id, state)
        }

        try {
            step(ServerInstallState.Step.CHECKING, "Checking what ${server.name} has.")
            val session = open(server)
            val look = HostProbe.read(session.run(scripts.hostProbe()).stdout)
            val refusal = HostProbe.whyNot(look.room)
            if (refusal != null) {
                failInstall(refusal)
                return
            }
            state = state.copy(
                done = state.done + if (HostProbe.usableNode(look.room)) {
                    "${server.name} has Node ${look.room.node} and npm, so no runtime is needed."
                } else {
                    "${server.name} has no Node 22 or newer, so the installer will fetch one and " +
                        "check it against the checksum Node published for it."
                }
            )

            val installer = scripts.installer()
            if (installer == null) {
                failInstall(
                    "This copy of the app does not carry the installer, so there is nothing here " +
                        "to install from."
                )
                return
            }

            step(ServerInstallState.Step.STAGING, "Copying the installer to ${server.name}.")
            val staged = ServerScripts.stageInstaller(installer)
            val put = session.run(staged.script)
            val path = put.stdout.trim()
            if (put.code != 0 || path.isEmpty()) {
                failInstall(
                    "The installer could not be written to ${server.name}.",
                    put.stderr.ifEmpty { "It ended with ${put.code}." },
                )
                return
            }
            state = state.copy(done = state.done + "Copied the installer to $path.")

            step(
                ServerInstallState.Step.INSTALLING,
                "Installing Terminal Deck $appVersion on ${server.name}. This takes a minute or two.",
            )
            val ran = session.stream(
                command = ServerScripts.runInstaller(path, appVersion),
                stdin = null,
                timeoutMs = installTimeoutMs,
            ) { chunk -> appendOutput(id, chunk) }
            state = state.copy(output = _state.value.installs[id]?.output ?: state.output)
            if (ran.code != 0) {
                failInstall(
                    "The host could not be installed on ${server.name}.",
                    "The installer ended with ${ran.code}. Its own output is above.",
                )
                return
            }

            val after = HostProbe.read(session.run(scripts.hostProbe()).stdout)
            if (!after.host.isInstalled) {
                failInstall("The install finished and there is no terminaldeck command on this server.")
                return
            }
            state = state.copy(
                done = state.done + ("Installed " +
                    after.host.version.ifEmpty { "the host" } + " at ${after.host.command}.")
            )

            step(ServerInstallState.Step.SERVICE, "Setting it to start on its own.")
            state = state.copy(done = state.done + arrangeStart(session, after))

            // Deliberately not rethrowing. The install is finished and said so; a look that fails
            // after it would otherwise report a working install as a failed one, which is the worst
            // of the four possible answers.
            val view = try {
                measure(session)
            } catch (e: Exception) {
                null
            }
            state = state.copy(
                step = ServerInstallState.Step.DONE,
                line = "${server.name} is a machine of its own now.",
            )
            putInstall(id, state)
            if (view != null) {
                _state.value = _state.value.copy(views = _state.value.views + (id to view))
            }
        } catch (e: SshException) {
            failInstall(e.problem.headline, e.problem.advice)
            drop(id)
        } catch (e: Exception) {
            failInstall("The install did not finish.", e.toString())
            drop(id)
        } finally {
            end(id)
        }
    }

    /**
     * The installer's own words, as they arrive, with a ceiling.
     *
     * The tail is kept rather than the head: what failed is at the end.
     */
    private fun appendOutput(id: String, chunk: String) {
        val current = _state.value.installs[id] ?: ServerInstallState()
        var text = current.output + chunk
        if (text.length > maxOutputChars) text = text.takeLast(maxOutputChars / 2)
        putInstall(id, current.copy(output = text))
    }

    /**
     * Make it start on its own, and say what was actually arranged.
     *
     * Three outcomes and all three are said out loud, because the difference between them is the
     * difference between a machine that is there tomorrow and one that is not. The third is not a
     * failure of the install and is not reported as one: a container has no init by design, and a
     * host running now is what somebody pressed the button for.
     */
    private suspend fun arrangeStart(session: SshLink, look: HostLook): String {
        if (look.room.systemdUser) {
            val unit = try {
                session.run(ServerScripts.service(look.host.command))
            } catch (e: Exception) {
                null
            }
            if (unit != null && unit.code == 0) {
                return if (unit.stdout.contains("linger yes")) {
                    "It runs as a systemd user service and keeps running when you log out."
                } else {
                    "It runs as a systemd user service. It will stop when your last login on this " +
                        "server ends — running `sudo loginctl enable-linger \$(id -un)` once on " +
                        "that server is what stops that."
                }
            }
            /*
             * **On a systemd box, a unit that did not come up is not started another way — it is
             * reported.**
             *
             * The old fall-through here went on to [ServerScripts.startDirect], a bare start over
             * the SSH session that is being closed the moment this install returns. On a machine
             * that has systemd — the machine that *should* be running under it — that "recovery"
             * starts a host that dies with the connection, which is one of the two ways an update
             * left a server dark on 2026-08-27: the files updated, the unit did not take, and a bare
             * host filled the gap only until the phone hung up. That is the shape of Asad's report —
             * *"after updating server app it keeps reconnecting… server is still connected but not
             * the sessions"*. The hardened [ServerScripts.service] now proves the unit is active
             * before it exits 0, so a non-zero code here means it genuinely could not, and the
             * honest answer is to say so and point at the control that retries — not to paper over
             * it with a start that cannot outlive this call.
             */
            return "It is installed and updated, but its background service did not come back up. " +
                "`terminaldeck status` on the server says why; the Start button here brings it up."
        }
        val started = try {
            session.run(ServerScripts.startDirect(look.host.command))
        } catch (e: Exception) {
            null
        }
        return if (started?.code == 0) {
            "This server has no systemd user manager, so it was started directly. It is running " +
                "now and will not come back on its own after a reboot."
        } else {
            "It is installed and not running. Starting it is the button above."
        }
    }

    /* ------------------------------------------------------------ start & stop -- */

    suspend fun start(id: String) = control(id, running = true)

    suspend fun stop(id: String) = control(id, running = false)

    private suspend fun control(id: String, running: Boolean) {
        val server = store.load(id) ?: return
        val look = _state.value.views[id]?.host ?: return
        if (_state.value.working.contains(id)) return
        begin(id)
        try {
            val session = open(server)
            val script = if (running) {
                ServerScripts.start(
                    command = look.host.command,
                    hasUnit = look.host.unit.isNotEmpty(),
                    systemdUser = look.room.systemdUser,
                )
            } else {
                ServerScripts.stop(command = look.host.command, hasUnit = look.host.unit.isNotEmpty())
            }
            session.run(script)
            if (running) {
                /*
                 * **Started is not reachable**, and the difference is the whole of the bug this
                 * closes.
                 *
                 * Both start scripts return the instant the daemon is forked — `systemctl start`
                 * by design, `nohup` by definition — while the thing a phone actually needs is a
                 * *relay dial* that has not happened yet. So the survey below read a `status` with
                 * no address block, [canConnect] answered false, and "start it and connect" started
                 * it and connected to nothing, silently. [ServerScripts.address] is the wait, and
                 * it is the host's own — it knows how old the daemon is and stops waiting when the
                 * answer cannot improve. Its result is ignored on purpose; what this call buys is
                 * the seconds, and the survey on the next line is what reads the answer.
                 *
                 * Swallowed rather than rethrown: an older host has no `address` verb, and a host
                 * that will not start has already failed in a way the survey reports properly.
                 * Neither is a reason to throw away a measurement that would have said so. `working`
                 * still holds `id` for all of this — deliberately, so the spinner is still turning
                 * while the wait happens rather than the card sitting still and looking done.
                 */
                try {
                    session.run(ServerScripts.address(look.host.command))
                } catch (e: Exception) {
                    // Handled by the survey below, which is the one that reports the true state.
                }
            }
            _state.value = _state.value.copy(views = _state.value.views + (id to measure(session)))
        } catch (e: SshException) {
            trouble(id, ServerTrouble(e.problem))
            drop(id)
        } catch (e: Exception) {
            trouble(id, ServerTrouble(SshProblem.Lost))
            drop(id)
        } finally {
            end(id)
        }
    }

    /**
     * Start the host if it is here and not running, then look again.
     *
     * *"If it exists, it brings it up and asks you to connect."* Two verbs somebody would otherwise
     * press in sequence, joined — because the screen that offers this is the one immediately after
     * a login, where the person has said what they want and should not have to press Start, wait,
     * read, and then press Connect.
     */
    suspend fun bringUp(id: String) {
        val look = _state.value.views[id]?.host ?: return
        if (!look.host.isInstalled) return
        if (look.host.running != HostRunning.YES) start(id)
    }

    /* ------------------------------------------------------------- removing -- */

    /**
     * Take it off that server again, and say what is left.
     *
     * ## Why this exists at all
     *
     * Because the install card promised it: *"needs no administrator access, and can be taken off
     * again."* That sentence was on screen for a build in which no verb on this side could remove
     * anything — the phone had install, start and stop, and the way back was a desktop. A promise a
     * product cannot keep is worse than a missing feature, and the desktop had already argued the
     * case in `host.ts`'s own header: *"If we want to uninstall we can uninstall."*
     *
     * ## The confirmation is the caller's
     *
     * [HostProbe.removeConsequence] is the sentence shown before the press, and [alsoData] is the
     * answer to it. By the time this runs the question has been asked, so this does the work and
     * reports it rather than asking again — the desktop's `ServerHosts.uninstall` splits it the
     * same way and for the same reason.
     *
     * ## What is deliberately left alone
     *
     * This phone's own record of the machine. The host is gone from that server, but the server row
     * and its pairing are this app's, not that server's. What *is* re-read is the survey, because
     * the card is drawn from it and it must not still be offering Stop for a program that is gone.
     */
    suspend fun uninstall(id: String, alsoData: Boolean) {
        val server = store.load(id) ?: return
        val look = _state.value.views[id]?.host ?: return
        if (!look.host.isInstalled || _state.value.working.contains(id)) return
        begin(id)

        var state = ServerInstallState(
            step = ServerInstallState.Step.REMOVING,
            line = "Stopping it and taking it off ${server.name}.",
        )
        putInstall(id, state)

        try {
            val session = open(server)
            val ran = session.run(
                ServerScripts.remove(
                    command = look.host.command,
                    dataDir = look.host.dataDir,
                    alsoData = alsoData,
                )
            )
            if (ran.code != 0) {
                // The server's own words, and the exit code when it had none. The one refusal with
                // a shape worth reading is the `$HOME` guard in [ServerScripts.remove]: "not ours
                // to remove", for a host somebody else installed for everyone on that machine.
                val said = ran.stderr.trim()
                state = state.copy(
                    step = ServerInstallState.Step.FAILED,
                    line = "That could not be removed from ${server.name}.",
                    detail = said.ifEmpty { "It ended with ${ran.code}." },
                )
                putInstall(id, state)
                return
            }
            state = state.copy(
                step = ServerInstallState.Step.DONE,
                line = "It was removed from ${server.name}.",
                done = listOf(
                    "The host program is gone, and its service with it.",
                    if (alsoData) {
                        "${look.host.dataDir} is gone too, so any device paired to it will need " +
                            "pairing again."
                    } else {
                        "${look.host.dataDir} was left alone — the devices paired to it and the " +
                            "folders each of them may use are still there for a later install."
                    },
                ),
            )
            putInstall(id, state)
            // A survey that fails a moment later must not turn a completed removal into a failed
            // one; the card falls back to "nothing has been looked at" and its Check button, which
            // is a true thing to say about a phone that has just lost its connection.
            val view = try {
                measure(session)
            } catch (e: Exception) {
                null
            }
            if (view != null) {
                _state.value = _state.value.copy(views = _state.value.views + (id to view))
            }
        } catch (e: SshException) {
            state = state.copy(
                step = ServerInstallState.Step.FAILED,
                line = e.problem.headline,
                detail = e.problem.advice,
            )
            putInstall(id, state)
            drop(id)
        } catch (e: Exception) {
            state = state.copy(
                step = ServerInstallState.Step.FAILED,
                line = "That removal did not finish.",
                detail = e.toString(),
            )
            putInstall(id, state)
            drop(id)
        } finally {
            end(id)
        }
    }

    /* ------------------------------------------------------------- connecting -- */

    /** What a connect needs, or null when this server cannot be connected to yet. */
    data class ConnectTicket(
        val address: String,
        val username: String,
        val secret: String,
        val method: EnrollMethod,
    )

    /**
     * The address and the login a connect spends, or null.
     *
     * The connect itself is `signin/ServerSignIn.kt` — the door that already exists, over the
     * relay, spending the same SSH login this phone already holds. Nothing new is invented for it:
     * the host verifies that login against its own sshd and mints a device credential, exactly as
     * it does for an address somebody pasted.
     */
    fun connectTicket(id: String): ConnectTicket? {
        val server = store.load(id) ?: return null
        val host = _state.value.views[id]?.host?.host ?: return null
        if (host.address.isEmpty()) return null
        val secret = store.secret(id) ?: run {
            trouble(
                id,
                ServerTrouble(
                    "That sign-in could not be read.",
                    "Log in to this server again and it will be saved.",
                ),
            )
            return null
        }
        clearTrouble(id)
        return ConnectTicket(
            address = host.address,
            username = server.username,
            secret = secret,
            method = if (server.credential == ServerCredentialKind.KEY) EnrollMethod.Key else EnrollMethod.Password,
        )
    }

    /**
     * Whether a Connect can even be offered without a prompt-and-fail: the same two questions
     * [connectTicket] asks before it touches the store.
     */
    fun canConnect(id: String): Boolean {
        val host = _state.value.views[id]?.host?.host ?: return false
        return host.address.isNotEmpty() && store.load(id) != null
    }

    /** Remember which machine row this server became, so the card can say "connected". */
    fun markConnected(id: String, hostId: String) {
        val server = store.load(id) ?: return
        store.save(server.copy(linkedHostId = hostId, lastConnectedAt = now()))
        _state.value = _state.value.copy(servers = store.all())
    }

    fun markDisconnected(id: String) {
        val server = store.load(id) ?: return
        store.save(server.copy(linkedHostId = null))
        _state.value = _state.value.copy(servers = store.all())
    }

    /* ------------------------------------------------------------------ rest -- */

    fun rename(id: String, name: String) {
        val server = store.load(id) ?: return
        val clean = name.trim()
        if (clean.isEmpty()) return
        store.save(server.copy(name = clean.take(ServerStore.MAX_NAME)))
        _state.value = _state.value.copy(servers = store.all())
    }

    /**
     * Forget a server here.
     *
     * Nothing on the far end changes — this phone stops holding its address and its sign-in, and
     * that is all.
     */
    fun forget(id: String) {
        drop(id)
        store.forget(id)
        _state.value = _state.value.copy(
            servers = store.all(),
            views = _state.value.views - id,
            problems = _state.value.problems - id,
            installs = _state.value.installs - id,
        )
    }

    fun server(id: String): StoredServer? = _state.value.servers.firstOrNull { it.id == id }

    /** Drop the session belonging to a card that has closed. */
    fun release(id: String) = drop(id)

    /** Every held connection, on the way out of the app. */
    fun releaseAll() {
        sessions.values.forEach { it.close() }
        sessions.clear()
    }

    /* ---------------------------------------------------------------- inside -- */

    private suspend fun open(server: StoredServer): SshLink {
        sessions[server.id]?.let { if (it.isOpen) return it }
        sessions.remove(server.id)
        val secret = store.secret(server.id) ?: SshProblem.SignInRefused.raise()
        val session = dialer.open(
            address = server.address,
            port = server.port,
            username = server.username,
            auth = if (server.credential == ServerCredentialKind.KEY) {
                SshAuth.Key(secret)
            } else {
                SshAuth.Password(secret)
            },
            expect = server.hostKey?.fingerprint,
        )
        sessions[server.id] = session
        return session
    }

    private fun drop(id: String) {
        sessions.remove(id)?.close()
    }

    private fun begin(id: String) {
        _state.value = _state.value.copy(
            working = _state.value.working + id,
            problems = _state.value.problems - id,
        )
    }

    private fun end(id: String) {
        _state.value = _state.value.copy(working = _state.value.working - id)
    }

    private fun trouble(id: String, trouble: ServerTrouble) {
        _state.value = _state.value.copy(problems = _state.value.problems + (id to trouble))
    }

    private fun clearTrouble(id: String) {
        _state.value = _state.value.copy(problems = _state.value.problems - id)
    }

    private fun putInstall(id: String, install: ServerInstallState) {
        _state.value = _state.value.copy(installs = _state.value.installs + (id to install))
    }
}
