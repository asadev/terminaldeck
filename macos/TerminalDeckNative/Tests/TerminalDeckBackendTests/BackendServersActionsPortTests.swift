import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// The exact remaining expectations in actions.test.ts and recovery catalogue tests.
@Suite("Server actions TypeScript case parity")
struct BackendServersActionsPortTests {
    private var facts: BackendServersActionFacts { .init(privilege: .yes(.yes, measuredAt: 1, how: "asked"), initSystem: .yes(.systemd, measuredAt: 1, how: "asked"), containerRuntime: .yes(.docker, measuredAt: 1, how: "asked")) }
    private var repo: BackendServersCard { .init(id: "service:td-scratch.service", kind: .app, name: "td-scratch", running: true, managedBy: .systemd(unit: "td-scratch.service"), repoDir: "/opt/td-scratch") }
    private func container(_ engine: BackendServersKnownEngine? = nil, compose: Bool = true) -> BackendServersCard { .init(id: "container:c1", kind: engine == nil ? .app : .database, name: "web", running: true, managedBy: .container(runtime: .docker, name: "c1", compose: compose ? .init(project: "p", service: "web", workingDir: "/opt/p") : nil), engine: engine) }
    private func available(_ card: BackendServersCard, download: Bool = true, compose: Bool = true, facts: BackendServersActionFacts? = nil) -> BackendServersAvailability { BackendServersActions.availableActions(card, facts: facts ?? self.facts, canDownload: download, composeAvailable: compose) }
    @Test func administratorCommand() { #expect(BackendServersActions.serviceCommand(.systemd(unit: "x.service"), verb: .restart, facts: facts) == ["systemctl", "restart", "x.service"]) }
    @Test func noninteractiveSudoCommand() {
        var f = facts; f.privilege = .yes(.sudoPassword, measuredAt: 1, how: "asked")
        #expect(BackendServersActions.serviceCommand(.systemd(unit: "x.service"), verb: .stop, facts: f) == ["sudo", "-n", "systemctl", "stop", "x.service"])
        #expect(BackendServersActions.elevate(["whoami"], facts: f) == ["sudo", "-n", "whoami"])
    }
    @Test func openRCDialect() { #expect(BackendServersActions.serviceCommand(.openrc(service: "nginx"), verb: .restart, facts: facts) == ["rc-service", "nginx", "restart"]) }
    @Test func measuredContainerNeedsNoSudo() {
        var f = facts; f.privilege = .yes(.sudoPassword, measuredAt: 1, how: "asked")
        #expect(BackendServersActions.serviceCommand(.container(runtime: .docker, name: "c1", compose: nil), verb: .restart, facts: f) == ["docker", "restart", "c1"])
    }
    @Test func refusesUnsafeServiceName() { #expect(BackendServersActions.serviceCommand(.systemd(unit: "x; reboot"), verb: .stop, facts: facts) == nil) }
    @Test func exactBoundedLogsAndNoOpenRCJournal() {
        #expect(BackendServersActions.logCommand(.systemd(unit: "x.service"), lines: Double(BackendServersActions.defaultLogLines), facts: facts) == ["journalctl", "-u", "x.service", "-n", "200", "--no-pager", "-o", "short-iso"])
        #expect(BackendServersActions.logCommand(.container(runtime: .docker, name: "c1", compose: nil), lines: 5, facts: facts)?.contains("--tail") == true)
        #expect(BackendServersActions.logCommand(.openrc(service: "nginx"), lines: 200, facts: facts) == nil)
    }
    @Test func openRequiresMeasuredAddress() {
        var site = repo; site.kind = .site; site.url = "https://example.test"
        #expect(available(site).offered.contains(.open)); #expect(!available(repo).offered.contains(.open))
    }
    @Test func startAndStopAreExclusive() {
        #expect(available(repo).offered.contains(.stop)); #expect(!available(repo).offered.contains(.start))
        var stopped = repo; stopped.running = false
        #expect(available(stopped).offered.contains(.start)); #expect(!available(stopped).offered.contains(.stop))
    }
    @Test func unknownManagerExplainsMissingRestart() {
        var card = repo; card.managedBy = nil; let a = available(card)
        #expect(!a.offered.contains(.restart)); #expect(a.absent.contains(.init(actionId: .restart, because: "We can’t tell how this server starts and stops things, so we’re not going to guess.")))
    }
    @Test func onlyAddedHereControlsDiscriminator() {
        var os = repo; os.id = "service:systemd-udevd.service"; os.kind = .other; os.name = "systemd-udevd"
        let a = available(os); #expect(a.offered == [.logs]); #expect(a.absent == [.init(actionId: .restart, because: BackendServersActions.notYoursToStop)])
        var ours = repo; ours.name = "systemd-udevd"; #expect(available(ours).offered.contains(.stop))
    }
    @Test func noPrivilegeExplainsMissingRestart() {
        var f = facts; f.privilege = .no(measuredAt: 1, how: "asked"); let a = available(repo, facts: f)
        #expect(!a.offered.contains(.restart)); #expect(a.absent.contains(.init(actionId: .restart, because: "This sign-in can’t start or stop things on this server.")))
    }
    @Test func unsupportedEngineExplainsMissingBackup() {
        let a = available(container(.redis)); #expect(!a.offered.contains(.backup))
        #expect(a.absent.contains(.init(actionId: .backup, because: "We can’t tell what kind of database this is, so we don’t know how to copy it safely.")))
    }
    @Test func missingTransferExplainsMissingBackup() { #expect(available(container(.postgres), download: false).absent.contains(.init(actionId: .backup, because: "This app can’t copy files off a server yet."))) }
    @Test func manualContainerHasNoUpdate() {
        let card = container(compose: false), a = available(container(compose: false))
        #expect(BackendServersActions.updateKind(card, composeAvailable: true) == nil); #expect(!a.offered.contains(.update)); #expect(a.absent.first { $0.actionId == .update }?.because.contains("how this was set up") == true)
    }
    @Test func missingComposeExplainsMissingUpdate() {
        let a = available(container(), compose: false); #expect(!a.offered.contains(.update))
        #expect(a.absent.first { $0.actionId == .update }?.because.contains("doesn’t have the tool we’d use to put a container back") == true)
    }
    @Test func databaseNeedsCopyBeforeUpdate() {
        let a = available(container(.postgres), download: false); #expect(!a.offered.contains(.update))
        #expect(a.absent.first { $0.actionId == .update }?.because.contains("updating a database without one isn’t something we can undo") == true)
    }
    @Test func dumpReadsContainerEnvironmentOnly() throws {
        let managed = BackendServersManagedBy.container(runtime: .docker, name: "db", compose: nil)
        let pg = try #require(BackendServersActions.dumpCommand(.postgres, managedBy: managed)); #expect(pg.dump.joined(separator: " ").contains("POSTGRES_USER")); #expect(pg.probe.joined(separator: " ").contains("command -v pg_dumpall"))
        let mysql = try #require(BackendServersActions.dumpCommand(.mysql, managedBy: managed)); #expect(mysql.dump.joined(separator: " ").contains("MYSQL_PWD")); #expect(mysql.dump.joined(separator: " ").range(of: #"-p['"]?\$"#, options: .regularExpression) == nil)
    }
    @Test func noDumpForHostOrUnknownEngine() {
        #expect(BackendServersActions.dumpCommand(.postgres, managedBy: .systemd(unit: "postgresql.service")) == nil)
        #expect(BackendServersActions.dumpCommand(.mongo, managedBy: .container(runtime: .docker, name: "m", compose: nil)) == nil)
        #expect(!BackendServersActions.canBackUp(.redis, managedBy: .container(runtime: .docker, name: "r", compose: nil))); #expect(!BackendServersActions.canBackUp(nil, managedBy: nil))
    }
    @Test func permissionOnlyWhenServerSaysPermission() {
        for stderr in ["Failed to restart x.service: Access denied", "sudo: a password is required"] { #expect(BackendServersActions.failureSentence(.init(code: 1, stdout: "", stderr: stderr), what: "your site").sentence == "This sign-in isn’t allowed to do that on this server.") }
    }
    @Test func missingIsNotPermission() { #expect(BackendServersActions.failureSentence(.init(code: 5, stdout: "", stderr: "Unit x.service could not be found."), what: "your site").sentence == "The server couldn’t find your site any more.") }
    @Test func relayServerWordsAndKernelSignal() {
        let other = BackendServersActions.failureSentence(.init(code: 1, stdout: "", stderr: "Job for x.service failed"), what: "your site")
        #expect(other.sentence == "The server refused to do that to your site."); #expect(other.detail.contains("Job for x.service failed"))
        #expect(BackendServersActions.failureSentence(.init(code: nil, signal: "SIGKILL", stdout: ""), what: "your site").detail.contains("SIGKILL"))
    }
    @Test func shellJoinExactlyMatchesTransportQuoting() {
        for argument in ["it's", "$(reboot)", "`reboot`", "a b", "x\"y", "\\", "\n", "", "a;b|c&d"] { #expect(BackendServersActions.shellJoin([argument]) == BackendServersConnections.quote(argument)) }
        #expect(BackendServersActions.shellJoin(["echo", "hello world"]) == "'echo' 'hello world'")
    }
    @Test func localActionLocations() { #expect(BackendServersActions.wherePerformed(.open) == "here"); #expect(BackendServersActions.wherePerformed(.copyAddress) == "here"); #expect(BackendServersActions.wherePerformed(.restart) == "server") }
    @Test func fullStopPreview() {
        let p = BackendServersActions.previewOf(.stop, target: .init(serverId: "s1", card: repo, facts: facts))
        #expect(p.actionId == .stop && p.klass == .reversible && p.label == "Stop" && p.target == "td-scratch" && p.wayBack == "Start" && p.keeps == nil); #expect(p.sentence.contains("td-scratch"))
    }
    @Test func everyActionHasExactlyOneOfThreeClassesAndNoDeletionName() {
        #expect(Set(BackendServersActionClass.allCases.map(\.rawValue)) == ["safe", "reversible", "kept"])
        for id in BackendServersActionID.ordered { #expect(BackendServersActionClass.allCases.contains(BackendServersActions.klass(id))); #expect(id.rawValue.range(of: "delete|remove|destroy|purge|drop|wipe|reset", options: .regularExpression) == nil) }
    }
    @Test func reversibleSentencesNameTheReturnButton() {
        let target = BackendServersActionTarget(serverId: "s1", card: repo, facts: facts)
        #expect(BackendServersActions.summary(.stop, target: target).localizedCaseInsensitiveContains("start it again")); #expect(BackendServersActions.summary(.goBack, target: target).contains("Update will bring it forward again"))
    }
    @Test func everyKeptActionRecordsRecovery() async throws {
        // Swift has one private keep function behind the closed kept class. Exercise
        // every kept catalogue member, rather than checking for a JS function value.
        for id in BackendServersActionID.ordered where BackendServersActions.klass(id) == .kept {
            let journal = BackendServersMemoryJournal()
            let deps = BackendServersActionDeps(run: { _, argv in .init(code: 0, stdout: argv.contains("rev-parse") ? String(repeating: "c", count: 40) : "") }, journal: journal)
            _ = try await BackendServersActions.perform(deps, actionId: id, target: .init(serverId: "s1", card: repo, facts: facts))
            #expect(await journal.get(serverId: "s1", cardId: repo.id) != nil)
        }
    }
    @Test func uncopiableDatabaseRefusesWithExactReasonAndNoPull() async {
        let calls = BackendServersActionsPortCalls()
        let deps = BackendServersActionDeps(run: { _, argv in await calls.add(argv); return .init(code: 0, stdout: "") }, journal: BackendServersMemoryJournal())
        do { _ = try await BackendServersActions.perform(deps, actionId: .update, target: .init(serverId: "s1", card: container(.postgres), facts: facts)); Issue.record("Uncopiable database was updated") }
        catch { #expect(error.localizedDescription.localizedCaseInsensitiveContains("can’t copy files off a server")) }
        #expect(await calls.values().filter { $0.contains("pull") } == [])
    }
}
private actor BackendServersActionsPortCalls { private var calls: [[String]] = []; func add(_ argv: [String]) { calls.append(argv) }; func values() -> [[String]] { calls } }
