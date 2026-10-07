import Foundation
import TerminalDeckNativeCore

/// Uses deck-core's exact report and importance judgement, plus the existing
/// PTY retained-scrollback view. sessionViews must be the authenticated caller's
/// current fleet, already projected by the same viewOf as sessions.list.
public struct BackendDeckToolsTourNativeEvidence: BackendDeckToolsTourEvidence, Sendable {
    private let surface: any BackendDeckCoreCatalogueSurface
    private let views: @Sendable () async throws -> [NativeRPCValue]
    private let scrollback: @Sendable (String) async throws -> String
    public init(surface: any BackendDeckCoreCatalogueSurface,
                sessionViews: @escaping @Sendable () async throws -> [NativeRPCValue],
                scrollback: @escaping @Sendable (String) async throws -> String) {
        self.surface = surface; views = sessionViews; self.scrollback = scrollback
    }
    public func facts(sessionID: String) async throws -> NativeRPCValue? {
        guard let session = try await views().first(where: { $0["id"].string == sessionID }) else { return nil }
        let report = try await surface.reportOnSession(session: session)
        let title = session["title"].string.flatMap { $0.isEmpty ? nil : $0 } ?? session["cwd"].string ?? ""
        return BackendDeckToolsSupport.object([("session", session), ("importance", BackendDeckCoreReports.importanceOf(report)),
            ("title", .string(title)), ("screen", .string(try await scrollback(sessionID))), ("changed", report["changes"]["paths"])])
    }
    public func supports(reason: String, importance: NativeRPCValue, median: Double?, sample: Int) async throws -> Bool {
        BackendDeckCoreImportance.supports(reason, input: importance, fleet: .init(medianTokens: median, sample: sample))
    }
}
