/**
 * The approval prompt — the one screen that is the entire explanation of the
 * credential proxy.
 *
 * There is deliberately no paragraph anywhere in this app saying that the token
 * is never stored on the other machine. Asad cut that copy and he is right: a
 * sentence in a settings pane that nobody reads is not security, it is
 * decoration. What is left is this, and this has to carry the whole idea in
 * three lines:
 *
 *   - **the repository**, so an approval is about one thing and not about
 *     everything the account can reach;
 *   - **the account**, so somebody can see whose name goes on the commit;
 *   - **the machine that asked, by name**, which is the line that makes it a
 *     question rather than a formality. "Approve a push" is not answerable.
 *     "Approve a push from *Work PC*" is.
 *
 * ## When the repository has no name
 *
 * The desktop sends nil when git gave it no path to derive one from — a gist, a
 * wiki, a self-hosted layout — and this says so rather than inventing a name.
 * That is not pedantry: the one screen in this feature that exists to tell the
 * truth about what is being approved must not be capable of naming the wrong
 * thing. "Always for this repo" disappears with it, because there is nothing to
 * attach the always to and the desktop refuses to record one.
 *
 * ## Why it cannot be swiped away
 *
 * A swipe down is not an answer, and the far end is a `git push` sitting on a
 * socket. Leaving without deciding would make it wait out the full minute and
 * then fail with "nobody answered on your device", which is a worse outcome than
 * either button and is one nobody would have chosen on purpose. Three buttons,
 * all of which answer.
 */

import SwiftUI

struct CredentialPromptView: View {
    let request: CredentialRequest
    /// The account whose name goes on the commit, if there still is one.
    let account: GitHubAccount?
    let approve: (_ remember: Bool) -> Void
    let deny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let repo = request.repo {
                // Mono because it is data: an `owner/name` is a thing somebody
                // typed and can check character by character, which is exactly
                // what this line is for.
                Text(repo)
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.primary)
                    .padding(.top, 6)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("credential.repo")
            }

            VStack(alignment: .leading, spacing: 10) {
                row(label: "Account", value: account.map { "@\($0.login)" } ?? "none connected", mono: true)
                row(label: "Host", value: request.origin, mono: true)
                // The line the whole prompt turns on. Not mono: it is the name a
                // person gave their machine, which is prose rather than data.
                row(label: "Asked by", value: request.machineName, mono: false)
            }
            .padding(.top, 22)

            Spacer(minLength: 24)

            VStack(spacing: 10) {
                Button {
                    approve(false)
                } label: {
                    Text("Approve")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.onAccent)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("credential.approve")

                // Only when there is a repository to remember. See the header.
                if request.repo != nil {
                    Button {
                        approve(true)
                    } label: {
                        Text("Always for this repo")
                            .font(.system(size: 16, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.primary)
                    .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("credential.approveAlways")
                }

                Button {
                    deny()
                } label: {
                    Text("Deny")
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .accessibilityIdentifier("credential.deny")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        // No identifier on this container, deliberately. One was here and it
        // matched nothing: an identifier on a `VStack` does not become an
        // element XCUITest can find, so `app.otherElements["credential.prompt"]`
        // resolved to nothing while the prompt was plainly on screen — which
        // reads as the sheet never appearing. The three buttons carry
        // identifiers and are what a test should ask about; an identifier that
        // matches nothing is worse than none, because somebody will trust it.
        .interactiveDismissDisabled()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    /**
     * The question, in the words of whatever git is doing.
     *
     * `prompt` is true for a push in every case a desktop sends today, but the
     * verb is read off `operation` rather than assumed: the two are separate
     * fields precisely so a client can say what is happening rather than what it
     * expected to happen.
     */
    private var title: String {
        let verb = request.operation == .write ? "Push" : "Sign in"
        if request.repo == nil {
            return "\(verb) to a repository on \(request.origin)?"
        }
        return request.operation == .write ? "Push to this repository?" : "Sign in to this repository?"
    }

    private func row(label: String, value: String, mono: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(mono
                      ? .system(size: 14, weight: .medium, design: .monospaced)
                      : .system(size: 15))
                .foregroundStyle(Theme.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        }
    }
}

/**
 * Put the prompt wherever this is applied.
 *
 * A modifier rather than a bare `.sheet` on `RootView` only because it is worth
 * writing the binding and the dismissal rule down once. There is one copy, on
 * `RootView`.
 *
 * There used to be two, with an `armed` flag deciding which was live, because
 * the localhost browser was a `fullScreenCover` and a sheet asked for by an
 * ancestor of a cover has nothing to present from. That screen is a push now, so
 * the second copy and the flag are gone — the note is kept because the trap is
 * real and would come back with the next `fullScreenCover` anybody adds.
 */
struct CredentialPromptHost: ViewModifier {
    let model: DeckModel

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { model.credentialPrompt },
            // A dismissal that is not one of the three buttons cannot happen —
            // `interactiveDismissDisabled` sees to that — so this setter only
            // ever runs as the sheet closes behind an answer that was already
            // sent, and has nothing left to do.
            set: { _ in }
        )) { request in
            CredentialPromptView(
                request: request,
                account: model.gitHubAccount,
                approve: { model.approveCredential(remember: $0) },
                deny: { model.denyCredential() },
            )
            .preferredColorScheme(.dark)
        }
    }
}

extension View {
    func credentialPrompt(_ model: DeckModel) -> some View {
        modifier(CredentialPromptHost(model: model))
    }
}
