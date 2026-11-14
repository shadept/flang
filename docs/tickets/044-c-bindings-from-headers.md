---
type: compiler
created: 2026-11-13
linear: SH-57
accepted: 2026-11-14
implemented: 2026-11-14
relates: [RFC-037, RFC-043]
---

# RFC-044: C bindings from headers

**Deviations.** A struct FLang cannot lay out as C does (bit-fields, packing, alignment attributes)
is emitted opaque rather than left out, so it stays usable behind a pointer. A C type named
lowercase is capitalized (`rAudioBuffer` -> `RAudioBuffer`) instead of skipped; C never sees FLang's
type names. A macro expanding to a single float literal becomes an `f32`/`f64` constant. Macros
named like a FLang keyword (`true`, `false`) are dropped. Headers are made absolute before probing.

## Summary

`flang build` turns every header listed under `[build.<os>].headers` into `vendor/<stem>.f`
before module discovery, so `import vendor.SDL` works with no hand-written bindings. Two `#foreign`
forms land with it, because C headers are full of them and FLang has no spelling today:

```flang
pub type SDL_Window = #foreign struct {}        // opaque: C's `struct SDL_Window;`

pub type SDL_Event = #foreign union {           // C union: members overlap at offset 0
    type_: u32
    common: SDL_CommonEvent
    key: SDL_KeyboardEvent
    padding: [u8; 128]
}

#foreign pub fn SDL_CreateWindow(title: &u8?, w: i32, h: i32, flags: u64) &SDL_Window?
```

The generated module is the raw layer: a faithful transcription of the header, no invented
semantics. Ownership, nullability, and pointer/length pairing are not in a header, so a safe API
stays hand-written on top.

## Motivation

- **The feature regressed.** The self-hosted compiler parses `headers` into `PlatformConfig` and
  drops it. Generation lived only in the C# reference (CppAst over libclang), removed in
  `e5199d77`. `examples/raylib` no longer builds; `examples/sdl3` carries 43 lines of hand-written
  bindings.
- **Handles are untyped.** Every opaque C handle is `&u8`, so `SDL_DestroyRenderer(window)`
  type-checks.
- **Unions have no spelling.** `SDL_Event` is hand-written as `{ kind: u32, rest: [u8; 124] }`.
  A byte blob is ABI-correct only by luck: SysV classifies an aggregate by what its members are,
  and a blob of a float-carrying union would claim the wrong registers.

## 1. Opaque types: `#foreign struct {}`

An empty `#foreign struct` is an incomplete C type. C has no empty structs, so the form is free;
no non-foreign zero-field struct changes meaning (`Type(T)`, `Context`, `Environment` stay as they
are). It parses today.

- Usable only as the target of a reference: `&T`, `&T?`, and inside other types through one
  (`List(&T)`, `#foreign fn(&T)`).
- **E2159** for every by-value use: a parameter, return, field, `let` annotation, array element or
  generic argument of type `T`; a literal `T {}`; a dereference of `&T`; `size_of(T)`,
  `align_of(T)`, `type_info(T)`.
- Distinct handle types do not unify: `&SDL_Window` is not `&SDL_Renderer`. `p as &u8` and back
  stay available through the existing reference cast.
- Behind a reference it emits as `void*`, as every reference does; the type never reaches the
  C backend.

## 2. Unions: `#foreign union { ... }`

`union` is a contextual keyword, recognised only as a type-declaration builder after `#foreign`
(`Bitset.union` keeps its name; `owned` is the precedent). `union` without `#foreign` is **E2161**.

- **Layout.** Every member at offset 0. Size is the largest member rounded up to the strictest
  alignment; alignment is the strictest member alignment. Emitted as a C `union` when it crosses a
  `#foreign` boundary by value, so the C compiler classifies it.
- **Members** are plain C data: primitives, references, arrays, `#foreign` structs and unions,
  `#foreign fn` types. An `owned` member or a non-copyable member type is **E2161**: there is no
  tag to say which member a release would run on.
- **Access** reads and writes members like fields. Reading a member other than the last one
  written reinterprets the bytes, as in C.
- **Literal** sets exactly one member: `SDL_Event { key = k }`. The rest of the storage is zeroed.
  Zero or several members is **E2160**. `.{ ... }` follows the same rule.
- **Patterns** do not destructure a union (**E2162**): without a tag every arm would match.
- **RTTI** reports `TypeKind.Union`, members at offset 0, so a generic field walker (`format`,
  derives) can tell a union from a struct.

## 3. Binding generation

### Pipeline

Per header, before `analyze_project`:

1. Expand `${VAR}` in `headers` (the expansion `libs` and `ldflags` already get).
2. **Stamp check.** `vendor/<stem>.stamp` lists the library headers the last run visited, each
   with its FNV-1a hash. All match: skip. No compiler is discovered and nothing is spawned.
3. **Probe.** Scan the header's directory tree for object-like `#define NAME` lines. Write a probe
   file: `#include "<header>"`, then one `__flang_probe "NAME" NAME __flang_end` line per name.
4. **Preprocess** the probe with the build's own C compiler (`cl /E`, `$CC -E`, clang, gcc: the
   discovery the C backend uses). No new dependency on any platform. The compiler expands the
   macros, so `SDL_UINT64_C(0x1)` arrives as `0x1ULL`. The include path is the header's
   directory and its parent, so a library that includes itself by its own folder name
   (`<SDL3/SDL_stdinc.h>`) resolves with no manifest key. Anything else missing is a
   preprocessor error naming the include.
5. **Parse** the output in `lib/flang_bindgen`: line markers (`# 12 "f.h"` and MSVC's
   `#line 12 "f.h"`), then C declarations. Integer constant expressions are evaluated for enum
   values, array sizes and macro probes. A probe expanding to string literals (adjacent ones
   concatenated) becomes a string constant. Any other probe is dropped silently (include guards,
   attributes, type names).
6. **Emit** `vendor/<stem>.f` and the stamp, each written to a temp file and renamed.

Only declarations whose line marker points inside the listed header's directory are emitted;
system headers contribute types by reference only.

### Type mapping

Generation runs on the build host, so the mapping is the host's C ABI (`long` is `i32` on Windows,
`i64` on LP64). `vendor/` is regenerated per machine and stays gitignored.

| C | FLang |
| --- | --- |
| `char`, `unsigned char` / `signed char` | `u8` / `i8` |
| `short`, `int`, `long long`, unsigned forms | `i16`, `i32`, `i64`, `u..` |
| `long`, `unsigned long` | host width |
| `float`, `double` | `f32`, `f64` |
| `_Bool`, `bool` | `bool` |
| `intN_t`, `uintN_t`, `size_t`, `ptrdiff_t`, `intptr_t`, `uintptr_t` | `iN`, `uN`, `usize`, `isize`, `isize`, `usize` |
| `T*`, `void*` | `&T?`, `&u8?`: parameters and returns alike, since a C pointer may be null |
| `T x[N]` field / param | `[T; N]` / pointer |
| function pointer | `#foreign fn(...) R` |
| `struct S { ... }` / `union U { ... }` | `#foreign struct` / `#foreign union` |
| incomplete `struct S` (here or in a system header) | `#foreign struct {}` |
| `enum E { ... }` | `pub type E = i32` (`u32` when a value exceeds `i32`) plus `pub const` per constant |
| `typedef T Name` | transparent alias `pub type Name = T` |
| object-like `#define` folding to an integer | `pub const`, typed by C's rules (`u` suffix `u32`, `ULL` `u64`) |
| object-like `#define` expanding to string literals | `pub const NAME = "..."` (`String`; C takes `Some(NAME.ptr)`) |

Anonymous nested structs and unions get a synthesized name, `<Outer>_<field>`; an unnamed member
becomes field `anon<N>`. A C name that is a FLang keyword gains a trailing `_` (`type_`); the
backend emits positional member names, so renaming never changes the C side.

### Skipped, with a warning naming the declaration

- variadic functions; `long double`; bit-fields; structs under `#pragma pack` (the pragma survives
  preprocessing); `_Alignas`/`__declspec(align)` members; anything using a skipped type by value.
- `static inline` functions are skipped silently: their symbols are not in the library.
- Global variables (`extern int x;`), not in v1.

### Diagnostics

A preprocessor failure or a parse error is a build error prefixed `FFI:` naming the header and
line, printed in the pre-analysis style (`flang: ...`, exit 1). A skipped declaration is a
warning. `flang check` and `flang test` run generation too; they share `build_project`.

## 4. Considered and not included

- **Tagless `#foreign enum` as a union.** Same bytes, but `match`, `as i32` and exhaustiveness
  would all have to be switched off, and reading by member is field access, not anything an enum
  does.
- **Byte blob plus generated accessors.** No language change, but by-value ABI is right only by
  accident, and the debugger shows bytes.
- **clang `-ast-dump=json`.** A new dependency (Linux ships gcc, Windows builds use MSVC), and its
  function types arrive as spelled strings (`"int (*)(void *, int)"`), so a C declarator parser is
  needed anyway.
- **A C header reader in the stdlib.** The reader needs an external preprocessor; the stdlib
  depends on nothing outside itself. A FLang preprocessor would remove that, at the cost of a C
  frontend.
- **Generated safety wrappers.** Ownership pairs, nullability, pointer/length pairs and the
  live-member tag of a union are conventions, not declarations; inferring them guesses
  differently per library, and a wrong guess is silently wrong at an FFI boundary. If the
  hand-written wrappers for SDL3, raylib and a third library repeat a pattern, an opt-in hints
  section in `flang.toml` is a later RFC.
- **Compiler identity in the stamp.** Switching C compilers can change what a header declares;
  checking it would cost discovery on every build. A header edit regenerates; a compiler switch
  needs `vendor/` deleted.

## 5. Implementation

No promote: the compiler only writes `union` and empty `#foreign struct` as text in generated
modules; its own sources declare neither.

### Phase 1: language (`#foreign union`, opaque)

- Parser: a `union` arm beside `struct` in `parse_type_decl_with_directives`, recognised by text.
  The CST node stays `StructDecl`; `AnonStructType` gains `is_union`, so every existing
  `AnonStruct` consumer keeps working. fmt needs nothing beyond the keyword token.
- Typer: `StructDef.is_foreign: bool` becomes `repr: Repr { Flang, C, CUnion, COpaque }`, set at
  placeholder registration from the AST (fields are empty until the body resolves, so opacity
  cannot be read off `fields`). The incremental fingerprint renders `repr`.
  - E2159: a type-position flag beside `sugar_ok` in `resolve_type_expr` (true only directly under
    a reference), plus `check_deref`, `check_struct_lit`, `reified_type_of`.
  - E2160: `report_missing_fields` branches on `CUnion` (both literal paths).
  - E2161: `check_foreign_fields` extended for union members; the parser hands `union` without
    `#foreign` to the checker.
  - E2162: struct-pattern checking.
- Driver: `layout.f` takes `repr` from the def; `fields_layout` puts every union member at
  offset 0. `c_layout_agrees` gains the union rule; `AggDef` a union flag; `emit_agg_type` a
  `typedef union` branch.
- RTTI: `TypeKind.Union` in `core.rtti`, `flang_typer/rtti.f`, `comptime.f`.
- Harness: union layout against C (`size_of`, offsets, a by-value round trip through a C shim with
  a float member), opaque handle round trip, one `error_e2159..e2162_*.f` each. Spec §10,
  `docs/error-codes.md`.

### Phase 2: `lib/flang_bindgen`

Depends on `flang_core` only. Text in, text out; no process or file access.

- `lexer.f`: C tokens, line markers in both spellings.
- `parser.f`: declarations into a model (`CFunction`, `CRecord` struct/union, `CEnum`, `CTypedef`)
  tagged with their source file. Skips extensions (`__declspec(...)`, `__attribute__((...))`,
  `__cdecl`, `__forceinline`, `__extension__`, `__asm__(...)`, `__restrict`, `_Static_assert`) and
  brace-matched function bodies; tracks `#pragma pack`.
- `consteval.f`: integer constant expressions (literals with suffixes, casts to integer types,
  unary and binary operators, references to earlier enum constants).
- `macros.f`: object-like `#define` names from header text; the probe file; reading probe results
  back.
- `emit.f`: model to FLang source, with the mapping and skip rules above.
- Colocated `test {}` blocks over fixed preprocessed snippets in both MSVC and GNU shape: each
  extension skipped, declarators (function pointers, arrays of pointers, pointer to array),
  consteval, nested anonymous records, keyword renaming, emission output.

### Phase 3: driver integration

- `c_backend.f`: `pub fn preprocess(info, path, include_dirs) Result(OwnedString, BuildError)`
  beside `run_compiler`, reading stdout apart from stderr (`run_compiler` merges them).
- `flang_driver/src/bindings.f`: per header, stamp check, then lazy `discover_compiler`, probe,
  preprocess, `flang_bindgen`, atomic writes. Returns warnings and errors as data; `main.f`
  prints.
- `main.f::build_project`: expand `headers` and run generation
  between `parse_project` and `analyze_project`. The `${VAR}` expansion moves ahead of analysis.
- `test-all.cs` lists `lib/flang_bindgen` (and the missing `flang_codegen`, `flang_fmt`).
- An end-to-end project with a self-contained fixture header and a companion `.c`, so the test
  needs no external library.

### Phase 4: examples and docs

- `examples/sdl3`: delete `src/sdl.f`, add
  `headers = ["${SDL3_PATH}/include/SDL3/SDL.h"]`, adapt `main.f` to the generated names and
  types (`SDL_Event.key`, `&SDL_Window?`, `Some(...)` at pointer arguments, `i32` scancodes).
- `examples/raylib`: `[build.windows]` against the raylib 6.2 `win64_msvc16` release (static
  `raylib.lib` plus the Windows system libraries it links); `Some(...)` at pointer arguments; drop
  the retired `-I/-L` comment in `main.f`. READMEs name the tested versions (raylib 6.2,
  SDL 3.4.20).
- Spec §7.6.1 rewritten (manifest-driven, mapping table, skip rules), §10 (§1-§2 above).
  `docs/architecture.md`: the FFI section (drop the stale `foreign_includes` and checked-in
  `vendor/` claims), the library table and graph. `docs/known-issues.md`: retire the
  "headers unconsumed" entry; add the LSP gap (the LSP does not generate, so `vendor.*` is
  unresolved in the editor until a build has run) and the compiler-switch staleness. Ticket
  index row.

## Settled in review

- **Every pointer is `&T?`.** There is no implicit `T -> T?` (ADR-0005), so call sites wrap
  (`SDL_RenderClear(Some(r))`). Faithful wins: mapping parameters to `&T` would make `NULL`
  unpassable (`SDL_CreateRenderer(w, NULL)`).
- **No include key.** The header's directory and its parent cover both target libraries.
- **String `#define`s are in v1.** raylib has `RAYLIB_VERSION`; SDL3 has 588
  (`SDL_PROP_*`, `SDL_HINT_*`).
