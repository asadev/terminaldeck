import Foundation
import TerminalDeckNativeCore

/// The server-side helper set (plain POSIX sh, systemd, Docker CLI). The Mac
/// generates these files; they run on the server with the Mac switched off.
/// Every automatic action is limited to resources carrying Terminal Deck's
/// ownership label, except one opt-in cleanup step that says so: Docker keeps a
/// single build cache for the whole server, without labels, so "Every tool's
/// build cache older than a week" trims all of it. No other global prune is here.
public enum BackendAppsServerScripts {
    static func header(_ layout: BackendAppsServerLayout) -> String {
        "#!/bin/sh\n" + BackendAppsServerLayout.marker + " v" + BackendAppsServerLayout.version + "\n"
    }

    public static func library(_ layout: BackendAppsServerLayout) -> String {
        let q = BackendAppsRuntime.quote
        return header(layout) + #"""
        # Shared settings and helpers. Sourced, never executed.
        TD_PREFIX=\#(q(layout.prefix))
        TD_BASE=\#(q(layout.base))
        TD_OPT=\#(q(layout.opt))
        TD_BIN=\#(q(layout.bin))
        TD_ETC=\#(q(layout.etc))
        TD_DATA=\#(q(layout.data))
        TD_STATE=\#(q(layout.state))
        TD_NET=\#(q(layout.network))
        TD_UNITS=\#(q(layout.units))
        TD_CADDY_LOCK=\#(q(layout.caddyLock))
        TD_LABEL='\#(BackendAppsServerLayout.managedLabel)=true'
        TD_APP_LABEL='\#(BackendAppsServerLayout.appLabel)'
        JQ="${TD_JQ:-$TD_BIN/jq}"
        umask 077
        td_now() { date +%s; }
        td_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }
        td_valid_id() {
          case "$1" in ''|-*|*[!a-z0-9-]*) return 1 ;; esac
          case "$1" in [a-z]*) ;; *) return 1 ;; esac
          [ "${#1}" -le 48 ]
        }
        td_key_file() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-120; }
        # Quote a value for a curl config file read from stdin (keeps secrets off argv).
        td_curlq() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN{ORS=""} NR>1{print "\\n"} {print}'; }
        td_tmpdir() { mkdir -p "$TD_DATA/tmp" && chmod 700 "$TD_DATA/tmp" && mktemp -d "$TD_DATA/tmp/w.XXXXXX"; }
        td_hex_to_bin() {
          _hex=$(tr -d ' \n')
          while [ -n "$_hex" ]; do
            _pair=${_hex%"${_hex#??}"}; _hex=${_hex#??}
            printf "\\$(printf '%03o' "$((0x$_pair))")"
          done
        }
        # HMAC-SHA256 of a file with a key file. Neither value ever appears on a command line.
        td_hmac_sha256() {
          _w=$(td_tmpdir) || return 1
          if [ "$(wc -c < "$1" | tr -d ' ')" -gt 64 ]; then sha256sum < "$1" | cut -c1-64 | td_hex_to_bin > "$_w/k"; else cat "$1" > "$_w/k"; fi
          : > "$_w/i"; : > "$_w/o"; _n=0
          for _b in $(od -An -v -tu1 "$_w/k"); do
            printf "\\$(printf '%03o' "$((_b ^ 54))")" >> "$_w/i"
            printf "\\$(printf '%03o' "$((_b ^ 92))")" >> "$_w/o"
            _n=$((_n + 1))
          done
          while [ "$_n" -lt 64 ]; do printf '\066' >> "$_w/i"; printf '\134' >> "$_w/o"; _n=$((_n + 1)); done
          cat "$_w/i" "$2" | sha256sum | cut -c1-64 | td_hex_to_bin > "$_w/inner"
          cat "$_w/o" "$_w/inner" | sha256sum | cut -c1-64
          rm -rf "$_w"
        }
        td_notify() { "$TD_BIN/td-notify" "$@" >/dev/null 2>&1 || true; }
        td_owned_container() {
          [ "$(docker inspect -f "{{index .Config.Labels \"$TD_APP_LABEL\"}}|{{index .Config.Labels \"\#(BackendAppsServerLayout.managedLabel)\"}}" "$1" 2>/dev/null)" = "$2|true" ]
        }

        """#
    }

    /// td-notify KEY SEVERITY TITLE MESSAGE [APP] | --resolve KEY [MESSAGE] | --test
    public static func notify(_ layout: BackendAppsServerLayout) -> String {
        header(layout) + ". \(BackendAppsRuntime.quote(layout.bin + "/td-lib.sh"))\n" + #"""
        conf="$TD_ETC/alerts.json"
        sent="$TD_DATA/alerts/sent"
        history="$TD_DATA/alerts/history.jsonl"
        mkdir -p "$sent" && chmod 700 "$TD_DATA/alerts" "$sent"
        host=$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9.-' | cut -c1-64)
        mode=send
        case "${1:-}" in
          --test) mode=test; key=test; severity=info; title="Test alert"; message="Alerts from $host reach this channel."; app='' ;;
          --resolve)
            key=${2:-}; [ -n "$key" ] || exit 2
            f="$sent/$(td_key_file "$key")"; [ -f "$f" ] || exit 0
            t=$(head -n 1 "$f.title" 2>/dev/null || true); rm -f "$f" "$f.title"
            mode=resolve; severity=info; title="Resolved: ${t:-a problem cleared}"; message=${3:-"The problem has cleared."}; app='' ;;
          *) key=${1:-}; severity=${2:-warning}; title=${3:-}; message=${4:-}; app=${5:-}
             [ -n "$key" ] && [ -n "$title" ] || exit 2 ;;
        esac
        case "$severity" in info|warning|critical) ;; *) severity=warning ;; esac
        title=$(printf '%s' "$title" | tr -d '\r\n' | cut -c1-200)
        message=$(printf '%s' "$message" | cut -c1-2000)
        [ -f "$conf" ] || { [ "$mode" = test ] && echo '{"channels":[]}'; exit 0; }
        if [ "$mode" = send ]; then
          [ "$("$JQ" -r '.enabled // true' "$conf" 2>/dev/null)" = true ] || exit 0
          remind=$("$JQ" -r '(.remindMinutes // 1440) | floor' "$conf" 2>/dev/null || echo 1440)
          f="$sent/$(td_key_file "$key")"
          if [ -f "$f" ]; then
            last=$(cat "$f" 2>/dev/null || echo 0)
            [ $(( $(td_now) - last )) -lt $(( remind * 60 )) ] && exit 0
          fi
          td_now > "$f"; printf '%s\n' "$title" > "$f.title"
        fi
        w=$(td_tmpdir) || exit 1
        trap 'rm -rf "$w"' EXIT
        at=$(td_now)
        "$JQ" -n --arg key "$key" --arg severity "$severity" --arg title "$title" --arg message "$message" --arg app "$app" \
          --arg server "$host" --argjson at "$at" \
          '{source:"terminaldeck",server:$server,key:$key,severity:$severity,title:$title,message:$message,app:(if $app=="" then null else $app end),at:$at}' > "$w/body.json"
        case "$severity" in critical) icon='[!!]' ;; warning) icon='[!]' ;; *) icon='[i]' ;; esac
        text="$icon $title ($host)
        $message"
        results=''
        n=$("$JQ" -r '(.channels // []) | length' "$conf" 2>/dev/null || echo 0)
        i=0
        while [ "$i" -lt "$n" ]; do
          "$JQ" -c ".channels[$i]" "$conf" > "$w/c.json"
          i=$((i + 1))
          id=$("$JQ" -r '.id // "channel"' "$w/c.json" | tr -cd 'A-Za-z0-9_-' | cut -c1-48)
          kind=$("$JQ" -r '.kind // ""' "$w/c.json")
          [ "$("$JQ" -r '.enabled // true' "$w/c.json")" = true ] || continue
          ok=0
          case "$kind" in
            telegram)
              { printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$(td_curlq "$("$JQ" -r '.botToken // ""' "$w/c.json")")"
                printf 'data-urlencode = "chat_id=%s"\n' "$(td_curlq "$("$JQ" -r '.chatId // ""' "$w/c.json")")"
                printf 'data-urlencode = "text=%s"\n' "$(td_curlq "$text")"
              } | curl -fsS --max-time 20 --proto =https -o /dev/null -K - 2>/dev/null && ok=1 ;;
            email)
              from=$("$JQ" -r '.from // ""' "$w/c.json" | tr -d '\r\n<>')
              { printf 'From: <%s>\r\n' "$from"
                printf 'To: %s\r\n' "$("$JQ" -r '[.to[]? | gsub("[\r\n<>,]"; "") | "<" + . + ">"] | join(", ")' "$w/c.json")"
                printf 'Subject: [Terminal Deck] %s\r\n' "$title"
                printf 'Date: %s\r\n' "$(date -R 2>/dev/null || date)"
                printf 'Content-Type: text/plain; charset=utf-8\r\n\r\n'
                printf '%s\r\n\r\nServer: %s\r\n' "$message" "$host"
              } > "$w/mail.txt"
              { printf 'url = "%s"\n' "$(td_curlq "$("$JQ" -r '.smtpUrl // ""' "$w/c.json")")"
                printf 'ssl-reqd\n'
                printf 'mail-from = "%s"\n' "$(td_curlq "$from")"
                "$JQ" -r '.to[]? | gsub("[\r\n<>,]"; "")' "$w/c.json" | while IFS= read -r to; do printf 'mail-rcpt = "%s"\n' "$(td_curlq "$to")"; done
                u=$("$JQ" -r '.username // ""' "$w/c.json")
                [ -n "$u" ] && printf 'user = "%s:%s"\n' "$(td_curlq "$u")" "$(td_curlq "$("$JQ" -r '.password // ""' "$w/c.json")")"
                printf 'upload-file = "%s"\n' "$w/mail.txt"
              } | curl -fsS --max-time 30 --proto =smtp,smtps -K - >/dev/null 2>&1 && ok=1 ;;
            webhook|receiver)
              url=$("$JQ" -r '.url // ""' "$w/c.json")
              { printf 'url = "%s"\n' "$(td_curlq "$url")"
                printf 'header = "Content-Type: application/json"\n'
                if [ "$kind" = receiver ]; then
                  printf 'header = "Authorization: Bearer %s"\n' "$(td_curlq "$("$JQ" -r '.token // ""' "$w/c.json")")"
                elif [ "$("$JQ" -r '(.secret // "") | length' "$w/c.json")" -gt 0 ]; then
                  "$JQ" -j '.secret' "$w/c.json" > "$w/key"
                  printf 'header = "X-Terminal-Deck-Signature: sha256=%s"\n' "$(td_hmac_sha256 "$w/key" "$w/body.json")"
                  rm -f "$w/key"
                fi
                printf 'data-binary = "@%s"\n' "$w/body.json"
              } | curl -fsS --max-time 20 --proto =https,http -o /dev/null -K - 2>/dev/null && ok=1 ;;
          esac
          results="$results$id:$ok "
        done
        summary=$(printf '%s' "$results" | "$JQ" -Rc 'split(" ") | map(select(length > 0) | split(":") | {id:.[0], ok:(.[1] == "1")})')
        if [ "$mode" = test ]; then printf '{"channels":%s}\n' "$summary"; exit 0; fi
        "$JQ" -c --argjson delivered "$summary" '. + {delivered:$delivered}' "$w/body.json" >> "$history"
        tail -n 200 "$history" > "$w/h" && cat "$w/h" > "$history"
        exit 0

        """#
    }

    /// Long-running: Docker's own event stream (push, never polling). Our
    /// labelled containers are watched by default; others only by opt-in name.
    public static func watch(_ layout: BackendAppsServerLayout) -> String {
        header(layout) + ". \(BackendAppsRuntime.quote(layout.bin + "/td-lib.sh"))\n" + #"""
        mkdir -p "$TD_DATA/watch" && chmod 700 "$TD_DATA/watch"
        tab=$(printf '\t')
        down_check() {
          sleep 8
          st=$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null) || exit 0
          case "$st" in exited|dead) ;; *) exit 0 ;; esac
          if [ "$3" = owned ]; then
            active=$("$JQ" -r '.containerId // ""' "$TD_STATE/$2/state.json" 2>/dev/null)
            [ "$active" = "$1" ] || exit 0
            td_notify "down:$2" critical "$2 is down" "The app $2 stopped and did not restart. Its address may show an error." "$2"
          else
            td_notify "down:$2" critical "$2 is down" "The watched container $2 stopped and did not restart."
          fi
        }
        # SRV2's recipe re-applies an app's address after a reboot or a restart
        # that changed its private address. Skipped while another change holds the lock.
        ensure_route() {
          d="$TD_STATE/$1"
          [ -f "$d/recipe.sh" ] && [ ! -L "$d/recipe.sh" ] || return 0
          mkdir "$d/.lock" 2>/dev/null || return 0
          tok="watch-$(td_uuid)"; printf '%s' "$tok" > "$d/.lock/owner"
          if ! ( cd / && timeout 120 sh "$d/recipe.sh" ensure-route ) >/dev/null 2>&1; then
            td_notify "route:$1" critical "Address for $1 needs attention" "Terminal Deck could not re-apply the address of $1 after a restart." "$1"
          fi
          [ "$(cat "$d/.lock/owner" 2>/dev/null)" = "$tok" ] && rm -f "$d/.lock/owner" && rmdir "$d/.lock"
          return 0
        }
        for f in "$TD_STATE"/*/recipe.sh; do
          [ -f "$f" ] || continue
          a=$(basename "$(dirname "$f")"); td_valid_id "$a" && ensure_route "$a"
        done
        docker events --format '{{json .}}' --filter type=container 2>/dev/null | while IFS= read -r ev; do
          line=$(printf '%s' "$ev" | "$JQ" -r '[(.Action // ""), (.Actor.ID // ""), (.Actor.Attributes.name // ""), (.Actor.Attributes["\#(BackendAppsServerLayout.managedLabel)"] // ""), (.Actor.Attributes["\#(BackendAppsServerLayout.appLabel)"] // "")] | map(gsub("[^A-Za-z0-9 _.:-]"; "")) | map(if . == "" then "-" else . end) | @tsv' 2>/dev/null) || continue
          IFS="$tab" read -r action id name managed app <<EOF
        $line
        EOF
          case "$id" in ''|*[!a-f0-9]*) continue ;; esac
          if [ "$managed" = true ] && td_valid_id "$app"; then who=owned; label=$app
          elif [ -f "$TD_ETC/alerts.json" ] && "$JQ" -e --arg n "$name" '(.watch.containers // []) | index($n) != null' "$TD_ETC/alerts.json" >/dev/null 2>&1; then who=watched; label=$name; app=''
          else continue; fi
          case "$action" in
            oom) td_notify "oom:$label" critical "$label ran out of memory" "The system stopped $label because it used all its memory." "$app" ;;
            "health_status: unhealthy") td_notify "unhealthy:$label" warning "$label is unhealthy" "$label failed its health check." "$app" ;;
            "health_status: healthy") td_notify --resolve "unhealthy:$label" ;;
            start) td_notify --resolve "down:$label"; [ "$who" = owned ] && ensure_route "$app" & ;;
            die)
              f="$TD_DATA/watch/$(printf '%s' "$id" | cut -c1-24).dies"
              { cat "$f" 2>/dev/null; td_now; } | tail -n 5 > "$f.new" && mv -f "$f.new" "$f"
              recent=$(awk -v now="$(td_now)" 'now - $1 <= 600' "$f" | wc -l | tr -d ' ')
              if [ "$recent" -ge 3 ]; then
                td_notify "loop:$label" critical "$label keeps restarting" "$label stopped $recent times in 10 minutes and is restarting in a loop." "$app"
              fi
              down_check "$id" "$label" "$who" &
              ;;
          esac
        done
        exit 1

        """#
    }

    /// Every 5 minutes: disk, memory pressure, failed backups/deploys, our
    /// address manager, and (every 6 hours) certificate renewal.
    public static func check(_ layout: BackendAppsServerLayout) -> String {
        header(layout) + ". \(BackendAppsRuntime.quote(layout.bin + "/td-lib.sh"))\n" + #"""
        conf="$TD_ETC/alerts.json"
        setting() { "$JQ" -r "$1" "$conf" 2>/dev/null || echo "$2"; }
        # SRV2: undo app changes that stopped halfway (their Mac or connection died),
        # with the Mac off. The helper only acts once a change's lease is 30 minutes stale.
        rec="$TD_STATE/.td-recover.sh"
        if [ -f "$rec" ] && [ ! -L "$rec" ]; then
          sh "$rec" --stale-minutes 30 2>/dev/null | while IFS='=' read -r key value; do
            [ "$key" = recovered ] && td_valid_id "$value" || continue
            [ -f "$conf" ] && td_notify "recovered:$value:$(date +%s)" warning "An interrupted change was undone" "A change to $value stopped halfway (its Mac or connection went away), so the server put $value back as it was." "$value"
          done
        fi
        [ -f "$conf" ] || exit 0
        disk_limit=$(setting '(.thresholds.diskPercent // 85) | floor' 85)
        pressure_limit=$(setting '(.thresholds.memoryPressure // 20) | floor' 20)
        cert_days=$(setting '(.thresholds.certDays // 14) | floor' 14)
        mkdir -p "$TD_DATA/check"
        root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
        for p in / "$root"; do
          [ -n "$p" ] && [ -d "$p" ] || continue
          set -- $(df -P "$p" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5, $6}')
          [ -n "${1:-}" ] || continue
          if [ "$1" -ge "$disk_limit" ]; then td_notify "disk:$2" warning "Disk is $1% full" "The disk holding $2 is $1% full (limit $disk_limit%). Unused app versions can be cleaned up from Terminal Deck."
          else td_notify --resolve "disk:$2" "The disk holding $2 is back below $disk_limit%."; fi
        done
        if [ -r /proc/pressure/memory ]; then
          some=$(awk '/^some/{split($3,a,"="); print int(a[2])}' /proc/pressure/memory)
          avail=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{if (t>0) print int(a*100/t); else print 100}' /proc/meminfo)
          if [ "${some:-0}" -ge "$pressure_limit" ] || [ "${avail:-100}" -lt 5 ]; then
            td_notify memory warning "Memory is running out" "Programs waited for memory ${some:-0}% of the last minute; ${avail:-?}% of memory is free."
          else td_notify --resolve memory "Memory pressure is back to normal."; fi
        fi
        systemctl list-units --all --plain --no-legend --type=service "${TD_PREFIX}-*-backup.service" 2>/dev/null | awk '{print $1}' | while read -r u; do
          r=$(systemctl show -p Result --value "$u" 2>/dev/null); t=$(systemctl show -p ExecMainExitTimestampMonotonic --value "$u" 2>/dev/null)
          set -- "${r:-success}" "${t:-0}"
          [ "$2" != 0 ] || continue
          app=${u#"$TD_PREFIX-"}; app=${app%-backup.service}
          if [ "${1:-success}" != success ]; then td_notify "backup:$u:$2" critical "Backup failed for $app" "The scheduled backup of $app did not finish. The previous backups are kept." "$app"; fi
        done
        for f in "$TD_STATE"/*/state.json; do
          [ -f "$f" ] || continue
          app=$(basename "$(dirname "$f")"); td_valid_id "$app" || continue
          id=$("$JQ" -r '(.deployments // []) | max_by((.createdAt | numbers) // 0) | select(.status == "failed") | .id // empty' "$f" 2>/dev/null | tr -cd 'A-Za-z0-9_.-' | cut -c1-96)
          [ -n "$id" ] || continue
          seen="$TD_DATA/check/deploy-$app"
          [ "$(cat "$seen" 2>/dev/null)" = "$id" ] && continue
          printf '%s' "$id" > "$seen"
          td_notify "deployfail:$app:$id" critical "Deploy failed for $app" "The latest deploy of $app failed. The previous version keeps running." "$app"
        done
        if docker inspect "$TD_BASE-caddy" >/dev/null 2>&1; then
          if [ "$(docker inspect -f '{{.State.Running}}' "$TD_BASE-caddy" 2>/dev/null)" = true ]; then td_notify --resolve addresses "Web addresses are being served again."
          else td_notify addresses critical "Web addresses are down" "Terminal Deck's address manager is not running, so app addresses do not answer."; fi
        fi
        if ! systemctl is-active --quiet "$TD_BASE-watch.service"; then td_notify watcher warning "App alerts are paused" "The app watcher is not running; down and restart alerts are delayed."
        else td_notify --resolve watcher; fi
        stamp="$TD_DATA/check/certs"
        if [ ! -f "$stamp" ] || [ $(( $(td_now) - $(cat "$stamp") )) -ge 21600 ]; then
          td_now > "$stamp"
          { for f in "$TD_STATE"/*/state.json; do [ -f "$f" ] && "$JQ" -r '.domains[]? // empty' "$f" 2>/dev/null; done
            "$JQ" -r '.hooksHost // empty' "$TD_ETC/server.json" 2>/dev/null; } | grep -E '^[A-Za-z0-9.-]{1,253}$' | sort -u | head -n 100 | while read -r d; do
            end=$(echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$d" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
            [ -n "$end" ] || continue
            ends=$(date -d "$end" +%s 2>/dev/null) || continue
            days=$(( (ends - $(td_now)) / 86400 ))
            if [ "$days" -lt "$cert_days" ]; then td_notify "cert:$d" warning "Certificate for $d is not renewing" "The HTTPS certificate for $d expires in $days days and has not been renewed."
            else td_notify --resolve "cert:$d"; fi
          done
        fi
        find "$TD_DATA/alerts/sent" -type f -mtime +30 -delete 2>/dev/null
        exit 0

        """#
    }

    /// td-cleanup [--dry-run]: removes only images that carry Terminal Deck's
    /// label, after rechecking that label on each one. Never `docker system prune`.
    /// The opt-in build cache trim is the server-wide exception named above.
    public static func cleanup(_ layout: BackendAppsServerLayout) -> String {
        header(layout) + ". \(BackendAppsRuntime.quote(layout.bin + "/td-lib.sh"))\n" + #"""
        dry=0; [ "${1:-}" = --dry-run ] && dry=1
        conf="$TD_ETC/cleanup.json"
        opt() { "$JQ" -r "$1" "$conf" 2>/dev/null || echo "$2"; }
        old=$(opt '.removeOldVersions // false' false)
        keep=$(opt '(.keepVersions // 3) | floor' 3)
        cache=$(opt '.buildCache // false' false)
        storage=$(opt '.unnamedStorage // false' false)
        w=$(td_tmpdir) || exit 1
        trap 'rm -rf "$w"' EXIT
        tab=$(printf '\t')
        root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
        [ -n "$root" ] || { echo '{"error":"docker-unavailable"}'; exit 1; }
        free_kb() { df -P "$root" | awk 'NR==2{print $4}'; }
        started=$(td_now); before=$(free_kb)
        : > "$w/remove"
        docker image ls -q --no-trunc --filter dangling=true --filter "label=$TD_LABEL" 2>/dev/null | sort -u | while read -r id; do
          printf '%s\tunused build leftover\n' "$id"; done >> "$w/remove"
        if [ "$old" = true ]; then
          docker ps -a -q --no-trunc 2>/dev/null | while read -r c; do docker inspect -f '{{.Image}}' "$c" 2>/dev/null; done > "$w/keep"
          for f in "$TD_STATE"/*/state.json; do
            [ -f "$f" ] && "$JQ" -r --argjson k "$keep" '(.deployments // []) | map(select(.imageId != null)) | sort_by((.createdAt | numbers) // 0) | .[-$k:] | .[].imageId' "$f" 2>/dev/null
          done >> "$w/keep"
          sort -u "$w/keep" -o "$w/keep"
          docker image ls --no-trunc --filter "label=$TD_LABEL" --format '{{.ID}}' 2>/dev/null | sort -u | while read -r id; do
            grep -qx "$id" "$w/keep" || printf '%s\tolder app version\n' "$id"
          done >> "$w/remove"
        fi
        : > "$w/items"
        sort -u -t "$tab" -k1,1 "$w/remove" | while IFS="$tab" read -r id reason; do
          case "$id" in sha256:*) ;; *) continue ;; esac
          [ "$(docker image inspect -f "{{index .Config.Labels \"\#(BackendAppsServerLayout.managedLabel)\"}}" "$id" 2>/dev/null)" = true ] || continue
          name=$(docker image inspect -f '{{index .Config.Labels "\#(BackendAppsServerLayout.appLabel)"}}' "$id" 2>/dev/null | tr -cd 'a-z0-9-')
          \#(layout.isTest ? "case \"$name\" in \"$TD_PREFIX\"-*) ;; *) continue ;; esac; " : "")size=$(docker image inspect -f '{{.Size}}' "$id" 2>/dev/null | tr -cd '0-9')
          if [ "$dry" = 1 ]; then result=would-remove
          elif docker image rm "$id" >/dev/null 2>&1; then result=removed
          else result=kept-in-use; fi
          "$JQ" -nc --arg id "$id" --arg app "$name" --arg reason "$reason" --arg result "$result" --arg size "${size:-0}" \
            '{kind:"image",id:$id,app:$app,reason:$reason,result:$result,bytes:($size|tonumber)}' >> "$w/items"
        done
        # Deploy rows whose version was just removed are marked, so Roll back is never
        # offered for them. An app busy with another change is left as it is.
        gone=$("$JQ" -sc '[.[] | select(.kind == "image" and .result == "removed") | .id]' "$w/items" 2>/dev/null)
        if [ -n "$gone" ] && [ "$gone" != "[]" ]; then
          for f in "$TD_STATE"/*/state.json; do
            [ -f "$f" ] && [ ! -L "$f" ] || continue
            "$JQ" -e --argjson g "$gone" 'any((.deployments // [])[]; .imageRemoved != true and ((.imageId // "") as $x | any($g[]; . == $x)))' "$f" >/dev/null 2>&1 || continue
            d=$(dirname "$f")
            mkdir "$d/.lock" 2>/dev/null || continue
            tok="cleanup-$(td_uuid)"; printf '%s' "$tok" > "$d/.lock/owner"
            "$JQ" --argjson g "$gone" '.deployments = [(.deployments // [])[] | if ((.imageId // "") as $x | any($g[]; . == $x)) then . + {imageRemoved:true} else . end]' "$f" > "$f.cleanup.tmp" \
              && [ -s "$f.cleanup.tmp" ] && chmod 600 "$f.cleanup.tmp" && mv -f "$f.cleanup.tmp" "$f"
            rm -f "$f.cleanup.tmp"
            [ "$(cat "$d/.lock/owner" 2>/dev/null)" = "$tok" ] && rm -f "$d/.lock/owner" && rmdir "$d/.lock"
          done
        fi
        if [ "$storage" = true ]; then
          docker volume ls -q --filter dangling=true --filter "label=$TD_LABEL" 2>/dev/null | grep -E '^[0-9a-f]{64}$' | while read -r v; do
            [ "$(docker volume inspect -f "{{index .Labels \"\#(BackendAppsServerLayout.managedLabel)\"}}" "$v" 2>/dev/null)" = true ] || continue
            if [ "$dry" = 1 ]; then result=would-remove; elif docker volume rm "$v" >/dev/null 2>&1; then result=removed; else result=kept-in-use; fi
            "$JQ" -nc --arg id "$v" --arg result "$result" '{kind:"unnamed-storage",id:$id,result:$result,bytes:0}' >> "$w/items"
          done
        fi
        if [ "$cache" = true ]; then
          if [ "$dry" = 1 ]; then result=would-trim; elif docker builder prune -f --filter until=168h >/dev/null 2>&1; then result=trimmed; else result=failed; fi
          "$JQ" -nc --arg result "$result" '{kind:"build-cache",id:"older than 7 days",result:$result,bytes:0}' >> "$w/items"
        fi
        after=$(free_kb)
        "$JQ" -sc --argjson dry "$dry" --argjson s "$started" --argjson e "$(td_now)" --argjson b "${before:-0}" --argjson a "${after:-0}" \
          '{dryRun:($dry == 1), startedAt:$s, finishedAt:$e, freedBytes:((($a - $b) * 1024) | if . < 0 then 0 else . end), items:.}' "$w/items" > "$w/result.json"
        if [ "$dry" = 1 ]; then cp "$w/result.json" "$TD_DATA/cleanup-preview.json"; else cp "$w/result.json" "$TD_DATA/cleanup-last.json"; fi
        cat "$w/result.json"
        exit 0

        """#
    }

    /// td-job APP JOB: runs one saved command inside the app's running
    /// container, keeps the last result and a capped log, alerts on failure.
    public static func job(_ layout: BackendAppsServerLayout) -> String {
        header(layout) + ". \(BackendAppsRuntime.quote(layout.bin + "/td-lib.sh"))\n" + #"""
        app=${1:-}; job=${2:-}
        td_valid_id "$app" && td_valid_id "$job" || exit 2
        dir="$TD_STATE/$app"; spec="$dir/jobs/$job.json"
        unit="$TD_PREFIX-${app}_job_$job"
        if [ ! -f "$dir/state.json" ] || [ ! -f "$spec" ]; then
          # The app or job was removed: retire this timer instead of failing forever.
          if grep -qF '\#(BackendAppsServerLayout.marker)' "$TD_UNITS/$unit.timer" 2>/dev/null; then systemctl disable --now "$unit.timer" >/dev/null 2>&1; fi
          exit 0
        fi
        [ "$("$JQ" -r '.enabled // true' "$spec")" = true ] || exit 0
        w=$(td_tmpdir) || exit 1
        trap 'rm -rf "$w"' EXIT
        started=$(td_now)
        cmd=$("$JQ" -r '.command // ""' "$spec")
        limit=$("$JQ" -r '(.timeoutSeconds // 600) | floor' "$spec")
        cid=$("$JQ" -r '.containerId // ""' "$dir/state.json")
        code=0
        if [ -z "$cmd" ]; then code=2; echo "No command is saved for this job." > "$w/out"
        elif [ -z "$cid" ] || ! td_owned_container "$cid" "$app" || [ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" != true ]; then
          code=3; echo "The app is not running, so the job could not start." > "$w/out"
        else
          timeout --kill-after=10 "$limit" docker exec "$cid" sh -c "$cmd" > "$w/out" 2>&1; code=$?
          [ "$code" = 124 ] && echo "The job was stopped after $limit seconds." >> "$w/out"
        fi
        mkdir -p "$dir/jobs"
        tail -c 65536 "$w/out" > "$dir/jobs/$job.log.new" && mv -f "$dir/jobs/$job.log.new" "$dir/jobs/$job.log"
        "$JQ" -nc --arg job "$job" --argjson s "$started" --argjson e "$(td_now)" --argjson c "$code" \
          '{jobId:$job, startedAt:$s, finishedAt:$e, exitCode:$c, ok:($c == 0)}' > "$dir/jobs/$job.last.json.new" && mv -f "$dir/jobs/$job.last.json.new" "$dir/jobs/$job.last.json"
        name=$("$JQ" -r '.name // .id' "$spec" | tr -d '\r\n' | cut -c1-80)
        if [ "$code" = 0 ]; then td_notify --resolve "job:$app:$job"
        else td_notify "job:$app:$job" warning "Scheduled job failed: $name" "The job $name of $app ended with code $code. Its last output is in Terminal Deck." "$app"; fi
        exit 0

        """#
    }

    // MARK: systemd units

    public static func coreUnits(_ layout: BackendAppsServerLayout, cleanupSchedule: String, traefikGateway: String?) -> [(name: String, text: String)] {
        let m = BackendAppsServerLayout.marker + " v" + BackendAppsServerLayout.version
        let bin = layout.bin
        var listen = "ListenStream=127.0.0.1:\(layout.hookPort)\n"
        if let traefikGateway { listen += "ListenStream=\(traefikGateway):\(layout.hookPort)\n" }
        return [
            (layout.unit("watch.service"), "\(m)\n[Unit]\nDescription=Terminal Deck app alerts\nAfter=docker.service network-online.target\nWants=docker.service\n[Service]\nType=simple\nExecStart=/bin/sh \(bin)/td-watch\nRestart=always\nRestartSec=15\nUMask=0077\n[Install]\nWantedBy=multi-user.target\n"),
            (layout.unit("check.service"), "\(m)\n[Unit]\nDescription=Terminal Deck server checks\nAfter=docker.service\n[Service]\nType=oneshot\nExecStart=/bin/sh \(bin)/td-check\nUMask=0077\nTimeoutStartSec=600\n"),
            (layout.unit("check.timer"), "\(m)\n[Unit]\nDescription=Terminal Deck server checks every 5 minutes\n[Timer]\nOnBootSec=3min\nOnUnitActiveSec=5min\nUnit=\(layout.unit("check.service"))\n[Install]\nWantedBy=timers.target\n"),
            (layout.unit("cleanup.service"), "\(m)\n[Unit]\nDescription=Terminal Deck cleanup of its own unused app versions\nAfter=docker.service\n[Service]\nType=oneshot\nExecStart=/bin/sh \(bin)/td-cleanup\nUMask=0077\nTimeoutStartSec=3600\n"),
            (layout.unit("cleanup.timer"), "\(m)\n[Unit]\nDescription=Terminal Deck scheduled cleanup\n[Timer]\nOnCalendar=\(cleanupSchedule)\nPersistent=true\nRandomizedDelaySec=30min\nUnit=\(layout.unit("cleanup.service"))\n[Install]\nWantedBy=timers.target\n"),
            (layout.unit("hook.socket"), "\(m)\n[Unit]\nDescription=Terminal Deck deploy endpoint (private; reached through the address manager)\n[Socket]\n\(listen)Accept=yes\nMaxConnections=16\nFreeBind=true\n[Install]\nWantedBy=sockets.target\n"),
            (layout.unit("hook@.service"), "\(m)\n[Unit]\nDescription=Terminal Deck deploy endpoint request\n[Service]\nType=simple\nExecStart=/bin/sh \(bin)/td-hook\nStandardInput=socket\nStandardOutput=socket\nStandardError=journal\nRuntimeMaxSec=60\nUMask=0077\nNoNewPrivileges=true\nPrivateTmp=true\n"),
            (layout.unit("deploy@.service"), "\(m)\n[Unit]\nDescription=Terminal Deck server-side deploy of %i\nAfter=docker.service network-online.target\n[Service]\nType=oneshot\nExecStart=/bin/sh \(bin)/td-deploy %i\nUMask=0077\nTimeoutStartSec=3600\n")
        ]
    }

    public static func jobUnits(_ layout: BackendAppsServerLayout, app: String, job: String, schedule: String) -> (service: String, timer: String) {
        let m = BackendAppsServerLayout.marker + " v" + BackendAppsServerLayout.version
        let name = layout.jobUnit(app: app, job: job)
        return ("\(m)\n[Unit]\nDescription=Terminal Deck scheduled job \(job) for \(app)\nAfter=docker.service\n[Service]\nType=oneshot\nExecStart=/bin/sh \(layout.bin)/td-job \(app) \(job)\nUMask=0077\nTimeoutStartSec=infinity\n",
                "\(m)\n[Unit]\nDescription=Terminal Deck schedule for job \(job) of \(app)\n[Timer]\nOnCalendar=\(schedule)\nPersistent=true\nUnit=\(name).service\n[Install]\nWantedBy=timers.target\n")
    }
}
