// Memory layout for codegen: size, alignment, and field offsets of any `Ty`.
// FIR is flat (7 scalars + `ptr`; aggregates are opaque byte buffers), so
// lowering computes layout here before it can emit a field access.
//
// Recursion stops at `Ref` (a pointer is 8 bytes), so the type graph is
// acyclic and needs no cycle-breaking; a by-value cycle is an infinite type
// the typer rejects.
//
// Default `auto` reorders fields by descending alignment to minimise size;
// `#foreign` is `repr(C)` (declaration order). The C# backend still does
// C-order always - see docs/known-issues.md.

import std.allocator
import std.list
import std.option
import std.string
import std.test
import flang_core.span
import flang_typer.type
import flang_typer.nominal_registry
import flang_typer.well_known

// Size and alignment of a value, in bytes.
pub type Layout = struct {
    size: usize
    align: usize
}

// A struct/tuple/record layout: total size and alignment plus the byte
// offset of each field. `offsets` is indexed by *declaration* order (so a
// resolved field index addresses it directly); under `auto` the values
// need not increase monotonically, since fields are physically reordered.
// The caller owns `offsets`.
pub type StructLayout = struct {
    size: usize
    align: usize
    offsets: List(usize)
}

// A tagged-union enum layout. `tag_size` is the discriminant width and
// `payload_offset` where the largest variant payload begins. When
// `is_niche` is set the enum is a pointer-niche `Option(&T)`: no tag, the
// null pointer encodes the empty case.
pub type EnumLayout = struct {
    size: usize
    align: usize
    tag_size: usize
    payload_offset: usize
    is_niche: bool
}

// How a struct's fields map to memory. `Auto` (the default) is free to
// reorder; `C` is locked to declaration order and C ABI padding. New
// representations (e.g. packed) become new variants here.
pub type Repr = enum {
    Auto
    C
}

// A struct's representation. `#foreign` locks the layout to C ABI rules
// (spec section 6); every other struct gets the size-minimising auto layout.
pub fn repr_of(def: &StructDef) Repr {
    if def.is_foreign { return Repr.C }
    return Repr.Auto
}

// Public API

// Size and alignment of any resolved `Ty`. The type must be zonked -
// unresolved variables are sized as `i32` (a defensive fallback for
// already-erroneous input, mirroring the reference compiler).
pub fn layout_of(ty: &Ty, reg: &NominalRegistry, allocator: &Allocator? = null) Layout {
    return layout_rec(ty, reg, allocator.or_global())
}

// Layout of a struct instantiation: `args` substitutes the struct's type
// parameters (empty for non-generic structs).
pub fn struct_layout(def: &StructDef, args: &List(Ty), reg: &NominalRegistry, allocator: &Allocator? = null) StructLayout {
    return struct_layout_impl(def, args, reg, allocator.or_global())
}

// Layout of an enum instantiation. Recognises the `Option(&T)` niche.
pub fn enum_layout(def: &EnumDef, args: &List(Ty), reg: &NominalRegistry, allocator: &Allocator? = null) EnumLayout {
    return enum_layout_impl(def, args, reg, allocator.or_global())
}

// Core walk

fn layout_rec(ty: &Ty, reg: &NominalRegistry, alloc: &Allocator) Layout {
    return ty.* match {
        Var(_) => lay(4, 4),
        Prim(p) => prim_layout(p),
        Ref(_) => lay(8, 8),
        Func(_) => lay(8, 8),
        Array(a) => array_layout(&a, reg, alloc),
        Tuple(elems) => aggregate_size(&elems, reg, alloc),
        Record(fields) => record_size(&fields, reg, alloc),
        Nominal(nr) => nominal_layout(&nr, reg, alloc),
        Never => lay(0, 1),
        Void => lay(0, 1),
        Error => lay(0, 1),
    }
}

fn prim_layout(p: PrimitiveKind) Layout {
    return p match {
        Bool => lay(1, 1),
        I8 => lay(1, 1),
        U8 => lay(1, 1),
        I16 => lay(2, 2),
        U16 => lay(2, 2),
        I32 => lay(4, 4),
        U32 => lay(4, 4),
        Char => lay(4, 4),
        F32 => lay(4, 4),
        I64 => lay(8, 8),
        U64 => lay(8, 8),
        ISize => lay(8, 8),
        USize => lay(8, 8),
        F64 => lay(8, 8),
    }
}

fn array_layout(a: &ArrayTy, reg: &NominalRegistry, alloc: &Allocator) Layout {
    let el = layout_rec(a.elem, reg, alloc)
    return lay(el.size * a.length, el.align)
}

// Fold a sequence of field types into offsets, total size and alignment.
// Fields are placed in `field_order` (declaration order for `C`, descending
// alignment for `Auto`), but `offsets` is written back indexed by
// declaration order so callers address it with a field's declared index.
fn fields_layout(tys: &List(Ty), repr: Repr, reg: &NominalRegistry, alloc: &Allocator) StructLayout {
    let n = tys.len
    let fls: List(Layout) = list(n, alloc)
    let max_align: usize = 1
    for i in 0..n {
        let fl = layout_rec(&tys[i], reg, alloc)
        fls.push(fl)
        if fl.align > max_align { max_align = fl.align }
    }

    let order = field_order(&fls, repr, max_align, alloc)

    let offsets: List(usize) = list(n, alloc)
    for i in 0..n { offsets.push(0) }
    let cursor: usize = 0
    for k in 0..order.len {
        let di = order[k]
        let fl = &fls[di]
        let off = align_up(cursor, fl.align)
        offsets[di] = off
        cursor = off + fl.size
    }

    fls.deinit()
    order.deinit()
    return .{ size = align_up(cursor, max_align), align = max_align, offsets = offsets }
}

// Physical placement order of declaration indices. `C` keeps source order.
// `Auto` emits fields by descending alignment, stable within an alignment
// class: because every type's size is a multiple of its own alignment,
// this packs each field at its natural offset with zero internal padding -
// the minimal-size layout. Alignments are powers of two, so a halving scan
// from `max_align` down to 1 buckets them without a sort.
fn field_order(fls: &List(Layout), repr: Repr, max_align: usize, alloc: &Allocator) List(usize) {
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
            if fls[i].align == a { order.push(i) }
        }
        if a == 1 { break }
        a = a / 2
    }
    return order
}

// Size/align of a positional tuple or anonymous record (offsets
// discarded). These have no declaration to lock them, so they take the
// default auto layout.
fn aggregate_size(elems: &List(Ty), reg: &NominalRegistry, alloc: &Allocator) Layout {
    let sl = fields_layout(elems, Repr.Auto, reg, alloc)
    let r = lay(sl.size, sl.align)
    sl.offsets.deinit()
    return r
}

// Size/align of an anonymous struct (offsets discarded).
fn record_size(fields: &List(Field), reg: &NominalRegistry, alloc: &Allocator) Layout {
    let tys: List(Ty) = list(fields.len, alloc)
    for i in 0..fields.len { tys.push(fields[i].ty) }
    let r = aggregate_size(&tys, reg, alloc)
    tys.deinit()
    return r
}

fn nominal_layout(nr: &NominalRef, reg: &NominalRegistry, alloc: &Allocator) Layout {
    let def = reg.get(nr.id)
    return def.* match {
        NomStruct(s) => struct_size(&s, &nr.args, reg, alloc),
        NomEnum(e) => enum_size(&e, &nr.args, reg, alloc),
    }
}

fn struct_size(def: &StructDef, args: &List(Ty), reg: &NominalRegistry, alloc: &Allocator) Layout {
    let sl = struct_layout_impl(def, args, reg, alloc)
    let r = lay(sl.size, sl.align)
    sl.offsets.deinit()
    return r
}

fn enum_size(def: &EnumDef, args: &List(Ty), reg: &NominalRegistry, alloc: &Allocator) Layout {
    let el = enum_layout_impl(def, args, reg, alloc)
    return lay(el.size, el.align)
}

// Aggregates

fn struct_layout_impl(def: &StructDef, args: &List(Ty), reg: &NominalRegistry, alloc: &Allocator) StructLayout {
    let tys: List(Ty) = list(def.fields.len, alloc)
    for i in 0..def.fields.len {
        tys.push(subst(&def.fields[i].ty, &def.type_params, args, alloc))
    }
    let sl = fields_layout(&tys, repr_of(def), reg, alloc)
    tys.deinit()
    if def.is_simd { return simd_layout(sl) }
    return sl
}

// SIMD vectors over-align to the next power-of-two of their byte size
// (min 16), so the C backend can request vector alignment.
fn simd_layout(sl: StructLayout) StructLayout {
    let want = next_pow2(sl.size)
    let align = if want > 16 { want } else { 16 }
    return .{ size = align_up(sl.size, align), align = align, offsets = sl.offsets }
}

fn enum_layout_impl(def: &EnumDef, args: &List(Ty), reg: &NominalRegistry, alloc: &Allocator) EnumLayout {
    if is_option_niche(def, args) {
        return .{ size = 8, align = 8, tag_size = 0, payload_offset = 0, is_niche = true }
    }

    const tag_size: usize = 4
    let largest: usize = 0
    let max_palign: usize = 1
    let any_payload: bool = false

    for i in 0..def.variants.len {
        let v = &def.variants[i]
        if v.payloads.len == 0 { continue }
        any_payload = true
        let ptys: List(Ty) = list(v.payloads.len, alloc)
        for j in 0..v.payloads.len {
            ptys.push(subst(&v.payloads[j], &def.type_params, args, alloc))
        }
        let pl = fields_layout(&ptys, Repr.Auto, reg, alloc)
        ptys.deinit()
        pl.offsets.deinit()
        if pl.size > largest { largest = pl.size }
        if pl.align > max_palign { max_palign = pl.align }
    }

    if !any_payload {
        return .{ size = tag_size, align = 4, tag_size = tag_size, payload_offset = 0, is_niche = false }
    }

    let align = if max_palign > 4 { max_palign } else { 4 }
    let payload_offset = align_up(tag_size, max_palign)
    let size = align_up(payload_offset + largest, align)
    return .{ size = size, align = align, tag_size = tag_size, payload_offset = payload_offset, is_niche = false }
}

fn is_option_niche(def: &EnumDef, args: &List(Ty)) bool {
    if def.fqn != FQN_OPTION { return false }
    if args.len != 1 { return false }
    return args[0] match {
        Ref(_) => true,
        _ => false,
    }
}

// Type-parameter substitution
//
// A generic struct/enum stores its fields against the declaration's type
// parameters; instantiating it replaces those variables with the concrete
// `args`. Substituted types are scratch - they alias the originals' heap
// buffers and the freshly-boxed nodes live in `alloc` - so the caller must
// pass an arena and must never deinit the results.

fn subst(ty: &Ty, params: &List(VarId), args: &List(Ty), alloc: &Allocator) Ty {
    if params.len == 0 { return ty.* }
    return ty.* match {
        Var(v) => subst_var(v, params, args),
        Ref(inner) => Ty.Ref(box(alloc, subst(inner, params, args, alloc))),
        Array(a) => Ty.Array(.{ elem = box(alloc, subst(a.elem, params, args, alloc)), length = a.length }),
        Func(f) => subst_func(&f, params, args, alloc),
        Tuple(elems) => Ty.Tuple(subst_list(&elems, params, args, alloc)),
        Record(fields) => Ty.Record(subst_fields(&fields, params, args, alloc)),
        Nominal(nr) => Ty.Nominal(.{ id = nr.id, args = subst_list(&nr.args, params, args, alloc) }),
        _ => ty.*,
    }
}

fn subst_var(v: TyVar, params: &List(VarId), args: &List(Ty)) Ty {
    for i in 0..params.len {
        if params[i] == v.id { return args[i] }
    }
    return Ty.Var(v)
}

fn subst_list(tys: &List(Ty), params: &List(VarId), args: &List(Ty), alloc: &Allocator) List(Ty) {
    let out: List(Ty) = list(tys.len, alloc)
    for ty in tys {
        out.push(subst(&ty, params, args, alloc))
    }
    return out
}

fn subst_fields(fields: &List(Field), params: &List(VarId), args: &List(Ty), alloc: &Allocator) List(Field) {
    let out: List(Field) = list(fields.len, alloc)
    for i in 0..fields.len {
        out.push(Field { name = fields[i].name, ty = subst(&fields[i].ty, params, args, alloc) })
    }
    return out
}

fn subst_func(f: &FunctionTy, params: &List(VarId), args: &List(Ty), alloc: &Allocator) Ty {
    let ps = subst_list(&f.params, params, args, alloc)
    let ret = box(alloc, subst(f.ret, params, args, alloc))
    return Ty.Func(.{ params = ps, ret = ret })
}

// Helpers

fn lay(size: usize, align: usize) Layout {
    return .{ size = size, align = align }
}

// Round `offset` up to the next multiple of `align`.
fn align_up(offset: usize, align: usize) usize {
    if align <= 1 { return offset }
    return ((offset + align - 1) / align) * align
}

fn next_pow2(v: usize) usize {
    let n: usize = 1
    while n < v { n = n * 2 }
    return n
}

// Tests

test "primitives have natural size and alignment" {
    let reg = nominal_registry()
    assert_eq(layout_of(&Ty.Prim(PrimitiveKind.Bool), &reg).size, 1 as usize, "bool is 1 byte")
    assert_eq(layout_of(&Ty.Prim(PrimitiveKind.I32), &reg).size, 4 as usize, "i32 is 4 bytes")
    assert_eq(layout_of(&Ty.Prim(PrimitiveKind.I32), &reg).align, 4 as usize, "i32 aligns to 4")
    assert_eq(layout_of(&Ty.Prim(PrimitiveKind.F64), &reg).size, 8 as usize, "f64 is 8 bytes")
    assert_eq(layout_of(&Ty.Prim(PrimitiveKind.Char), &reg).size, 4 as usize, "char is a 4-byte codepoint")
    assert_eq(layout_of(&Ty.Prim(PrimitiveKind.USize), &reg).size, 8 as usize, "usize is 8 bytes on a 64-bit target")
}

test "references and arrays" {
    let reg = nominal_registry()
    let none_alloc: &Allocator? = null
    let alloc = none_alloc.or_global()

    let r = Ty.Ref(box(alloc, Ty.Prim(PrimitiveKind.I32)))
    assert_eq(layout_of(&r, &reg).size, 8 as usize, "a reference is a pointer")

    let a = Ty.Array(.{ elem = box(alloc, Ty.Prim(PrimitiveKind.I32)), length = 4 })
    assert_eq(layout_of(&a, &reg).size, 16 as usize, "[i32; 4] is 16 bytes")
    assert_eq(layout_of(&a, &reg).align, 4 as usize, "[i32; 4] aligns to its element")

    let a8 = Ty.Array(.{ elem = box(alloc, Ty.Prim(PrimitiveKind.I64)), length = 3 })
    assert_eq(layout_of(&a8, &reg).size, 24 as usize, "[i64; 3] is 24 bytes")
}

test "auto layout reorders fields by alignment to minimise padding" {
    let reg = nominal_registry()
    let fields: List(Field) = list(3)
    fields.push(Field { name = "a", ty = Ty.Prim(PrimitiveKind.I8) })   // decl 0, align 1
    fields.push(Field { name = "b", ty = Ty.Prim(PrimitiveKind.I64) })  // decl 1, align 8
    fields.push(Field { name = "c", ty = Ty.Prim(PrimitiveKind.I16) })  // decl 2, align 2
    let def = StructDef {
        fqn = "T", module = "", is_pub = true,
        type_params = list(0), fields = fields,
        decl_span = none_span(), deprecation = null,
        is_simd = false, is_foreign = false,
    }
    let no_args: List(Ty) = list(0)
    let sl = struct_layout(&def, &no_args, &reg)
    // Physical order i64, i16, i8 - but offsets stay keyed by declaration index.
    assert_eq(sl.offsets[1], 0 as usize, "i64 placed first")
    assert_eq(sl.offsets[2], 8 as usize, "i16 packed after the i64")
    assert_eq(sl.offsets[0], 10 as usize, "i8 packed last")
    assert_eq(sl.size, 16 as usize, "auto packs to 16 (declaration order would be 24)")
    assert_eq(sl.align, 8 as usize, "alignment is the widest field")
}

test "C repr keeps declaration order and C padding" {
    let reg = nominal_registry()
    let fields: List(Field) = list(3)
    fields.push(Field { name = "a", ty = Ty.Prim(PrimitiveKind.I8) })
    fields.push(Field { name = "b", ty = Ty.Prim(PrimitiveKind.I64) })
    fields.push(Field { name = "c", ty = Ty.Prim(PrimitiveKind.I16) })
    let def = StructDef {
        fqn = "T", module = "", is_pub = true,
        type_params = list(0), fields = fields,
        decl_span = none_span(), deprecation = null,
        is_simd = false, is_foreign = true,
    }
    let no_args: List(Ty) = list(0)
    let sl = struct_layout(&def, &no_args, &reg)
    assert_eq(sl.offsets[0], 0 as usize, "first field at offset 0")
    assert_eq(sl.offsets[1], 8 as usize, "i64 padded to offset 8")
    assert_eq(sl.offsets[2], 16 as usize, "i16 follows the i64")
    assert_eq(sl.size, 24 as usize, "#foreign keeps the C padding")
}

test "generic struct substitutes type parameters" {
    let reg = nominal_registry()
    let params: List(VarId) = list(2)
    params.push(0u32)
    params.push(1u32)
    let fields: List(Field) = list(2)
    fields.push(Field { name = "first", ty = Ty.Var(.{ id = 0u32, level = 0u32 }) })
    fields.push(Field { name = "second", ty = Ty.Var(.{ id = 1u32, level = 0u32 }) })
    let def = StructDef {
        fqn = "Pair", module = "", is_pub = true,
        type_params = params, fields = fields,
        decl_span = none_span(), deprecation = null,
        is_simd = false, is_foreign = false,
    }
    let args: List(Ty) = list(2)
    args.push(Ty.Prim(PrimitiveKind.I64))
    args.push(Ty.Prim(PrimitiveKind.I64))
    let sl = struct_layout(&def, &args, &reg)
    // Both args are i64 (align 8) so order is identity; size proves the
    // Var fields resolved to i64 (else the i32 fallback would give 8).
    assert_eq(sl.offsets[1], 8 as usize, "second field after the first")
    assert_eq(sl.size, 16 as usize, "Pair(i64, i64) is two 8-byte words")
}

test "tagged enum reserves a tag plus the largest payload" {
    let reg = nominal_registry()
    let variants: List(VariantDef) = list(3)
    let p_a: List(Ty) = list(1); p_a.push(Ty.Prim(PrimitiveKind.I32))
    variants.push(VariantDef { name = "A", payloads = p_a })
    let p_b: List(Ty) = list(1); p_b.push(Ty.Prim(PrimitiveKind.I64))
    variants.push(VariantDef { name = "B", payloads = p_b })
    variants.push(VariantDef { name = "C", payloads = list(0) })
    let def = EnumDef {
        fqn = "E", module = "", is_pub = true,
        type_params = list(0), variants = variants,
        tag_values = null, decl_span = none_span(), deprecation = null,
    }
    let no_args: List(Ty) = list(0)
    let el = enum_layout(&def, &no_args, &reg)
    assert_eq(el.tag_size, 4 as usize, "discriminant is 4 bytes")
    assert_eq(el.payload_offset, 8 as usize, "i64 payload forces 8-byte alignment")
    assert_eq(el.size, 16 as usize, "tag + largest payload, aligned")
}

test "payloadless enum is just the tag" {
    let reg = nominal_registry()
    let variants: List(VariantDef) = list(2)
    variants.push(VariantDef { name = "A", payloads = list(0) })
    variants.push(VariantDef { name = "B", payloads = list(0) })
    let def = EnumDef {
        fqn = "Flag", module = "", is_pub = true,
        type_params = list(0), variants = variants,
        tag_values = null, decl_span = none_span(), deprecation = null,
    }
    let no_args: List(Ty) = list(0)
    let el = enum_layout(&def, &no_args, &reg)
    assert_eq(el.size, 4 as usize, "naked enum is a 4-byte tag")
}

test "Option of a reference uses the pointer niche" {
    let reg = nominal_registry()
    let none_alloc: &Allocator? = null
    let alloc = none_alloc.or_global()

    let some: List(Ty) = list(1); some.push(Ty.Var(.{ id = 0, level = 0 }))
    let variants: List(VariantDef) = list(2)
    variants.push(VariantDef { name = "Some", payloads = some })
    variants.push(VariantDef { name = "None", payloads = list(0) })
    let params: List(VarId) = list(1); params.push(0)
    let def = EnumDef {
        fqn = FQN_OPTION, module = "core.option", is_pub = true,
        type_params = params, variants = variants,
        tag_values = null, decl_span = none_span(), deprecation = null,
    }

    let niche_args: List(Ty) = list(1)
    niche_args.push(Ty.Ref(box(alloc, Ty.Prim(PrimitiveKind.I32))))
    let niche = enum_layout(&def, &niche_args, &reg)
    assert_true(niche.is_niche, "Option(&i32) collapses to a nullable pointer")
    assert_eq(niche.size, 8, "the niche is pointer-sized")

    let val_args: List(Ty) = list(1)
    val_args.push(Ty.Prim(PrimitiveKind.I32))
    let val = enum_layout(&def, &val_args, &reg)
    assert_true(!val.is_niche, "Option(i32) keeps a tag")
    assert_eq(val.size, 8, "tag + i32 payload")
}
