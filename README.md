# nvc-wasm

A WebAssembly build of the [nvc](https://github.com/nickg/nvc) VHDL
analyser/elaborator/simulator. Runs in Node.js today and in any modern
browser with SharedArrayBuffer + cross-origin isolation.

## Status

**Working.** `nvc.wasm` analyses, elaborates, and simulates real VHDL designs
using the IEEE 1993 and 2008 standard libraries:

```text
=== Counter using IEEE numeric_bit (VHDL 2008) ===
** Note: 10ns+0: count = 1
** Note: 20ns+0: count = 2
** Note: 30ns+0: count = 3
...
```

What works:

- VHDL 1993 standard library (`std`, `ieee` including `std_logic_1164`,
  `numeric_bit`, `numeric_std`, `math_real`, the `vital_*` packages)
- VHDL 2008 standard library, minus `IEEE.FIXED_PKG` (known crash; see Limitations)
- The bytecode interpreter path (`--disable-llvm`), which is the only viable
  execution model on wasm
- Threading via Emscripten pthreads (SharedArrayBuffer)
- File I/O via `NODERAWFS=1` (the wasm module sees the host filesystem
  directly when run via Node)

What doesn't:

- VHDL 2019 `STD.REFLECTION` crashes the wasm interpreter mid-elaboration
  (memory access out of bounds — an interpreter bug, not a fundamental
  blocker)
- `IEEE.FIXED_PKG` / `IEEE.FLOAT_PKG` (both std-2008 and std-2019) hit a
  similar crash during the generic-package instantiation
- Foreign C subprograms (VHPI, GHDL-style `--foreign`) are disabled —
  there's no `dlopen` on wasm. The C ABI required to call them would need
  to be replaced with statically-linked symbols at wasm link time.
- LLVM JIT and x86 JIT backends are both disabled; wasm cannot generate
  executable code at runtime.

## Why the previous attempt concluded this was impossible

The previous README said: *"impossible to build nvc for [wasm] without
massive changes because NVC uses dynamic linking and wasm does not support
so."*

That's correct in substance — nvc has four uses of dynamic linking:

1. **Per-design `.so` generation** at elaboration time (`cgen.c`, `make.c`).
   Each VHDL unit becomes a native shared library. Elaboration calls
   `fork()` to invoke the system C compiler, then `dlopen`s the result.
2. **LLVM JIT** (`jit-llvm.c`) and **x86 JIT** (`jit-x86.c`) — runtime native
   code generation; needs `mmap(PROT_EXEC)`.
3. **`dlopen(NULL, ...)`** in `jit-ffi.c` to expose nvc's own internal
   symbols (the `INTERNAL` foreign-function convention).
4. **`dlopen(user.so)`** in `jit-ffi.c` for VHPI / GHDL-style foreign C.

Wasm can do exactly none of these. But nvc *also* has a complete bytecode
interpreter (`jit-interp.c`) that needs none of them. The previous attempt
tried to build the whole machine with `cmake glob *.c` and didn't reach the
point of discovering that `./configure --disable-llvm --without-system-cc`
sidesteps blockers (1) and (2) entirely. (3) and (4) are addressed by the
patches in `patches/nvc-wasm.patch`.

## Building

You need:

- [emsdk](https://github.com/emscripten-core/emsdk) — `latest` is fine
- `autoconf`, `automake`, `flex`, `bison`, `pkg-config`
- `git`, `curl`

```sh
git submodule update --init 3rdparty/nvc
source /path/to/emsdk/emsdk_env.sh
./build.sh
```

Produces `build/wasm/bin/nvc.{js,wasm}` plus the compiled standard
libraries in `build/wasm/lib/`.

## Running

```sh
node build/wasm/bin/nvc -L build/wasm/lib -a your.vhd -e top -r
```

For VHDL-2008:

```sh
node build/wasm/bin/nvc --std=08 -L build/wasm/lib -a your.vhd -e top -r
```

## How it works

`build.sh` does five things, in order:

1. **Applies `patches/nvc-wasm.patch`** to the pinned nvc submodule. The
   patch is small (~40 lines net) and guards wasm-incompatible code with
   `#ifdef __EMSCRIPTEN__`. Source files touched:
   - `src/jit/jit-ffi.c` — stub dlopen/dlsym/dlclose for wasm
   - `src/jit/jit-code.c` — skip `__builtin___clear_cache` on wasm
   - `src/thread.c` — disable signal-based stop-the-world on wasm
   - `src/util.c` — route `nvc_memalign`/`munmap` through `posix_memalign`/`free`
     (mmap's partial-munmap trick doesn't work on Emscripten)
   - `thirdparty/cpustate.c` — no-op stub for register capture on wasm
   - `src/vhpi/vhpi_user.h` — include `<stdint.h>` on Emscripten
   - `src/rt/{assert,simpkg,standard,stdenv}.c` — fix UB in foreign symbol
     signatures (some declared 1-arg but called as 2-arg; works on x86,
     trapped by wasm's strict indirect-call type checking)
   - `src/jit/Makemodule.am` — include the generated `wasm_symtab.c`

2. **Generates `src/jit/wasm_symtab.c`** from `src/symbols.txt`. This is a
   static `(name → function pointer)` lookup table that replaces
   `dlsym(NULL, name)` for nvc's INTERNAL foreign symbols.

3. **Builds wasm dependencies** in `build/wasm-deps/`:
   - Real `libzstd.a` (used by nvc's compressed work-library format)
   - Stub `libffi.a` (the wasm32 backend in upstream libffi 3.4.6 references
     Emscripten JS helpers that were renamed; the stub satisfies the linker
     and any actual call traps at runtime, which is fine because FFI is
     disabled)

4. **Configures nvc** with `emconfigure ./configure --disable-llvm
   --without-system-cc --host=wasm32-unknown-emscripten`, passing
   `--disable-llvm` (no LLVM JIT) and `--without-system-cc` (no AOT-via-
   external-CC). Also pre-seeds a few `ac_cv_func_*=no` cache vars because
   autoconf's function probes give false positives under cross-compile.

5. **Runs `emmake make -k`**. The `-k` lets the build continue past the
   two known stdlib crash points (STD.REFLECTION, IEEE.FIXED_PKG) so we
   still get all the working stdlib units.

## Repository layout

```
.
├── 3rdparty/nvc/         # nvc submodule (pinned upstream commit)
├── patches/
│   └── nvc-wasm.patch    # applied to nvc at build time
├── scripts/
│   ├── build_deps.sh     # builds wasm libzstd + stub libffi
│   ├── gen_wasm_symtab.sh # generates wasm symbol lookup table
│   └── libffi_stub.c     # stub libffi source
├── build.sh              # top-level entry point
└── README.md
```

## Credit

This builds on top of:

- [Zhukov Georgiy's nvc_wasm](https://github.com/zhugeo/nvc_wasm), which
  mapped out the dependency space and concluded it would need "massive
  changes." It does — but they're tractable when you start from
  `--disable-llvm` and don't try to recreate nvc's own autotools in CMake.
- The [nvc compiler](https://github.com/nickg/nvc) by Nick Gasson, GPLv3.
