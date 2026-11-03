import Foundation

/// 28 Oct (CPU, Asad: every terminal slow): which app events make the team-chat list read itself again. It listened
/// to every session's status changes (several per turn of every working session, his phone's typing included) and
/// re-listed every team chat each time. A status change matters to that list only for one of its own team chats (a
/// job starting, finishing); a session appearing or going and a task changing still re-read it.
public enum TeamChatListRefresh {
    public static func wanted(event: String, sessionID: String?, knownJobs: Set<String>) -> Bool {
        guard event == "session:status" else { return true }
        guard let sessionID else { return false }
        return knownJobs.contains(sessionID)
    }
}
