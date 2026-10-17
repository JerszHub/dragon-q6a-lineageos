#!/bin/bash
# setup_tree.sh — prepares a LineageOS 24 source tree for the Dragon Q6A, from nothing.
#
#   1. repo init + sync, pinned to manifests/q6a-pinned.xml (every project at the exact
#      commit our images were built from; it already contains local_manifests/)
#   2. the kernel, android-mainline at KERNEL_COMMIT, fetched shallow
#   3. the patches listed in patches/series
#   4. device/radxa/dragon_q6a and our files for device/mainline/generic
#
# Each step can be re-run: a patch that is already applied is skipped.
#
# Needs: repo, git, git-lfs, curl. About 400 GB free for the tree plus the build.
# Usage: scripts/setup_tree.sh [tree]     (default: $LINEAGE_TREE or ~/q6a/lineage)
set -euo pipefail
REPO_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
TREE=${1:-${LINEAGE_TREE:-$HOME/q6a/lineage}}
# android-mainline of 2026-10-16 (Linux 7.2 plus the 7.3 merge window). See docs/BUILD.md.
KERNEL_COMMIT=${KERNEL_COMMIT:-1e8ffda06e4c0b6304831d603520101b7840137d}
KERNEL_PATH=kernel/mainline/android-mainline
JOBS=${SYNC_JOBS:-8}

mkdir -p "$TREE"
cd "$TREE"

echo "=== 1/4 sources ($TREE)"
if [ ! -d .repo ]; then
  repo init -u https://github.com/LineageOS/android.git -b lineage-24.0 --git-lfs
fi
# The pinned manifest already lists the projects from local_manifests/, so a copy of
# those in .repo/local_manifests would declare them twice and repo would refuse to sync.
if ls .repo/local_manifests/*.xml >/dev/null 2>&1; then
  echo "STOP: $TREE/.repo/local_manifests has manifests; the pinned manifest replaces them."
  echo "      Move them out of the way and run this again."
  exit 1
fi
repo sync -c -j"$JOBS" --no-clone-bundle -m "$REPO_DIR/manifests/q6a-pinned.xml"

echo "=== 2/4 kernel ($KERNEL_COMMIT)"
if [ ! -d "$KERNEL_PATH/.git" ]; then
  git init -q "$KERNEL_PATH"
  git -C "$KERNEL_PATH" remote add origin https://android.googlesource.com/kernel/common
fi
if [ "$(git -C "$KERNEL_PATH" rev-parse -q --verify HEAD 2>/dev/null)" != "$KERNEL_COMMIT" ]; then
  git -C "$KERNEL_PATH" fetch --depth 1 origin "$KERNEL_COMMIT"
  git -C "$KERNEL_PATH" checkout -q --detach FETCH_HEAD
fi

echo "=== 3/4 patches"
grep -v '^#' "$REPO_DIR/patches/series" | while read -r p dir; do
  [ -n "$dir" ] || continue
  if git -C "$dir" apply --check -R "$REPO_DIR/patches/$p" 2>/dev/null; then
    echo "    already applied  $p"
  else
    git -C "$dir" apply --whitespace=nowarn "$REPO_DIR/patches/$p"
    echo "    applied          $p"
  fi
done

echo "=== 4/4 device files"
mkdir -p device/radxa
cp -r "$REPO_DIR/device/radxa/dragon_q6a" device/radxa/
cp -r "$REPO_DIR/device/mainline/generic/." device/mainline/generic/

echo
echo "Tree ready. Next: scripts/build_all.sh $TREE"
