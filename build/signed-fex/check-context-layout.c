#include <stddef.h>
#include <windef.h>
#include <winnt.h>
#include "SignedFEX.h"
_Static_assert(sizeof(struct MadeiraFEXContext) == sizeof(AMD64_CONTEXT), "AMD64 context size");
_Static_assert(sizeof(struct MadeiraFEXContext) == sizeof(ARM64EC_NT_CONTEXT), "ARM64EC context size");
_Static_assert(offsetof(struct MadeiraFEXContext, flags) == offsetof(AMD64_CONTEXT, ContextFlags), "Context flags");
_Static_assert(offsetof(struct MadeiraFEXContext, gregs) == offsetof(AMD64_CONTEXT, Rax), "Integer registers");
_Static_assert(offsetof(struct MadeiraFEXContext, rip) == offsetof(ARM64EC_NT_CONTEXT, Pc), "Instruction pointer");
_Static_assert(offsetof(struct MadeiraFEXContext, floating) == offsetof(AMD64_CONTEXT, FltSave), "Floating-point state");
