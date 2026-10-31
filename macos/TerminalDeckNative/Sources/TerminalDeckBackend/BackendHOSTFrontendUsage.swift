#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import TerminalDeckNativeCore

extension BackendHOSTFrontendResources {
    /// Same original request scope, real helper account/probe and original app
    /// resolver. No app broker/env/token is created or returned here.
    public static func usageProbe(client: BackendHOSTClient, account: BackendUsageAccount,
                                  cancellation: BackendMCPCancellation?) async -> BackendUsageProbe.Outcome {
        let started = Date()
        func unreadable(_ detail: String) -> BackendUsageProbe.Outcome {
            .init(kind: "unreadable", detail: detail, readings: [], spawned: false,
                  elapsedMilliseconds: Date().timeIntervalSince(started) * 1000)
        }
        do {
            guard cancellation?.isCancelled != true else { throw CancellationError() }
            let app = try accountApp(client: client), original = try BackendHOSTProfileScope.requireCurrent()
            let request = try app.authority.begin(channel: "host.usage.probe", arguments: [account.wireValue], context: original)
            defer { app.authority.complete(request.nonce) }
            let scope = BackendMCPCancellation()
            let observer = cancellation?.observe {
                scope.cancel()
                app.authority.complete(request.nonce)
                Task { _ = try? await client.resource("account.cancel", arguments: .object([.init("nonce", .string(request.nonce.uuidString))])) }
            }
            defer { if let observer { cancellation?.removeObserver(observer) } }
            return try await withTaskCancellationHandler {
                _ = try await app.authority.authorize(request: request, cancellation: scope)
                guard !scope.isCancelled else { throw CancellationError() }
                let reply = try await client.resource("account.facade", arguments: NativeRPCValue.parseJSON(JSONEncoder().encode(request)))
                _ = try await app.authority.authorize(request: request, cancellation: scope)
                guard !scope.isCancelled else { throw CancellationError() }
                return try BackendHOSTUsageWire.outcome(reply)
            } onCancel: {
                scope.cancel(); app.authority.complete(request.nonce)
                Task { _ = try? await client.resource("account.cancel", arguments: .object([.init("nonce", .string(request.nonce.uuidString))])) }
            }
        } catch is CancellationError { return unreadable("The original usage request was cancelled.") }
        catch { return unreadable("The original account/provider usage owner is unavailable: " + error.localizedDescription) }
    }
}
private enum BackendHOSTUsageWire {
    static func outcome(_ value: NativeRPCValue) throws -> BackendUsageProbe.Outcome {
        let kind = try value["kind"].requireString("actual usage outcome"), detail = try value["detail"].requireString("actual usage detail")
        guard let spawned = value["spawned"].bool, let elapsed = value["elapsedMilliseconds"].number,
              elapsed.isFinite, elapsed >= 0, let values = value["readings"].elements, values.count <= 64 else {
            throw BackendHOSTFailure.invalid("Invalid actual usage probe outcome.")
        }
        return .init(kind: kind, detail: detail, readings: try values.map(reading), spawned: spawned, elapsedMilliseconds: elapsed)
    }
    static func reading(_ value: NativeRPCValue) throws -> BackendUsageReading {
        let accountValue = value["account"]
        let provider = try accountValue["provider"].requireString("actual usage provider")
        let account = BackendUsageAccount(provider: provider, id: accountValue["id"].string, name: accountValue["name"].string,
            configDirectory: accountValue["configDir"].string)
        guard provider == "claude", let window = value["window"].string.flatMap(BackendUsageWindow.init(rawValue:)),
              let observed = value["observedAt"].number, let reported = value["reportedAt"].number,
              observed.isFinite, reported.isFinite else { throw BackendHOSTFailure.invalid("Invalid actual usage reading identity.") }
        let amount: BackendUsageAmount
        switch value["used"]["kind"].string {
        case "reported":
            guard let fraction = value["used"]["fraction"].number, fraction.isFinite, fraction >= 0 else { throw BackendHOSTFailure.invalid("Invalid actual utilization.") }
            amount = .reported(fraction: fraction)
        case "not-reported": amount = .notReported
        default: throw BackendHOSTFailure.invalid("Unknown actual usage amount.")
        }
        let reset: BackendUsageReset
        switch value["resets"]["kind"].string {
        case "at":
            guard let date = value["resets"]["at"].number, date.isFinite, date > 0 else { throw BackendHOSTFailure.invalid("Invalid actual reset timestamp.") }
            reset = .at(date)
        case "described": reset = .described(try value["resets"]["text"].requireString("actual reset description"))
        case "not-reported": reset = .notReported
        default: throw BackendHOSTFailure.invalid("Unknown actual usage reset.")
        }
        let originalID = try value["id"].requireString("actual usage reading id")
        let prefix = account.key + "/" + window.rawValue
        let qualifier: String?
        if originalID == prefix { qualifier = nil }
        else if originalID.hasPrefix(prefix + ":") { qualifier = String(originalID.dropFirst(prefix.count + 1)) }
        else { throw BackendHOSTFailure.invalid("The actual usage reading changed identity.") }
        let reading = BackendUsageReading(account: account, window: window, qualifier: qualifier, windowMinutes: value["windowMinutes"].number,
            label: try value["label"].requireString("actual usage window"), used: amount, resets: reset,
            observedAt: observed, reportedAt: reported, source: try value["source"].requireString("actual usage evidence source"))
        guard originalID == reading.id else { throw BackendHOSTFailure.invalid("The actual usage reading changed identity.") }
        return reading
    }
}
#endif
