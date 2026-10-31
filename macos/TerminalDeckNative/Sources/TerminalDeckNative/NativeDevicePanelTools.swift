import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func devicePanelToolDefinitions(gate: BackendCompositionDeckToolsGate) throws -> [BackendDeckToolsDefinition] {
        let spec = try BackendMCPTool(id: "sessions.device_panels", wireName: "sessions_device_panels",
            description: "Read/open/close/pick either of the two device panels belonging to Hoot (sessionId hoot) or a local Chat/terminal session. Slot 0 is first, 1 second. Pick requires slot and an already-running deviceId; existing device tools own explicit boot/start. Close without slot hides both panels and keeps devices running. Open and pick leave the person's window where it is; show true also brings that session (or Hoot) to the front. Mac owner only; normal consent applies.",
            inputSchema: try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"sessionId":{"type":"string"},"do":{"type":"string","enum":["read","open","close","pick"]},"slot":{"type":"integer","minimum":0,"maximum":1},"deviceId":{"type":"string"},"show":{"type":"boolean"}},"required":["sessionId","do"],"additionalProperties":false}"#.utf8)), tier: .read)
        return [BackendDeckToolsDefinition(spec: spec, title: "Hoot and session device panels") { caller, args in
            await BackendDeckToolsSupport.reply {
                let resolved = try await gate.authority.resolve(caller)
                guard resolved.caller.kind == .local else { throw NativeRPCError(code: "not-granted", message: "Managing panels on this Mac belongs to its owner.") }
                let id = try args["sessionId"].requireString("session ID", nonempty: true), action = try args["do"].requireString("action")
                guard ["read", "open", "close", "pick"].contains(action) else { throw NativeRPCError.invalidArguments("Choose read, open, close or pick.") }
                if id != "hoot" { let meta = try await gate.authority.requireSession(id, native: caller); guard meta.exitCode == nil else { throw NativeRPCError.invalidArguments("Choose a live local session.") } }
                let slot = args["slot"].isNullish ? nil : try NativeDevicePanelSurface.slot(args["slot"].number)
                if action == "pick", slot == nil { throw NativeRPCError.invalidArguments("Name device slot 0 or 1 when picking a device.") }
                let show = args["show"].bool == true
                try await gate.authorize(caller, action == "read" ? .read : action == "pick" ? .alter : .act, "\(action.capitalized) device panel for \(id)", action != "read")
                let result = try await Task { @MainActor in
                    let store = NativeUIGSessionSimulatorStore.shared, owner = NativeUIGSessionSimulatorStore.owner(id)
                    guard !owner.isRemote, !owner.ended, !owner.removed else { throw NativeRPCError.invalidArguments("Choose a live local panel owner.") }
                    let entry = store.entry(owner, slot: slot ?? 0)
                    if action == "open" { entry.setOpen(true) }
                    if action == "close" { if slot == nil { store.closeAll(owner) } else { store.close(entry) } }
                    if action == "pick" {
                        let wanted = try args["deviceId"].requireString("running device ID", nonempty: true)
                        _ = await entry.model.refresh()
                        guard let device = entry.entries.first(where: { $0.id == wanted && $0.available }) else { throw NativeRPCError.invalidArguments("Pick an already-running device from devices_list; explicit device start uses the existing device tools.") }
                        guard entry.model.markers.isEmpty || entry.ticket?.deviceID == wanted else { throw NativeRPCError.invalidArguments("Keep or discard this panel's unsent markers before changing its device.") }
                        entry.setOpen(true); await entry.select(device)
                        guard entry.ticket?.deviceID == device.id else { throw NativeRPCError(code: "attach-failed", message: entry.problem.isEmpty ? "The device attachment was not confirmed." : entry.problem) }
                    }
                    // The person's window moves only when the caller asks for it: an agent opening a panel for
                    // session B must not pull the person away from session A.
                    if ["open", "pick"].contains(action), show { if id == "hoot" { HootProfileRoute.close() }; AppModel.shared.select(id) }
                    let panels = [0, 1].map { store.entry(owner, slot: $0) }
                    return NativeRPCValue.object([.init("sessionId", .string(id)), .init("maximumDevices", .number(2)), .init("panels", .array(panels.map { panel in
                        .object([.init("slot", .number(Double(panel.slot))), .init("open", .bool(panel.layout.isOpen)), .init("detached", .bool(panel.inOwnWindow)), .init("deviceId", panel.ticket?.deviceID.map(NativeRPCValue.string) ?? .null)])
                    }))])
                }.value
                await gate.noteResult(caller, result); return .value(result)
            }
        }]
    }
}
