import SwiftUI
import TerminalDeckNativeCore

/// "Add a server" (`AddServer.tsx`): the address, the port, the name you sign in
/// with, a password or a key (from the keys this Mac has, a file, or pasted),
/// the key's own password when it needs one, what to call it, and whether to
/// remember the sign-in.
struct NativeAddServerPage: View {
    @Bindable var model: NativeServersModel
    @Binding var route: NativeServersRoute
    @State private var address = ""
    @State private var port = ""
    @State private var username = ""
    @State private var method = "password"
    @State private var password = ""
    @State private var key = ""
    @State private var passphrase = ""
    @State private var name = ""
    @State private var remember = true

    var body: some View {
        let locked = AddServerRules.wantsPassphrase(model.addReason, passphrase: passphrase)
        let chosenPort = AddServerRules.readPort(port)
        let filled = !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && chosenPort.ok
            && (method == "password" ? !password.isEmpty : !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button("Back to machines") { cancel() }
                    .disabled(model.adding)
                Text("Add a server").font(.title3.weight(.semibold))
                Text("Three things, and you can get all three from whoever set the server up.")
                    .foregroundStyle(.secondary)
                if let error = model.addError {
                    NativeCodingAINotice(tone: .error, text: error)
                }

                field("Address", help: "Where the server is. A name like example.com, or a set of numbers like 203.0.113.10.") {
                    TextField("Address", text: $address)
                }
                field("Port", help: chosenPort.ok ? AddServerRules.portHelp : (chosenPort.sentence ?? ""), warn: !chosenPort.ok) {
                    TextField("Port", text: $port, prompt: Text("22"))
                        .frame(width: 110)
                }
                field("The name you sign in with", help: "Whoever set the server up chose this. It is often a word like admin, or your own name.") {
                    TextField("The name you sign in with", text: $username)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("How you sign in").font(.headline)
                    Picker("How you sign in", selection: $method) {
                        Text("With a password").tag("password")
                        Text("With a key").tag("key")
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                if method == "password" {
                    field("Password", help: nil) {
                        SecureField("Password", text: $password)
                    }
                } else {
                    NativeServerKeyField(model: model, key: $key)
                }
                if method == "key" && locked {
                    field("The password that opens the key", help: "Keys are often locked with one. It is not the same as the password for the server.") {
                        SecureField("The password that opens the key", text: $passphrase)
                    }
                }

                field("What to call it here", help: "Optional. Leave it empty and the address is used.") {
                    TextField("What to call it here", text: $name)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Remember this sign-in on this computer", isOn: $remember)
                        .toggleStyle(.checkbox)
                    Text("Turn this off and it is used once and forgotten when you close the app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }

                HStack {
                    Button(model.adding ? "Connecting…" : "Add server") {
                        submit(locked: locked, port: chosenPort.port)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!filled || model.adding)
                    Button("Cancel") { cancel() }
                        .disabled(model.adding)
                }
            }
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field<Control: View>(_ label: String, help: String?, warn: Bool = false, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.headline)
            control().labelsHidden()
            if let help {
                Text(help)
                    .font(.callout)
                    .foregroundStyle(warn ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func submit(locked: Bool, port: Int?) {
        let draft = AddServerRules.draft(address: address, port: port, username: username, method: method,
                                         password: password, key: key, passphrase: passphrase, locked: locked,
                                         name: name, remember: remember)
        model.submit(draft, route: $route)
    }

    private func cancel() {
        model.clearAddError()
        route = .list
    }
}

/// "Your key" (`KeyField`): the keys this Mac has, a file, or pasting it.
struct NativeServerKeyField: View {
    let model: NativeServersModel
    @Binding var key: String
    @State private var found: [AddServerRules.KeyOffer] = []
    @State private var chosen: AddServerRules.KeyOffer?
    @State private var problem: String?
    @State private var pasting = false

    var body: some View {
        let routes = AddServerRules.keyRoutes(hasChooser: true, found: found.count, chosen: chosen != nil, pasting: pasting)
        VStack(alignment: .leading, spacing: 8) {
            Text("Your key").font(.headline)
            if routes.list {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(found) { offer in
                        Button { use(offer) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: chosen?.path == offer.path ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(chosen?.path == offer.path ? Color.accentColor : Color.secondary)
                                Text(offer.name)
                                Text(offer.says).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if routes.panel {
                HStack {
                    Button("Choose a file…", action: browse)
                    if routes.offerPaste {
                        Button("Paste it instead") {
                            key = AddServerRules.pasteBoxText(fromFile: chosen != nil, typed: key)
                            chosen = nil
                            pasting = true
                        }
                    }
                }
            }
            if let chosen, !pasting {
                Text("Using \(Text(chosen.name).bold()). Its contents are not shown here, and they go nowhere except to the server you are adding.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if routes.paste {
                Text(routes.list ? "Or paste it, including the first and last lines." : "Paste the whole file, including the first and last lines.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { key }, set: { key = $0; chosen = nil }))
                    .font(.callout.monospaced())
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
            }
            if let problem { NativeCodingAINotice(tone: .warn, text: problem) }
        }
        .task {
            found = await model.listKeys()
        }
    }

    private func use(_ offer: AddServerRules.KeyOffer) {
        problem = nil
        Task {
            let answer = await model.readKey(offer.path)
            if answer.ok, let text = answer.key {
                chosen = offer
                key = text
            } else {
                chosen = nil
                problem = answer.sentence
            }
        }
    }

    private func browse() {
        problem = nil
        Task {
            do {
                if let offer = try await model.pickKey() { use(offer) }
            } catch {
                problem = "That file could not be opened. Try choosing it again."
            }
        }
    }
}
