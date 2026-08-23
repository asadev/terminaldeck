/**
 * Reading what a server answered — both scripts, against output a real server
 * really produced.
 *
 * ## Where the fixtures came from
 *
 * Not invented. Both were captured from a live Ubuntu 24.04 box over this app's
 * own SSH client, running `ProbeScripts.server` and `ProbeScripts.host`
 * unmodified, and then had the machine's own name, address and site redacted —
 * a repository is a public place and a stranger's service inventory does not
 * belong in one. Everything that decides a branch in the reader is exactly what
 * that machine said: `node v18.19.1` with **no npm**, an empty `command`,
 * `systemd_user yes`, `containers=docker`, a `listeners` section with a mix of
 * rows that name a program and rows that do not.
 *
 * That last detail is the one worth having a real capture for. `ss -tlnp` prints
 * the program only for sockets the sign-in is allowed to see, so a two-state
 * reader turns "this account may not ask" into "nothing is listening" — the
 * exact failure `facts.ts` has three states to prevent.
 */

import XCTest
@testable import TerminalDeck

final class ServerProbeReadingTests: XCTestCase {

    // MARK: - The host that is not there

    func testReadsABareServerAsHavingNoHost() {
        let look = HostProbe.read(Self.hostProbeBare)
        XCTAssertFalse(look.host.isInstalled)
        XCTAssertEqual(look.host.running, .unknown)
        XCTAssertEqual(look.room.os, "linux")
        XCTAssertEqual(look.room.node, "v18.19.1")
        XCTAssertEqual(look.room.npm, "")
        XCTAssertTrue(look.room.systemdUser)
        XCTAssertEqual(look.room.homeFreeKb, 32_906_336)
        XCTAssertEqual(look.host.dataDir, "/root/.local/share/terminaldeck")
    }

    /// Node 18 with no npm is not a usable Node, and the difference decides
    /// whether the installer fetches 120 MB or none.
    func testNode18WithoutNpmIsNotUsable() {
        XCTAssertFalse(HostProbe.usableNode(HostProbe.read(Self.hostProbeBare).room))
        var room = HostRoom()
        room.node = "v22.23.2"
        room.npm = "/usr/bin/npm"
        XCTAssertTrue(HostProbe.usableNode(room))
        room.npm = ""
        XCTAssertFalse(HostProbe.usableNode(room), "Node without npm cannot install anything")
    }

    /// A machine that can take the host offers the button; every refusal names
    /// the machine's own reason instead of drawing a control that cannot act.
    func testOffersTheInstallOnAMachineThatCanTakeIt() {
        XCTAssertNil(HostProbe.whyNot(HostProbe.read(Self.hostProbeBare).room))
    }

    func testRefusesMuslWithTheReasonAndTheWayRound() {
        var room = HostProbe.read(Self.hostProbeBare).room
        room.libc = "musl"
        let why = HostProbe.whyNot(room)
        XCTAssertNotNil(why)
        XCTAssertTrue(why!.contains("musl"))
        XCTAssertTrue(why!.contains("apk add"))
    }

    func testRefusesALinuxBoxWithNoCompilerAndNamesTheMissingTools() {
        var room = HostProbe.read(Self.hostProbeBare).room
        room.missingTools = ["make", "g++"]
        let why = HostProbe.whyNot(room)
        XCTAssertTrue(why?.contains("make, g++") == true)
        XCTAssertTrue(why?.contains("apt-get install -y make g++") == true)
    }

    func testRefusesAServerWithNoRoomAndSaysHowMuch() {
        var room = HostProbe.read(Self.hostProbeBare).room
        room.homeFreeKb = 50 * 1024
        XCTAssertTrue(HostProbe.whyNot(room)?.contains("50 MB free") == true)
    }

    func testRefusesWindows() {
        var room = HostRoom()
        room.os = "mingw64_nt-10.0"
        XCTAssertTrue(HostProbe.whyNot(room)?.contains("desktop app") == true)
    }

    // MARK: - The host that is there

    func testReadsARunningHostAndTheAddressItPrints() {
        let look = HostProbe.read(Self.hostProbeRunning)
        XCTAssertTrue(look.host.isInstalled)
        XCTAssertEqual(look.host.version, "0.10.0")
        XCTAssertEqual(look.host.running, .yes)
        XCTAssertEqual(look.host.unit, "active")
        XCTAssertTrue(look.host.linger)
        XCTAssertEqual(HostProbe.relay(in: look.host.status), .connected)
        XCTAssertEqual(HostProbe.channels(in: look.host.status), 0)
        XCTAssertTrue(look.host.address.hasPrefix("srv1."))
        XCTAssertNil(HostProbe.connectRefusal(look.host))
    }

    func testReadsAStoppedHostAsStoppedRatherThanMissing() {
        let look = HostProbe.read(Self.hostProbeStopped)
        XCTAssertTrue(look.host.isInstalled)
        XCTAssertEqual(look.host.running, .no)
        XCTAssertTrue(HostProbe.line(look.host).contains("is not running"))
        XCTAssertTrue(HostProbe.connectRefusal(look.host)?.contains("Start it first") == true)
    }

    /**
     * A host that answered `--version` and printed no status at all.
     *
     * The third state, and the reason it exists: reporting this as "running"
     * would put a claim on screen that nobody measured, and reporting it as
     * "not running" would send somebody to press Start on a host that is up.
     */
    func testAHostThatWillNotSayIsReportedAsNotHavingSaid() {
        let look = HostProbe.read("command\t/root/.local/bin/terminaldeck\nversion\t0.6.1\n")
        XCTAssertEqual(look.host.running, .unknown)
        XCTAssertTrue(HostProbe.line(look.host).contains("would not say"))
    }

    /// A host with no server address is a host a phone cannot dial, and the
    /// sentence has to name the real reason rather than offering a dead button.
    func testSaysWhyAPhoneCannotConnectToAnOlderHost() {
        var host = HostOnServer()
        host.command = "/root/.local/bin/terminaldeck"
        host.version = "0.6.1"
        host.running = .yes
        host.status = "Relay\nconnected to wss://relay.terminaldeck.dev\n  channels 0\n"
        XCTAssertEqual(host.address, "")
        let refusal = HostProbe.connectRefusal(host)
        XCTAssertTrue(refusal?.contains("older") == true, "got: \(refusal ?? "nil")")
    }

    func testSaysWhenTheRelayIsOffRatherThanBlamingTheVersion() {
        var host = HostOnServer()
        host.command = "/root/.local/bin/terminaldeck"
        host.version = "0.10.0"
        host.running = .yes
        host.status = "Relay\noff\n"
        XCTAssertTrue(HostProbe.connectRefusal(host)?.contains("relay switched off") == true)
    }

    /// Whether it will still be there tomorrow is a different question from
    /// whether it is running now, and each answer names what would change it.
    func testTellsTheTruthAboutSurvivingALogout() {
        var host = HostOnServer()
        host.command = "/root/.local/bin/terminaldeck"
        XCTAssertTrue(HostProbe.reachLine(host)?.contains("reboots") == true)
        host.unit = "active"
        XCTAssertTrue(HostProbe.reachLine(host)?.contains("enable-linger") == true)
        host.linger = true
        XCTAssertTrue(HostProbe.reachLine(host)?.contains("keeps running") == true)
    }

    // MARK: - The machine

    func testReadsARealServersFacts() {
        let facts = ServerProbe.read(Self.serverProbe)
        XCTAssertEqual(facts.os.value, "Ubuntu 24.04.4 LTS")
        XCTAssertEqual(facts.kernel.value, "Linux 6.8.0-137-generic")
        XCTAssertEqual(facts.arch.value, "x86_64")
        XCTAssertEqual(facts.user.value, "root")
        XCTAssertEqual(facts.privilege.value, "yes")
        XCTAssertEqual(facts.initSystem.value, "systemd")
        XCTAssertEqual(facts.containerRuntime.value, "docker")
        XCTAssertEqual(facts.packageManager.value, "apt-get")
        XCTAssertEqual(facts.webServer.value, "caddy")
        XCTAssertEqual(facts.cpus.value, 2)
        XCTAssertEqual(facts.disk.value?.totalKb, 39_020_108)
        XCTAssertEqual(facts.memory.value?.totalKb, 3_911_564)
        XCTAssertEqual(facts.load1.value, 0)
        XCTAssertEqual(facts.uptimeSeconds.value, 674_104)
    }

    func testSeparatesWhatIsRunningFromWhatIsMerelyThere() {
        let facts = ServerProbe.read(Self.serverProbe)
        let services = facts.services.value ?? []
        XCTAssertEqual(services.count, 5)
        XCTAssertEqual(services.filter(\.isRunning).map(\.name),
                       ["caddy.service", "docker.service", "ssh.service"])
        XCTAssertEqual(services.first?.detail, "ACPI event daemon")
    }

    func testReadsListenersIncludingTheOnesWithNoProgramNamed() {
        let listeners = ServerProbe.read(Self.serverProbe).listeners.value ?? []
        XCTAssertEqual(listeners.count, 3)
        XCTAssertEqual(listeners.first?.port, "22")
        XCTAssertEqual(listeners.first?.program, "sshd")
        XCTAssertEqual(listeners.last?.program, "", "a socket this account may not ask about")
        XCTAssertEqual(listeners.last?.port, "443")
    }

    func testReadsContainersAndTheSitesTheWebServerNames() {
        let facts = ServerProbe.read(Self.serverProbe)
        XCTAssertEqual(facts.containers.value?.count, 1)
        XCTAssertEqual(facts.containers.value?.first?.image, "redis:7")
        XCTAssertTrue(facts.containers.value?.first?.isRunning == true)
        XCTAssertEqual(facts.siteNames.value, ["example.test"])
    }

    /**
     * `cannot` is not `no`.
     *
     * A sign-in that may not ask about containers is a fact about the account. A
     * two-state reader records it as "no containers" — on a machine whose
     * containers are the whole point of it.
     */
    func testAnAccountThatMayNotAskIsNotAServerWithNothingToShow() {
        let facts = ServerProbe.read("containers=present-no-permission\n#end ok\n")
        XCTAssertNil(facts.containerRuntime.value)
        XCTAssertTrue(facts.containerRuntime.refusal?.contains("not allowed") == true)
    }

    func testASectionThatCouldNotBeAskedCarriesTheServersOwnReason() {
        let facts = ServerProbe.read(
            "#listeners cannot this server has no tool installed for listing what is listening\n#end ok\n")
        XCTAssertEqual(facts.listeners.refusal,
                       "This server has no tool installed for listing what is listening.")
    }

    /// Output that stopped partway says so, rather than reporting emptiness.
    func testOutputThatWasCutOffSaysSoRatherThanClaimingNothingIsThere() {
        let facts = ServerProbe.read("os=Ubuntu\n")
        XCTAssertTrue(facts.services.refusal?.contains("stopped answering") == true)
    }

    /// Servers print things nobody asked for. One MOTD line must not cost the
    /// whole reading.
    func testIgnoresWhatTheServerVolunteers() {
        let facts = ServerProbe.read("""
        Welcome to Ubuntu 24.04.4 LTS
        mesg: ttyname failed: Inappropriate ioctl for device
        os=Ubuntu 24.04.4 LTS
        #end ok
        """)
        XCTAssertEqual(facts.os.value, "Ubuntu 24.04.4 LTS")
    }

    /// The empty answer for a web server is a fact about the machine — it was
    /// looked for and is not there — and the missing answer is not.
    func testNoWebServerIsAnAnswerAndAMissingLineIsNot() {
        XCTAssertEqual(ServerProbe.read("web=\n#end ok\n").webServer, .no(how: "looked for a web server"))
        XCTAssertNotNil(ServerProbe.read("#end ok\n").webServer.refusal)
    }

    // MARK: - Fixtures, captured from a live server and redacted

    private static let hostProbeBare = """
    os\tLinux
    arch\tx86_64
    libc\tgnu
    node\tv18.19.1
    npm\t
    tools\t
    fetch\tcurl
    hash\tsha256sum
    tar\tyes
    home_free_kb\t32906336
    state_dir\t/root/.local/share/terminaldeck
    systemd_user\tyes
    command\t
    """

    /// The address block carries `ServerAddressFixture.printedByAHost` — the
    /// literal output of the encoder a host calls, generated on the desktop side
    /// and checked by a vitest run. A typed-out token is what let four green
    /// suites ship parsers that refused every real address.
    private static let hostProbeRunning = """
    os\tLinux
    arch\tx86_64
    libc\tgnu
    node\tv22.23.2
    npm\t/root/.terminaldeck/runtime/bin/npm
    tools\t
    fetch\tcurl
    hash\tsha256sum
    tar\tyes
    home_free_kb\t32000000
    state_dir\t/root/.local/share/terminaldeck
    systemd_user\tyes
    unit\tactive
    linger\tyes
    state\tyes
    command\t/root/.local/bin/terminaldeck
    version\t0.10.0
    --- status ---
    Terminal Deck host 0.10.0

    Relay
      connected to wss://relay.terminaldeck.dev
      host id  7QK4M2N8
      channels 0

    Server address
      \(ServerAddressFixture.printedByAHost)
    """

    private static let hostProbeStopped = """
    os\tLinux
    arch\tx86_64
    libc\tgnu
    node\tv22.23.2
    npm\t/usr/bin/npm
    tar\tyes
    hash\tsha256sum
    fetch\tcurl
    systemd_user\tyes
    unit\tinactive
    command\t/root/.local/bin/terminaldeck
    version\t0.10.0
    --- status ---
    host: not running
    """

    private static let serverProbe = """
    schema=1
    os=Ubuntu 24.04.4 LTS
    kernel=Linux 6.8.0-137-generic
    arch=x86_64
    host=a-server
    user=root
    root=yes
    init=systemd
    containers=docker
    packages=apt-get
    web=caddy
    installer_fetch=curl
    installer_npm=
    mem_avail_kb=3328284
    home_free_kb=32906336
    cpus=2
    disk_used_kb=4496948
    disk_total_kb=39020108
    memory_total_kb=3911564
    memory_free_kb=3328284
    load1=0.00
    uptime_s=674104
    #services ok
    acpid.service\tinactive\tdead\tACPI event daemon
    apparmor.service\tactive\texited\tLoad AppArmor profiles
    caddy.service\tactive\trunning\tCaddy
    docker.service\tactive\trunning\tDocker Application Container Engine
    ssh.service\tactive\trunning\tOpenBSD Secure Shell server
    #containers ok
    cache\tredis:7\trunning\tUp 3 days\t127.0.0.1:6379->6379/tcp
    #listeners ok
    0.0.0.0\t22\tsshd\t882\tssh.service
    127.0.0.1\t2019\tcaddy\t761\tcaddy.service
    *\t443\t\t\t
    #sites ok
    example.test
    #adminunits ok
    syslog.service
    #agents ok
    #end ok
    """
}
