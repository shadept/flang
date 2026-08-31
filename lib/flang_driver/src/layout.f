// Memory layout for codegen: size, alignment, and field offsets of any `Ty`. FIR is flat (7 scalars
// + `ptr`; aggregates are opaque byte buffers), so lowering computes layout here before it can emit
// a field access.
//
// Types are interned handles; every walk goes through the `TypeInterner` carried by the
// `TypeCheckResult` being lowered.
//
// Recursion stops at `Ref` (a pointer is 8 bytes), so the type graph is acyclic and needs no
// cycle-breaking; a by-value cycle is an infinite type the typer rejects.
//
// Default `auto` reorders fields by descending alignment to minimise size; `#foreign` is `repr(C)`
// (declaration order). The C# backend still does C-order always - see docs/known-issues.md.

import std.allocator
import std.dict
import std.list
import std.option
import std.string
import std.test
import flang_core.span
import flang_typer.type
import flang_typer.interner
import flang_typer.nominal_registry
import flang_typer.well_known

// Size and alignment of a value, in bytes.
pub type Layout = struct {
    size: usize
    align: usize
}

// A struct/tuple/record layout: total size and alignment plus the byte offset of each field.
// `offsets` is indexed by *declaration* order (so a resolved field index addresses it directly);
// under `auto` the values need not increase monotonically, since fields are physically reordered.
// The caller owns `offsets`.
pub type StructLayout = struct {
    size: usize
    align: usize
    offsets: List(usize)
}

// A tagged-union enum layout. `tag_size` is the discriminant width and `payload_offset` where the
// largest variant payload begins. When `is_niche` is set the enum is a pointer-niche `Option(&T)`:
// no tag, the null pointer encodes the empty case.
pub type EnumLayout = struct {
    size: usize
    align: usize
    tag_size: usize
    payload_offset: usize
    is_niche: bool
}

// How a struct's fields map to memory. `Auto` (the default) is free to reorder; `C` is locked to
// declaration order and C ABI padding. New representations (e.g. packed) become new variants here.
pub type Repr = enum {
    Auto
    C
}

// A struct's representation. `#foreign` locks the layout to C ABI rules (spec section 6); every
// other struct gets the size-minimising auto layout.
pub fn repr_of(def: &StructDef) Repr {
    if def.is_foreign {
        return Repr.C
    }
    return Repr.Auto
}

// Memoisation
//
// A `Ty` is an append-only interned id and a concrete type's layout is a pure function of it (and
// the registry, fixed for a check result), so one cache entry per id is valid for the cache's whole
// lifetime. Create one per lowering run over one interner; never share across interners.

// Memo of per-type layouts, dense over interned ids. `align == 0` marks an unfilled slot (every
// real layout has alignment >= 1).
pub type LayoutCache = struct {
    entries: List(Layout)
}

pub fn layout_cache(allocator: &Allocator? = null) LayoutCache {
    return .{ entries = list(0, allocator) }
}

pub fn deinit(self: &LayoutCache) {
    self.entries.deinit()
}

fn cache_get(cache: &LayoutCache?, ty: Ty) Layout? {
    if cache.is_none() {
        return null
    }
    let c = cache.unwrap()
    if ty as usize >= c.entries.len {
        return null
    }
    let e = c.entries[ty as usize]
    if e.align == 0 {
        return null
    }
    return Some(e)
}

fn cache_put(cache: &LayoutCache?, ty: Ty, l: Layout) {
    if cache.is_none() {
        return
    }
    let c = cache.unwrap()
    while c.entries.len <= ty as usize {
        c.entries.push(lay(0, 0))
    }
    c.entries[ty as usize] = l
}

// Public API

// Size and alignment of any resolved `Ty`. The type must be zonked and concrete: a `Var` reaching
// layout is a compiler bug (lowering's contract - docs/self-host.md).
pub fn layout_of(it: &TypeInterner, ty: Ty, reg: &NominalRegistry, cache: &LayoutCache? = null,
    allocator: &Allocator? = null) Layout {
    return layout_rec(it, ty, reg, cache, allocator)
}

// Layout of a struct instantiation: `args` substitutes the struct's type parameters (empty for
// non-generic structs).
pub fn struct_layout(it: &TypeInterner, def: &StructDef, args: &List(Ty), reg: &NominalRegistry,
    cache: &LayoutCache? = null, allocator: &Allocator? = null) StructLayout {
    return struct_layout_impl(it, def, args, reg, cache, allocator)
}

// Layout of an enum instantiation. Recognises the `Option(&T)` niche.
pub fn enum_layout(it: &TypeInterner, def: &EnumDef, args: &List(Ty), reg: &NominalRegistry,
    cache: &LayoutCache? = null, allocator: &Allocator? = null) EnumLayout {
    return enum_layout_impl(it, def, args, reg, cache, allocator)
}

// The declared type of field `index` with the instantiation's type arguments substituted in (the
// raw definition stores generic fields against the declaration's type parameters).
pub fn field_ty(it: &TypeInterner, def: &StructDef, index: usize, args: &List(Ty)) Ty {
    return subst(it, def.fields[index].ty, &def.type_params, args)
}

// The declared type of variant `vnum`'s payload `index` with the instantiation's type arguments
// substituted in - the enum-side mirror of `field_ty`.
pub fn variant_payload_ty(it: &TypeInterner, def: &EnumDef, vnum: usize, index: usize,
    args: &List(Ty)) Ty {
    return subst(it, def.variants[vnum].payloads[index], &def.type_params, args)
}

// Core walk

fn layout_rec(it: &TypeInterner, ty: Ty, reg: &NominalRegistry, cache: &LayoutCache?,
    alloc: &Allocator?) Layout {
    let hit = cache_get(cache, ty)
    if hit.is_some() {
        return hit.unwrap()
    }
    let r = it.node(ty) match {
        // Since M10 every type reaching layout is concrete - templates never lower and
        // specializations substitute real types. A Var here means a checker bug; guessing a width
        // corrupts every downstream offset silently, so fail loudly instead.
        NVar(_) => panic("unresolved type variable reached layout - checker bug")
        NPrim(p) => prim_layout(p)
        NRef(_) => lay(8, 8)
        NFunc(_) => lay(8, 8)
        NArray(a) => array_layout(it, &a, reg, cache, alloc)
        NTuple(span) => span_size(it, span, reg, cache, alloc)
        NRecord(rec) => span_size(it, rec.tys, reg, cache, alloc)
        NNominal(nn) => nominal_layout(it, &nn, reg, cache, alloc)
        NNever => lay(0, 1)
        NVoid => lay(0, 1)
        NError => lay(0, 1)
    }
    cache_put(cache, ty, r)
    return r
}

fn prim_layout(p: PrimitiveKind) Layout {
    return p match {
        Bool => lay(1, 1)
        I8 => lay(1, 1)
        U8 => lay(1, 1)
        I16 => lay(2, 2)
        U16 => lay(2, 2)
        I32 => lay(4, 4)
        U32 => lay(4, 4)
        Char => lay(4, 4)
        F32 => lay(4, 4)
        I64 => lay(8, 8)
        U64 => lay(8, 8)
        ISize => lay(8, 8)
        USize => lay(8, 8)
        F64 => lay(8, 8)
    }
}

fn array_layout(it: &TypeInterner, a: &NArrayNode, reg: &NominalRegistry, cache: &LayoutCache?,
    alloc: &Allocator?) Layout {
    let el = layout_rec(it, a.elem, reg, cache, alloc)
    return lay(el.size * a.length, el.align)
}

// Fold a sequence of field types into offsets, total size and alignment. Fields are placed in
// `field_order` (declaration order for `C`, descending alignment for `Auto`), but `offsets` is
// written back indexed by declaration order so callers address it with a field's declared index.
fn fields_layout(it: &TypeInterner, tys: &List(Ty), repr: Repr, reg: &NominalRegistry,
    cache: &LayoutCache?, alloc: &Allocator?) StructLayout {
    let n = tys.len
    let fls: List(Layout) = list(n, alloc)
    let max_align: usize = 1
    for i in 0..n {
        let fl = layout_rec(it, tys[i], reg, cache, alloc)
        fls.push(fl)
        if fl.align > max_align {
            max_align = fl.align
        }
    }

    let order = field_order(&fls, repr, max_align, alloc)

    let offsets: List(usize) = list(n, alloc)
    for i in 0..n { offsets.push(0) }
    let cursor: usize = 0
    for di in order {
        let fl = &fls[di]
        let off = align_up(cursor, fl.align)
        offsets[di] = off
        cursor = off + fl.size
    }

    fls.deinit()
    order.deinit()
    return .{ size = align_up(cursor, max_align), align = max_align, offsets = offsets }
}

// Physical placement order of declaration indices. `C` keeps source order. `Auto` emits fields by
// descending alignment, stable within an alignment class: because every type's size is a multiple
// of its own alignment, this packs each field at its natural offset with zero internal padding -
// the minimal-size layout. Alignments are powers of two, so a halving scan from `max_align` down to
// 1 buckets them without a sort.
fn field_order(fls: &List(Layout), repr: Repr, max_align: usize, alloc: &Allocator?) List(usize) {
    let n = fls.len
    let order: List(usize) = list(n, alloc)
    let is_c = repr match { C => true, Auto => false }
    if is_c {
        for i in 0..n { order.push(i) }
        return order
    }

    let a = max_align
    while a >= 1 {
        for i in 0..n {
            if fls[i].align == a {
                order.push(i)
            }
        }
        if a == 1 {
            break
        }
        a = a / 2
    }
    return order
}

// A tuple's full layout - size, align, and per-element offsets (M11 tuple literals and `t.N`
// projection read them).
pub fn tuple_layout(it: &TypeInterner, elems: &List(Ty), reg: &NominalRegistry,
    cache: &LayoutCache? = null, allocator: &Allocator? = null) StructLayout {
    return fields_layout(it, elems, Repr.Auto, reg, cache, allocator)
}

// Size/align of a positional tuple or anonymous record's child window (offsets discarded). These
// have no declaration to lock them, so they take the default auto layout.
fn span_size(it: &TypeInterner, span: ChildSpan, reg: &NominalRegistry, cache: &LayoutCache?,
    alloc: &Allocator?) Layout {
    let tys: List(Ty) = list(span.len, alloc)
    for i in 0..span.len { tys.push(it.child_at(span, i)) }
    let r = aggregate_size(it, &tys, reg, cache, alloc)
    tys.deinit()
    return r
}

fn aggregate_size(it: &TypeInterner, elems: &List(Ty), reg: &NominalRegistry, cache: &LayoutCache?,
    alloc: &Allocator?) Layout {
    let sl = fields_layout(it, elems, Repr.Auto, reg, cache, alloc)
    let r = lay(sl.size, sl.align)
    sl.offsets.deinit()
    return r
}

fn nominal_layout(it: &TypeInterner, nn: &NNominalNode, reg: &NominalRegistry, cache: &LayoutCache?,
    alloc: &Allocator?) Layout {
    let args: List(Ty) = list(nn.args.len, alloc)
    defer args.deinit()
    for i in 0..nn.args.len { args.push(it.child_at(nn.args, i)) }
    let def = reg.get(nn.id)
    return def.* match {
        NomStruct(s) => {
            // `Type(T)` is declared empty but its VALUE is a TypeInfo (the reified-type handle -
            // `type_of` returns it as one), so it lays out as TypeInfo (M11 minimal RTTI).
            if s.fqn == FQN_TYPE {
                let ti = reg.by_fqn.get(FQN_TYPE_INFO)
                if ti.is_some() {
                    let tdef = reg.get(ti.unwrap())
                    tdef.* match {
                        NomStruct(ts) => {
                            let none: List(Ty) = list(0, alloc)
                            let r = struct_size(it, &ts, &none, reg, cache, alloc)
                            none.deinit()
                            return r
                        }
                        _ => {}
                    }
                }
            }
            struct_size(it, &s, &args, reg, cache, alloc)
        }
        NomEnum(e) => enum_size(it, &e, &args, reg, cache, alloc)
    }
}

fn struct_size(it: &TypeInterner, def: &StructDef, args: &List(Ty), reg: &NominalRegistry,
    cache: &LayoutCache?, alloc: &Allocator?) Layout {
    let sl = struct_layout_impl(it, def, args, reg, cache, alloc)
    let r = lay(sl.size, sl.align)
    sl.offsets.deinit()
    return r
}

fn enum_size(it: &TypeInterner, def: &EnumDef, args: &List(Ty), reg: &NominalRegistry,
    cache: &LayoutCache?, alloc: &Allocator?) Layout {
    let el = enum_layout_impl(it, def, args, reg, cache, alloc)
    return lay(el.size, el.align)
}

// Aggregates

fn struct_layout_impl(it: &TypeInterner, def: &StructDef, args: &List(Ty), reg: &NominalRegistry,
    cache: &LayoutCache?, alloc: &Allocator?) StructLayout {
    let tys: List(Ty) = list(def.fields.len, alloc)
    for i in 0..def.fields.len {
        tys.push(subst(it, def.fields[i].ty, &def.type_params, args))
    }
    let sl = fields_layout(it, &tys, repr_of(def), reg, cache, alloc)
    tys.deinit()
    if def.is_simd {
        return simd_layout(sl)
    }
    return sl
}

// SIMD vectors over-align to the next power-of-two of their byte size (min 16), so the C backend
// can request vector alignment. Per-payload byte offsets of one variant, relative to the ENUM's
// base: the shared payload offset plus the variant's own struct-like internal layout (M11
// multi-payload variants). Never call for the niche form.
pub fn variant_payload_offsets(it: &TypeInterner, def: &EnumDef, vnum: usize, args: &List(Ty),
    reg: &NominalRegistry, cache: &LayoutCache? = null, allocator: &Allocator? = null) List(usize) {
    let el = enum_layout(it, def, args, reg, cache, allocator)
    let v = &def.variants[vnum]
    let ptys: List(Ty) = list(v.payloads.len, allocator)
    for j in 0..v.payloads.len {
        ptys.push(subst(it, v.payloads[j], &def.type_params, args))
    }
    let pl = fields_layout(it, &ptys, Repr.Auto, reg, cache, allocator)
    ptys.deinit()
    let out: List(usize) = list(pl.offsets.len, allocator)
    for j in 0..pl.offsets.len {
        out.push(el.payload_offset + pl.offsets[j])
    }
    pl.offsets.deinit()
    return out
}

fn simd_layout(sl: StructLayout) StructLayout {
    let want = next_pow2(sl.size)
    let align = if want > 16 { want } else { 16 }
    return .{ size = align_up(sl.size, align), align = align, offsets = sl.offsets }
}

fn enum_layout_impl(it: &TypeInterner, def: &EnumDef, args: &List(Ty), reg: &NominalRegistry,
    cache: &LayoutCache?, alloc: &Allocator?) EnumLayout {
    if is_option_niche(it, def, args) {
        return .{ size = 8, align = 8, tag_size = 0, payload_offset = 0, is_niche = true }
    }

    const tag_size: usize = 4
    let largest: usize = 0
    let max_palign: usize = 1
    let any_payload: bool = false

    for &v in def.variants {
        if v.payloads.len == 0 {
            continue
        }
        any_payload = true
        let ptys: List(Ty) = list(v.payloads.len, alloc)
        for j in 0..v.payloads.len {
            ptys.push(subst(it, v.payloads[j], &def.type_params, args))
        }
        let pl = fields_layout(it, &ptys, Repr.Auto, reg, cache, alloc)
        ptys.deinit()
        pl.offsets.deinit()
        if pl.size > largest {
            largest = pl.size
        }
        if pl.align > max_palign {
            max_palign = pl.align
        }
    }

    if !any_payload {
        return .{
            size = tag_size,
            align = 4,
            tag_size = tag_size,
            payload_offset = 0,
            is_niche = false,
        }
    }

    let align = if max_palign > 4 { max_palign } else { 4 }
    let payload_offset = align_up(tag_size, max_palign)
    let size = align_up(payload_offset + largest, align)
    return .{
        size = size,
        align = align,
        tag_size = tag_size,
        payload_offset = payload_offset,
        is_niche = false,
    }
}

fn is_option_niche(it: &TypeInterner, def: &EnumDef, args: &List(Ty)) bool {
    if def.fqn != FQN_OPTION {
        return false
    }
    if args.len != 1 {
        return false
    }
    return it.node(args[0]) match {
        NRef(_) => true
        _ => false
    }
}

// Type-parameter substitution
//
// A generic struct/enum stores its fields against the declaration's type parameters; instantiating
// it replaces those variables with the concrete `args`. Results are interned handles like
// everything else.

fn subst(it: &TypeInterner, ty: Ty, params: &List(VarId), args: &List(Ty)) Ty {
    if params.len == 0 {
        return ty
    }
    if it.is_ground(ty) {
        return ty
    }
    return it.node(ty) match {
        NVar(v) => subst_var(v, params, args, ty)
        NRef(inner) => it.ref_of(subst(it, inner, params, args))
        NArray(a) => it.array_of(subst(it, a.elem, params, args), a.length)
        NFunc(f) => subst_func(it, &f, params, args)
        NTuple(span) => subst_tuple(it, span, params, args)
        NRecord(rec) => subst_record(it, &rec, params, args)
        NNominal(nn) => subst_nominal(it, &nn, params, args)
        _ => ty
    }
}

fn subst_var(v: TyVar, params: &List(VarId), args: &List(Ty), fallback: Ty) Ty {
    for i in 0..params.len {
        if params[i] == v.id {
            return args[i]
        }
    }
    return fallback
}

fn subst_span(it: &TypeInterner, span: ChildSpan, params: &List(VarId), args: &List(Ty)) List(Ty) {
    let out: List(Ty) = list(span.len)
    for i in 0..span.len {
        out.push(subst(it, it.child_at(span, i), params, args))
    }
    return out
}

fn subst_tuple(it: &TypeInterner, span: ChildSpan, params: &List(VarId), args: &List(Ty)) Ty {
    let es = subst_span(it, span, params, args)
    defer es.deinit()
    return it.tuple_of(&es)
}

fn subst_record(it: &TypeInterner, rec: &NRecordNode, params: &List(VarId), args: &List(Ty)) Ty {
    let fs: List(Field) = list(rec.tys.len)
    defer fs.deinit()
    for i in 0..rec.tys.len {
        fs.push(Field {
            name = it.rec_name(rec, i),
            ty = subst(it, it.rec_ty(rec, i), params, args),
            decl_span = it.rec_span(rec, i),
        })
    }
    return it.record_of(&fs)
}

fn subst_nominal(it: &TypeInterner, nn: &NNominalNode, params: &List(VarId), args: &List(Ty)) Ty {
    let as_ = subst_span(it, nn.args, params, args)
    defer as_.deinit()
    return it.nominal_of(nn.id, &as_)
}

fn subst_func(it: &TypeInterner, f: &NFuncNode, params: &List(VarId), args: &List(Ty)) Ty {
    let ps = subst_span(it, f.params, params, args)
    defer ps.deinit()
    return it.func_of(&ps, subst(it, f.ret, params, args))
}

// Helpers

fn lay(size: usize, align: usize) Layout {
    return .{ size = size, align = align }
}

// Round `offset` up to the next multiple of `align`.
fn align_up(offset: usize, align: usize) usize {
    if align <= 1 {
        return offset
    }
    return ((offset + align - 1) / align) * align
}

fn next_pow2(v: usize) usize {
    let n: usize = 1
    while n < v { n = n * 2 }
    return n
}

// Whether a type is SPELLED as an aggregate. Purely syntactic - the pointer-niche `Option(&T)` is
// nominal and so counts, even though its runtime value is a bare pointer. Use `is_by_ref` for the
// runtime classification; this stays the right test for `ir_of`, where the niche form is `ptr`
// either way.
pub fn is_aggregate(it: &TypeInterner, ty: Ty) bool {
    return it.node(ty) match {
        NNominal(_) => true
        NRecord(_) => true
        NTuple(_) => true
        NArray(_) => true
        _ => false
    }
}

// Tests

test "primitives have natural size and alignment" {
    let it = type_interner()
    defer it.deinit()
    let reg = nominal_registry()
    defer reg.deinit()
    assert_eq(layout_of(&it, prim_of(PrimitiveKind.Bool), &reg).size, 1 as usize, "bool is 1 byte")
    assert_eq(layout_of(&it, prim_of(PrimitiveKind.I32), &reg).size, 4 as usize, "i32 is 4 bytes")
    assert_eq(layout_of(&it, prim_of(PrimitiveKind.I32), &reg).align, 4 as usize, "i32 aligns to 4")
    assert_eq(layout_of(&it, prim_of(PrimitiveKind.F64), &reg).size, 8 as usize, "f64 is 8 bytes")
    assert_eq(layout_of(&it, prim_of(PrimitiveKind.Char), &reg).size, 4 as usize,
        "char is a 4-byte codepoint")
    assert_eq(layout_of(&it, prim_of(PrimitiveKind.USize), &reg).size, 8 as usize,
        "usize is 8 bytes on a 64-bit target")
}

test "references and arrays" {
    let it = type_interner()
    defer it.deinit()
    let reg = nominal_registry()
    defer reg.deinit()

    let r = it.ref_of(prim_of(PrimitiveKind.I32))
    assert_eq(layout_of(&it, r, &reg).size, 8 as usize, "a reference is a pointer")

    let a = it.array_of(prim_of(PrimitiveKind.I32), 4)
    assert_eq(layout_of(&it, a, &reg).size, 16 as usize, "[i32; 4] is 16 bytes")
    assert_eq(layout_of(&it, a, &reg).align, 4 as usize, "[i32; 4] aligns to its element")

    let a8 = it.array_of(prim_of(PrimitiveKind.I64), 3)
    assert_eq(layout_of(&it, a8, &reg).size, 24 as usize, "[i64; 3] is 24 bytes")
}

test "auto layout reorders fields by alignment to minimise padding" {
    let it = type_interner()
    defer it.deinit()
    let reg = nominal_registry()
    defer reg.deinit()
    let fields: List(Field) = list(3)
    fields.push(Field { name = "a", ty = prim_of(PrimitiveKind.I8), decl_span = none_span() }) // decl 0, align 1
    fields.push(Field { name = "b", ty = prim_of(PrimitiveKind.I64), decl_span = none_span() }) // decl 1, align 8
    fields.push(Field { name = "c", ty = prim_of(PrimitiveKind.I16), decl_span = none_span() }) // decl 2, align 2
    let def = StructDef {
        fqn = "T",
        module = "",
        is_pub = true,
        type_params = list(0),
        fields = fields,
        decl_span = none_span(),
        deprecation = null,
        is_simd = false,
        is_foreign = false,
    }
    let no_args: List(Ty) = list(0)
    let sl = struct_layout(&it, &def, &no_args, &reg)
    // Physical order i64, i16, i8 - but offsets stay keyed by declaration index.
    assert_eq(sl.offsets[1], 0 as usize, "i64 placed first")
    assert_eq(sl.offsets[2], 8 as usize, "i16 packed after the i64")
    assert_eq(sl.offsets[0], 10 as usize, "i8 packed last")
    assert_eq(sl.size, 16 as usize, "auto packs to 16 (declaration order would be 24)")
    assert_eq(sl.align, 8 as usize, "alignment is the widest field")
}

test "C repr keeps declaration order and C padding" {
    let it = type_interner()
    defer it.deinit()
    let reg = nominal_registry()
    defer reg.deinit()
    let fields: List(Field) = list(3)
    fields.push(Field { name = "a", ty = prim_of(PrimitiveKind.I8), decl_span = none_span() })
    fields.push(Field { name = "b", ty = prim_of(PrimitiveKind.I64), decl_span = none_span() })
    fields.push(Field { name = "c", ty = prim_of(PrimitiveKind.I16), decl_span = none_span() })
    let def = StructDef {
        fqn = "T",
        module = "",
        is_pub = true,
        type_params = list(0),
        fields = fields,
        decl_span = none_span(),
        deprecation = null,
        is_simd = false,
        is_foreign = true,
    }
    let no_args: List(Ty) = list(0)
    let sl = struct_layout(&it, &def, &no_args, &reg)
    assert_eq(sl.offsets[0], 0 as usize, "first field at offset 0")
    assert_eq(sl.offsets[1], 8 as usize, "i64 padded to offset 8")
    assert_eq(sl.offsets[2], 16 as usize, "i16 follows the i64")
    assert_eq(sl.size, 24 as usize, "#foreign keeps the C padding")
}

test "generic struct substitutes type parameters" {
    let it = type_interner()
    defer it.deinit()
    let reg = nominal_registry()
    defer reg.deinit()
    let params: List(VarId) = list(2)
    params.push(0u32)
    params.push(1u32)
    let fields: List(Field) = list(2)
    fields.push(Field {
        name = "first",
        ty = it.var_of(.{ id = 0u32, level = 0u32 }),
        decl_span = none_span(),
    })
    fields.push(Field {
        name = "second",
        ty = it.var_of(.{ id = 1u32, level = 0u32 }),
        decl_span = none_span(),
    })
    let def = StructDef {
        fqn = "Pair",
        module = "",
        is_pub = true,
        type_params = params,
        fields = fields,
        decl_span = none_span(),
        deprecation = null,
        is_simd = false,
        is_foreign = false,
    }
    let args: List(Ty) = list(2)
    args.push(prim_of(PrimitiveKind.I64))
    args.push(prim_of(PrimitiveKind.I64))
    let sl = struct_layout(&it, &def, &args, &reg)
    // Both args are i64 (align 8) so order is identity; size proves the Var fields resolved to i64.
    assert_eq(sl.offsets[1], 8 as usize, "second field after the first")
    assert_eq(sl.size, 16 as usize, "Pair(i64, i64) is two 8-byte words")
}

test "tagged enum reserves a tag plus the largest payload" {
    let it = type_interner()
    defer it.deinit()
    let reg = nominal_registry()
    defer reg.deinit()
    let variants: List(VariantDef) = list(3)
    let p_a: List(Ty) = list(1)
    p_a.push(prim_of(PrimitiveKind.I32))
    variants.push(VariantDef { name = "A", payloads = p_a, decl_span = none_span() })
    let p_b: List(Ty) = list(1)
    p_b.push(prim_of(PrimitiveKind.I64))
    variants.push(VariantDef { name = "B", payloads = p_b, decl_span = none_span() })
    variants.push(VariantDef { name = "C", payloads = list(0), decl_span = none_span() })
    let def = EnumDef {
        fqn = "E",
        module = "",
        is_pub = true,
        type_params = list(0),
        variants = variants,
        tag_values = null,
        decl_span = none_span(),
        deprecation = null,
    }
    let no_args: List(Ty) = list(0)
    let el = enum_layout(&it, &def, &no_args, &reg)
    assert_eq(el.tag_size, 4 as usize, "discriminant is 4 bytes")
    assert_eq(el.payload_offset, 8 as usize, "i64 payload forces 8-byte alignment")
    assert_eq(el.size, 16 as usize, "tag + largest payload, aligned")
}

test "payloadless enum is just the tag" {
    let it = type_interner()
    defer it.deinit()
    let reg = nominal_registry()
    defer reg.deinit()
    let variants: List(VariantDef) = list(2)
    variants.push(VariantDef { name = "A", payloads = list(0), decl_span = none_span() })
    variants.push(VariantDef { name = "B", payloads = list(0), decl_span = none_span() })
    let def = EnumDef {
        fqn = "Flag",
        module = "",
        is_pub = true,
        type_params = list(0),
        variants = variants,
        tag_values = null,
        decl_span = none_span(),
        deprecation = null,
    }
    let no_args: List(Ty) = list(0)
    let el = enum_layout(&it, &def, &no_args, &reg)
    assert_eq(el.size, 4 as usize, "naked enum is a 4-byte tag")
}

test "layout cache memoises by interned type id" {
    let it = type_interner()
    defer it.deinit()
    let reg = nominal_registry()
    defer reg.deinit()
    let cache = layout_cache()
    defer cache.deinit()

    let a: Ty = it.array_of(prim_of(PrimitiveKind.I64), 3)
    let first = layout_of(&it, a, &reg, Some(&cache))
    assert_eq(first.size, 24 as usize, "computed layout is correct")
    assert_true(cache.entries.len > a as usize, "cache grew to cover the id")
    assert_eq(cache.entries[a as usize].size, 24 as usize, "entry holds the layout")

    let again = layout_of(&it, a, &reg, Some(&cache))
    assert_eq(again.size, 24 as usize, "cached result matches")
    assert_eq(again.align, 8 as usize, "alignment survives the round trip")
}

test "Option of a reference uses the pointer niche" {
    let it = type_interner()
    defer it.deinit()
    let reg = nominal_registry()
    defer reg.deinit()

    let some: List(Ty) = list(1)
    some.push(it.var_of(.{ id = 0, level = 0 }))
    let variants: List(VariantDef) = list(2)
    variants.push(VariantDef { name = "Some", payloads = some, decl_span = none_span() })
    variants.push(VariantDef { name = "None", payloads = list(0), decl_span = none_span() })
    let params: List(VarId) = list(1)
    params.push(0)
    let def = EnumDef {
        fqn = FQN_OPTION,
        module = "core.option",
        is_pub = true,
        type_params = params,
        variants = variants,
        tag_values = null,
        decl_span = none_span(),
        deprecation = null,
    }

    let niche_args: List(Ty) = list(1)
    niche_args.push(it.ref_of(prim_of(PrimitiveKind.I32)))
    let niche = enum_layout(&it, &def, &niche_args, &reg)
    assert_true(niche.is_niche, "Option(&i32) collapses to a nullable pointer")
    assert_eq(niche.size, 8, "the niche is pointer-sized")

    let val_args: List(Ty) = list(1)
    val_args.push(prim_of(PrimitiveKind.I32))
    let val = enum_layout(&it, &def, &val_args, &reg)
    assert_true(!val.is_niche, "Option(i32) keeps a tag")
    assert_eq(val.size, 8, "tag + i32 payload")
}
