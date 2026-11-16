import Foundation
import TerminalDeckNativeCore

/// Lane L3 (Cloud folder, artifacts): "no Mac ever receives a record it does not understand", by the memory store's own
/// mechanism (one rule, phase 2), reused for other kinds of record. Each Mac of this build announces, per feature, one
/// shared memory setting `onerule.understands.<feature>.<device id>` = "v<format>:<service ms>". The key carries the
/// memory one rule's travelling prefix, so it travels in I05 on this build AND on the build installed this morning
/// (both have that prefix; an older build keeps it as history only, `isMachineLocal`). Memory's own check reads only
/// `onerule.understands.<device id>`, so a feature key never counts for memory.
///
/// A feature sends only while the account's Mac list is known, holds this Mac, and EVERY Mac in it renewed its
/// announcement of this format within 3 days (a Mac rolled back to an older build stops renewing it; within 3 days the
/// feature stops sending by itself, and nothing an older build cannot read is ever sent to it meanwhile, because it
/// never announced in the first place).
extension DeckMemoryStore {
    static func featureKey(_ feature: String, device: String) -> String {
        understandsPrefix + feature + "." + device.lowercased()
    }
    /// Fresh = this format or newer, renewed within the last 3 days, not more than an hour ahead.
    static func featureFresh(_ raw: String?, format: Int, now: Int64) -> Bool {
        guard let value = parseUnderstands(raw), value.format >= format else { return false }
        return value.at <= now + understandsAheadAllowed && now - value.at <= understandsFreshFor
    }
    /// This Mac understands `feature` records of `format`, as of now. Renewed after 12 hours; waits while the service
    /// clock or this Mac's device id is not known yet. Returns true when a setting was written.
    @discardableResult
    public func cloudFeatureAnnounce(_ feature: String, format: Int, force: Bool = false) throws -> Bool {
        guard cloudMemoryEnabled, !feature.isEmpty, !feature.contains("."), format > 0 else { return false }
        guard let id = cloudDeviceId, UUID(uuidString: id) != nil, let now = DeckMemoryCloudClocks.shared.now(for: self), now > 0 else {
            // Lead's decision 11: the service clock (or this Mac's id) is not known yet. The maintenance step writes it
            // with this same writer as soon as it is (`cloudRetryPendingAnnouncements`), within minutes, not 12 hours later.
            try? db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text(Self.featurePendingPrefix + feature), .text(String(format))])
            return false
        }
        try? db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text(Self.featurePendingPrefix + feature)])
        let key = Self.featureKey(feature, device: id)
        if !force, let held = Self.parseUnderstands(try setting(key, owner: nil)), held.format == format, held.at <= now, now - held.at < Self.understandsRenewAfter {
            return false
        }
        try setSetting(Self.understandsValue(format: format, at: now), key: key, owner: nil)
        post(.settings, nil, key)
        return true
    }
    static let featurePendingPrefix = "featureAnnounce:pending:"
    /// Announcements that waited for the clock: written now (forced, as a launch announcement is) when it is known.
    func cloudRetryPendingAnnouncements() throws {
        guard cloudMemoryEnabled else { return }
        let rows = try db.rows("SELECT key,value FROM cloud_memory_control WHERE substr(key,1,?)=?",
                               [.int(Int64(Self.featurePendingPrefix.count)), .text(Self.featurePendingPrefix)])
        for row in rows {
            let feature = String(row.text(0).dropFirst(Self.featurePendingPrefix.count))
            guard let format = row.string(1).flatMap(Int.init) else {
                try db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text(row.text(0))]); continue
            }
            _ = try cloudFeatureAnnounce(feature, format: format, force: true)
        }
    }
    /// The account's Mac list is known, holds this Mac, and every Mac in it has a fresh announcement of `feature` at
    /// `format` or newer. false whenever anything is unknown (signed out, list not read, clock not known, memory off).
    public func cloudFeatureEveryMacUnderstands(_ feature: String, format: Int) -> Bool {
        guard cloudMemoryEnabled, let macs = cloudAccountMacs, !macs.isEmpty, let me = cloudDeviceId, macs.contains(me),
              let now = DeckMemoryCloudClocks.shared.now(for: self) else { return false }
        for id in macs where !Self.featureFresh((try? setting(Self.featureKey(feature, device: id), owner: nil)) ?? nil, format: format, now: now) {
            return false
        }
        return true
    }
    /// Project secret files (review 14 Nov, F11): the marks travel with Cloud memory, so a feature's page names this
    /// when it is off here instead of "waits for your devices".
    public func cloudMemoryIsOn() -> Bool { cloudMemoryEnabled }
    /// Review 14 Nov (point 8): the device ids of the account's Macs that have no fresh announcement of `feature` (the
    /// Cloud folder's page line names them). Empty when every Mac understands or nothing is known yet.
    public func cloudFeatureMacsWaiting(_ feature: String, format: Int) -> [String] {
        guard cloudMemoryEnabled, let macs = cloudAccountMacs, let now = DeckMemoryCloudClocks.shared.now(for: self) else { return [] }
        return macs.filter { !Self.featureFresh((try? setting(Self.featureKey(feature, device: $0), owner: nil)) ?? nil, format: format, now: now) }
    }
}
