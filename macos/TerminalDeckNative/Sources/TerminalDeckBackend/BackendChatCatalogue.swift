import TerminalDeckNativeCore

extension BackendSessionChats {
    /// Listing conversations never reads their transcripts to calculate attention counts.
    public func conversationCatalogue(project: String? = nil, agent: String? = nil, state: String? = nil) -> [NativeRPCValue] {
        conversations(project: project, agent: agent, state: state).map(\.wire)
    }
}
