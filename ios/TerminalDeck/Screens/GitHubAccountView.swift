/**
 * The GitHub account on this phone: connect one, or forget the one that is here.
 *
 * ## What is deliberately not on this screen
 *
 * Any sentence reassuring somebody that their token is not stored on the machine
 * they are working on. That copy was written and cut, and cutting it was right:
 * the approval prompt already names the repository, the account and the machine
 * that asked, which is the explanation. A paragraph here would be a second,
 * weaker version of it in the one place nobody looks.
 *
 * What is left is one line saying what connecting is *for*, which is a fact
 * about behaviour rather than a claim about safety, and then the controls.
 *
 * ## Why the borrowed OAuth client is named out loud
 *
 * GitHub's consent page will say "GitHub CLI" rather than this product's name,
 * because this project has not registered an application of its own yet. A
 * person who taps Sign in and lands on a page bearing somebody else's name will
 * — correctly — think something is wrong. So it is said before the tap rather
 * than discovered after it. See `GitHubSignIn`.
 */

import SwiftUI

struct GitHubAccountView: View {
    let model: DeckModel
    let dismiss: () -> Void

    @State private var signIn: GitHubSignIn
    @State private var showingTokenField = false
    @State private var typedToken = ""

    @Environment(\.openURL) private var openURL

    init(model: DeckModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
        _signIn = State(initialValue: model.makeGitHubSignIn())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let account = model.gitHubAccount {
                            connected(account)
                        } else {
                            disconnected
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("github.done")
                }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        // A poll that outlives the screen would wake the radio every five
        // seconds for a code nobody is going to type.
        .onDisappear { signIn.cancel() }
    }

    // MARK: - Connected

    private func connected(_ account: GitHubAccount) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("@\(account.login)")
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .accessibilityIdentifier("github.login")

            Text(source(account))
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .padding(.top, 6)

            Button {
                model.disconnectGitHub()
            } label: {
                Text("Disconnect")
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.critical)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 28)
            .accessibilityIdentifier("github.disconnect")
        }
    }

    private func source(_ account: GitHubAccount) -> String {
        let when = account.connectedAt.formatted(date: .abbreviated, time: .omitted)
        switch account.source {
        case .signIn: return "Signed in on \(when)"
        case .token: return "Personal access token, added \(when)"
        }
    }

    // MARK: - Not connected

    @ViewBuilder
    private var disconnected: some View {
        Text("Used when git on a machine you are working on needs a login.")
            .font(.system(size: 15))
            .foregroundStyle(Theme.secondary)
            .fixedSize(horizontal: false, vertical: true)

        switch signIn.phase {
        case let .waiting(userCode, verificationURI):
            waiting(userCode: userCode, verificationURI: verificationURI)
        default:
            entry
        }

        if case let .failed(sentence) = signIn.phase {
            Text(sentence)
                .font(.system(size: 13))
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .accessibilityIdentifier("github.error")
        }
    }

    @ViewBuilder
    private var entry: some View {
        Button {
            signIn.start()
        } label: {
            HStack(spacing: 8) {
                if signIn.isBusy { ProgressView().controlSize(.small).tint(Theme.onAccent) }
                Text(signIn.isBusy ? "Working…" : "Sign in with GitHub")
                    .font(.system(size: 17, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.onAccent)
        .background(Theme.accent.opacity(signIn.isBusy ? 0.6 : 1),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .disabled(signIn.isBusy)
        .padding(.top, 24)
        .accessibilityIdentifier("github.signIn")

        if gitHubClientIsBorrowed {
            Text("GitHub will name the sign-in “GitHub CLI”. This app has not registered one of its own yet.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }

        if showingTokenField {
            VStack(alignment: .leading, spacing: 12) {
                SecureField("ghp_… or github_pat_…", text: $typedToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 15, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.hairline, lineWidth: 1)
                    }
                    .accessibilityIdentifier("github.tokenField")

                Button {
                    signIn.useToken(typedToken)
                    typedToken = ""
                } label: {
                    Text("Use this token")
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.primary)
                .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(signIn.isBusy)
                .accessibilityIdentifier("github.useToken")
            }
            .padding(.top, 20)
        } else {
            Button("Use a token instead") { showingTokenField = true }
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
                .padding(.top, 18)
                .accessibilityIdentifier("github.useTokenInstead")
        }
    }

    private func waiting(userCode: String, verificationURI: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(userCode)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
                .accessibilityIdentifier("github.userCode")

            Text("Enter this on GitHub, then come back. This screen finishes on its own.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            Button {
                openURL(verificationURI)
            } label: {
                Text("Open GitHub")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.onAccent)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 22)
            .accessibilityIdentifier("github.openGitHub")

            Button("Cancel") { signIn.cancel() }
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
                .padding(.top, 14)
                .accessibilityIdentifier("github.cancelSignIn")
        }
        .padding(.top, 26)
    }
}
