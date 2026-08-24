AW="$PATH"
for d in "$HOME/.local/bin" "$HOME/bin" "$HOME/.terminaldeck/runtime/bin" \
         "$HOME/.npm-global/bin" /usr/local/bin /opt/homebrew/bin /snap/bin; do
  [ -d "$d" ] && AW="$AW:$d"
done
p() { printf "%s\t%s\n" "$1" "$2"; }
have() { PATH="$AW" command -v "$1" >/dev/null 2>&1; }

p os "$(uname -s 2>/dev/null)"
p arch "$(uname -m 2>/dev/null)"
LIBC=gnu
if (ldd --version 2>&1 || true) | grep -qi musl; then LIBC=musl
elif ls /lib/ld-musl-* >/dev/null 2>&1; then LIBC=musl; fi
p libc "$LIBC"

p node "$(PATH="$AW" node --version 2>/dev/null)"
p npm "$(PATH="$AW" command -v npm 2>/dev/null)"
MISS=
have python3 || have python || MISS="$MISS python3"
have make || MISS="$MISS make"
have cc || have gcc || have clang || MISS="$MISS gcc"
have c++ || have g++ || have clang++ || MISS="$MISS g++"
p tools "$MISS"
FETCH=
for f in curl wget; do have "$f" && { FETCH=$f; break; }; done
p fetch "$FETCH"
HASH=
for h in sha256sum shasum openssl; do have "$h" && { HASH=$h; break; }; done
p hash "$HASH"
have tar && p tar yes
p home_free_kb "$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"

# The state folder, XDG first, because that is what the host itself reads.
SD="${XDG_DATA_HOME:-$HOME/.local/share}/terminaldeck"
p state_dir "$SD"
[ -d "$SD" ] && p state yes

# Whether a session on this box could be **held inside the folder it was
# granted** — which is a different question from whether the host will install,
# and the one nobody was asking. A box with no `unshare`, or one whose kernel
# refuses an unprivileged user namespace, takes the install perfectly and then
# throws ConfinementUnavailableError at every session, because `confineSpawn`
# will not pretend a boundary it cannot build. That is an install that looks
# like a success and is a dead end, which is the shape this whole flow exists to
# stop.
#
# Asked by opening the namespace rather than by reading a kernel version, for
# the reason `confine/index.ts` gives about its own proof: the machine can
# change its mind — apparmor_restrict_unprivileged_userns is a sysctl — and a
# version number never knew the answer in the first place. The two sysctls below
# are read only to say *why* after the attempt has already failed, so a person
# gets the machine's own reason rather than "it did not work".
CONF=
CONFWHY=
case "$(uname -s 2>/dev/null)" in
  Linux)
    if ! have unshare; then
      CONFWHY="it has no unshare, which is the util-linux package"
    elif ! have setpriv; then
      CONFWHY="it has no setpriv, which is the util-linux package"
    elif PATH="$AW" unshare --user --map-root-user --mount true >/dev/null 2>&1; then
      CONF=yes
    elif [ "$(cat /proc/sys/user/max_user_namespaces 2>/dev/null)" = 0 ]; then
      CONFWHY="user namespaces are switched off on it (user.max_user_namespaces is 0)"
    elif [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = 1 ]; then
      CONFWHY="its kernel restricts unprivileged user namespaces (apparmor_restrict_unprivileged_userns is 1)"
    else
      CONFWHY="this account cannot open a user namespace on it"
    fi ;;
  Darwin)
    if [ -x /usr/bin/sandbox-exec ]; then CONF=yes; else CONFWHY="it has no sandbox-exec"; fi ;;
esac
p confine "$CONF"
p confine_why "$CONFWHY"

systemctl --user is-system-running >/dev/null 2>&1 && p systemd_user yes
# The unit *file*, not just `is-active`. Measured on a real box: asking
# `is-active` about a unit that does not exist answers "inactive" — so a
# server with no unit of ours and a server whose unit is stopped were
# indistinguishable, and `reachLine` would have claimed the first one starts
# with the machine.
if [ -f "$HOME/.config/systemd/user/terminaldeck.service" ]; then
  p unit "$(systemctl --user is-active terminaldeck.service 2>/dev/null)"
fi
[ "$(loginctl show-user "$(id -u)" -p Linger --value 2>/dev/null)" = yes ] && p linger yes

B=$(PATH="$AW" command -v terminaldeck 2>/dev/null)
p command "$B"
if [ -n "$B" ]; then
  p version "$(PATH="$AW" "$B" --version 2>/dev/null | head -n 1)"
  # The whole answer, verbatim. The running/not-running verdict is decided on
  # the other side rather than grepped here — see readHostProbe.
  printf "%s\n" "--- status ---"
  PATH="$AW" "$B" status 2>&1 | head -n 60
fi
exit 0