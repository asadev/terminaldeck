import AppKit
import Foundation
import SwiftUI
import TerminalDeckNativeCore

/// UI names are categories; preset identifiers retain their existing payload mapping.
enum NativeRCVSourceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case webhook = "Webhook (any JSON)", whatsapp = "WhatsApp gateway", code = "Code host"
    case errors = "Error tracker", crm = "CRM", uptime = "Uptime monitor"
    case server = "Server alert", chat = "Chat app", containers = "Container host"
    var id: String { rawValue }
    var presetID: String {
        switch self {
        case .webhook: "webhook"; case .whatsapp: "whapi"; case .code: "github"
        case .errors: "sentry"; case .crm: "crm"; case .server: "server"
        case .uptime: "uptime"; case .chat: "chat"; case .containers: "containers"
        }
    }
    var symbol: String {
        switch self {
        case .webhook: "link"; case .whatsapp, .chat: "message"; case .code: "chevron.left.forwardslash.chevron.right"
        case .errors: "ladybug"; case .crm: "person.text.rectangle"; case .uptime: "waveform.path.ecg"
        case .server: "server.rack"; case .containers: "shippingbox"
        }
    }
    var pasteHelp: String {
        switch self {
        case .webhook: "Paste this address into your sender’s webhook settings."
        case .whatsapp: "In your WhatsApp gateway’s settings, paste this address."
        case .code: "In your code host’s webhook settings, paste this address."
        case .errors: "In your error tracker’s integration settings, paste this address."
        case .crm: "In your CRM’s webhook settings, paste this address."
        case .uptime: "In your uptime monitor’s alert settings, paste this address."
        case .server: "Send your server alerts to this address."
        case .chat: "In your chat app’s webhook settings, paste this address."
        case .containers: "In your container host’s alert settings, paste this address."
        }
    }
    static func of(_ source: RCVSource) -> Self {
        // Reading the optional field also supports older encrypted source records.
        if let data = try? JSONEncoder().encode(source),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = object["type"] as? String {
            if let value = Self(rawValue: name) { return value }
            let key = name.lowercased().filter { $0.isLetter || $0.isNumber }
            switch key {
            case "whatsappgateway": return .whatsapp
            case "codehost": return .code
            case "errortracker": return .errors
            case "crm": return .crm
            case "uptimemonitor": return .uptime
            case "serveralert": return .server
            case "chatapp": return .chat
            case "containerhost": return .containers
            case "webhook", "webhookanyjson": return .webhook
            default: break
            }
        }
        return allCases.first { $0.presetID == source.preset } ?? .webhook
    }
    func preset(in presets: [RCVPreset]) -> RCVPreset {
        var value = presets.first { $0.id == presetID } ?? RCVPresets.generic
        value.name = rawValue; value.help = pasteHelp; value.symbol = symbol
        // Categories with no specialised mapping use the existing JSON contract.
        return value
    }
}

/// One seam for the shared shell tokens; replaced when SHELL-CORE publishes READY.
enum NativeRCVSurface {
    static var page: Color { Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 30/255, green: 30/255, blue: 33/255, alpha: 1) : NSColor(red: 247/255, green: 247/255, blue: 249/255, alpha: 1) }) }
    static var card: Color { Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 42/255, green: 42/255, blue: 46/255, alpha: 1) : .white }) }
    static func projectColour(_ name: String) -> Color {
        let hex: String
        switch name.lowercased() {
        case "blue": hex = "0A84FF"; case "purple": hex = "8E5CF7"; case "green": hex = "34A853"
        case "orange": hex = "F08A24"; case "pink": hex = "E8508A"; case "teal": hex = "1AA6B7"
        case "yellow": hex = "D9B200"; case "gray", "grey", "graphite": hex = "8E8E93"
        default: hex = name.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return .secondary }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct NativeRCVRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DeckRowStyle().makeBody(configuration: configuration)
    }
}
