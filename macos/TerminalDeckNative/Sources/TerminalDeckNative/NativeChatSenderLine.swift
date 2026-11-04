import SwiftUI

struct NativeChatSenderLine<Avatar: View>: View {
    let name: String
    @ViewBuilder var avatar: () -> Avatar
    var body: some View {
        HStack(spacing: DeckTokens.Spacing.s8) {
            avatar()
            Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
}
