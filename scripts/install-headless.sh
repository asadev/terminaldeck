#!/bin/sh
# Terminal Deck — headless host installer.
#
#     curl -fsSL https://terminaldeck.dev/install.sh | sh
#
# What this is, and what it deliberately is not.
#
# It is a wrapper around `npm install -g terminaldeck`, and that is not a
# cop-out — it is the honest shape of the problem. Sessions are real pseudo
# terminals, so `node-pty` is a native module, and something has to put the right
# prebuilt binary on this machine. npm already does that correctly for every
# platform, architecture and libc this could land on. A hand-rolled installer
# that downloaded a tarball would have to redo that decision, get it wrong on
# Alpine, and be the thing standing between somebody and a working host.
#
# That argument is about the *package*. It never said anything about the
# *runtime*, and for a while this script behaved as though it did: no Node, no
# install, here is a sentence, goodbye. Measured on the owner's own server on
# 2026-08-18 — aarch64, Ubuntu 24.04.4, glibc 2.39 — that box had no node and no
# npm, so the one machine this feature was built against was the one machine it
# could not be installed on. A rented Linux server having no Node is not the
# user's mistake; it is what a rented Linux server looks like on day one.
#
# So when Node is missing or too old, this fetches an official Node build into a
# private prefix of its own (`~/.terminaldeck/runtime`), verifies it against the
# `SHASUMS256.txt` the Node project publishes beside it, and runs the same
# `npm install -g` using that node and npm. Nothing is written to /usr, nothing
# runs as root, nothing is put on anybody's PATH behind their back, and a machine
# that already has a good Node downloads none of it and behaves exactly as
# before. `rm -rf ~/.terminaldeck` undoes the whole thing.
#
# What it adds over typing the npm line yourself:
#
#   - it refuses early, with a sentence, when the machine genuinely cannot take
#     this — musl, an architecture Node does not build for, no C++ toolchain for
#     node-pty — rather than letting npm fail halfway through a native build;
#   - it supplies the Node runtime itself when there is none, instead of handing
#     back a homework assignment;
#   - it installs into a user prefix when the global one is not writable,
#     instead of telling you to re-run the whole thing under sudo;
#   - it says what to do next, which on a server is the part people get wrong —
#     a host installed and never started is indistinguishable from a broken one
#     when you are looking at a phone in another country;
#   - and it names the two util-linux tools a confined session is built out of,
#     when they are not here, because a box without them installs perfectly and
#     then refuses every session a device starts.
#
# POSIX sh, no bashisms: this runs on whatever /bin/sh a minimal server image
# ships, which is dash as often as not. No `local`, no `[[`, no arrays, no
# `pipefail` — every one of those is a silent behaviour change under dash.
#
# Environment, all optional:
#
#   TERMINALDECK_VERSION          npm version/tag to install (default: latest)
#   TERMINALDECK_PACKAGE          what to hand npm instead (a path to a tarball)
#   TERMINALDECK_DRYRUN=1         print the plan and exit; writes nothing
#   TERMINALDECK_NO_RUNTIME=1     never fetch Node; refuse instead (old behaviour)
#   TERMINALDECK_FORCE_RUNTIME=1  always use the private runtime, even if this
#                                 machine has a good Node
#   TERMINALDECK_RUNTIME          where the private runtime goes
#   TERMINALDECK_NODE_VERSION     pin it, e.g. 22.23.2
#   TERMINALDECK_NODE_LINE        release directory to track (default latest-v22.x)
#   TERMINALDECK_NODE_MIRROR      base URL for Node downloads
#   TERMINALDECK_OS / _ARCH / _LIBC   override detection (the tests use these)
#   TERMINALDECK_SKIP_TOOLCHAIN_CHECK=1   skip the node-pty build-tools check

set -eu

# `terminaldeck` from the registry, unless something else is named. A local
# tarball is a real case — a server with no route to npmjs.org, or a build being
# tried before it is published — and it is also the only way to test the second
# half of this script without publishing to prove it.
PACKAGE_SPEC="${TERMINALDECK_PACKAGE:-}"
PACKAGE="terminaldeck"
VERSION="${TERMINALDECK_VERSION:-latest}"
[ -n "$PACKAGE_SPEC" ] || PACKAGE_SPEC="${PACKAGE}@${VERSION}"
MIN_NODE_MAJOR=22

# The Node line the private runtime tracks.
#
# `latest-v22.x` is a directory the Node project keeps pointing at the newest
# 22.x release, and its SHASUMS256.txt names the version *inside the filenames*.
# So one 4 KB fetch answers both "which version" and "what must it hash to",
# with no JSON parsing in POSIX sh — which is the kind of thing that looks fine
# until a field moves and the installer starts downloading the string "null".
#
# 22 rather than the newest line at all, because that is what `engines` says and
# because native modules get prebuilds for LTS ABIs first.
NODE_LINE="${TERMINALDECK_NODE_LINE:-latest-v22.x}"
NODE_MIRROR="${TERMINALDECK_NODE_MIRROR:-https://nodejs.org/dist}"
NODE_PINNED="${TERMINALDECK_NODE_VERSION:-}"

DRYRUN="${TERMINALDECK_DRYRUN:-}"
NO_RUNTIME="${TERMINALDECK_NO_RUNTIME:-}"
FORCE_RUNTIME="${TERMINALDECK_FORCE_RUNTIME:-}"
SKIP_TOOLCHAIN="${TERMINALDECK_SKIP_TOOLCHAIN_CHECK:-}"

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -n "${HOME:-}" ] || die "HOME is not set, so there is nowhere to put a user install.
Run this as a normal user with a home directory, not from a bare service context."

RUNTIME="${TERMINALDECK_RUNTIME:-$HOME/.terminaldeck/runtime}"
LAUNCHER_DIR="$HOME/.local/bin"

# Upgrading the private runtime means replacing that directory, so this script
# contains an `rm -rf "$RUNTIME"` — and $RUNTIME can be set from the environment.
# A typo that expands to `/` or to a home directory would be this script wiping a
# machine, which is not a thing to leave to whoever writes the env line.
#
# Two rules, and they are deliberately narrow. Requiring at least two path
# components rules out `/` and every top-level directory — /usr, /var, /etc — in
# one line. The named list is only the handful of two-component directories whose
# loss would be as bad. Anything else the person names is a directory they chose,
# including one under /var or /opt, and refusing those was the first version of
# this check: it rejected the temporary homes the tests run in, which is how a
# guard teaches people to work around it.
case "$RUNTIME" in
  /*/?*) ;;
  *) die "TERMINALDECK_RUNTIME has to be an absolute path with a directory of its own (got '$RUNTIME')." ;;
esac
case "$RUNTIME" in
  "$HOME" | /usr/local | /usr/bin | /usr/lib | /usr/sbin | /usr/share | /var/lib | /var/log | /etc/*)
    die "TERMINALDECK_RUNTIME points at '$RUNTIME', and this replaces that whole directory when
it installs or upgrades Node. Give it somewhere of its own."
    ;;
esac

# The PATH the person actually has, kept before this process puts the private
# runtime in front of it. The closing "add this to your PATH" advice has to be
# answered about their shell, not about this script's environment — otherwise the
# runtime install always looks like it is already on PATH and never says the one
# thing that makes the command work tomorrow.
ORIGINAL_PATH="$PATH"

# ------------------------------------------------------------- this machine --

# Node's build matrix is keyed on three things and each one has a wrong answer
# that fails later rather than here: the OS name, the architecture *as Node
# spells it* (aarch64 is arm64 to Node, x86_64 is x64), and the C library.
detect_platform() {
  os_raw="${TERMINALDECK_OS:-$(uname -s)}"
  case "$os_raw" in
    Linux | linux) OS=linux ;;
    Darwin | darwin) OS=darwin ;;
    *)
      die "This installs the headless host, which is a Linux and macOS thing, and this is '$os_raw'.
On Windows install the desktop app from https://terminaldeck.dev instead."
      ;;
  esac

  arch_raw="${TERMINALDECK_ARCH:-$(uname -m)}"
  case "$arch_raw" in
    x86_64 | amd64) ARCH=x64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    armv7l | armv7 | armhf) ARCH=armv7l ;;
    ppc64le) ARCH=ppc64le ;;
    s390x) ARCH=s390x ;;
    *)
      die "Unrecognised architecture '$arch_raw', so there is no Node build to ask for.
If Node runs here, install it yourself and run this again — it only needs 22 or newer on PATH."
      ;;
  esac

  # musl vs glibc. Node's own downloads page has no musl build at all, so on
  # Alpine every one of those URLs is a glibc binary that unpacks perfectly and
  # then dies with "not found" (which is the loader missing, not the file).
  # Detect it before building a URL, not after running one.
  #
  # `ldd --version` is the reliable probe: GNU's prints "ldd (GNU libc) 2.39" and
  # exits 0, musl's prints "musl libc (aarch64)" and exits 1 — hence 2>&1 and the
  # `|| true`, and hence doing it inside an `if`, where errexit is suspended.
  # The loader-file check is the fallback for a musl box with no `ldd` shim.
  LIBC=gnu
  if [ -n "${TERMINALDECK_LIBC:-}" ]; then
    LIBC="$TERMINALDECK_LIBC"
  elif [ "$OS" = linux ]; then
    if (ldd --version 2>&1 || true) | grep -qi musl; then
      LIBC=musl
    elif ls /lib/ld-musl-* >/dev/null 2>&1; then
      LIBC=musl
    fi
  else
    LIBC=libsystem
  fi
}

describe_machine() {
  if [ "$OS" = linux ]; then
    printf '%s %s (%s)' "$OS" "$ARCH" "$LIBC"
  else
    printf '%s %s' "$OS" "$ARCH"
  fi
}

# --------------------------------------------------- what node-pty will need --

# Checked against the published package on 2026-08-18: node-pty 1.1.0's npm
# tarball carries prebuilds for darwin-arm64, darwin-x64, win32-arm64 and
# win32-x64 — and nothing for Linux. Its install script is
# `node scripts/prebuild.js || node-gyp rebuild`, so on every Linux box the
# second half runs and a compiler has to exist. On a minimal server image it
# does not, and the failure arrives as a wall of node-gyp output ending in
# "gyp ERR! find Python", which reads like a bug in this project.
#
# So it is checked here, before anything is downloaded or written, and named as
# packages a person can install. If node-pty ever ships Linux prebuilds this
# check becomes a false refusal — hence the documented way past it.
check_native_toolchain() {
  [ "$OS" = linux ] || return 0
  [ -z "$SKIP_TOOLCHAIN" ] || return 0

  missing=""
  have python3 || have python || missing="$missing python3"
  have make || missing="$missing make"
  have cc || have gcc || have clang || missing="$missing gcc"
  have c++ || have g++ || have clang++ || missing="$missing g++"

  [ -n "$missing" ] || return 0

  hint="sudo apt-get install -y python3 make g++"
  if have apk; then
    hint="sudo apk add --no-cache python3 make g++"
  elif have dnf; then
    hint="sudo dnf install -y python3 make gcc-c++"
  elif have yum; then
    hint="sudo yum install -y python3 make gcc-c++"
  elif have pacman; then
    hint="sudo pacman -S --needed python make gcc"
  elif have zypper; then
    hint="sudo zypper install -y python3 make gcc-c++"
  fi

  die "Missing the build tools node-pty needs on Linux:$missing

Sessions are real pseudo terminals, so node-pty is a native module, and its
published package has prebuilt binaries for macOS and Windows only — on Linux it
compiles itself during \`npm install\`. Without a compiler that fails a minute
in, with node-gyp output that looks like this project is broken.

Install them and run this again:

    $hint

Nothing has been written to this machine.
(If node-pty has since started shipping Linux prebuilds, TERMINALDECK_SKIP_TOOLCHAIN_CHECK=1 goes past this.)"
}

# ----------------------------------------------- what confinement will need --

# `unshare` and `setpriv`, which are what actually hold a session inside its
# folder on this machine.
#
# `src/main/confine/linux.ts` builds the boundary out of an unprivileged user
# namespace: `unshare` makes the namespace, a handful of mounts cover the trees
# holding the account's secrets, and `setpriv --bounding-set=-all` throws away
# the capabilities that would let the session mount them back. Both are
# util-linux, both are on essentially every distribution, and both are absent
# often enough on a minimal image to be worth one `command -v` each.
#
# ## Why this warns and does not refuse, unlike the check above it
#
# They are different failures with different costs. Without a compiler,
# `npm install` dies half way through and there is no install at all — so
# refusing before anything is written is strictly better than letting it start.
# Without these two the install is fine and the host runs; what breaks is one
# thing, loudly and safely: a session started from a device is *refused* rather
# than started outside its folder, because `confineSpawn` throws rather than
# falling back. Nothing is quietly less protected. Refusing the whole install
# over it would mean somebody who only wants to attach to sessions from their
# phone cannot install at all, and the fix here does not need the installer
# re-run — one package, and the next session is held.
#
# So it is said at the end, beside the other "this works, and this machine needs
# one more thing" lines, rather than shouted from the middle of a scroll nobody
# reads on a `curl | sh`.
check_confine_tools() {
  [ "$OS" = linux ] || return 0

  confine_missing=""
  have unshare || confine_missing="$confine_missing unshare"
  have setpriv || confine_missing="$confine_missing setpriv"
  [ -n "$confine_missing" ] || return 0

  confine_hint="sudo apt-get install -y util-linux"
  if have apk; then
    confine_hint="sudo apk add --no-cache util-linux"
  elif have dnf; then
    confine_hint="sudo dnf install -y util-linux"
  elif have yum; then
    confine_hint="sudo yum install -y util-linux"
  elif have pacman; then
    confine_hint="sudo pacman -S --needed util-linux"
  elif have zypper; then
    confine_hint="sudo zypper install -y util-linux"
  fi

  say ""
  say "This machine is missing:$confine_missing"
  say ""
  say "Those are how a session started from your phone is held inside the folder you"
  say "granted it — a user namespace made by \`unshare\`, with every capability dropped"
  say "by \`setpriv\` before the shell starts. Without them a session from a device is"
  say "refused rather than started unconfined, so New Session will not work until:"
  say ""
  say "    $confine_hint"
  say ""
  say "Everything else here is installed and working. Sessions you start on this"
  say "machine yourself are unaffected."
}

# ------------------------------------------------------------- fetch + hash --

# Everything the private-runtime path needs, checked in one place and before a
# single byte moves.
#
# This is not tidiness. `fetch` and `sha256_of` are both called as `x=$(...)`,
# and a `die` inside a command substitution exits only that subshell — the
# script would carry on with an empty string and report a checksum mismatch
# when the real problem was that the machine has no `shasum`. Refusing here
# keeps every message true.
require_tools() {
  have curl || have wget || die "Neither curl nor wget is here, so there is no way to download Node.
Install one of them, or install Node ${MIN_NODE_MAJOR}+ yourself, then run this again."

  have sha256sum || have shasum || have openssl || die "No sha256 tool here (sha256sum, shasum or openssl), and this will not unpack
an unverified tarball onto your machine. Install coreutils, or install Node
${MIN_NODE_MAJOR}+ yourself, then run this again."

  have tar || die "tar is missing, so the Node download cannot be unpacked.
Install tar, or install Node ${MIN_NODE_MAJOR}+ yourself, then run this again."

  have mktemp || die "mktemp is missing, so there is no safe place to unpack a download.
Install coreutils, or install Node ${MIN_NODE_MAJOR}+ yourself, then run this again."
}

fetch() { # $1 url, $2 destination, or "-" for stdout
  if have curl; then
    if [ "$2" = "-" ]; then curl -fsSL "$1"; else curl -fsSL "$1" -o "$2"; fi
  elif have wget; then
    if [ "$2" = "-" ]; then wget -qO- "$1"; else wget -qO "$2" "$1"; fi
  else
    die "internal: no downloader (require_tools should have caught this)"
  fi
}

sha256_of() {
  if have sha256sum; then
    sha256sum "$1" | cut -d' ' -f1
  elif have shasum; then
    shasum -a 256 "$1" | cut -d' ' -f1
  elif have openssl; then
    openssl dgst -sha256 "$1" | sed 's/.*= *//'
  else
    die "internal: no sha256 tool (require_tools should have caught this)"
  fi
}

# Resolve the version and the expected hash from one file.
#
# Verification matters more here than anywhere else in this script: an installer
# that pipes an unchecked download into `tar` on somebody's server has made the
# machine less safe than the refusal it replaced. What this buys, precisely: the
# bytes are the bytes the Node project published, so a corrupted transfer, a
# stale mirror or a mirror serving something else is caught. What it does not
# buy: it is not a signature check — SHASUMS256.txt comes from the same origin
# as the tarball, so a compromised origin signs its own homework. Node does
# publish a detached GPG signature, and checking it would mean shipping a
# keyring and a gpg dependency into a `curl | sh`; the honest line is that this
# trusts nodejs.org over TLS, and says so.
resolve_node() {
  if [ -n "$NODE_PINNED" ]; then
    NODE_VERSION="${NODE_PINNED#v}"
    SHASUMS_URL="$NODE_MIRROR/v$NODE_VERSION/SHASUMS256.txt"
  else
    SHASUMS_URL="$NODE_MIRROR/$NODE_LINE/SHASUMS256.txt"
  fi

  sums=$(fetch "$SHASUMS_URL" -) || sums=""
  [ -n "$sums" ] || die "Could not read $SHASUMS_URL

That file is how this learns which Node to fetch and what it must hash to, so
there is nothing safe to do without it. Check this machine can reach the network
(or set TERMINALDECK_NODE_MIRROR to a mirror it can), then run this again."

  if [ -z "$NODE_PINNED" ]; then
    # The source tarball line is the one entry that is on every release and
    # carries no platform, so the version is read from it rather than from a
    # platform build that might legitimately be absent.
    NODE_VERSION=$(printf '%s\n' "$sums" |
      sed -n 's/^[0-9a-f]\{64\}  node-v\([0-9][0-9.]*\)\.tar\.gz$/\1/p' | head -n 1)
    [ -n "$NODE_VERSION" ] || die "$SHASUMS_URL did not name a Node version.
Either that mirror is serving something else, or the layout has changed. Pin one
with TERMINALDECK_NODE_VERSION=22.23.2 and run this again."
  fi

  # .tar.gz rather than .tar.xz, deliberately. The xz is roughly half the size,
  # and GNU tar shells out to an `xz` binary that a minimal image need not have,
  # which turns a 25 MB saving into "tar: Cannot exec xz" on exactly the bare
  # servers this exists for. gzip is everywhere.
  NODE_DIR="node-v$NODE_VERSION-$OS-$ARCH"
  NODE_TARBALL="$NODE_DIR.tar.gz"
  NODE_URL="$NODE_MIRROR/v$NODE_VERSION/$NODE_TARBALL"

  # Two spaces separate hash and filename in SHASUMS256.txt, so awk's default
  # splitting gives $1=hash $2=name. Matching the whole field, not a substring:
  # `grep linux-arm64` would also match nothing useful, but a loose match here
  # is how an installer ends up verifying the wrong file against the right hash.
  NODE_SHA=$(printf '%s\n' "$sums" | awk -v want="$NODE_TARBALL" '$2 == want { print $1; exit }')
  [ -n "$NODE_SHA" ] || die "Node $NODE_VERSION has no $OS-$ARCH build — $NODE_TARBALL is not listed in
$SHASUMS_URL

That is Node's answer, not this installer's: it publishes no build for this
combination. Install Node ${MIN_NODE_MAJOR}+ some other way (your package manager, nvm, or a
distribution build), then run this again — it only needs node and npm on PATH."
}

guard_musl() {
  [ "$LIBC" = musl ] || return 0

  hint="apk add --no-cache nodejs npm"
  have apk || hint="your package manager's nodejs and npm packages"

  die "This machine uses musl (Alpine or similar), and the Node project publishes no
musl build — every tarball on nodejs.org/dist is linked against glibc. Unpacking
one here would give you a node binary that exits with \"not found\" and no clue
why, so this will not do it.

Install Node ${MIN_NODE_MAJOR}+ from the distribution instead, then run this again:

    $hint

The rest works normally once node and npm are on PATH: node-pty compiles against
musl fine, given \`build-base python3\` as well.

Nothing has been written to this machine."
}

# ------------------------------------------------------------- private Node --

runtime_node_major() {
  [ -x "$RUNTIME/bin/node" ] || return 1
  rt_version=$("$RUNTIME/bin/node" --version 2>/dev/null | sed 's/^v//') || return 1
  rt_major="${rt_version%%.*}"
  case "$rt_major" in
    '' | *[!0-9]*) return 1 ;;
  esac
  printf '%s' "$rt_major"
}

install_runtime() {
  say "Fetching Node $NODE_VERSION for $(describe_machine) into $RUNTIME"
  say "(nothing is installed system-wide; removing that folder removes it)"

  mkdir -p "$(dirname "$RUNTIME")"

  # The staging directory is a sibling of the runtime rather than /tmp, so the
  # final move is a rename on the same filesystem — atomic, and it cannot half-
  # copy 200 MB onto a server whose /tmp is a small tmpfs.
  tmp=$(mktemp -d "$(dirname "$RUNTIME")/.install.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT INT HUP TERM

  fetch "$NODE_URL" "$tmp/$NODE_TARBALL" || die "Download failed: $NODE_URL
Check this machine can reach nodejs.org, then run this again."

  got=$(sha256_of "$tmp/$NODE_TARBALL")
  [ "$got" = "$NODE_SHA" ] || die "The Node download does not match the checksum Node published for it.

    file      $NODE_TARBALL
    expected  $NODE_SHA
    got       $got

Nothing has been unpacked. That is usually a truncated download or a mirror
serving something stale — try again, and if it repeats, you are not getting the
file nodejs.org says you are."

  tar -xzf "$tmp/$NODE_TARBALL" -C "$tmp"
  [ -d "$tmp/$NODE_DIR" ] || die "The Node tarball did not contain $NODE_DIR as expected. Nothing was installed."

  # The old runtime is moved aside rather than deleted first, so the window in
  # which there is no runtime at all is one rename long instead of one `rm -rf`
  # long. It goes when $tmp goes, on the line below.
  [ ! -e "$RUNTIME" ] || mv "$RUNTIME" "$tmp/previous"
  mv "$tmp/$NODE_DIR" "$RUNTIME"
  rm -rf "$tmp"
  trap - EXIT INT HUP TERM

  # It hashed correctly and it unpacked, and neither of those proves it runs
  # here — a forced/incorrect architecture produces exactly that, and the error
  # from the next command would be about npm rather than about this.
  rt_reported=$("$RUNTIME/bin/node" --version 2>/dev/null || printf '')
  [ "$rt_reported" = "v$NODE_VERSION" ] || die "The Node in $RUNTIME will not run on this machine (it reported '$rt_reported').
That normally means the architecture guess was wrong: this asked for $OS-$ARCH.
Remove $RUNTIME and install Node ${MIN_NODE_MAJOR}+ some other way."
}

# ------------------------------------------------------------------- plan ----

detect_platform

NODE_FOUND=""
NEEDS_RUNTIME=1

if [ -z "$FORCE_RUNTIME" ] && have node; then
  node_version=$(node --version 2>/dev/null | sed 's/^v//')
  node_major="${node_version%%.*}"
  case "$node_major" in
    '' | *[!0-9]*)
      die "Could not read a version out of \`node --version\` (got '$node_version')."
      ;;
  esac
  # npm is part of the answer, not a separate question: a Node without npm
  # cannot place node-pty's binary, and the reference server had exactly that
  # shape — node 18.19.1 and no npm at all. Both roads lead to the same fix, so
  # both take it rather than one refusing.
  if [ "$node_major" -ge "$MIN_NODE_MAJOR" ] && have npm; then
    NODE_FOUND="$node_version"
    NEEDS_RUNTIME=""
  fi
fi

if [ -n "$NEEDS_RUNTIME" ] && [ -n "$NO_RUNTIME" ]; then
  die "Node ${MIN_NODE_MAJOR} or newer with npm is required, and TERMINALDECK_NO_RUNTIME is set, so this
will not fetch one. Install it from https://nodejs.org or with your distribution's
package manager, then run this again.

Nothing has been written to this machine."
fi

if [ -n "$NEEDS_RUNTIME" ]; then
  guard_musl
  check_native_toolchain
  require_tools
  resolve_node
else
  check_native_toolchain
fi

# Where the package lands.
#
# `npm prefix -g` is where a global install goes. On a system Node it is often
# root-owned, and the usual advice at that point is "run it with sudo", which
# installs a user's tool as root and then leaves every future update needing sudo
# too. A user prefix is the better answer and costs one PATH line.
#
# With the private runtime there is a third answer and it is the tidiest: its own
# prefix. node, npm and the `terminaldeck` shim then live in one bin directory,
# which matters because npm's shim is a symlink to a file whose shebang is
# `#!/usr/bin/env node` — it finds node on PATH at run time, so the two have to
# be reachable together or the command dies looking for a runtime it was
# installed with.
if [ -n "$NEEDS_RUNTIME" ]; then
  TARGET=runtime
  INSTALL_PREFIX="$RUNTIME"
else
  prefix=$(npm prefix -g 2>/dev/null || printf '')
  if [ -n "$prefix" ] && [ -w "$prefix/lib" ] 2>/dev/null; then
    TARGET=global
    INSTALL_PREFIX="$prefix"
  else
    TARGET=user
    INSTALL_PREFIX="$HOME/.local"
  fi
fi

# ---------------------------------------------------------------- dry run ----

# A dry run prints the whole plan and writes nothing. It exists so this file is
# testable on a machine that is not the machine it is for: the tests force an
# OS/arch and read back the URL it would use, which is the part that is hard to
# eyeball and easy to get wrong for exactly one architecture.
if [ -n "$DRYRUN" ]; then
  say "Dry run — nothing will be downloaded, written or installed."
  say ""
  say "  package        ${PACKAGE_SPEC}"
  say "  this machine   $(describe_machine)"
  if [ -n "$NODE_FOUND" ]; then
    say "  node found     v$NODE_FOUND at $(command -v node)"
    say "  runtime        not needed"
  else
    if [ -n "$FORCE_RUNTIME" ]; then
      say "  node found     ignored (TERMINALDECK_FORCE_RUNTIME)"
    else
      say "  node found     none usable (needs ${MIN_NODE_MAJOR}+ with npm)"
    fi
    say "  runtime        $RUNTIME"
    say "  checksums      $SHASUMS_URL"
    say "  node version   $NODE_VERSION"
    say "  tarball        $NODE_URL"
    say "  sha256         $NODE_SHA"
  fi
  say "  install        npm install -g ${PACKAGE_SPEC}"
  say "  prefix         $INSTALL_PREFIX ($TARGET)"
  if [ "$TARGET" = runtime ]; then
    say "  launcher       $LAUNCHER_DIR/$PACKAGE"
  fi
  exit 0
fi

# --------------------------------------------------------------- install ----

if [ -n "$NEEDS_RUNTIME" ]; then
  existing=$(runtime_node_major || printf '')
  if [ -n "$existing" ] && [ "$existing" -ge "$MIN_NODE_MAJOR" ]; then
    say "Using the Node already in $RUNTIME"
  else
    install_runtime
  fi
  # For this process only. Nothing here edits a shell profile, so the machine's
  # own `node` — if it ever gets one — stays the one its owner sees.
  PATH="$RUNTIME/bin:$PATH"
  export PATH
fi

have npm || die "npm is required — it is what places the right node-pty binary for this machine."

npm_config_prefix="$INSTALL_PREFIX"
export npm_config_prefix
mkdir -p "$INSTALL_PREFIX/bin"

say "Installing ${PACKAGE_SPEC}…"
npm install -g "$PACKAGE_SPEC" >/dev/null

# npm exiting 0 means a package was installed. It does not mean a `terminaldeck`
# command exists — a package with no `bin` entry installs perfectly and leaves
# nothing to run, which is what the placeholder currently on the registry does.
# Saying "Installed to …" over that is the exact failure this script was written
# to prevent: a host that looks installed and answers nothing when a phone
# reaches for it.
[ -x "$INSTALL_PREFIX/bin/$PACKAGE" ] || die "npm installed $PACKAGE_SPEC and it provided no \`$PACKAGE\` command
($INSTALL_PREFIX/bin/$PACKAGE is not there).

Nothing is running and nothing will answer a phone. If you asked for a version
that predates the headless host, name a newer one:

    TERMINALDECK_VERSION=0.5.0 sh install.sh"

# A launcher, only for the private-runtime case.
#
# The alternative is telling somebody to put ~/.terminaldeck/runtime/bin on their
# PATH, which also puts our Node in front of every other command they ever run —
# and if they later install a system Node, ours silently wins. This is four lines
# that pin the runtime for one process instead.
bin_dir="$INSTALL_PREFIX/bin"
if [ "$TARGET" = runtime ]; then
  mkdir -p "$LAUNCHER_DIR"
  launcher="$LAUNCHER_DIR/$PACKAGE"
  if [ ! -e "$launcher" ] || grep -q 'terminaldeck-launcher' "$launcher" 2>/dev/null; then
    cat >"$launcher" <<LAUNCHER
#!/bin/sh
# terminaldeck-launcher — generated by install.sh, safe to delete.
# Puts the private Node runtime first for this process only, then hands over.
PATH="$RUNTIME/bin:\$PATH"
export PATH
exec "$RUNTIME/bin/$PACKAGE" "\$@"
LAUNCHER
    chmod +x "$launcher"
    bin_dir="$LAUNCHER_DIR"
  else
    say ""
    say "There is already something at $launcher that this did not write, so it was left alone."
    say "The installed command is $RUNTIME/bin/$PACKAGE."
  fi
fi

# ------------------------------------------------------------------- report --

say ""
say "Installed to ${bin_dir}"

case ":${ORIGINAL_PATH}:" in
  *":${bin_dir}:"*) on_path=1 ;;
  *) on_path="" ;;
esac

if [ -z "$on_path" ]; then
  say ""
  say "${bin_dir} is not on your PATH. Add it:"
  say ""
  say "    export PATH=\"${bin_dir}:\$PATH\""
  say ""
  say "…in your shell's startup file, then open a new shell."
fi

check_confine_tools

say ""
say "Next:"
say ""
say "    terminaldeck address   # the address to paste into the app on your phone"
say "    terminaldeck pair      # show a code instead, and approve the device here"
say "    terminaldeck status    # what this machine needs to stay reachable"
say ""

# The address itself, not the name of the command that would print it.
#
# This is the last thing between a fresh server and a phone, and until now it
# was missing entirely: the host printed a host id and a fingerprint, both of
# them one-way hashes, so there was nothing a person could type into a phone to
# reach a machine it had never met. `terminaldeck address` prints the one string
# that can start that handshake, and an installer that ends by naming a command
# instead of running it is an installer that ends one step early — on a rented
# box, in an SSH window somebody is about to close.
#
# It starts the host, deliberately, exactly as `terminaldeck pair` has always
# done. The address is derived from the relay link and the relay link only
# exists inside a running host, so there is no version of this that both prints
# an address and leaves nothing running. The alternative is the failure this
# script's own header names: "a host installed and never started is
# indistinguishable from a broken one when you are looking at a phone in another
# country."
#
# `2>/dev/null` because that command puts the address on stdout and every
# sentence it has — including "Starting the host…" — on stderr, so this captures
# an address or an empty string and never a mixture. A failure is not fatal
# here: the install itself succeeded, and the fallback names the two commands
# that explain why there is nothing to paste yet.
address=""
if [ -x "${bin_dir}/${PACKAGE}" ]; then
  say "Starting the host and asking it for this server's address…"
  address=$("${bin_dir}/${PACKAGE}" address 2>/dev/null || printf '')
fi

if [ -n "$address" ]; then
  say ""
  say "This server's address:"
  say ""
  say "    ${address}"
  say ""
  say "Paste it into the app on your phone or another computer: Add a server, then"
  say "sign in with a username and password or key this machine already accepts."
  say ""
  say "That address is NOT a secret. It carries a public key and a public name at a"
  say "relay, and it grants nothing on its own — the login is the gate. Copy it to"
  say "yourself however is convenient."
else
  say ""
  say "No address yet — this host is not on the relay, so there is no slot for a phone"
  say "to find it in. \`${PACKAGE} status\` says why, and \`${PACKAGE} address\` prints"
  say "the address once it is up."
fi

say ""
say "Read the status output before you rely on this from somewhere else. On a"
say "server it usually says there is nothing to do. Inside WSL it does not: Windows"
say "shuts the distribution down when the last terminal closes, and a phone that"
say "then finds nothing here looks exactly like the app being broken."

if [ "$TARGET" = user ]; then
  say ""
  say "(Installed under ${HOME}/.local because the global npm prefix is not writable."
  say " That is deliberate — installing your own tool as root makes every update need sudo.)"
fi

if [ "$TARGET" = runtime ]; then
  say ""
  say "(This machine had no usable Node, so Node ${NODE_VERSION} was installed into"
  say " ${RUNTIME} and is used by nothing else here. Nothing was written outside"
  say " your home directory. \`rm -rf ${RUNTIME}\` and \`rm ${LAUNCHER_DIR}/${PACKAGE}\` remove it all.)"
fi
