import Foundation
import TerminalDeckNativeCore

/// I10 owners. Each adapter binds its owner to one Cloud account on first use; `CloudBrainAgentsPump.stop()`
/// (sign-out) detaches it so nothing more is captured into that account (design D3).
public enum BackendCloudBrainAgents {
  public static func adapter(owner: BackendTaskConfiguration, account: CloudBrainAgentsAccount) -> CloudBrainAgentsAdapter {
    .init(row: "I10", domains: ["agents"], owner: .init(
      inventory: { try await owner.cloudAttach(account); return try await owner.cloudAgentInventory() },
      snapshot: { cut in try await owner.cloudAttach(account); return try await owner.cloudAgentSnapshot(cut: cut) },
      apply: { incoming in try await owner.cloudAttach(account); return try await owner.cloudAgentImport(incoming) },
      retained: { try await owner.cloudAgentRetained($0) },
      ownChanges: { try await owner.cloudAgentOwnChanges(after: $0, limit: $1) },
      cursor: { try await owner.cloudAgentCursor() },
      saveCursor: { try await owner.cloudAgentSaveCursor($0) },
      notices: { await owner.cloudAgentNotices() },
      detach: { await owner.cloudDetach() }))
  }
  public static func optionsAdapter(owner: BackendAGSStore, account: CloudBrainAgentsAccount) -> CloudBrainAgentsAdapter {
    .init(row: "I10", domains: ["agent-options"], owner: .init(
      inventory: { try await owner.cloudAttach(account); return try await owner.cloudOptionsInventory() },
      snapshot: { cut in try await owner.cloudAttach(account); return try await owner.cloudOptionsSnapshot(cut: cut) },
      apply: { incoming in try await owner.cloudAttach(account); return try await owner.cloudOptionsImport(incoming) },
      retained: { try await owner.cloudOptionsRetained($0) },
      ownChanges: { try await owner.cloudOptionsOwnChanges(after: $0, limit: $1) },
      cursor: { try await owner.cloudOptionsCursor() },
      saveCursor: { try await owner.cloudOptionsSaveCursor($0) },
      notices: { await owner.cloudOptionsNotices() },
      detach: { await owner.cloudDetach() }))
  }
  public static func shellAdapter(owner: BackendAGTShellAgents, account: CloudBrainAgentsAccount) -> CloudBrainAgentsAdapter {
    .init(row: "I10", domains: ["seats"], owner: .init(
      inventory: { try owner.cloudAttach(account); return try owner.cloudSeatInventory() },
      snapshot: { cut in try owner.cloudAttach(account); return try owner.cloudSeatSnapshot(cut: cut) },
      apply: { incoming in try owner.cloudAttach(account); return try owner.cloudSeatImport(incoming) },
      retained: { try owner.cloudSeatRetained($0) },
      ownChanges: { try owner.cloudSeatOwnChanges(after: $0, limit: $1) },
      cursor: { try owner.cloudSeatCursor() },
      saveCursor: { try owner.cloudSeatSaveCursor($0) },
      notices: { owner.cloudSeatNotices() },
      detach: { owner.cloudDetach() }))
  }
  public static func sessionOptionsAdapter(owner: BackendAGSSessionChoices, account: CloudBrainAgentsAccount) -> CloudBrainAgentsAdapter {
    .init(row: "I10", domains: ["agent-session-options"], owner: .init(
      inventory: { try await owner.cloudAttach(account); return try await owner.cloudChoicesInventory() },
      snapshot: { cut in try await owner.cloudAttach(account); return try await owner.cloudChoicesSnapshot(cut: cut) },
      apply: { incoming in try await owner.cloudAttach(account); return try await owner.cloudChoicesImport(incoming) },
      retained: { try await owner.cloudChoicesRetained($0) },
      ownChanges: { try await owner.cloudChoicesOwnChanges(after: $0, limit: $1) },
      cursor: { try await owner.cloudChoicesCursor() },
      saveCursor: { try await owner.cloudChoicesSaveCursor($0) },
      notices: { await owner.cloudChoicesNotices() },
      detach: { await owner.cloudDetach() }))
  }
}
