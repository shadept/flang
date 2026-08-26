// Coercion rules.
//
// A coercion turns an `actual` type into an `expected` type by means
// other than direct structural unification - integer widening, float
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
// Rules match shapes through the `TypeInterner` the engine passes in.
// Prim-on-prim rules need it only for the node lookup; nominal-aware
// rules (option wrapping, string to byte-slice, array decay, etc.) also
// need the registry to resolve well-known FQNs.

import std.allocator
import std.list
import std.option
import flang_typer.type
import flang_typer.interner
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
    let empty = list(0, allocator)
    return .{ result_ty = result_ty, cost = 1u32, side_unifications = empty }
}

fn prim_kind_of(it: &TypeInterner, t: Ty) PrimitiveKind? {
    return it.node(t) match {
        NPrim(p) => Some(p),
        _ => null,
    }
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

pub fn try_integer_widening(it: &TypeInterner, from: Ty, to: Ty, allocator: &Allocator? = null) Coercion? {
    let pf = prim_kind_of(it, from) match { Some(p) => p, None => return null }
    let pt = prim_kind_of(it, to) match { Some(p) => p, None => return null }

    // bool → any integer
    if pf == PrimitiveKind.Bool {
        if signed_rank(pt) > 0i32 or unsigned_rank(pt) > 0i32 {
            return Some(simple(to, allocator))
        }
        return null
    }

    let sf = signed_rank(pf)
    let st = signed_rank(pt)
    if sf > 0i32 and st > 0i32 and sf <= st { return Some(simple(to, allocator)) }

    let uf = unsigned_rank(pf)
    let ut = unsigned_rank(pt)
    if uf > 0i32 and ut > 0i32 and uf <= ut { return Some(simple(to, allocator)) }

    // Unsigned → signed with strictly larger rank (so the unsigned range
    // fits without truncation or sign reinterpretation).
    if uf > 0i32 and st > 0i32 and uf < st { return Some(simple(to, allocator)) }

    return null
}

// ─────────────────────────────────────────────────────────────────────
// Char narrowing: char → u8.
// ponytail: fires for every char value; the reference checker restricts
// this to literals, so the bootstrap accepts strictly more programs.
// ─────────────────────────────────────────────────────────────────────

pub fn try_char_to_u8(it: &TypeInterner, from: Ty, to: Ty, allocator: &Allocator? = null) Coercion? {
    let pf = prim_kind_of(it, from) match { Some(p) => p, None => return null }
    let pt = prim_kind_of(it, to) match { Some(p) => p, None => return null }
    if pf == PrimitiveKind.Char and pt == PrimitiveKind.U8 {
        return Some(simple(to, allocator))
    }
    return null
}

// ─────────────────────────────────────────────────────────────────────
// Float widening: f32 → f64.
// ─────────────────────────────────────────────────────────────────────

pub fn try_float_widening(it: &TypeInterner, from: Ty, to: Ty, allocator: &Allocator? = null) Coercion? {
    let pf = prim_kind_of(it, from) match { Some(p) => p, None => return null }
    let pt = prim_kind_of(it, to) match { Some(p) => p, None => return null }
    if pf == PrimitiveKind.F32 and pt == PrimitiveKind.F64 {
        return Some(simple(to, allocator))
    }
    return null
}

// ─────────────────────────────────────────────────────────────────────
// Nominal-aware rules - require the `NominalRegistry` to resolve the
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

fn nominal_node_of(it: &TypeInterner, t: Ty) NNominalNode? {
    return it.node(t) match {
        NNominal(n) => Some(n),
        _ => null,
    }
}

// `Type(T) → TypeInfo` - a reified type handle flows wherever the
// erased runtime type-info record is expected.
pub fn try_type_to_typeinfo(it: &TypeInterner, from: Ty, to: Ty, reg: &NominalRegistry, allocator: &Allocator? = null) Coercion? {
    let fn_n = nominal_node_of(it, from) match { Some(n) => n, None => return null }
    let tn = nominal_node_of(it, to) match { Some(n) => n, None => return null }
    let type_id = lookup_well_known(reg, FQN_TYPE)
    let info_id = lookup_well_known(reg, FQN_TYPE_INFO)
    type_id match {
        Some(tid) => if tid != fn_n.id { return null },
        None => return null,
    }
    info_id match {
        Some(iid) => if iid != tn.id { return null },
        None => return null,
    }
    return Some(simple(to, allocator))
}

// `String → Slice(u8)` - binary-compatible view cast.
pub fn try_string_to_byte_slice(it: &TypeInterner, from: Ty, to: Ty, reg: &NominalRegistry, allocator: &Allocator? = null) Coercion? {
    let fn_n = nominal_node_of(it, from) match { Some(n) => n, None => return null }
    let tn = nominal_node_of(it, to) match { Some(n) => n, None => return null }

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
    if it.child_ids(tn.args)[0] != prim_of(PrimitiveKind.U8) { return null }
    return Some(simple(to, allocator))
}

// `Slice(u8) → String` - the inverse binary-compatible view cast. The
// reference engine applies its rules in both directions; this pair keeps
// byte views and strings interchangeable.
pub fn try_byte_slice_to_string(it: &TypeInterner, from: Ty, to: Ty, reg: &NominalRegistry, allocator: &Allocator? = null) Coercion? {
    let c = try_string_to_byte_slice(it, to, from, reg, allocator)
    return c match {
        Some(inner) => {
            inner.side_unifications.deinit()
            Some(simple(to, allocator))
        },
        None => null,
    }
}

// Array decay rules. Four variants, distinguished by whether `from`
// is `Array` or `&Array` and whether `to` is `Slice(T)` or `&T`.
//   - `[T; N] → Slice(T)`
//   - `&[T; N] → Slice(T)`
//   - `[T; N] → &T`
//   - `&[T; N] → &T`
// Each emits one side-unification: the array's element type unifies
// with the target's element / inner type.
pub fn try_array_decay(it: &TypeInterner, from: Ty, to: Ty, reg: &NominalRegistry, allocator: &Allocator? = null) Coercion? {
    // Identify the array element of `from`, if any (with or without a
    // surrounding reference).
    let elem = array_element_of(it, from)
    if elem.is_none() { return null }
    let e = elem.unwrap()

    return decay_to(it, to, e, reg, allocator)
}

fn array_element_of(it: &TypeInterner, t: Ty) Ty? {
    return it.node(t) match {
        NArray(arr) => Some(arr.elem),
        NRef(inner) => it.node(inner) match {
            NArray(arr) => Some(arr.elem),
            _ => null,
        },
        _ => null,
    }
}

fn decay_to(it: &TypeInterner, to: Ty, elem: Ty, reg: &NominalRegistry, allocator: &Allocator?) Coercion? {
    return it.node(to) match {
        NNominal(n) => decay_to_slice(it, to, &n, elem, reg, allocator),
        NRef(target_inner) => decay_to_ref(to, target_inner, elem, allocator),
        _ => null,
    }
}

fn decay_to_slice(it: &TypeInterner, to: Ty, n: &NNominalNode, elem: Ty, reg: &NominalRegistry, allocator: &Allocator?) Coercion? {
    let slice_id = lookup_well_known(reg, FQN_SLICE)
    if slice_id.is_none() { return null }
    if slice_id.unwrap() != n.id { return null }
    if n.args.len != 1 { return null }
    let side = list(1, allocator)
    side.push(Constraint { a = elem, b = it.child_ids(n.args)[0] })
    return Some(Coercion { result_ty = to, cost = 1u32, side_unifications = side })
}

fn decay_to_ref(to: Ty, target_inner: Ty, elem: Ty, allocator: &Allocator?) Coercion? {
    let side = list(1, allocator)
    side.push(Constraint { a = elem, b = target_inner })
    return Some(Coercion { result_ty = to, cost = 1u32, side_unifications = side })
}

// `Slice(T) → &T` - extract the pointer from a slice.
pub fn try_slice_to_reference(it: &TypeInterner, from: Ty, to: Ty, reg: &NominalRegistry, allocator: &Allocator? = null) Coercion? {
    let fn_n = nominal_node_of(it, from) match { Some(n) => n, None => return null }
    let ref_inner = it.node(to) match { NRef(inner) => inner, _ => return null }
    let slice_id = lookup_well_known(reg, FQN_SLICE)
    slice_id match {
        Some(sid) => if sid != fn_n.id { return null },
        None => return null,
    }
    if fn_n.args.len != 1 { return null }
    let side = list(1, allocator)
    side.push(Constraint { a = it.child_ids(fn_n.args)[0], b = ref_inner })
    return Some(Coercion { result_ty = to, cost = 1u32, side_unifications = side })
}

// `T → Type(T)` for RTTI handles. The result wraps `from` in a
// freshly-instantiated `Type(T)`. The instantiation is recorded by
// the engine so codegen knows which RTTI tables to emit.
pub fn try_nominal_to_type(it: &TypeInterner, from: Ty, to: Ty, reg: &NominalRegistry, allocator: &Allocator? = null) Coercion? {
    let tn = nominal_node_of(it, to) match { Some(n) => n, None => return null }
    let type_id = lookup_well_known(reg, FQN_TYPE)
    type_id match {
        Some(tid) => if tid != tn.id { return null },
        None => return null,
    }
    if tn.args.len != 1 { return null }
    // `from` must be a concrete type - not a Type(T) itself, not a
    // bare TypeVar (the bare-var case is caught at the engine level
    // and never reaches coercion).
    let valid_from = it.node(from) match {
        NNominal(nf) => type_id match {
            Some(tid) => nf.id != tid,
            None => true,
        },
        NPrim(_) => true,
        NRef(_) => true,
        NArray(_) => true,
        NFunc(_) => true,
        NTuple(_) => true,
        _ => false,
    }
    if !valid_from { return null }
    let side = list(1, allocator)
    side.push(Constraint { a = from, b = it.child_ids(tn.args)[0] })
    return Some(Coercion { result_ty = to, cost = 1u32, side_unifications = side })
}
