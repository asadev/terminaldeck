import Foundation
import TerminalDeckBackend
import TerminalDeckSimDirect

// Entry points only: ssh askpass, the packaging gate, the notify channel, the iOS Simulator direct screen, its
// accessibility and rotation, and the account vault shim. Each answers on its own and exits.
if CommandLine.arguments.contains(BackendServersSSHAskpass.dispatchArgument) {
    exit(BackendServersSSHAskpass.run(arguments: CommandLine.arguments,
        environment: ProcessInfo.processInfo.environment))
}

if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--native-capabilities" {
    print("{\"notifyChannel\":true,\"sshAskpass\":true,\"vaultSecurity\":true}")
    exit(0)
}

if CommandLine.arguments.count == 5, CommandLine.arguments[1] == BackendNodelessPackagingCommand.argument {
    let result = BackendNodelessPackagingCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
    FileHandle.standardOutput.write(Data(result.output.utf8)); exit(result.code)
}

if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--notify-channel" {
    do {
        try await BackendDeckCoreEventsChannelBridge.runStandardIO()
        exit(0)
    } catch {
        try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
}

// Finding 3 (22 Oct): one booted iOS Simulator's screen and input, straight from CoreSimulator, for the
// app's phone panel. Private frameworks stay in this process; the panel shows still pictures if it ends.
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--sim-direct" {
    exit(td_sim_direct_run(CommandLine.arguments[2], CommandLine.arguments[3]))
}

// 28 Oct: Terminal Deck's own device engine. What is on a simulator's screen (`tree [max]`, `point <x> <y>`, `front`,
// from Apple's accessibility translation) and turning it, each answered once and then this process exits.
if (4...6).contains(CommandLine.arguments.count), CommandLine.arguments[1] == "--sim-ax" {
    let arguments = CommandLine.arguments
    let first = arguments.count > 4 ? arguments[4] : "", second = arguments.count > 5 ? arguments[5] : ""
    exit(td_sim_ax_run(arguments[2], arguments[3], first, second))
}
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--sim-rotate" {
    exit(td_sim_rotate_run(CommandLine.arguments[2], CommandLine.arguments[3]))
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "vault:capabilities" {
    print(BackendAccountSecurityShimClient.capabilities)
    exit(0)
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "vault:security" {
    exit(BackendAccountSecurityShimClient.main(arguments: Array(CommandLine.arguments.dropFirst(2))))
}

FileHandle.standardError.write(Data("The native helper has no such entry point.\n".utf8))
exit(64)
