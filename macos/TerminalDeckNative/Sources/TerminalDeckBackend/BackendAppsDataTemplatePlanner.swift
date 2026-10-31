import Foundation
import TerminalDeckNativeCore

/// DKA replaces APE's private templatePlan body with this reviewed planner.
/// It returns APE's existing plan, keeping its route/state/health transaction.
struct BackendAppsDataTemplatePlanner: Sendable {
    let runtime: BackendAppsRuntime

    func plan(serverID: String, appID: String, source: NativeRPCValue, tag: String) async throws -> BackendAppsDeployPlan {
        let entry = try BackendAppsDataTemplates.validatedEntry(source)
        try Self.validateRuntime(runtime, appID: appID)
        let repository = runtime.resourcePrefix == "terminaldeck" ? "terminaldeck/" + appID : runtime.resourcePrefix + "-" + appID
        guard tag.hasPrefix(repository + ":"), tag.split(separator: ":").count == 2,
              tag.split(separator: ":").last?.range(of: #"\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,95}\z"#, options: .regularExpression) != nil else {
            throw NativeRPCError.invalidArguments("The template's retained version has an invalid name.")
        }
        let q = BackendAppsRuntime.quote
        if runtime.resourcePrefix == "td-test" {
            _ = try await runtime.checked(serverID, "docker image inspect " + q(entry.image) + " >/dev/null 2>&1",
                                          message: "This test needs the template software already present. Test runs may create only their own named resources.")
        } else {
            _ = try await runtime.checked(serverID, "docker pull " + q(entry.image) + " >/dev/null 2>&1", timeoutMS: 300_000,
                                          code: "build-failed", message: "The template software could not be downloaded.")
        }
        let response = try await runtime.docker(serverID, "GET", "/images/" + entry.image + "/json", nil)
        guard response.ok, let image = try? response.value(), let id = image["Id"].string,
              id.range(of: #"\Asha256:[a-f0-9]{64}\z"#, options: .regularExpression) != nil else {
            throw NativeRPCError(code: "build-failed", message: "The template software's exact version could not be verified.")
        }
        try Self.validateStorage(image: image, source: source)
        _ = try await runtime.checked(serverID, "docker build --network none --label io.terminaldeck.managed=true --label "
                                      + q("io.terminaldeck.app=" + appID) + " --tag " + q(tag) + " - >/dev/null 2>&1",
                                      stdin: Data(("FROM " + id + "\n").utf8), timeoutMS: 300_000,
                                      code: "build-failed", message: "The template version could not be retained safely.")
        var mounts: [NativeRPCValue] = []
        if let dataPath = entry.dataPath {
            let volume = runtime.resourcePrefix + "-" + appID + "-data"
            var volumeResponse = try await runtime.docker(serverID, "GET", "/volumes/" + volume, nil)
            if volumeResponse.status == 404 {
                let body = BackendAppsValidation.object([
                    ("Name", .string(volume)), ("Driver", .string("local")),
                    ("Labels", BackendAppsValidation.object([
                        ("io.terminaldeck.managed", .string("true")), ("io.terminaldeck.app", .string(appID))
                    ]))
                ])
                let created = try await runtime.docker(serverID, "POST", "/volumes/create", body.encodedJSON())
                guard created.ok else { throw NativeRPCError(code: "build-failed", message: "The app's saved data space could not be created.") }
                volumeResponse = try await runtime.docker(serverID, "GET", "/volumes/" + volume, nil)
            }
            guard volumeResponse.ok, let volumeRecord = try? volumeResponse.value(),
                  volumeRecord["Driver"].string == "local", volumeRecord["Name"].string == volume,
                  volumeRecord["Labels"]["io.terminaldeck.managed"].string == "true",
                  volumeRecord["Labels"]["io.terminaldeck.app"].string == appID,
                  volumeRecord["Options"].isNullish || volumeRecord["Options"].fields?.isEmpty == true else {
                throw NativeRPCError(code: "conflict", message: "That saved data space belongs to something this app does not manage.")
            }
            mounts = [BackendAppsValidation.object([
                ("Type", .string("volume")), ("Source", .string(volume)), ("Target", .string(dataPath))
            ])]
        }
        return BackendAppsDeployPlan(mode: .dockerfile, context: ".", dockerfile: "Dockerfile", port: entry.port, mounts: mounts)
    }

    /// Both source and retained images must have only the reviewed data folder.
    static func validateStorage(image: NativeRPCValue, source: NativeRPCValue) throws {
        let entry = try BackendAppsDataTemplates.validatedEntry(source)
        let volumes = image["Config"]["Volumes"]
        guard volumes.isNullish || (volumes.fields?.allSatisfy { $0.key == entry.dataPath } == true) else {
            throw BackendAppsRuntime.unavailable("This template requests saved storage outside its reviewed data folder.")
        }
    }

    static func validateRuntime(_ runtime: BackendAppsRuntime, appID: String) throws {
        try BackendAppsDataDatabases.validateRuntime(runtime, appID: appID)
    }
}
