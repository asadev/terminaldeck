import SwiftUI
import TerminalDeckNativeCore

struct NativeChatQuestionsCard: View {
    let request: NativeRPCValue
    let disabled: Bool
    let answer: (Bool, NativeRPCValue) -> Void

    var body: some View {
        NativeChatElicitationCard(request: request, disabled: disabled, answer: answer)
            .id(request["requestId"].string ?? request.compact)
    }
}
