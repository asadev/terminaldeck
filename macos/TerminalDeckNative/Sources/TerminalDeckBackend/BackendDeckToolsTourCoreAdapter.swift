import Foundation
import TerminalDeckNativeCore

/// The core door's tour channels share the exact stage used by tour.play.
/// Approver/window authentication remains at that door, before these calls.
public struct BackendDeckToolsTourCoreAdapter: BackendDeckCoreTours, Sendable {
    public let stage: BackendDeckToolsTourStage
    public init(stage: BackendDeckToolsTourStage) { self.stage = stage }
    public func driving() async -> Bool { await stage.driving() }
    public func list(count: Int) async throws -> [NativeRPCValue] { await stage.list(limit: count) }
    public func acknowledge(id: String) async throws -> Bool { await stage.acknowledge(id) }
    public func progress(id: String, record: NativeRPCValue) async throws -> Bool { await stage.progress(id, update: record) != .null }
    public func end(id: String, record: NativeRPCValue) async throws -> Bool { await stage.end(id, update: record) != .null }
    public func windowGone() async { await stage.stop() }
    public func stop() async { await stage.stop() }
}
