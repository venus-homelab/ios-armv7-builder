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
