import Foundation
import Darwin

extension BackendHOSTOrphanKernel {
    public static var live: Self {
        .init(inspect: { try BackendHOSTOrphanDarwin.inspect($0) },
              children: { try BackendHOSTOrphanDarwin.children($0) },
              signal: { try BackendHOSTOrphanDarwin.signal($0, signal: $1) },
              watch: { pid, changed in
                  let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: [.fork, .exec, .exit], queue: .global(qos: .utility))
                  source.setEventHandler(handler: changed); source.resume()
                  return BackendHOSTOrphanWatch { source.cancel() }
              })
    }
}

enum BackendHOSTOrphanDarwin {
    static func bsd(_ pid: Int32) throws -> proc_bsdinfo? {
        guard pid > 1 else { throw BackendHOSTOrphanFailure.invalid("A recovery identity cannot name pid 0 or 1.") }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        if read == 0, errno == ESRCH || errno == ENOENT { return nil }
        guard read == size else { throw BackendHOSTOrphanFailure.kernel("read process identity", errno) }
        guard info.pbi_pid == UInt32(pid) else { throw BackendHOSTOrphanFailure.invalid("The kernel returned another process identity.") }
        return info
    }
    static func inspect(_ pid: Int32) throws -> BackendHOSTOrphanIdentity? {
        guard let before = try bsd(pid) else { return nil }
        // HOSTLOST (9 Oct): a recorded PID now held by ANOTHER user's process is, by birth identity,
        // not the recorded process (whose uid was ours). Report it as what it is — a different
        // process — so recovery drops the record instead of refusing to finish forever.
        guard before.pbi_uid == geteuid() else { return identity(before, words: [], zombie: false) }
        if before.pbi_status == UInt32(SZOMB) {
            return identity(before, words: [], zombie: true)
        }
        var port: mach_port_name_t = 0
        let named = task_name_for_pid(mach_task_self_, pid, &port)
        // No audit port (a hardened or system process of this user): its birth identity still decides
        // whether it is the recorded process; without audit words it is never signalled.
        guard named == KERN_SUCCESS else { return identity(before, words: [], zombie: false) }
        defer { mach_port_deallocate(mach_task_self_, port) }
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(port, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count) }
        }
        guard result == KERN_SUCCESS, count == 8 else { throw BackendHOSTOrphanFailure.kernel("read the audit process identity", result) }
        let words = withUnsafeBytes(of: &token) { Array($0.bindMemory(to: UInt32.self)) }
        guard let after = try bsd(pid) else { return nil }
        guard before.pbi_start_tvsec == after.pbi_start_tvsec, before.pbi_start_tvusec == after.pbi_start_tvusec,
              before.pbi_uid == after.pbi_uid, words.count == 8, words[5] == UInt32(pid), words[1] == after.pbi_uid else {
            throw BackendHOSTOrphanFailure.invalid("The process changed while its kernel identity was being read.")
        }
        return identity(after, words: words, zombie: after.pbi_status == UInt32(SZOMB))
    }
    static func identity(_ info: proc_bsdinfo, words: [UInt32], zombie: Bool) -> BackendHOSTOrphanIdentity {
        .init(pid: Int32(info.pbi_pid), parentPID: Int32(info.pbi_ppid), groupID: Int32(info.pbi_pgid), uid: info.pbi_uid,
              startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec,
              auditWords: words, zombie: zombie, stopped: info.pbi_status == UInt32(SSTOP))
    }
    static func children(_ pid: Int32) throws -> [Int32] {
        // A fixed bound avoids silently treating a truncated child table as a complete tree.
        var values = [Int32](repeating: 0, count: 4_097)
        let count = values.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        guard count >= 0 else { throw BackendHOSTOrphanFailure.kernel("read owned descendants", errno) }
        // proc_listchildpids converts proc_listpids' byte count into a PID count.
        let used = Int(count)
        guard used < values.count else { throw BackendHOSTOrphanFailure.budget }
        return Array(values.prefix(used)).filter { $0 > 1 }
    }
    static func signal(_ expected: BackendHOSTOrphanIdentity, signal: Int32) throws -> Bool {
        guard [SIGSTOP, SIGCONT, SIGKILL].contains(signal), expected.valid else {
            throw BackendHOSTOrphanFailure.invalid("Invalid identity-bound recovery signal.")
        }
        guard let actual = try inspect(expected.pid), actual.sameProcess(as: expected), !actual.zombie,
              actual.auditWords.count == 8 else { return false } // never signal what cannot be audited
        var token = audit_token_t()
        withUnsafeMutableBytes(of: &token) { bytes in
            let words = bytes.bindMemory(to: UInt32.self)
            for index in 0..<8 { words[index] = actual.auditWords[index] }
        }
        // XNU verifies pidversion and holds the exact proc reference for delivery.
        // A process exiting/reusing its PID after inspect cannot redirect this signal.
        let result = proc_signal_with_audittoken(&token, signal)
        guard result == 0 else {
            if result == ESRCH { return false }
            throw BackendHOSTOrphanFailure.kernel("signal the verified owned process", result)
        }
        return true
    }
}
