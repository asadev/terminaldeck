#!/bin/zsh
# mk-worktree.sh <name> — worktree at ../td-wt-<name> with hardlinked node_modules
set -e
NAME="$1"; [ -z "$NAME" ] && { echo "usage: mk-worktree.sh <name>"; exit 1; }
REPO=/Users/apple/Projects/terminaldeck
WT="/Users/apple/Projects/td-wt-$NAME"
[ -d "$WT" ] && { echo "$WT"; exit 0; }
cd "$REPO"
git worktree add -q -b "wt/$NAME" "$WT" HEAD
# hardlink, never symlink: a symlinked node_modules breaks the bundler
cp -al "$REPO/node_modules" "$WT/node_modules"
[ -d "$REPO/pwa/node_modules" ] && cp -al "$REPO/pwa/node_modules" "$WT/pwa/node_modules"
touch "$WT/.metadata_never_index"
echo "$WT"
