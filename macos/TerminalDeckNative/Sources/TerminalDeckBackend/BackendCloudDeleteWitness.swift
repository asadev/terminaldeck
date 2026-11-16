import Foundation

/// The Cloud engines share the accepted-hook witness, including its persisted command identity and names.
/// Constructing this adapter does not open a store or replace the witness installed by session composition.
public struct BackendCloudDeleteWitness: CloudDeleteWitness {
    private let witness: BackendAIDeleteWitness?

    /// Nil follows the production witness once session composition has installed it. Tests pass an isolated one.
    public init(witness: BackendAIDeleteWitness? = nil) {
        self.witness = witness
    }

    public func who(removed path: URL, lastSeen: Date, seenGoneAt: Date) async -> CloudDeleteWitnessAnswer {
        guard path.isFileURL, let witness = witness ?? BackendAIDeleteWitness.current else { return .cannotKnow }
        let answer = witness.assessment(path: path.path, lastSeen: lastSeen, goneAt: seenGoneAt, now: Date())
        switch answer.verdict {
        case .byAI(_, _, let since):
            // Names are captured at the command's start, not looked up after a rename or session removal.
            guard let window = answer.window, let name = window.sessionName,
                  UUID(uuidString: window.group) != nil else { return .cannotKnow }
            return .ai(session: name, agent: window.seatName, command: since, group: window.group)
        case .byHand: return .notAI
        case .cannotKnow: return .cannotKnow
        }
    }
}
