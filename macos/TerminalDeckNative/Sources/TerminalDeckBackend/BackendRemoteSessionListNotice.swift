import Foundation

/// 28 Oct (bug C, Asad: Commander came back on the Mac at 03:43 and his phone listed it only about half an hour
/// later). A paired phone lists exactly the sessions the Mac last sent it, and the Mac sent the list again only when a
/// session ended, was renamed or was started from a phone: a session started or reopened on the Mac itself (by hand,
/// a restored or held tab, the session helper's restart, an account switch that replaces the session) never reached
/// the phone until something else happened. Every session that appears on the Mac now sends the list at once.
/// Ends (exit, removal) are sent by the remote host itself; a status change is not a list change.
public enum BackendRemoteSessionListNotice {
    public static func announces(_ event: BackendSessionLifecycleEvent) -> Bool {
        switch event {
        case .created, .replaced: return true
        case .accountChanged, .switchPending, .switchFailed, .held, .restored, .status, .process: return false
        }
    }
}
