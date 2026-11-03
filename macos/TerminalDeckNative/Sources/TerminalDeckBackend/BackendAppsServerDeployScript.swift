import Foundation
import TerminalDeckNativeCore

/// The deploy as it starts ON the server (td-deploy), and the small
/// authenticated endpoint that starts it (td-hook). td-deploy downloads the
/// source and runs the app's recipe (BackendAppsSRV2Recipe), the one place an
/// app's deploy steps live, and records its result in the same state file and
/// lock as the Mac deployer, so the Mac and the server can take turns on one app.
public enum BackendAppsServerDeployScript {
    /// GitHub's published SSH host key (api.github.com/meta), pinned for deploy keys.
    public static let githubKnownHosts = "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n"

    public static func deploy(_ layout: BackendAppsServerLayout) -> String {
        let q = BackendAppsRuntime.quote
        let repository = layout.isTest ? "\"$TD_PREFIX-$app\"" : "\"terminaldeck/$app\""
        let defaultDomain = layout.isTest
            ? #"case "$app" in "$TD_PREFIX"-*) d=$app ;; *) d="$TD_PREFIX-$app" ;; esac; printf '%s.%s.sslip.io' "$d" "$(printf '%s' "$1" | tr . -)""#
            : #"printf '%s.%s.sslip.io' "$app" "$1""#
        // Only the live-test layout may clone a local repository it owns.
        let testSource = layout.isTest ? #"""
          if [ -f "$TD_ETC/apps/$app/source-url" ]; then
            url=$(head -n 1 "$TD_ETC/apps/$app/source-url")
            case "$url" in "file://$TD_STATE/"*) ;; *) fail "The test source is not allowed." ;; esac
            gitc="-c core.hooksPath=/dev/null -c credential.helper= -c protocol.file.allow=always"
          fi
        """# : ""
        return BackendAppsServerScripts.header(layout) + ". \(q(layout.bin + "/td-lib.sh"))\n" + #"""
        app=${1:-}
        td_valid_id "$app" || exit 2
        dir="$TD_STATE/$app"; st="$dir/state.json"; conf="$TD_ETC/server.json"
        mkdir -p "$TD_DATA/deploys" "$TD_DATA/deploy-queue" "$TD_DATA/check"
        log="$TD_DATA/deploys/$app.log"
        queue="$TD_DATA/deploy-queue/$app.json"
        say() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$log"; }
        now_ms() { echo "$(td_now)000"; }
        default_domain() { \#(defaultDomain); }
        rel_ok() {
          case "$1" in ''|/*|*..*|-*) return 1 ;; esac
          printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._/-]{1,255}$'
        }
        write_state() { "$JQ" "$@" "$st" > "$st.server.tmp" && [ -s "$st.server.tmp" ] && chmod 600 "$st.server.tmp" && { sync "$st.server.tmp" 2>/dev/null || true; } && mv -f "$st.server.tmp" "$st"; }
        update_row() { write_state --arg id "$id" --argjson patch "$1" '.deployments = [(.deployments // [])[] | if .id == $id then . + $patch else . end]'; }
        val() { grep "^$1=" "$res" 2>/dev/null | tail -n 1 | cut -d= -f2-; }
        list() { grep "^$1=" "$res" 2>/dev/null | cut -d= -f2- | "$JQ" -Rsc 'split("\n") | map(select(length > 0))'; }
        # The recipe result in $res goes onto deploy row $1 (exit code $2, addresses $3) the way
        # the Mac deployer's finish() records it. 0 when the new version runs; otherwise $msg says why.
        record_result() {
          c=$(val container); u=$(val upstream); err=$(val error)
          if [ "$2" = 0 ] && [ -n "$c" ] && [ -n "$u" ]; then
            write_state --arg id "$1" --arg c "$c" --arg u "$u" --arg tag "$(val tag)" --arg image "$(val image)" --arg port "$(val port)" --arg probe "$(val probe)" \
              --argjson d "$3" --argjson retired "$(list retired)" --argjson pruned "$(list pruned)" --argjson warnings "$(list warning)" --argjson t "$(now_ms)" '
              .deployments = [(.deployments // [])[] | if .id == $id then . + {status:"running",finishedAt:$t,containerId:$c,upstream:$u}
                  + (if ($d | length) > 0 then {domains:$d} else {} end)
                  + (if $tag == "" then {} else {imageTag:$tag} end) + (if $image == "" then {} else {imageId:$image} end)
                  + (if ($port | test("^[0-9]+$")) then {port:($port | tonumber)} else {} end) + (if $probe == "" then {} else {probe:$probe} end)
                  + (if ($warnings | length) > 0 then {warnings:$warnings} else {} end)
                elif ((.containerId // "") as $x | $retired | any(. == $x)) then . + {instanceState:"stopped"} else . end]
              | .deployments = [.deployments[] | if ((.imageId // "") as $x | $pruned | any(. == $x)) then . + {imageRemoved:true} else . end]
              | .activeDeploymentId = $id | .containerId = $c | .status = "running" | .updatedAt = $t
              | (if ($d | length) > 0 then .address = ("https://" + $d[0]) | .domains = $d else . end)
              | del(.pendingDeploymentId) | del(.lastError)'
            return 0
          fi
          case "$err" in
            build*) msg="The app could not be built. The build output is kept on the server." ;;
            before*) msg="The before-deploy command failed, so the new version was not switched on." ;;
            after*) msg="The after-deploy command failed. The previous version was kept." ;;
            health*|start*|create*) msg="The new version did not start or pass its health check." ;;
            route-uncertain|after-route-uncertain) msg="The app address needs recovery. Both versions were kept." ;;
            route*|router*) msg="The app address could not be switched. The previous address was kept." ;;
            *) msg="The deploy stopped (${err:-unknown})." ;;
          esac
          write_state --arg id "$1" --arg e "${err:-deploy-failed}" --arg m "$msg" --argjson t "$(now_ms)" '
            .deployments = [(.deployments // [])[] | if .id == $id then . + {status:"failed",failure:$e,message:$m,finishedAt:$t} else . end]
            | del(.pendingDeploymentId) | .lastError = $m | (if .activeDeploymentId == null then .status = "failed" else . end)'
          return 1
        }
        # A deploy left unfinished by a Mac that went away, or by this script when the server
        # restarted: record its result, or once it has gone quiet clean up after it and mark it
        # interrupted (as the Mac deployer's settle() does), so later deploys are not refused.
        settle() {
          case "$1" in "$TD_PREFIX"-deploy-*) ;; *) return 1 ;; esac
          case "$1" in *[!a-z0-9-]*) return 1 ;; esac
          "$JQ" -e --arg id "$1" 'any((.deployments // [])[]; .id == $id)' "$st" >/dev/null 2>&1 || return 1
          res="$dir/deploys/$1.result"
          if [ -f "$res" ] && grep -q '^exit=' "$res"; then
            record_result "$1" "$(val exit)" "$("$JQ" -c '.domains // []' "$st")" || true
          elif [ ! -f "$res" ] || [ -n "$(find "$res" -mmin +10 2>/dev/null)" ]; then
            if [ -f "$res" ] && [ -f "$dir/recipe.sh" ] && [ ! -L "$dir/recipe.sh" ]; then ( cd / && sh "$dir/recipe.sh" recover "$1" ) >> "$log" 2>&1; fi
            write_state --arg id "$1" --argjson t "$(now_ms)" '
              .deployments = [(.deployments // [])[] | if .id == $id then . + {status:"failed",failure:"interrupted",finishedAt:$t} else . end] | del(.pendingDeploymentId)' || return 1
            [ -L "$dir/$TD_PREFIX-builds" ] || rm -rf "$dir/$TD_PREFIX-builds/$1"
          else return 1; fi
          say "The earlier deploy $1 was left unfinished; its result is recorded."
        }

        deploy_once() {
          : > "$log"; chmod 600 "$log"
          trigger=$(printf '%s' "$1" | "$JQ" -r '.trigger // "server"' 2>/dev/null | tr -cd 'a-z')
          revision=$(printf '%s' "$1" | "$JQ" -r '.revision // ""' 2>/dev/null)
          token="server-$(td_uuid)"
          id=''; row=0; held=0; work=''
          release() {
            if [ "$held" = 1 ] && [ "$(cat "$dir/.lock/owner" 2>/dev/null)" = "$token" ]; then rm -f "$dir/.lock/owner"; rmdir "$dir/.lock"; fi
            held=0
          }
          fail() {
            say "FAILED: $1"
            if [ "$row" = 1 ]; then update_row "$("$JQ" -nc --arg e "$1" --argjson t "$(now_ms)" '{status:"failed",finishedAt:$t,error:$e}')"; printf '%s' "$id" > "$TD_DATA/check/deploy-$app"; fi
            [ -n "$work" ] && rm -rf "$work"
            release
            td_notify "deployfail:$app:${id:-early}" critical "Deploy failed for $app" "$1 The previous version keeps running." "$app"
            "$JQ" -nc --arg e "$1" '{ok:false,error:$e}'
            exit 1
          }
          trap 'release' EXIT
          trap 'exit 130' HUP INT TERM
          case "$revision" in '') ;; *) printf '%s' "$revision" | grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$' || fail "The requested revision is invalid." ;; esac
          [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$st" ] && [ ! -L "$st" ] || fail "This app is not saved on this server."
          waited=0
          while :; do
            if mkdir "$dir/.lock" 2>/dev/null; then
              held=1; printf '%s' "$token" > "$dir/.lock/owner"
              # A deploy started from the Mac runs without the lock; wait for it the same way.
              pend=$("$JQ" -r '.pendingDeploymentId // ""' "$st" 2>/dev/null)
              case "$pend" in ''|*[!a-z0-9-]*) break ;; esac
              pres="$dir/deploys/$pend.result"
              [ -f "$pres" ] && ! grep -q '^exit=' "$pres" && [ -z "$(find "$pres" -mmin +10 2>/dev/null)" ] || break
              release
            fi
            [ "$waited" -ge 600 ] && fail "Another change to this app did not finish within 10 minutes."
            sleep 10; waited=$((waited + 10))
          done
          pend=$("$JQ" -r '.pendingDeploymentId // ""' "$st" 2>/dev/null)
          [ -z "$pend" ] || settle "$pend" || fail "This app has an unfinished change that needs recovery first."
          "$JQ" -e '.kind == "app" and .pendingDeploymentId == null' "$st" >/dev/null 2>&1 || fail "This app has an unfinished change that needs recovery first."
          case "$trigger" in push|link)
            [ "$("$JQ" -r '.enabled // false' "$TD_ETC/apps/$app/autodeploy.json" 2>/dev/null)" = true ] || fail "Automatic deploys are off for this app." ;;
          esac
          [ "$("$JQ" -r '.source.kind // ""' "$st")" = github ] || fail "Only apps from a GitHub repository deploy on the server."
          repo=$("$JQ" -r '.source.repository // ""' "$st")
          printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$' || fail "The saved repository name is invalid."
          case "$repo" in */.|*/..) fail "The saved repository name is invalid." ;; esac
          branch=$("$JQ" -r '.source.branch // ""' "$st")
          [ -z "$branch" ] || { rel_ok "$branch" && case "$branch" in *@\{*) false ;; esac; } || fail "The saved branch name is invalid."
          case "$("$JQ" -r '.source.build // "auto"' "$st")" in auto|dockerfile) ;; *) fail "Compose apps deploy from the Mac app for now." ;; esac
          # The app's recipe is the only deploy path; the Mac writes it (on a deploy, a settings
          # change, or when automatic deploys are turned on).
          recipe="$dir/recipe.sh"
          [ -f "$recipe" ] && [ ! -L "$recipe" ] || fail "Deploy this app once from Terminal Deck on your Mac first. After that, pushes and deploy links deploy it on the server."
          id="$TD_PREFIX-deploy-$(td_uuid | tr -cd 'a-f0-9-')"
          tag=\#(repository):$id
          write_state --argjson row "$("$JQ" -nc --arg id "$id" --arg tag "$tag" --arg trig "$trigger" --arg rev "$revision" --argjson t "$(now_ms)" \
            '{id:$id,imageTag:$tag,status:"building",createdAt:$t,trigger:$trig} + (if $rev == "" then {} else {requestedRevision:$rev} end)')" \
            '. as $s | .deployments = (([$row] + (.deployments // [])) | sort_by(-((.createdAt | numbers) // 0))
              | .[:50] + (.[50:] | map(select(.id == $s.activeDeploymentId or .id == $s.pendingDeploymentId))))'
          row=1
          say "Deploy $id started ($trigger)."
          builds="$dir/$TD_PREFIX-builds"
          [ ! -L "$builds" ] || fail "The build folder is unsafe."
          mkdir -p "$builds" && chmod 700 "$builds"
          work="$builds/$id"; mkdir "$work" || fail "The build folder could not be created."
          export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
          gitc="-c core.hooksPath=/dev/null -c credential.helper= -c protocol.file.allow=never"
          key="$TD_ETC/apps/$app/deploy_key"
          if [ -f "$key" ]; then
            url="git@github.com:$repo.git"
            export GIT_SSH_COMMAND="ssh -i $key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$TD_OPT/github_known_hosts"
          else url="https://github.com/$repo.git"; fi
        \#(testSource)
          say "Downloading $repo${branch:+ ($branch)}."
          git $gitc clone --depth 1 --single-branch ${branch:+--branch "$branch"} -- "$url" "$work/source" >> "$log" 2>&1 \
            || fail "The repository could not be downloaded. Check the deploy key or that the repository is public."
          if [ -n "$revision" ]; then
            git -C "$work/source" $gitc fetch --depth 1 --no-tags origin "$revision" >> "$log" 2>&1 \
              && git -C "$work/source" $gitc checkout --detach "$revision" -- >> "$log" 2>&1 || fail "The pushed revision could not be downloaded."
          fi
          commit=$(git -C "$work/source" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)
          [ -z "$revision" ] || [ "$commit" = "$revision" ] || fail "The downloaded revision does not match the push."
          update_row "$("$JQ" -nc --arg c "$commit" '{commit:$c}')"
          "$JQ" -r '.domains[]? // empty' "$st" | grep -E '^[A-Za-z0-9.-]{1,253}$' > "$work/domains"
          if [ ! -s "$work/domains" ]; then
            ip=$("$JQ" -r '.publicIPv4 // ""' "$conf" 2>/dev/null)
            printf '%s' "$ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || fail "This server has no saved public address for a default web address."
            default_domain "$ip" > "$work/domains"; echo >> "$work/domains"
          fi
          domains=$("$JQ" -Rsc 'split("\n") | map(select(length > 0))' "$work/domains")
          first=$(printf '%s' "$domains" | "$JQ" -r '.[0]')
          prevcid=$("$JQ" -r '.containerId // ""' "$st")
          say "Running the app's deploy recipe."
          # The result file exists before the deploy is marked pending, so settle() can tell
          # a running recipe (kept fresh) from one that died with the server.
          res="$dir/deploys/$id.result"
          mkdir -p "$dir/deploys" && chmod 700 "$dir/deploys" && : > "$res" || fail "The deploy could not be started on the server."
          write_state --arg id "$id" '.pendingDeploymentId = $id'
          ( cd / && env TD_DEPLOYMENT="$id" TD_SOURCE="$work/source" TD_PREVIOUS="$prevcid" sh "$recipe" deploy ) >> "$log" 2>&1
          code=$?
          if record_result "$id" "$code" "$domains"; then
            rm -rf "$work"; work=''
            release
            say "Deploy $id is live at https://$first."
            td_notify --resolve "route:$app"
            "$JQ" -nc --arg id "$id" --arg c "$commit" --arg a "https://$first" '{ok:true,deploymentId:$id,commit:$c,address:$a,recipe:true}'
            exit 0
          fi
          row=0; printf '%s' "$id" > "$TD_DATA/check/deploy-$app"
          fail "$msg"
        }

        rc=0; runs=0
        while [ "$runs" -lt 3 ]; do
          runs=$((runs + 1)); request='{"trigger":"server"}'
          if [ -f "$queue" ]; then mv -f "$queue" "$queue.taken" 2>/dev/null && request=$(head -c 4096 "$queue.taken"); rm -f "$queue.taken"
          elif [ "$runs" -gt 1 ]; then break; fi
          ( deploy_once "$request" ); rc=$?
          [ -f "$queue" ] || break
        done
        exit "$rc"

        """#
    }

    /// One HTTP request per connection (systemd Accept=yes) on 127.0.0.1,
    /// reached through the address manager. GitHub HMAC or a per-app token;
    /// it only queues a deploy and starts the systemd unit. Nothing is eval'd.
    public static func hook(_ layout: BackendAppsServerLayout) -> String {
        BackendAppsServerScripts.header(layout) + ". \(BackendAppsRuntime.quote(layout.bin + "/td-lib.sh"))\n" + #"""
        cr=$(printf '\r')
        respond() {
          printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n%s' "$1" "${#2}" "$2"
          exit 0
        }
        IFS= read -r line || exit 0
        line=${line%"$cr"}
        method=${line%% *}; rest=${line#* }; target=${rest%% *}
        [ "${#target}" -le 512 ] || respond '414 URI Too Long' '{"error":"target"}'
        len=''; sig=''; event=''; delivery=''; auth=''; count=0; seen=''
        while IFS= read -r h; do
          h=${h%"$cr"}
          [ -z "$h" ] && break
          count=$((count + 1)); [ "$count" -le 100 ] || respond '431 Request Header Fields Too Large' '{"error":"headers"}'
          name=$(printf '%s' "${h%%:*}" | tr 'A-Z' 'a-z'); value=${h#*:}; value=${value# }
          case "$name" in content-length|x-hub-signature-256|x-github-event|x-github-delivery|authorization)
            case " $seen " in *" $name "*) respond '400 Bad Request' '{"error":"duplicate header"}' ;; esac
            seen="$seen $name" ;;
          esac
          case "$name" in
            content-length) len=$value ;;
            x-hub-signature-256) sig=$value ;;
            x-github-event) event=$value ;;
            x-github-delivery) delivery=$value ;;
            authorization) auth=$value ;;
          esac
        done
        path=${target%%\?*}; query=''
        case "$target" in *\?*) query=${target#*\?} ;; esac
        if [ "$method" = GET ] && [ "$path" = /health ]; then respond '200 OK' '{"ok":true}'; fi
        [ "$method" = POST ] || respond '405 Method Not Allowed' '{"error":"method"}'
        case "$len" in ''|*[!0-9]*) respond '411 Length Required' '{"error":"length"}' ;; esac
        [ "${#len}" -le 8 ] && [ "$len" -le 4194304 ] || respond '413 Payload Too Large' '{"error":"size"}'
        case "$path" in
          /hooks/github/*) kind=github; app=${path#/hooks/github/} ;;
          /deploy/*) kind=link; app=${path#/deploy/} ;;
          *) respond '404 Not Found' '{"error":"not found"}' ;;
        esac
        td_valid_id "$app" || respond '404 Not Found' '{"error":"not found"}'
        secrets="$TD_ETC/apps/$app"
        [ "$("$JQ" -r '.enabled // false' "$secrets/autodeploy.json" 2>/dev/null)" = true ] || respond '404 Not Found' '{"error":"not found"}'
        w=$(td_tmpdir) || respond '503 Service Unavailable' '{"error":"busy"}'
        trap 'rm -rf "$w"' EXIT
        if [ "$len" -gt 0 ]; then head -c "$len" > "$w/body"; else : > "$w/body"; fi
        [ "$(wc -c < "$w/body" | tr -d ' ')" = "$len" ] || respond '400 Bad Request' '{"error":"body"}'
        revision=''
        if [ "$kind" = github ]; then
          [ -f "$secrets/hook-secret" ] || respond '404 Not Found' '{"error":"not found"}'
          case "$sig" in sha256=*) sig=${sig#sha256=} ;; *) respond '401 Unauthorized' '{"error":"signature"}' ;; esac
          printf '%s' "$sig" | grep -Eq '^[0-9a-f]{64}$' || respond '401 Unauthorized' '{"error":"signature"}'
          [ "$(td_hmac_sha256 "$secrets/hook-secret" "$w/body")" = "$sig" ] || respond '401 Unauthorized' '{"error":"signature"}'
          printf '%s' "$delivery" | grep -Eq '^[0-9A-Za-z-]{8,64}$' || respond '400 Bad Request' '{"error":"delivery"}'
          ledger="$TD_DATA/hook-deliveries"
          if grep -qxF "$delivery" "$ledger" 2>/dev/null; then respond '200 OK' '{"ok":true,"duplicate":true}'; fi
          printf '%s\n' "$delivery" >> "$ledger"; tail -n 1000 "$ledger" > "$w/l" && cat "$w/l" > "$ledger"
          case "$event" in ping) respond '200 OK' '{"ok":true,"ping":true}' ;; push) ;; *) respond '202 Accepted' '{"ok":true,"ignored":"event"}' ;; esac
          "$JQ" -e 'type == "object"' "$w/body" >/dev/null 2>&1 || respond '400 Bad Request' '{"error":"json"}'
          [ "$("$JQ" -r '.deleted // false' "$w/body")" = true ] && respond '202 Accepted' '{"ok":true,"ignored":"deleted"}'
          repo=$("$JQ" -r '.repository.full_name // ""' "$w/body" | tr 'A-Z' 'a-z')
          saved=$("$JQ" -r '.source.repository // ""' "$TD_STATE/$app/state.json" 2>/dev/null | tr 'A-Z' 'a-z')
          [ -n "$repo" ] && [ "$repo" = "$saved" ] || respond '202 Accepted' '{"ok":true,"ignored":"repository"}'
          branch=$("$JQ" -r '.source.branch // ""' "$TD_STATE/$app/state.json" 2>/dev/null)
          [ -n "$branch" ] || branch=$("$JQ" -r '.repository.default_branch // ""' "$w/body")
          [ "$("$JQ" -r '.ref // ""' "$w/body")" = "refs/heads/$branch" ] || respond '202 Accepted' '{"ok":true,"ignored":"branch"}'
          revision=$("$JQ" -r '.after // ""' "$w/body")
          printf '%s' "$revision" | grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$' || respond '202 Accepted' '{"ok":true,"ignored":"revision"}'
          printf '%s' "$revision" | grep -Eq '^0+$' && respond '202 Accepted' '{"ok":true,"ignored":"revision"}'
        else
          # The header only: a key in the web address would land in access and CI logs.
          tok=''
          case "$auth" in "Bearer "*) tok=${auth#Bearer } ;; esac
          printf '%s' "$tok" | grep -Eq '^[A-Za-z0-9_-]{20,128}$' || respond '401 Unauthorized' '{"error":"token"}'
          [ -f "$secrets/deploy-token.sha256" ] || respond '401 Unauthorized' '{"error":"token"}'
          [ "$(printf '%s' "$tok" | sha256sum | cut -c1-64)" = "$(head -c 64 "$secrets/deploy-token.sha256")" ] || respond '401 Unauthorized' '{"error":"token"}'
          for kv in $(printf '%s' "$query" | tr '&' ' '); do case "$kv" in revision=*) revision=${kv#revision=} ;; esac; done
          [ -z "$revision" ] || printf '%s' "$revision" | grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$' || respond '400 Bad Request' '{"error":"revision"}'
        fi
        mkdir -p "$TD_DATA/deploy-queue"
        "$JQ" -nc --arg t "$kind" --arg r "$revision" --argjson at "$(td_now)" '{trigger:(if $t == "github" then "push" else "link" end), requestedAt:$at} + (if $r == "" then {} else {revision:$r} end)' > "$w/q"
        mv -f "$w/q" "$TD_DATA/deploy-queue/$app.json"
        systemctl start --no-block "$TD_BASE-deploy@$app.service" >/dev/null 2>&1 || respond '503 Service Unavailable' '{"error":"deploy unavailable"}'
        echo "deploy queued for $app ($kind)" >&2
        respond '202 Accepted' '{"ok":true,"queued":true}'

        """#
    }
}
