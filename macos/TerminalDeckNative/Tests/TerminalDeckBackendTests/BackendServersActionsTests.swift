import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendServersActionsRecorder: BackendServersWayBackJournal {
    var calls: [[String]] = []; var events: [String] = []; var record: BackendServersWayBack?
    let failPut: Bool; let failRead: Bool; let dirty: Bool; let emptyBackup: Bool; let missingImage: Bool
    init(failPut: Bool = false, failRead: Bool = false, dirty: Bool = false, emptyBackup: Bool = false, missingImage: Bool = false) { self.failPut = failPut; self.failRead = failRead; self.dirty = dirty; self.emptyBackup = emptyBackup; self.missingImage = missingImage }
    func run(_ id: String, _ argv: [String]) -> BackendServersRunResult {
        calls.append(argv); events.append(argv.joined(separator: " "))
        if argv.contains("status") { return .init(code: 0, stdout: dirty ? " M app.js\n" : "") }
        if argv.contains("rev-parse") { return .init(code: 0, stdout: String(repeating: "a", count: 40) + "\n") }
        if argv.contains("inspect") && argv.contains("--format") { return .init(code: 0, stdout: "sha256:" + String(repeating: "b", count: 64) + "\tapp:latest\n") }
        if argv.contains("image") && argv.contains("inspect") && missingImage { return .init(code: 1, stdout: "", stderr: "No such image") }
        if argv.contains(where: { $0.hasPrefix("wc -c") }) { return .init(code: 0, stdout: emptyBackup ? "0\n" : "123\n") }
        return .init(code: 0, stdout: "")
    }
    func download(_ id: String, _ remote: String, _ local: String) -> Int { events.append("download"); return 123 }
    func put(serverId: String, cardId: String, record: BackendServersWayBack) throws { events.append("put"); if failPut { throw BackendServersActionRefused("disk full") }; self.record = record }
    func get(serverId: String, cardId: String) -> BackendServersWayBack? { events.append("get"); return failRead ? nil : record }
    func clear(serverId: String, cardId: String) { events.append("clear"); record = nil }
}

private func backendServersActionFacts(_ privilege: BackendServersPrivilege = .yes) -> BackendServersActionFacts {
    .init(privilege: .yes(privilege, measuredAt: 1, how: "asked privileges"), initSystem: .yes(.systemd, measuredAt: 1, how: "asked init"), containerRuntime: .yes(.docker, measuredAt: 1, how: "asked runtime"))
}
private func backendServersRepo(_ name: String = "app") -> BackendServersCard { .init(id: "service:app.service", kind: .app, name: name, running: true, managedBy: .systemd(unit: "app.service"), repoDir: "/opt/app") }
private func backendServersContainer(_ engine: BackendServersKnownEngine? = nil) -> BackendServersCard { .init(id: "container:project-web-1", kind: engine == nil ? .app : .database, name: "web", running: true, managedBy: .container(runtime: .docker, name: "project-web-1", compose: .init(project: "project", service: "web", workingDir: "/opt/project")), engine: engine) }
private func backendServersTarget(_ card: BackendServersCard) -> BackendServersActionTarget { .init(serverId: "s1", card: card, facts: backendServersActionFacts()) }
private func backendServersDeps(_ state: BackendServersActionsRecorder, download: Bool = false) -> BackendServersActionDeps {
    .init(run: { await state.run($0, $1) }, journal: state, download: download ? { @Sendable a, b, c in await state.download(a, b, c) } : nil, backupDir: download ? "/safe/backups" : nil, now: { 1_700_000_000_000 })
}

@Suite("Curated server actions preserve recovery and refusal rules")
struct BackendServersActionsTests {
    @Test func commandsUseDetectedDialectAndNoninteractiveElevation() {
        let f = backendServersActionFacts()
        #expect(BackendServersActions.serviceCommand(.systemd(unit: "app.service"), verb: .restart, facts: f) == ["systemctl", "restart", "app.service"])
        #expect(BackendServersActions.serviceCommand(.openrc(service: "nginx"), verb: .start, facts: backendServersActionFacts(.sudoPassword)) == ["sudo", "-n", "rc-service", "nginx", "start"])
        #expect(BackendServersActions.serviceCommand(.container(runtime: .podman, name: "web", compose: nil), verb: .stop, facts: backendServersActionFacts(.no)) == ["podman", "stop", "web"])
        #expect(BackendServersActions.serviceCommand(.systemd(unit: "$(reboot)"), verb: .restart, facts: f) == nil)
        #expect(BackendServersActions.logCommand(.systemd(unit: "app.service"), lines: 999999, facts: f)?.contains("2000") == true)
        #expect(BackendServersActions.logCommand(.systemd(unit: "app.service"), lines: -5, facts: f)?.contains("1") == true)
        #expect(BackendServersActions.logCommand(.openrc(service: "nginx"), lines: 10, facts: f) == nil)
        #expect(BackendServersActions.shellJoin(["a'b", "$(reboot)"]) == "'a'\\''b' '$(reboot)'")
    }
    @Test func permissionsMissingFaultsAndSignalsRemainDistinct() {
        let permission = BackendServersActions.failureSentence(.init(code: 1, stdout: "", stderr: "sudo: a password is required"), what: "app")
        #expect(permission.sentence.contains("isn’t allowed"))
        #expect(BackendServersActions.failureSentence(.init(code: 1, stdout: "", stderr: "Unit app.service not found"), what: "app").sentence == "The server couldn’t find app any more.")
        #expect(BackendServersActions.failureSentence(.init(code: nil, signal: "KILL", stdout: ""), what: "app").detail == "The command was stopped by KILL.")
        #expect(BackendServersActions.failureSentence(.init(code: 1, stdout: "", stderr: "configuration invalid"), what: "app").sentence == "The server refused to do that to app.")
        #expect(BackendServersActions.failureSentence(.init(code: 1, stdout: Array(repeating: "line", count: 30).joined(separator: "\n")), what: "app").detail.components(separatedBy: "\n").count == 20)
    }
    @Test func availabilityRemovesUnsupportedAndReadOnlyControls() {
        let f = backendServersActionFacts(); var card = backendServersRepo()
        #expect(BackendServersActions.availableActions(card, facts: f, canDownload: true, composeAvailable: true).offered == [.logs, .restart, .stop, .update])
        card.running = false
        #expect(BackendServersActions.availableActions(card, facts: f, canDownload: true, composeAvailable: true).offered.contains(.start))
        #expect(!BackendServersActions.availableActions(card, facts: f, canDownload: true, composeAvailable: true).offered.contains(.stop))
        card.kind = .other
        let other = BackendServersActions.availableActions(card, facts: f, canDownload: true, composeAvailable: true)
        #expect(other.offered == [.logs]); #expect(other.absent.count == 1); #expect(other.absent[0].because == BackendServersActions.notYoursToStop)
        let database = backendServersContainer(.postgres)
        #expect(!BackendServersActions.availableActions(database, facts: f, canDownload: false, composeAvailable: true).offered.contains(.update))
        #expect(!BackendServersActions.availableActions(database, facts: f, canDownload: true, composeAvailable: false).offered.contains(.update))
        #expect(BackendServersActions.availableActions(database, facts: f, canDownload: true, composeAvailable: true).offered.contains(.backup))
        #expect(!BackendServersActions.canBackUp(.redis, managedBy: database.managedBy))
        #expect(!BackendServersActions.canBackUp(.postgres, managedBy: .systemd(unit: "postgres.service")))
        #expect(BackendServersActions.availableActions(backendServersRepo(), facts: backendServersActionFacts(.no), canDownload: true, composeAvailable: true).absent.contains { $0.because == "This sign-in can’t start or stop things on this server." })
    }
    @Test func dumpCommandsUseOnlyContainersOwnEnvironment() {
        let managed = backendServersContainer().managedBy!
        #expect(BackendServersActions.dumpCommand(.postgres, managedBy: managed)?.dump.last == #"exec pg_dumpall -U "${POSTGRES_USER:-postgres}""#)
        let mysql = BackendServersActions.dumpCommand(.mariadb, managedBy: managed)!
        #expect(mysql.dump.last?.contains("MYSQL_PWD") == true); #expect(mysql.dump.last?.contains("MARIADB_ROOT_PASSWORD") == true)
        #expect(mysql.probe.last == "command -v mariadb-dump || command -v mysqldump")
    }
    @Test func journalFailureOrLostReadCannotReachMutation() async {
        for state in [BackendServersActionsRecorder(failPut: true), BackendServersActionsRecorder(failRead: true)] {
            do { _ = try await BackendServersActions.perform(backendServersDeps(state), actionId: .update, target: backendServersTarget(backendServersRepo())); Issue.record("Missing journal must refuse") }
            catch { #expect(error is BackendServersActionRefused) }
            let calls = await state.calls; #expect(!calls.contains { $0.contains("fetch") || $0.contains("merge") || $0.contains("restart") })
        }
    }
    @Test func exactVersionIsRecordedReadBackAndThenChanged() async throws {
        let state = BackendServersActionsRecorder(); let target = backendServersTarget(backendServersRepo())
        let outcome = try await BackendServersActions.perform(backendServersDeps(state), actionId: .update, target: target)
        let events = await state.events
        #expect(events.firstIndex(of: "put")! < events.firstIndex(of: "get")!)
        #expect(events.firstIndex(of: "get")! < events.firstIndex(where: { $0.contains("fetch") })!)
        #expect(outcome.wayBack?.actionId == .goBack)
        let kept = await state.record
        if let kept, case .repoCommit(_, let dir, let commit, _, _) = kept { #expect(dir == "/opt/app"); #expect(commit == String(repeating: "a", count: 40)) } else { Issue.record("Repository record missing") }
    }
    @Test func dirtyCheckoutAndUncopyableDatabaseAreRefusedBeforeChanges() async {
        let dirty = BackendServersActionsRecorder(dirty: true)
        do { _ = try await BackendServersActions.perform(backendServersDeps(dirty), actionId: .update, target: backendServersTarget(backendServersRepo())); Issue.record("Dirty repo must refuse") } catch { #expect((error as? BackendServersActionRefused)?.sentence.contains("changed this on the server itself") == true) }
        let dirtyCalls = await dirty.calls; #expect(dirtyCalls.count == 1)
        let database = BackendServersActionsRecorder()
        do { _ = try await BackendServersActions.perform(backendServersDeps(database), actionId: .update, target: backendServersTarget(backendServersContainer(.postgres))); Issue.record("Uncopyable database must refuse") } catch { #expect(error is BackendServersActionRefused) }
        let databaseCalls = await database.calls; #expect(databaseCalls.isEmpty)
    }
    @Test func automaticDatabaseBackupPrecedesImagePullAndEmptyCopiesAreRemoved() async throws {
        let state = BackendServersActionsRecorder(); let target = backendServersTarget(backendServersContainer(.postgres))
        _ = try await BackendServersActions.perform(backendServersDeps(state, download: true), actionId: .update, target: target)
        let events = await state.events
        #expect(events.firstIndex(of: "download")! < events.firstIndex(where: { $0.contains("compose") && $0.contains("pull") })!)
        #expect(events.contains { $0.hasPrefix("rm -f /tmp/td-backup-") })
        let empty = BackendServersActionsRecorder(emptyBackup: true)
        do { _ = try await BackendServersActions.perform(backendServersDeps(empty, download: true), actionId: .backup, target: target); Issue.record("Empty backup must fail") } catch { #expect(error is BackendServersActionFailed) }
        let emptyEvents = await empty.events
        #expect(emptyEvents.contains { $0.hasPrefix("rm -f /tmp/td-backup-") }); #expect(!emptyEvents.contains("download"))
    }
    @Test func rollbackChecksImagePresenceAndKeepsRecoveryWhenItFails() async throws {
        let state = BackendServersActionsRecorder(missingImage: true); let target = backendServersTarget(backendServersContainer())
        _ = try await BackendServersActions.perform(backendServersDeps(state), actionId: .update, target: target)
        do { _ = try await BackendServersActions.perform(backendServersDeps(state), actionId: .goBack, target: target); Issue.record("Missing image must fail") } catch { #expect((error as? BackendServersActionFailed)?.sentence.contains("previous version isn’t on this server") == true) }
        let record = await state.record, calls = await state.calls
        #expect(record != nil); #expect(!calls.contains { $0.contains("tag") })
    }
    @Test func closedVocabularyUnknownCommandsNeverReachTransport() async {
        #expect(BackendServersActionID.ordered.map(\.rawValue) == ["open", "copy-address", "logs", "start", "restart", "stop", "update", "go-back", "backup"])
        #expect(Set(BackendServersActionClass.allCases.map(\.rawValue)) == ["safe", "reversible", "kept"])
        #expect(!BackendServersActionID.control.contains(.open))
        let state = BackendServersActionsRecorder()
        do { _ = try await BackendServersActions.perform(backendServersDeps(state), action: "rm -rf /", target: backendServersTarget(backendServersRepo())); Issue.record("Unknown action must refuse") } catch { #expect(error is BackendServersActionRefused) }
        let calls = await state.calls; #expect(calls.isEmpty)
    }
    @Test func backendOwnsAllConsequencesAndPreviews() {
        for card in [backendServersRepo(), backendServersContainer(), backendServersContainer(.postgres)] {
            let target = backendServersTarget(card)
            for action in BackendServersActionID.ordered {
                let p = BackendServersActions.previewOf(action, target: target)
                #expect(p.sentence == BackendServersActions.summary(action, target: target)); #expect(p.sentence.contains(card.name)); #expect(!p.sentence.isEmpty)
            }
        }
        let database = BackendServersActions.previewOf(.update, target: backendServersTarget(backendServersContainer(.postgres)))
        #expect(database.keeps?.contains("copy of everything in this database") == true); #expect(database.sentence.contains("a minute or two")); #expect(!database.sentence.contains("seconds"))
        #expect(BackendServersActions.wherePerformed(.open) == "here"); #expect(BackendServersActions.wherePerformed(.restart) == "server")
    }
    @Test func localActionsNeverTouchTransportAndMissingAddressRefuses() async throws {
        let state = BackendServersActionsRecorder(); var card = backendServersRepo(); card.url = "https://example.com"
        let opened = try await BackendServersActions.perform(backendServersDeps(state), actionId: .open, target: backendServersTarget(card))
        #expect(opened.value?["url"].string == "https://example.com")
        _ = try await BackendServersActions.perform(backendServersDeps(state), actionId: .copyAddress, target: backendServersTarget(card))
        let calls = await state.calls; #expect(calls.isEmpty)
        do { _ = try await BackendServersActions.perform(backendServersDeps(state), actionId: .open, target: backendServersTarget(backendServersRepo())); Issue.record("Missing URL must refuse") } catch { #expect(error is BackendServersActionRefused) }
    }
    @Test func logsKeepPrintedOutputOnFailureAndRejectSilentFailure() async throws {
        let target = backendServersTarget(backendServersRepo())
        let printed = BackendServersActionDeps(run: { _, _ in .init(code: 1, stdout: "first\nsecond\n\n", stderr: "stopped") }, journal: BackendServersMemoryJournal())
        let result = try await BackendServersActions.perform(printed, actionId: .logs, target: target)
        #expect(result.value?["lines"].elements == [.string("first"), .string("second")])
        let silent = BackendServersActionDeps(run: { _, _ in .init(code: nil, signal: "TERM", stdout: "") }, journal: BackendServersMemoryJournal())
        do { _ = try await BackendServersActions.perform(silent, actionId: .logs, target: target); Issue.record("Silent signalled logs must fail") } catch { #expect(error is BackendServersActionFailed) }
    }
    @Test func signalledServiceDoesNotReportSuccess() async {
        let deps = BackendServersActionDeps(run: { _, _ in .init(code: nil, signal: "KILL", stdout: "") }, journal: BackendServersMemoryJournal())
        do { _ = try await BackendServersActions.perform(deps, actionId: .restart, target: backendServersTarget(backendServersRepo())); Issue.record("Signal must fail") } catch { #expect((error as? BackendServersActionFailed)?.detail.contains("KILL") == true) }
    }
    @Test func repositoryGoBackUsesRecordedCommitAndClearsOnlyAfterSuccess() async throws {
        let state = BackendServersActionsRecorder(), target = backendServersTarget(backendServersRepo())
        _ = try await BackendServersActions.perform(backendServersDeps(state), actionId: .update, target: target)
        let back = try await BackendServersActions.perform(backendServersDeps(state), actionId: .goBack, target: target)
        #expect(back.wayBack?.actionId == .update)
        let calls = await state.calls, record = await state.record
        #expect(calls.contains(["git", "-C", "/opt/app", "reset", "--hard", String(repeating: "a", count: 40)])); #expect(record == nil)
    }
    @Test func missingRecordedVersionRefusesGoBack() async {
        let state = BackendServersActionsRecorder()
        do { _ = try await BackendServersActions.perform(backendServersDeps(state), actionId: .goBack, target: backendServersTarget(backendServersRepo())); Issue.record("Missing record must refuse") } catch { #expect((error as? BackendServersActionRefused)?.sentence.contains("nothing to go back to") == true) }
        let calls = await state.calls; #expect(calls.isEmpty)
    }
    @Test func databaseBackupRefusesUnsafeLocalDestinationBeforeDump() async {
        let state = BackendServersActionsRecorder()
        let deps = BackendServersActionDeps(run: { await state.run($0, $1) }, journal: state, download: { await state.download($0, $1, $2) }, backupDir: "/tmp/$(reboot)", now: { 0 })
        do { _ = try await BackendServersActions.perform(deps, actionId: .backup, target: backendServersTarget(backendServersContainer(.postgres))); Issue.record("Unsafe destination must refuse") } catch { #expect(error is BackendServersActionRefused) }
        let calls = await state.calls; #expect(calls.count == 1); #expect(calls[0].last == "command -v pg_dumpall")
    }
    @Test func recoveryRecordCodableUsesSourceDiscriminatorsAndNulls() throws {
        let records: [BackendServersWayBack] = [.repoCommit(at: 1, dir: "/opt/app", commit: String(repeating: "a", count: 40), managedBy: nil, backupPath: nil), .containerImage(at: 2, container: "web", imageId: "sha256:a", imageRef: "app:latest", compose: .init(project: "app", service: "web"), backupPath: "/safe/file.sql")]
        #expect(try JSONDecoder().decode([BackendServersWayBack].self, from: JSONEncoder().encode(records)) == records)
        let encoded = try NativeRPCValue.parseJSON(JSONEncoder().encode(records[0]))
        #expect(encoded["kind"].string == "repo-commit"); #expect(encoded["backupPath"] == .null); #expect(encoded["managedBy"] == .null)
    }
}
