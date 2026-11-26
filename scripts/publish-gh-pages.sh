#!/bin/bash
# Publish repo/ (as produced by scripts/make-repo.sh) to the gh-pages branch.
#
# The tree is pushed under gh-pages's repo/ subdirectory -- the same path the
# main branch used to carry -- so the public URL
#     https://venus-homelab.github.io/ios-armv7-builder/repo
# never changes, whichever branch GitHub Pages is currently serving.
#
# gh-pages is force-pushed as a single orphan commit every time, so binary
# accumulation cannot grow it: the branch is always exactly one snapshot.
# The main branch never carries the debs after the 2026-11-21 history rewrite
# (out/ and repo/ are gitignored there).
#
# Usage:  scripts/publish-gh-pages.sh        # publishes ./repo to origin
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
# PUBLISH_URL overrides the push target -- on CI the push happens from a
# throwaway "git init" dir, so actions/checkout's credential extraheader
# (stored only in the main checkout's .git/config) never applies; pass a
# token-bearing URL there (full-build.yaml does).  Local runs keep origin.
url="${PUBLISH_URL:-$(git -C "$here" remote get-url origin)}"
[ -d "$here/repo/pool" ] || { echo "repo/ not built; run scripts/make-repo.sh first" >&2; exit 1; }

# staging INSIDE the tree: mktemp's /tmp is a 1.5G tmpfs and the repo
# snapshot (50+ debs, go4 alone is 52MB) blows its quota -- AGENTS.md rule 0
# (tmp/ is gitignored, so a fresh CI checkout does not have it)
mkdir -p "$here/tmp"
tmp="$(mktemp -d "$here/tmp/ghpub.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/repo"
cp -r "$here/repo/." "$tmp/repo/"

# The landing page: GitHub Pages renders markdown through its built-in
# Jekyll -- no static-site tooling needed.  The package table and the
# per-package docs are copied alongside so every relative link resolves.
cp "$here/docs/PACKAGES.md" "$tmp/PACKAGES.md"
mkdir -p "$tmp/docs" "$tmp/tests"
for f in "$here"/docs/*.md; do cp "$f" "$tmp/docs/"; done
for f in "$here"/tests/*.sh; do cp "$f" "$tmp/tests/"; done
cat > "$tmp/index.md" <<'MD'
# ios-armv7-builder

A cross-build kit for **jailbroken 32-bit iOS** (`armv7`, iOS 10.x) that
works entirely **on a Linux host** — no Xcode, no macOS, no Apple signing.
Every package is built with the real Apple SDK headers, signed with `ldid`,
packaged as a `.deb` and served from this APT repository.

## Install on the device

Add the source to Cydia (or `/etc/apt/sources.list.d/`):

```
deb https://venus-homelab.github.io/ios-armv7-builder/repo stable main
```

Signing key: [repo/venus-homelab.asc](repo/venus-homelab.asc)

## What ships

The full package table — versions, build recipes, per-package docs and the
device-acceptance test each package passes — is generated from the APT
index: **[PACKAGES.md](PACKAGES.md)** (46 packages and counting).

## Build it yourself

The same flow the CI runs, for one package end to end:

```sh
tools/bootstrap-toolchain.sh --prefix=/opt/ios-tool   # once: clang+ld64+SDK
(cd net/curl && ./build.sh)                           # -> out/curl-*-armv7
./net/curl/make-deb.sh                                # -> out/curl4_*.deb
scripts/make-repo.sh && scripts/publish-gh-pages.sh   # -> this repo
```

See the [source repository](https://github.com/venus-homelab/ios-armv7-builder)
for the other ~45 packages, the porting docs (`docs/<pkg>.md`) and the
toolchain-level rules (`docs/toolchain.md`).
MD
cd "$tmp"
git init -q -b gh-pages
git add -A
git -c user.name="venus-homelab" \
    -c user.email="venus-homelab@users.noreply.github.com" \
    commit -qm "publish APT repo $(date -u +%FT%TZ)"
git remote add origin "$url"
# Force pushes race when two publishes overlap (the ref moves between
# negotiation and apply -> "cannot lock ref"); retry a few times.  The
# snapshot-vs-snapshot lost-deb race is prevented upstream by the
# gh-pages-publish concurrency group on the publishing workflows.
ok=0
for i in 1 2 3 4 5; do
    if git push -f -q origin gh-pages 2>/tmp/push.err; then ok=1; break; fi
    echo "==> push rejected (attempt $i), retrying"; sleep $((i * 5))
done
[ "$ok" = 1 ] || { cat /tmp/push.err >&2; exit 1; }
echo "==> pushed gh-pages (single orphan commit, repo/ subtree) to $url"
