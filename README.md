# ios-armv7-builder

A cross-build kit for **jailbroken 32-bit iOS** (`armv7`, iOS 10.x) that works
entirely **on a Linux host** — no Xcode, no macOS, no Apple signing.  Since the
2026-11-15 SDK-mode ruling, builds use the real Apple headers from the public
`xybp888/iOS-SDKs` mirror
([toolchain notes §16](https://venus-homelab.github.io/ios-armv7-builder/docs/toolchain.md));
the shipped package set is generated from the repo index in
[docs/PACKAGES.md](docs/PACKAGES.md).

```
Linux host ──(clang+ld64)──▶ Mach-O armv7 ──(ldid)──▶ .deb ──▶ APT repo ──▶ OTA to the device
```

## Quick start

One package end to end (curl, the canary every other port is measured
against):

```sh
tools/bootstrap-toolchain.sh --prefix=/opt/ios-tool   # once: clang+ld64+SDK
tools/bootstrap-hooks.sh                              # once: commit gates (core.hooksPath is NOT cloned)
(cd net/curl && ./build.sh && ./make-deb.sh)          # -> out/curl4_*.deb
tools/byte-ab.sh net/curl                             # payload reproducibility A/B (9 walls so far)
scripts/make-repo.sh                                  # -> the APT repo; publish RIGHT AFTER building
tools/pool-freshness.sh                               # pool vs recipes consistency gate
scripts/publish-gh-pages.sh                           # -> GitHub Pages (when publishing externally)
# device acceptance: scp the deb, ssh root@<device> dpkg -i, bash tests/curl.sh
```

Pristine source always comes from `sources.lock` through
`tools/fetch-src.sh` (sha256-checked, cached under `tmp/src-cache/` —
build.sh calls it, you never unpack by hand).  Go packages additionally
share `tools/go-env.sh` (revived-toolchain bootstrap + environment iron
rules); the standard shape for a Go port is
[the Go app template](https://venus-homelab.github.io/ios-armv7-builder/docs/go-app-template.md).  Publishing is part of
the job, not an afterthought: `tools/pool-freshness.sh` flags a deb that
was built into `out/` but never reached the pool (the 2026-11-25 ffmpeg
-2 case), and byte-A/B is what turns "rebuild differs sometimes" into a
named wall ([the byte-A/B report](https://venus-homelab.github.io/ios-armv7-builder/docs/byte-ab-report.md)).  The whole
fleet's device acceptance is `bash tests/run-all.sh` (regenerates
`tests/REPORT.md`).

Every other package follows the same shape: `<pkg>/build.sh` produces the
binary, `<pkg>/make-deb.sh` packages it.  In CI this whole flow is
`.github/workflows/single-build.yaml` (run it per package from the Actions
tab); the periodic whole-repo audit is local: `tools/gate-local.sh`
(full-build.yaml / nightly.yml removed 2026-11-25 -- GitHub suspended, and
a hosted runner cannot reach the LAN device).

## Install on the device

The canonical repo URL lives in ONE place: `REPO_URL` in
`scripts/make-repo.sh` (Depiction normalization + install docs quote it —
do not hardcode copies).  The GitHub Pages APT source is live:

```
https://venus-homelab.github.io/ios-armv7-builder/repo
```

Offline install from the local pool also works:

```sh
scp repo/pool/main/*/<pkg>/<pkg>_*_iphoneos-arm.deb <device>:/var/mobile/
ssh root@<device> dpkg -i /var/mobile/<pkg>_<ver>_iphoneos-arm.deb
```

The repository is **signed** (`InRelease` / `Release.gpg`, key
`2A324C4577AB01949BEA46BC8A6DFC60F7F9E596`).  Add it in Cydia/Sileo (you
get the trust prompt), or on
the command line as root — the URL is `REPO_URL` from
`scripts/make-repo.sh`, quoted here as `<REPO_URL>`:

```sh
wget -qO- <REPO_URL>/venus-homelab.asc | apt-key add -
echo "deb <REPO_URL> stable main" > /etc/apt/sources.list.d/ios-tools.list
apt-get update
apt-get install tmux              # /usr/bin/tmux
apt-get install openssl4 curl4    # /var/mobile/openssl4, /var/mobile/tools
apt-get install lsof              # /var/mobile/tools/lsof
apt-get install wget4 git vim     # /var/mobile/tools/{wget,git,vim}
apt-get install sqlite3 jq tcpdump # /var/mobile/tools/{sqlite3,jq,tcpdump}
apt-get install nmap               # /var/mobile/tools/{nmap,ncat} + share/nmap
apt-get install netstat4            # /var/mobile/tools/bin/netstat
apt-get install ifconfig4           # /var/mobile/tools/ifconfig/{ifconfig,route} + /usr/bin links
```

Every package name in an `apt-get install` line is pool-checked by
`tools/doc-rot-check.sh` (the 2026-11-25 node4 drift: node moved out of
this kit on 2026-11-24).

The live package list is generated from the APT index — see docs/PACKAGES.md (do not hand-edit counts here) — including `dropbear4`
and `openssh4`, which shadow system SSH components: an `apt-get upgrade`
can now update them — re-check ports and re-load the daemon after such an
upgrade. The manual equivalent, for reference:

```sh
dpkg -i openssh4_10.6p2-1_iphoneos-arm.deb
sudo launchctl load -w /Library/LaunchDaemons/com.hesper.osshd.plist
```

The package ships the job, the wrapper and an `sshd_config`, so an install
gives a running service on port **22** instead of a directory of binaries; host
keys are generated on first start. Re-signing on the device is no longer
needed — the packaging scripts now assert the signature rather than swallowing
the failure that caused the old warning.

`net/openssh/make-deb.sh` takes `OSSH_PORT=` to package it elsewhere, and
`net/dropbear/make-deb.sh` takes `DROPBEAR_PORT=` (plus `DROPBEAR_EXTRA_ARGS=` for
an extra `-p`) for the same reason. Both default to 22.

Which packages the repository carries is simply what `scripts/make-repo.sh`
finds under `out/` at generation time — there is no allowlist; remove a
`.deb` from `out/` before regenerating if you do not want it published.

The *libraries* stay untouched: `/usr/lib/libcrypto.dylib` and the shared
cache are what `sshd` and the rest of iOS are linked against, and replacing
them bricks remote access. Removing the packages (`rm -rf /var/mobile/openssl4`)
leaves the device exactly as it was.

### Making them the default on a device

If you want the new tools to answer to their bare names, **symlink rather than
copy** — a symlink is one `rm` from being reverted, keeps a single source of
truth, and leaves dpkg's md5sums valid, whereas a file copied into a
dpkg-owned path is silently clobbered back to 0.9.8zg by the next
`--reinstall`.

Three things that are easy to get wrong:

* A **non-login shell** (`sh -c`, scripts, launchd jobs) gets
  `PATH=/usr/bin:/bin` and cannot see `/usr/local/bin` at all, so a link placed
  only there leaves scripts on the old versions. Put links in `/usr/bin` too,
  but only for files no dpkg package owns.
* Do not `dpkg -r` the old packages. `openssh` owns `/usr/sbin/sshd` and the
  ssh clients, and `sshpass` depends on it; removing it is the one step in this
  whole exercise that can cost remote access. Shadow, do not delete.
* Never write over a dpkg-owned binary — write a symlink somewhere earlier on
  `PATH` instead.

Which links actually exist on the author's iPad, and how to undo them, is in
`DEVICE.md` (not published).


