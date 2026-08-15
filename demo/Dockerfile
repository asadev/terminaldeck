# One visitor's machine.
#
# Built from `out/headless` — the output of `npm run dist:headless` — and not
# from npm, deliberately. `npm view terminaldeck version` is 0.0.1, a three
# kilobyte name reservation whose own description says "This package is not the
# app", and a demo built from a placeholder would be a demo of nothing.
#
# ## The two decisions in here that are about safety rather than packaging
#
# **Debian, not Alpine.** `node-pty` is a native module and its prebuilt binaries
# are glibc; on musl the image would have to compile it, which means shipping a
# C toolchain in a container that hands out shells to strangers. A slightly
# larger base is a much smaller attack surface.
#
# **No agent CLI.** No `claude`, no `codex`, no `gemini`. A signed-out one looks
# like the app is broken, and a signed-in one is our OAuth token sitting in a
# stranger's shell. The demo is a terminal, which is what the App Store
# description claims and all it claims.
#
# The image is not the fence. The fence is the container's own limits, the egress
# rules on the box, and `/usr/local/bin/demo-shell` — see that file, and see
# `demo/escapes.sh`, which measures both against CONFINEMENT.md's escape table.

# ---------------------------------------------------------------- the build --
#
# A separate stage, and the reason is a compiler.
#
# `node-pty` ships no prebuilt binary for linux-x64 on this Node — measured, on
# the first build of this image: *"Rebuilding because directory
# prebuilds/linux-x64 does not exist"*, followed by node-gyp failing to find
# Python. So it has to be compiled, which needs python3 and a toolchain.
#
# Compiling it in the runtime image would leave `gcc`, `make` and the headers in
# a container that hands a shell to an anonymous stranger — a build environment
# is the single most useful thing an attacker can be given. So the toolchain
# lives here, in a stage that is thrown away, and the runtime gets the compiled
# `.node` file and nothing that made it.
FROM node:22-bookworm AS build
WORKDIR /opt/terminaldeck
COPY headless/ /opt/terminaldeck/
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 build-essential \
 && npm install --omit=dev --no-audit --no-fund \
 && npm cache clean --force \
 && node -e "import('/opt/terminaldeck/chunk-version.mjs').then(()=>console.log('bundle loads'))"

# -------------------------------------------------------------- the runtime --

FROM node:22-bookworm-slim

# `util-linux` is not optional and is the reason this line is not shorter: it
# carries `unshare` and `setpriv`, which are the two programs the confinement is
# made of. `procps` and `less` are there so that a curious visitor typing `top`
# or piping into `less` finds a working machine rather than a stub.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates git less nano procps util-linux tini vim-tiny file \
 && rm -rf /var/lib/apt/lists/*

# uid 1001 rather than the image's own `node` user (1000): a visitor who reads a
# uid should not be able to guess that it is the same one the build used, and a
# home under /home is what the tmpfs in `demo-shell` covers.
RUN groupadd -g 1001 visitor && useradd -u 1001 -g 1001 -M -d /home/visitor -s /bin/bash visitor

# The host itself, already built. `npm install --omit=dev` was used up in the
# stage above rather than `ci`, because the manifest `scripts/build-headless.mjs`
# writes has no lockfile beside it — the dependency list is read out of the
# emitted bundle, so there is nothing for a lockfile to pin that the bundle has
# not already decided.
WORKDIR /opt/terminaldeck
COPY --from=build /opt/terminaldeck /opt/terminaldeck
RUN node -e "import('/opt/terminaldeck/chunk-version.mjs').then(()=>console.log('bundle loads'))" \
 && rm -rf /root/.npm

COPY image/demo-shell /usr/local/bin/demo-shell
COPY image/demo-code.mjs /usr/local/bin/demo-code
COPY image/entrypoint.sh /usr/local/bin/demo-entrypoint
COPY image/seed/ /opt/demo-seed/
RUN chmod 0755 /usr/local/bin/demo-shell /usr/local/bin/demo-code /usr/local/bin/demo-entrypoint \
 && chmod 0755 /opt/demo-seed/hello.sh

# The confinement's holding point is *not* baked in here, and that is worth a
# note because it was tried twice. The container runs `--read-only`, so
# `demo-shell` cannot `mkdir` a mount point at session time — and creating one in
# the image does not help either, because the kernel refuses to mount over a
# directory that lives on a read-only mount. Both were measured on the real box.
# The holding point is under `/run`, which is a tmpfs. Worse than either failure
# was that the first one was quiet enough for the escape suite to score sixteen
# passes against a shell that had never started; `demo/escapes.sh` now refuses to
# score a run whose shell did not come up.

# `providers.ts` starts a plain shell session as `$SHELL -l`. This is the whole
# of how the confinement is applied: the product asks the machine what its login
# shell is, and on this machine the answer is the confined one. Nothing in the
# product knows, which is the point — a demo must not need a special code path.
ENV SHELL=/usr/local/bin/demo-shell \
    HOME=/root \
    DEMO_VISITOR_UID=1001 \
    DEMO_VISITOR_GID=1001 \
    DEMO_VISITOR_HOME=/home/visitor \
    TERMINALDECK_DEMO_PLAYGROUND=/home/visitor/playground \
    NODE_ENV=production

# `tini` because the visitor's shell will leave zombies — every backgrounded
# thing they start and abandon — and PID 1 in a container is expected to reap
# them. Without it a fork bomb's remains count against `--pids-limit` after the
# fork bomb itself is gone.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/demo-entrypoint"]
