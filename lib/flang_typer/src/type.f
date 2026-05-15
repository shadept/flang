// Ty ADT — the closed set of value shapes the inference engine reasons
// about. Pure data: every constructor is plain; the engine owns all
// allocator-bearing operations (`mk_ref`, `mk_array`, `mk_func`, etc.)
// so this file has no allocator dependencies and can be unit-tested in
// isolation.
//
// The recursion is broken by `&Ty` inside `Ref`, `ArrayTy.elem`, and
// `FunctionTy.ret`. `Tuple(List(Ty))`, `Record(List(Field))`, and
// `Nominal(NominalRef.args)` all rely on `List`'s heap-buffered storage
// — no inline cycles.
//
// Identity rules:
//   - `TyVar` is by `id` (the level/`generation` is metadata). Two
//     `Var(TyVar { id = n })` values with the same id are the same
//     variable regardless of level.
//   - `Prim`, `Never`, `Void`, `Error` are by tag.
//   - `Ref`, `Array`, `Func`, `Tuple`, `Record`, `Nominal` are by their
//     structural payload — see `equals(...)`.
//
// `Error` is poison. Unification with `Error` on either side resolves
// to `Error` and emits no diagnostic, so a single upstream failure does
// not cascade.

import std.list
import std.option
import std.string
import std.string_builder

// ─────────────────────────────────────────────────────────────────────
// Handles — transparent aliases over plain integers so APIs read at a
// glance and the engine pays no wrapping overhead.
// ─────────────────────────────────────────────────────────────────────

// Inference-variable identifier. Allocated by the engine; opaque to
// callers. Two `TyVar`s with the same `VarId` are the same variable.
pub type VarId = u32

// Let-generalisation depth. Variables created at a deeper level than the
// current `enter_level`/`exit_level` cursor are eligible to be quantified
// by `generalize`.
pub type Level = u32

// Handle into the `NominalRegistry`. Stable across a single compilation.
pub type NominalId = u32

// ─────────────────────────────────────────────────────────────────────
// Inference variables
// ─────────────────────────────────────────────────────────────────────

// One unification variable. The `level` is metadata used by
// `generalize`/`specialize`; equality is by `id` alone (see `equals`).
pub type TyVar = struct {
    id: VarId
    level: Level
}

// ─────────────────────────────────────────────────────────────────────
// Primitives — tagged, not stringly typed
// ─────────────────────────────────────────────────────────────────────

// The 14 FLang scalar primitives. Compared by tag; no string names
// flow through the type system at runtime. Diagnostic rendering goes
// through `prim_name(...)` in `well_known.f`.
pub type PrimitiveKind = enum {
    Bool
    I8
    I16
    I32
    I64
    ISize
    U8
    U16
    U32
    U64
    USize
    F32
    F64
    Char
}

// ─────────────────────────────────────────────────────────────────────
// Compound shapes
// ─────────────────────────────────────────────────────────────────────

// `[elem; length]` — fixed-size array. `length` is resolved (no Expr
// in the type model); array-length errors are already reported at the
// declaration site.
pub type ArrayTy = struct {
    elem: &Ty
    length: usize
}

// `fn(params) ret`. `params` is owned by this struct; `ret` is boxed
// because there is exactly one. The engine's `mk_func` allocates both.
pub type FunctionTy = struct {
    params: List(Ty)
    ret: &Ty
}

// A name → type pair used for `Record` (anonymous structs) and for
// nominal struct fields when the registry materialises them.
pub type Field = struct {
    name: String
    ty: Ty
}

// Reference into the `NominalRegistry` plus type arguments for the
// instantiation. `args` is empty for non-generic types.
pub type NominalRef = struct {
    id: NominalId
    args: List(Ty)
}

// ─────────────────────────────────────────────────────────────────────
// The ADT
// ─────────────────────────────────────────────────────────────────────

pub type Ty = enum {
    // Unification variable (free or bound; binding lives in the engine's
    // union-find, never on the value).
    Var(TyVar)
    // Built-in scalar.
    Prim(PrimitiveKind)
    // `&T` — non-null reference.
    Ref(&Ty)
    // `[T; N]` — fixed-size array.
    Array(ArrayTy)
    // `fn(args) ret` — function value.
    Func(FunctionTy)
    // `(T0, T1, …)` — positional tuple. Distinct from `Record`; field
    // names are positional and live in the consumer (`format`, codegen
    // tuple-field lookup), not here.
    Tuple(List(Ty))
    // Anonymous struct — name-addressed fields. The structural cousin
    // of `Nominal` for unnamed values. Field order matters: `equals`
    // and codegen both walk positionally.
    Record(List(Field))
    // User-declared struct or enum, parameterised by `args`.
    Nominal(NominalRef)
    // Bottom — diverging computations. Unifies with everything.
    Never
    // Unit — the empty-tuple type. Distinct from `Tuple([])` only by
    // convention; the engine treats them as equal in `equals`.
    Void
    // Poison — propagated by the checker when an upstream error has
    // already been reported. Unification with `Error` resolves to
    // `Error` and emits no diagnostic so failures don't cascade.
    Error
}

// ─────────────────────────────────────────────────────────────────────
// Structural equality
//
// Two types are equal when their payloads are structurally identical:
//   - `Var` by `id` (level ignored).
//   - `Prim`, `Never`, `Void`, `Error` by tag.
//   - `Ref(a) ~~ Ref(b)`            iff `equals(a, b)`.
//   - `Array(a) ~~ Array(b)`        iff lengths match and `equals(a.elem, b.elem)`.
//   - `Func(a) ~~ Func(b)`          iff param counts match, every param equal, returns equal.
//   - `Tuple(a) ~~ Tuple(b)`        iff lengths match and every element equal.
//   - `Record(a) ~~ Record(b)`      iff field counts match and every (name, ty) pair matches in order.
//   - `Nominal(a) ~~ Nominal(b)`    iff `a.id == b.id` and arg lists element-wise equal.
//   - `Tuple([]) ~~ Void`           by convention (unit ≡ empty tuple).
//
// `Error` participates in identity: `Error ~~ Error` is `true`. The
// engine's `unify` is responsible for the "Error absorbs anything"
// behaviour; pure equality does not.
// ─────────────────────────────────────────────────────────────────────

pub fn equals(a: &Ty, b: &Ty) bool {
    return a.* match {
        Var(va) => b.* match {
            Var(vb) => va.id == vb.id,
            _ => false,
        },
        Prim(pa) => b.* match {
            Prim(pb) => pa == pb,
            _ => false,
        },
        Ref(ia) => b.* match {
            Ref(ib) => equals(ia, ib),
            _ => false,
        },
        Array(aa) => b.* match {
            Array(ab) => aa.length == ab.length and equals(aa.elem, ab.elem),
            _ => false,
        },
        Func(fa) => b.* match {
            Func(fb) => func_equals(&fa, &fb),
            _ => false,
        },
        Tuple(ta) => b.* match {
            Tuple(tb) => list_equals(&ta, &tb),
            // Empty tuple ≡ Void.
            Void => ta.len == 0,
            _ => false,
        },
        Record(ra) => b.* match {
            Record(rb) => record_equals(&ra, &rb),
            _ => false,
        },
        Nominal(na) => b.* match {
            Nominal(nb) => na.id == nb.id and list_equals(&na.args, &nb.args),
            _ => false,
        },
        Never => b.* match { Never => true, _ => false },
        Void => b.* match {
            Void => true,
            Tuple(tb) => tb.len == 0,
            _ => false,
        },
        Error => b.* match { Error => true, _ => false },
    }
}

fn func_equals(a: &FunctionTy, b: &FunctionTy) bool {
    if a.params.len != b.params.len { return false }
    for i in 0..a.params.len {
        let pa = &a.params[i]
        let pb = &b.params[i]
        if !equals(pa, pb) { return false }
    }
    return equals(a.ret, b.ret)
}

fn list_equals(a: &List(Ty), b: &List(Ty)) bool {
    if a.len != b.len { return false }
    for i in 0..a.len {
        let ea = &a[i]
        let eb = &b[i]
        if !equals(ea, eb) { return false }
    }
    return true
}

fn record_equals(a: &List(Field), b: &List(Field)) bool {
    if a.len != b.len { return false }
    for i in 0..a.len {
        let fa = &a[i]
        let fb = &b[i]
        if fa.name != fb.name { return false }
        if !equals(&fa.ty, &fb.ty) { return false }
    }
    return true
}

// ─────────────────────────────────────────────────────────────────────
// Rendering for diagnostics
// ─────────────────────────────────────────────────────────────────────

// Append a human-readable form of `self` to `sb`. Used by the reporter
// when constructing diagnostic messages. Does not allocate beyond the
// builder's own buffer.
pub fn format(self: &Ty, sb: &StringBuilder, spec: String) {
    self.* match {
        Var(v) => {
            sb.append("?")
            sb.append(v.id)
        },
        Prim(p) => sb.append(prim_name(p)),
        Ref(inner) => {
            sb.append("&")
            format(inner, sb, "")
        },
        Array(arr) => {
            sb.append("[")
            format(arr.elem, sb, "")
            sb.append("; ")
            sb.append(arr.length)
            sb.append("]")
        },
        Func(fn_ty) => format_func(&fn_ty, sb),
        Tuple(elems) => format_tuple(&elems, sb),
        Record(fields) => format_record(&fields, sb),
        Nominal(nr) => format_nominal(&nr, sb),
        Never => sb.append("never"),
        Void => sb.append("void"),
        Error => sb.append("<error>"),
    }
}

fn format_func(fn_ty: &FunctionTy, sb: &StringBuilder) {
    sb.append("fn(")
    for i in 0..fn_ty.params.len {
        if i > 0 { sb.append(", ") }
        let p = &fn_ty.params[i]
        format(p, sb, "")
    }
    sb.append(") ")
    format(fn_ty.ret, sb, "")
}

fn format_tuple(elems: &List(Ty), sb: &StringBuilder) {
    sb.append("(")
    for i in 0..elems.len {
        if i > 0 { sb.append(", ") }
        let e = &elems[i]
        format(e, sb, "")
    }
    if elems.len == 1 { sb.append(",") }
    sb.append(")")
}

fn format_record(fields: &List(Field), sb: &StringBuilder) {
    sb.append("{ ")
    for i in 0..fields.len {
        if i > 0 { sb.append(", ") }
        let f = &fields[i]
        sb.append(f.name)
        sb.append(": ")
        format(&f.ty, sb, "")
    }
    sb.append(" }")
}

fn format_nominal(nr: &NominalRef, sb: &StringBuilder) {
    sb.append("#")
    sb.append(nr.id)
    if nr.args.len > 0 {
        sb.append("(")
        for i in 0..nr.args.len {
            if i > 0 { sb.append(", ") }
            let a = &nr.args[i]
            format(a, sb, "")
        }
        sb.append(")")
    }
}

// Lower-case lexical name of a primitive — same spelling used in source
// for type annotations (`i32`, `bool`, `char`, …). Diagnostics for
// `Prim(...)` types use this directly.
pub fn prim_name(p: PrimitiveKind) String {
    return p match {
        Bool => "bool",
        I8 => "i8",
        I16 => "i16",
        I32 => "i32",
        I64 => "i64",
        ISize => "isize",
        U8 => "u8",
        U16 => "u16",
        U32 => "u32",
        U64 => "u64",
        USize => "usize",
        F32 => "f32",
        F64 => "f64",
        Char => "char",
    }
}

// ─────────────────────────────────────────────────────────────────────
// Shape predicates — small helpers consumers reach for repeatedly.
// ─────────────────────────────────────────────────────────────────────

pub fn is_var(self: &Ty) bool {
    return self.* match { Var(_) => true, _ => false }
}

pub fn is_error(self: &Ty) bool {
    return self.* match { Error => true, _ => false }
}

pub fn is_never(self: &Ty) bool {
    return self.* match { Never => true, _ => false }
}

// Every primitive except `Bool`. Includes `Char` (a u32 codepoint).
pub fn is_numeric(p: PrimitiveKind) bool {
    return p match {
        Bool => false,
        _ => true,
    }
}

pub fn is_integer(p: PrimitiveKind) bool {
    return p match {
        I8 => true, I16 => true, I32 => true, I64 => true, ISize => true,
        U8 => true, U16 => true, U32 => true, U64 => true, USize => true,
        _ => false,
    }
}

pub fn is_signed_integer(p: PrimitiveKind) bool {
    return p match {
        I8 => true, I16 => true, I32 => true, I64 => true, ISize => true,
        _ => false,
    }
}

pub fn is_float(p: PrimitiveKind) bool {
    return p match {
        F32 => true, F64 => true,
        _ => false,
    }
}
