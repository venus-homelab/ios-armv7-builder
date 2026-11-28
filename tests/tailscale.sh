#!/bin/bash
# tests/tailscale.sh -- userspace-netstack build; the CLI must be signed
# and versioned; tailscaled presence (the daemon script manages it).
source "$(dirname "$0")/lib.sh"
T=/var/mobile/tools/tailscale/bin/tailscale
expect_ver "tailscale: version" "$T version 2>&1 | head -1" "1.104.7"
expect_rc0 "tailscale: tailscaled staged" "test -x /var/mobile/tools/tailscale/bin/tailscaled"
summary tailscale
