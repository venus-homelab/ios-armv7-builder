# godeps/ — the darwin/arm-adapted Go dependencies

Three upstream dependency trees, adapted for the revived darwin/arm
(32-bit iOS) port.  They are the ONLY non-upstream Go dependencies in
this repo: everything else resolves from go.sum through the module
proxy like any Go build.

The trees are committed in full (not patches) because each carries
dozens of small edits across type definitions, ioctl constants and
syscall stubs — a 32-bit darwin port touches nearly every
`*_ztypes_darwin_arm*.go`-shaped file, and per-file patches would be
harder to review than the trees themselves.

| tree | upstream base | why it exists |
|---|---|---|
| xsys-darwin-arm  | golang.org/x/sys v0.48.0 | darwin/arm (32-bit) type definitions, RTF_GLOBAL/RTF_DEAD/RTF_LLDATA, the syscall stubs the pure-Go runtime calls; probe leftovers (probe-*.o) removed |
| xnet-darwin-arm  | golang.org/x/net v0.60.0 | the route/BPF surfaces 32-bit darwin needs (wall #1 companion) |
| uroot-darwin-arm | github.com/u-root/u-root v0.16 | the pieces tailscaled's userspace-networking path vendors |

Provenance: each tree is the upstream module at the version above with
the darwin/arm32 adaptations applied during the tailcat 0.7.0 port
(2026-11-19, commit ee291af1 era) and the tailscale 1.104.7 port
(2026-11-19).  The diff against pristine upstream is what
docs/go.md and docs/tailscale.md describe.

Consumers wire them with go.mod `replace` directives pointing at
`../../godeps/<tree>` (see tailscale/build.sh, which rewrites the
replace lines after fetching the pristine tailscale source).

Regeneration: re-diff the upstream module at the new version against
these trees when bumping a dependency — the adaptations must be
carried forward explicitly, never re-invented.
