import Foundation
import TerminalDeckNativeCore

public struct BackendInsightsService: Sendable {
    public static let channels: Set<String> = ["insights:session", "insights:latest", "insights:list"]
    private let cost: BackendCostService
    public init(cost: BackendCostService) { self.cost = cost }
    public func session(path: String, context: NativeRPCContext, cancellation: BackendMCPCancellation? = nil,
                        maxTimeline: Int = 750, maxContextPoints: Int = 400) async throws -> NativeRPCValue {
        guard (0...5000).contains(maxTimeline), (0...4000).contains(maxContextPoints) else { throw NativeRPCError.invalidArguments("The insights response limits are too large.") }
        return try await cost.session(path: path, context: context, cancellation: cancellation).insights(maxTimeline: maxTimeline, maxContextPoints: maxContextPoints)
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        let path = try (args.first ?? .missing).requireString("project/transcript path", nonempty: true)
        switch channel {
        case "insights:session": return try await session(path: path, context: context)
        case "insights:latest": guard let file = try await cost.files(project: path, context: context).first else { return .null }; return try await session(path: file.path, context: context)
        case "insights:list": return .array(try await cost.files(project: path, context: context).map { try NativeRPCValue.fromFoundation($0.wireValue) })
        default: throw BackendSessionFailure.unsupported("The native insights channel is not registered.")
        }
    }
}
