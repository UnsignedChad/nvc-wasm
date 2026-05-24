#!/bin/bash
# nvc-wasm top-level build.
#
# Requires:
#   - emsdk installed and active (source emsdk_env.sh)
#   - autotools (autoreconf / automake / autoconf), flex, bison
#   - the 3rdparty/nvc submodule initialised
#
# Produces build/wasm/bin/nvc{.js,.wasm}, runnable via Node:
#   node build/wasm/bin/nvc -L build/wasm/lib -a foo.vhd -e foo -r
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NVC="$ROOT/3rdparty/nvc"
BUILD="$ROOT/build/wasm"
DEPS="$ROOT/build/wasm-deps"

if ! command -v emcc >/dev/null 2>&1; then
   echo "error: emsdk environment is not active (emcc not on PATH)" >&2
   echo "       run: source /path/to/emsdk/emsdk_env.sh" >&2
   exit 1
fi

if [ ! -f "$NVC/configure.ac" ]; then
   echo "error: $NVC/configure.ac not found; did you 'git submodule update --init 3rdparty/nvc'?" >&2
   exit 1
fi

# 1. Apply the nvc-wasm patch (idempotent).
cd "$NVC"
if ! git apply --check --reverse "$ROOT/patches/nvc-wasm.patch" >/dev/null 2>&1; then
   echo "[1/5] applying patches/nvc-wasm.patch"
   git apply "$ROOT/patches/nvc-wasm.patch"
else
   echo "[1/5] patch already applied"
fi

# 2. Generate src/jit/wasm_symtab.c from symbols.txt.
echo "[2/5] generating wasm symbol lookup table"
"$ROOT/scripts/gen_wasm_symtab.sh" "$NVC"

# 3. Build wasm-compatible deps (libzstd, stub libffi).
echo "[3/5] building wasm dependencies"
PREFIX="$DEPS" "$ROOT/scripts/build_deps.sh"

# 4. autoreconf + emconfigure.
echo "[4/5] configuring nvc for wasm32-emscripten"
cd "$NVC"
[ -f configure ] || ./autogen.sh
mkdir -p "$BUILD"
cd "$BUILD"
if [ ! -f Makefile ]; then
   zlib_CFLAGS="-sUSE_ZLIB=1" zlib_LIBS="-sUSE_ZLIB=1" \
   libffi_CFLAGS="-I$DEPS/include"  libffi_LIBS="-L$DEPS/lib -lffi" \
   libzstd_CFLAGS="-I$DEPS/include" libzstd_LIBS="-L$DEPS/lib -lzstd" \
   ac_cv_func_fpurge=no ac_cv_func_gettid=no ac_cv_func_tcgetwinsize=no \
   emconfigure "$NVC/configure" \
      --disable-llvm --without-system-cc --disable-lto \
      --host=wasm32-unknown-emscripten \
      CFLAGS="-O2 -sUSE_ZLIB=1" \
      LDFLAGS="-sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=64MB -sMAXIMUM_MEMORY=2GB -sNODERAWFS=1 -sEXIT_RUNTIME=1"
fi

# 5. Build. -k so we still produce the stdlib units that DO work even if
# the known-broken ones (STD.REFLECTION, IEEE.FIXED_PKG) crash the wasm
# interpreter -- those are tracked nvc-wasm bugs, not blockers.
# Run twice: with -j -k a stdlib unit can be skipped because its dep was
# in-flight when a sibling fatal'd; the second pass picks it up.
echo "[5/5] building nvc.wasm and standard library"
emmake make -k -j"$(nproc)" || true
emmake make -k -j"$(nproc)" || true

if [ -f bin/nvc.wasm ]; then
   echo
   echo "built: $BUILD/bin/nvc.wasm"
   echo "run:   node $BUILD/bin/nvc -L $BUILD/lib -a your.vhd -e top -r"
else
   echo "build failed" >&2
   exit 1
fi
