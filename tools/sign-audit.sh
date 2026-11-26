#!/bin/bash
# tools/sign-audit.sh -- the deb payload signature gate.
#
#   tools/sign-audit.sh out/<pkg>.deb [...]      # audit; exit 1 on any
#                                                # unsigned Mach-O
#
# Why: individual make-deb scripts sign their payloads in different ways,
# and several used `ldid -S ... || true` -- a FAILED SIGNATURE CONTINUES
# THE BUILD, and an unsigned Mach-O dies at dyld on the device with no
# crash report (the classic SIGKILL trap).  This gate audits the FINAL
# REAL PAYLOAD instead of trusting each script's style:
#
#   * every freshly-built deb is unpacked;
#   * every Mach-O file inside (executables, dylibs, python .so bundles)
#     must carry a valid ldid signature (ldid -e parses);
#   * executable bits and the install shape are reported for eyeballing.
#
# The kernel rule this enforces (AGENTS.md 部署三件套): an unsigned binary
# is exec-killed with NO diagnostics.

set -uo pipefail
rc=0

for deb in "$@"; do
    [ -f "$deb" ] || { echo "not a file: $deb" >&2; rc=1; continue; }
    stage=$(mktemp -d)
    # explicit cleanup: a RETURN trap never fires in a top-level loop
    if ! dpkg-deb -x "$deb" "$stage" 2>/dev/null; then
        echo "FAIL $deb: dpkg-deb -x cannot unpack" >&2
        rm -rf "$stage"
        rc=1
        continue
    fi
    n_macho=0
    n_unsigned=0
    while IFS= read -r bin; do
        # foreign-arch Mach-O (go4 ships race .syso for arm64/amd64 and
        # dwarf testdata fixtures inside the goroot source tree) can never
        # execute on the armv7 device -- signature enforcement is for the
        # payloads that dyld would actually load
        ftype=$(file -b "$bin")
        if ! grep -qE 'arm|universal' <<<"$ftype"; then
            continue
        fi
        if grep -qE 'arm64|x86_64' <<<"$ftype"; then
            continue
        fi
        n_macho=$((n_macho + 1))
        if ! ldid -e "$bin" >/dev/null 2>&1; then
            rel=${bin#"$stage"}
            echo "UNSIGNED $deb:$rel" >&2
            n_unsigned=$((n_unsigned + 1))
        fi
    done < <(find "$stage" -type f -exec sh -c 'file -b "$1" | grep -q "Mach-O"' _ {} \; -print)
    # a binary package whose payload lost its main program (the packing
    # script signing only alias copies, a stale wildcard) would pass the
    # old check as "OK: 0 Mach-O files, all signed" -- 2026-11-24 audit
    # P1: executables with zero Mach-O are a FAIL; only data-only payloads
    # (no executable bit outside DEBIAN/, e.g. ca-certificates4) pass
    n_exec=0
    while IFS= read -r x; do
        # shell/interpreter scripts legitimately ship with +x (the CA
        # bundle's atomic-update tooling) -- only a BINARY executable with
        # zero Mach-O in the payload means the main binary went missing
        if file -b "$x" | grep -qE 'text|script'; then continue; fi
        n_exec=$((n_exec + 1))
    done < <(find "$stage" -type f -perm /111 ! -path "$stage/DEBIAN/*")
    if [ "$n_macho" -eq 0 ] && [ "$n_exec" -gt 0 ]; then
        echo "FAIL $deb: $n_exec executables but 0 Mach-O -- the main binary is missing/renamed in the payload" >&2
        rc=1
    elif [ "$n_unsigned" = 0 ]; then
        echo "OK $deb: $n_macho Mach-O files, all signed"
    else
        echo "FAIL $deb: $n_unsigned/$n_macho Mach-O files unsigned" >&2
        rc=1
    fi
    rm -rf "$stage"
done
exit $rc
