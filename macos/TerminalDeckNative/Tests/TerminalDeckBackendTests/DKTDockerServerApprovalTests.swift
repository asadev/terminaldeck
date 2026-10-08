import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Real native-window authority, consent broker, approval adapter and registry.
/// The mutation is a counter after the gate; no Engine/SSH request is opened.
/// Source-only regression for DKA's serial gate.
@MainActor
final class DKTDockerServerApprovalTests: XCTestCase {
    func testSavedTargetRevokedDuringPendingNativeConsentRefusesBeforeMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DKTDockerServerApproval-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let stateFile = directory.appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
        let store = try NativeStateStore(file: stateFile, ownership: .readOnly)
        let data = try XCTUnwrap(store.file).deletingLastPathComponent().standardizedFileURL
        let root = try BackendCompositionRoot(dataRoot: data, state: store, environment: [:], home: directory.path)
        let state = await BackendCompositionState.make(store: store, settings: root.settings, dataRoot: data,
            registry: root.registry, copilotRoot: { _ in directory.appendingPathComponent("copilot").path })
        let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: directory,
            appName: "Terminal Deck Fixture", appID: "terminaldeck", helperExecutable: directory.appendingPathComponent("never-run-helper"),
            inheritedEnvironment: root.preparedSessions.environment)

        // Reuse the existing composition tests' locked fixture boxes.
        let known = BackendDeckCoreSecurityTestBox<Bool>(true)
        let wasPending = BackendDeckCoreSecurityTestBox<Bool>(false)
        let answerAccepted = BackendDeckCoreSecurityTestBox<Bool>(false)
        let questions = BackendDeckCoreSecurityTestBox<[BackendDeckCoreSecurityConsentRequest]>([])
        let lookups = BackendDeckCoreSecurityTestBox<[Bool]>([])
        let mutations = BackendDeckCoreSecurityTestBox<Int>(0)
        let holder = BackendDeckCoreSecurityTestBox<BackendDeckCoreSecurityConsentBroker?>(nil)
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { question in
            questions.edit { $0.append(question) }
            guard let current = holder.get() else { return false }
            // The real broker has an outstanding native question. Revoke the
            // saved-server permission before answering that same question.
            let pending = await current.list()
            wasPending.set(pending.contains { $0.id == question.id })
            known.set(false)
            answerAccepted.set(await current.respond(id: question.id, approved: true, by: "window"))
            return true
        })
        holder.set(broker)
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: directory.appendingPathComponent("actions")), consent: broker)
        let joins = BackendCompositionProductionBindings(root: root, state: state, configuration: configuration)
        let authority = try BackendCompositionAuthority(prepared: root.preparedSessions, state: state,
            configuration: configuration, coreContexts: joins.contexts, gate: control.compositionGate(), hidden: joins.hidden)
        try joins.bind(authority: authority)
        addTeardownBlock {
            await broker.stop()
            holder.set(nil)
            authority.close()
            await state.stop()
            try await root.shutdown()
        }

        let approval = BackendDockerMCPServerApproval(authority: authority, consent: broker, knownServer: { target in
            let permitted = target == "saved-server" && known.get()
            lookups.edit { $0.append(permitted) }
            return permitted
        })
        let context = try authority.localContext()
        try await root.registry.register("docker:containers:remove", ownerID: "dkt-server-approval") { context, arguments in
            try await approval.authorize(context: context, channel: "docker:containers:remove",
                target: arguments[0]["target"].string, changing: true,
                summary: "Remove container \"td-test-revocation\" on \"saved-server\".", arguments: arguments[0])
            // Represents the protected mutation callback after the actual
            // approval adapter. This must never dispatch after revocation.
            mutations.edit { $0 += 1 }
            return .object([.init("ok", .bool(true))])
        }
        let arguments = NativeRPCValue.object([
            .init("target", .string("saved-server")), .init("id", .string("td-test-revocation")),
            .init("confirmName", .string("td-test-revocation"))
        ])
        do {
            _ = try await root.registry.invoke("docker:containers:remove", context: context, arguments: [arguments])
            XCTFail("An answered native prompt must not authorize a server removed while that prompt was pending.")
        } catch let error as NativeRPCError {
            XCTAssertEqual(error.code, "access-denied")
        } catch {
            XCTFail("Saved-target revocation must preserve its access-denied refusal: \(type(of: error)).")
        }
        XCTAssertTrue(wasPending.get(), "Revocation must occur while the real consent question is outstanding.")
        XCTAssertTrue(answerAccepted.get(), "The failure must be target revocation, not an unanswered or invalid consent response.")
        XCTAssertEqual(questions.get().count, 1)
        XCTAssertEqual(questions.get().first?.origin, "window")
        XCTAssertEqual(lookups.get(), [true, false], "Saved-target permission must be rechecked after the answer.")
        XCTAssertEqual(mutations.get(), 0, "No protected mutation callback may run after target revocation.")
    }
}
