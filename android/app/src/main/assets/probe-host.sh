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