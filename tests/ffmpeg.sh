#!/bin/bash
# tests/ffmpeg.sh -- device acceptance for ffmpeg (the largest port; static
# against libSystem + openssl/zlib/libios-compat, no Depends).
source "$(dirname "$0")/lib.sh"
F=/var/mobile/tools/bin/ffmpeg
P=/var/mobile/tools/bin/ffprobe
expect_ver "ffmpeg: version" "$F -version 2>&1 | head -1" "ffmpeg version 9.0.2"
expect_rc0 "ffmpeg: ffprobe present" "test -x $P"
expect_rc0 "ffmpeg: lavfi synth roundtrip" "$F -v error -f rawvideo -pix_fmt gray -s 64x64 -r 10 -i /dev/zero -frames:v 8 -f null - 2>&1"
summary ffmpeg
