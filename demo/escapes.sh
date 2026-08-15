#!/usr/bin/env bash
#
# The escape table, run against a live container rather than against a comment.
#
# CONFINEMENT.md rule 2: *"Test the escapes, not the happy path."* Every row in
# its measured table is here, plus the rows that table does not have because it
# was written about a granted folder on a machine somebody owns, and this is an
# anonymous stranger on a machine nobody does.
#
# It starts a container with **the flags the broker uses** — read out of
# `broker.mjs --print-run-flags`, so this cannot drift into measuring a container
# nobody runs — and then runs each attempt through the same
# `/usr/local/bin/demo-shell` a real session runs through. The shell is
# interactive `bash` reading its commands from stdin, which is what `docker exec
# -i` gives it; nothing here is a parallel implementation of the confinement.
#
#   ./demo/escapes.sh            start a container, measure, remove it
#   ./demo/escapes.sh <name>     measure a container that is already running
#
# Run it on the demo box. It needs Docker and it needs the image built.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${DEMO_IMAGE:-terminaldeck-demo:latest}"
NAME="${1:-}"
OWNED=0
PASS=0
FAIL=0

cleanup() {
  if [ "$OWNED" = "1" ] && [ -n "$NAME" ]; then docker kill "$NAME" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

if [ -z "$NAME" ]; then
  NAME="td-escapes-$$"
  OWNED=1
  mapfile -t FLAGS < <(DEMO_IMAGE="$IMAGE" node "$HERE/broker/broker.mjs" --print-run-flags)
  # The flags come out with a literal NAME placeholder where the container's
  # name goes, because they are printed by the same function that starts a real
  # one and that function takes the name as an argument.
  ARGS=()
  for flag in "${FLAGS[@]}"; do
    if [ "$flag" = "NAME" ]; then ARGS+=("$NAME"); else ARGS+=("$flag"); fi
  done
  echo "starting a container with the broker's own flags…"
  docker "${ARGS[@]}" >/tmp/escapes-$$.log 2>&1 &
  for _ in $(seq 1 60); do
    if docker exec "$NAME" true >/dev/null 2>&1; then break; fi
    sleep 1
  done
  if ! docker exec "$NAME" true >/dev/null 2>&1; then
    echo "the container never came up. Its output:"
    cat "/tmp/escapes-$$.log"
    exit 1
  fi
fi

# ---------------------------------------------------------------- the runner --

# One attempt, run the way a session runs: through `demo-shell`, as the visitor,
# in the mount namespace it builds. `-i` on the shell means bash reads the script
# from stdin, so this is the production path with a pipe where a phone would be.
# The `» ` prefix is not decoration and the whole suite was wrong without it.
#
# `demo-shell` execs an *interactive* bash, which is the point — it is the shell
# a session gets — and an interactive bash echoes each command it reads back to
# the terminal. So the first honest-looking run scored `echo REACHED || echo
# blocked` as a network escape: the word was in the echoed command line, not in
# any output. Piping the attempt through `sed` prefixes everything the attempt
# *printed* and nothing the shell merely repeated, because the echo is written by
# readline rather than through the pipeline.
#
# `set +m` turns off job control, which an interactive shell on a pipe otherwise
# complains about on every command with "tcsetattr: Inappropriate ioctl".
visitor() {
  printf '%s\n' 'set +m' 'echo __CONFINED_SHELL_UP__' "{ $1 ; } 2>&1 | sed 's/^/» /'" \
    | docker exec -i -e TERM=dumb "$NAME" /usr/local/bin/demo-shell -l 2>&1
}

# `expect_absent` — the attempt must NOT produce the marker. That is the shape
# every escape test wants: a boundary is proven by what did not come back.
#
# The marker check in front of it is the more important half and it was added
# after a real failure: `demo-shell` could not build its mount namespace, exited
# before running anything, and sixteen escape tests reported *held* because
# nothing had happened. A suite that scores silence as safety is worse than no
# suite, so a run whose shell did not start is a failure of that test, loudly.
check() {
  local title="$1" script="$2" pattern="$3" mode="${4:-absent}"
  local out
  out="$(visitor "$script")"
  if ! grep -q '__CONFINED_SHELL_UP__' <<<"$out"; then
    FAIL=$((FAIL + 1))
    printf '  \033[31mNO SHELL\033[0m %s\n' "$title"
    printf '         %s\n' "$(tr '\n' '|' <<<"$out" | cut -c1-300)"
    return
  fi
  # Only what the attempt printed. Everything else on that stream is the motd a
  # real visitor sees and the shell's own echo of the command it was given, and
  # both contain the words these patterns are looking for.
  out="$(grep '^» ' <<<"$out" | sed 's/^» //')"
  local hit=0
  grep -qE "$pattern" <<<"$out" && hit=1
  if { [ "$mode" = "absent" ] && [ "$hit" = "0" ]; } || { [ "$mode" = "present" ] && [ "$hit" = "1" ]; }; then
    PASS=$((PASS + 1))
    printf '  \033[32mheld\033[0m   %s\n' "$title"
  else
    FAIL=$((FAIL + 1))
    printf '  \033[31mESCAPE\033[0m %s\n' "$title"
    printf '         %s\n' "$(tr '\n' '|' <<<"$out" | cut -c1-300)"
  fi
}

echo
echo "CONFINEMENT.md's measured table"

# The one that was an ESCAPE on WSL without dropped capabilities. It is the whole
# reason `setpriv --bounding-set=-all --inh-caps=-all` is in `demo-shell`.
check "umount /home is refused" \
  'umount /home 2>&1; ls /home' \
  'ESCAPED-VISIBLE|root' absent

check "umount /home leaves the tmpfs in place" \
  'umount /home >/dev/null 2>&1; ls /home' \
  '^visitor$' present

# The escape a stranger reaches for second: regain CAP_SYS_ADMIN in a nested
# namespace and then undo the mounts.
check "a nested user namespace is refused" \
  'unshare --user --map-root-user --mount sh -c "echo NESTED-OK" 2>&1' \
  'NESTED-OK' absent

# On WSL this depended on PID 1 being another uid. Here it is the demo host,
# running as the container's root, and the visitor is 1001 — plus the shell is
# PID 1 of its own namespace, so there is no other process to reach at all.
# A denial is the wanted answer here, so the pattern names what must NOT come
# back — the host's state — rather than the refusal, which is the pass.
check "/proc/1/root does not lead to the host's own files" \
  'ls -a /proc/1/root/root /proc/1/root/root/.local 2>&1' \
  'terminaldeck|host\.json' absent

check "the host process is not even visible in /proc" \
  'ls /proc | grep -cE "^[0-9]+$"' \
  '^[1-5]$' present

check "a symlink out of the playground resolves to nothing" \
  'ln -sfn /root ~/escape 2>/dev/null; ls ~/escape/ 2>&1' \
  '\.local|host\.json' absent

check "an absolute path to the host's home is refused" \
  'ls -la /root 2>&1' \
  'host\.json|\.local' absent

# /mnt/c is a WSL row and cannot apply on a VPS. Asserted anyway, because the
# cheapest way for a table to rot is for a row to stop being checked.
check "there is no WSL interop path to a Windows binary" \
  'ls /mnt/c 2>&1' \
  'Windows|System32' absent

echo
echo "The rows that table does not have"

# The sharpest one. The daemon keeps a 0600 control token beside a 0700 state
# directory and spawns sessions as the same uid, so on a machine you own a
# session can drive the control socket and grant itself every folder. Here it
# cannot, because the session is a different uid inside a namespace where that
# path is not present.
check "the host's control token cannot be read" \
  'cat /root/.local/share/terminaldeck/host.json 2>&1; find / -name host.json -readable 2>/dev/null | head -3' \
  '"token"' absent

check "the host's control socket cannot be reached" \
  'ls /root/.local/share/terminaldeck/host.sock 2>&1' \
  'host\.sock$' absent

check "the visitor holds no capabilities at all" \
  'grep -E "^Cap(Eff|Bnd|Prm|Inh)" /proc/self/status' \
  'Cap(Eff|Bnd|Prm|Inh):\s+0000000000000000\s*$' present

check "the root filesystem is read-only" \
  'touch /etc/escaped 2>&1; touch /usr/local/bin/escaped 2>&1' \
  'Read-only file system' present

check "there is no Docker socket to escalate through" \
  'ls -la /var/run/docker.sock 2>&1' \
  'docker\.sock$' absent

check "the visitor is not root" \
  'id -u' \
  '^0$' absent

check "the demo host's own program is not writable" \
  'echo x >> /opt/terminaldeck/demo.mjs 2>&1' \
  'Read-only file system|Permission denied' present

echo
echo "Egress — the danger the filesystem table says nothing about"

check "the relay is reachable, because the session depends on it" \
  'timeout 8 bash -c "exec 3<>/dev/tcp/relay.terminaldeck.dev/443" && echo RELAY-OK' \
  'RELAY-OK' present

check "an unrelated host on the internet is not reachable" \
  'timeout 6 bash -c "exec 3<>/dev/tcp/1.1.1.1/443" && echo OPENED || echo shut' \
  'OPENED' absent

check "github is not reachable, so git clone cannot work" \
  'timeout 8 bash -c "exec 3<>/dev/tcp/github.com/443" && echo OPENED || echo shut' \
  'OPENED' absent

check "the relay box's ssh port is not reachable" \
  'timeout 6 bash -c "exec 3<>/dev/tcp/178.105.248.86/22" && echo OPENED || echo shut' \
  'OPENED' absent

# The bridge gateway is the demo box itself, and 8787 is the broker — which
# hands out containers. A visitor who could reach it could ask for more.
check "the broker on the demo box is not reachable from inside" \
  'timeout 6 bash -c "exec 3<>/dev/tcp/172.31.240.1/8787" && echo OPENED || echo shut' \
  'OPENED' absent

echo
echo "Breaking it, which is the case the container shape exists for"

check "the disk cannot be filled past the tmpfs cap" \
  'dd if=/dev/zero of=$HOME/playground/fill bs=1M count=512 >/dev/null 2>&1; s=$(stat -c %s $HOME/playground/fill 2>/dev/null || echo 0); [ "$s" -lt 40000000 ] && echo BOUNDED-$s || echo UNBOUNDED-$s' \
  'BOUNDED-' present

# Scored from outside, and it has to be.
#
# A fork bomb that works takes the shell down with it, so the attempt cannot
# report its own result: the honest question is not "what did the visitor see"
# but "was the machine still there afterwards". `--pids-limit` is what makes the
# answer yes, and the broker answering is the proof that the box, not just the
# container, survived.
printf '  ...forking as hard as the container allows\n'
visitor 'for i in $(seq 1 600); do sleep 20 & done' >/dev/null 2>&1 || true
sleep 2
alive="$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)"
broker="$(curl -fsS --max-time 5 localhost:8787/healthz 2>/dev/null || echo '')"
if [ "$alive" = "true" ] && [ -n "$broker" ]; then
  PASS=$((PASS + 1))
  printf '  \033[32mheld\033[0m   a fork bomb leaves the container and the box standing\n'
else
  FAIL=$((FAIL + 1))
  printf '  \033[31mESCAPE\033[0m a fork bomb leaves the container and the box standing\n'
  printf '         container running=%s, broker said %s\n' "$alive" "${broker:-nothing}"
fi

echo
printf '\n%s held, %s escaped\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
