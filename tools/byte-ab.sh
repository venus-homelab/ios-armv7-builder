#!/bin/bash
# tools/byte-ab.sh -- payload byte-level A/B between two independent builds.
#
#   tools/byte-ab.sh <cat/pkg> [--report <file>] [--keep]
#       e.g.  tools/byte-ab.sh net/whois
#             tools/byte-ab.sh lang/quickjs --report docs/byte-ab-report.md
#
# Why: the deb CONTAINER layer is already deterministic (SOURCE_DATE_EPOCH is
# exported by every make-deb.sh, dpkg-deb clamps tar mtimes, and entry order
# proved stable -- 2026-11-24 openssh probe).  What this tool tests is the
# PAYLOAD layer: build the same commit twice, once in place and once in a
# clean git clone at a DIFFERENT absolute path, and compare the resulting
# debs byte for byte.  A difference localizes to exact payload members, so
# path embedding, wall-clock leakage and signature nondeterminism all name
# themselves instead of hiding behind "rebuild differs sometimes".
#
# Method:
#   A  build.sh + make-deb.sh in $root (the tree you are standing in).
#   B  git clone of $root at the same HEAD into tmp/byte-ab/<pkg>/B-tree
#      (hardlink-cloned src-cache, so no re-download), built the same way.
#   The two debs are sha256-compared; on differ, every payload member is
#   compared (size + first differing byte + Mach-O note), which turns
#   "nondeterministic" into a file list.
#
# Hygiene: out/ is snapshotted (hardlinks) before A and restored afterwards,
# so the pool-facing artifact area ends the run exactly as it started.
# Everything heavy lives in tmp/ (root partition, AGENTS.md rule 0).
#
# First-run 2026-11-24 on net/whois (real pool package, per AGENTS.md rule 12).

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

[ $# -ge 1 ] || { echo "usage: $0 <cat/pkg> [--report <file>] [--keep]" >&2; exit 2; }
PKGDIR="$1"; shift || true
REPORT=""; KEEP=0
FRESH=()
while [ $# -gt 0 ]; do
    case "$1" in
        --report) REPORT="$2"; shift 2;;
        --keep)   KEEP=1; shift;;
        --fresh)  FRESH+=("$2"); shift 2;;   # extra pristine paths (subbuild caches)
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done
[ -f "$PKGDIR/build.sh" ] && [ -f "$PKGDIR/make-deb.sh" ] || {
    echo "no build.sh/make-deb.sh under $PKGDIR" >&2; exit 2; }

name="${PKGDIR#*/}"          # whois, quickjs, curl
work="$root/tmp/byte-ab/$name"
logA="$work/A.log"; logB="$work/B.log"
mkdir -p "$work"

# The toolchain env CI exports (full-build.yaml IOS_LD64); on homelab hosts the
# stub toolchain lives under $HOME/ios-tool.  An explicit env always wins.
export IOS_LD64="${IOS_LD64:-$HOME/ios-tool/x-ld64/bin/x86_64-apple-darwin13.4.0-ld}"

commit="$(git rev-parse HEAD)"
dirty="$(git status --porcelain | wc -l)"
echo "== byte-A/B $name @ $commit (dirty entries: $dirty)"

# ---- hygiene: snapshot out/ so the run cannot leave residue ----------------
pre="$work/pre-out"; rm -rf "$pre"; mkdir -p "$pre"
for f in out/*_iphoneos-arm.deb; do [ -e "$f" ] || continue; ln "$f" "$pre/" 2>/dev/null || cp "$f" "$pre/"; done

restore_out() {
    # Bring out/ back to the pre-run state -- WITHOUT clobbering concurrent
    # writers.  Third strike for this class (2026-11-25: the snapshot
    # hardlink resurrected pre-fix python314 bytes over the python3
    # subagent's fresh rebuild, because a cp-back of an untouched-by-us
    # name is indistinguishable from restoring our own overwrite).  Rule:
    # only touch names byte-ab itself created (they appear in $logA);
    # anything else that changed under us belongs to whoever changed it.
    for f in "$pre"/*_iphoneos-arm.deb; do [ -e "$f" ] || continue
        b="$(basename "$f")"; [ "$f" -ef "out/$b" ] && continue   # untouched hardlink
        if [ ! -e "out/$b" ]; then cp -f "$f" "out/$b"; continue; fi
        if cmp -s "$f" "out/$b"; then continue; fi
        if grep -qF "$b" "$logA" 2>/dev/null; then
            cp -f "$f" "out/$b"   # our own rebuild overwrote it -- put the original back
        else
            echo "   (concurrent writer replaced out/$b during the run -- leaving their bytes)"
        fi
    done
    for f in out/*_iphoneos-arm.deb; do [ -e "$f" ] || continue
        b="$(basename "$f")"; [ -e "$pre/$b" ] && continue
        grep -qF "$b" "$logA" 2>/dev/null || { echo "   (keeping concurrently created out/$b)"; continue; }
        echo "   (removing test artifact out/$b)"; rm -f "$f"
    done
}
trap 'restore_out' EXIT

# ---- build A: in place -----------------------------------------------------
# Fair A/B: both sides must start from pristine source.  build.sh scripts
# reuse an already-extracted tmp/src tree when it exists, so stale objects or
# generated headers from an older build would silently leak into A (the
# 2026-11-24 whois first-run caught exactly this: a Nov 21 tree -- with a
# stale whois.o 128 bytes fat -- next to a fresh clone).  The extraction dir
# name cannot be derived from the lock URL (codeload URLs carry no filename),
# so read it from the cached tarball's top-level entry.
cache="$root/tmp/src-cache/$name"
if [ -d "$cache" ]; then
    tarball="$cache/$(ls "$cache" | head -1)"
    # full listing to a file first: `tar tf | head -1` SIGPIPEs tar mid-stream
    # and pipefail turns that into a silent exit (2026-11-24, three lost runs)
    tar tf "$tarball" >"$work/tf.txt" 2>/dev/null || true
    top="$(head -1 "$work/tf.txt" | cut -d/ -f1)"
    if [ -n "$top" ] && [ -d "tmp/src/$top" ]; then
        echo "   (pristine-source: removing tmp/src/$top)"
        rm -rf "tmp/src/$top"
    else
        echo "   (pristine-source: tmp/src/$top absent -- already pristine)"
    fi
fi
# --fresh: subbuild caches the package consumes from the surrounding tree
# (e.g. curl's tmp/curl-*-abi and tmp/src/openssl-*).  A warm cache built by an
# older toolchain state vs B's fresh rebuild is an UNFAIR A/B -- the 2026-11-24
# curl run showed 1-byte flag flips + table deltas from exactly that.  Wipe
# them on the A side so both sides build from pristine inputs.  Paths must be
# relative and stay inside the repo.
for p in "${FRESH[@]:-}"; do
    [ -n "$p" ] || continue
    case "$p" in /*|*..*) echo "refusing unsafe --fresh path: $p" >&2; exit 2;; esac
    if [ -e "$root/$p" ]; then
        echo "   (pristine-source: removing $p)"
        rm -rf "$root/$p"
    fi
done
marker="$work/marker"; touch "$marker"
if ! bash "$PKGDIR/build.sh" >"$logA" 2>&1; then
    echo "FAIL: A build failed (see $logA)"; tail -20 "$logA"; exit 1
fi
if ! bash "$PKGDIR/make-deb.sh" >>"$logA" 2>&1; then
    echo "FAIL: A make-deb failed (see $logA)"; tail -20 "$logA"; exit 1
fi
# Capture A's product by the deb paths make-deb itself printed (the
# "==> out/<name>_<ver>-<rev>_iphoneos-arm.deb" lines in A.log), NOT by
# "newer than marker": a concurrent writer CAN land an unrelated deb in
# out/ during the A-side build (2026-11-25: a traceroute deb landed
# mid-tailscale-build and find -newer silently handed back 15KB of
# traceroute as A.deb).  Log-named debs are this package's by
# construction; multi-deb packages (net/curl emits curl4+openssl4)
# deterministically compare the alphabetically-first name.
debA=""
for p in $(grep -ho 'out/[A-Za-z0-9._+-]*_iphoneos-arm\.deb' "$logA" 2>/dev/null | sort -u || true); do
    if [ -f "$p" ]; then debA="$p"; break; fi
done
if [ -z "$debA" ]; then
    # fallback for make-deb scripts that print no path: only safe when
    # exactly one deb appeared in out/ during the build
    mapfile -t newDebs < <(find out -maxdepth 1 -name '*_iphoneos-arm.deb' -newer "$marker")
    if [ "${#newDebs[@]}" -ne 1 ]; then
        echo "FAIL: cannot identify A's deb: ${#newDebs[@]} debs newer than the marker, none named in $logA (concurrent writer? see $logA)" >&2
        exit 1
    fi
    debA="${newDebs[0]}"
fi
[ -n "$debA" ] || { echo "FAIL: A produced no deb (see $logA)"; tail -20 "$logA"; exit 1; }
cp "$debA" "$work/A.deb"

# ---- build B: clean clone at a different absolute path ---------------------
treeB="$work/B-tree"
chmod -R u+w "$treeB" 2>/dev/null || true   # sysroot copies carry r-x dirs (cgroup snapshots)
rm -rf "$treeB"
git clone --quiet "file://$root" "$treeB"   # .git so make-deb's SOURCE_DATE_EPOCH resolves
# overlay the CURRENT working tree (uncommitted edits included): A and B must
# differ in absolute path only, or the run tests the wrong thing
git -C "$root" ls-files -z --cached --others --exclude-standard \
    | tar --null -T - -cf - | tar -xf - -C "$treeB"
# gitignored build inputs the tree-relative defaults expect (see below)
mkdir -p "$treeB/out" "$treeB/tmp/src"   # build.sh tar -C into tmp/src
# gitignored build inputs the tree-relative defaults expect: the fetch cache is
# immutable (hardlinks safe); the sysroot is written by toolchain bootstrap and
# only read by package builds, but copy it for real -- hardlinking a tree a
# build might touch would leak mutations back into A's copy.
if [ -d "$root/tmp/src-cache" ]; then cp -al "$root/tmp/src-cache" "$treeB/tmp/src-cache"; fi
if [ -d "$root/tmp/sysroot" ];    then cp -a  "$root/tmp/sysroot"    "$treeB/tmp/sysroot"; fi
if ! (cd "$treeB" && bash "$PKGDIR/build.sh" >"$logB" 2>&1 && bash "$PKGDIR/make-deb.sh" >>"$logB" 2>&1); then
    echo "FAIL: B build failed (see $logB)"; tail -20 "$logB"; exit 1
fi
# same log-based capture as the A side -- multi-deb packages must compare
# the SAME deb name on both sides (A takes the alphabetically first, so B)
debB=""
for p in $(grep -ho 'out/[A-Za-z0-9._+-]*_iphoneos-arm\.deb' "$logB" 2>/dev/null | sort -u || true); do
    if [ -f "$treeB/$p" ]; then debB="$treeB/$p"; break; fi
done
[ -n "$debB" ] || debB="$(find "$treeB/out" -maxdepth 1 -name '*_iphoneos-arm.deb' | head -1)"
[ -n "$debB" ] || { echo "FAIL: B produced no deb (see $logB)"; exit 1; }
cp "$debB" "$work/B.deb"

shaA="$(sha256sum "$work/A.deb" | awk '{print $1}')"
shaB="$(sha256sum "$work/B.deb" | awk '{print $1}')"
szA="$(stat -c%s "$work/A.deb")"; szB="$(stat -c%s "$work/B.deb")"

# ---- verdict ---------------------------------------------------------------
rep="$work/report.md"
{
    echo "# byte-A/B: $name  ($(date -u +%F))"
    echo "- commit: \`$commit\` (dirty entries in A tree: $dirty)"
    echo "- A (in-place):  \`$shaA\` ($szA bytes)"
    echo "- B (clean clone, different path): \`$shaB\` ($szB bytes)"
} >"$rep"

if [ "$shaA" = "$shaB" ]; then
    echo "VERDICT: IDENTICAL"
    echo "- verdict: **IDENTICAL** -- payload layer is deterministic at this commit" >>"$rep"
else
    echo "VERDICT: DIFFER"
    echo "- verdict: **DIFFER**" >>"$rep"
    echo "" >>"$rep"
    echo "| payload member | A size | B size | first difference |" >>"$rep"
    echo "|---|---|---|---|" >>"$rep"
    xa="$work/xA"; xb="$work/xB"; rm -rf "$xa" "$xb"
    dpkg-deb -R "$work/A.deb" "$xa"; dpkg-deb -R "$work/B.deb" "$xb"
    ( cd "$xa" && find . -type f | sed 's#^\./##'; cd "$xb" && find . -type f | sed 's#^\./##' ) \
        | LC_ALL=C sort -u >"$work/members"
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        fa="$xa/$rel"; fb="$xb/$rel"
        if [ -f "$fa" ] && [ -f "$fb" ] && cmp -s "$fa" "$fb"; then continue; fi
        sa=$(stat -c%s "$fa" 2>/dev/null || echo 0)
        sb=$(stat -c%s "$fb" 2>/dev/null || echo 0)
        msg="-"
        if [ -f "$fa" ] && [ -f "$fb" ]; then
            msg="$(cmp "$fa" "$fb" 2>&1 | head -1 || true)"
            [ -n "$msg" ] || msg="differs (cmp silent)"
        fi
        macho=""
        if [ -f "$fa" ] && file -b "$fa" 2>/dev/null | grep -q Mach-O; then macho=" (Mach-O)"; fi
        echo "| \`$rel\`$macho | $sa | $sb | $msg |" >>"$rep"
    done <"$work/members"
    cat "$rep"
fi

if [ -n "$REPORT" ]; then cat "$rep" >>"$REPORT"; echo "(appended to $REPORT)"; fi

if [ "$KEEP" != 1 ]; then
    chmod -R u+w "$treeB" "${xa:-/nonexistent}" "${xb:-/nonexistent}" 2>/dev/null || true
    rm -rf "$treeB" "${xa:-}" "${xb:-}" 2>/dev/null || true
fi
echo "== artifacts kept in $work (A.deb B.deb A.log B.log report.md)"
