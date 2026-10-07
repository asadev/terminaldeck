import Foundation
import AppKit
import Security
import IOKit.ps
import SystemConfiguration
import TerminalDeckNativeCore
import TerminalDeckBackend

// One operation per invocation. stdout is exactly one JSON result; in
// particular, secrets and Keychain passwords never go into diagnostics.
struct HelperFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func requireText(_ args: [String: Any], _ names: String...) throws -> String {
    for name in names { if let value = args[name] as? String { return value } }
    throw HelperFailure(message: "The native helper is missing a required string argument.")
}

func storagePassword(_ args: [String: Any], mayCreate: Bool) throws -> Data {
    let name = try requireText(args, "appName")
    guard !name.isEmpty else { throw HelperFailure(message: "The safe-storage app name is empty.") }
    let service = name + " Safe Storage"
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: name,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseAuthenticationUI as String: (args["allowInteraction"] as? Bool == true)
            ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail,
    ]
    // Also covers the legacy file-based Keychain ACL used by Electron.
    let interaction = args["allowInteraction"] as? Bool == true
    SecKeychainSetUserInteractionAllowed(interaction)
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess {
        guard let password = item as? Data, !password.isEmpty else {
            throw HelperFailure(message: "The safe-storage Keychain item is empty. Existing encrypted data needs its original key.")
        }
        return password
    }
    if status == errSecItemNotFound, mayCreate, args["createIfMissing"] as? Bool == true {
        var random = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw HelperFailure(message: "macOS could not generate a safe-storage key.")
        }
        // Chromium stores the base64 text of 16 random bytes as its password.
        let password = Data(Data(random).base64EncodedString().utf8)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecValueData as String: password,
        ]
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Another invocation created it first. Use that item, never replace it.
            return try storagePassword(args, mayCreate: false)
        }
        guard addStatus == errSecSuccess else { throw keychainFailure(addStatus) }
        return password
    }
    throw keychainFailure(status)
}

func keychainFailure(_ status: OSStatus) -> HelperFailure {
    let detail: String
    switch status {
    case errSecItemNotFound:
        detail = "The original safe-storage Keychain item was not found. Restore its original key to read existing encrypted data."
    case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
        detail = "macOS denied this helper access to the safe-storage Keychain item. Authorize the signed native helper in Keychain Access; the original encryption key must be kept."
    case errSecNotAvailable:
        detail = "The macOS Keychain is unavailable. Unlock the login Keychain and try again."
    default:
        detail = "macOS could not read the safe-storage Keychain item."
    }
    return HelperFailure(message: "\(detail) (Keychain status \(status).)")
}

func batteryPower() throws -> Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
        throw HelperFailure(message: "macOS did not report the current power source.")
    }
    return (source as String) == (kIOPSBatteryPowerValue as String)
}

func networkOnline() throws -> Bool {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    let reachability = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            SCNetworkReachabilityCreateWithAddress(nil, $0)
        }
    }
    guard let reachability else { throw HelperFailure(message: "macOS could not inspect network reachability.") }
    var flags = SCNetworkReachabilityFlags()
    guard SCNetworkReachabilityGetFlags(reachability, &flags) else {
        throw HelperFailure(message: "macOS did not report network reachability.")
    }
    return flags.contains(.reachable) && !flags.contains(.connectionRequired)
}

@MainActor
func rectJSON(_ rect: NSRect, primaryTop: CGFloat) -> [String: Double] {
    ["x": rect.minX, "y": primaryTop - rect.maxY, "width": rect.width, "height": rect.height]
}

@MainActor
func allScreens() throws -> [[String: Any]] {
    let screens = NSScreen.screens
    guard let primary = screens.first else { throw HelperFailure(message: "macOS did not report any displays.") }
    return screens.map { screen in
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let bounds = rectJSON(screen.frame, primaryTop: primary.frame.maxY)
        let work = rectJSON(screen.visibleFrame, primaryTop: primary.frame.maxY)
        // The property, on both SDKs: SDK 26.5 (CI, Swift 6.3) refuses the old function too.
        let colorDepth = screen.depth.bitsPerPixel
        return [
            "id": number, "label": screen.localizedName, "bounds": bounds, "workArea": work,
            "size": ["width": screen.frame.width, "height": screen.frame.height],
            "workAreaSize": ["width": screen.visibleFrame.width, "height": screen.visibleFrame.height],
            "scaleFactor": screen.backingScaleFactor, "rotation": CGDisplayRotation(number),
            "internal": CGDisplayIsBuiltin(number) != 0, "isPrimary": screen === primary,
            "colorDepth": colorDepth,
            "displayFrequency": CGDisplayCopyDisplayMode(number)?.refreshRate ?? 0,
        ]
    }
}

@MainActor
func imageTransform(_ args: [String: Any]) throws -> [String: Any] {
    let encoded = try requireText(args, "base64", "data")
    guard let bytes = Data(base64Encoded: encoded), let source = NSBitmapImageRep(data: bytes),
          source.pixelsWide > 0, source.pixelsHigh > 0 else {
        throw HelperFailure(message: "The native helper could not decode the image.")
    }
    var result: [String: Any] = ["width": source.pixelsWide, "height": source.pixelsHigh]
    guard let resize = args["resize"] as? [String: Any] else {
        if args["toPNG"] as? Bool == true {
            guard let png = source.representation(using: .png, properties: [:]) else {
                throw HelperFailure(message: "The native helper could not encode the image as PNG.")
            }
            result["base64"] = png.base64EncodedString()
        }
        return result
    }
    let sourceWidth = Double(source.pixelsWide), sourceHeight = Double(source.pixelsHigh)
    let requestedWidth = (resize["width"] as? NSNumber)?.doubleValue
    let requestedHeight = (resize["height"] as? NSNumber)?.doubleValue
    guard requestedWidth != nil || requestedHeight != nil else {
        throw HelperFailure(message: "Image resizing needs a width or height.")
    }
    let width = requestedWidth ?? sourceWidth * (requestedHeight! / sourceHeight)
    let height = requestedHeight ?? sourceHeight * (requestedWidth! / sourceWidth)
    guard width.isFinite, height.isFinite, width >= 1, height >= 1, width <= 16384, height <= 16384,
          width * height <= 64_000_000 else {
        throw HelperFailure(message: "The requested image size is invalid or too large.")
    }
    let w = Int(width.rounded()), h = Int(height.rounded())
    guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: output) else {
        throw HelperFailure(message: "The native helper could not allocate the resized image.")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = output.representation(using: .png, properties: [:]) else {
        throw HelperFailure(message: "The native helper could not encode the resized image.")
    }
    return ["width": w, "height": h, "base64": png.base64EncodedString()]
}

@MainActor
func execute(_ operation: String, _ args: [String: Any]) throws -> Any {
    switch operation {
    case "clipboard:read":
        let format = args["format"] as? String ?? "text"
        if format == "public.file-url" || format == "text/uri-list" {
            let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            return urls.map(\.absoluteString).joined(separator: "\n")
        }
        if format == "NSFilenamesPboardType" {
            let paths = NSPasteboard.general.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] ?? []
            guard !paths.isEmpty else { return "" }
            let data = try PropertyListSerialization.data(fromPropertyList: paths, format: .xml, options: 0)
            return String(data: data, encoding: .utf8) ?? ""
        }
        guard format == "text" || format == "text/plain" else { throw HelperFailure(message: "The native clipboard does not support that format.") }
        return NSPasteboard.general.string(forType: .string) ?? ""
    case "clipboard:write":
        let text = try requireText(args, "text", "value")
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(text, forType: .string) else { throw HelperFailure(message: "macOS refused the clipboard text.") }
        return NSNull()
    case "clipboard:image":
        guard let image = NSImage(pasteboard: .general), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return "" }
        return png.base64EncodedString()
    case "screen:all": return try allScreens()
    case "screen:cursor":
        guard let primary = NSScreen.screens.first else { throw HelperFailure(message: "macOS did not report any displays.") }
        let point = NSEvent.mouseLocation
        return ["x": point.x, "y": primary.frame.maxY - point.y]
    case "power:onBattery": return try batteryPower()
    case "network:online": return try networkOnline()
    case "appearance:get":
        return [
            "shouldUseDarkColors": UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark",
            "shouldUseHighContrastColors": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            "shouldUseInvertedColorScheme": NSWorkspace.shared.accessibilityDisplayShouldInvertColors,
            "shouldUseReducedTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
        ]
    case "safeStorage:available":
        _ = try storagePassword(args, mayCreate: true)
        return true
    case "safeStorage:encrypt":
        let text = try requireText(args, "text", "value", "string")
        let password = try storagePassword(args, mayCreate: true)
        return try ChromiumSafeStorageCipher.encrypt(text, password: password).base64EncodedString()
    case "safeStorage:decrypt":
        let encoded = try requireText(args, "base64", "data", "value")
        guard let blob = Data(base64Encoded: encoded) else { throw HelperFailure(message: "The safe-storage blob is not valid base64.") }
        // A missing read key must never silently create a new, incompatible one.
        let password = try storagePassword(args, mayCreate: false)
        return try ChromiumSafeStorageCipher.decrypt(blob, password: password)
    case "image:transform": return try imageTransform(args)
    default: throw HelperFailure(message: "The native helper does not support operation '\(operation)'.")
    }
}

if CommandLine.arguments.contains(BackendServersSSHAskpass.dispatchArgument) {
    exit(BackendServersSSHAskpass.run(arguments: CommandLine.arguments,
        environment: ProcessInfo.processInfo.environment))
}

if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--native-capabilities" {
    print("{\"notifyChannel\":true,\"sshAskpass\":true,\"vaultSecurity\":true}")
    exit(0)
}

if CommandLine.arguments.count == 5, CommandLine.arguments[1] == BackendNodelessPackagingCommand.argument {
    let result = BackendNodelessPackagingCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
    FileHandle.standardOutput.write(Data(result.output.utf8)); exit(result.code)
}

if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--notify-channel" {
    do {
        try await BackendDeckCoreEventsChannelBridge.runStandardIO()
        exit(0)
    } catch {
        try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "vault:capabilities" {
    print(BackendAccountSecurityShimClient.capabilities)
    exit(0)
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "vault:security" {
    exit(BackendAccountSecurityShimClient.main(arguments: Array(CommandLine.arguments.dropFirst(2))))
}

let response: [String: Any]
do {
    guard CommandLine.arguments.count == 3 else {
        throw HelperFailure(message: "Use native-helper <operation> <JSON arguments or ->.")
    }
    let encoded = CommandLine.arguments[2] == "-"
        ? FileHandle.standardInput.readDataToEndOfFile() : Data(CommandLine.arguments[2].utf8)
    guard encoded.count <= 128 * 1024 * 1024,
          let args = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
        throw HelperFailure(message: "Native-helper arguments must be a JSON object within the size limit.")
    }
    response = ["value": try execute(CommandLine.arguments[1], args)]
} catch {
    response = ["error": error.localizedDescription]
}
if let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
   let output = String(data: data, encoding: .utf8) {
    print(output)
} else {
    print("{\"error\":\"The native helper could not encode its result.\"}")
}
