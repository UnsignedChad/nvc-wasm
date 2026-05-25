#!/bin/bash
# Build the wasm-compatible dependencies that nvc needs to link.
#
# Produces in $PREFIX:
#   - libzstd.a  (real wasm-compiled zstd, used for the work-library format)
#   - libffi.a   (a minimal stub; nvc's wasm build never invokes FFI at runtime
#                 because dlopen / foreign C subprograms are disabled)
set -euo pipefail

if ! command -v emcc >/dev/null 2>&1; then
   echo "error: emsdk environment is not active (emcc not on PATH)" >&2
   echo "       run: source /path/to/emsdk/emsdk_env.sh" >&2
   exit 1
fi

PREFIX="${PREFIX:-$PWD/build/wasm-deps}"
WORK="${WORK:-$PWD/build/wasm-deps-src}"

ZSTD_VER=1.5.6
LIBFFI_VER=3.4.6

mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$WORK"

# --- zstd ----------------------------------------------------------------
if [ ! -f "$PREFIX/lib/libzstd.a" ]; then
   cd "$WORK"
   [ -d "zstd-$ZSTD_VER" ] || \
      curl -sL "https://github.com/facebook/zstd/releases/download/v$ZSTD_VER/zstd-$ZSTD_VER.tar.gz" | tar xz
   cd "zstd-$ZSTD_VER/lib"
   emmake make CC=emcc AR=emar libzstd.a -j"$(nproc)"
   cp libzstd.a "$PREFIX/lib/"
   cp zstd.h zstd_errors.h "$PREFIX/include/"
   cat > "$PREFIX/lib/pkgconfig/libzstd.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: zstd
Description: fast lossless compression algorithm library
Version: $ZSTD_VER
Libs: -L\${libdir} -lzstd
Cflags: -I\${includedir}
EOF
fi

# --- libffi (stub) -------------------------------------------------------
if [ ! -f "$PREFIX/lib/libffi.a" ] || [ ! -f "$PREFIX/include/ffi.h" ]; then
   cd "$WORK"
   [ -d "libffi-$LIBFFI_VER" ] || \
      curl -sL "https://github.com/libffi/libffi/releases/download/v$LIBFFI_VER/libffi-$LIBFFI_VER.tar.gz" | tar xz

   # Configure libffi just to get the public headers (ffi.h, ffitarget.h).
   # We do NOT use its compiled .a because the wasm32 backend depends on JS
   # helpers (generateFuncType / uleb128Encode) that were renamed in recent
   # Emscripten versions. nvc never calls into libffi in the wasm build, so
   # a tiny stub satisfies the linker.
   cd "libffi-$LIBFFI_VER"
   if [ ! -f include/ffi.h ]; then
      # libffi configure does a libffi_dependency check that fails on newer
      # emscripten (renamed JS helpers); tolerate the failure, then verify
      # the headers we actually need landed in include/.
      set +e
      emconfigure ./configure \
         --prefix="$PREFIX" \
         --host=wasm32-unknown-emscripten \
         --disable-shared --enable-static \
         --disable-multi-os-directory --disable-builddir \
         >/dev/null 2>&1
      set -e
      if [ ! -f include/ffi.h ] || [ ! -f include/ffitarget.h ]; then
         echo "error: libffi configure failed to produce ffi.h/ffitarget.h" >&2
         exit 1
      fi
   fi
   cp include/ffi.h include/ffitarget.h "$PREFIX/include/"

   cd "$PREFIX"
   emcc -O2 -c -I"$PREFIX/include" \
      "$(dirname "$0")/../scripts/libffi_stub.c" -o libffi_stub.o
   rm -f lib/libffi.a
   emar rcs lib/libffi.a libffi_stub.o
   emranlib lib/libffi.a
   rm -f libffi_stub.o

   cat > "$PREFIX/lib/pkgconfig/libffi.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libffi
Description: stub for nvc-wasm (FFI disabled)
Version: $LIBFFI_VER
Libs: -L\${libdir} -lffi
Cflags: -I\${includedir}
EOF
fi

echo "wasm deps ready in: $PREFIX"
