import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Apps contract presentation")
struct NativeAppsContractTests {
    private let secret = "DO_NOT_RETAIN_SECRET_8844"
    private let milliseconds = 1_700_000_000_000.0

    @Test func capabilitiesKeepReadViewsAndRequireExactRecoveryBeforeChanges() throws {
        #expect(!NativeAppsCapabilities().canChange)
        let payload = NativeRPCValue.object([
            .init("available", .bool(true)), .init("features", .array([.string("apps"), .string("logs")])),
            .init("unavailableReason", .string(secret)),
        ])
        let readOnly = try NativeAppsContract.capabilities(payload)
        #expect(readOnly.available)
        #expect(readOnly.features == Set(["apps", "logs"]))
        #expect(!readOnly.canChange)
        #expect(readOnly.unavailableMessage == "Changes are turned off because the server cannot safely undo an interrupted change.")
        #expect(!String(reflecting: readOnly).contains(secret))

        for feature in ["transaction-recovery", "apps:transaction-recovery-v2", "Apps:transaction-recovery", "future:deployment"] {
            #expect(try NativeAppsContract.capabilities(payload.setting("features", .array([.string(feature)]))).canChange == false)
        }
        let enabledPayload = payload.setting("features", .array([.string("apps"), .string("apps:transaction-recovery")]))
        let enabled = try NativeAppsContract.capabilities(enabledPayload)
        #expect(enabled.canChange)
        #expect(enabled.unavailableMessage == nil)
        let unavailable = try NativeAppsContract.capabilities(enabledPayload.setting("available", .bool(false)))
        #expect(!unavailable.canChange)
        #expect(unavailable.unavailableMessage == "App controls are not connected to this server.")
    }

    @Test func malformedCapabilitiesCannotEnableChangesByDroppingBadFields() {
        let valid = NativeRPCValue.object([
            .init("available", .bool(true)), .init("features", .array([.string("apps:transaction-recovery")])),
        ])
        let missing: [NativeRPCValue] = [.missing, .null, .bool(true), .object([]), valid.removing("available"), valid.removing("features")]
        for value in missing { expectMalformed { _ = try NativeAppsContract.capabilities(value) } }
        let invalidAvailability: [NativeRPCValue] = [.string("true"), .number(1), .null]
        for value in invalidAvailability {
            expectMalformed { _ = try NativeAppsContract.capabilities(valid.setting("available", value)) }
        }
        let invalidFeatures: [NativeRPCValue] = [.missing, .null, .string("apps:transaction-recovery"), .object([]),
            .array([.string("apps:transaction-recovery"), .bool(true)]), .array([.string("")]),
            .array([.string("apps:transaction-recovery"), .string("bad\nfeature")])]
        for value in invalidFeatures { expectMalformed { _ = try NativeAppsContract.capabilities(valid.setting("features", value)) } }
        expectMalformed { _ = try NativeAppsContract.capabilities(valid.setting("approved", .bool(true))) }
        expectMalformed { _ = try NativeAppsContract.capabilities(valid.setting("unavailableReason", .number(1))) }
        expectMalformed {
            _ = try NativeAppsContract.capabilities(.object([
                .init("available", .bool(false)), .init("available", .bool(true)),
                .init("features", .array([.string("apps:transaction-recovery")])),
            ]))
        }
    }

    @Test func aReplyForAnotherAppCannotBecomeTheSelectedCreatedApp() throws {
        #expect(try NativeAppsContract.scopedSummary(app, appID: "customer-app").id == "customer-app")
        expectMalformed { _ = try NativeAppsContract.scopedSummary(app.setting("id", .string("different-app")), appID: "customer-app") }
    }

    private var app: NativeRPCValue {
        .object([
            .init("id", .string("customer-app")), .init("name", .string("Customer app")),
            .init("kind", .string("app")), .init("status", .string("running")),
            .init("address", .string("customer-app.203.0.113.10.sslip.io")),
            .init("source", .object([
                .init("kind", .string("github")), .init("repository", .string("owner/customer-app")),
                .init("branch", .string("main")), .init("port", .number(3000)),
            ])),
            .init("activeDeploymentId", .string("deploy-current")),
            .init("createdAt", .number(milliseconds)), .init("updatedAt", .number(milliseconds)),
            .init("envKeys", .array([.string("DATABASE_URL")])),
        ])
    }

    @Test func environmentRepliesKeepOnlyNamesEvenIfAValueIsUnmasked() throws {
        let payload = NativeRPCValue.array([
            .object([.init("key", .string("DATABASE_URL")), .init("value", .string(secret)), .init("secret", .bool(true))]),
            .object([.init("key", .string("PORT")), .init("value", .string("3000")), .init("secret", .bool(false))]),
        ])
        let rows = try NativeAppsContract.environments(payload)
        #expect(rows == [NativeAppsEnvironmentKey(key: "DATABASE_URL", isSecret: true),
                         NativeAppsEnvironmentKey(key: "PORT", isSecret: true)])
        #expect(!String(reflecting: rows).contains(secret))

        let detail = try NativeAppsContract.detail(app.setting("env", .object([.init("DATABASE_URL", .string(secret))])))
        #expect(detail.environment == [NativeAppsEnvironmentKey(key: "DATABASE_URL", isSecret: true)])
        #expect(!String(reflecting: detail).contains(secret))
    }

    @Test func unreadableListsAndInvalidRowsThrowInsteadOfBecomingEmptySuccess() throws {
        let invalidLists: [NativeRPCValue] = [.missing, .null, .bool(false), .object([]), .string("unavailable")]
        for value in invalidLists {
            #expect(throws: NativeRPCError.self) { try NativeAppsContract.records(value) }
            #expect(throws: NativeRPCError.self) { try NativeAppsContract.environments(value) }
            #expect(throws: NativeRPCError.self) { try NativeAppsContract.deployments(value, activeID: nil) }
            #expect(throws: NativeRPCError.self) { try NativeAppsContract.backups(value) }
            #expect(throws: NativeRPCError.self) { try NativeAppsContract.templates(value) }
        }
        let invalidRows: [NativeRPCValue] = [.null, .bool(true), .object([])]
        for row in invalidRows {
            #expect(throws: NativeRPCError.self) { try NativeAppsContract.summary(row) }
            #expect(throws: NativeRPCError.self) { try NativeAppsContract.environments(.array([row])) }
            #expect(throws: NativeRPCError.self) { try NativeAppsContract.deployments(.array([row]), activeID: nil) }
            #expect(throws: NativeRPCError.self) { try NativeAppsContract.backups(.array([row])) }
            #expect(throws: NativeRPCError.self) { try NativeAppsContract.templates(.array([row])) }
        }
        #expect(try NativeAppsContract.environments(.array([])).isEmpty)
        #expect(try NativeAppsContract.backups(.array([])).isEmpty)
        #expect(throws: NativeRPCError.self) { try NativeAppsContract.summary(app.setting("name", .string(""))) }
    }

    @Test func malformedOptionalCollectionsDoNotSilentlyLoseSettingsOrAddresses() throws {
        let omitted = try NativeAppsContract.detail(app.removing("envKeys").removing("domains"))
        #expect(omitted.environment.isEmpty)
        let malformedCollections: [NativeRPCValue] = [.bool(false), .string("not a list"), .array([.string("valid"), .number(42)])]
        for value in malformedCollections {
            expectMalformed { _ = try NativeAppsContract.detail(app.setting("envKeys", value)) }
            expectMalformed { _ = try NativeAppsContract.detail(app.setting("domains", value)) }
        }
    }

    @Test func theDefaultHostnameBecomesAnHTTPSLinkAndAPrimaryAddress() throws {
        let summary = try NativeAppsContract.summary(app)
        #expect(summary.address == "https://customer-app.203.0.113.10.sslip.io")
        #expect(NativeAppsRules.safeAddress(summary.address)?.host == "customer-app.203.0.113.10.sslip.io")
        let detail = try NativeAppsContract.detail(app.setting("domains", .array([
            .string("customer-app.203.0.113.10.sslip.io"), .string("customer.example.com"),
        ])))
        #expect(detail.source == "owner/customer-app")
        #expect(detail.branch == "main")
        #expect(detail.port == 3000)
        #expect(detail.addresses == [NativeAppsAddress(hostname: "customer-app.203.0.113.10.sslip.io", isPrimary: true, isDefault: true),
                                    NativeAppsAddress(hostname: "customer.example.com")])
        for unsafe in ["javascript:alert(1)", "file:///tmp/app", "https://person:secret@example.com",
                       "https://customer.example.com?token=" + secret, "https://customer.example.com/" + secret] {
            #expect(try NativeAppsContract.summary(app.setting("address", .string(unsafe))).address == nil)
        }
    }

    @Test func primaryCustomAddressesStayEditableWhileAutomaticNamesStayIdentified() throws {
        let record = app.setting("address", .string("https://customer.example.com"))
            .setting("domains", .array([.string("customer.example.com"), .string("customer-app.203.0.113.10.sslip.io")]))
        let detail = try NativeAppsContract.detail(record)
        #expect(detail.addresses == [NativeAppsAddress(hostname: "customer.example.com", isPrimary: true),
                                    NativeAppsAddress(hostname: "customer-app.203.0.113.10.sslip.io", isDefault: true)])
        #expect(detail.addresses.allSatisfy { $0.httpsReady == nil && $0.dnsReady == nil })
        for host in ["customer-app.anything.sslip.io", "customer-app.256.0.113.10.sslip.io",
                     "customer-app.203.00.113.10.sslip.io", "other-app.203.0.113.10.sslip.io",
                     "customer-app.203.0.113.10.sslip.io.example.com"] {
            let rows = try NativeAppsContract.detail(app.setting("address", .string("https://" + host))).addresses
            #expect(rows.first?.isPrimary == true)
            #expect(rows.first?.isDefault == false)
        }
        let testRecord = app.setting("id", .string("td-test-customer-app"))
            .setting("address", .string("https://td-test-customer-app.178-105-239-176.sslip.io"))
        #expect(try NativeAppsContract.detail(testRecord).addresses.first?.isDefault == true)
    }

    @Test func settingAndAddressNamesCannotCarryRawValuesOrDuplicateSettingIdentities() {
        for key in ["DATABASE_URL=" + secret, "KEY\n" + secret, String(repeating: "A", count: 129)] {
            expectMalformed { _ = try NativeAppsContract.detail(app.setting("envKeys", .array([.string(key)]))) }
            expectMalformed {
                _ = try NativeAppsContract.environments(.array([.object([.init("key", .string(key)), .init("value", .string(secret))])]))
            }
        }
        expectMalformed { _ = try NativeAppsContract.detail(app.setting("envKeys", .array([.string("PORT"), .string("PORT")]))) }
        expectMalformed {
            _ = try NativeAppsContract.environments(.array([
                .object([.init("key", .string("PORT"))]), .object([.init("key", .string("PORT"))]),
            ]))
        }
        for hostname in ["https://person:" + secret + "@example.com", "app.example.com/" + secret, "app..example.com"] {
            expectMalformed { _ = try NativeAppsContract.detail(app.setting("domains", .array([.string(hostname)]))) }
        }
    }

    @Test func sourceRepositoryCredentialsNeverBecomeVisibleSourceText() throws {
        for repository in ["https://person:" + secret + "@github.com/owner/repository", "owner/repository?token=" + secret,
                           "owner/repository\n" + secret, "owner/repository\n", "owner/.."] {
            expectMalformed { _ = try NativeAppsContract.detail(app.setting("source", app["source"].setting("repository", .string(repository)))) }
        }
        #expect(try NativeAppsContract.detail(app).source == "owner/customer-app")
    }

    @Test func duplicateSavedRecordsCannotShareAnActionIdentity() {
        let deployment = NativeRPCValue.object([.init("id", .string("deploy-one")), .init("status", .string("running"))])
        let backup = NativeRPCValue.object([.init("id", .string("backup-one"))])
        let template = NativeRPCValue.object([.init("id", .string("template-one")), .init("name", .string("Template"))])
        expectMalformed { _ = try NativeAppsContract.deployments(.array([deployment, deployment]), activeID: nil) }
        expectMalformed { _ = try NativeAppsContract.backups(.array([backup, backup])) }
        expectMalformed { _ = try NativeAppsContract.templates(.array([template, template])) }
    }

    @Test func databaseAndTemplateRepliesMatchTheEngineShapes() throws {
        let database = app.setting("id", .string("customer-data")).setting("kind", .string("postgres"))
            .setting("address", .null).setting("source", .null).removing("envKeys")
        let detail = try NativeAppsContract.detail(database)
        #expect(detail.app.kind == "postgres")
        #expect(detail.app.address == nil)
        #expect(detail.source == "Database")
        #expect(detail.port == nil)
        #expect(detail.environment.isEmpty)

        // BackendAppsTemplates.list() supplies licence/credit fields but no category.
        let template = NativeRPCValue.object([
            .init("id", .string("uptime-kuma")), .init("name", .string("Uptime Kuma")),
            .init("description", .string("A status page and checks for your apps.")),
            .init("credit", .string("Adapted from Coolify by coolLabs")), .init("license", .string("Apache-2.0")),
            .init("sourceURL", .string("https://github.com/coollabsio/coolify/blob/main/templates/compose/uptime-kuma.yaml")),
            .init("requires", .array([.string("A private data volume")])),
        ])
        #expect(try NativeAppsContract.templates(.array([template])) == [
            NativeAppsTemplate(id: "uptime-kuma", name: "Uptime Kuma",
                               description: "A status page and checks for your apps.", category: "App",
                               credit: "Adapted from Coolify by coolLabs", license: "Apache-2.0",
                               sourceURL: "https://github.com/coollabsio/coolify/blob/main/templates/compose/uptime-kuma.yaml"),
        ])
        for (id, name, license, source) in [
            ("uptime-kuma", "Uptime Kuma", "MIT", "https://github.com/louislam/uptime-kuma"),
            ("it-tools", "IT Tools", "GPL-3.0", "https://github.com/corentinth/it-tools"),
        ] {
            let templateSource = "https://github.com/coollabsio/coolify/blob/main/templates/compose/" + id + ".yaml"
            let record = template.setting("id", .string(id)).setting("name", .string(name))
                .setting("sourceURL", .string(templateSource)).setting("applicationLicense", .string(license))
                .setting("applicationSourceURL", .string(source))
            let visible = try NativeAppsContract.templates(.array([record])).first
            #expect(visible?.license == "Apache-2.0")
            #expect(visible?.sourceURL == templateSource)
            #expect(visible?.applicationLicense == license)
            #expect(visible?.applicationSourceURL == source)

            let unsafe = record.setting("applicationSourceURL", .string("https://person:" + secret + "@github.com/owner/repo"))
            #expect(try NativeAppsContract.templates(.array([unsafe])).first?.applicationSourceURL == nil)
        }
    }

    @Test func datesUseUnixMillisecondsAndRefuseValuesOutsideTheSupportedCalendar() throws {
        let expected = Date(timeIntervalSince1970: 1_700_000_000).formatted(date: .abbreviated, time: .shortened)
        #expect(NativeAppsContract.timestamp(.number(milliseconds)) == expected)
        #expect(try NativeAppsContract.detail(app).updatedAt == expected)
        let backups = try NativeAppsContract.backups(.array([
            .object([.init("id", .string("backup-now")), .init("createdAt", .number(milliseconds)), .init("bytes", .number(2048))]),
            .object([.init("id", .string("backup-undated")), .init("createdAt", .number(-1)), .init("size", .number(0))]),
        ]))
        #expect(backups[0].createdAt == expected)
        #expect(backups[0].size == ByteCountFormatter.string(fromByteCount: 2048, countStyle: .file))
        #expect(backups[1].createdAt == nil)
        #expect(NativeAppsContract.timestamp(.number(0)) == Date(timeIntervalSince1970: 0).formatted(date: .abbreviated, time: .shortened))
        let invalid: [NativeRPCValue] = [.missing, .null, .string("2023-11-14"), .number(-1),
                                         .number(253_402_300_800_000), .number(Double.greatestFiniteMagnitude),
                                         .number(Double.infinity), .number(Double.nan)]
        for value in invalid { #expect(NativeAppsContract.timestamp(value) == nil) }
    }

    @Test func onlyARetainedSuccessfulVersionOffersRollback() throws {
        func deploy(_ id: String, _ status: String) -> NativeRPCValue {
            .object([.init("id", .string(id)), .init("status", .string(status)),
                     .init("commit", .string("abc123")), .init("createdAt", .number(milliseconds))])
        }
        let rows = try NativeAppsContract.deployments(.array([
            deploy("deploy-current", "running"), deploy("deploy-previous", "running"),
            deploy("deploy-failed", "failed"), deploy("deploy-building", "building"),
            deploy("deploy-ready", "ready"), deploy("deploy-healthy", "healthy"),
            deploy("deploy-succeeded", "succeeded"), deploy("deploy-unknown", "unknown"),
        ]), activeID: "deploy-current")
        #expect(rows.filter(\.canRollback).map(\.id) == ["deploy-previous"])
        #expect(rows[1].title == "abc123")
        #expect(rows[1].createdAt == NativeAppsContract.timestamp(.number(milliseconds)))
    }

    @Test func malformedPortAndBackupNumbersThrowInsteadOfTrappingOrTruncating() throws {
        let invalidPorts: [NativeRPCValue] = [.number(Double.greatestFiniteMagnitude), .number(Double(Int.max)),
            .number(-1), .number(0), .number(65_536), .number(3000.5), .number(Double.nan), .string("3000")]
        for value in invalidPorts {
            expectMalformed { _ = try NativeAppsContract.detail(app.setting("source", app["source"].setting("port", value))) }
        }
        #expect(try NativeAppsContract.detail(app.setting("source", app["source"].removing("port"))).port == nil)
        #expect(try NativeAppsContract.detail(app.setting("source", app["source"].setting("port", .number(65_535)))).port == 65_535)
        let invalidSizes: [NativeRPCValue] = [.number(Double.greatestFiniteMagnitude), .number(Double(Int64.max)),
            .number(-1), .number(12.5), .number(Double.nan), .string("2048")]
        for value in invalidSizes {
            for field in ["bytes", "size"] {
                let row = NativeRPCValue.object([.init("id", .string("backup")), .init(field, value)])
                expectMalformed { _ = try NativeAppsContract.backups(.array([row])) }
            }
        }
        #expect(try NativeAppsContract.backups(.array([.object([.init("id", .string("backup"))])])).first?.size == nil)
    }

    @Test func backupSchedulingRequiresAnExplicitEnabledState() throws {
        let disabled = try NativeAppsContract.backupSchedule(.object([.init("enabled", .bool(false))]))
        #expect(disabled == NativeAppsBackupSchedule(enabled: false, time: "02:00", retentionCount: 7))
        expectMalformed { _ = try NativeAppsContract.backupSchedule(.object([])) }
        expectMalformed {
            _ = try NativeAppsContract.backupSchedule(.object([
                .init("schedule", .string("*-*-* 02:00:00")), .init("retention", .number(7)),
            ]))
        }
        expectMalformed { _ = try NativeAppsContract.backupSchedule(.object([.init("enabled", .string("false"))])) }
        expectMalformed {
            _ = try NativeAppsContract.backupSchedule(.object([.init("enabled", .bool(true)), .init("retention", .number(7))]))
        }
        expectMalformed {
            _ = try NativeAppsContract.backupSchedule(.object([
                .init("enabled", .bool(true)), .init("schedule", .number(2)), .init("retention", .number(7)),
            ]))
        }
        expectMalformed {
            _ = try NativeAppsContract.backupSchedule(.object([.init("enabled", .bool(true)), .init("schedule", .string("hourly"))]))
        }
    }

    @Test func backupCalendarsAndRetentionKeepTheExistingServerChoice() throws {
        let dailyCalendar = "*-*-* 03:45:00"
        let daily = NativeRPCValue.object([
            .init("enabled", .bool(true)), .init("schedule", .string(dailyCalendar)), .init("retention", .number(14)),
        ])
        #expect(try NativeAppsContract.backupSchedule(daily) == NativeAppsBackupSchedule(
            enabled: true, time: "03:45", retentionCount: 14, calendar: dailyCalendar))

        let hourly = try NativeAppsContract.backupSchedule(daily.setting("schedule", .string("hourly")))
        #expect(hourly.enabled)
        #expect(hourly.calendar == "hourly")
        #expect(hourly.time.isEmpty)
        #expect(hourly.retentionCount == 14)
        let disabledHourly = try NativeAppsContract.backupSchedule(daily.setting("schedule", .string("hourly")).setting("enabled", .bool(false)))
        #expect(!disabledHourly.enabled)
        #expect(disabledHourly.calendar == "hourly")
        #expect(disabledHourly.time.isEmpty)
        expectMalformed { _ = try NativeAppsContract.backupSchedule(daily.setting("schedule", .string("PASSWORD=" + secret))) }
        expectMalformed { _ = try NativeAppsContract.backupSchedule(daily.setting("schedule", .string("hourly\n"))) }
        expectMalformed { _ = try NativeAppsContract.backupSchedule(daily.setting("schedule", .string("   "))) }

        for days in [1.0, 365.0] {
            #expect(try NativeAppsContract.backupSchedule(daily.setting("retention", .number(days))).retentionCount == Int(days))
        }
        let invalid: [NativeRPCValue] = [.number(Double.greatestFiniteMagnitude), .number(Double(Int.max)),
            .number(7.5), .number(-1), .number(0), .number(366), .number(Double.nan), .string("7")]
        for value in invalid {
            expectMalformed { _ = try NativeAppsContract.backupSchedule(daily.setting("retention", value)) }
        }
    }

    @Test func displayedProblemsNeverContainRawErrorOutputOrSubmittedSecrets() {
        let codes = ["unavailable", "approval-required", "access-denied", "confirmation-required", "not-found",
                     "conflict", "busy", "build-failed", "health-failed", "dns-mismatch", "backup-failed",
                     "restore-failed", "cancelled", "invalid-arguments", "malformed", "internal", secret]
        for code in codes {
            let error = NativeRPCError(code: code, message: "Raw stderr with \(secret)",
                                       details: .object([.init("stderr", .string(secret)), .init("password", .string(secret))]))
            let message = NativeAppsContract.problem(error)
            #expect(!message.isEmpty)
            #expect(!message.contains(secret))
            #expect(!message.contains("Raw stderr"))
        }
        #expect(NativeAppsContract.problem(NativeRPCError.malformed(secret)) ==
                "The server’s reply could not be read. Refresh to check what happened before trying again.")
        let uncertainReply = "No usable reply arrived from the server. Refresh to check what happened before trying again."
        #expect(NativeAppsContract.problem(NativeRPCError(code: "internal", message: secret)) == uncertainReply)
        let unknown = NSError(domain: "Apps", code: 1, userInfo: [NSLocalizedDescriptionKey: secret])
        #expect(NativeAppsContract.problem(unknown) == uncertainReply)
        for (reason, cause) in [
            ("This action is unavailable because recovery after an interrupted change is not connected yet.",
             "Changes are turned off because the server cannot safely undo an interrupted change."),
            ("The app engine has no Docker connection yet.", "App controls are not connected to this server."),
            ("The GitHub connection could not supply a usable sign-in.", "The GitHub connection could not sign in to read this repository."),
            ("This app has no running service yet. Deploy it first.", "This app has no running version yet."),
            ("Live app logs need an event connection for this window.", "Live logs are not connected for this window."),
        ] {
            let message = NativeAppsContract.problem(NativeRPCError(code: "unavailable", message: reason))
            #expect(message == cause)
            #expect(!message.lowercased().contains("docker"))
            #expect(!message.lowercased().contains("container"))
            #expect(!message.lowercased().contains("image"))
        }
        let unknownCause = "This action is unavailable, but its cause could not be identified."
        #expect(NativeAppsContract.unavailableProblem() == unknownCause)
        #expect(NativeAppsContract.unavailableProblem("The GitHub connection could not supply a usable sign-in. " + secret) == unknownCause)
        #expect(NativeAppsContract.problem(NativeRPCError(code: "unavailable", message: "Raw stderr " + secret)) == unknownCause)
    }

    private func expectMalformed(_ body: () throws -> Void) {
        do {
            try body()
            Issue.record("A malformed server field was accepted.")
        } catch let error as NativeRPCError {
            #expect(error.code == "malformed")
            #expect(!error.message.contains(secret))
        } catch {
            Issue.record("A malformed server field threw an unexpected error type.")
        }
    }
}
