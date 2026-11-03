import Foundation
import TerminalDeckNativeCore

/// #27 (Asad, 3 Nov): "for my device, when you choose my device, it should have everything ... all the accounts ...
/// same as you own it". The trust store already lets the person's own device ("mine") reach every login and session
/// (BackendRemoteTrustGrants); this brings the devices paired before 0.21.0 to the same place once: any login, session
/// or folder list kept for a device of the person's own is removed, and one that never had a level chosen (it could do
/// nothing) gets Full control. A level the person chose is never changed (Decker, review S-D3: someone who lowered a
/// device to Look meant it), before or after this runs.
///
/// It runs once per data folder (a marker file in the trust folder). Guests are never touched.
extension BackendRemoteTrustStore {
    public static let ownDevicesFullMarker = "own-devices-full.json"
    public static let ownDeviceReachesAll = "This is your own device: it already reaches every folder, login and session on this Mac, as you do here. There is nothing to limit."

    /// A folder, login or session list for the person's own device would narrow nothing (BackendRemoteTrustGrants), so
    /// a change to one (the Remote lists, the remote.manage tool) is refused in plain words, never "saved".
    func refuseOwnDeviceLimit(_ deviceID: String) throws {
        guard deviceID.isEmpty || kindOf(deviceID) != .mine else {
            throw NativeRPCError(code: "own-device", message: Self.ownDeviceReachesAll)
        }
    }

    public struct OwnDevicesFullOutcome: Equatable, Sendable {
        public let own: Int, raised: Int, unlimited: Int
        public var line: String {
            "[remote] own devices get everything (one time, 0.21.0): \(own) of yours; \(raised) without a level set to Full control; "
                + "\(unlimited) had a login, session or folder list removed"
        }
    }

    /// Nil when it already ran for this data folder. Writes the levels and lists first, then the marker, so a failure
    /// part-way runs it again on the next start.
    @discardableResult
    public func upgradeOwnDevicesToFull(report: @Sendable (String) -> Void) throws -> OwnDevicesFullOutcome? {
        try requireOpen()
        let marker = directory.appendingPathComponent(Self.ownDevicesFullMarker)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return nil }
        let own = devices.filter { $0.approved && !$0.revoked && kinds[$0.id]?.kind == .mine }.map(\.id).sorted()
        var levels = phoneAccessLevels, raised = 0
        // Only a device with no level at all (it could do nothing): a level the person chose stays as chosen.
        for id in own where levels[id] == nil { levels[id] = .full; raised += 1 }
        if raised > 0 { try writePhoneAccessLevels(levels) }
        var unlimited = 0
        for id in own {
            let logins = try remoteServeForgetAccountGrants(id), sessions = try remoteServeForgetSessionGrants(id)
            let folders = try remoteServeForgetFolderGrants(id)
            if logins || sessions || folders { unlimited += 1 }
        }
        try BackendRemoteTrustStorage.write(.object([.init("version", .number(1)), .init("doneAt", .number(clock())),
            .init("ownDevices", .number(Double(own.count))), .init("raised", .number(Double(raised))),
            .init("unlimited", .number(Double(unlimited)))]), file: marker)
        let outcome = OwnDevicesFullOutcome(own: own.count, raised: raised, unlimited: unlimited)
        report(outcome.line)
        if raised > 0 || unlimited > 0 { onChanged?() }
        return outcome
    }
}
