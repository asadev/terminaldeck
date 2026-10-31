import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppsDataTemplateTests: XCTestCase, @unchecked Sendable {
    func testExpandedCatalogueRequiresConnectedPlanner() throws {
        let defaults = try BackendAppsDataTemplates.list().requireArray("templates")
        XCTAssertEqual(defaults.map { $0["id"].string }, ["uptime-kuma"])
        let expanded = try BackendAppsDataTemplates.list(expandedTemplatesEnabled: true).requireArray("templates")
        XCTAssertEqual(Set(expanded.compactMap { $0["id"].string }), ["uptime-kuma", "it-tools", "excalidraw"])
        for entry in expanded {
            XCTAssertEqual(entry["license"].string, "Apache-2.0")
            XCTAssertTrue(entry["sourceURL"].string?.hasPrefix("https://github.com/coollabsio/coolify/") == true)
            XCTAssertNotNil(entry["credit"].string)
            XCTAssertNotNil(entry["applicationLicense"].string)
        }
    }

    func testSavedSourceAcceptsReorderedJSONFields() throws {
        let source = try BackendAppsDataTemplates.source(templateID: "it-tools")
        let reordered = NativeRPCValue.object(Array((source.fields ?? []).reversed()))
        XCTAssertEqual(try BackendAppsDataTemplates.validatedEntry(reordered).id, "it-tools")
    }

    func testSavedSourceRejectsChangedImagePortMountAndExtraCommand() throws {
        let source = try BackendAppsDataTemplates.source(templateID: "uptime-kuma")
        for changed in [source.setting("image", .string("other/image:latest")),
                        source.setting("port", .number(22)), source.setting("dataPath", .string("/etc")),
                        source.setting("command", .array([.string("sh")]))] {
            XCTAssertThrowsError(try BackendAppsDataTemplates.validatedEntry(changed)) {
                XCTAssertEqual(($0 as? NativeRPCError)?.code, "invalid-arguments")
            }
        }
        let duplicate = NativeRPCValue.object((source.fields ?? []) + [.init("image", source["image"])])
        XCTAssertThrowsError(try BackendAppsDataTemplates.validatedEntry(duplicate))
    }

    func testTemplateImageMayDeclareOnlyReviewedStorage() throws {
        let stored = try BackendAppsDataTemplates.source(templateID: "it-tools")
        let stateless = try BackendAppsDataTemplates.source(templateID: "excalidraw")
        let image = NativeRPCValue.object([.init("Config", .object([
            .init("Volumes", .object([.init("/app/data", .object([]))]))
        ]))])
        XCTAssertNoThrow(try BackendAppsDataTemplatePlanner.validateStorage(image: image, source: stored))
        XCTAssertThrowsError(try BackendAppsDataTemplatePlanner.validateStorage(image: image, source: stateless))
        XCTAssertThrowsError(try BackendAppsDataTemplatePlanner.validateStorage(image: image.setting("Config", .object([
            .init("Volumes", .object([.init("/var/run/docker.sock", .object([]))]))
        ])), source: stored))
    }

    func testUnknownTemplateAndUnavailableExpansionRefuseBeforeIO() async throws {
        let fake = BackendAppsDataTemplateFake()
        let runtime = await fake.runtime()
        let service = BackendAppsDataTemplateDeploy(runtime: runtime, store: BackendAppsStore(runtime: runtime))
        for (id, code) in [("unknown", "not-found"), ("excalidraw", "unavailable")] {
            do {
                _ = try await service.deploy(serverID: "fixture", appID: "demo", name: "Demo", templateID: id)
                XCTFail("Template should refuse before saving state")
            } catch let error as NativeRPCError { XCTAssertEqual(error.code, code) }
        }
        let calls = await fake.calls
        XCTAssertEqual(calls.count, 0)
    }

    func testMaskAndUnscopedLiveAppRefuseBeforeIO() async throws {
        let fake = BackendAppsDataTemplateFake()
        let normal = await fake.runtime()
        let service = BackendAppsDataTemplateDeploy(runtime: normal, store: BackendAppsStore(runtime: normal))
        do {
            _ = try await service.deploy(serverID: "fixture", appID: "demo", name: "Demo", templateID: "uptime-kuma", environment: ["TOKEN": "••••••••"])
            XCTFail("Mask was saved as a real setting")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "invalid-arguments") }
        let testRuntime = await fake.runtime(testNamespace: true)
        let testService = BackendAppsDataTemplateDeploy(runtime: testRuntime, store: BackendAppsStore(runtime: testRuntime))
        do {
            _ = try await testService.deploy(serverID: "fixture", appID: "demo", name: "Demo", templateID: "uptime-kuma")
            XCTFail("Live test accepted an ordinary app name")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "invalid-arguments") }
        let calls = await fake.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testStatelessPlanCreatesNoSavedVolumeAndRetainsExactImageID() async throws {
        let fake = BackendAppsDataTemplateFake()
        let planner = BackendAppsDataTemplatePlanner(runtime: await fake.runtime())
        let source = try BackendAppsDataTemplates.source(templateID: "excalidraw")
        let plan = try await planner.plan(serverID: "fixture", appID: "demo", source: source, tag: "terminaldeck/demo:terminaldeck-deploy-one")
        XCTAssertEqual(plan.port, 80)
        XCTAssertTrue(plan.mounts.isEmpty)
        let calls = await fake.calls
        XCTAssertFalse(calls.contains(where: { $0.contains("/volumes") }))
        let buildInput = await fake.buildInput
        XCTAssertEqual(buildInput, "FROM sha256:" + String(repeating: "a", count: 64) + "\n")
    }

    func testManagedDataPlanRejectsVolumeOwnedByAnotherApp() async throws {
        let fake = BackendAppsDataTemplateFake()
        let planner = BackendAppsDataTemplatePlanner(runtime: await fake.runtime())
        do {
            _ = try await planner.plan(serverID: "fixture", appID: "demo", source: BackendAppsDataTemplates.source(templateID: "it-tools"), tag: "terminaldeck/demo:terminaldeck-deploy-one")
            XCTFail("Template attached another app's data")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "conflict") }
        let calls = await fake.calls
        XCTAssertFalse(calls.contains(where: { $0.hasPrefix("POST /volumes") }))
    }

    func testRetainedVersionAndSavedSourceRefuseBeforePlannerIO() async throws {
        let fake = BackendAppsDataTemplateFake()
        let planner = BackendAppsDataTemplatePlanner(runtime: await fake.runtime())
        let source = try BackendAppsDataTemplates.source(templateID: "excalidraw")
        for tag in ["other/demo:version", "terminaldeck/demo:version\n"] {
            do {
                _ = try await planner.plan(serverID: "fixture", appID: "demo", source: source, tag: tag)
                XCTFail("Planner wrote an unrelated or multiline image name")
            } catch let error as NativeRPCError { XCTAssertEqual(error.code, "invalid-arguments") }
        }
        do {
            _ = try await planner.plan(serverID: "fixture", appID: "demo\n", source: source, tag: "terminaldeck/demo:version")
            XCTFail("Planner accepted a multiline app name")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "invalid-arguments") }
        do {
            _ = try await planner.plan(serverID: "fixture", appID: "demo", source: source.setting("dataPath", .string("/")), tag: "terminaldeck/demo:version")
            XCTFail("Planner accepted unreviewed source")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "invalid-arguments") }
        let calls = await fake.calls
        XCTAssertTrue(calls.isEmpty)
    }
}

private actor BackendAppsDataTemplateFake {
    var calls: [String] = []
    var buildInput: String?

    func execute(_ command: String, _ input: Data?) -> BackendServersRunResult {
        calls.append(command)
        if let input { buildInput = String(data: input, encoding: .utf8) }
        return .init(code: 0, stdout: "")
    }

    func http(_ method: String, _ path: String) throws -> BackendAppsHTTPResponse {
        calls.append(method + " " + path)
        if path.hasPrefix("/images/") {
            return .init(status: 200, body: try NativeRPCValue.object([
                .init("Id", .string("sha256:" + String(repeating: "a", count: 64))), .init("Config", .object([]))
            ]).encodedJSON())
        }
        if path.hasPrefix("/volumes/") {
            return .init(status: 200, body: try NativeRPCValue.object([
                .init("Name", .string("terminaldeck-demo-data")), .init("Driver", .string("local")),
                .init("Labels", .object([.init("io.terminaldeck.managed", .string("true")), .init("io.terminaldeck.app", .string("someone-else"))]))
            ]).encodedJSON())
        }
        return .init(status: 404)
    }

    func runtime(testNamespace: Bool = false) -> BackendAppsRuntime {
        BackendAppsRuntime(execute: { _, command, input, _, _ in await self.execute(command, input) },
                           docker: { _, method, path, _ in try await self.http(method, path) },
                           privateNetwork: testNamespace ? "td-test-apps" : "terminaldeck-apps",
                           resourcePrefix: testNamespace ? "td-test" : "terminaldeck",
                           stateRoot: testNamespace ? "/var/lib/td-test-apps" : "/var/lib/terminaldeck/apps")
    }
}
