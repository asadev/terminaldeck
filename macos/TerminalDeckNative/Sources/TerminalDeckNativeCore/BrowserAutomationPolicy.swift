import Foundation

/// A JavaScript world isolates globals, not cookies or the person's sign-in.
/// Powerful page controls therefore require a separate, temporary website store.
public enum BrowserAutomationPolicy {
    public static func refusal(operation: String, arguments: NativeRPCValue, isolated: Bool) -> String? {
        if operation == "permissions", ["camera", "microphone"].contains(where: { arguments[$0].string == "allow" }) {
            return "Only the person can allow the camera or microphone on the tab. Use ask or deny."
        }
        if operation == "route" {
            for mock in arguments["mock"].elements ?? [] where !mock["status"].isNullish {
                guard let raw = mock["status"].number, let status = Int(exactly: raw), (200...599).contains(status) else {
                    return "A mocked response status must be a whole number from 200 to 599."
                }
            }
        }
        let needsIsolation: Bool
        switch operation {
        case "evaluate", "storage", "route", "requests", "console", "dialogs", "emulate": needsIsolation = true
        case "wait": needsIsolation = arguments["for"].string == "function"
        default: needsIsolation = false
        }
        if needsIsolation && !isolated {
            return "This control needs an isolated browser tab, so it cannot use the person's saved sign-ins or storage. Open a new window with isolate: true; sessions can use only their own windows."
        }
        return nil
    }
}
