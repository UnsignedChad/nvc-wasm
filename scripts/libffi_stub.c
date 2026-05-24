// Minimal libffi stub for nvc-wasm.
//
// nvc only uses libffi to call foreign C subprograms loaded via dlopen.
// In the wasm build there is no dlopen and no foreign subprograms, so the
// real libffi is dead weight (and its wasm32 backend is broken against
// recent Emscripten releases). This stub provides just enough symbols for
// the linker to succeed; any call into ffi_call at runtime aborts.

#include <ffi.h>
#include <stdio.h>
#include <stdlib.h>

#define DEFTYPE(name, sz)                          \
   ffi_type ffi_type_##name = {                    \
      .size = sz, .alignment = sz, .type = 0,      \
      .elements = (struct _ffi_type **)0,          \
   }

DEFTYPE(void,    0);
DEFTYPE(sint8,   1);
DEFTYPE(sint16,  2);
DEFTYPE(sint32,  4);
DEFTYPE(sint64,  8);
DEFTYPE(double,  8);
DEFTYPE(pointer, sizeof(void *));

ffi_status ffi_prep_cif(ffi_cif *cif, ffi_abi abi, unsigned int nargs,
                        ffi_type *rtype, ffi_type **atypes)
{
   (void)cif; (void)abi; (void)nargs; (void)rtype; (void)atypes;
   return FFI_OK;
}

void ffi_call(ffi_cif *cif, void (*fn)(void), void *rvalue, void **avalue)
{
   (void)cif; (void)fn; (void)rvalue; (void)avalue;
   fprintf(stderr, "nvc-wasm: ffi_call invoked but FFI is disabled\n");
   abort();
}
