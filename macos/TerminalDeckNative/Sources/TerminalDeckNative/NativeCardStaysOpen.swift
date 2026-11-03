import SwiftUI

/// The rule for every card that sends to a session (Screenshot, Video, Annotate; phone and
/// browser): a click outside never closes it. It closes only through its own buttons (Send,
/// Done, Cancel), so what is typed, the crop and the attachment stay while he works elsewhere.
/// Escape is Cancel.
extension View {
    func nativeCardStaysOpen(cancel: @escaping () -> Void) -> some View {
        interactiveDismissDisabled(true)
            .onExitCommand(perform: cancel)
    }
}

/// The card's visible Cancel: closes it and discards what it holds.
struct NativeCardCancelButton: View {
    let action: () -> Void
    var body: some View {
        Button("Cancel", action: action)
            .keyboardShortcut(.cancelAction)
            .help("Close this card and discard it")
    }
}
