#!/bin/sh
# Rebuild using Bellard QuickJS and the wasi-sdk 25.0 clang distribution.
set -eu
: "${WASI_SDK_PATH:?Set WASI_SDK_PATH to the extracted wasi-sdk-25.0 directory}"
root=$(cd "$(dirname "$0")/../.." && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cd "$stage"
curl -fsSLo quickjs.tar.xz https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz
echo 'b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a  quickjs.tar.xz' | shasum -a 256 -c -
tar xf quickjs.tar.xz
cd quickjs-2026-06-04
# This single-threaded target has no pthreads; retain upstream stack checking.
sed '/^#define CONFIG_ATOMICS$/d' quickjs.c > quickjs-wasi.c
"$WASI_SDK_PATH/bin/clang" -Oz -std=gnu11 -D_GNU_SOURCE -DNDEBUG \
  '-DCONFIG_VERSION="2026-06-04"' -include malloc.h -mllvm -wasm-enable-sjlj \
  -I . -Wl,-z,stack-size=1048576 -Wl,--max-memory=67108864 -Wl,--strip-all \
  quickjs-wasi.c dtoa.c libregexp.c libunicode.c cutils.c "$root/tool/quickjs/runner.c" \
  -o "$root/assets/program_runner/quickjs.wasm"
chmod 644 "$root/assets/program_runner/quickjs.wasm"
