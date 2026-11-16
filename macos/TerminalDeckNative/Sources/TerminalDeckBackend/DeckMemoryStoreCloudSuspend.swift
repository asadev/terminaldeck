import Foundation
import TerminalDeckNativeCore

extension DeckMemoryStore {
    /// Sign-out or a closed gate returns memory writes to their no-account behaviour (AM8) in one step:
    /// TEMP capture triggers dropped, the account's database detached, the launch pointer removed, flags cleared.
    /// Safe to call at any time, also when nothing was ever attached this run. Retained Cloud data stays in the
    /// account's own folder; the account is marked "interrupted", so its next activation runs the reconcile.
    public func cloudSuspendCapture() throws {
        var state = cloudStateRoot
        if state == nil, let pointer = cloudCapturePointer, let data = try? Data(contentsOf: pointer),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: String], let path = saved["stateRoot"] {
            state = URL(fileURLWithPath: path, isDirectory: true)
        }
        cloudMemoryEnabled = false
        cloudCaptureLost = false
        cloudEnabledRows = nil
        cloudReconcileList = nil
        _ = db.takeCaptureLoss()
        cloudMemorySnapshots = [:]
        cloudCloseSnapshotReaders()
        var failure: (any Error)?
        do { try cloudDropCaptureTriggers() } catch { failure = error }
        // Leftovers from an earlier build in main are removed too, so sign-out always ends with zero Cloud triggers.
        if let names = try? db.rows("SELECT name FROM main.sqlite_master WHERE type='trigger' AND name LIKE 'cloud_memory_%'").map({ $0.text(0) }) {
            for name in names where Self.cloudSafeIdentifier(name) { try? db.exec("DROP TRIGGER IF EXISTS main.\(name)") }
        }
        if (try? cloudAttached()) == true {
            do { try db.exec("DETACH DATABASE cloud") } catch { failure = failure ?? error }
        }
        cloudStateRoot = nil
        if let pointer = cloudCapturePointer, FileManager.default.fileExists(atPath: pointer.path) {
            do { try FileManager.default.removeItem(at: pointer) } catch { failure = failure ?? error }
        }
        if let state { Self.cloudMarkGap(stateRoot: state) }
        if let failure { throw failure }
    }
}
