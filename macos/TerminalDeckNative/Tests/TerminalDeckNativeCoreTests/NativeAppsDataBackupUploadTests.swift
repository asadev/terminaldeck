import Foundation
import XCTest
@testable import TerminalDeckNativeCore

final class NativeAppsDataBackupUploadTests: XCTestCase {
    func testPublicPolicyReadsOnlyDestinationAndSchedule() throws {
        let settings = try NativeAppsDataBackupSettings.read(policy())
        XCTAssertEqual(settings.upload?.endpoint, "https://storage.example.com")
        XCTAssertEqual(settings.upload?.bucket, "saved-backups")
        XCTAssertEqual(settings.schedule.calendar, "weekly")
        XCTAssertEqual(settings.schedule.retentionCount, 14)
        XCTAssertThrowsError(try NativeAppsDataBackupSettings.read(policy().setting("upload", policy()["upload"].setting("secretKey", .string("unexpected-secret")))))
    }

    func testChangingUploadKeepsServerCalendarAndRetention() throws {
        let settings = try NativeAppsDataBackupSettings.read(policy())
        let payload = try NativeAppsDataBackupUploadChange.replace(validDraft()).policyPayload(settings: settings)
        XCTAssertEqual(payload["schedule"].string, "weekly")
        XCTAssertEqual(payload["retention"].number, 14)
        XCTAssertEqual(payload["upload"]["accessKey"].string, "new-access")
    }

    func testRemovingUploadIsExplicitNullAndPreservesSchedule() throws {
        let payload = try NativeAppsDataBackupUploadChange.remove.policyPayload(settings: NativeAppsDataBackupSettings.read(policy()))
        XCTAssertTrue(payload.has("upload"))
        XCTAssertEqual(payload["upload"], .null)
        XCTAssertEqual(payload["schedule"].string, "weekly")
        XCTAssertEqual(payload["enabled"].bool, true)
    }

    func testDisabledPolicyCanChangeUploadWithoutEnablingTimer() throws {
        let disabled = NativeAppsDataBackupSettings(schedule: .init(enabled: false))
        let added = try NativeAppsDataBackupUploadChange.replace(validDraft()).policyPayload(settings: disabled)
        XCTAssertEqual(added["enabled"].bool, false)
        XCTAssertEqual(added["upload"]["bucket"].string, "saved-backups")
        XCTAssertFalse(added.has("schedule"))
        XCTAssertFalse(added.has("retention"))
        let removed = try NativeAppsDataBackupUploadChange.remove.policyPayload(settings: disabled)
        XCTAssertEqual(removed["enabled"].bool, false)
        XCTAssertEqual(removed["upload"], .null)
    }

    func testEnabledPolicyWithUnknownTimingCannotChangeUpload() {
        let unreadable = NativeAppsDataBackupSettings(schedule: .init(enabled: true, time: ""))
        XCTAssertThrowsError(try NativeAppsDataBackupUploadChange.remove.policyPayload(settings: unreadable))
    }

    func testFreshKeysAreRequiredWhenDestinationChangesAndMasksRefused() {
        var draft = validDraft()
        draft.bucket = "new-backups"
        draft.secretKey = ""
        XCTAssertNotNil(draft.validationMessage)
        draft.secretKey = "••••••••"
        XCTAssertNotNil(draft.validationMessage)
        draft.secretKey = "new-secret\nextra"
        XCTAssertNotNil(draft.validationMessage)
        XCTAssertThrowsError(try draft.uploadPayload())
    }

    func testSameDestinationWithBlankKeysPreservesProtectedCredentials() throws {
        let saved = NativeAppsDataBackupUpload(endpoint: "https://storage.example.com", bucket: "saved-backups", prefix: "folder")
        let draft = NativeAppsDataBackupUploadDraft(destination: saved)
        XCTAssertNil(draft.validationMessage)
        let payload = try draft.uploadPayload()
        XCTAssertFalse(payload.has("accessKey"))
        XCTAssertFalse(payload.has("secretKey"))
        XCTAssertEqual(payload["bucket"].string, saved.bucket)
        var changed = draft; changed.prefix = "another-folder"
        XCTAssertNotNil(changed.validationMessage)
        var partial = draft; partial.accessKey = "only-one-key"
        XCTAssertNotNil(partial.validationMessage)
        let unsaved = NativeAppsDataBackupUploadDraft()
        XCTAssertNotNil(unsaved.validationMessage)
    }

    func testMalformedPublicFieldsAndNestedSecretsAreRejected() {
        let unsafe = policy().setting("upload", policy()["upload"].setting("metadata", .object([.init("secret", .string("hidden"))])))
        XCTAssertThrowsError(try NativeAppsDataBackupSettings.read(unsafe))
        XCTAssertThrowsError(try NativeAppsDataBackupSettings.read(policy().setting("credentials", .object([.init("token", .string("hidden"))]))))
    }

    func testUnsafeDestinationsNeverBecomeUploadPayloads() {
        for endpoint in ["http://storage.example.com", "https://user:password@storage.example.com", "https://storage.example.com?token=private", "https://storage.example.com#private", "https://storage.example.com:65536", "https://storage.example.com/../admin"] {
            var draft = validDraft(); draft.endpoint = endpoint
            XCTAssertNotNil(draft.validationMessage)
            XCTAssertThrowsError(try draft.uploadPayload())
        }
        var draft = validDraft(); draft.prefix = "$(echo secret)"
        XCTAssertNotNil(draft.validationMessage)
        for prefix in ["/folder", "folder/", "folder//another"] {
            draft = validDraft(); draft.prefix = prefix
            XCTAssertNotNil(draft.validationMessage)
        }
        for bucket in ["10.0.0.1", "bad..bucket", "bad.-bucket", "bad-.bucket"] {
            draft = validDraft(); draft.bucket = bucket
            XCTAssertNotNil(draft.validationMessage)
        }
        draft = validDraft(); draft.accessKey = String(repeating: "a", count: 257)
        XCTAssertNotNil(draft.validationMessage)
        draft = validDraft(); draft.secretKey = "secret with spaces"
        XCTAssertNotNil(draft.validationMessage)
        draft = validDraft(); draft.secretKey = "secret\n"
        XCTAssertNotNil(draft.validationMessage)
        draft = validDraft(); draft.prefix = "folder\n"
        XCTAssertNotNil(draft.validationMessage)
    }

    func testDraftDescriptionAndClearingCannotLeakCredentials() {
        var draft = validDraft()
        XCTAssertFalse(String(describing: draft).contains("new-secret"))
        XCTAssertFalse(String(reflecting: draft).contains("new-access"))
        draft.clearCredentials()
        XCTAssertEqual(draft.accessKey, "")
        XCTAssertEqual(draft.secretKey, "")
        XCTAssertEqual(draft.bucket, "saved-backups")
    }

    private func validDraft() -> NativeAppsDataBackupUploadDraft {
        var draft = NativeAppsDataBackupUploadDraft(destination: .init(endpoint: "https://storage.example.com", bucket: "saved-backups", prefix: "folder"))
        draft.accessKey = "new-access"; draft.secretKey = "new-secret"
        return draft
    }

    private func policy() -> NativeRPCValue {
        .object([
            .init("enabled", .bool(true)), .init("schedule", .string("weekly")), .init("retention", .number(14)),
            .init("upload", .object([
                .init("endpoint", .string("https://storage.example.com")), .init("bucket", .string("saved-backups")), .init("prefix", .string("folder"))
            ]))
        ])
    }
}
