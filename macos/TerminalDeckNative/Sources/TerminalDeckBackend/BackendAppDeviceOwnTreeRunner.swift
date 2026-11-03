import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// Terminal Deck's own small UI-test runner for an iOS Simulator's element tree (28 Oct 2026).
///
/// Apple's accessibility translation (the helper's `--sim-ax`) reads an app's elements only once that app's
/// accessibility is on. Measured on Xcode 27.1 / iOS 27: an app that was running before anything asked (Safari, News,
/// Maps right after launch) answers with an empty application and no size, while Settings and Terminal Deck's phone app
/// answer in full. XCTest turns an app's accessibility on when it looks at it, after which the translation reads that
/// app in full as well. So when the tree of the app in front comes back empty, Terminal Deck runs this runner once for
/// that app: it takes one XCTest snapshot (also kept as the answer if the translation still says nothing).
///
/// Nothing prebuilt is shipped. The runner's source lives below; the first time it is needed it is written into the
/// app's data folder and built there with `xcodebuild` for the simulator (Xcode is on every Mac that has simulators),
/// signed to run locally, and reused until its source or Xcode changes.
public actor BackendAppDeviceOwnTreeRunner {
    private static let registry = Registry()
    /// One runner per data folder, so one build at a time.
    public static func shared(dataFolder: String) -> BackendAppDeviceOwnTreeRunner { registry.runner(dataFolder) }

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var runners: [String: BackendAppDeviceOwnTreeRunner] = [:]
        func runner(_ folder: String) -> BackendAppDeviceOwnTreeRunner {
            lock.withLock {
                if let found = runners[folder] { return found }
                let made = BackendAppDeviceOwnTreeRunner(dataFolder: folder); runners[folder] = made; return made
            }
        }
    }

    public static let name = "DeviceTreeRunner"
    public static let buildWithin = 600_000
    public static let runWithin = 120_000

    private let root: URL
    private var building: Task<URL, any Error>?
    /// Each simulator runs one snapshot at a time.
    private var running: Set<String> = []

    public init(dataFolder: String) {
        root = URL(fileURLWithPath: dataFolder).appendingPathComponent("devices/tree-runner", isDirectory: true)
    }

    /// The runner's source files, by path inside its folder.
    public static var sources: [String: String] {
        ["\(name).xcodeproj/project.pbxproj": project,
         "\(name).xcodeproj/xcshareddata/xcschemes/\(name).xcscheme": scheme,
         "DeviceTree.swift": test]
    }

    /// The folder for this source on this Xcode: a new source or a new Xcode builds afresh.
    static func folder(root: URL, xcode: String) -> URL {
        var hasher = SHA256()
        for (path, text) in sources.sorted(by: { $0.key < $1.key }) { hasher.update(data: Data((path + "\n" + text).utf8)) }
        hasher.update(data: Data(xcode.utf8))
        let digest = hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest, isDirectory: true)
    }

    /// One snapshot of `bundleID` on simulator `udid`, as the panel's snapshot; nil when XCTest could not look at it.
    public func snapshot(udid: String, bundleID: String, platform: BackendAppDevicePlatform) async throws -> NativeRPCValue? {
        guard !bundleID.isEmpty, bundleID.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return nil }
        guard !running.contains(udid) else { return nil }
        running.insert(udid); defer { running.remove(udid) }
        let xctestrun = try await built(platform: platform)
        let out = root.appendingPathComponent("answer-\(UUID().uuidString).json")
        let results = root.appendingPathComponent("results-\(UUID().uuidString).xcresult")
        defer { try? FileManager.default.removeItem(at: out); try? FileManager.default.removeItem(at: results) }
        // TEST_RUNNER_ variables reach the test process without the prefix.
        let run = await platform.run("/usr/bin/xcrun", ["xcodebuild", "test-without-building", "-xctestrun", xctestrun.path,
            "-destination", "id=\(udid)", "-only-testing:\(Self.name)/DeviceTreeTests/testSnapshot", "-resultBundlePath", results.path, "-quiet"],
            Self.runWithin, extra: ["TEST_RUNNER_" + NativeLaunchSwitches.treeRunnerApp: bundleID, "TEST_RUNNER_" + NativeLaunchSwitches.treeRunnerOut: out.path])
        guard let data = try? Data(contentsOf: out), let raw = try? NativeRPCValue.parseJSON(data) else {
            if !run.ok { throw BackendAppSessionError("XCTest could not look at the app in front: " + Self.firstLine(run.stderr + "\n" + run.stdout)) }
            return nil
        }
        return BackendAppDeviceParsing.snapshot(raw)
    }

    /// The built runner's .xctestrun, building it first when this source and Xcode have none yet.
    private func built(platform: BackendAppDevicePlatform) async throws -> URL {
        if let building { return try await building.value }
        let root = self.root
        let work = Task { () async throws -> URL in
            let version = await platform.run("/usr/bin/xcrun", ["xcodebuild", "-version"], 30_000)
            guard version.ok else { throw BackendAppSessionError("Xcode is not set up on this Mac, so the element tree of this app cannot be read.") }
            let folder = Self.folder(root: root, xcode: version.stdout)
            let products = folder.appendingPathComponent("build/Build/Products", isDirectory: true)
            if let found = Self.xctestrun(in: products) { return found }
            try? FileManager.default.removeItem(at: root)   // an older source or Xcode's build goes
            for (path, text) in Self.sources {
                let file = folder.appendingPathComponent("source/" + path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file)
            }
            let build = await platform.run("/usr/bin/xcrun", ["xcodebuild", "build-for-testing",
                "-project", folder.appendingPathComponent("source/\(Self.name).xcodeproj").path, "-scheme", Self.name,
                "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", folder.appendingPathComponent("build").path, "-quiet",
                "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM="], Self.buildWithin)
            guard build.ok, let found = Self.xctestrun(in: products) else {
                throw BackendAppSessionError("Terminal Deck could not build its element-tree runner with this Mac's Xcode: " + Self.firstLine(build.stderr + "\n" + build.stdout))
            }
            return found
        }
        building = work
        do { let url = try await work.value; return url } catch { building = nil; throw error }
    }

    static func xctestrun(in products: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: products.path)) ?? []
        return names.sorted().first { $0.hasSuffix(".xctestrun") }.map { products.appendingPathComponent($0) }
    }

    static func firstLine(_ text: String) -> String {
        let line = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "no reason given"
        return String(line.prefix(240))
    }

    // MARK: - The runner's source

    static let test = #"""
    import XCTest

    // Terminal Deck's element-tree runner, built on this Mac by Terminal Deck and run against one simulator. It looks once
    // at the app named in TD_TREE_APP (which turns that app's accessibility on) and writes what it saw to TD_TREE_OUT.
    final class DeviceTreeTests: XCTestCase {
        private var count = 0
        private let maximum = 1500

        func testSnapshot() throws {
            let environment = ProcessInfo.processInfo.environment
            guard let bundle = environment["\#(NativeLaunchSwitches.treeRunnerApp)"], !bundle.isEmpty else { return }
            let snapshot = try XCUIApplication(bundleIdentifier: bundle).snapshot()
            let root = node(snapshot, screen: snapshot.frame, depth: 0)
            let answer: [String: Any] = ["source": "ios-xctest", "capturedAt": ISO8601DateFormatter().string(from: Date()), "root": root,
                                         "stats": ["nodeCount": count, "truncated": count >= maximum, "quality": count > 1 ? "full" : "degraded"]]
            let data = try JSONSerialization.data(withJSONObject: answer)
            if let out = environment["\#(NativeLaunchSwitches.treeRunnerOut)"], !out.isEmpty { try data.write(to: URL(fileURLWithPath: out)) }
        }

        private func node(_ element: XCUIElementSnapshot, screen: CGRect, depth: Int) -> [String: Any] {
            count += 1
            var fields: [String: Any] = ["ref": "x\(count)", "role": role(element.elementType), "enabled": element.isEnabled]
            if !element.label.isEmpty { fields["label"] = element.label }
            if !element.identifier.isEmpty { fields["identifier"] = element.identifier }
            if !element.title.isEmpty { fields["title"] = element.title }
            if let placeholder = element.placeholderValue, !placeholder.isEmpty { fields["placeholder"] = placeholder }
            if element.elementType == .secureTextField { fields["valueRedacted"] = true }
            else if let value = element.value as? String, !value.isEmpty { fields["value"] = value }
            else if let value = element.value as? NSNumber { fields["value"] = value.stringValue }
            if element.hasFocus { fields["focused"] = true }
            let frame = element.frame
            if screen.width > 0, screen.height > 0, !frame.isNull {
                fields["frame"] = ["normalized": ["x": (frame.minX - screen.minX) / screen.width, "y": (frame.minY - screen.minY) / screen.height,
                                                  "width": frame.width / screen.width, "height": frame.height / screen.height]]
            }
            if depth < 120 {
                var children: [[String: Any]] = []
                for child in element.children where count < maximum { children.append(node(child, screen: screen, depth: depth + 1)) }
                if !children.isEmpty { fields["children"] = children }
            }
            return fields
        }

        private func role(_ type: XCUIElement.ElementType) -> String {
            switch type {
            case .application: return "AXApplication"
            case .window: return "AXWindow"
            case .button: return "AXButton"
            case .staticText: return "AXStaticText"
            case .textField: return "AXTextField"
            case .secureTextField: return "AXSecureTextField"
            case .searchField: return "AXSearchField"
            case .textView: return "AXTextArea"
            case .image, .icon: return "AXImage"
            case .cell: return "AXCell"
            case .switch, .toggle: return "AXSwitch"
            case .slider: return "AXSlider"
            case .link: return "AXLink"
            case .table, .collectionView, .outline: return "AXList"
            case .scrollView: return "AXScrollArea"
            case .navigationBar: return "AXNavigationBar"
            case .tabBar: return "AXTabBar"
            case .toolbar: return "AXToolbar"
            case .alert: return "AXAlert"
            case .sheet: return "AXSheet"
            case .keyboard: return "AXKeyboard"
            case .key: return "AXKey"
            case .picker, .pickerWheel, .datePicker: return "AXPicker"
            case .segmentedControl: return "AXSegmentedControl"
            case .menu: return "AXMenu"
            case .menuItem: return "AXMenuItem"
            case .webView: return "AXWebArea"
            case .progressIndicator, .activityIndicator: return "AXProgressIndicator"
            case .other, .group: return "AXGroup"
            default: return "AXUnknown"
            }
        }
    }
    """#

    static let scheme = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <Scheme LastUpgradeVersion = "2700" version = "1.7">
       <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
          <BuildActionEntries>
             <BuildActionEntry buildForTesting = "YES" buildForRunning = "NO" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "NO">
                <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "7DEE00000000000000000008" BuildableName = "DeviceTreeRunner.xctest" BlueprintName = "DeviceTreeRunner" ReferencedContainer = "container:DeviceTreeRunner.xcodeproj">
                </BuildableReference>
             </BuildActionEntry>
          </BuildActionEntries>
       </BuildAction>
       <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
          <Testables>
             <TestableReference skipped = "NO">
                <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "7DEE00000000000000000008" BuildableName = "DeviceTreeRunner.xctest" BlueprintName = "DeviceTreeRunner" ReferencedContainer = "container:DeviceTreeRunner.xcodeproj">
                </BuildableReference>
             </TestableReference>
          </Testables>
       </TestAction>
    </Scheme>
    """#

    static let project = #"""
    // !$*UTF8*$!
    {
    	archiveVersion = 1;
    	classes = {
    	};
    	objectVersion = 56;
    	objects = {
    		7DEE00000000000000000001 = {isa = PBXBuildFile; fileRef = 7DEE00000000000000000002; };
    		7DEE00000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DeviceTree.swift; sourceTree = "<group>"; };
    		7DEE00000000000000000003 = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = DeviceTreeRunner.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
    		7DEE00000000000000000004 = {isa = PBXGroup; children = (7DEE00000000000000000002, 7DEE00000000000000000005, ); sourceTree = "<group>"; };
    		7DEE00000000000000000005 = {isa = PBXGroup; children = (7DEE00000000000000000003, ); name = Products; sourceTree = "<group>"; };
    		7DEE00000000000000000006 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (7DEE00000000000000000001, ); runOnlyForDeploymentPostprocessing = 0; };
    		7DEE00000000000000000007 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ( ); runOnlyForDeploymentPostprocessing = 0; };
    		7DEE00000000000000000008 = {isa = PBXNativeTarget; buildConfigurationList = 7DEE00000000000000000009; buildPhases = (7DEE00000000000000000006, 7DEE00000000000000000007, ); buildRules = ( ); dependencies = ( ); name = DeviceTreeRunner; productName = DeviceTreeRunner; productReference = 7DEE00000000000000000003; productType = "com.apple.product-type.bundle.ui-testing"; };
    		7DEE00000000000000000009 = {isa = XCConfigurationList; buildConfigurations = (7DEE0000000000000000000A, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
    		7DEE0000000000000000000A = {isa = XCBuildConfiguration; buildSettings = {
    			ARCHS = arm64;
    			CODE_SIGN_IDENTITY = "-";
    			CODE_SIGN_STYLE = Manual;
    			GENERATE_INFOPLIST_FILE = YES;
    			IPHONEOS_DEPLOYMENT_TARGET = 17.0;
    			PRODUCT_BUNDLE_IDENTIFIER = dev.terminaldeck.device-tree-runner;
    			PRODUCT_NAME = "$(TARGET_NAME)";
    			SDKROOT = iphoneos;
    			SUPPORTED_PLATFORMS = "iphonesimulator iphoneos";
    			SWIFT_VERSION = 5.0;
    			TARGETED_DEVICE_FAMILY = "1,2";
    		}; name = Debug; };
    		7DEE0000000000000000000B = {isa = XCConfigurationList; buildConfigurations = (7DEE0000000000000000000C, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
    		7DEE0000000000000000000C = {isa = XCBuildConfiguration; buildSettings = {
    			ALWAYS_SEARCH_USER_PATHS = NO;
    			ENABLE_TESTABILITY = YES;
    			ONLY_ACTIVE_ARCH = YES;
    			SDKROOT = iphoneos;
    			SWIFT_COMPILATION_MODE = singlefile;
    			SWIFT_OPTIMIZATION_LEVEL = "-Onone";
    		}; name = Debug; };
    		7DEE0000000000000000000D = {isa = PBXProject; attributes = {LastUpgradeCheck = 2700; }; buildConfigurationList = 7DEE0000000000000000000B; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = 7DEE00000000000000000004; productRefGroup = 7DEE00000000000000000005; projectDirPath = ""; projectRoot = ""; targets = (7DEE00000000000000000008, ); };
    	};
    	rootObject = 7DEE0000000000000000000D;
    }
    """#
}
