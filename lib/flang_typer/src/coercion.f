// Coercion rules.
//
// A coercion turns an `actual` type into an `expected` type by means
// other than direct structural unification — integer widening, float
// widening, optional wrapping, and so on. Rules are *directional*:
// `from → to`, mirroring `unify(actual, expected)`.
//
// A rule's `try_*` returns `Coercion { result_ty, cost, side_unifications }`
// or `null`. The engine commits the side-unifications atomically (any
// failure rolls everything back) and replaces `actual`'s entry in
// `InferenceResults.node_types` with `result_ty`. No coercion ever
// leaks past the type checker: lowering reads the result type from the
// side-table and never inspects the surrounding slot.
//
// Rules in this file are pure prim-on-prim — no registry dependency,
// no engine reference. Nominal-aware rules (option wrapping, string
// to byte-slice, array decay, anon-struct to nominal, etc.) live next
// to `nominal_registry.f` because they need the registry to resolve
// well-known FQNs.

import std.allocator
import std.list
import std.option
import flang_typer.type
import flang_typer.nominal_registry
import flang_typer.well_known

// Side-unification request emitted by a coercion rule. The engine runs
// `unify(a, b)` for each and rolls everything back if any one fails.
pub type Constraint = struct {
    a: Ty
    b: Ty
}

// A successful coercion's payload. `result_ty` is what the engine will
// store as the unified type. `cost` lets overload resolution score
// candidates that need fewer coercions higher. `side_unifications` is
// usually empty for simple widening; option wrapping, slice decay, and
// the nominal/anon-struct rules use it to communicate "also unify these
// inner types".
pub type Coercion = struct {
    result_ty: Ty
    cost: u32
    side_unifications: List(Constraint)
}

// Build a side-effect-free coercion. Most widening rules use this.
#inline pub fn simple(result_ty: Ty, allocator: &Allocator? = null) Coercion {
    let alloc = allocator.or_global()
    let empty: List(Constraint) = list(0, alloc)
    return .{ result_ty = result_ty, cost = 1u32, side_unifications = empty }
}

// ─────────────────────────────────────────────────────────────────────
// Integer widening
//
// Two signedness-isolated rank ladders. Same-signed widening is allowed
// when `from`'s rank ≤ `to`'s rank. Cross-signedness widening is one-
// way: unsigned `from` can widen into signed `to` only when `to`'s rank
// is strictly larger (so the unsigned range fits).
//
// `bool` widens to any integer (treating false=0 / true=1).
//
// `isize` / `usize` rank: 4 (64-bit target). When 32-bit targets land,
// thread the pointer width through the engine and parameterise here.
// ─────────────────────────────────────────────────────────────────────

fn signed_rank(p: PrimitiveKind) i32 {
    return p match {
        I8 => 1i32,
        I16 => 2i32,
        I32 => 3i32,
        I64 => 4i32,
        ISize => 4i32,
        _ => 0i32,
    }
}

fn unsigned_rank(p: PrimitiveKind) i32 {
    return p match {
        U8 => 1i32,
        U16 => 2i32,
        U32 => 3i32,
        U64 => 4i32,
        USize => 4i32,
        _ => 0i32,
    }
}

pub fn try_integer_widening(from: Ty, to: Ty, allocator: &Allocator? = null) Coercion? {
    let alloc = allocator.or_global()
    let pf = from match { Prim(p) => p, _ => return null }
    let pt = to match { Prim(p) => p, _ => return null }

    // bool → any integer
    if pf == PrimitiveKind.Bool {
        if signed_rank(pt) > 0i32 or unsigned_rank(pt) > 0i32 {
            return simple(to, alloc)
        }
        return null
    }

    let sf = signed_rank(pf)
    let st = signed_rank(pt)
    if sf > 0i32 and st > 0i32 and sf <= st { return simple(to, alloc) }

    let uf = unsigned_rank(pf)
    let ut = unsigned_rank(pt)
    if uf > 0i32 and ut > 0i32 and uf <= ut { return simple(to, alloc) }

    // Unsigned → signed with strictly larger rank (so the unsigned range
    // fits without truncation or sign reinterpretation).
    if uf > 0i32 and st > 0i32 and uf < st { return simple(to, alloc) }

    return null
}

// ─────────────────────────────────────────────────────────────────────
// Float widening: f32 → f64.
// ─────────────────────────────────────────────────────────────────────

pub fn try_float_widening(from: Ty, to: Ty, allocator: &Allocator? = null) Coercion? {
    let alloc = allocator.or_global()
    let pf = from match { Prim(p) => p, _ => return null }
    let pt = to match { Prim(p) => p, _ => return null }
    if pf == PrimitiveKind.F32 and pt == PrimitiveKind.F64 {
        return simple(to, alloc)
    }
    return null
}

// ─────────────────────────────────────────────────────────────────────
// Nominal-aware rules — require the `NominalRegistry` to resolve the
// FQNs of well-known sugar types (`Option`, `String`, `Slice`).
//
// Each rule's `apply` either returns a `Coercion` whose `result_ty`
// is the target nominal and whose `side_unifications` express the
// inner-arg constraint, or `null` to indicate "this rule does not
// fire here".
// ─────────────────────────────────────────────────────────────────────

fn lookup_well_known(reg: &NominalRegistry, fqn: String) NominalId? {
    return reg.lookup_fqn(fqn)
}

// `T → Option(T)`. The Option's payload type-arg unifies with `from`.
pub fn try_option_wrapping(from: Ty, to: Ty, reg: &NominalRegistry, allocator: &Allocator? = null) Coercion? {
    let alloc = allocator.or_global()
    let nr = to match { Nominal(n) => n, _ => return null }
    let opt_id = lookup_well_known(reg, FQN_OPTION)
    opt_id match {
        Some(id) => if id != nr.id { return null },
        None => return null,
    }
    if nr.args.len != 1 { return null }
    let inner = nr.args[0]
    let side: List(Constraint) = list(1, alloc)
    side.push(Constraint { a = from, b = inner })
    return Coercion { result_ty = to, cost = 1u32, side_unifications = side }
}

// `String → Slice(u8)` — binary-compatible view cast.
pub fn try_string_to_byte_slice(from: Ty, to: Ty, reg: &NominalRegistry, allocator: &Allocator? = null) Coercion? {
    let alloc = allocator.or_global()
    let fn_n = from match { Nominal(n) => n, _ => return null }
    let tn = to match { Nominal(n) => n, _ => return null }

    let string_id = lookup_well_known(reg, FQN_STRING)
    let slice_id = lookup_well_known(reg, FQN_SLICE)
    string_id match {
        Some(sid) => if sid != fn_n.id { return null },
        None => return null,
    }
    slice_id match {
        Some(sid) => if sid != tn.id { return null },
        None => return null,
    }
    if tn.args.len != 1 { return null }
    let inner = tn.args[0]
    let is_u8 = inner match {
        Prim(p) => p == PrimitiveKind.U8,
        _ => false,
    }
    if !is_u8 { return null }
    return simple(to, alloc)
}

// Array decay rules. Four variants, distinguished by whether `from`
// is `Array` or `&Array` and whether `to` is `Slice(T)` or `&T`.
//   - `[T; N] → Slice(T)`
//   - `&[T; N] → Slice(T)`
//   - `[T; N] → &T`
//   - `&[T; N] → &T`
// Each emits one side-unification: the array's element type unifies
// with the target's element / inner type.
pub fn try_array_decay(from: Ty, to: Ty, reg: &NominalRegistry, allocator: &Allocator? = null) Coercion? {
    let alloc = allocator.or_global()

    // Identify the array element of `from`, if any (with or without a
    // surrounding reference).
    let elem = array_element_of(from)
    if elem.is_none() { return null }
    let e = elem.unwrap()

    return decay_to(to, e, reg, alloc)
}

fn array_element_of(t: Ty) Ty? {
    return t match {
        Array(arr) => Some(arr.elem.*),
        Ref(inner) => inner_array_element(inner),
        _ => null,
    }
}

fn inner_array_element(inner: &Ty) Ty? {
    return inner.* match {
        Array(arr) => Some(arr.elem.*),
        _ => null,
    }
}

fn decay_to(to: Ty, elem: Ty, reg: &NominalRegistry, alloc: &Allocator) Coercion? {
    return to match {
        Nominal(n) => decay_to_slice(to, &n, elem, reg, alloc),
        Ref(target_inner) => decay_to_ref(to, target_inner, elem, alloc),
        _ => null,
    }
}

fn decay_to_slice(to: Ty, n: &NominalRef, elem: Ty, reg: &NominalRegistry, alloc: &Allocator) Coercion? {
    let slice_id = lookup_well_known(reg, FQN_SLICE)
    if slice_id.is_none() { return null }
    if slice_id.unwrap() != n.id { return null }
    if n.args.len != 1 { return null }
    let side: List(Constraint) = list(1, alloc)
    side.push(Constraint { a = elem, b = n.args[0] })
    return Coercion { result_ty = to, cost = 1u32, side_unifications = side }
}

fn decay_to_ref(to: Ty, target_inner: &Ty, elem: Ty, alloc: &Allocator) Coercion? {
    let side: List(Constraint) = list(1, alloc)
    side.push(Constraint { a = elem, b = target_inner.* })
    return Coercion { result_ty = to, cost = 1u32, side_unifications = side }
}

// `Slice(T) → &T` — extract the pointer from a slice.
pub fn try_slice_to_reference(from: Ty, to: Ty, reg: &NominalRegistry, allocator: &Allocator? = null) Coercion? {
    let alloc = allocator.or_global()
    let fn_n = from match { Nominal(n) => n, _ => return null }
    let ref_inner = to match { Ref(inner) => inner, _ => return null }
    let slice_id = lookup_well_known(reg, FQN_SLICE)
    slice_id match {
        Some(sid) => if sid != fn_n.id { return null },
        None => return null,
    }
    if fn_n.args.len != 1 { return null }
    let side: List(Constraint) = list(1, alloc)
    side.push(Constraint { a = fn_n.args[0], b = ref_inner.* })
    return Coercion { result_ty = to, cost = 1u32, side_unifications = side }
}

// `T → Type(T)` for RTTI handles. The result wraps `from` in a
// freshly-instantiated `Type(T)`. The instantiation is recorded by
// the engine so codegen knows which RTTI tables to emit.
pub fn try_nominal_to_type(from: Ty, to: Ty, reg: &NominalRegistry, allocator: &Allocator? = null) Coercion? {
    let alloc = allocator.or_global()
    let tn = to match { Nominal(n) => n, _ => return null }
    let type_id = lookup_well_known(reg, FQN_TYPE)
    type_id match {
        Some(tid) => if tid != tn.id { return null },
        None => return null,
    }
    if tn.args.len != 1 { return null }
    // `from` must be a concrete type — not a Type(T) itself, not a
    // bare TypeVar (the bare-var case is caught at the engine level
    // and never reaches coercion).
    let valid_from = from match {
        Nominal(nf) => type_id match {
            Some(tid) => nf.id != tid,
            None => true,
        },
        Prim(_) => true,
        Ref(_) => true,
        Array(_) => true,
        Func(_) => true,
        _ => false,
    }
    if !valid_from { return null }
    let side: List(Constraint) = list(1, alloc)
    side.push(Constraint { a = from, b = tn.args[0] })
    return Coercion { result_ty = to, cost = 1u32, side_unifications = side }
}
