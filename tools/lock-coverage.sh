#!/bin/bash
# tools/lock-coverage.sh -- every source download must go through
# sources.lock, and every lock row should have a consumer.
#
#   tools/lock-coverage.sh            # report; exit 1 on used-but-unlocked
#   tools/lock-coverage.sh --quiet    # only the problems
#
# What it checks:
#   1. every */build.sh that calls tools/fetch-src.sh names a key that
#      exists in sources.lock (used-but-unlocked = the build would fail on
#      a clean checkout, or worse: download unverified bytes);
#   2. every lock row is referenced by at least one build.sh (locked-but-
#      unused = a stale row -- warning only, some rows are consumed via
#      variable indirection).
#
# Key extraction: the token after `fetch-src.sh` (with or without --lock),
# extended with dots (gnu-config.sub), minus flags and shell variables.
# Indirect keys (LOCK_KEY=python3 style) are picked up from their
# assignment lines.

set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1

lock_keys="$(awk -F'\t' '!/^#/ && NF>=4 {print $1}' "$here/sources.lock" | sort -u)"

# direct + indirect key candidates from every build.sh
used="$(cat "$here"/*/build.sh "$here"/*/*/build.sh 2>/dev/null | grep -oP \
    "fetch-src\.sh[\"' ]+(--lock[\"' ]+)?\K[a-z0-9][a-z0-9._-]*" \
    | grep -v '^--' | sort -u)"
# variable-indirect: assignments like LOCK_KEY=python3 consumed by a
# fetch-src --lock "$LOCK_KEY"
indirect="$(cat "$here"/*/build.sh "$here"/*/*/build.sh 2>/dev/null | grep -oP \
    "^\s*[A-Z_]*KEY=\"?\K[a-z0-9][a-z0-9._-]*" | sort -u)"
used_all="$(printf '%s\n%s\n' "$used" "$indirect" | sort -u | grep -v '^$')"

rc=0
missing="$(comm -23 <(echo "$used_all") <(echo "$lock_keys"))"
if [ -n "$missing" ]; then
    rc=1
    echo "ERROR: used by a build.sh but absent from sources.lock:"
    echo "$missing" | sed 's/^/  /'
elif [ "$QUIET" = 0 ]; then
    echo "OK: every fetch-src key resolves to a lock row"
fi

stale="$(comm -13 <(echo "$used_all") <(echo "$lock_keys"))"
# 显式 allowlist:已知的间接消费键,附一行原因(2026-11-25 审计)。不在名单
# 里的 stale 行才是真问题——否则真 stale 被常驻噪音淹没。
allowlist="python3	lang/python3 的取源键经 build.sh 变量与 make-deb-314.sh 变体间接拼装,直接 grep 不可见
python314	同上:make-deb-314.sh 变体(Version/UPSTREAM 运行期推导)
xnu-coalition.h	SDK 哨兵头:tools/fetch-darwin-header.sh 按批消费,不经 build.sh
xnu-if-arp.h	SDK 哨兵头:同上
xnu-if-ether.h	SDK 哨兵头:同上
xnu-if-types.h	SDK 哨兵头:同上
xnu-route.h	SDK 哨兵头:同上"
if [ -n "$stale" ]; then
    echo "$stale" | while IFS= read -r k; do
        reason=$(awk -F'\t' -v k="$k" '$1==k {print $2; exit}' <<<"$allowlist")
        if [ -n "$reason" ]; then
            echo "NOTE (indirect, allowlisted): $k -- $reason"
        else
            echo "WARNING: lock row $k 无任何 build.sh 引用(stale?)-- 若属间接消费,请入上方 allowlist 并写明原因"
        fi
    done
elif [ "$QUIET" = 0 ]; then
    echo "OK: every lock row has a consumer"
fi
exit $rc
