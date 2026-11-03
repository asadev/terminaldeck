import Foundation
import TerminalDeckNativeCore

/// The server performs one compensated policy transaction while BackendAppsStore holds the app lock.
public enum BackendAppsDataBackupSchedule {
    public static func unit(directory: String, appID: String, prefix: String, policy: BackendAppsDataBackupPolicy) throws -> (name: String, service: String, timer: String) {
        guard appID.range(of: #"\A[a-z][a-z0-9-]{0,47}\z"#, options: .regularExpression) != nil,
              prefix.range(of: #"\A[a-z][a-z0-9-]{0,47}\z"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("The database backup timer identity is invalid.") }
        let name = prefix + "-" + appID + "-backup"
        guard name.utf8.count <= 160, directory.hasSuffix("/" + appID),
              directory.range(of: #"\A/var/lib/(?:terminaldeck/apps|[a-z][a-z0-9-]{0,47}-apps)/[a-z][a-z0-9-]{0,47}\z"#, options: .regularExpression) != nil else {
            throw NativeRPCError.invalidArguments("The database backup timer is invalid.")
        }
        let marker = "# Terminal Deck managed backup for " + appID
        let service = """
        \(marker)
        [Unit]
        Description=Terminal Deck database backup
        After=docker.service
        [Service]
        Type=oneshot
        User=root
        UMask=0077
        ExecStart=/bin/sh \(directory)/backup-run.sh
        StandardOutput=null
        StandardError=null
        TimeoutStartSec=3600

        """
        let timer = """
        \(marker)
        [Unit]
        Description=Terminal Deck scheduled database backup
        [Timer]
        OnCalendar=\(policy.schedule ?? "daily")
        Persistent=true
        Unit=\(name).service
        [Install]
        WantedBy=timers.target

        """
        return (name, service, timer)
    }

    public static func payload(directory: String, appID: String, prefix: String, network: String = "terminaldeck-apps", policy: BackendAppsDataBackupPolicy, now: Double) throws -> Data {
        guard now.isFinite, now > 0 else { throw NativeRPCError.invalidArguments("The backup policy time is invalid.") }
        let units = try unit(directory: directory, appID: appID, prefix: prefix, policy: policy)
        let runner = policy.enabled ? try BackendAppsDataBackupRunner.script(directory: directory, appID: appID, prefix: prefix, network: network) : ""
        return try BackendAppsValidation.object([
            ("policy", policy.publicValue), ("updatedAt", .number(now)),
            ("runner", .string(runner)), ("service", .string(units.service)), ("timer", .string(units.timer)),
            ("credentials", policy.upload.map { .string(String(decoding: $0.protectedCredentials, as: UTF8.self)) } ?? .null)
        ]).encodedJSON()
    }

    public static func transaction(directory: String, appID: String, prefix: String, policy: BackendAppsDataBackupPolicy) throws -> String {
        let units = try unit(directory: directory, appID: appID, prefix: prefix, policy: policy)
        let marker = "# Terminal Deck managed backup for " + appID
        let nonce = UUID().uuidString.lowercased()
        let stateRoot = String(directory[..<directory.lastIndex(of: "/")!])
        return #"""
        set -eu
        umask 077
        dir=\#(BackendAppsRuntime.quote(directory))
        unit=\#(BackendAppsRuntime.quote(units.name))
        marker=\#(BackendAppsRuntime.quote(marker))
        root=\#(BackendAppsRuntime.quote(stateRoot))
        test ! -L /var/lib/terminaldeck
        test -d "$root" && test ! -L "$root" && test -d "$dir" && test ! -L "$dir"
        test -d "$dir/.lock" && test ! -L "$dir/.lock" && test -f "$dir/.lock/owner" && test ! -L "$dir/.lock/owner"
        test ! -e "$dir/data-backup-policy-recovery.json" && test ! -L "$dir/data-backup-policy-recovery.json"
        test ! -e "$dir/data-restore-intent.json" && test ! -L "$dir/data-restore-intent.json"
        test -d /etc/systemd/system && test ! -L /etc/systemd/system
        for file in backup-policy.json backup-run.sh .backup-s3-credentials state.json; do
          test ! -L "$dir/$file"
          test ! -e "$dir/$file" || test -f "$dir/$file"
        done
        for kind in service timer; do
          path="/etc/systemd/system/$unit.$kind"
          test ! -L "$path"
          if [ -e "$path" ]; then test -f "$path"; grep -Fx -- "$marker" "$path" > /dev/null; fi
        done
        work="$dir/.backup-policy-transaction-\#(nonce)"
        test ! -e "$work" && test ! -L "$work"
        mkdir -- "$work"
        chmod 700 -- "$work"
        committed=0
        changed=0
        rollback_failed=0
        snapshot() {
          target="$1"; name="$2"
          if [ -f "$target" ]; then cp -p -- "$target" "$work/$name.saved"; else : > "$work/$name.absent"; fi
        }
        restore_file() {
          target="$1"; name="$2"
          if [ -L "$target" ]; then rollback_failed=1; return; fi
          if [ -f "$work/$name.saved" ]; then
            cp -p -- "$work/$name.saved" "$work/$name.restore" || { rollback_failed=1; return; }
            sync -f "$work/$name.restore" || { rollback_failed=1; return; }
            mv -f -- "$work/$name.restore" "$target" || rollback_failed=1
          elif [ -f "$work/$name.absent" ]; then rm -f -- "$target" || rollback_failed=1; fi
        }
        finish() {
          result=$?
          trap - EXIT
          if [ "$committed" = 0 ] && [ "$changed" = 1 ]; then
            set +e
            systemctl disable --now "$unit.timer" > /dev/null 2>&1
            restore_file "$dir/backup-policy.json" policy
            restore_file "$dir/backup-run.sh" runner
            restore_file "$dir/.backup-s3-credentials" credentials
            restore_file "$dir/state.json" state
            restore_file "/etc/systemd/system/$unit.service" service
            restore_file "/etc/systemd/system/$unit.timer" timer
            systemctl daemon-reload > /dev/null 2>&1 || rollback_failed=1
            if [ "$was_enabled" = enabled ]; then systemctl enable "$unit.timer" > /dev/null 2>&1 || rollback_failed=1
            elif [ -f "/etc/systemd/system/$unit.timer" ]; then systemctl disable "$unit.timer" > /dev/null 2>&1 || rollback_failed=1; fi
            if [ "$was_active" = active ]; then systemctl start "$unit.timer" > /dev/null 2>&1 || rollback_failed=1
            elif [ -f "/etc/systemd/system/$unit.timer" ]; then systemctl stop "$unit.timer" > /dev/null 2>&1 || rollback_failed=1; fi
            now_enabled=$(systemctl is-enabled "$unit.timer" 2>/dev/null || true)
            now_active=$(systemctl is-active "$unit.timer" 2>/dev/null || true)
            if [ "$was_enabled" = enabled ]; then [ "$now_enabled" = enabled ] || rollback_failed=1
            else [ "$now_enabled" != enabled ] || rollback_failed=1; fi
            if [ "$was_active" = active ]; then [ "$now_active" = active ] || rollback_failed=1
            else [ "$now_active" != active ] || rollback_failed=1; fi
            sync -f "$dir" || rollback_failed=1
            sync -f /etc/systemd/system || rollback_failed=1
            if [ "$rollback_failed" = 0 ]; then
              rm -f -- "$dir/data-backup-policy-recovery.json" || rollback_failed=1
              sync -f "$dir" || rollback_failed=1
            fi
            if [ "$rollback_failed" = 1 ]; then
              jq -n --arg path "$work" '{phase:"policy-recovery-required",snapshotPath:$path}' > "$dir/data-backup-policy-recovery.json"
              chmod 600 "$dir/data-backup-policy-recovery.json"
              sync -f "$dir/data-backup-policy-recovery.json"
              sync -f "$dir"
              exit 74
            fi
          fi
          rm -rf -- "$work"
          exit "$result"
        }
        trap finish EXIT
        trap 'exit 130' HUP INT TERM
        cat > "$work/input.json"
        chmod 600 "$work/input.json"
        jq -e '(.policy.enabled | type) == "boolean" and (.updatedAt | type == "number" and . > 0)' "$work/input.json" >/dev/null
        enabled=$(jq -r '.policy.enabled' "$work/input.json")
        if [ "$enabled" = true ]; then
          schedule=$(jq -er '.policy.schedule' "$work/input.json")
          systemd-analyze calendar "$schedule" >/dev/null 2>&1
        fi
        was_enabled=$(systemctl is-enabled "$unit.timer" 2>/dev/null || true)
        was_active=$(systemctl is-active "$unit.timer" 2>/dev/null || true)
        case "$was_enabled" in enabled|disabled|not-found|'') ;; *) exit 69;; esac
        case "$was_active" in active|inactive|failed|unknown|'') ;; *) exit 69;; esac
        snapshot "$dir/backup-policy.json" policy
        snapshot "$dir/backup-run.sh" runner
        snapshot "$dir/.backup-s3-credentials" credentials
        snapshot "$dir/state.json" state
        snapshot "/etc/systemd/system/$unit.service" service
        snapshot "/etc/systemd/system/$unit.timer" timer
        sync -f "$work"
        # From this point every error or signal restores the prior files and timer state.
        changed=1
        jq -n --arg path "$work" '{phase:"policy-in-progress",snapshotPath:$path}' > "$work/intent.new"
        chmod 600 "$work/intent.new"
        sync -f "$work/intent.new"
        mv -f -- "$work/intent.new" "$dir/data-backup-policy-recovery.json"
        sync -f "$dir"
        if [ -f "/etc/systemd/system/$unit.timer" ]; then systemctl disable --now "$unit.timer" > /dev/null 2>&1; fi
        jq '.policy' "$work/input.json" > "$work/policy.new"
        chmod 600 "$work/policy.new"
        sync -f "$work/policy.new"
        mv -f -- "$work/policy.new" "$dir/backup-policy.json"
        if jq -e '.credentials != null' "$work/input.json" > /dev/null; then
          jq -r '.credentials' "$work/input.json" > "$work/credentials.new"
          chmod 600 "$work/credentials.new"
          sync -f "$work/credentials.new"
          mv -f -- "$work/credentials.new" "$dir/.backup-s3-credentials"
        else rm -f -- "$dir/.backup-s3-credentials"; fi
        if [ "$enabled" = true ]; then
          jq -r '.runner' "$work/input.json" > "$work/runner.new"
          jq -r '.service' "$work/input.json" > "$work/service.new"
          jq -r '.timer' "$work/input.json" > "$work/timer.new"
          chmod 600 "$work/runner.new" "$work/service.new" "$work/timer.new"
          sync -f "$work/runner.new"
          sync -f "$work/service.new"
          sync -f "$work/timer.new"
          mv -f -- "$work/runner.new" "$dir/backup-run.sh"
          mv -f -- "$work/service.new" "/etc/systemd/system/$unit.service"
          mv -f -- "$work/timer.new" "/etc/systemd/system/$unit.timer"
          systemd-analyze verify "/etc/systemd/system/$unit.service" "/etc/systemd/system/$unit.timer" > /dev/null 2>&1
          systemctl daemon-reload
          systemctl enable --now "$unit.timer" > /dev/null 2>&1
          systemctl is-enabled --quiet "$unit.timer"
          systemctl is-active --quiet "$unit.timer"
        else
          test "$(systemctl is-enabled "$unit.timer" 2>/dev/null || true)" != enabled
          test "$(systemctl is-active "$unit.timer" 2>/dev/null || true)" != active
        fi
        jq --slurpfile input "$work/input.json" '.backupPolicy = $input[0].policy | .updatedAt = $input[0].updatedAt' "$dir/state.json" > "$work/state.new"
        chmod 600 "$work/state.new"
        sync -f "$work/state.new"
        mv -f -- "$work/state.new" "$dir/state.json"
        sync -f "$dir"
        sync -f /etc/systemd/system
        rm -- "$dir/data-backup-policy-recovery.json"
        sync -f "$dir"
        committed=1
        """#
    }
}
