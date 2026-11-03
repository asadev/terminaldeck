import Foundation

/// Coming back after a crash (Asad, 1 Nov, item 57: "the whole Terminal Deck app on the Mac quits; I need to go to the
/// Mac and turn it on again"). A small watcher started by the app waits for the app to end; it opens the app again,
/// in the background, ONLY when all of these hold:
/// - the app did not end the orderly way (Quit, logout, an update, a scripted quit all leave the clean mark);
/// - macOS wrote a crash report for THIS copy of the app after it started (a Force Quit, `kill -9`, a jetsam or a
///   power cut write none, so the person's own Force Quit is respected);
/// - it has not already done so 3 times in the last 10 minutes (a crash at launch never loops);
/// - no copy of the app is running by then (the person may have opened it already).
/// Only the installed app in /Applications watches; development, scratch and test copies never do.
public enum CrashRelaunchPolicy {
    public static let mostRelaunches = 3
    public static let window: TimeInterval = 600

    public static func watches(bundlePath: String, standalone: Bool, testSwitches: Bool) -> Bool {
        standalone && !testSwitches && bundlePath.hasPrefix("/Applications/") && bundlePath.hasSuffix(".app")
    }

    /// The decision once the app has ended (the watcher script does the same in shell).
    public static func reopen(cleanMark: Bool, crashReportForThisCopy: Bool, recentRelaunches: [TimeInterval], now: TimeInterval,
                              appRunning: Bool) -> Bool {
        guard !cleanMark, crashReportForThisCopy, !appRunning else { return false }
        return recentRelaunches.filter { now - $0 < window }.count < mostRelaunches
    }

    /// The watcher, as a /bin/sh script: $1 the app's pid, $2 the app's bundle path, $3 the clean mark, $4 the start
    /// mark (crash reports newer than it count), $5 the file of recent relaunch times, $6 the opener (/usr/bin/open; a
    /// test passes its own), $7 how many times to look for the crash report, 2 s apart (30).
    public static let script = #"""
    pid="$1"; app="$2"; clean="$3"; start="$4"; hist="$5"; opener="${6:-/usr/bin/open}"; looks="${7:-30}"
    # Crash reports write the path with escaped slashes: \/Applications\/…
    want=$(printf '%s' "$app/Contents/MacOS/TerminalDeckNative" | sed 's#/#\\/#g')
    while kill -0 "$pid" 2>/dev/null; do sleep 2; done
    [ -f "$clean" ] && exit 0
    found=""; i=0
    while [ $i -lt "$looks" ]; do
      for f in $(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name 'TerminalDeckNative-*.ips' -newer "$start" 2>/dev/null); do
        grep -qF "$want" "$f" 2>/dev/null && found="$f"
      done
      [ -n "$found" ] && break
      sleep 2; i=$((i+1))
    done
    [ -z "$found" ] && exit 0
    now=$(date +%s)
    recent=$(awk -v n="$now" '$1 > n - 600' "$hist" 2>/dev/null | wc -l | tr -d ' ')
    [ "${recent:-0}" -ge 3 ] && exit 0
    pgrep -f "$app/Contents/MacOS/TerminalDeckNative" >/dev/null 2>&1 && exit 0
    echo "$now" >> "$hist"
    exec "$opener" -g -a "$app"
    """#

    /// What the run folder says about the run before this one, read at launch before this run clears it (2 Nov
    /// restarts audit: engine.log had no line saying how the last run ended or who opened this one). `markNames` are
    /// the file names in the run folder; a `started-<pid>` with no `clean-<pid>` is a run that did not end the orderly way.
    public static func previousEnd(markNames: [String], currentPID: Int32, relaunchTimes: [TimeInterval], now: TimeInterval) -> String {
        let names = Set(markNames)
        let earlier = markNames.compactMap { $0.hasPrefix("started-") ? Int32($0.dropFirst("started-".count)) : nil }
            .filter { $0 != currentPID }.sorted()
        var words: [String] = []
        if earlier.isEmpty { words.append("no record of the previous run") }
        for pid in earlier {
            words.append(names.contains("clean-\(pid)")
                ? "the previous run (pid \(pid)) ended the orderly way (Quit, an update or a scripted quit)"
                : "the previous run (pid \(pid)) did NOT end the orderly way (a crash leaves a TerminalDeckNative-*.ips; none means Force Quit, a kill, memory or power)")
        }
        // The watcher writes the time just before it opens the app (`open -g`).
        if let last = relaunchTimes.max(), now - last >= 0, now - last < 120 { words.append("opened again by the crash watcher") }
        return words.joined(separator: "; ")
    }
}
