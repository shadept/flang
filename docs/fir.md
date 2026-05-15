# FIR — FLang Intermediate Representation

FIR is a **typed, SSA, block-based IR** designed as a portable subset of
QBE / Cranelift / LLVM IR. The goal: any FIR module translates to any of
those three (and to C) by mechanical, near-1:1 rewriting.

FIR is target-shaped, not language-shaped. Generics, sum types, closures,
defer, pattern matching, and slices are lowered *before* FIR. By the time
something is in FIR, it's already a flat program of integers, floats,
pointers, and byte buffers.

## Goals

- **Simple.** Fits in one head. ~25 instructions, 7 types, one CFG model.
- **Portable.** Same semantics as QBE/Cranelift/LLVM whenever possible —
  divergence is a smell.
- **Optimisable.** SSA + explicit basic blocks give DCE, copy-propagation,
  constant-folding, mem2reg, and dominance analysis for free.
- **Convertible.** A naive walker → QBE/Cranelift/LLVM/C is a few hundred
  LOC each.

## Non-goals

- Aliasing analysis, atomics, exceptions, GC barriers, vectors, SIMD.
  Vector ops, atomics, and CPU intrinsics (popcount, clz, bswap, …) live
  in sibling C files surfaced via `#foreign`. Promote into FIR only if
  measurement justifies inlining them.
- Debug info (DWARF/PDB) — add later as a side-channel attached to
  values/blocks/instructions, not part of the core type.
- Inline assembly. Use a `call @foreign_fn` instead.

## Module

```
module := global* foreign_decl* function*
```

- `global` — named static buffer in the data segment with size + align +
  optional initialiser bytes.
- `foreign_decl` — external symbol with a signature. C ABI by default;
  per-symbol convention can be added later.
- `function` — defined function (see below).

There is no notion of "imported FIR module." Linking is the host
toolchain's job; FIR modules are compiled independently to objects.

## Types

Seven types, full stop.

```
i8  i16  i32  i64    // integers, sign-agnostic at the type level
f32  f64             // IEEE 754 floats
ptr                  // opaque pointer (target-pointer-width)
```

Aggregates (structs, enum variants, arrays, slices) are **not FIR types**.
They are byte buffers — represented as `ptr` to memory of a known size and
alignment, accessed via `gep` + `load` / `store`. Layout (offsets, padding,
sizes) is the lowering pass's responsibility, finalised before FIR is
emitted.

Boolean is not a type. `icmp` / `fcmp` produce `i8` with value `0` or `1`.
Branches take any integer operand and treat zero as false. This matches
QBE; LLVM's `i1` is synthesised at the backend.

Signedness is **not** part of the type. Operations that care (division,
remainder, comparison, integer↔float conversion, right shift) come in
signed/unsigned variants.

Sizes and alignments (target-independent for the integer/float types):

| Type | Size | Align |
|------|------|-------|
| i8   | 1    | 1     |
| i16  | 2    | 2     |
| i32  | 4    | 4     |
| i64  | 8    | 8     |
| f32  | 4    | 4     |
| f64  | 8    | 8     |
| ptr  | target-word | target-word |

## Values

Every value is an SSA register, **defined once**. Names are local to the
function (`%v0`, `%name`, etc.). Each value has a static type, printed
inline as `%name: type` at the definition site.

Operands are one of:

- Local SSA value `%v`
- Integer immediate `42`, `0xff`, `-1`
- Float immediate `3.14`, `0.0`
- Null pointer `null` (type `ptr`)
- Global reference `@name` (type `ptr`)
- Function reference `@func` (type `ptr`)

Constants don't need explicit types — they take the type required by the
instruction's operand position.

## Functions

```
fn @name(%v0: t0, %v1: t1, ...) -> ret_ty? {
entry:
    instructions...
    terminator
block_label_1(%vN: ty, ...):
    instructions...
    terminator
...
}
```

Function parameters are declared once in the function header. They are
SSA values in scope for the entire function (entry dominates everything
else, so dominance scoping carries them down). The entry block has no
formal parameters of its own. Other blocks may declare parameters,
which receive values from `br` arguments at every predecessor edge.

The return type may be omitted for void functions; `ret` then takes no
operand.

Functions carry a **calling convention** (`cc(C)` is the only value
today; the enum exists so we can add `WindowsX64`, `SystemV`, `FastCall`,
`Swift`, etc. without an IR redesign). Direct `call @foo` reads the cc
from the target's declaration; `call_indirect` carries it inline.

Functions also carry a `variadic: bool` flag. In v1 it must be `false`
for non-foreign functions — internal FIR variadics are reserved as a
future extension (`va_list_init`, `va_arg.<ty>`, `va_list_cleanup`
intrinsics). Foreign decls may set `variadic: true` to model C `...`.
**Source-level FLang variadics still exist**; they are lowered to
non-variadic FIR (typically via monomorphisation) until we decide
otherwise.

## Blocks

A function is a list of basic blocks. Each block:

- Has a label unique within the function.
- Declares zero or more typed parameters (the entry block always has
  zero — its inputs are the function's parameters).
- Contains a (possibly empty) sequence of straight-line instructions
  followed by exactly one terminator.

Blocks **never fall through.** Every block ends in `br`, `br_if`, `ret`,
or `unreachable`. The branch syntax carries arguments to the target
block's parameters, replacing phi nodes.

Values defined in a block are visible to every block it dominates. Block
parameters are only needed where a value reaches a join from multiple
predecessor edges with different values (loop heads, merges from `br_if`).

Domination, CFG edges, predecessor/successor sets are derivable in one
linear pass — there is no explicit predecessor list stored.

## Instruction set

Format: `%result: type = opcode operand0, operand1, ...` for value-producing
instructions; `opcode operand0, operand1, ...` for void instructions and
terminators.

### Integer arithmetic

All take two operands of the same integer type, produce the same type.
Wrap on overflow (two's complement).

```
iadd  isub  imul  ineg
sdiv  udiv  srem  urem
iand  ior   ixor
ishl  ushr  sshr
```

Division by zero, signed division of `INT_MIN / -1`, and shifts by `>= bit
width` are undefined behaviour. Lower defensive checks before FIR if you
want defined behaviour.

### Float arithmetic

```
fadd  fsub  fmul  fdiv  fneg
```

NaN handling and rounding follow IEEE 754 default mode (round-to-nearest-
even). No FP exceptions, no signalling NaN propagation guarantees.

### Compare

Produce `i8` (0 or 1).

```
icmp.eq   icmp.ne
icmp.slt  icmp.sle  icmp.sgt  icmp.sge   // signed
icmp.ult  icmp.ule  icmp.ugt  icmp.uge   // unsigned

fcmp.eq   fcmp.ne                        // ordered (false if NaN)
fcmp.lt   fcmp.le   fcmp.gt   fcmp.ge    // ordered
```

Pointer comparison: use `icmp.eq` / `icmp.ne` on `ptr` operands. Ordering
comparisons on pointers are not defined.

### Conversions

```
trunc.<dst>   v       // narrow integer (e.g. i64 -> i32)
zext.<dst>    v       // zero-extend
sext.<dst>    v       // sign-extend
fptosi.<dst>  v       // float -> signed int
fptoui.<dst>  v       // float -> unsigned int
sitofp.<dst>  v       // signed int -> float
uitofp.<dst>  v       // unsigned int -> float
fpext         v       // f32 -> f64
fptrunc       v       // f64 -> f32
bitcast.<dst> v       // same-size reinterpret (e.g. i32 <-> f32)
ptrtoint.<dst> v      // ptr -> integer (target word width or wider)
inttoptr      v       // integer -> ptr
```

### Memory

```
%p: ptr = stack_slot size, align          // size and align are i64 immediates
%v: ty  = load.<ty> %ptr
          store.<ty> %val, %ptr
%q: ptr = gep %ptr, %offset_i64           // pointer + signed byte offset
          memcpy %dst, %src, %size_i64
          memset %dst, %byte_i8, %size_i64
```

`stack_slot` is the only allocator in FIR. Heap allocations are lowered
to `call @malloc` / `call @free` before FIR.

`gep` is byte-offset, not LLVM-style typed-gep. Field offsets are computed
during lowering and passed as constants — keeps FIR ignorant of layouts.
Array indexing is lowering's job: emit `%off = imul %idx, stride` then
`gep %base, %off`. There is no element-typed sugar form. Semantics:

- **Result is `ptr`.** Element type is carried by the downstream `load.<ty>`
  / `store.<ty>`.
- **Offset is signed `i64`.** Negative offsets are legal.
- **`gep %p, 0` ≡ `%p`.** Optimisers fold it.
- **Past-the-end addresses are legal to construct.** Dereferencing them
  is UB; construction is not.
- **`gep null, n` is legal.** Loading from the result is UB.
- **Wraps on overflow.** No `inbounds`-style nowrap flag in v1.
- **No provenance tracking in v1.** Add `noalias` and provenance rules
  when alias analysis demands it.

Loads and stores are typed. The type tells the backend the access width
and alignment (defaulting to natural alignment for the type).

### Control flow

```
br      target(args...)
br_if   %cond, then(args...), else(args...)
ret     %val?
unreachable
```

`%cond` is any integer type; zero is false, non-zero is true. `args...`
are values passed to the target block's parameters (count and types must
match).

`ret` with no operand returns from a void function. `unreachable` is UB
and signals to optimisers that this path cannot be reached — useful for
exhaustive matches and trap-on-error patterns.

### Calls

```
%r: ty = call @func(args...)
%r: ty = call_indirect sig, %fn_ptr, args...
         call @func(args...)              // void
         call_indirect sig, %fn_ptr, args... // void
```

`@func` is a function reference (resolved at link time). `%fn_ptr` is a
`ptr` value; `sig` is an inline signature `(t0, t1, ...) -> ret_ty? cc(C)`
since FIR doesn't carry function-pointer types.

For variadic foreign calls (`printf` and friends), trailing arg types are
listed at the call site after a `...` marker:

```
%n: i32 = call @printf(@fmt, ..., i32 %x, f64 %y)
```

The trailing types are required: register-class routing on most ABIs
depends on per-argument types.

## Text format example

Factorial:

```
fn @factorial(n: i32) -> i32 {
entry:
    %t0: i8  = icmp.sle n, 1
    br_if %t0, base, recur

base:
    ret 1

recur:
    %t1: i32 = isub n, 1
    %t2: i32 = call @factorial(%t1)
    %t3: i32 = imul n, %t2
    ret %t3
}
```

Loop sum (mutable variable becomes a block parameter):

```
fn @sum_to(n: i32) -> i32 {
entry:
    br loop(0, 0)

loop(i: i32, acc: i32):
    %done: i8  = icmp.sge i, n
    br_if %done, exit(acc), step(i, acc)

step(i: i32, acc: i32):
    %i1:   i32 = iadd i, 1
    %acc1: i32 = iadd acc, i1
    br loop(%i1, %acc1)

exit(r: i32):
    ret r
}
```

Struct field write (struct laid out by the front end as offset 0 = `x:
i32`, offset 4 = `y: i32`):

```
fn @set_y(p: ptr, value: i32) {
entry:
    %q: ptr = gep p, 4
    store.i32 value, %q
    ret
}
```

Globals and foreign:

```
foreign fn @write(fd: i32, buf: ptr, len: i64) -> i64
foreign fn @malloc(size: i64) -> ptr

global @msg: i8[14] = "hello, world!\n"

fn @main() -> i32 {
entry:
    %_: i64 = call @write(1, @msg, 14)
    ret 0
}
```

## Text format

The syntax shown throughout this document **is** the canonical text
format — not pseudo-syntax. `lib/flang_codegen` exposes
`print(module, sb)` to emit exactly this form and `to_json(module, sb)`
to emit a structural dump consumed by the explorer tool. Tools and users
read the text form; the explorer renders both side-by-side.

## C backend: signed/unsigned mapping

Since signedness lives on the *operation*, every FIR `iN` value maps to
the **signed** C type `intN_t` as its canonical representation. Per-op
casts produce correct semantics:

| FIR op              | C lowering                                        |
|---------------------|---------------------------------------------------|
| `iadd / isub / imul`| `(intN_t)((uintN_t)a OP (uintN_t)b)` — wrap       |
| `ineg a`            | `(intN_t)(0u - (uintN_t)a)`                       |
| `sdiv / srem`       | `a OP b` — natural signed                         |
| `udiv / urem`       | `(intN_t)((uintN_t)a OP (uintN_t)b)`              |
| `ishl`              | `(intN_t)((uintN_t)a << b)`                       |
| `sshr`              | `a >> n` — mandated by C23, universal pre-C23     |
| `ushr`              | `(intN_t)((uintN_t)a >> n)`                       |
| `iand / ior / ixor` | natural — operates on bit patterns               |
| `icmp.s*`           | `a OP b`                                          |
| `icmp.u*`           | `(uintN_t)a OP (uintN_t)b`                        |
| `sext.iM v`         | `(intM_t)v`                                       |
| `zext.iM v`         | `(intM_t)(uintN_t)v`                              |
| `trunc.iM v`        | `(intM_t)(intN_t)v` (or rely on implicit narrowing)|

Casts are noisy in the emitted source but every C compiler folds them
out at `-O1`. The backend emits a single `_Static_assert` at the top of
the translation unit to assert arithmetic right shift, in case we end up
on a hypothetical compiler that disagrees:

```c
_Static_assert((-1 >> 1) == -1, "FIR backend requires arithmetic right shift");
```

## Lowered before FIR

The lowering passes that run on the AST/HIR before FIR is emitted:

- **Monomorphisation.** No generics in FIR.
- **Closure lowering.** Captured environment becomes a struct passed as
  a `ptr` first argument.
- **Sum type lowering.** Enums become `{ tag: iN, payload: byte_buffer }`
  laid out by `TypeLayoutService`. Niche optimisation (e.g. `Option(&T)`
  → nullable pointer) applied here.
- **Pattern matching.** Match arms lower to nested `br_if` cascades or
  tag-jump tables, depending on shape.
- **Defer.** Cleanup blocks inlined at every exit point.
- **Slices / strings.** Become `{ ptr, i64 len }` pairs passed as two
  values, or stored in a buffer addressed by `ptr`.
- **Aggregate construction.** Allocated via `stack_slot`, fields written
  with typed stores.
- **Aggregate copy.** Lowered to `memcpy` (or field-by-field for small
  fixed-size aggregates).

## Backend mapping notes

| FIR          | QBE                  | Cranelift           | LLVM IR             | C                          |
|--------------|----------------------|---------------------|---------------------|----------------------------|
| `i8/16/32/64`| `b/h/w/l`            | `i8/i16/i32/i64`    | `i8/i16/i32/i64`    | `int8_t…int64_t`           |
| `f32/f64`    | `s/d`                | `f32/f64`           | `float/double`      | `float/double`             |
| `ptr`        | `l`                  | `r64` or `i64`      | `ptr`               | `void*`                    |
| block params | block params         | block params        | phi nodes (synth)   | locals + assign-at-br      |
| `gep`        | `add` (l)            | `iadd` (i64)        | `getelementptr i8`  | byte ptr arith             |
| `stack_slot` | `alloc4/8/16`        | `stack_slot`        | `alloca`            | local array                |
| `br`         | `jmp` + temp moves   | `jump block(args)`  | `br` + phi setup    | `goto` + assigns           |

The phi-from-block-params transform for LLVM: at each `br target(args)`,
for each `(arg_i, param_i)` pair, add an incoming edge `[arg_i,
current_block]` to a phi placed at the top of `target`.

## C backend (lib/flang_codegen)

The C backend lives in `lib/flang_codegen/src/`:

- `backend.f` — backend-agnostic types: `BuildOptions`, `BuildResult`,
  `BuildError`, `CompilerInfo`. The compilation model (extra `.c` files,
  libraries, include paths, link flags) is shared across backends.
- `c_backend.f` — `translate(&Module, &StringBuilder)` walks FIR and
  emits a C99 translation unit; `compile(&Module, &BuildOptions)` runs
  discovery, writes the `.c`, invokes the C compiler, and returns a
  `BuildResult` with the executable path.

Lowering choices:

- Block parameters hoist to function-scope locals. `br target(args)`
  emits a brace-scoped two-phase write — temps first, then assignments
  — to handle parallel-move corner cases (loop rotations etc.).
- `load.<ty>` / `store.<ty>` round-trip through `memcpy` to dodge
  strict-aliasing UB. The optimiser folds it back to a direct load on
  naturally-aligned access at `-O1`.
- `stack_slot size, align` becomes `_Alignas(align) unsigned char __slotN[size]`
  followed by a `void*` alias for the SSA result.
- `bitcast` round-trips through `memcpy` for the same aliasing reason.

Runtime preamble + main wrapping:

The C backend emits a small runtime block at the top of every
translation unit:

```c
static int __flang_argc = 0;
static char** __flang_argv = 0;
int32_t __flang_get_argc(void);
unsigned char* __flang_get_arg(int32_t index);
unsigned char* __flang_getenv(const unsigned char* name);
```

These are the foreign symbols `stdlib/std/env.f` declares, so user code
that calls `std.env.args_count()` / `arg(i)` / `env(key)` resolves
directly to the C-runtime helpers.

The FIR function named `main` is treated as the program entry point.
Its C signature is rewritten to `int main(int __flang_argc_, char**
__flang_argv_)` and the body is prefixed with two assignments that
copy argc/argv into the runtime globals before any user code runs.
Foreign decls for the three `__flang_*` accessors are filtered out at
emission time so they don't conflict with the preamble definitions.

Compiler discovery (`discover_compiler`):

- **Windows** — first try MSVC: locate `vswhere.exe` under
  `%ProgramFiles(x86)%\Microsoft Visual Studio\Installer`, spawn it with
  `-latest -requires VC.Tools.x86.x64 -property installationPath`, then
  walk `VC\Tools\MSVC\<toolset>\bin\Hostx64\x64\cl.exe`. Windows SDK
  include/lib roots come from `C:\Program Files (x86)\Windows Kits\10`.
  The discovered `INCLUDE`, `LIB`, and `PATH` env vars are attached to
  the spawned `cl.exe` so it works outside a developer prompt. Falls
  back to `cl.exe` / `clang` / `gcc` on `PATH`.
- **macOS** — `$CC` → `xcrun --find clang` → `clang` / `cc` / `gcc`.
- **Linux** — `$CC` → `clang` → `cc` → `gcc`.

The C# implementation in `src/FLang.CLI/CompilerDiscovery.cs` follows the
same algorithm; the self-hosted port is the new source of truth as we
migrate.

## Optimization pipeline

Planned passes that run on FIR before backend translation — principles,
tier-1 cleanup, the shim inliner that catches FLang's mutator-wrapper
pattern, mem2reg / SROA on non-escaping `stack_slot`s, dead-function
elimination, and the verifier — are specified in
[RFC-015](tickets/015-fir-inliner-and-dce.md).

## Open questions

- Function attributes (`noinline`, `cold`, `noreturn`) — defer until we
  need them for `panic` / hot-path tuning.
- Calling conventions beyond C ABI — defer; FLang is C-ABI-only today.
- TBAA / aliasing hints — skip. Add `noalias` on parameters later if
  benchmarks justify.
- Volatile loads/stores for memory-mapped I/O — skip until needed.
- Debug locations on instructions — add as a side-channel
  (`instr_id -> (file, line, col)`) so the core IR stays small.
