import Observation
import SwiftUI
import TerminalDeckNativeCore

// Hoot on other machines, for the native Hoot screen (lane R embeds these):
//  - `NativeCopilotMachinesModel.shared.machines` — `useCopilotMachines`
//  - `NativeCopilotMachines(chosen:)` — `CopilotMachines.tsx`, the switch at the top
//  - `NativeRemoteCopilot(machine:)` — `RemoteCopilot.tsx`, another machine's Hoot

/// Every machine whose Hoot this computer could talk to: this one (id "") first.
@MainActor
@Observable
final class NativeCopilotMachinesModel {
    static let shared = NativeCopilotMachinesModel()

    private(set) var machines: [CopilotMachineRow] = [CopilotMachineRow(id: "", name: "This Mac", reach: .ready, open: true)]
    @ObservationIgnored private var subscription: EngineSubscription?

    private init() {}

    /// Read the machines once and follow every `machines:state` push after.
    func start() {
        guard subscription == nil, EngineBridge.shared.isReady else { return }
        subscription = EngineBridge.shared.on("machines:state") { [weak self] args in
            self?.machines = CopilotMachineRow.rows(CodingAIJSON(args.first))
        }
        Task {
            if let raw = try? await EngineBridge.shared.invoke("machines:list", []) {
                machines = CopilotMachineRow.rows(CodingAIJSON(raw))
            }
        }
    }

    /// The chosen machine, or nil when it has gone (the page then goes back to this one, id "").
    func machine(_ id: String) -> CopilotMachineRow? {
        machines.first { $0.id == id }
    }
}

/// "Which machine's Hoot": one button per machine, the chosen one marked.
/// Draws nothing while there is only this one.
struct NativeCopilotMachines: View {
    @Binding var chosen: String
    private let model = NativeCopilotMachinesModel.shared

    var body: some View {
        Group {
            if model.machines.count >= 2 {
                HStack(spacing: 6) {
                    ForEach(model.machines) { machine in
                        let on = machine.id == chosen
                        Button {
                            chosen = machine.id
                        } label: {
                            HStack(spacing: 5) {
                                if machine.reach != .ready {
                                    Circle()
                                        .fill(machine.reach == .refused ? Color.orange : Color.secondary)
                                        .frame(width: 6, height: 6)
                                }
                                Text(machine.name)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(on ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.08)))
                            .overlay(Capsule().stroke(on ? Color.secondary.opacity(0.45) : Color.clear))
                        }
                        .buttonStyle(.plain)
                        .help("Hoot on \(machine.name)")
                        .accessibilityAddTraits(on ? [.isSelected] : [])
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Which machine’s Hoot")
            }
        }
        .onAppear { model.start() }
        // A machine that went away while chosen: back to this one.
        .onChange(of: model.machines) { _, rows in
            if !chosen.isEmpty, !rows.contains(where: { $0.id == chosen }) { chosen = "" }
        }
    }
}

/// Another machine's Hoot: the conversation that machine reports, and a line to
/// ask it something. Never a terminal — a copilot's pty is not put on the network.
struct NativeRemoteCopilot: View {
    let machine: CopilotMachineRow
    @State private var model = NativeRemoteCopilotModel()

    var body: some View {
        Group {
            switch machine.reach {
            case .unreachable:
                NativePageEmpty(mark: AnyView(HootMark(size: 96)), title: "\(machine.name) is not connected",
                                message: { EmptyView() }, hint: { EmptyView() }, extra: { EmptyView() })
            case .refused:
                NativePageEmpty(mark: AnyView(HootMark(size: 96)), title: "\(machine.name) is not offering Hoot to this computer",
                                message: { EmptyView() }, hint: { EmptyView() }, extra: { EmptyView() })
            case .ready:
                if let report = model.report {
                    if report.run == nil {
                        NativePageEmpty(mark: AnyView(HootMark(size: 96)), title: "Hoot is not running for you on \(machine.name)",
                                        message: { Text(model.problem.isEmpty ? "It runs there, in that computer's folders, as that computer's account." : model.problem) },
                                        action: PageEmptyAction(label: model.busy ? "Starting…" : "Start it", primary: true, busy: model.busy) { model.start(machine) },
                                        hint: { EmptyView() }, extra: { EmptyView() })
                    } else {
                        conversation
                    }
                } else {
                    NativePageEmpty(mark: AnyView(HootMark(size: 96)), title: "Reaching \(machine.name)…",
                                    message: { Text(model.problem) }, hint: { EmptyView() }, extra: { EmptyView() })
                }
            }
        }
        .onAppear { model.attach(machine) }
        .onChange(of: machine) { old, new in
            if old.id != new.id || old.open != new.open { model.attach(new) }
        }
        .onDisappear { model.detach() }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.bubbles) { bubble in
                            if bubble.role == .agent {
                                HStack(alignment: .top, spacing: 8) {
                                    HootMark(size: 32)
                                    bubbleText(bubble)
                                    Spacer(minLength: 40)
                                }
                            } else {
                                HStack {
                                    Spacer(minLength: 40)
                                    bubbleText(bubble)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .onChange(of: model.bubbles.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            if !model.problem.isEmpty {
                Text(model.problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            HStack(spacing: 8) {
                TextField("Ask Hoot on \(machine.name)", text: $model.typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.say(machine) }
                    .accessibilityLabel("Ask Hoot on \(machine.name)")
                Button("Send") { model.say(machine) }
                    .disabled(model.busy || model.typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
    }

    private func bubbleText(_ bubble: RemoteCopilotBubble) -> some View {
        Text(bubble.text)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(bubble.role == .agent ? Color.secondary.opacity(0.1) : Color.accentColor.opacity(0.18)))
            .id(bubble.id)
    }
}

@MainActor
@Observable
final class NativeRemoteCopilotModel {
    private(set) var report: RemoteCopilotModel.Report?
    private(set) var bubbles: [RemoteCopilotBubble] = []
    var typed = ""
    private(set) var problem = ""
    private(set) var busy = false
    @ObservationIgnored private var machineId = ""
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []

    private func call(_ channel: String, _ args: [Any?]) async -> (ok: Bool, message: String)? {
        guard let raw = try? await EngineBridge.shared.invoke(channel, args) else { return nil }
        return RemoteCopilotModel.outcome(CodingAIJSON(raw))
    }

    /// Follow that machine's Hoot: its state and its conversation, once the link is open.
    func attach(_ machine: CopilotMachineRow) {
        detach()
        machineId = machine.id
        report = nil
        bubbles = []
        problem = ""
        guard machine.open else { return }
        subscriptions = [
            EngineBridge.shared.on("machines:copilot:chat") { [weak self] args in
                let row = CodingAIJSON(args.first)
                guard let self, row["machineId"].string == self.machineId,
                      let chat = RemoteCopilotModel.chat(row["chat"]) else { return }
                self.bubbles = RemoteCopilotModel.apply(self.bubbles, chat)
            },
            EngineBridge.shared.on("machines:copilot:state") { [weak self] args in
                let row = CodingAIJSON(args.first)
                guard let self, row["machineId"].string == self.machineId,
                      let report = RemoteCopilotModel.report(row["state"]) else { return }
                self.report = report
            },
        ]
        let name = machine.name
        let id = machine.id
        Task {
            let answer = await call("machines:copilot:attach", [id])
            guard id == machineId else { return }
            if answer?.ok != true { problem = (answer?.message).flatMap { $0.isEmpty ? nil : $0 } ?? "\(name) did not answer." }
        }
    }

    func detach() {
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
    }

    func start(_ machine: CopilotMachineRow) {
        busy = true
        problem = ""
        Task {
            let answer = await call("machines:copilot:start", [machine.id])
            if answer?.ok != true { problem = (answer?.message).flatMap { $0.isEmpty ? nil : $0 } ?? "\(machine.name) would not start it." }
            busy = false
        }
    }

    func say(_ machine: CopilotMachineRow) {
        let line = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !busy else { return }
        busy = true
        problem = ""
        Task {
            let answer = await call("machines:copilot:say", [machine.id, line])
            if answer?.ok == true {
                typed = ""
            } else if let answer {
                problem = answer.message.isEmpty ? "\(machine.name) refused it." : answer.message
            } else {
                problem = "\(machine.name) did not answer."
            }
            busy = false
        }
    }
}
