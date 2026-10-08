import Foundation

// Read-only lane checks. No signing identities, credential files or Apple calls.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
var failures = 0
func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "PASS" : "FAIL") \(label)")
    if !condition { failures += 1 }
}
func propertyList(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url),
          let result = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
    return result
}
func run(_ executable: String, _ arguments: [String]) -> String {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments; process.standardOutput = pipe; process.standardError = pipe
    do { try process.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : ""
}
let spec = (try? String(contentsOf: root.appendingPathComponent("ios/project.yml"), encoding: .utf8)) ?? ""
func setting(_ key: String) -> String {
    let line = spec.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + ":") }
    return line?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "") ?? ""
}
let package = (try? Data(contentsOf: root.appendingPathComponent("package.json")))
let metadata = package.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
let version = setting("MARKETING_VERSION"), build = setting("CURRENT_PROJECT_VERSION")
check(!version.isEmpty && version == metadata["version"] as? String, "Version \(version) matches repo")
check(UInt32(build) != nil && build.count == 10, "Build \(build) is a valid UTC stamp")
check(setting("TARGETED_DEVICE_FAMILY") == "1", "iPhone only")
check(FileManager.default.fileExists(atPath: root.appendingPathComponent("ios/TerminalDeck.xcodeproj/project.pbxproj").path), "Generated Xcode project exists")
let source = propertyList(root.appendingPathComponent("ios/Support/Info.plist"))
check(source["UILaunchScreen"] != nil, "Launch screen configured")
check(source["ITSAppUsesNonExemptEncryption"] == nil, "Encryption declaration follows existing release setup")
let icon = run("/usr/bin/sips", ["-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", root.appendingPathComponent("ios/TerminalDeck/Assets.xcassets/AppIcon.appiconset/icon-1024.png").path])
check(icon.contains("pixelWidth: 1024") && icon.contains("pixelHeight: 1024") && icon.contains("hasAlpha: no"), "App icon 1024 square, no alpha")
func bundle(_ relative: String, label: String) {
    let info = propertyList(root.appendingPathComponent(relative + "/Info.plist"))
    check(info["CFBundleIdentifier"] as? String == "dev.terminaldeck.ios", "\(label) bundle identifier")
    check(info["CFBundleShortVersionString"] as? String == version && info["CFBundleVersion"] as? String == build, "\(label) version/build")
    check(info["UIDeviceFamily"] as? [Int] == [1], "\(label) iPhone family")
    check(info["CFBundleIconName"] as? String == "AppIcon", "\(label) compiled icon")
}
bundle("ios/.dd-ios/Build/Products/Debug-iphonesimulator/TerminalDeck.app", label: "Simulator")
if CommandLine.arguments.contains("--archive") {
    bundle("ios/.dd-ios/ReleaseReady.xcarchive/Products/Applications/TerminalDeck.app", label: "Unsigned archive")
}
print("\(failures == 0 ? "PASS" : "FAIL") IOS lane preflight; signing/upload remain the release worker's checks")
exit(failures == 0 ? 0 : 1)
