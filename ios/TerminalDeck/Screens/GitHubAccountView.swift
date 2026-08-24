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
 * ## The sign-in does not belong to this screen
 *
 * `signIn` is read off the model rather than built here, and that is the fix for
 * the fault he recorded rather than a tidy-up. A device flow lasts as long as
 * somebody takes to type a code into a browser in another app; when it was this
 * screen's `@State`, pressing **Done** — the obvious thing to do on coming back
 * to a screen that has not caught up yet — tore the flow down one poll short of
 * the token, and reopening the screen offered to start again. See `DeckModel`.
 *
 * ## Signing in is half of it
 *
 * The registration is a **GitHub App** now, so a token only reaches repositories
 * the app is installed on and the person chooses those on GitHub's install
 * screen. That screen is the entire reason for the move off OAuth — it is where
 * "only these repositories" is said — so the link to it is on this screen rather
 * than left for somebody to discover after a push is refused.
 */

import SwiftUI

struct GitHubAccountView: View {
    let model: DeckModel
    let dismiss: () -> Void

    @State private var showingTokenField = false
    @State private var typedToken = ""

    @Environment(\.openURL) private var openURL

    /// Read through, never stored. The flow belongs to the model — see the
    /// header — and a `@State` copy here is precisely the bug that was fixed.
    private var signIn: GitHubSignIn { model.gitHubSignIn }

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
        // Nothing is cancelled on the way out, deliberately. Closing this sheet
        // used to end a sign-in that was seconds from finishing — see the
        // header, and `GitHubSignIn.cancel`. The flow belongs to the model, ends
        // by itself when GitHub's code expires, and has a Cancel button of its
        // own for somebody who has actually changed their mind.
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

            /*
             * The half a sign-in does not do.
             *
             * A GitHub App's token reaches the repositories the app is installed
             * on and no others, so an account connected here can still be
             * refused by `git` — and the refusal happens on somebody else's
             * machine, in a push, which is the worst place to discover it. Only
             * on a `signIn` account: a pasted personal access token carries its
             * own repository list and this link would be about nothing.
             */
            if account.source == .signIn {
                Button {
                    openURL(gitHubInstallURL)
                } label: {
                    Text("Choose repositories on GitHub")
                        .font(.system(size: 15))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .padding(.top, 14)
                .accessibilityIdentifier("github.chooseRepos")
            }

            Button {
                model.disconnectGitHub()
            } label: {
                Text("Disconnect")
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    // See `waiting`: a plain button is only as tappable as the
                    // shape of its label, and a `Text` centred in a full-width
                    // frame is a word in the middle of a dead pill.
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.critical)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
            // See `waiting`. This one worked more often only because its label
            // is longer, not because it was any more of a button.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.onAccent)
        .background(Theme.accent.opacity(signIn.isBusy ? 0.6 : 1),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .disabled(signIn.isBusy)
        .padding(.top, 24)
        .accessibilityIdentifier("github.signIn")

        Text("You choose which repositories Terminal Deck may touch, on GitHub, when you install it.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)

        if showingTokenField {
            VStack(alignment: .leading, spacing: 12) {
                SecureField("ghp_… or github_pat_…", text: $typedToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 15, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
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
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.primary)
                .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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

            Text("Enter this on GitHub, then come back. It finishes on its own — closing this screen does not stop it.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            /*
             * The button he tapped seven times.
             *
             * `.contentShape(Rectangle())` is the whole of it, and it is not
             * defensive. `.buttonStyle(.plain)` makes the *label* the target,
             * and this label is a `Text` centred inside `.frame(maxWidth:
             * .infinity)` — a frame is a layout container, not a surface, so
             * only the drawn word takes a touch. The blue pill is painted by a
             * `.background` on the button, three hundred points wide; the word
             * "Open GitHub" in the middle of it is about a hundred. Two thirds
             * of what looks like a button was not one, and a thumb aimed at a
             * pill lands off the word more often than on it — which is exactly
             * "I clicked, nothing happened… now I click a lot and one action
             * happened". A content shape makes the whole frame the target.
             *
             * The same trap is under every `.buttonStyle(.plain)` on this screen
             * and each one is fixed the same way.
             */
            Button {
                openURL(verificationURI)
            } label: {
                Text("Open GitHub")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.onAccent)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
