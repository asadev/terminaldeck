import Foundation
import TerminalDeckNativeCore

/// SRV2: durable, server-side recovery for interrupted app changes.
///
/// Every app change already holds the app's server lock (`<app>/.lock`). While
/// it does, the server keeps a small journal next to it (`<app>/.txn`): the
/// lock's token, a lease that each step renews, and the exact before-image of
/// every app file the change rewrote. A finished change deletes its journal
/// before releasing the lock. If the Mac (or the connection, or the server)
/// dies mid-change, the lock and journal stay behind; once the lease is stale
/// the recovery script — run by the next Mac action on that app, or by the
/// server's own 5-minute check with the Mac off — puts the files back, removes
/// containers that change created, re-applies the app's address from the
/// restored settings and releases the lock. A deploy holds the lock only to
/// start and to record its result; its server-side recipe runs in between
/// without it, and the next Mac action records (or, when it died, cleans up)
/// what it left (BackendAppsSRV2Deployer.settle). A journal an earlier version
/// marked "resume" is resumed instead of undone: `recipe.sh recover` cleans up
/// its deploy.
public enum BackendAppsSRV2TxnRecovery {
    public static let version = 2
    public static let scriptName = ".td-recover.sh"
    public static let defaultStaleMinutes = 30

    public static func scriptPath(stateRoot: String) -> String { stateRoot + "/" + scriptName }
    public static func journal(_ appDirectory: String) -> String { appDirectory + "/.txn" }

    /// Removes only the files a journal holds (token, paths, lease, resume and the
    /// numbered before-images), then its now-empty folders. Never a recursive delete.
    static func removeJournal(_ t: String) -> String {
        let q = BackendAppsRuntime.quote
        // Every path here is absolute, so no `--` is needed (and none of the lock-step words appear).
        return "if [ -d \(q(t)) ]; then for td_f in \(q(t + "/before"))/*; do if [ -f \"$td_f\" ] && [ ! -L \"$td_f\" ]; then case \"${td_f##*/}\" in *[!0-9]*) ;; *) rm -f \"$td_f\" ;; esac; fi; done; rm -f \(q(t + "/token")) \(q(t + "/paths")) \(q(t + "/lease")) \(q(t + "/resume")); rmdir \(q(t + "/before")) 2>/dev/null; rmdir \(q(t)); fi"
    }

    // Each journal step is its own small command whose first line names the step
    // and its paths (`# td-journal <step> '<path>' ...`): the shell ignores it,
    // and in-memory test servers can model the step exactly.

    /// Right after the lock is taken: a fresh journal owned by the lock token
    /// (any older journal is a finished change's leftover).
    static func acquireJournal(_ appDirectory: String) -> String {
        let q = BackendAppsRuntime.quote, t = journal(appDirectory), lock = appDirectory + "/.lock"
        return "# td-journal create \(q(lock)) \(q(t))\numask 077; test ! -L \(q(t)) || exit 45; test -f \(q(lock + "/owner")) || exit 45; \(removeJournal(t)); mkdir -- \(q(t)) && mkdir -- \(q(t + "/before")) && cat -- \(q(lock + "/owner")) > \(q(t + "/token")) && : > \(q(t + "/paths")) && touch \(q(t + "/lease")) || exit 45"
    }

    /// Before an app file is rewritten inside a change: keep its first
    /// before-image (or note that it didn't exist) and renew the lease.
    static func captureBeforeWrite(appDirectory: String, path: String, token: String) -> String {
        let q = BackendAppsRuntime.quote, t = journal(appDirectory)
        let relative = String(path.dropFirst(appDirectory.count + 1))
        return """
        # td-journal capture \(q(t)) \(q(path)) \(q(token))
        set -eu
        umask 077
        if [ -f \(q(t + "/token")) ] && [ ! -L \(q(t)) ] && [ "$(head -c 128 \(q(t + "/token")))" = \(q(token)) ]; then
          if ! grep -qxF -- \(q(relative)) \(q(t + "/paths")); then
            td_n=$(wc -l < \(q(t + "/paths")) | tr -d ' ')
            if [ -f \(q(path)) ] && [ ! -L \(q(path)) ]; then cp -p -- \(q(path)) \(q(t + "/before/"))"$td_n" || exit 45; fi
            printf '%s\\n' \(q(relative)) >> \(q(t + "/paths")) || exit 45
          fi
          touch \(q(t + "/lease"))
        fi
        """
    }

    /// After a change finished: its journal goes first, then the lock is released.
    static func finishJournal(_ appDirectory: String, token: String) -> String {
        let q = BackendAppsRuntime.quote, t = journal(appDirectory)
        return "# td-journal finish \(q(t)) \(q(token))\ntest ! -L \(q(t)) || exit 45; if [ -f \(q(t + "/token")) ] && [ \"$(head -c 128 \(q(t + "/token")))\" = \(q(token)) ]; then \(removeJournal(t)) || exit 45; fi; exit 0"
    }

    /// Writes (or refreshes) the server's recovery script when its version differs.
    public static func install(runtime: BackendAppsRuntime, serverID: String) async throws {
        let q = BackendAppsRuntime.quote, path = scriptPath(stateRoot: runtime.stateRoot)
        // The script travels inside the command, base64-encoded (no stdin, no secrets),
        // so its text never looks like a lock or file step to anything reading commands.
        let encoded = Data(script(stateRoot: runtime.stateRoot).utf8).base64EncodedString()
        let check = "# td-journal install \(q(path))\ntest ! -L \(q(runtime.stateRoot)) || exit 45; grep -qx '# td-recover v\(version)' \(q(path)) 2>/dev/null && exit 0; mkdir -p -- \(q(runtime.stateRoot)) && chmod 700 \(q(runtime.stateRoot)) && printf '%s' \(q(encoded)) | base64 -d > \(q(path + ".tmp")) && chmod 700 \(q(path + ".tmp")) && mv -f -- \(q(path + ".tmp")) \(q(path))"
        let result = try await runtime.run(serverID, check, timeoutMS: 20_000, maximumBytes: 4096)
        guard result.code == 0 else { throw NativeRPCError(code: "state-failed", message: "The server's recovery helper could not be saved.") }
    }

    /// Recovers stale interrupted changes (all apps, or one). Returns the apps recovered.
    @discardableResult
    public static func recover(runtime: BackendAppsRuntime, serverID: String, appID: String? = nil, staleMinutes: Int = defaultStaleMinutes) async throws -> [String] {
        if let appID { _ = try BackendAppsValidation.id(appID) }
        guard (0...1440).contains(staleMinutes) else { throw NativeRPCError.invalidArguments("Choose a lease between 0 and 1440 minutes.") }
        try await install(runtime: runtime, serverID: serverID)
        let q = BackendAppsRuntime.quote
        let result = try await runtime.run(serverID, "# td-journal recover \(q(runtime.stateRoot))\nsh \(q(scriptPath(stateRoot: runtime.stateRoot))) --stale-minutes \(staleMinutes)" + (appID.map { " " + q($0) } ?? ""), timeoutMS: 300_000, maximumBytes: 65_536)
        guard result.code == 0 else { throw NativeRPCError(code: "state-failed", message: "An interrupted change could not be recovered on the server. Its saved notes are kept; try again.") }
        return BackendAppsSRV2Recipe.result(result.stdout)["recovered"] ?? []
    }

    /// The recovery script (POSIX sh, root). Usage:
    /// `sh .td-recover.sh [--stale-minutes N] [app ...]`. It only acts on a lock
    /// whose journal (or, without one, the lock itself) is older than N minutes.
    public static func script(stateRoot: String) -> String {
        let q = BackendAppsRuntime.quote
        return """
        #!/bin/sh
        # td-recover v\(version)
        # Terminal Deck: undo (or resume) app changes that were interrupted. Generated; Terminal Deck rewrites this file.
        set -u
        umask 077
        LC_ALL=C; export LC_ALL
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH
        ROOT=\(q(stateRoot))
        STALE=\(defaultStaleMinutes)
        if [ "${1:-}" = --stale-minutes ]; then STALE=$2; shift 2; fi
        case "$STALE" in ''|*[!0-9]*) echo error=usage; exit 2 ;; esac
        [ -d "$ROOT" ] && [ ! -L "$ROOT" ] || { echo recovered-none=1; exit 0; }
        td_stale() { [ -n "$(find "$1" -prune -mmin +"$STALE" 2>/dev/null)" ] || [ "$STALE" = 0 ]; }
        # Only the journal's own files, then its empty folders (never a recursive delete).
        td_rmjournal() {
          [ -d "$1" ] && [ ! -L "$1" ] || return 0
          for f in "$1"/before/*; do
            if [ -f "$f" ] && [ ! -L "$f" ]; then case "${f##*/}" in *[!0-9]*) ;; *) rm -f -- "$f" ;; esac; fi
          done
          rm -f -- "$1/token" "$1/paths" "$1/lease" "$1/resume"
          rmdir -- "$1/before" 2>/dev/null
          rmdir -- "$1"
        }
        td_one() {
          app=$1
          case "$app" in ''|*[!a-z0-9-]*|-*) return 0 ;; esac
          d="$ROOT/$app"; L="$d/.lock"; T="$d/.txn"
          [ -d "$d" ] && [ ! -L "$d" ] || return 0
          [ ! -L "$L" ] && [ ! -L "$T" ] || { echo "skipped=$app"; return 0; }
          owner=''; token=''
          if [ -f "$L/owner" ] && [ ! -L "$L/owner" ]; then owner=$(head -c 128 "$L/owner"); fi
          if [ -f "$T/token" ] && [ ! -L "$T/token" ]; then token=$(head -c 128 "$T/token"); fi
          if [ ! -d "$L" ]; then
            # No change in progress: a journal here is a finished change's leftover.
            td_rmjournal "$T"
            return 0
          fi
          if [ -n "$token" ] && [ "$token" = "$owner" ]; then probe="$T/lease"; else probe="$L"; fi
          [ -e "$probe" ] || probe="$L"
          td_stale "$probe" || { echo "busy=$app"; return 0; }
          if [ -n "$token" ] && [ "$token" = "$owner" ]; then
            if [ -f "$T/resume" ] && [ ! -L "$T/resume" ]; then
              dep=$(head -c 200 "$T/resume")
              case "$dep" in ''|*[!a-z0-9-]*) ;; *) [ -f "$d/recipe.sh" ] && sh "$d/recipe.sh" recover "$dep" >/dev/null 2>&1 ;; esac
            else
              i=0
              while IFS= read -r rel; do
                case "$rel" in ''|/*|*..*|*[!A-Za-z0-9/_.-]*) echo "error=journal-$app"; return 1 ;; esac
                target="$d/$rel"
                if [ -L "$target" ]; then echo "error=journal-$app"; return 1; fi
                if [ -f "$T/before/$i" ]; then
                  cp -p -- "$T/before/$i" "$target.td-recover" && mv -f -- "$target.td-recover" "$target" || { echo "error=restore-$app"; return 1; }
                else
                  rm -f -- "$target" || { echo "error=restore-$app"; return 1; }
                fi
                i=$((i + 1))
              done < "$T/paths"
              if command -v docker >/dev/null 2>&1; then
                active=$(sed -n 's/.*"containerId"[[:space:]]*:[[:space:]]*"\\([a-f0-9]*\\)".*/\\1/p' "$d/state.json" 2>/dev/null | head -n 1)
                for c in $(docker ps -aq --no-trunc --filter "label=io.terminaldeck.transaction=$owner" --filter "label=io.terminaldeck.app=$app" 2>/dev/null); do
                  [ -n "$active" ] && [ "$c" = "$active" ] && continue
                  docker rm -f "$c" >/dev/null 2>&1 || echo "warning=container-$app"
                done
              fi
              if [ -f "$d/recipe.sh" ] && grep -q '"activeDeploymentId"' "$d/state.json" 2>/dev/null; then
                sh "$d/recipe.sh" apply-route >/dev/null 2>&1 || echo "warning=route-$app"
              fi
            fi
          fi
          # Release: the journal first, then the lock (never a lock we can't name).
          td_rmjournal "$T" || { echo "error=journal-$app"; return 1; }
          if [ -n "$owner" ]; then rm -f -- "$L/owner"; fi
          rmdir -- "$L" 2>/dev/null || { echo "error=lock-$app"; return 1; }
          echo "recovered=$app"
        }
        status=0
        if [ "$#" -gt 0 ]; then
          for app in "$@"; do td_one "$app" || status=1; done
        else
          for dir in "$ROOT"/*/; do
            [ -d "$dir" ] || continue
            app=${dir%/}; app=${app##*/}
            td_one "$app" || status=1
          done
        fi
        exit $status
        """
    }
}
