import Foundation
import CryptoKit
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("APD backups: protected policy and recovery safety, no servers")
struct BackendAppsDataBackupTests {
    @Test func wrongConfirmationNeverReachesDocker() async throws {
        let fake = try BackendAppsDataBackupFixture(), service = fake.service()
        do {
            _ = try await service.restore(serverID: "saved-server", appID: fake.appID, backupID: "td-test-backup", confirmation: "Test data")
            Issue.record("Different database name was accepted")
        } catch let error as NativeRPCError { #expect(error.code == "confirmation-required") }
        #expect((await fake.calls).isEmpty)
    }

    @Test func corruptBackupCannotCreateOrStopDatabase() async throws {
        let fake = try BackendAppsDataBackupFixture()
        await fake.setChecksumFailure()
        do {
            _ = try await fake.service().restore(serverID: "saved-server", appID: fake.appID, backupID: "td-test-backup", confirmation: "Test database")
            Issue.record("Corrupt backup returned success")
        } catch let error as NativeRPCError { #expect(error.code == "restore-failed") }
        #expect((await fake.calls).allSatisfy { $0.method == "GET" })
        #expect(!(await fake.files).keys.contains(where: { $0.contains("data-restore-intent") }))
    }

    @Test func wrongRestoreTokenNeverMountsRecoveryVolume() async throws {
        let fake = try BackendAppsDataBackupFixture()
        await fake.setWrongVolumeToken()
        do {
            _ = try await fake.service().restore(serverID: "saved-server", appID: fake.appID, backupID: "td-test-backup", confirmation: "Test database")
            Issue.record("Another operation's volume was mounted")
        } catch let error as NativeRPCError { #expect(error.code == "restore-failed") }
        let calls = await fake.calls
        #expect(!calls.contains { $0.path.hasPrefix("/containers/create") || $0.path.contains("/stop") })
        #expect(!calls.contains { $0.method == "DELETE" })
    }

    @Test func restoreKeepsOriginalVolumeAndVerifiesStablePrivateAddress() async throws {
        let fake = try BackendAppsDataBackupFixture()
        let result = try await fake.service().restore(serverID: "saved-server", appID: fake.appID, backupID: "td-test-backup", confirmation: "Test database")
        #expect(result["restored"].bool == true)
        #expect(result["recoveryPreserved"].bool == true)
        let files = await fake.files, calls = await fake.calls
        let record = try NativeRPCValue.parseJSON(try #require(files[fake.directory + "/state.json"]))
        #expect(record["database"]["containerId"].string == BackendAppsDataBackupFixture.candidateID)
        #expect(record["databaseRecovery"].elements?.last?["volumeName"].string == fake.originalVolume)
        #expect(await fake.hasStableAlias(BackendAppsDataBackupFixture.candidateID))
        #expect(!(await fake.isAttached(BackendAppsDataBackupFixture.originalID)))
        #expect(files[fake.directory + "/data-restore-intent.json"] == nil)
        #expect(!calls.contains { $0.method == "DELETE" })
    }

    @Test func failedImportRecoversOriginalAndRetainsBothVolumes() async throws {
        let fake = try BackendAppsDataBackupFixture()
        await fake.setImportFailure()
        do {
            _ = try await fake.service().restore(serverID: "saved-server", appID: fake.appID, backupID: "td-test-backup", confirmation: "Test database")
            Issue.record("Failed import returned success")
        } catch let error as NativeRPCError {
            #expect(error.code == "restore-failed")
            #expect(error.message.contains("original database was recovered"))
        }
        #expect(await fake.hasStableAlias(BackendAppsDataBackupFixture.originalID))
        #expect(!(await fake.isAttached(BackendAppsDataBackupFixture.candidateID)))
        #expect((await fake.volumes).count == 2)
        #expect(!(await fake.calls).contains { $0.method == "DELETE" })
    }

    @Test func lostConnectResponseUsesObservedEndpointsForCompensation() async throws {
        let fake = try BackendAppsDataBackupFixture()
        await fake.setConnectResponseLost()
        do {
            _ = try await fake.service().restore(serverID: "saved-server", appID: fake.appID, backupID: "td-test-backup", confirmation: "Test database")
            Issue.record("Lost activation response returned success")
        } catch let error as NativeRPCError {
            #expect(error.code == "restore-failed")
            #expect(error.message.contains("original database was recovered"))
            #expect(!error.message.contains("fake-secret"))
        }
        #expect(await fake.hasStableAlias(BackendAppsDataBackupFixture.originalID))
        #expect(!(await fake.isAttached(BackendAppsDataBackupFixture.candidateID)))
        #expect((await fake.calls).contains { $0.path.hasSuffix("/disconnect") && $0.body?["Container"].string == BackendAppsDataBackupFixture.candidateID })
    }

    @Test func unverifiedCompensationKeepsJournalAndBlocksMoreChanges() async throws {
        let fake = try BackendAppsDataBackupFixture()
        await fake.setImportFailure()
        await fake.setRecoveryRestartFailure()
        do {
            _ = try await fake.service().restore(serverID: "saved-server", appID: fake.appID, backupID: "td-test-backup", confirmation: "Test database")
            Issue.record("Failed recovery returned success")
        } catch let error as NativeRPCError { #expect(error.message.contains("restore journal")) }
        let journal = try NativeRPCValue.parseJSON(try #require((await fake.files)[fake.directory + "/data-restore-intent.json"]))
        #expect(journal["phase"].string == "recovery-required")
        let before = (await fake.calls).count
        do {
            _ = try await fake.service().create(serverID: "saved-server", appID: fake.appID)
            Issue.record("An unresolved recovery allowed another write")
        } catch let error as NativeRPCError { #expect(error.code == "conflict") }
        #expect((await fake.calls).count == before)
    }

    @Test func noOpDisconnectCannotBecomeSuccessfulRecovery() async throws {
        let fake = try BackendAppsDataBackupFixture()
        await fake.setImportFailure()
        await fake.setNoOpCandidateDisconnect()
        do {
            _ = try await fake.service().restore(serverID: "saved-server", appID: fake.appID, backupID: "td-test-backup", confirmation: "Test database")
            Issue.record("A fake successful disconnect hid an attached recovery database")
        } catch let error as NativeRPCError { #expect(error.message.contains("restore journal")) }
        #expect((await fake.files)[fake.directory + "/data-restore-intent.json"] != nil)
    }

    @Test func revokedRPCRecoveryPreservesExistingJournalWithoutClaimingRecovery() async throws {
        let fake = try BackendAppsDataBackupFixture()
        await fake.setImportFailure()
        await fake.setRecoveryDenied()
        do {
            _ = try await fake.service().restore(serverID: "saved-server", appID: fake.appID, backupID: "td-test-backup", confirmation: "Test database")
            Issue.record("A revoked RPC allowed restore recovery success")
        } catch let error as NativeRPCError {
            // With no sealed kernel, the revoked ordinary receipt also denies lock release.
            // Store must surface that exact cleanup failure, not pretend its lock was released.
            #expect(error.code == "state-failed")
            #expect(error.message.contains("owned lock recovery could not be verified"))
            #expect(!error.message.contains("original database was recovered"))
            #expect(!error.message.contains("fake-secret"))
        }
        let journal = try NativeRPCValue.parseJSON(try #require((await fake.files)[fake.directory + "/data-restore-intent.json"]))
        #expect(journal["originalContainerId"].string == BackendAppsDataBackupFixture.originalID)
        #expect(journal["candidateContainerId"].string == BackendAppsDataBackupFixture.candidateID)
        #expect((await fake.files)[fake.directory + "/.lock/owner"] != nil)
        #expect((await fake.volumes).count == 2)
        #expect(!(await fake.calls).contains { $0.method == "DELETE" })
    }

    @Test func runningCandidateIsRetainedWhenItsStopCannotBeVerified() async throws {
        let fake = try BackendAppsDataBackupFixture()
        await fake.setImportFailure()
        await fake.setCandidateStopFailure()
        do {
            _ = try await fake.service().restore(serverID: "saved-server", appID: fake.appID, backupID: "td-test-backup", confirmation: "Test database")
            Issue.record("Unstopped recovery candidate became a recovered original")
        } catch let error as NativeRPCError { #expect(error.message.contains("restore journal")) }
        #expect(await fake.isRunning(BackendAppsDataBackupFixture.candidateID))
        #expect(await fake.isAttached(BackendAppsDataBackupFixture.candidateID))
        #expect(!(await fake.isRunning(BackendAppsDataBackupFixture.originalID)))
        #expect(!(await fake.calls).contains { $0.path == "/containers/\(BackendAppsDataBackupFixture.originalID)/start" || $0.method == "DELETE" })
        #expect((await fake.files)[fake.directory + "/data-restore-intent.json"] != nil)
    }

    @Test func sealedPolicyBeforeImagesAndTimerRecoverAfterOrdinaryReceiptRevocation() async throws {
        let fake = try BackendAppsDataBackupFixture()
        await fake.seedBackupTimerBaseline(enabled: false, active: false)
        await fake.setPolicyFailure(revoke: true)
        let kernel = await fake.recoveryKernel()
        let context = NativeRPCContext(caller: .page, ownerID: "backup-owner", capabilities: ["apps.write"])
        do {
            _ = try await NativeCompositionCallContext.$rpc.withValue(context) {
                try await fake.service(recovery: kernel).policy(serverID: "saved-server", appID: fake.appID, request: policy().setting("upload", upload()))
            }
            Issue.record("Cancelled policy returned success")
        } catch let error as NativeRPCError {
            #expect(error.code == "state-failed")
            #expect(error.message.contains("captured files and timer state were restored"))
        }
        let audits = await fake.audits
        #expect(audits.contains { $0.event == "sealed" && $0.operation == "restore-captured-timer" })
        #expect(audits.contains { $0.event == "finished" && $0.operation == "restore-captured-timer" && $0.successful == true })
        #expect(audits.filter { $0.event == "finished" }.allSatisfy { $0.successful == true })
        #expect(!audits.contains { $0.value.compact.contains("fake-secret") || $0.value.compact.contains("fake-access") })
        let files = await fake.files
        let record = try NativeRPCValue.parseJSON(try #require(files[fake.directory + "/state.json"]))
        #expect(record["backupPolicy"]["enabled"].bool == false)
        #expect(files[fake.directory + "/data-backup-policy-recovery.json"] == nil)
        #expect(files[fake.directory + "/.lock/owner"] == nil)
        let timer = try #require(await fake.backupTimerState())
        #expect(!timer.enabled && !timer.active)
        #expect(timer.loaded && !timer.needsReload)
        #expect((await fake.policyTransactions) == 1)
        let scripts = (await fake.commands).map { command in
            let words = BackendAppsDatabaseFixture.words(command)
            return words.first == "sh" && words.dropFirst().first == "-c" ? words.dropFirst(2).first ?? "" : command
        }
        let reload = try #require(scripts.firstIndex(of: "systemctl daemon-reload"))
        let disable = try #require(scripts.firstIndex(of: "systemctl disable -- 'td-test-td-test-data-backup.timer'"))
        let stop = try #require(scripts.firstIndex(of: "systemctl stop -- 'td-test-td-test-data-backup.timer'"))
        let queries = scripts.indices.filter { scripts[$0].hasPrefix("systemctl show ") }
        #expect(reload < disable && disable < stop)
        #expect(queries.contains { $0 < reload } && queries.contains { $0 > disable && $0 < stop } && queries.contains { $0 > stop })
        #expect(queries.allSatisfy { index in ["FragmentPath", "LoadState", "UnitFileState", "ActiveState", "NeedDaemonReload"].allSatisfy { scripts[index].contains("--property=" + $0) } })
        #expect((await fake.closedRecoveryTransports) == 1)
    }

    @Test func typedRestoreRetainsRunningCandidateAndJournalWhenOriginalRecoveryFails() async throws {
        let fake = try BackendAppsDataBackupFixture()
        await fake.setImportFailure()
        await fake.setRecoveryDenied()
        await fake.setRecoveryRestartFailure()
        let kernel = await fake.recoveryKernel()
        let context = NativeRPCContext(caller: .page, ownerID: "backup-owner", capabilities: ["apps.write"])
        do {
            _ = try await NativeCompositionCallContext.$rpc.withValue(context) {
                try await fake.service(recovery: kernel).restore(serverID: "saved-server", appID: fake.appID, backupID: "td-test-backup", confirmation: "Test database")
            }
            Issue.record("Failed original recovery returned success")
        } catch let error as NativeRPCError { #expect(error.message.contains("restore journal")); #expect(!error.message.contains("was recovered")) }
        #expect(await fake.isRunning(BackendAppsDataBackupFixture.candidateID))
        #expect(await fake.isAttached(BackendAppsDataBackupFixture.candidateID))
        #expect(!(await fake.isRunning(BackendAppsDataBackupFixture.originalID)))
        #expect((await fake.volumes).count == 2)
        #expect(!(await fake.calls).contains { $0.method == "DELETE" })
        #expect((await fake.files)[fake.directory + "/data-restore-intent.json"] != nil)
        #expect(!(await fake.audits).contains { $0.operation == "remove-transaction-candidates" })
        #expect((await fake.audits).contains { $0.event == "finished" && $0.operation == "recover-owned-database-pair" && $0.successful == false })
        let candidate = try #require((await fake.calls).first { $0.path.hasPrefix("/containers/create") }?.body)
        #expect(candidate["Labels"]["io.terminaldeck.transaction"].string != nil)
    }

    @Test func typedDatabaseRecoveryRestoresCapturedStateAndOnlyThenClearsJournalAfterReceiptRevocation() async throws {
        let fake = try BackendAppsDataBackupFixture()
        await fake.setImportFailure()
        await fake.setRecoveryDenied()
        let kernel = await fake.recoveryKernel()
        let context = NativeRPCContext(caller: .page, ownerID: "backup-owner", capabilities: ["apps.write"])
        do {
            _ = try await NativeCompositionCallContext.$rpc.withValue(context) {
                try await fake.service(recovery: kernel).restore(serverID: "saved-server", appID: fake.appID, backupID: "td-test-backup", confirmation: "Test database")
            }
            Issue.record("Failed data import was reported as a successful restore")
        } catch let error as NativeRPCError {
            #expect(error.code == "restore-failed")
            #expect(error.message.contains("original database was recovered"))
        }
        #expect(await fake.isRunning(BackendAppsDataBackupFixture.originalID))
        #expect(await fake.hasStableAlias(BackendAppsDataBackupFixture.originalID))
        #expect(!(await fake.isRunning(BackendAppsDataBackupFixture.candidateID)))
        #expect(!(await fake.isAttached(BackendAppsDataBackupFixture.candidateID)))
        #expect((await fake.volumes).count == 2)
        #expect(!(await fake.calls).contains { $0.method == "DELETE" })
        let files = await fake.files
        let record = try NativeRPCValue.parseJSON(try #require(files[fake.directory + "/state.json"]))
        #expect(record["database"]["containerId"].string == BackendAppsDataBackupFixture.originalID)
        #expect(record["database"]["volumeName"].string == fake.originalVolume)
        #expect(files[fake.directory + "/data-restore-intent.json"] == nil)
        #expect(files[fake.directory + "/.lock/owner"] == nil)
        let finished = (await fake.audits).filter { $0.event == "finished" }
        let database = try #require(finished.firstIndex { $0.operation == "recover-owned-database-pair" && $0.successful == true })
        let filesAfter = finished.enumerated().filter { $0.offset > database && $0.element.operation == "restore-captured-file" && $0.element.successful == true }
        #expect(filesAfter.count == 2)
        #expect((await fake.closedRecoveryTransports) == 1)
    }

    @Test func differentBackupSoftwareIsUnavailableBeforeAnyTypedRestoreMutation() async throws {
        let fake = try BackendAppsDataBackupFixture()
        try await fake.seedBackupImage(imageID: "sha256:" + String(repeating: "e", count: 64), image: "postgres:16")
        let kernel = await fake.recoveryKernel()
        let context = NativeRPCContext(caller: .page, ownerID: "backup-owner", capabilities: ["apps.write"])
        do {
            _ = try await NativeCompositionCallContext.$rpc.withValue(context) {
                try await fake.service(recovery: kernel).restore(serverID: "saved-server", appID: fake.appID, backupID: "td-test-backup", confirmation: "Test database")
            }
            Issue.record("Unsupported cross-version typed recovery reached a data mutation")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable"); #expect(error.message.contains("same exact software")) }
        #expect((await fake.calls).isEmpty)
        #expect((await fake.volumes).count == 1)
        #expect(await fake.isRunning(BackendAppsDataBackupFixture.originalID))
        #expect((await fake.files)[fake.directory + "/data-restore-intent.json"] == nil)
        #expect((await fake.files)[fake.directory + "/.lock/owner"] == nil)
    }

    @Test func lostInitialJournalReplyRecoversItsSealedBeforeImageWithoutCreatingDataResources() async throws {
        let fake = try BackendAppsDataBackupFixture()
        await fake.setJournalReplyLost()
        let kernel = await fake.recoveryKernel()
        let context = NativeRPCContext(caller: .page, ownerID: "backup-owner", capabilities: ["apps.write"])
        do {
            _ = try await NativeCompositionCallContext.$rpc.withValue(context) {
                try await fake.service(recovery: kernel).restore(serverID: "saved-server", appID: fake.appID, backupID: "td-test-backup", confirmation: "Test database")
            }
            Issue.record("Lost journal reply returned a successful restore")
        } catch let error as NativeRPCError {
            #expect(error.code == "restore-failed")
            #expect(error.message.contains("original database was recovered"))
            #expect(!error.message.contains("fake-secret"))
        }
        #expect((await fake.calls).allSatisfy { $0.method == "GET" })
        #expect((await fake.volumes).count == 1)
        #expect(await fake.isRunning(BackendAppsDataBackupFixture.originalID))
        #expect(await fake.hasStableAlias(BackendAppsDataBackupFixture.originalID))
        #expect((await fake.files)[fake.directory + "/data-restore-intent.json"] == nil)
        #expect((await fake.files)[fake.directory + "/.lock/owner"] == nil)
        #expect((await fake.audits).contains { $0.event == "finished" && $0.operation == "recover-owned-database-pair" && $0.successful == true })
    }

    @Test func transportErrorBeforeMutationNeverLeaksRawSecret() async throws {
        let fake = try BackendAppsDataBackupFixture()
        await fake.setImageTransportFailure()
        do {
            _ = try await fake.service().restore(serverID: "saved-server", appID: fake.appID, backupID: "td-test-backup", confirmation: "Test database")
            Issue.record("Missing image transport returned success")
        } catch let error as NativeRPCError {
            #expect(error.code == "unavailable")
            #expect(!error.message.contains("fake-secret"))
        }
        #expect((await fake.calls).allSatisfy { $0.method == "GET" })
    }

    @Test func invalidScheduleAndPartialCredentialsNeverReachServer() async throws {
        for request in [
            policy().setting("schedule", .string("daily\nExecStart=/tmp/nope")),
            policy().setting("schedule", .string("daily\n")),
            policy().setting("retention", .number(0)),
            policy().setting("upload", upload().setting("secretKey", .missing))
        ] {
            let fake = try BackendAppsDataBackupFixture()
            do {
                _ = try await fake.service().policy(serverID: "saved-server", appID: fake.appID, request: request)
                Issue.record("Invalid policy reached a successful save")
            } catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
            #expect((await fake.commands).isEmpty)
            #expect((await fake.calls).isEmpty)
        }
    }

    @Test func uploadDestinationChangesRequireBothReplacementKeys() throws {
        let existing = try BackendAppsDataS3Upload(upload())
        let same = policy().setting("upload", existing.publicValue)
        #expect(try BackendAppsDataBackupPolicy(request: same, preserving: existing).upload?.publicValue == existing.publicValue)
        do {
            _ = try BackendAppsDataBackupPolicy(request: same.setting("upload", existing.publicValue.setting("endpoint", .string("https://other.example.invalid"))), preserving: existing)
            Issue.record("New endpoint inherited a saved credential")
        } catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        #expect(try BackendAppsDataBackupPolicy(request: policy().setting("upload", .null), preserving: existing).upload?.publicValue == nil)
    }

    @Test func scheduleOffPreservesUploadAndProtectedCredentialsUntilExplicitRemoval() async throws {
        let fake = try BackendAppsDataBackupFixture()
        let originalPolicy = policy().setting("upload", try BackendAppsDataS3Upload(upload()).publicValue)
        try await fake.seedPolicy(originalPolicy, credentials: try BackendAppsDataS3Upload(upload()).protectedCredentials)
        let disabled = try await fake.service().policy(serverID: "saved-server", appID: fake.appID, request: BackendAppsValidation.object([("enabled", .bool(false))]))
        #expect(disabled["enabled"].bool == false)
        #expect(disabled["upload"]["endpoint"].string == "https://s3.example.invalid")
        #expect(disabled["schedule"].string == "daily")
        #expect((await fake.files)[fake.directory + "/.backup-s3-credentials"] != nil)
        #expect(!disabled.compact.contains("fake-access") && !disabled.compact.contains("fake-secret"))
        let removed = try await fake.service().policy(serverID: "saved-server", appID: fake.appID, request: BackendAppsValidation.object([("enabled", .bool(false)), ("upload", .null)]))
        #expect(removed["upload"] == .missing)
        #expect((await fake.files)[fake.directory + "/.backup-s3-credentials"] == nil)
    }

    @Test func scheduleOnlyEditPreservesSavedUploadWithoutReturningSecrets() async throws {
        let fake = try BackendAppsDataBackupFixture(), existing = try BackendAppsDataS3Upload(upload())
        try await fake.seedPolicy(policy().setting("upload", existing.publicValue), credentials: existing.protectedCredentials)
        let result = try await fake.service().policy(serverID: "saved-server", appID: fake.appID, request: policy().setting("retention", .number(12)))
        #expect(result["retention"].number == 12)
        #expect(result["upload"]["endpoint"].string == existing.endpoint)
        #expect(!result.compact.contains("fake-secret"))
        #expect(!(await fake.commands).contains { $0.contains("fake-secret") || $0.contains("fake-access") })
    }

    @Test func malformedPreservedCredentialsFailBeforeDockerMutation() async throws {
        let fake = try BackendAppsDataBackupFixture(), existing = try BackendAppsDataS3Upload(upload())
        try await fake.seedPolicy(policy().setting("upload", existing.publicValue), credentials: Data("[foreign]\nsecret=fake-secret\n".utf8))
        do {
            _ = try await fake.service().policy(serverID: "saved-server", appID: fake.appID, request: policy())
            Issue.record("Malformed credentials were reused")
        } catch let error as NativeRPCError { #expect(error.code == "state-failed"); #expect(!error.message.contains("fake-secret")) }
        #expect((await fake.calls).isEmpty)
    }

    @Test func failedTimerTransactionReturnsFailureAndPreservesPriorPolicy() async throws {
        let fake = try BackendAppsDataBackupFixture()
        await fake.setPolicyFailure()
        do {
            _ = try await fake.service().policy(serverID: "saved-server", appID: fake.appID, request: policy().setting("upload", upload()))
            Issue.record("An unverified timer transaction returned a saved policy")
        } catch let error as NativeRPCError { #expect(error.code == "state-failed"); #expect(!error.message.contains("fake-secret")) }
        let policy = try await fake.service().policyRead(serverID: "saved-server", appID: fake.appID)
        #expect(policy["enabled"].bool == false)
        #expect(policy["upload"] == .missing)
        #expect((await fake.files)[fake.directory + "/.backup-s3-credentials"] == nil)
        #expect((await fake.policyTransactions) == 1)
    }

    @Test func trailingControlsAndUnsafeS3ValuesAreRejected() throws {
        for value in [upload().setting("accessKey", .string("fake-access\n")), upload().setting("secretKey", .string("fake-secret\r")), upload().setting("bucket", .string("td-test-bucket\n")), upload().setting("prefix", .string("saved\n")), upload().setting("prefix", .string("../foreign")), upload().setting("endpoint", .string("http://s3.example.invalid")), upload().setting("endpoint", .string("https://user:fake-secret@s3.example.invalid"))] {
            do { _ = try BackendAppsDataS3Upload(value); Issue.record("Unsafe S3 value was accepted") }
            catch let error as NativeRPCError { #expect(error.code == "invalid-arguments") }
        }
    }

    @Test func manifestsWhitelistPublicFieldsAndRejectMismatchedIdentity() throws {
        let fake = try BackendAppsDataBackupFixture(), service = fake.service()
        let valid = BackendAppsDataBackupFixture.manifest().setting("accessKey", .string("fake-access")).setting("private", BackendAppsValidation.object([("password", .string("fake-secret"))]))
        let result = try service.publicManifest(valid, appID: fake.appID, kind: "postgres", expectedID: "td-test-backup")
        #expect(result["imageId"] == .missing)
        #expect(!result.compact.contains("fake-secret") && !result.compact.contains("fake-access"))
        for bad in [valid.setting("id", .string("td-test-backup\n")), valid.setting("appId", .string("other-app")), valid.setting("kind", .string("mysql")), valid.setting("verified", .bool(false)), valid.setting("bytes", .number(1.5)), valid.setting("sha256", .string(String(repeating: "c", count: 64) + "\n"))] {
            do { _ = try service.publicManifest(bad, appID: fake.appID, kind: "postgres"); Issue.record("Invalid manifest became public") }
            catch let error as NativeRPCError { #expect(error.code == "backup-failed") }
        }
    }

    @Test func generatedServerProgramsPreserveSafetyOrderingAndCompleteDumpCommands() throws {
        let script = try BackendAppsDataBackupRunner.script(directory: "/var/lib/td-test-apps/td-test-data", appID: "td-test-data", prefix: "td-test", network: "td-test-apps")
        for command in ["pg_dump", "mysqldump", "redis-check-rdb", "mongodump", "fsyncUnlock"] { #expect(script.contains(command)) }
        #expect(script.components(separatedBy: "if(!(r===1||(r&&r.ok===1)))quit(1);").count - 1 == 2)
        #expect(!script.contains("MONGO_INITDB_ROOT_PASSWORD)!==1"))
        #expect(!script.contains("source ") && !script.contains(". \"$dir/.env\""))
        #expect(script.contains("/data/configdb"))
        #expect(script.contains("test ! -L \"$catalog.ids\""))
        let claim = try #require(script.range(of: "mkdir -- \"$candidate\"")), assignment = try #require(script.range(of: "work=\"$candidate\""))
        #expect(claim.lowerBound < assignment.lowerBound)
        let verify = try #require(script.range(of: "sha256sum \"$work/upload-check\"")), publish = try #require(script.range(of: "mv -- \"$work\" \"$dir/backups/$id\"")), retention = try #require(script.range(of: "# Retention starts only"))
        #expect(verify.lowerBound < publish.lowerBound && publish.lowerBound < retention.lowerBound)
        #expect(script.contains("get-object") && script.contains("--version-id"))
        #expect(script.contains(".id == $id and .appId == $app"))
        let parsed = try BackendAppsDataBackupPolicy(request: policy())
        let schedule = try BackendAppsDataBackupSchedule.transaction(directory: "/var/lib/td-test-apps/td-test-data", appID: "td-test-data", prefix: "td-test", policy: parsed)
        #expect(schedule.contains("policy-in-progress"))
        #expect(schedule.contains("policy-recovery-required"))
        #expect(schedule.contains("mv -f -- \"$work/$name.restore\" \"$target\""))
        #expect(!schedule.contains("cp -p -- \"$work/$name.saved\" \"$target\""))
        let units = try BackendAppsDataBackupSchedule.unit(directory: "/var/lib/td-test-apps/td-test-data", appID: "td-test-data", prefix: "td-test", policy: parsed)
        #expect(units.timer.contains("Persistent=true"))
        #expect(units.service.contains("StandardOutput=null") && units.service.contains("StandardError=null"))
    }

    @Test func changedMongoAuthSourceRefusesPartialOrUnknownTransformation() throws {
        let old = #"if(db.getSiblingDB("admin").auth(a.MONGO_INITDB_ROOT_USERNAME,a.MONGO_INITDB_ROOT_PASSWORD)!==1) quit(1);"#
        let transformed = try BackendAppsDataBackupRunner.compatibleMongoAuthentication(old + "\nfsyncLock();\n" + old + "\nfsyncUnlock();")
        #expect(transformed.contains("fsyncLock();") && transformed.contains("fsyncUnlock();"))
        #expect(try BackendAppsDataBackupRunner.compatibleMongoAuthentication(transformed) == transformed)
        do { _ = try BackendAppsDataBackupRunner.compatibleMongoAuthentication(old); Issue.record("Partial maintained auth logic was silently adapted") }
        catch let error as NativeRPCError { #expect(error.code == "unavailable") }
    }

    private func policy() -> NativeRPCValue { BackendAppsValidation.object([("enabled", .bool(true)), ("schedule", .string("daily")), ("retention", .number(7))]) }
    private func upload() -> NativeRPCValue { BackendAppsValidation.object([("endpoint", .string("https://s3.example.invalid")), ("bucket", .string("td-test-bucket")), ("prefix", .string("saved")), ("accessKey", .string("fake-access")), ("secretKey", .string("fake-secret"))]) }
}

/// In-memory SSH/API seam. It records requests; it never opens a socket or runs shell.
actor BackendAppsDataBackupFixture {
    struct Call: Sendable { let method: String, path: String; let body: NativeRPCValue? }
    struct TimerState: Sendable {
        var enabled: Bool, active: Bool
        var loaded = true
        var needsReload = false
        var fragment = "/etc/systemd/system/td-test-td-test-data-backup.timer"
    }
    nonisolated let appID = "td-test-data"
    nonisolated let directory = "/var/lib/td-test-apps/td-test-data"
    nonisolated let originalVolume = "td-test-td-test-data-data"
    static let originalID = String(repeating: "a", count: 64)
    static let candidateID = String(repeating: "b", count: 64)
    static let imageID = "sha256:" + String(repeating: "d", count: 64)
    private(set) var calls: [Call] = []
    private(set) var commands: [String] = []
    private(set) var files: [String: Data] = [:]
    private(set) var volumes: [String: NativeRPCValue] = [:]
    private(set) var audits: [BackendAppsRecoveryAudit] = []
    private(set) var closedRecoveryTransports = 0
    private(set) var policyTransactions = 0
    private var timers: [String: TimerState] = [:]
    private var locks: Set<String> = []
    private var candidateVolume: String?
    private var candidateLabels: NativeRPCValue = .missing
    private var running: [String: Bool] = [BackendAppsDataBackupFixture.originalID: true]
    private var aliases: [String: [String]] = [BackendAppsDataBackupFixture.originalID: ["td-test-td-test-data"]]
    private var checksumFailure = false, wrongToken = false, importFailure = false, connectLost = false, recoveryRestartFailure = false, noOpDisconnect = false, imageFailure = false, denyRecovery = false, revoked = false, policyFailure = false, candidateStopFailure = false, revokeOnPolicyFailure = false, journalReplyLost = false

    init() throws {
        let database = BackendAppsValidation.object([("kind", .string("postgres")), ("containerId", .string(Self.originalID)), ("volumeName", .string(originalVolume)), ("image", .string("postgres:17")), ("imageId", .string(Self.imageID)), ("network", .string("td-test-apps")), ("dataPath", .string("/var/lib/postgresql/data"))])
        let record = BackendAppsValidation.object([("id", .string(appID)), ("name", .string("Test database")), ("kind", .string("postgres")), ("status", .string("running")), ("containerId", .string(Self.originalID)), ("database", database), ("backupPolicy", BackendAppsValidation.object([("enabled", .bool(false))]))])
        files[directory + "/state.json"] = try record.encodedJSON()
        files[directory + "/backups/td-test-backup/manifest.json"] = try Self.manifest().encodedJSON()
        files[directory + "/.env"] = Data("POSTGRES_USER=terminaldeck\nPOSTGRES_PASSWORD=fake-password\nPOSTGRES_DB=terminaldeck\n".utf8)
        volumes[originalVolume] = BackendAppsValidation.object([("Name", .string(originalVolume)), ("Driver", .string("local")), ("Labels", Self.labels()), ("Options", .null)])
    }
    nonisolated func service(recovery: BackendAppsRecovery? = nil) -> BackendAppsDataBackups {
        let runtime = BackendAppsRuntime(execute: { [self] _, command, stdin, _, _ in try await execute(command, stdin) }, docker: { [self] _, method, path, body in try await docker(method, path, body) }, privateNetwork: "td-test-apps", resourcePrefix: "td-test", stateRoot: "/var/lib/td-test-apps", recovery: recovery, now: { 1_797_000_000_000 })
        return BackendAppsDataBackups(runtime: runtime, store: BackendAppsStore(runtime: runtime))
    }
    func setChecksumFailure() { checksumFailure = true }
    func setWrongVolumeToken() { wrongToken = true }
    func setImportFailure() { importFailure = true }
    func setConnectResponseLost() { connectLost = true }
    func setRecoveryRestartFailure() { recoveryRestartFailure = true }
    func setNoOpCandidateDisconnect() { noOpDisconnect = true }
    func setImageTransportFailure() { imageFailure = true }
    func setRecoveryDenied() { denyRecovery = true }
    func setPolicyFailure(revoke: Bool = false) { policyFailure = true; revokeOnPolicyFailure = revoke }
    func setCandidateStopFailure() { candidateStopFailure = true }
    func setJournalReplyLost() { journalReplyLost = true }
    func hasStableAlias(_ id: String) -> Bool { aliases[id]?.contains("td-test-td-test-data") == true }
    func isAttached(_ id: String) -> Bool { aliases[id] != nil }
    func isRunning(_ id: String) -> Bool { running[id] == true }
    func seedBackupTimerBaseline(enabled: Bool, active: Bool) {
        let unit = "td-test-td-test-data-backup"
        let marker = "# Terminal Deck managed backup for " + appID
        files["/etc/systemd/system/" + unit + ".service"] = Data((marker + "\n[Service]\nType=oneshot\n").utf8)
        files["/etc/systemd/system/" + unit + ".timer"] = Data((marker + "\n[Timer]\nOnCalendar=daily\nPersistent=true\n").utf8)
        timers[unit + ".timer"] = TimerState(enabled: enabled, active: active)
    }
    func backupTimerState() -> TimerState? { timers["td-test-td-test-data-backup.timer"] }
    func recoveryKernel() -> BackendAppsRecovery {
        BackendAppsRecovery(capture: { [self] scope, context in
            try await registration(context)
            guard scope.serverID == "saved-server", scope.appID == appID else { throw NativeRPCError(code: "access-denied", message: "Wrong recovery scope") }
            return BackendAppsRecoveryTransport(execute: { [self] _, command, stdin, _, _ in try await execute(command, stdin, sealed: true) }, docker: { [self] _, method, path, body in try await docker(method, path, body, sealed: true) }, caddy: { _, _, _, _ in throw BackendAppsRuntime.unavailable("No route in database recovery fixture") }, authorizeRegistration: { [self] context in try await registration(context) }, validateBinding: {}, close: { [self] in await closeRecovery() })
        }, audit: { [self] entry in await recordAudit(entry) })
    }
    private func registration(_ context: NativeRPCContext?) throws {
        guard !revoked, context?.ownerID == "backup-owner", context?.capabilities.contains("apps.write") == true else { throw NativeRPCError(code: "access-denied", message: "Original receipt revoked") }
    }
    private func closeRecovery() { closedRecoveryTransports += 1 }
    private func recordAudit(_ entry: BackendAppsRecoveryAudit) { audits.append(entry) }
    func seedPolicy(_ policy: NativeRPCValue, credentials: Data) throws {
        let record = try NativeRPCValue.parseJSON(files[directory + "/state.json"]!)
        files[directory + "/state.json"] = try record.setting("backupPolicy", policy).encodedJSON()
        files[directory + "/.backup-s3-credentials"] = credentials
    }
    func seedBackupImage(imageID: String, image: String) throws {
        files[directory + "/backups/td-test-backup/manifest.json"] = try Self.manifest().setting("imageId", .string(imageID)).setting("image", .string(image)).encodedJSON()
    }
    private func execute(_ command: String, _ stdin: Data?, sealed: Bool = false) throws -> BackendServersRunResult {
        if revoked && !sealed { throw NativeRPCError(code: "access-denied", message: "fake-secret revoked RPC") }
        commands.append(command)
        let words = BackendAppsDatabaseFixture.words(command)
        let script = words.first == "sh" && words.dropFirst().first == "-c" ? words.dropFirst(2).first ?? "" : command
        if let stdin {
            if let acquire = Self.captures(#"mkdir -- '([^']+/\.lock)' 2>/dev/null \|\| exit 73; cat > '([^']+/\.lock/owner)' \|\| exit 45"#, in: script) {
                let lock = directory + "/.lock"
                guard acquire == [lock, lock + "/owner"] else { return .init(code: 45, stdout: "") }
                guard locks.insert(lock).inserted else { return .init(code: 73, stdout: "") }
                files[lock + "/owner"] = stdin
                return .init(code: 0, stdout: "")
            }
            if let value = try? NativeRPCValue.parseJSON(stdin), value["policy"].fields != nil {
                policyTransactions += 1
                if policyFailure {
                    if revokeOnPolicyFailure {
                        // Model a partially accepted server transaction whose ordinary reply/rollback
                        // authority is lost. Sealed recovery must restore changed bytes and timer state.
                        let record = try NativeRPCValue.parseJSON(files[directory + "/state.json"]!)
                        files[directory + "/state.json"] = try record.setting("backupPolicy", value["policy"]).encodedJSON()
                        files[directory + "/backup-policy.json"] = try value["policy"].encodedJSON()
                        files[directory + "/backup-run.sh"] = value["runner"].string.map { Data($0.utf8) }
                        files[directory + "/.backup-s3-credentials"] = value["credentials"].string.map { Data($0.utf8) }
                        files["/etc/systemd/system/td-test-td-test-data-backup.service"] = value["service"].string.map { Data($0.utf8) }
                        files["/etc/systemd/system/td-test-td-test-data-backup.timer"] = value["timer"].string.map { Data($0.utf8) }
                        files[directory + "/data-backup-policy-recovery.json"] = Data(#"{"phase":"policy-recovery-required"}"#.utf8)
                        timers["td-test-td-test-data-backup.timer"] = TimerState(enabled: true, active: true)
                        revoked = true
                    }
                    return .init(code: 74, stdout: "", stderr: "fake-secret timer error")
                }
                let record = try NativeRPCValue.parseJSON(files[directory + "/state.json"]!)
                files[directory + "/state.json"] = try record.setting("backupPolicy", value["policy"]).encodedJSON()
                files[directory + "/backup-policy.json"] = try value["policy"].encodedJSON()
                files[directory + "/.backup-s3-credentials"] = value["credentials"].string.map { Data($0.utf8) }
                return .init(code: 0, stdout: "")
            }
            if let line = script.split(separator: "\n").first(where: { $0.hasPrefix("mv -f -- ") }), let path = BackendAppsDatabaseFixture.words(String(line)).last {
                putFile(stdin, path: path)
                if !sealed, journalReplyLost, path == directory + "/data-restore-intent.json" {
                    journalReplyLost = false
                    revoked = true
                    throw NativeRPCError(code: "unavailable", message: "fake-secret journal write reply lost")
                }
            }
            if sealed, script.contains("mv -f -- "), script.contains(".recovery-") {
                let pieces = script.components(separatedBy: "mv -f -- ")
                if pieces.count > 1, let line = pieces.last?.components(separatedBy: ";").first, let path = BackendAppsDatabaseFixture.words(line).last { putFile(stdin, path: path) }
            }
            return .init(code: 0, stdout: "")
        }
        // A command substitution used to prove a lock is not an ordinary file read.
        // Verify the exact captured owner before any release; mismatched peer locks remain intact.
        if let proof = Self.captures(#"\$\(cat -- '([^']+/\.lock/owner)'\)" = '([^']+)'"#, in: script), proof.count == 2 {
            let ownerPath = proof[0], expectedOwner = proof[1]
            guard ownerPath == directory + "/.lock/owner" else { return .init(code: 45, stdout: "") }
            let lock = directory + "/.lock"
            if sealed, script.contains("rmdir -- "), !locks.contains(lock) { return .init(code: 0, stdout: "") }
            guard locks.contains(lock), files[ownerPath] == Data(expectedOwner.utf8) else { return .init(code: 1, stdout: "") }
            if let release = Self.captures(#"rmdir -- '([^']+)'"#, in: script) {
                guard release == [directory + "/.lock"] else { return .init(code: 45, stdout: "") }
                files[ownerPath] = nil
                locks.remove(lock)
            }
            return .init(code: 0, stdout: "")
        }
        // Store and kernel snapshot reads finish with this exact cat command. Do not use
        // words.last: release/proof commands end with a lock directory or an owner token.
        if let read = Self.captures(#"(?:^|;\s*)cat -- '([^']+)'\s*\z"#, in: script), let path = read.first {
            guard let data = files[path] else { return .init(code: 44, stdout: "") }
            return .init(code: 0, stdout: String(decoding: data, as: UTF8.self))
        }
        if script.contains("for file in data-restore-intent.json data-backup-policy-recovery.json"), files[directory + "/data-restore-intent.json"] != nil || files[directory + "/data-backup-policy-recovery.json"] != nil { return .init(code: 73, stdout: "") }
        if script.contains("sha256sum \"$file\""), checksumFailure { return .init(code: 1, stdout: "") }
        if sealed, script.contains("sha256sum -- "), let part = script.components(separatedBy: "sha256sum -- ").last,
           let path = BackendAppsDatabaseFixture.words(part).first, let contents = files[path] {
            return .init(code: 0, stdout: SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined())
        }
        if let assignment = Self.captures(#"td_timer_file='([^']+)'"#, in: script), let path = assignment.first {
            guard path == "/etc/systemd/system/td-test-td-test-data-backup.timer" else { return .init(code: 45, stdout: "") }
            let marker = "# Terminal Deck managed backup for " + appID
            guard let bytes = files[path] else { return .init(code: 0, stdout: "absent\n") }
            guard String(decoding: bytes, as: UTF8.self).split(separator: "\n").contains(Substring(marker)) else { return .init(code: 45, stdout: "") }
            return .init(code: 0, stdout: "present\n")
        }
        if script.hasPrefix("systemctl ") {
            return try timerCommand(script)
        }
        if sealed, script.contains("rm -f -- "), let part = script.components(separatedBy: "rm -f -- ").last,
           let path = BackendAppsDatabaseFixture.words(part.components(separatedBy: ";").first ?? "").first { putFile(nil, path: path) }
        if script.hasPrefix("set -eu; docker exec -i "), importFailure { if denyRecovery { revoked = true }; return .init(code: 1, stdout: "") }
        if script.contains("; rm -- "), script.contains("data-restore-intent.json") { files[directory + "/data-restore-intent.json"] = nil }
        return .init(code: 0, stdout: "")
    }
    private func putFile(_ data: Data?, path: String) {
        let changed = files[path] != data
        files[path] = data
        if changed, path == "/etc/systemd/system/td-test-td-test-data-backup.timer",
           var timer = timers["td-test-td-test-data-backup.timer"], timer.loaded {
            timer.needsReload = true
            timers["td-test-td-test-data-backup.timer"] = timer
        }
    }
    private func timerCommand(_ script: String) throws -> BackendServersRunResult {
        let unit = "td-test-td-test-data-backup.timer", path = "/etc/systemd/system/" + unit
        let arguments = BackendAppsDatabaseFixture.words(script)
        if script == "systemctl daemon-reload" {
            if var timer = timers[unit] {
                if files[path] != nil { timer.loaded = true; timer.fragment = path; timer.needsReload = false }
                else if !timer.enabled && !timer.active { timer.loaded = false; timer.fragment = ""; timer.needsReload = false }
                else { timer.needsReload = true } // PID 1 can still own an enabled/active cached unit.
                timers[unit] = timer
            }
            return .init(code: 0, stdout: "")
        }
        if arguments.count == 11, Array(arguments.prefix(4)) == ["systemctl", "show", "--no-pager", "--all"],
           Set(arguments[4..<9]) == Set(["--property=FragmentPath", "--property=LoadState", "--property=UnitFileState", "--property=ActiveState", "--property=NeedDaemonReload"]),
           arguments[9] == "--", arguments[10] == unit {
            if timers[unit] == nil, files[path] != nil { timers[unit] = TimerState(enabled: false, active: false) }
            guard let timer = timers[unit], timer.loaded else {
                return .init(code: 0, stdout: "FragmentPath=\nLoadState=not-found\nUnitFileState=not-found\nActiveState=inactive\nNeedDaemonReload=no\n")
            }
            return .init(code: 0, stdout: "ActiveState=" + (timer.active ? "active" : "inactive") + "\nFragmentPath=" + timer.fragment + "\nNeedDaemonReload=" + (timer.needsReload ? "yes" : "no") + "\nLoadState=loaded\nUnitFileState=" + (timer.enabled ? "enabled" : "disabled") + "\n")
        }
        guard arguments.count == 4, arguments[0] == "systemctl", arguments[2] == "--", arguments[3] == unit,
              ["stop", "start", "enable", "disable"].contains(arguments[1]) else { return .init(code: 64, stdout: "") }
        guard var timer = timers[unit], timer.loaded else { return .init(code: 5, stdout: "") }
        if ["start", "enable"].contains(arguments[1]) {
            let marker = "# Terminal Deck managed backup for " + appID
            guard let bytes = files[path], String(decoding: bytes, as: UTF8.self).split(separator: "\n").contains(Substring(marker)) else { return .init(code: 45, stdout: "") }
        }
        switch arguments[1] {
        case "stop": timer.active = false
        case "start": timer.active = true
        case "disable": timer.enabled = false
        case "enable": timer.enabled = true
        default: return .init(code: 64, stdout: "")
        }
        timers[unit] = timer
        return .init(code: 0, stdout: "")
    }
    private func docker(_ method: String, _ path: String, _ data: Data?, sealed: Bool = false) throws -> BackendAppsHTTPResponse {
        if revoked && !sealed { throw NativeRPCError(code: "access-denied", message: "fake-secret revoked RPC") }
        let body = try data.map { try NativeRPCValue.parseJSON($0) }
        calls.append(.init(method: method, path: path, body: body))
        if method == "GET", path.hasPrefix("/images/") {
            if imageFailure { throw NativeRPCError(code: "unavailable", message: "fake-secret-transport") }
            return try response(200, BackendAppsValidation.object([("Id", .string(Self.imageID))]))
        }
        if method == "GET", path.hasPrefix("/containers/json?") {
            guard let components = URLComponents(string: "https://fake.invalid" + path),
                  let filterText = components.queryItems?.first(where: { $0.name == "filters" })?.value else { return .init(status: 400) }
            let filters = try NativeRPCValue.parseJSON(Data(filterText.utf8))
            let labels = filters["label"].elements?.compactMap(\.string) ?? []
            guard labels.count == 3, labels.contains("io.terminaldeck.app=" + appID), labels.contains("io.terminaldeck.managed=true"),
                  labels.filter({ $0.hasPrefix("io.terminaldeck.transaction=") }).count == 1 else { return .init(status: 400) }
            let rows: [NativeRPCValue]
            if running[Self.candidateID] != nil, labels.allSatisfy({ filter in
                guard let split = filter.firstIndex(of: "=") else { return false }
                return candidateLabels[String(filter[..<split])].string == String(filter[filter.index(after: split)...])
            }) {
                rows = [BackendAppsValidation.object([("Id", .string(Self.candidateID)), ("Labels", candidateLabels)])]
            } else { rows = [] }
            return try response(200, .array(rows))
        }
        if method == "GET", path.hasPrefix("/volumes/") { let name = String(path.dropFirst("/volumes/".count)); return try response(volumes[name] == nil ? 404 : 200, volumes[name] ?? .null) }
        if method == "POST", path == "/volumes/create", let body, let name = body["Name"].string {
            candidateVolume = name
            let labels = wrongToken ? body["Labels"].setting("io.terminaldeck.restore-token", .string("different-operation")) : body["Labels"]
            volumes[name] = BackendAppsValidation.object([("Name", .string(name)), ("Driver", .string("local")), ("Labels", labels), ("Options", .null)])
            return try response(201, volumes[name]!)
        }
        if method == "POST", path.hasPrefix("/containers/create"), let body {
            candidateLabels = body["Labels"]
            running[Self.candidateID] = false
            aliases[Self.candidateID] = []
            return try response(201, BackendAppsValidation.object([("Id", .string(Self.candidateID))]))
        }
        if method == "GET", path.hasPrefix("/containers/"), path.hasSuffix("/json") {
            let id = String(path.dropFirst("/containers/".count).dropLast("/json".count))
            return try response(200, container(id))
        }
        if method == "POST", path.hasPrefix("/containers/"), path.contains("/stop?") {
            let id = String(path.dropFirst("/containers/".count).prefix(while: { $0 != "/" }))
            if id == Self.candidateID && candidateStopFailure { return .init(status: 500) }
            running[id] = false
            return .init(status: 204)
        }
        if method == "POST", path.hasPrefix("/containers/"), path.hasSuffix("/start") {
            let id = String(path.dropFirst("/containers/".count).dropLast("/start".count))
            if id == Self.originalID && recoveryRestartFailure { return .init(status: 500) }
            running[id] = true
            return .init(status: 204)
        }
        if method == "POST", path.hasSuffix("/disconnect"), let id = body?["Container"].string {
            if !(id == Self.candidateID && noOpDisconnect) { aliases[id] = nil }
            return .init(status: 200)
        }
        if method == "POST", path.hasSuffix("/connect"), let id = body?["Container"].string {
            aliases[id] = body?["EndpointConfig"]["Aliases"].elements?.compactMap(\.string) ?? []
            if id == Self.candidateID && connectLost { connectLost = false; throw NativeRPCError(code: "unavailable", message: "fake-secret-after-connect") }
            return .init(status: 200)
        }
        return .init(status: 500)
    }
    private func container(_ id: String) throws -> NativeRPCValue {
        let labels = id == Self.originalID ? Self.labels() : candidateLabels
        let volume = id == Self.originalID ? originalVolume : candidateVolume ?? ""
        let health = try BackendAppsDataDatabases.authenticatedHealthcheck(kind: "postgres")
        let network = aliases[id].map { BackendAppsValidation.object([("td-test-apps", BackendAppsValidation.object([("Aliases", .array($0.map(NativeRPCValue.string)))]))]) } ?? .object([])
        return BackendAppsValidation.object([
            ("Id", .string(id)), ("Image", .string(Self.imageID)),
            ("Config", BackendAppsValidation.object([("Labels", labels), ("Healthcheck", BackendAppsValidation.object([("Test", .array([.string("CMD-SHELL"), .string(health)]))]))])),
            ("State", BackendAppsValidation.object([("Running", .bool(running[id] ?? false)), ("Health", BackendAppsValidation.object([("Status", .string("healthy"))]))])),
            ("HostConfig", BackendAppsValidation.object([("NetworkMode", .string("td-test-apps")), ("Privileged", .bool(false)), ("PublishAllPorts", .bool(false)), ("PortBindings", .object([]))])),
            ("Mounts", .array([BackendAppsValidation.object([("Type", .string("volume")), ("Name", .string(volume)), ("Destination", .string("/var/lib/postgresql/data")), ("RW", .bool(true))])])),
            ("NetworkSettings", BackendAppsValidation.object([("Networks", network), ("Ports", .object([]))]))
        ])
    }
    private func response(_ status: Int, _ value: NativeRPCValue) throws -> BackendAppsHTTPResponse { .init(status: status, body: try value.encodedJSON()) }
    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
    private static func labels() -> NativeRPCValue { BackendAppsValidation.object([("io.terminaldeck.app", .string("td-test-data")), ("io.terminaldeck.managed", .string("true"))]) }
    static func manifest() -> NativeRPCValue { BackendAppsValidation.object([("id", .string("td-test-backup")), ("appId", .string("td-test-data")), ("kind", .string("postgres")), ("imageId", .string(imageID)), ("image", .string("postgres:17")), ("bytes", .number(12)), ("sha256", .string(String(repeating: "c", count: 64))), ("createdAt", .number(1_797_000_000_000)), ("verified", .bool(true)), ("uploaded", .bool(false))]) }
}
