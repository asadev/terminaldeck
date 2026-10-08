import Foundation
import Darwin
import XCTest

/// Exercises the real @main app and NativeCompositionProduction, rather than a
/// miniature registry assembled by a unit-test fixture. Run after swift build.
// Keep this process-level smoke first in this target's XCTest run, so an
// unrelated unit-test trap cannot prevent checking whether the product boots.
final class AAINT2ProductionStartupSmokeTests: XCTestCase {
    func testEmptyDataFolderBootsRealProductionEngine() throws {
        let fm = FileManager.default
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let repository = package.deletingLastPathComponent().deletingLastPathComponent()
        let products = package.appendingPathComponent(".build/out/Products/Debug")
        // Foundation standardizes even /private/var back through the /var
        // symlink, which the production migration deliberately refuses. Keep
        // this disposable fixture under the existing, physical package cache.
        let scratch = package.appendingPathComponent(".build/INT2-production-startup-" + UUID().uuidString)
        let app = scratch.appendingPathComponent("INT2 Startup Smoke.app")
        let contents = app.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let resources = contents.appendingPathComponent("Resources")
        let home = scratch.appendingPathComponent("home")
        let data = scratch.appendingPathComponent("data")
        for directory in [macOS, resources.appendingPathComponent("web"), home, data] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: scratch) }
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: data.path).isEmpty)
        for name in ["TerminalDeckNative", "TerminalDeckNativeHelper", "TerminalDeckJSCorePluginHelper"] {
            let source = products.appendingPathComponent(name)
            XCTAssertTrue(fm.isExecutableFile(atPath: source.path), "Build the complete app before its startup gate: \(source.path)")
            try fm.copyItem(at: source, to: macOS.appendingPathComponent(name))
        }
        for bundle in try fm.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)
            where bundle.pathExtension == "bundle" {
            try fm.copyItem(at: bundle, to: resources.appendingPathComponent(bundle.lastPathComponent))
        }
        for (source, name) in [("out/renderer", "renderer"), ("out/native-web", "native-web"), ("pwa/dist", "pwa")] {
            try fm.copyItem(at: repository.appendingPathComponent(source),
                to: resources.appendingPathComponent("web/" + name))
        }
        let fixedPackage = resources.appendingPathComponent("staysfixed/package")
        try fm.createDirectory(at: fixedPackage, withIntermediateDirectories: true)
        try fm.copyItem(at: repository.appendingPathComponent("vendor/staysfixed-0.15.0-neutral.tgz"),
            to: fixedPackage.appendingPathComponent("staysfixed-0.15.0-neutral.tgz"))
        var info = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: repository.appendingPathComponent("macos/Info.plist")),
            format: nil) as? [String: Any])
        info["CFBundleIdentifier"] = "dev.terminaldeck.int2.startup." + UUID().uuidString.lowercased()
        info["CFBundleName"] = "INT2 Startup Smoke"
        info["CFBundleDisplayName"] = "INT2 Startup Smoke"
        info["CFBundleShortVersionString"] = "0.20.0"
        info["TDNativeStandalone"] = true
        info["TDNativeOnly"] = true
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--deep", "--sign", "-", app.path]
        signer.standardOutput = FileHandle.nullDevice; signer.standardError = FileHandle.nullDevice
        try signer.run(); signer.waitUntilExit()
        XCTAssertEqual(signer.terminationStatus, 0, "Scratch app must be a valid local bundle")

        let output = scratch.appendingPathComponent("launch.log")
        XCTAssertTrue(fm.createFile(atPath: output.path, contents: nil))
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        process.executableURL = macOS.appendingPathComponent("TerminalDeckNative")
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["TD_NATIVE_DATA_DIR"] = data.path
        environment["TD_NATIVE_GRAPH"] = "full"
        environment["TD_NATIVE_DUMP_ROUTES"] = "1"
        // Never allow a developer's checkout/engine selector to change this gate.
        environment.removeValue(forKey: "TD_REPO")
        process.environment = environment
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 10) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                XCTAssertEqual(exited.wait(timeout: .now() + 2), .success,
                    "The owned smoke app must finish shutdown; never hang the suite")
            }
        }
        let engineLog = data.appendingPathComponent("engine.log")
        let deadline = Date().addingTimeInterval(45)
        var log = ""
        while process.isRunning && Date() < deadline {
            log = (try? String(contentsOf: engineLog, encoding: .utf8)) ?? ""
            if log.contains("engine ready at ") || log.contains("engine: none") { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let stderr = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        XCTAssertTrue(process.isRunning, "Production app exited before readiness: \(stderr.suffix(4000))")
        XCTAssertTrue(log.contains("native backend: no engine process"), "Must use the real native backend: \(log)")
        XCTAssertTrue(log.contains("engine ready at "), "Production startup failed or timed out: \(log)\n\(stderr.suffix(4000))")
        let manifest = try Data(contentsOf: data.appendingPathComponent("native-routes.json"))
        let routes = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        XCTAssertFalse((routes["invoke"] as? [String] ?? []).isEmpty, "A real sealed production registry must back the ready engine")
        XCTAssertTrue(fm.fileExists(atPath: data.appendingPathComponent("native-shell-port").path), "The in-process page server must actually listen")
        print("INT2 production startup: pid=\(process.processIdentifier), initially empty data, isolated HOME, full sealed graph, native page server, actual engine ready")
    }
}
