import Foundation
import TerminalDeckNativeCore

/// Shell is emitted only for the selected Linux server. Database dump commands stay owned by APE.
public enum BackendAppsDataBackupRunner {
    public static func script(directory: String, appID: String, prefix: String, network: String = "terminaldeck-apps") throws -> String {
        guard appID.range(of: #"\A[a-z][a-z0-9-]{0,47}\z"#, options: .regularExpression) != nil,
              prefix.range(of: #"\A[a-z][a-z0-9-]{0,47}\z"#, options: .regularExpression) != nil,
              directory.range(of: #"\A/var/lib/(?:terminaldeck/apps|[a-z][a-z0-9-]{0,47}-apps)/[a-z][a-z0-9-]{0,47}\z"#, options: .regularExpression) != nil,
              directory.hasSuffix("/" + appID), network.range(of: #"\A[a-z][a-z0-9_.-]{0,95}\z"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("The database backup folder is invalid.") }
        // Extract exactly the maintained dump switch, never a whole runner with weaker path/retention rules.
        let original = BackendAppsBackups.runner(directory: directory, appID: appID, prefix: prefix)
        guard let first = original.range(of: "        case \"$kind\" in") ?? original.range(of: "case \"$kind\" in"),
              let last = original.range(of: "test -s \"$work/data\"", range: first.upperBound..<original.endIndex) else {
            throw BackendAppsRuntime.unavailable("The database backup commands are unavailable in this build.")
        }
        let dump = try compatibleMongoAuthentication(String(original[first.lowerBound..<last.lowerBound]))
        let parent = String(directory[..<directory.lastIndex(of: "/")!])
        let parentCheck = parent == BackendAppsStore.root ? "test ! -L /var/lib/terminaldeck" : "true"
        return #"""
        #!/bin/sh
        set -eu
        umask 077
        dir=\#(BackendAppsRuntime.quote(directory))
        app=\#(BackendAppsRuntime.quote(appID))
        prefix=\#(BackendAppsRuntime.quote(prefix))
        expected_network=\#(BackendAppsRuntime.quote(network))
        \#(parentCheck)
        test ! -L \#(BackendAppsRuntime.quote(parent))
        test -d "$dir" && test ! -L "$dir"
        test -f "$dir/state.json" && test ! -L "$dir/state.json"
        test ! -L "$dir/.lock" && test ! -L "$dir/backups"
        test ! -L "$dir/backup-policy.json" && test ! -L "$dir/.backup-s3-credentials"
        test ! -e "$dir/data-restore-intent.json" || exit 73
        test ! -L "$dir/data-restore-intent.json" || exit 73
        test ! -e "$dir/data-backup-policy-recovery.json" && test ! -L "$dir/data-backup-policy-recovery.json" || exit 73
        test "$(stat -c %u "$dir")" = "$(id -u)"
        test "$(stat -c %a "$dir")" = 700
        owned_lock=0
        work=
        token=
        cleanup() {
          result=$?
          if [ -n "$work" ] && [ -d "$work" ] && [ ! -L "$work" ]; then rm -rf -- "$work"; fi
          if [ "$owned_lock" = 1 ] && [ ! -L "$dir/.lock" ] && [ -f "$dir/.lock/owner" ] && [ ! -L "$dir/.lock/owner" ]; then
            if [ "$(cat "$dir/.lock/owner")" = "$token" ]; then rm -- "$dir/.lock/owner"; rmdir "$dir/.lock"; fi
          fi
          exit "$result"
        }
        trap cleanup EXIT
        trap 'exit 130' HUP INT TERM
        if [ "${1:-}" = --already-locked ]; then
          test "$#" = 2 && test -d "$dir/.lock" && test -f "$dir/.lock/owner" && test ! -L "$dir/.lock/owner"
          id="$2"
        else
          test "$#" = 0
          test -f "$dir/backup-policy.json"
          test "$(jq -er '.enabled | type' "$dir/backup-policy.json")" = boolean
          test "$(jq -r '.enabled' "$dir/backup-policy.json")" = true || exit 0
          mkdir "$dir/.lock" 2>/dev/null || exit 75
          owned_lock=1
          token=$(cat /proc/sys/kernel/random/uuid)
          printf '%s' "$token" > "$dir/.lock/owner"
          id="$prefix-$(date +%s)-$token"
        fi
        case "$id" in *[!a-zA-Z0-9_.-]*|''|.|..) exit 65;; esac
        test "${#id}" -le 96
        case "$id" in "$prefix-"*) ;; *) exit 65;; esac
        jq -e --arg app "$app" '.id == $app and (.kind == "postgres" or .kind == "mysql" or .kind == "redis" or .kind == "mongodb") and (.database.containerId | test("^[a-f0-9]{12,64}$")) and (.database.imageId | test("^sha256:[a-f0-9]{64}$")) and (.database.volumeName | test("^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,191}$"))' "$dir/state.json" > /dev/null
        container=$(jq -er '.database.containerId' "$dir/state.json")
        kind=$(jq -er '.kind' "$dir/state.json")
        image=$(jq -er '.database.imageId' "$dir/state.json")
        software=$(jq -er '.database.image' "$dir/state.json")
        volume=$(jq -er '.database.volumeName' "$dir/state.json")
        network=$(jq -er '.database.network' "$dir/state.json")
        data_path=$(jq -er '.database.dataPath' "$dir/state.json")
        test "$network" = "$expected_network"
        case "$volume" in "$prefix-"*) ;; *) exit 65;; esac
        case "$kind:$data_path" in postgres:/var/lib/postgresql/data|mysql:/var/lib/mysql|redis:/data|mongodb:/data/db) ;; *) exit 65;; esac
        mkdir -p -- "$dir/backups"
        chmod 700 -- "$dir/backups"
        candidate="$dir/backups/.partial-$id"
        test ! -e "$candidate" && test ! -L "$candidate"
        mkdir -- "$candidate"
        work="$candidate"
        chmod 700 -- "$work"
        docker inspect "$container" > "$work/inspect.json" 2>/dev/null
        jq -e --arg app "$app" --arg container "$container" --arg image "$image" --arg volume "$volume" --arg network "$network" --arg path "$data_path" --arg kind "$kind" 'length == 1 and (.[0] |
          .Id == $container and .Image == $image and .Config.Labels["io.terminaldeck.app"] == $app and .Config.Labels["io.terminaldeck.managed"] == "true" and .State.Running == true and
          .HostConfig.NetworkMode == $network and (.HostConfig.Privileged != true) and (.HostConfig.PublishAllPorts != true) and
          ((.HostConfig.PortBindings // {}) | length == 0) and ((.NetworkSettings.Ports // {}) | all(. == null or length == 0)) and
          ((.HostConfig.Binds // []) | length == 0) and ((.HostConfig.Devices // []) | length == 0) and ((.HostConfig.DeviceRequests // []) | length == 0) and ((.HostConfig.VolumesFrom // []) | length == 0) and ((.HostConfig.CapAdd // []) | length == 0) and
          ((.HostConfig.PidMode // "") == "") and ((.HostConfig.IpcMode // "private") == "private" or (.HostConfig.IpcMode // "") == "") and
          ((.HostConfig.UTSMode // "") != "host") and ((.HostConfig.UsernsMode // "") != "host") and ((.HostConfig.SecurityOpt // []) | all(contains("unconfined") | not)) and
          ([.Mounts[] | select(.Type == "volume" and .Name == $volume and .Destination == $path and .RW == true)] | length == 1) and
          ([.Mounts[] | select(.Type != "volume" or .Name != $volume or .Destination != $path or .RW != true)] | length <= 1 and all($kind == "mongodb" and .Type == "tmpfs" and .Destination == "/data/configdb" and .RW == true)) and
          (.NetworkSettings.Networks | keys == [$network]))' "$work/inspect.json" >/dev/null
        docker volume inspect "$volume" > "$work/volume.json" 2>/dev/null
        jq -e --arg app "$app" --arg volume "$volume" 'length == 1 and (.[0] | .Name == $volume and .Driver == "local" and .Labels["io.terminaldeck.app"] == $app and .Labels["io.terminaldeck.managed"] == "true" and ((.Options // {}) | length == 0))' "$work/volume.json" > /dev/null
        rm -- "$work/inspect.json" "$work/volume.json"
        \#(dump)
        test -s "$work/data" && test ! -L "$work/data"
        sum=$(sha256sum "$work/data" | cut -d ' ' -f 1)
        bytes=$(wc -c < "$work/data" | tr -d ' ')
        uploaded=false
        retention=7
        if [ -f "$dir/backup-policy.json" ]; then
          jq -e '(.enabled | type) == "boolean" and (if .retention != null then (.retention | type == "number" and . >= 1 and . <= 365 and floor == .) else (.enabled == false) end)' "$dir/backup-policy.json" >/dev/null
          retention=$(jq -er '.retention // 7' "$dir/backup-policy.json")
            if jq -e '.upload != null' "$dir/backup-policy.json" >/dev/null; then
              jq -e '.upload | (.endpoint | test("^https://[^[:space:]@]+$")) and (.bucket | test("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$")) and (.prefix | test("^([A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*)?$")) and (has("accessKey") | not) and (has("secretKey") | not)' "$dir/backup-policy.json" >/dev/null
              \#(BackendAppsDataS3Upload.uploadAndVerifyScript)
            fi
        fi
        jq -n --arg id "$id" --arg app "$app" --arg kind "$kind" --arg sum "$sum" --arg image "$image" --arg software "$software" --argjson bytes "$bytes" --argjson created "$(date +%s)000" --argjson uploaded "$uploaded" '{id:$id,appId:$app,kind:$kind,sha256:$sum,imageId:$image,image:$software,bytes:$bytes,createdAt:$created,verified:true,uploaded:$uploaded}' > "$work/manifest.json"
        test "$(sha256sum "$work/data" | cut -d ' ' -f 1)" = "$sum"
        test "$(wc -c < "$work/data" | tr -d ' ')" = "$bytes"
        chmod 600 -- "$work/data" "$work/manifest.json"
        sync -f "$work/data"
        sync -f "$work/manifest.json"
        sync -f "$work"
        test ! -e "$dir/backups/$id" && test ! -L "$dir/backups/$id"
        mv -- "$work" "$dir/backups/$id"
        work=
        sync -f "$dir/backups"
        # Retention starts only after verified durable publication. Each manifest must name its own folder.
        catalog="$dir/backups/.retention-$id"
        test ! -e "$catalog" && test ! -L "$catalog"
        test ! -e "$catalog.ids" && test ! -L "$catalog.ids"
        : > "$catalog"
        for folder in "$dir/backups"/*; do
          [ -d "$folder" ] && [ ! -L "$folder" ] || continue
          old=${folder##*/}
          case "$old" in "$prefix-"*) ;; *) continue;; esac
          case "$old" in *[!a-zA-Z0-9_.-]*|''|.|..) continue;; esac
          [ -f "$folder/manifest.json" ] && [ ! -L "$folder/manifest.json" ] && [ -f "$folder/data" ] && [ ! -L "$folder/data" ] || continue
          jq -e --arg id "$old" --arg app "$app" --arg kind "$kind" '.id == $id and .appId == $app and .kind == $kind and .verified == true and (.createdAt | type == "number" and . > 0 and floor == .) and (.sha256 | test("^[a-f0-9]{64}$")) and (.bytes | type == "number" and . > 0 and floor == .)' "$folder/manifest.json" > /dev/null || continue
          jq -c '{id,createdAt}' "$folder/manifest.json" >> "$catalog"
        done
        jq -s -r --arg current "$id" --argjson keep "$retention" 'sort_by(.createdAt, .id) | reverse | .[$keep:][] | select(.id != $current) | .id' "$catalog" > "$catalog.ids"
        while IFS= read -r old; do
          case "$old" in "$prefix-"*) ;; *) continue;; esac
          case "$old" in *[!a-zA-Z0-9_.-]*|''|.|..) continue;; esac
          test "$old" != "$id" || continue
          test -d "$dir/backups/$old" && test ! -L "$dir/backups/$old" || continue
          test -f "$dir/backups/$old/manifest.json" && test ! -L "$dir/backups/$old/manifest.json" || continue
          jq -e --arg id "$old" --arg app "$app" '.id == $id and .appId == $app and .verified == true' "$dir/backups/$old/manifest.json" > /dev/null || continue
          rm -rf -- "$dir/backups/$old"
        done < "$catalog.ids"
        rm -- "$catalog" "$catalog.ids"
        sync -f "$dir/backups"
        cat -- "$dir/backups/$id/manifest.json"
        """#
    }

    /// MongoDB's db.auth manual documents numeric 1; mongosh's Database.auth returns {ok: number}.
    /// Normalize only the two inherited auth predicates. Preserve the maintained dump/lock/unlock body.
    /// Sources: mongodb.com/docs/v8.0/reference/method/db.auth/ and mongosh shell-api/src/database.ts.
    static func compatibleMongoAuthentication(_ commands: String) throws -> String {
        let old = #"if(db.getSiblingDB("admin").auth(a.MONGO_INITDB_ROOT_USERNAME,a.MONGO_INITDB_ROOT_PASSWORD)!==1) quit(1);"#
        let accepted = #"const r=db.getSiblingDB("admin").auth(a.MONGO_INITDB_ROOT_USERNAME,a.MONGO_INITDB_ROOT_PASSWORD); if(!(r===1||(r&&r.ok===1)))quit(1);"#
        let oldCount = commands.components(separatedBy: old).count - 1
        let acceptedCount = commands.components(separatedBy: accepted).count - 1
        guard oldCount + acceptedCount == 2 else {
            throw BackendAppsRuntime.unavailable("The MongoDB backup sign-in commands need a compatibility check in this build.")
        }
        return commands.replacingOccurrences(of: old, with: accepted)
    }
}
